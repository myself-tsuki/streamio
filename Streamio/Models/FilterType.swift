//
//  FilterType.swift
//  Streamio
//

import Foundation

/// Metal colour filters applied to the canvas. Raw values are persisted; titles are display-only.
nonisolated public enum FilterType: String, CaseIterable, Identifiable, Codable, Sendable {
    case passthrough
    case mono
    case sepia
    case neon
    case vignette
    case posterize
    case invert
    case chromaKey

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .passthrough: String(localized: "None")
        case .mono: String(localized: "Monochrome")
        case .sepia: String(localized: "Warm Sepia")
        case .neon: String(localized: "Neon Split")
        case .vignette: String(localized: "Vignette")
        case .posterize: String(localized: "Posterize")
        case .invert: String(localized: "Invert")
        case .chromaKey: String(localized: "Chroma Key (Green)")
        }
    }

    public var systemImage: String {
        switch self {
        case .passthrough: "circle.slash"
        case .mono: "circle.lefthalf.filled"
        case .sepia: "sun.haze"
        case .neon: "light.beacon.max"
        case .vignette: "circle.dashed.inset.filled"
        case .posterize: "square.stack.3d.down.forward"
        case .invert: "circle.righthalf.filled"
        case .chromaKey: "person.crop.rectangle"
        }
    }

    /// Index understood by the fragment shader.
    public var shaderCode: UInt32 {
        switch self {
        case .passthrough: 0
        case .mono: 1
        case .sepia: 2
        case .neon: 3
        case .vignette: 4
        case .posterize: 5
        case .invert: 6
        case .chromaKey: 7
        }
    }
}
