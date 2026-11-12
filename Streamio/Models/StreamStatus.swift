//
//  StreamStatus.swift
//  Streamio
//

import Foundation

nonisolated public enum StreamStatus: Equatable, Sendable {
    case idle
    case connecting
    case streaming
    case reconnecting
    case error(String)

    public var label: String {
        switch self {
        case .idle: String(localized: "Offline")
        case .connecting: String(localized: "Connecting…")
        case .streaming: String(localized: "Live")
        case .reconnecting: String(localized: "Reconnecting…")
        case .error: String(localized: "Stream Error")
        }
    }

    public var isLive: Bool { self == .streaming }

    /// True while a stream session exists (including connection attempts).
    public var isActive: Bool {
        switch self {
        case .connecting, .streaming, .reconnecting: true
        case .idle, .error: false
        }
    }

    public var errorMessage: String? {
        if case .error(let message) = self { message } else { nil }
    }
}
