//
//  RTMPChunker.swift
//  Streamio
//
//  Splits outgoing RTMP messages into chunks (RTMP spec §5.3).
//

import Foundation

nonisolated public enum RTMPMessageType: UInt8, Sendable {
    case setChunkSize = 1
    case abort = 2
    case acknowledgement = 3
    case userControl = 4
    case windowAckSize = 5
    case setPeerBandwidth = 6
    case audio = 8
    case video = 9
    case dataAMF3 = 15
    case commandAMF3 = 17
    case dataAMF0 = 18
    case commandAMF0 = 20
}

/// Chunk stream IDs used for outgoing traffic.
nonisolated public enum RTMPChunkStream {
    public static let control: UInt32 = 2
    public static let command: UInt32 = 3
    public static let audio: UInt32 = 4
    public static let data: UInt32 = 5
    public static let video: UInt32 = 6
}

nonisolated public enum RTMPChunker {
    /// Formats an RTMP message into chunk packets according to `chunkSize`.
    /// The first chunk carries a type-0 header; continuation chunks use type 3.
    public static func chunkMessage(
        csid: UInt32,
        typeId: UInt8,
        streamId: UInt32,
        timestamp: UInt32,
        payload: Data,
        chunkSize: Int
    ) -> Data {
        let totalLength = payload.count
        let hasExtendedTimestamp = timestamp >= 0x00FF_FFFF
        let timestampField: UInt32 = hasExtendedTimestamp ? 0x00FF_FFFF : timestamp
        let continuationCount = max(0, (totalLength - 1) / max(chunkSize, 1))

        var result = Data()
        result.reserveCapacity(totalLength + 18 + continuationCount * (hasExtendedTimestamp ? 7 : 3))

        result.append(basicHeader(fmt: 0, csid: csid))
        appendUInt24(timestampField, to: &result)
        appendUInt24(UInt32(totalLength), to: &result)
        result.append(typeId)
        // Message stream ID is the only little-endian field in the protocol.
        withUnsafeBytes(of: streamId.littleEndian) { result.append(contentsOf: $0) }
        if hasExtendedTimestamp {
            withUnsafeBytes(of: timestamp.bigEndian) { result.append(contentsOf: $0) }
        }

        var offset = payload.startIndex
        let end = payload.endIndex
        let firstEnd = min(end, offset + chunkSize)
        result.append(payload[offset..<firstEnd])
        offset = firstEnd

        let continuationHeader = basicHeader(fmt: 3, csid: csid)
        while offset < end {
            result.append(continuationHeader)
            if hasExtendedTimestamp {
                withUnsafeBytes(of: timestamp.bigEndian) { result.append(contentsOf: $0) }
            }
            let nextEnd = min(end, offset + chunkSize)
            result.append(payload[offset..<nextEnd])
            offset = nextEnd
        }

        return result
    }

    static func basicHeader(fmt: UInt8, csid: UInt32) -> Data {
        if csid >= 2 && csid < 64 {
            return Data([(fmt << 6) | UInt8(csid)])
        } else if csid < 320 {
            return Data([fmt << 6, UInt8(csid - 64)])
        } else {
            let value = csid - 64
            return Data([(fmt << 6) | 1, UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
        }
    }

    private static func appendUInt24(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
}
