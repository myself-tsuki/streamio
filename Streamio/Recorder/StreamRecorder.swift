//
//  StreamRecorder.swift
//  Streamio
//
//  Writes the program to disk. Video is passed through from the shared hardware encoder
//  (no second encode); audio is encoded to AAC by AVAssetWriter from the mixer output.
//

import AVFoundation
import CoreMedia
import Foundation

nonisolated public final class StreamRecorder: @unchecked Sendable {
    public struct Settings: Sendable {
        public var directory: URL
        public var format: RecordingFormat
        public var audioBitrate: AudioBitrate

        public init(directory: URL, format: RecordingFormat, audioBitrate: AudioBitrate) {
            self.directory = directory
            self.format = format
            self.audioBitrate = audioBitrate
        }
    }

    public enum Event: Sendable {
        case started(URL)
        case finished(URL)
        case failed(String)
    }

    public var onEvent: (@Sendable (Event) -> Void)?

    private let queue = DispatchQueue(label: "com.streamio.recorder", qos: .utility)

    // Confined to `queue`.
    private var settings: Settings?
    private var outputURL: URL?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var sessionStart: CMTime?
    private var isActive = false
    private var pendingAudio: [CMSampleBuffer] = []
    private var pendingVideo: [CMSampleBuffer] = []
    private var stopRequestedAt: Date?

    public init() {}

    /// Prepares a new file. The writer itself is created on the first key frame,
    /// because pass-through video needs the encoder's format description.
    public func start(_ settings: Settings) throws -> URL {
        try FileManager.default.createDirectory(at: settings.directory, withIntermediateDirectories: true)
        let url = settings.directory.appending(path: Self.fileName(format: settings.format))
        queue.sync {
            self.settings = settings
            outputURL = url
            writer = nil
            videoInput = nil
            audioInput = nil
            sessionStart = nil
            pendingAudio.removeAll()
            pendingVideo.removeAll()
            isActive = true
        }
        return url
    }

    public func appendVideo(_ frame: EncodedVideoFrame) {
        queue.async { [self] in
            guard isActive else { return }
            if writer == nil {
                guard frame.isKeyFrame else { return }
                guard createWriter(for: frame.sampleBuffer) else { return }
            }
            guard let writer, writer.status == .writing, let videoInput else {
                reportFailureIfNeeded()
                return
            }
            if sessionStart == nil {
                let start = CMSampleBufferGetPresentationTimeStamp(frame.sampleBuffer)
                writer.startSession(atSourceTime: start)
                sessionStart = start
                if let outputURL { onEvent?(.started(outputURL)) }
            }
            // Never drop a recorded video frame: a missing P-frame smears the picture until the next
            // keyframe. If the writer is busy, queue the frame and write it in order when it is ready.
            pendingVideo.append(frame.sampleBuffer)
            drainPendingVideo(into: videoInput)
            if pendingVideo.count > 300 {
                DiagnosticsLog.log("recorder", "writer is far behind: \(pendingVideo.count) video frames queued")
                pendingVideo.removeFirst(pendingVideo.count - 300)
            }
        }
    }

    public func appendAudio(_ buffer: AVAudioPCMBuffer, time: Double) {
        // Copy the PCM out of the mixer's buffer now; it is reused once we return.
        guard let sampleBuffer = PCMSampleBufferFactory.makeSampleBuffer(from: buffer, time: time) else { return }
        nonisolated(unsafe) let sample = sampleBuffer
        queue.async { [self] in
            guard isActive, let writer, writer.status == .writing, let audioInput, let sessionStart else { return }
            guard CMSampleBufferGetPresentationTimeStamp(sample) >= sessionStart else { return }
            // If the writer is briefly busy (a disk flush), keep the audio and send it in order
            // when it is ready, instead of leaving a hole in the recording.
            pendingAudio.append(sample)
            drainPendingAudio(into: audioInput)
            if pendingAudio.count > 500 { pendingAudio.removeFirst(pendingAudio.count - 500) }
        }
    }

    public func stop() {
        queue.async { [self] in
            guard isActive else { return }
            isActive = false
            guard let writer, writer.status == .writing, sessionStart != nil else {
                writer?.cancelWriting()
                if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
                resetState()
                onEvent?(.failed(String(localized: "Recording stopped before any video was written.")))
                return
            }
            if let videoInput { drainPendingVideo(into: videoInput) }
            if let audioInput { drainPendingAudio(into: audioInput) }
            let stopStarted = Date.now
            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
            let url = outputURL
            writer.finishWriting { [self] in
                queue.async { [self] in
                    DiagnosticsLog.log("recorder", "finished writing in \(String(format: "%.1f", Date.now.timeIntervalSince(stopStarted))) s, status \(writer.status.rawValue)")
                    if writer.status == .completed, let url {
                        onEvent?(.finished(url))
                    } else {
                        onEvent?(.failed(writer.error?.localizedDescription ?? String(localized: "The recording could not be finalised.")))
                    }
                    resetState()
                }
            }
        }
    }

    // MARK: - Private

    private func drainPendingVideo(into input: AVAssetWriterInput) {
        while let first = pendingVideo.first, input.isReadyForMoreMediaData {
            if !input.append(first) {
                DiagnosticsLog.log("recorder", "video append failed: \(writer?.error?.localizedDescription ?? "unknown")")
            }
            pendingVideo.removeFirst()
        }
    }

    private func drainPendingAudio(into input: AVAssetWriterInput) {
        while let first = pendingAudio.first, input.isReadyForMoreMediaData {
            if !input.append(first) {
                DiagnosticsLog.log("recorder", "audio append failed: \(writer?.error?.localizedDescription ?? "unknown")")
            }
            pendingAudio.removeFirst()
        }
    }

    private func createWriter(for sampleBuffer: CMSampleBuffer) -> Bool {
        guard let settings, let outputURL,
              let formatHint = CMSampleBufferGetFormatDescription(sampleBuffer) else { return false }
        do {
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: settings.format.fileType)
            // No "optimize for network use": that rewrites the whole file when recording stops, which
            // took minutes for long recordings.
            writer.shouldOptimizeForNetworkUse = false

            let video = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formatHint)
            video.expectsMediaDataInRealTime = true
            guard writer.canAdd(video) else { throw CocoaError(.fileWriteUnknown) }
            writer.add(video)

            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: AudioMixer.sampleRate,
                AVNumberOfChannelsKey: Int(AudioMixer.channelCount),
                AVEncoderBitRateKey: settings.audioBitrate.rawValue
            ]
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audio.expectsMediaDataInRealTime = true
            if writer.canAdd(audio) {
                writer.add(audio)
                audioInput = audio
            }

            guard writer.startWriting() else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
            self.writer = writer
            videoInput = video
            return true
        } catch {
            isActive = false
            onEvent?(.failed(error.localizedDescription))
            resetState()
            return false
        }
    }

    private func reportFailureIfNeeded() {
        guard let writer, writer.status == .failed else { return }
        isActive = false
        onEvent?(.failed(writer.error?.localizedDescription ?? String(localized: "The recording failed.")))
        resetState()
    }

    private func resetState() {
        pendingAudio.removeAll()
        pendingVideo.removeAll()
        writer = nil
        videoInput = nil
        audioInput = nil
        sessionStart = nil
        outputURL = nil
    }

    static func fileName(format: RecordingFormat, date: Date = .now) -> String {
        // Fixed, sortable, filesystem-safe pattern (not user-facing date formatting).
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return "Streamio \(formatter.string(from: date)).\(format.rawValue)"
    }
}
