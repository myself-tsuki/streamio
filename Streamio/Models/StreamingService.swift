//
//  StreamingService.swift
//  Streamio
//

import Foundation

/// Preset destinations, mirroring OBS's Settings ▸ Stream ▸ Service list.
nonisolated public enum StreamingService: String, CaseIterable, Identifiable, Codable, Sendable {
    case youtube
    case twitch
    case facebook
    case custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .youtube: "YouTube"
        case .twitch: "Twitch"
        case .facebook: "Facebook Live"
        case .custom: String(localized: "Custom RTMP")
        }
    }

    public var servers: [IngestServer] {
        switch self {
        case .youtube:
            [
                IngestServer(name: String(localized: "Primary (RTMPS)"), url: "rtmps://a.rtmps.youtube.com:443/live2"),
                IngestServer(name: String(localized: "Primary (RTMP)"), url: "rtmp://a.rtmp.youtube.com/live2"),
                IngestServer(name: String(localized: "Backup (RTMP)"), url: "rtmp://b.rtmp.youtube.com/live2?backup=1")
            ]
        case .twitch:
            [IngestServer(name: String(localized: "Auto (closest)"), url: "rtmp://live.twitch.tv/app")]
        case .facebook:
            [IngestServer(name: String(localized: "Default (RTMPS)"), url: "rtmps://live-api-s.facebook.com:443/rtmp")]
        case .custom:
            []
        }
    }

    /// Where the user copies their stream key from.
    public var streamKeyHelpURL: URL? {
        switch self {
        case .youtube: URL(string: "https://studio.youtube.com")
        case .twitch: URL(string: "https://dashboard.twitch.tv/settings/stream")
        case .facebook: URL(string: "https://www.facebook.com/live/producer")
        case .custom: nil
        }
    }
}
