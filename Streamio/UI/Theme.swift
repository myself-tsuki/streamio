//
//  Theme.swift
//  Streamio
//
//  "Control room glass": OBS's dock layout as Liquid Glass panels over a
//  behind-window blur. System colours and SF Pro text styles throughout; the accent
//  marks selection, red is reserved for LIVE / REC and always paired with a word.
//

import SwiftUI

enum Theme {
    static let spacingXS: CGFloat = 4
    static let spacingS: CGFloat = 8
    static let spacingM: CGFloat = 12
    static let spacingL: CGFloat = 16
    static let dockRadius: CGFloat = 18
    static let previewRadius: CGFloat = 14
    static let dockHeight: CGFloat = 248
    static let controlsWidth: CGFloat = 220
    static let live = Color.red
    static let meterGreen = Color.green
    static let meterYellow = Color.yellow
    static let meterRed = Color.red
}

extension Duration {
    /// "1:02:03" / "02:03" for on-air timers.
    nonisolated static func clock(since start: Date?, now: Date) -> String {
        guard let start else { return "00:00:00" }
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return Duration.seconds(seconds).formatted(.time(pattern: .hourMinuteSecond(padHourToLength: 2)))
    }
}
