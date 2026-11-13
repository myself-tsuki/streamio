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

nonisolated final class AuxAudioCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    var onAudio: (@Sendable (CMSampleBuffer) -> Void)?
    var onError: (@Sendable (String) -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "com.streamio.capture.aux.audio", qos: .userInteractive)
    private let sessionQueue = DispatchQueue(label: "com.streamio.capture.aux.session", qos: .userInitiated)
    private var input: AVCaptureDeviceInput?
    private var runtimeErrorObserver: NSObjectProtocol?

    override init() {
        super.init()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioMixer.sampleRate,
            AVNumberOfChannelsKey: Int(AudioMixer.channelCount),
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
        ) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.onError?(error?.localizedDescription ?? String(localized: "The second audio input stopped unexpectedly."))
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
                session.startRunning()
            } else if input == nil, session.isRunning {
                session.stopRunning()
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onAudio?(sampleBuffer)
    }
}
