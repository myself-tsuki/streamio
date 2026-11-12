//
//  CaptureSessionController.swift
//  Streamio
//

import Foundation
import AVFoundation
import CoreMedia
import Accelerate

public protocol CaptureSessionDelegate: AnyObject {
    func captureSession(_ controller: CaptureSessionController, didOutputVideoSampleBuffer sampleBuffer: CMSampleBuffer)
    func captureSession(_ controller: CaptureSessionController, didOutputAudioSampleBuffer sampleBuffer: CMSampleBuffer)
}

public final class CaptureSessionController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    public weak var delegate: CaptureSessionDelegate?

    private let captureSession = AVCaptureSession()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let audioDataOutput = AVCaptureAudioDataOutput()

    private let videoQueue = DispatchQueue(label: "com.streamio.videoqueue", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "com.streamio.audioqueue", qos: .userInteractive)
    private let sessionQueue = DispatchQueue(label: "com.streamio.sessionqueue", qos: .userInitiated)

    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?

    private var currentResolution: VideoResolution = .res1080p
    private var currentFps: FrameRate = .fps30

    // Callback for live VU meter (dB)
    public var onAudioLevelsUpdated: ((Float, Float) -> Void)?

    public override init() {
        super.init()
    }

    public func startSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if !self.captureSession.isRunning {
                self.captureSession.startRunning()
            }
        }
    }

    public func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
        }
    }

    public func configureSession(videoDevice: AVCaptureDevice?,
                                 audioDevice: AVCaptureDevice?,
                                 resolution: VideoResolution,
                                 frameRate: FrameRate) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.currentResolution = resolution
            self.currentFps = frameRate

            self.captureSession.beginConfiguration()

            // 1. Configure Resolution Preset
            if self.captureSession.canSetSessionPreset(resolution.preset) {
                self.captureSession.sessionPreset = resolution.preset
            } else if self.captureSession.canSetSessionPreset(.high) {
                self.captureSession.sessionPreset = .high
            }

            // 2. Video Device Input
            if let currentVideo = self.videoInput {
                self.captureSession.removeInput(currentVideo)
                self.videoInput = nil
            }

            if let videoDevice = videoDevice,
               let newVideoInput = try? AVCaptureDeviceInput(device: videoDevice),
               self.captureSession.canAddInput(newVideoInput) {
                self.captureSession.addInput(newVideoInput)
                self.videoInput = newVideoInput

                // Set framerate on active video device
                self.applyFrameRate(frameRate, to: videoDevice)
            }

            // 3. Audio Device Input
            if let currentAudio = self.audioInput {
                self.captureSession.removeInput(currentAudio)
                self.audioInput = nil
            }

            if let audioDevice = audioDevice,
               let newAudioInput = try? AVCaptureDeviceInput(device: audioDevice),
               self.captureSession.canAddInput(newAudioInput) {
                self.captureSession.addInput(newAudioInput)
                self.audioInput = newAudioInput
            }

            // 4. Video Output
            if !self.captureSession.outputs.contains(self.videoDataOutput) {
                self.videoDataOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                self.videoDataOutput.alwaysDiscardsLateVideoFrames = true
                self.videoDataOutput.setSampleBufferDelegate(self, queue: self.videoQueue)
                if self.captureSession.canAddOutput(self.videoDataOutput) {
                    self.captureSession.addOutput(self.videoDataOutput)
                }
            }

            // 5. Audio Output
            if !self.captureSession.outputs.contains(self.audioDataOutput) {
                self.audioDataOutput.setSampleBufferDelegate(self, queue: self.audioQueue)
                if self.captureSession.canAddOutput(self.audioDataOutput) {
                    self.captureSession.addOutput(self.audioDataOutput)
                }
            }

            self.captureSession.commitConfiguration()

            if !self.captureSession.isRunning {
                self.captureSession.startRunning()
            }
        }
    }

    private func applyFrameRate(_ frameRate: FrameRate, to device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            let desiredDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate.rawValue))
            
            // Find format matching framerate or adjust activeVideoMinFrameDuration
            var bestFormat: AVCaptureDevice.Format?
            for format in device.formats {
                for range in format.videoSupportedFrameRateRanges {
                    if range.minFrameRate <= Double(frameRate.rawValue) && Double(frameRate.rawValue) <= range.maxFrameRate {
                        bestFormat = format
                        break
                    }
                }
                if bestFormat != nil { break }
            }

            if let format = bestFormat, device.activeFormat != format {
                device.activeFormat = format
            }

            device.activeVideoMinFrameDuration = desiredDuration
            device.activeVideoMaxFrameDuration = desiredDuration
            device.unlockForConfiguration()
        } catch {
            print("Failed to lock device for configuration: \(error)")
        }
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output == videoDataOutput {
            delegate?.captureSession(self, didOutputVideoSampleBuffer: sampleBuffer)
        } else if output == audioDataOutput {
            calculateAudioLevels(sampleBuffer: sampleBuffer)
            delegate?.captureSession(self, didOutputAudioSampleBuffer: sampleBuffer)
        }
    }

    private func calculateAudioLevels(sampleBuffer: CMSampleBuffer) {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var lengthAtOffset: Int = 0
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?

        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )

        guard status == noErr, let rawData = dataPointer, totalLength > 0 else { return }

        // Audio format extraction
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else {
            return
        }

        let channelCount = Int(asbd.mChannelsPerFrame)
        let sampleCount = totalLength / (MemoryLayout<Int16>.size * max(1, channelCount))
        guard sampleCount > 0 else { return }

        let samples = rawData.withMemoryRebound(to: Int16.self, capacity: totalLength / MemoryLayout<Int16>.size) { ptr in
            Array(UnsafeBufferPointer(start: ptr, count: min(sampleCount * max(1, channelCount), 1024)))
        }

        var floatSamples = samples.map { Float($0) / 32768.0 }
        var rms: Float = 0.0
        vDSP_rmsqv(&floatSamples, 1, &rms, vDSP_Length(floatSamples.count))

        var db = 20.0 * log10(max(rms, 0.0001))
        db = max(-60.0, min(0.0, db))

        onAudioLevelsUpdated?(db, db)
    }
}

