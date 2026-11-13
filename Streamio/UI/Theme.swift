//
//  Theme.swift
//  Streamio
//
//  "Control room glass": OBS's dock layout (scenes and sources on the left, program on top,
//  mixer below, controls on the right) as Liquid Glass panels over a behind-window blur.
//  System colours and SF Pro text styles throughout; the accent marks selection and active
//  monitoring, red is reserved for LIVE / REC / mute and always paired with a word or symbol.
//

import SwiftUI

enum Theme {
    static let spacingXS: CGFloat = 4
    static let spacingS: CGFloat = 8
    static let spacingM: CGFloat = 12
    static let spacingL: CGFloat = 16
    static let spacingXL: CGFloat = 24
    static let dockRadius: CGFloat = 18
    static let previewRadius: CGFloat = 14
    static let rowRadius: CGFloat = 8
    static let sidebarWidth: CGFloat = 260
    static let controlsWidth: CGFloat = 280
    static let mixerHeight: CGFloat = 214
    static let live = Color.red
    static let warning = Color.orange
    static let good = Color.green
    static let meterGreen = Color.green
    static let meterYellow = Color.yellow
    static let meterRed = Color.red
}

extension Duration {
    /// "01:02:03" for on-air timers.
    nonisolated static func clock(since start: Date?, now: Date) -> String {
        guard let start else { return "00:00:00" }
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return Duration.seconds(seconds).formatted(.time(pattern: .hourMinuteSecond(padHourToLength: 2)))
    }
}

extension StreamStatus {
    var tint: Color {
        switch self {
        case .streaming: Theme.live
        case .connecting, .reconnecting: Theme.warning
        case .error: Theme.live
        case .idle: .secondary
        }
    }

    var systemImage: String {
        switch self {
        case .streaming: "dot.radiowaves.left.and.right"
        case .connecting, .reconnecting: "arrow.triangle.2.circlepath"
        case .error: "exclamationmark.triangle.fill"
        case .idle: "antenna.radiowaves.left.and.right.slash"
        }
    }
}

extension StreamingService {
    /// Glyph for destination pills.
    var systemImage: String {
        switch self {
        case .youtube: "play.rectangle.fill"
        case .twitch: "gamecontroller.fill"
        case .facebook: "person.2.fill"
        case .custom: "server.rack"
        }
    }
}
