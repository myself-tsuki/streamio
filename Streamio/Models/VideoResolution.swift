//
//  VideoResolution.swift
//  Streamio
//

import Foundation

/// Output canvas size. Every source is scaled (aspect-fit) onto this canvas.
nonisolated public enum VideoResolution: String, CaseIterable, Identifiable, Codable, Sendable {
    case uhd2160 = "2160p"
    case qhd1440 = "1440p"
    case fhd1080 = "1080p"
    case hd720 = "720p"

    public var id: String { rawValue }

    public var width: Int {
        switch self {
        case .uhd2160: 3840
        case .qhd1440: 2560
        case .fhd1080: 1920
        case .hd720: 1280
        }
    }

    public var height: Int {
        switch self {
        case .uhd2160: 2160
        case .qhd1440: 1440
        case .fhd1080: 1080
        case .hd720: 720
        }
    }

    public var title: String { "\(width)×\(height)" }

    /// Bitrate suggested for a 30 fps H.264 stream at this size, in bits per second.
    public var recommendedBitrate: Int {
        switch self {
        case .uhd2160: 20_000_000
        case .qhd1440: 9_000_000
        case .fhd1080: 6_000_000
        case .hd720: 3_500_000
        }
    }
}
