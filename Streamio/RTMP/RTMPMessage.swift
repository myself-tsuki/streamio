//
//  RTMPMessage.swift
//  Streamio
//

import Foundation

/// A fully reassembled RTMP message received from the server.
nonisolated public struct RTMPMessage: Equatable, Sendable {
    public var typeId: UInt8
    public var streamId: UInt32
    public var timestamp: UInt32
    public var payload: Data

    public init(typeId: UInt8, streamId: UInt32, timestamp: UInt32, payload: Data) {
        self.typeId = typeId
        self.streamId = streamId
        self.timestamp = timestamp
        self.payload = payload
    }

    public var type: RTMPMessageType? { RTMPMessageType(rawValue: typeId) }

    /// Reads a big-endian UInt32 at the start of the payload (control messages).
    public var leadingUInt32: UInt32? {
        guard payload.count >= 4 else { return nil }
        return payload.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
