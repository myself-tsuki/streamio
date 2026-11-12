//
//  FLVTag.swift
//  Streamio
//

import Foundation

public struct FLVTag {
    /// Creates an FLV Video Tag for AVC Sequence Header (AVCDecoderConfigurationRecord containing SPS & PPS)
    public static func makeAVCSequenceHeader(sps: Data, pps: Data) -> Data {
        var body = Data()

        // Byte 0: FrameType (1 = keyframe) << 4 | CodecID (7 = AVC) => 0x17
        body.append(0x17)
        // Byte 1: AVCPacketType (0 = AVC sequence header)
        body.append(0x00)
        // Bytes 2..4: CompositionTime (3 bytes, 0)
        body.append(contentsOf: [0x00, 0x00, 0x00])

        // AVCDecoderConfigurationRecord (ISO/IEC 14496-15)
        // configurationVersion
        body.append(0x01)
        // AVCProfileIndication (sps[1])
        body.append(sps.count > 1 ? sps[1] : 0x64)
        // profile_compatibility (sps[2])
        body.append(sps.count > 2 ? sps[2] : 0x00)
        // AVCLevelIndication (sps[3])
        body.append(sps.count > 3 ? sps[3] : 0x1F)
        // lengthSizeMinusOne (0xFC | 3 => 0xFF for 4-byte NALU length prefix)
        body.append(0xFF)

        // numOfSequenceParameterSets (0xE0 | 1 => 0xE1)
        body.append(0xE1)
        // sequenceParameterSetLength (2 bytes, big endian)
        var spsLen = UInt16(sps.count).bigEndian
        body.append(Data(bytes: &spsLen, count: 2))
        body.append(sps)

        // numOfPictureParameterSets (1)
        body.append(0x01)
        // pictureParameterSetLength (2 bytes, big endian)
        var ppsLen = UInt16(pps.count).bigEndian
        body.append(Data(bytes: &ppsLen, count: 2))
        body.append(pps)

        return body
    }

    /// Creates an FLV Video Tag for an AVC NALU
    public static func makeAVCPacket(naluData: Data, isKeyFrame: Bool, compositionTimeMs: Int32 = 0) -> Data {
        var body = Data()

        // Byte 0: FrameType (1 = keyframe, 2 = interframe) << 4 | CodecID (7 = AVC)
        let headerByte: UInt8 = isKeyFrame ? 0x17 : 0x27
        body.append(headerByte)

        // Byte 1: AVCPacketType (1 = AVC NALU)
        body.append(0x01)

        // Bytes 2..4: Composition Time Offset (3 bytes big endian signed 24-bit)
        let comp = UInt32(bitPattern: compositionTimeMs)
        let compB0 = UInt8((comp >> 16) & 0xFF)
        let compB1 = UInt8((comp >> 8) & 0xFF)
        let compB2 = UInt8(comp & 0xFF)
        body.append(contentsOf: [compB0, compB1, compB2])

        // NALU with 4-byte length prefix
        var naluLength = UInt32(naluData.count).bigEndian
        body.append(Data(bytes: &naluLength, count: 4))
        body.append(naluData)

        return body
    }

    /// Creates an FLV Audio Tag for AAC Sequence Header (AudioSpecificConfig)
    public static func makeAACSequenceHeader(config: Data) -> Data {
        var body = Data()
        // Byte 0: SoundFormat (10 = AAC) << 4 | SoundRate (3 = 44kHz) << 2 | SoundSize (1 = 16bit) << 1 | SoundType (1 = Stereo) => 0xAF
        body.append(0xAF)
        // Byte 1: AACPacketType (0 = AAC sequence header)
        body.append(0x00)
        // Payload: AudioSpecificConfig
        body.append(config)
        return body
    }

    /// Creates an FLV Audio Tag for raw AAC frame
    public static func makeAACPacket(aacData: Data) -> Data {
        var body = Data()
        // Byte 0: 0xAF (AAC, 44kHz, 16bit, Stereo)
        body.append(0xAF)
        // Byte 1: AACPacketType (1 = AAC raw)
        body.append(0x01)
        // Payload: raw AAC frame
        body.append(aacData)
        return body
    }
}

