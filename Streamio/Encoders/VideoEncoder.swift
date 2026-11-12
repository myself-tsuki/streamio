//
//  VideoEncoder.swift
//  Streamio
//

import Foundation
import VideoToolbox
import CoreMedia

public protocol VideoEncoderDelegate: AnyObject {
    func videoEncoder(_ encoder: VideoEncoder, didOutputSPS sps: Data, pps: Data)
    func videoEncoder(_ encoder: VideoEncoder, didOutputNALU nalu: Data, pts: CMTime, dts: CMTime, isKeyFrame: Bool)
}

public final class VideoEncoder: @unchecked Sendable {
    public weak var delegate: VideoEncoderDelegate?

    private var compressionSession: VTCompressionSession?
    private var width: Int32 = 1920
    private var height: Int32 = 1080
    private var bitrate: Int = 4_500_000
    private var fps: Int = 30
    private var codec: VideoCodec = .h264

    private var hasSentSPSAndPPS = false
    private let encoderQueue = DispatchQueue(label: "com.streamio.videoencoder", qos: .userInitiated)

    public init() {}

    deinit {
        stop()
    }

    public func configure(width: Int32, height: Int32, bitrate: Int, fps: Int, codec: VideoCodec = .h264) {
        encoderQueue.async { [weak self] in
            guard let self = self else { return }
            self.stopInternal()

            self.width = width
            self.height = height
            self.bitrate = bitrate
            self.fps = fps
            self.codec = codec
            self.hasSentSPSAndPPS = false

            self.createSession()
        }
    }

    private func createSession() {
        let callback: VTCompressionOutputCallback = { outputCallbackRefCon, _, status, flags, sampleBuffer in
            guard status == noErr, let sampleBuffer = sampleBuffer, let refCon = outputCallbackRefCon else {
                return
            }
            let encoder = Unmanaged<VideoEncoder>.fromOpaque(refCon).takeUnretainedValue()
            encoder.handleEncodedSampleBuffer(sampleBuffer, flags: flags)
        }

        let refCon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: codec.cmCodecType,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: callback,
            refcon: refCon,
            compressionSessionOut: &session
        )

        guard status == noErr, let compSession = session else {
            print("Failed to create VTCompressionSession: \(status)")
            return
        }

        self.compressionSession = compSession

        // Real-time properties
        VTSessionSetProperty(compSession, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(compSession, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(compSession, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        
        // Data rate limit (bytes per second with 1-second window)
        let limits: [CFNumber] = [(bitrate * 3 / 2 / 8) as CFNumber, 1 as CFNumber]
        VTSessionSetProperty(compSession, key: kVTCompressionPropertyKey_DataRateLimits, value: limits as CFArray)

        // 2-second Keyframe (GOP) interval recommended for YouTube RTMP
        let keyFrameInterval = fps * 2
        VTSessionSetProperty(compSession, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: keyFrameInterval as CFNumber)
        VTSessionSetProperty(compSession, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 2.0 as CFNumber)

        // Low latency: disable frame reordering (no B-frames) for real-time RTMP streaming
        VTSessionSetProperty(compSession, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(compSession, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)

        VTCompressionSessionPrepareToEncodeFrames(compSession)
    }

    public func encode(pixelBuffer: CVPixelBuffer, presentationTimeStamp: CMTime, duration: CMTime) {
        encoderQueue.async { [weak self] in
            guard let self = self, let session = self.compressionSession else { return }

            var flags: VTEncodeInfoFlags = []
            let status = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: pixelBuffer,
                presentationTimeStamp: presentationTimeStamp,
                duration: duration,
                frameProperties: nil,
                sourceFrameRefcon: nil,
                infoFlagsOut: &flags
            )

            if status != noErr {
                print("VTCompressionSessionEncodeFrame error: \(status)")
            }
        }
    }

    private func handleEncodedSampleBuffer(_ sampleBuffer: CMSampleBuffer, flags: VTEncodeInfoFlags) {
        guard flags.contains(.frameDropped) == false else {
            return
        }

        let isKeyFrame: Bool
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first,
           let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKeyFrame = !notSync
        } else {
            isKeyFrame = true
        }

        // On keyframe or first frame, extract and send SPS & PPS
        if isKeyFrame {
            if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
                var parameterSetCount = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    formatDescription,
                    parameterSetIndex: 0,
                    parameterSetPointerOut: nil,
                    parameterSetSizeOut: nil,
                    parameterSetCountOut: &parameterSetCount,
                    nalUnitHeaderLengthOut: nil
                )

                var spsData: Data?
                var ppsData: Data?

                for index in 0..<parameterSetCount {
                    var paramPtr: UnsafePointer<UInt8>?
                    var paramSize: Int = 0
                    let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        formatDescription,
                        parameterSetIndex: index,
                        parameterSetPointerOut: &paramPtr,
                        parameterSetSizeOut: &paramSize,
                        parameterSetCountOut: nil,
                        nalUnitHeaderLengthOut: nil
                    )

                    if status == noErr, let ptr = paramPtr, paramSize > 0 {
                        let data = Data(bytes: ptr, count: paramSize)
                        if index == 0 {
                            spsData = data
                        } else if index == 1 {
                            ppsData = data
                        }
                    }
                }

                if let sps = spsData, let pps = ppsData {
                    delegate?.videoEncoder(self, didOutputSPS: sps, pps: pps)
                    hasSentSPSAndPPS = true
                }
            }
        }

        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var lengthAtOffset: Int = 0
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?

        let status = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )

        guard status == noErr, let pointer = dataPointer else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let dts = CMSampleBufferGetDecodeTimeStamp(sampleBuffer)

        // Read NALUs (AVCC format: 4-byte length prefix + NALU payload)
        var bufferOffset = 0
        let avcHeaderLength = 4

        while bufferOffset < totalLength - avcHeaderLength {
            var naluLength: UInt32 = 0
            memcpy(&naluLength, pointer + bufferOffset, avcHeaderLength)
            naluLength = CFSwapInt32BigToHost(naluLength)

            bufferOffset += avcHeaderLength

            if bufferOffset + Int(naluLength) <= totalLength {
                let naluData = Data(bytes: pointer + bufferOffset, count: Int(naluLength))
                delegate?.videoEncoder(self, didOutputNALU: naluData, pts: pts, dts: dts.isValid ? dts : pts, isKeyFrame: isKeyFrame)
                bufferOffset += Int(naluLength)
            } else {
                break
            }
        }
    }

    public func stop() {
        encoderQueue.sync { [weak self] in
            self?.stopInternal()
        }
    }

    private func stopInternal() {
        if let session = compressionSession {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
        }
    }
}

