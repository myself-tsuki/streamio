//
//  VideoEncoder.swift
//  Streamio
//
//  Hardware H.264 / HEVC encoder on VideoToolbox. One encoder feeds both the stream and
//  the recording (OBS's "same as stream" mode), so the GPU media engine encodes each frame once.
//

import CoreMedia
import Foundation
import VideoToolbox

nonisolated public final class VideoEncoder: @unchecked Sendable {
    public struct Settings: Equatable, Sendable {
        public var width: Int
        public var height: Int
        public var fps: Int
        public var bitrate: Int
        public var codec: VideoCodec
        public var keyFrameIntervalSeconds: Double

        public init(width: Int, height: Int, fps: Int, bitrate: Int, codec: VideoCodec, keyFrameIntervalSeconds: Double) {
            self.width = width
            self.height = height
            self.fps = fps
            self.bitrate = bitrate
            self.codec = codec
            self.keyFrameIntervalSeconds = keyFrameIntervalSeconds
        }
    }

    public enum EncoderError: LocalizedError {
        case sessionCreationFailed(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .sessionCreationFailed(let status):
                String(localized: "The hardware video encoder could not start (error \(status)).")
            }
        }
    }

    /// Decoder configuration record (`avcC`/`hvcC`) whenever it changes.
    public var onFormat: (@Sendable (Data, CMFormatDescription) -> Void)?
    public var onFrame: (@Sendable (EncodedVideoFrame) -> Void)?

    private let lock = NSLock()
    private var session: VTCompressionSession?
    private var settings: Settings?
    private var lastConfigurationRecord: Data?
    private var forceKeyFrame = false
    private var skippedFrames = 0

    public init() {}

    deinit {
        stop()
    }

    public var isRunning: Bool { lock.withLock { session != nil } }

    /// Frames VideoToolbox dropped because it could not keep up (OBS "skipped frames").
    public var skippedFrameCount: Int { lock.withLock { skippedFrames } }

    public func start(_ settings: Settings) throws {
        stop()

        let specification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true
        ]

        var newSession: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(settings.width),
            height: Int32(settings.height),
            codecType: settings.codec.cmCodecType,
            encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &newSession
        )
        guard status == noErr, let newSession else {
            throw EncoderError.sessionCreationFailed(status)
        }

        let profile: CFString = settings.codec == .hevc
            ? kVTProfileLevel_HEVC_Main_AutoLevel
            : kVTProfileLevel_H264_High_AutoLevel

        set(newSession, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(newSession, kVTCompressionPropertyKey_ProfileLevel, profile)
        set(newSession, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(newSession, kVTCompressionPropertyKey_ExpectedFrameRate, settings.fps as CFNumber)
        set(newSession, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, settings.keyFrameIntervalSeconds as CFNumber)
        set(newSession, kVTCompressionPropertyKey_MaxKeyFrameInterval, Int(Double(settings.fps) * settings.keyFrameIntervalSeconds) as CFNumber)
        if settings.codec == .h264 {
            set(newSession, kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CABAC)
        }
        applyBitrate(settings.bitrate, to: newSession)
        _ = VTCompressionSessionPrepareToEncodeFrames(newSession)

        lock.withLock {
            session = newSession
            self.settings = settings
            lastConfigurationRecord = nil
            forceKeyFrame = true
            skippedFrames = 0
        }
    }

    public func stop() {
        let current: VTCompressionSession? = lock.withLock {
            defer { session = nil; settings = nil }
            return session
        }
        guard let current else { return }
        _ = VTCompressionSessionCompleteFrames(current, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(current)
    }

    /// Changes the target bitrate of a running session without restarting it.
    public func updateBitrate(_ bitrate: Int) {
        lock.withLock {
            guard let session else { return }
            settings?.bitrate = bitrate
            applyBitrate(bitrate, to: session)
        }
    }

    public func requestKeyFrame() {
        lock.withLock { forceKeyFrame = true }
    }

    public func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime, duration: CMTime) {
        let (session, wantsKeyFrame): (VTCompressionSession?, Bool) = lock.withLock {
            defer { forceKeyFrame = false }
            return (session, forceKeyFrame)
        }
        guard let session else { return }

        let frameProperties: CFDictionary? = wantsKeyFrame
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
            : nil

        _ = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: frameProperties,
            infoFlagsOut: nil
        ) { [weak self] status, flags, sampleBuffer in
            guard let self else { return }
            guard status == noErr, !flags.contains(.frameDropped), let sampleBuffer else {
                self.lock.withLock { self.skippedFrames += 1 }
                return
            }
            self.handle(sampleBuffer)
        }
    }

    // MARK: - Output

    private func handle(_ sampleBuffer: CMSampleBuffer) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        let isKeyFrame = Self.isKeyFrame(sampleBuffer)
        if isKeyFrame, let record = Self.configurationRecord(from: formatDescription) {
            let changed: Bool = lock.withLock {
                defer { lastConfigurationRecord = record }
                return lastConfigurationRecord != record
            }
            if changed {
                onFormat?(record, formatDescription)
            }
        }

        let length = CMBlockBufferGetDataLength(dataBuffer)
        var accessUnit = Data(count: length)
        let copyStatus = accessUnit.withUnsafeMutableBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: length, destination: base)
        }
        guard copyStatus == kCMBlockBufferNoErr else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let dts = CMSampleBufferGetDecodeTimeStamp(sampleBuffer)
        let frame = EncodedVideoFrame(
            accessUnit: accessUnit,
            pts: CMTimeGetSeconds(pts),
            dts: CMTimeGetSeconds(dts.isValid ? dts : pts),
            isKeyFrame: isKeyFrame,
            sampleBuffer: sampleBuffer
        )
        onFrame?(frame)
    }

    private static func isKeyFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else { return true }
        return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    /// The `avcC` or `hvcC` box VideoToolbox stores in the format description.
    static func configurationRecord(from formatDescription: CMFormatDescription) -> Data? {
        guard let atoms = CMFormatDescriptionGetExtension(
            formatDescription,
            extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
        ) as? [String: Any] else { return nil }
        return (atoms["avcC"] ?? atoms["hvcC"]) as? Data
    }

    // MARK: - Helpers

    private func applyBitrate(_ bitrate: Int, to session: VTCompressionSession) {
        set(session, kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber)
        // Cap bursts at 1.5× the target over one second, which keeps RTMP ingest happy.
        let limits = [Double(bitrate) * 1.5 / 8, 1.0] as CFArray
        set(session, kVTCompressionPropertyKey_DataRateLimits, limits)
    }

    private func set(_ session: VTCompressionSession, _ key: CFString, _ value: CFTypeRef?) {
        _ = VTSessionSetProperty(session, key: key, value: value)
    }
}
