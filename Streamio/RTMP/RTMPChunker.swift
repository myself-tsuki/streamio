//
//  RTMPChunker.swift
//  Streamio
//

import Foundation

public struct RTMPChunker {
    /// Formats an RTMP message into chunk packets according to chunk size
    public static func chunkMessage(
        csid: UInt32,
        typeId: UInt8,
        streamId: UInt32,
        timestamp: UInt32,
        payload: Data,
        chunkSize: Int
    ) -> Data {
        var result = Data()
        let totalLength = payload.count

        // 1. Basic header for first chunk (Type 0: fmt = 0)
        let basicHeader = makeBasicHeader(fmt: 0, csid: csid)
        result.append(basicHeader)

        // 2. Message header Type 0 (11 bytes)
        let hasExtendedTimestamp = timestamp >= 0x00FFFFFF
        let tsField: UInt32 = hasExtendedTimestamp ? 0x00FFFFFF : timestamp

        // Timestamp (3 bytes, big endian)
        result.append(UInt8((tsField >> 16) & 0xFF))
        result.append(UInt8((tsField >> 8) & 0xFF))
        result.append(UInt8(tsField & 0xFF))

        // Message length (3 bytes, big endian)
        result.append(UInt8((totalLength >> 16) & 0xFF))
        result.append(UInt8((totalLength >> 8) & 0xFF))
        result.append(UInt8(totalLength & 0xFF))

        // Message type ID (1 byte)
        result.append(typeId)

        // Message Stream ID (4 bytes, little endian!)
        var streamIdLE = streamId.littleEndian
        result.append(Data(bytes: &streamIdLE, count: 4))

        // Extended timestamp if needed
        if hasExtendedTimestamp {
            var extTs = timestamp.bigEndian
            result.append(Data(bytes: &extTs, count: 4))
        }

        // First chunk data
        let firstChunkSize = min(totalLength, chunkSize)
        result.append(payload.subdata(in: 0..<firstChunkSize))

        // Subsequent chunks (Type 3: fmt = 3)
        var offset = firstChunkSize
        let type3Header = makeBasicHeader(fmt: 3, csid: csid)

        while offset < totalLength {
            result.append(type3Header)
            if hasExtendedTimestamp {
                var extTs = timestamp.bigEndian
                result.append(Data(bytes: &extTs, count: 4))
            }
            let nextSize = min(totalLength - offset, chunkSize)
            result.append(payload.subdata(in: offset..<(offset + nextSize)))
            offset += nextSize
        }

        return result
    }

    private static func makeBasicHeader(fmt: UInt8, csid: UInt32) -> Data {
        var header = Data()
        if csid < 64 {
            let b0 = (fmt << 6) | UInt8(csid)
            header.append(b0)
        } else if csid < 320 {
            let b0 = (fmt << 6)
            let b1 = UInt8(csid - 64)
            header.append(contentsOf: [b0, b1])
        } else {
            let b0 = (fmt << 6) | 1
            let csidVal = csid - 64
            let b1 = UInt8(csidVal & 0xFF)
            let b2 = UInt8((csidVal >> 8) & 0xFF)
            header.append(contentsOf: [b0, b1, b2])
        }
        return header
    }
}

