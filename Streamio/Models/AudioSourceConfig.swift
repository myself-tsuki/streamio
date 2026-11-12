//
//  AudioSourceConfig.swift
//  Streamio
//

import Foundation

/// OBS "Audio Monitoring": hear a source through headphones or speakers.
nonisolated public enum MonitoringMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case off
    /// Heard locally, left out of the stream and recording.
    case monitorOnly
    /// Heard locally and sent to the stream and recording.
    case monitorAndOutput

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: String(localized: "Monitor Off")
        case .monitorOnly: String(localized: "Monitor Only (mute output)")
        case .monitorAndOutput: String(localized: "Monitor and Output")
        }
    }

    public var isMonitoring: Bool { self != .off }
    public var feedsOutput: Bool { self != .monitorOnly }
}

/// A mixer channel the user added. Nothing is captured until a source is added.
nonisolated public struct AudioSourceConfig: Identifiable, Equatable, Codable, Sendable {
    public var channel: AudioChannelID
    /// Exact `AVCaptureDevice.uniqueID` for the microphone channel. Never replaced by the system default.
    public var deviceID: String
    /// Fader gain in dB; -60 and below is silence (-inf), up to +20 dB of boost.
    public var gainDecibels: Float
    public var isMuted: Bool
    /// -1 (left) … 0 (centre) … 1 (right)
    public var balance: Float
    public var isMono: Bool
    public var monitoring: MonitoringMode

    public var id: AudioChannelID { channel }

    public static let minimumGain: Float = -60
    public static let maximumGain: Float = 20

    public init(channel: AudioChannelID, deviceID: String = "", gainDecibels: Float = 0, isMuted: Bool = false,
                balance: Float = 0, isMono: Bool = false, monitoring: MonitoringMode = .off) {
        self.channel = channel
        self.deviceID = deviceID
        self.gainDecibels = gainDecibels
        self.isMuted = isMuted
        self.balance = balance
        self.isMono = isMono
        self.monitoring = monitoring
    }
}
