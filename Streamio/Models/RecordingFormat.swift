//
//  RecordingFormat.swift
//  Streamio
//

import AVFoundation

nonisolated public enum RecordingFormat: String, CaseIterable, Identifiable, Codable, Sendable {
    case mp4
    case mov

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .mp4: String(localized: "MPEG-4 (.mp4)")
        case .mov: String(localized: "QuickTime (.mov)")
        }
    }

    public var fileType: AVFileType {
        switch self {
        case .mp4: .mp4
        case .mov: .mov
        }
    }
}
