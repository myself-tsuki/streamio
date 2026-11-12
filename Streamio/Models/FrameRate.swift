//
//  FrameRate.swift
//  Streamio
//

import Foundation

nonisolated public enum FrameRate: Int, CaseIterable, Identifiable, Codable, Sendable {
    case fps24 = 24
    case fps25 = 25
    case fps30 = 30
    case fps50 = 50
    case fps60 = 60

    public var id: Int { rawValue }
    public var title: String { String(localized: "\(rawValue) fps") }
}
