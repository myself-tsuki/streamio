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

    public override init() {
        super.init()
        sessionQueue.async { [self] in
            session.beginConfiguration()
            session.sessionPreset = .inputPriority

            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

            // macOS lets us ask for the mixer's native format directly, saving a conversion.
            audioOutput.audioSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: AudioMixer.sampleRate,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsNonInterleaved: true
            ]
            audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
            if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }
            session.commitConfiguration()
        }

        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
        ) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.onError?(error?.localizedDescription ?? String(localized: "The capture session stopped unexpectedly."))
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
            session.beginConfiguration()

            if videoInput?.device != camera {
                if let videoInput { session.removeInput(videoInput) }
                videoInput = nil
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
                Self.applyBestFormat(to: camera, width: canvasWidth, height: canvasHeight, fps: fps)
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
            onAudio?(sampleBuffer)
        }
    }
}
