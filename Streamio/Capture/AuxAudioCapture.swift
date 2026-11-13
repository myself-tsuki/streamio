//
//  AuxAudioCapture.swift
//  Streamio
//
//  The second input device (another microphone or an audio interface) on its own capture
//  session, so both devices can run together. The first device stays on CaptureSessionController.
//

import AVFoundation
import CoreMedia
import Foundation
import QuartzCore

/// Remembers when audio last arrived, so a capture session that went quiet can be restarted.
nonisolated final class AudioHeartbeat: @unchecked Sendable {
    private let lock = NSLock()
    private var last = CACurrentMediaTime()

    func beat() { lock.withLock { last = CACurrentMediaTime() } }
    var silence: Double { lock.withLock { CACurrentMediaTime() - last } }
}

nonisolated final class AuxAudioCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    var onAudio: (@Sendable (CMSampleBuffer) -> Void)?
    var onError: (@Sendable (String) -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "com.streamio.capture.aux.audio", qos: .userInteractive)
    private let sessionQueue = DispatchQueue(label: "com.streamio.capture.aux.session", qos: .userInitiated)
    private var input: AVCaptureDeviceInput?
    private var runtimeErrorObserver: NSObjectProtocol?
    private let heartbeat = AudioHeartbeat()
    private var watchdog: DispatchSourceTimer?

    private let name: String

    init(name: String = "The second audio input") {
        self.name = name
        super.init()
        output.setSampleBufferDelegate(self, queue: queue)
        // A USB device that hiccups can leave the session running but silent. Restart it.
        let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self, self.input != nil, self.session.isRunning, self.heartbeat.silence > 3 else { return }
            DiagnosticsLog.log("capture", "audio input silent for \(Int(self.heartbeat.silence)) s: restarting capture session")
            self.session.stopRunning()
            self.session.startRunning()
            self.heartbeat.beat()
        }
        timer.resume()
        watchdog = timer
        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
        ) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.onError?(error?.localizedDescription ?? String(localized: "\(self?.name ?? "The audio input") stopped unexpectedly."))
            self?.sessionQueue.asyncAfter(deadline: .now() + 1) {
                guard let self, self.input != nil, !self.session.isRunning else { return }
                self.session.startRunning()
            }
        }
    }

    deinit {
        if let runtimeErrorObserver { NotificationCenter.default.removeObserver(runtimeErrorObserver) }
    }

    /// Uses `device`, or stops when it is nil (not added, or unplugged).
    func configure(device: AVCaptureDevice?) {
        sessionQueue.async { [self] in
            if input?.device != device {
                session.beginConfiguration()
                if let input { session.removeInput(input) }
                input = nil
                if let device {
                    do {
                        let newInput = try AVCaptureDeviceInput(device: device)
                        if session.canAddInput(newInput) {
                            session.addInput(newInput)
                            input = newInput
                        }
                        if !session.outputs.contains(output), session.canAddOutput(output) {
                            session.addOutput(output)
                        }
                    } catch {
                        onError?(error.localizedDescription)
                    }
                }
                session.commitConfiguration()
            }
            if input != nil, !session.isRunning {
                heartbeat.beat()
                session.startRunning()
            } else if input == nil, session.isRunning {
                session.stopRunning()
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let gap = heartbeat.silence
        if gap > 0.25 { DiagnosticsLog.log("capture", "\(name): no audio for \(Int(gap * 1000)) ms before this buffer") }
        heartbeat.beat()
        onAudio?(sampleBuffer)
    }
}
