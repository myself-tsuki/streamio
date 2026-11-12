//
//  StreamRecorder.swift
//  Streamio
//

import Foundation
import AVFoundation
import CoreMedia

public final class StreamRecorder: @unchecked Sendable {
    public private(set) var isRecording = false
    public private(set) var currentRecordingURL: URL?
    public private(set) var recordingDuration: TimeInterval = 0.0
    public private(set) var recordedBytes: UInt64 = 0

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?

    private var sessionStartTime: CMTime = .invalid
    private var recordingTimer: Timer?
    private let recordingQueue = DispatchQueue(label: "com.streamio.recorder", qos: .utility)

    public init() {}

    public func startRecording(width: Int32,
                               height: Int32,
                               bitrate: Int,
                               fps: Int,
                               audioAsbd: AudioStreamBasicDescription? = nil,
                               destinationDirectory: URL? = nil) throws -> URL {
        let directory = destinationDirectory ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let filename = "Streamio_Recording_\(formatter.string(from: Date())).mp4"
        let outputURL = directory.appendingPathComponent(filename)

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        // Video input settings
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2
            ]
        ]

        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true

        let sourcePixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vInput,
            sourcePixelBufferAttributes: sourcePixelBufferAttributes
        )

        if writer.canAdd(vInput) {
            writer.add(vInput)
        }

        // Audio input settings
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 160000
        ]

        let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        aInput.expectsMediaDataInRealTime = true

        if writer.canAdd(aInput) {
            writer.add(aInput)
        }

        writer.startWriting()

        self.assetWriter = writer
        self.videoInput = vInput
        self.audioInput = aInput
        self.pixelBufferAdaptor = adaptor
        self.sessionStartTime = .invalid
        self.currentRecordingURL = outputURL
        self.isRecording = true
        self.recordingDuration = 0.0
        self.recordedBytes = 0

        DispatchQueue.main.async { [weak self] in
            self?.recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self = self, self.isRecording else { return }
                self.recordingDuration += 1.0
                if let path = self.currentRecordingURL?.path,
                   let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                   let size = attrs[.size] as? UInt64 {
                    self.recordedBytes = size
                }
            }
        }

        return outputURL
    }

    public func appendVideoPixelBuffer(_ pixelBuffer: CVPixelBuffer, at timestamp: CMTime) {
        recordingQueue.async { [weak self] in
            guard let self = self, self.isRecording, let writer = self.assetWriter else { return }

            if writer.status == .unknown {
                return
            }

            if !self.sessionStartTime.isValid {
                self.sessionStartTime = timestamp
                writer.startSession(atSourceTime: timestamp)
            }

            guard let adaptor = self.pixelBufferAdaptor, adaptor.assetWriterInput.isReadyForMoreMediaData else {
                return
            }

            adaptor.append(pixelBuffer, withPresentationTime: timestamp)
        }
    }

    public func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        recordingQueue.async { [weak self] in
            guard let self = self, self.isRecording, let writer = self.assetWriter, let aInput = self.audioInput else { return }

            if !self.sessionStartTime.isValid {
                return
            }

            if aInput.isReadyForMoreMediaData {
                aInput.append(sampleBuffer)
            }
        }
    }

    public func stopRecording(completion: (@Sendable (URL?) -> Void)? = nil) {
        recordingQueue.async { [weak self] in
            guard let self = self, self.isRecording, let writer = self.assetWriter else {
                DispatchQueue.main.async { completion?(nil) }
                return
            }

            self.isRecording = false

            DispatchQueue.main.async {
                self.recordingTimer?.invalidate()
                self.recordingTimer = nil
            }

            self.videoInput?.markAsFinished()
            self.audioInput?.markAsFinished()

            let outputURL = self.currentRecordingURL
            writer.finishWriting {
                self.assetWriter = nil
                self.videoInput = nil
                self.audioInput = nil
                self.pixelBufferAdaptor = nil
                DispatchQueue.main.async {
                    completion?(outputURL)
                }
            }
        }
    }
}

