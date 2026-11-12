//
//  SceneSource.swift
//  Streamio
//

import Foundation

/// Where a source sits on the canvas.
nonisolated public enum SourceLayout: String, CaseIterable, Identifiable, Codable, Sendable {
    case fit
    case fill
    case stretch
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fit: String(localized: "Fit to Canvas")
        case .fill: String(localized: "Fill Canvas (Crop)")
        case .stretch: String(localized: "Stretch to Canvas")
        case .topLeft: String(localized: "Picture in Picture · Top Left")
        case .topRight: String(localized: "Picture in Picture · Top Right")
        case .bottomLeft: String(localized: "Picture in Picture · Bottom Left")
        case .bottomRight: String(localized: "Picture in Picture · Bottom Right")
        }
    }

    public var isPictureInPicture: Bool {
        switch self {
        case .topLeft, .topRight, .bottomLeft, .bottomRight: true
        case .fit, .fill, .stretch: false
        }
    }
}

/// One layer of a scene, like an OBS source: input + transform + filters.
nonisolated public struct SceneSource: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var input: VideoSource
    public var isVisible: Bool
    public var layout: SourceLayout
    /// Picture-in-picture width as a fraction of the canvas width.
    public var pipScale: Double
    public var isMirrored: Bool
    public var opacity: Float
    public var filter: FilterType
    public var adjustments: FilterParameters

    public init(id: UUID = UUID(), name: String, input: VideoSource, isVisible: Bool = true,
                layout: SourceLayout = .fit, pipScale: Double = 0.3, isMirrored: Bool = false, opacity: Float = 1,
                filter: FilterType = .passthrough, adjustments: FilterParameters = FilterParameters()) {
        self.id = id
        self.name = name
        self.input = input
        self.isVisible = isVisible
        self.layout = layout
        self.pipScale = pipScale
        self.isMirrored = isMirrored
        self.opacity = opacity
        self.filter = filter
        self.adjustments = adjustments
    }
}
