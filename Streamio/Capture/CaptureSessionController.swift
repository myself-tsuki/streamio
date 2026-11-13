//
//  CaptureSessionController.swift
//  Streamio
//
//  AVFoundation capture for the camera (video) and microphone (Mic/Aux audio).
//  Configuration runs on a private session queue; sample buffers arrive on dedicated queues.
//

import AVFoundation
import CoreMedia
import Foundation

nonisolated public final class CaptureSessionController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {

    public var onVideo: (@Sendable (CMSampleBuffer) -> Void)?
    public var onAudio: (@Sendable (CMSampleBuffer) -> Void)?
    public var onError: (@Sendable (String) -> Void)?

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.streamio.capture.session", qos: .userInitiated)
    private let videoQueue = DispatchQueue(label: "com.streamio.capture.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "com.streamio.capture.audio", qos: .userInteractive)

    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var runtimeErrorObserver: NSObjectProtocol?
    private let heartbeat = AudioHeartbeat()
    private var watchdog: DispatchSourceTimer?
    /// Device + canvas the active format was chosen for. Re-locking a camera that is already
    /// configured makes many USB webcams restart their stream, which shows as black blinks.
    private var appliedFormatKey: String?

    public override init() {
        super.init()
        sessionQueue.async { [self] in
            session.beginConfiguration()
            if session.canSetSessionPreset(.high) {
                session.sessionPreset = .high
            }

            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
            audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
            if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }
            session.commitConfiguration()
        }

        // A USB microphone that hiccups can leave the session running but silent. Restart it.
        let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self, self.videoInput != nil || self.audioInput != nil else { return }
            if !self.session.isRunning {
                DiagnosticsLog.log("capture", "camera session is not running: starting it again")
                self.session.startRunning()
            }
        }
        timer.resume()
        watchdog = timer

        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
        ) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
            DiagnosticsLog.log("capture", "session runtime error: \(error?.localizedDescription ?? "unknown")")
            self?.onError?(error?.localizedDescription ?? String(localized: "The capture session stopped unexpectedly."))
            self?.restartAfterError()
        }
    }

    /// A cable glitch can stop the session. Try again shortly so the camera and microphone come
    /// back by themselves once the device is there.
    private func restartAfterError() {
        sessionQueue.asyncAfter(deadline: .now() + 1) { [self] in
            guard videoInput != nil || audioInput != nil, !session.isRunning else { return }
            session.startRunning()
        }
    }

    deinit {
        if let runtimeErrorObserver {
            NotificationCenter.default.removeObserver(runtimeErrorObserver)
        }
    }

    /// Swaps inputs. Pass nil to remove the camera (e.g. a display scene) or the microphone.
    public func configure(camera: AVCaptureDevice?, microphone: AVCaptureDevice?, canvasWidth: Int, canvasHeight: Int, fps: Int) {
        sessionQueue.async { [self] in
            // Nothing to change: leave the running session alone. Even an empty begin/commit pair
            // can make a USB camera or microphone skip a moment.
            let formatKey = camera.map { "\($0.uniqueID)|\(canvasWidth)x\(canvasHeight)@\(fps)" }
            if videoInput?.device == camera, audioInput?.device == microphone,
               formatKey == nil || formatKey == appliedFormatKey {
                let needsSession = videoInput != nil || audioInput != nil
                if needsSession, !session.isRunning { session.startRunning() }
                return
            }
            session.beginConfiguration()

            if videoInput?.device != camera {
                if let videoInput { session.removeInput(videoInput) }
                videoInput = nil
                appliedFormatKey = nil
                if let camera {
                    do {
                        let input = try AVCaptureDeviceInput(device: camera)
                        if session.canAddInput(input) {
                            session.addInput(input)
                            videoInput = input
                        }
                    } catch {
                        onError?(error.localizedDescription)
                    }
                }
            }
            if let camera = videoInput?.device {
                let formatKey = "\(camera.uniqueID)|\(canvasWidth)x\(canvasHeight)@\(fps)"
                if formatKey != appliedFormatKey {
                    Self.applyBestFormat(to: camera, width: canvasWidth, height: canvasHeight, fps: fps)
                    appliedFormatKey = formatKey
                }
            }

            if audioInput?.device != microphone {
                if let audioInput { session.removeInput(audioInput) }
                audioInput = nil
                if let microphone {
                    do {
                        let input = try AVCaptureDeviceInput(device: microphone)
                        if session.canAddInput(input) {
                            session.addInput(input)
                            audioInput = input
                        }
                    } catch {
                        onError?(error.localizedDescription)
                    }
                }
            }

            session.commitConfiguration()

            let needsSession = videoInput != nil || audioInput != nil
            if needsSession, !session.isRunning {
                heartbeat.beat()
                session.startRunning()
            } else if !needsSession, session.isRunning {
                session.stopRunning()
            }
        }
    }

    public func stop() {
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    /// Picks the smallest format that covers the canvas at the requested frame rate,
    /// falling back to the largest one available, then locks the frame duration.
    static func applyBestFormat(to device: AVCaptureDevice, width: Int, height: Int, fps: Int) {
        let rate = Double(fps)
        let supportsRate: (AVCaptureDevice.Format) -> Bool = { format in
            format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= rate && rate <= $0.maxFrameRate }
        }
        let candidates = device.formats.filter(supportsRate)
        let pool = candidates.isEmpty ? device.formats : candidates

        func area(_ format: AVCaptureDevice.Format) -> Int32 {
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return size.width * size.height
        }
        let covering = pool.filter {
            let size = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return Int(size.width) >= width && Int(size.height) >= height
        }
        let chosen = covering.min { area($0) < area($1) } ?? pool.max { area($0) < area($1) }
        guard let chosen else { return }

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.activeFormat != chosen {
                device.activeFormat = chosen
            }
            if supportsRate(chosen) {
                let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
            }
        } catch {
            // The device is in use elsewhere; it keeps its current format.
        }
    }

    // MARK: - Sample buffer delegate

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput {
            onVideo?(sampleBuffer)
        } else if output === audioOutput {
            heartbeat.beat()
            onAudio?(sampleBuffer)
        }
    }
}
