//
//  AudioChannelID.swift
//  Streamio
//

import Foundation

/// Mixer channels, matching OBS's default "Desktop Audio" and "Mic/Aux" strips.
nonisolated public enum AudioChannelID: String, CaseIterable, Identifiable, Codable, Sendable {
    case desktop
    case microphone

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .desktop: String(localized: "Desktop Audio")
        case .microphone: String(localized: "Mic/Aux")
        }
    }

    public var systemImage: String {
        switch self {
        case .desktop: "speaker.wave.2"
        case .microphone: "mic"
        }
    }
}
