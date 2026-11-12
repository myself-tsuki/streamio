//
//  RTMPChunkReader.swift
//  Streamio
//
//  Incremental de-chunker for server → client traffic (RTMP spec §5.3).
//  Feed it whatever bytes arrive from the socket; it returns complete messages.
//

import Foundation

nonisolated public struct RTMPChunkReader: Sendable {
    private struct ChunkStreamState: Sendable {
        var timestamp: UInt32 = 0
        var timestampDelta: UInt32 = 0
        var messageLength: Int = 0
        var typeId: UInt8 = 0
        var streamId: UInt32 = 0
        var hasExtendedTimestamp = false
        var partial = Data()
    }

    public private(set) var chunkSize = 128
    private var buffer: [UInt8] = []
    private var streams: [UInt32: ChunkStreamState] = [:]

    public init() {}

    /// Applies a Set Chunk Size received from the peer.
    public mutating func setChunkSize(_ size: Int) {
        chunkSize = max(1, min(size, 0x7FFF_FFFF))
    }

    public mutating func append(_ data: Data) -> [RTMPMessage] {
        buffer.append(contentsOf: data)
        var messages: [RTMPMessage] = []
        var offset = 0

        while let (consumed, message) = parseChunk(at: offset) {
            offset += consumed
            if let message {
                if message.type == .setChunkSize, let size = message.leadingUInt32 {
                    // Takes effect for the very next chunk.
                    setChunkSize(Int(size & 0x7FFF_FFFF))
                }
                messages.append(message)
            }
        }

        if offset > 0 {
            buffer.removeFirst(offset)
        }
        return messages
    }

    /// Parses one chunk at `start`. Returns nil when more bytes are needed.
    private mutating func parseChunk(at start: Int) -> (Int, RTMPMessage?)? {
        var cursor = start
        guard cursor < buffer.count else { return nil }

        let first = buffer[cursor]
        cursor += 1
        let fmt = first >> 6
        var csid = UInt32(first & 0x3F)
        if csid == 0 {
            guard cursor < buffer.count else { return nil }
            csid = UInt32(buffer[cursor]) + 64
            cursor += 1
        } else if csid == 1 {
            guard cursor + 1 < buffer.count else { return nil }
            csid = UInt32(buffer[cursor]) + UInt32(buffer[cursor + 1]) * 256 + 64
            cursor += 2
        }

        var state = streams[csid] ?? ChunkStreamState()
        let headerSize = [11, 7, 3, 0][Int(fmt)]
        guard cursor + headerSize <= buffer.count else { return nil }

        var timestampField: UInt32 = 0
        if fmt <= 2 {
            timestampField = readUInt24(cursor)
        }
        if fmt <= 1 {
            state.messageLength = Int(readUInt24(cursor + 3))
            state.typeId = buffer[cursor + 6]
        }
        if fmt == 0 {
            state.streamId = UInt32(buffer[cursor + 7])
                | UInt32(buffer[cursor + 8]) << 8
                | UInt32(buffer[cursor + 9]) << 16
                | UInt32(buffer[cursor + 10]) << 24
        }
        cursor += headerSize

        if fmt <= 2 {
            state.hasExtendedTimestamp = timestampField == 0x00FF_FFFF
        }
        if state.hasExtendedTimestamp {
            guard cursor + 4 <= buffer.count else { return nil }
            timestampField = readUInt32(cursor)
            cursor += 4
        }

        let startsMessage = state.partial.isEmpty
        if startsMessage {
            switch fmt {
            case 0:
                state.timestamp = timestampField
                state.timestampDelta = 0
            case 1, 2:
                state.timestampDelta = timestampField
                state.timestamp &+= timestampField
            default:
                state.timestamp &+= state.timestampDelta
            }
        }

        let remaining = state.messageLength - state.partial.count
        let payloadSize = min(chunkSize, max(remaining, 0))
        guard cursor + payloadSize <= buffer.count else { return nil }

        state.partial.append(contentsOf: buffer[cursor..<cursor + payloadSize])
        cursor += payloadSize

        var completed: RTMPMessage?
        if state.partial.count >= state.messageLength {
            completed = RTMPMessage(
                typeId: state.typeId,
                streamId: state.streamId,
                timestamp: state.timestamp,
                payload: state.partial
            )
            state.partial = Data()
        }

        streams[csid] = state
        return (cursor - start, completed)
    }

    private func readUInt24(_ index: Int) -> UInt32 {
        UInt32(buffer[index]) << 16 | UInt32(buffer[index + 1]) << 8 | UInt32(buffer[index + 2])
    }

    private func readUInt32(_ index: Int) -> UInt32 {
        UInt32(buffer[index]) << 24 | UInt32(buffer[index + 1]) << 16 | UInt32(buffer[index + 2]) << 8 | UInt32(buffer[index + 3])
    }
}
