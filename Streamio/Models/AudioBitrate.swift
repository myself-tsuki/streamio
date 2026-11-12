//
//  AudioBitrate.swift
//  Streamio
//

import Foundation

nonisolated public enum AudioBitrate: Int, CaseIterable, Identifiable, Codable, Sendable {
    case kbps96 = 96_000
    case kbps128 = 128_000
    case kbps160 = 160_000
    case kbps192 = 192_000
    case kbps256 = 256_000
    case kbps320 = 320_000

    public var id: Int { rawValue }
    public var title: String { String(localized: "\(rawValue / 1000) kbps") }
}
