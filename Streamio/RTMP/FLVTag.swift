//
//  FLVTag.swift
//  Streamio
//
//  Builds FLV audio/video tag bodies carried in RTMP audio (8) and video (9) messages.
//  H.264 uses the legacy FLV header; HEVC uses Enhanced RTMP (veovera E-RTMP v1),
//  which YouTube, Twitch and OBS 29+ understand.
//

import Foundation

nonisolated public enum FLVVideoFormat: Sendable {
    case avc
    case hevc

    /// Value advertised in onMetaData `videocodecid`.
    public var metadataCodecID: Double {
        switch self {
        case .avc: 7
        case .hevc: Double(FLVTag.hevcFourCC)
        }
    }
}

nonisolated public enum FLVTag {
    /// 'hvc1' as a big-endian FourCC.
    public static let hevcFourCC: UInt32 = 0x6876_6331

    // MARK: Video

    /// Sequence header carrying the decoder configuration record
    /// (`avcC` for H.264, `hvcC` for HEVC) exactly as VideoToolbox produced it.
    public static func videoSequenceHeader(format: FLVVideoFormat, configurationRecord: Data) -> Data {
        var body = Data()
        switch format {
        case .avc:
            body.append(0x17)                         // keyframe | AVC
            body.append(0x00)                         // AVC sequence header
            body.append(contentsOf: [0x00, 0x00, 0x00])
        case .hevc:
            body.append(0x80 | (1 << 4) | 0x00)       // ExHeader | keyframe | SequenceStart
            appendFourCC(to: &body)
        }
        body.append(configurationRecord)
        return body
    }

    /// One complete access unit in AVCC/HVCC form (4-byte length-prefixed NAL units).
    public static func videoFrame(format: FLVVideoFormat, accessUnit: Data, isKeyFrame: Bool, compositionTimeMs: Int32) -> Data {
        var body = Data()
        body.reserveCapacity(accessUnit.count + 8)
        let frameType: UInt8 = isKeyFrame ? 1 : 2

        switch format {
        case .avc:
            body.append((frameType << 4) | 0x07)
            body.append(0x01)                         // AVC NALU
            appendInt24(compositionTimeMs, to: &body)
        case .hevc:
            if compositionTimeMs == 0 {
                body.append(0x80 | (frameType << 4) | 0x03) // CodedFramesX (no composition time)
                appendFourCC(to: &body)
            } else {
                body.append(0x80 | (frameType << 4) | 0x01) // CodedFrames
                appendFourCC(to: &body)
                appendInt24(compositionTimeMs, to: &body)
            }
        }
        body.append(accessUnit)
        return body
    }

    /// Video tag that signals end of sequence (sent before unpublishing).
    public static func videoEndOfSequence(format: FLVVideoFormat) -> Data {
        guard format == .hevc else {
            return Data([0x17, 0x02, 0x00, 0x00, 0x00])
        }
        var body = Data([0x80 | (1 << 4) | 0x02])         // ExHeader | keyframe | SequenceEnd
        appendFourCC(to: &body)
        return body
    }

    // MARK: Audio

    /// 0xAF: AAC, "44 kHz" (always used for AAC), 16-bit, stereo.
    private static let aacHeaderByte: UInt8 = 0xAF

    public static func makeAACSequenceHeader(config: Data) -> Data {
        var body = Data([aacHeaderByte, 0x00])
        body.append(config)
        return body
    }

    public static func makeAACPacket(aacData: Data) -> Data {
        var body = Data([aacHeaderByte, 0x01])
        body.append(aacData)
        return body
    }

    /// Two-byte AudioSpecificConfig for AAC-LC (ISO/IEC 14496-3 §1.6.2.1).
    public static func audioSpecificConfig(sampleRate: Double, channels: Int) -> Data {
        let rates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        let frequencyIndex = UInt8(rates.firstIndex { abs($0 - sampleRate) < 1 } ?? 4)
        let objectType: UInt8 = 2 // AAC-LC
        let channelConfig = UInt8(max(1, min(channels, 7)))
        let byte1 = (objectType << 3) | (frequencyIndex >> 1)
        let byte2 = ((frequencyIndex & 0x01) << 7) | (channelConfig << 3)
        return Data([byte1, byte2])
    }

    // MARK: Helpers

    private static func appendFourCC(to data: inout Data) {
        withUnsafeBytes(of: hevcFourCC.bigEndian) { data.append(contentsOf: $0) }
    }

    private static func appendInt24(_ value: Int32, to data: inout Data) {
        let bits = UInt32(bitPattern: value)
        data.append(UInt8((bits >> 16) & 0xFF))
        data.append(UInt8((bits >> 8) & 0xFF))
        data.append(UInt8(bits & 0xFF))
    }
}
