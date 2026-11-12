//
//  StreamDestination.swift
//  Streamio
//

import Foundation

/// One RTMP output. Every enabled destination receives the same encoded packets,
/// so going live on YouTube and Facebook at once costs a single encode.
nonisolated public struct StreamDestination: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var service: StreamingService
    public var serverURL: String
    public var isEnabled: Bool

    public init(id: UUID = UUID(), name: String, service: StreamingService, serverURL: String? = nil, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.service = service
        self.serverURL = serverURL ?? service.servers.first?.url ?? ""
        self.isEnabled = isEnabled
    }

    /// Keychain account holding this destination's stream key.
    public var keychainAccount: String { "destination.\(id.uuidString)" }
}
