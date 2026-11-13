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

/// Outline a source is cut to. The "square" shapes crop the picture to a centred square so a
/// face stays a face; the rectangle shapes keep the source's own proportions.
nonisolated public enum SourceShape: String, CaseIterable, Identifiable, Codable, Sendable {
    case rectangle
    case roundedRectangle
    case square
    case roundedSquare
    case circle
    case hexagon
    case diamond

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .rectangle: String(localized: "Rectangle")
        case .roundedRectangle: String(localized: "Rounded Rectangle")
        case .square: String(localized: "Square")
        case .roundedSquare: String(localized: "Rounded Square")
        case .circle: String(localized: "Circle")
        case .hexagon: String(localized: "Hexagon")
        case .diamond: String(localized: "Diamond")
        }
    }

    public var systemImage: String {
        switch self {
        case .rectangle: "rectangle"
        case .roundedRectangle: "rectangle.roundedtop"
        case .square: "square"
        case .roundedSquare: "app"
        case .circle: "circle"
        case .hexagon: "hexagon"
        case .diamond: "diamond"
        }
    }

    /// Crops the picture to a centred square when the source is a corner overlay.
    public var cropsToSquare: Bool {
        switch self {
        case .rectangle, .roundedRectangle: false
        default: true
        }
    }

    /// Code used by the Metal shader: 0 box, 1 rounded box, 2 ellipse, 3 hexagon, 4 diamond.
    public var shaderCode: UInt32 {
        switch self {
        case .rectangle, .square: 0
        case .roundedRectangle, .roundedSquare: 1
        case .circle: 2
        case .hexagon: 3
        case .diamond: 4
        }
    }
}

/// Plain sRGB colour for borders (SwiftUI's Color is not Codable).
nonisolated public struct SourceColor: Equatable, Codable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let white = SourceColor(red: 1, green: 1, blue: 1)
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
    /// Outline for corner overlays such as a face camera.
    public var shape: SourceShape
    /// Border thickness as a fraction of the shorter side (0 = none).
    public var borderWidth: Double
    public var borderColor: SourceColor
    /// Nudge from the layout's position, as a fraction of the canvas (right and down are positive).
    public var offsetX: Double
    public var offsetY: Double

    public init(id: UUID = UUID(), name: String, input: VideoSource, isVisible: Bool = true,
                layout: SourceLayout = .fit, pipScale: Double = 0.3, isMirrored: Bool = false, opacity: Float = 1,
                filter: FilterType = .passthrough, adjustments: FilterParameters = FilterParameters(),
                shape: SourceShape = .rectangle, borderWidth: Double = 0, borderColor: SourceColor = .white,
                offsetX: Double = 0, offsetY: Double = 0) {
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
        self.shape = shape
        self.borderWidth = borderWidth
        self.borderColor = borderColor
        self.offsetX = offsetX
        self.offsetY = offsetY
    }

    // Scenes saved before shapes existed lack the new keys; give them the old look.
    private enum CodingKeys: String, CodingKey {
        case id, name, input, isVisible, layout, pipScale, isMirrored, opacity, filter, adjustments
        case shape, borderWidth, borderColor, offsetX, offsetY
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        input = try c.decode(VideoSource.self, forKey: .input)
        isVisible = try c.decode(Bool.self, forKey: .isVisible)
        layout = try c.decode(SourceLayout.self, forKey: .layout)
        pipScale = try c.decode(Double.self, forKey: .pipScale)
        isMirrored = try c.decode(Bool.self, forKey: .isMirrored)
        opacity = try c.decode(Float.self, forKey: .opacity)
        filter = try c.decode(FilterType.self, forKey: .filter)
        adjustments = try c.decode(FilterParameters.self, forKey: .adjustments)
        shape = try c.decodeIfPresent(SourceShape.self, forKey: .shape) ?? .rectangle
        borderWidth = try c.decodeIfPresent(Double.self, forKey: .borderWidth) ?? 0
        borderColor = try c.decodeIfPresent(SourceColor.self, forKey: .borderColor) ?? .white
        offsetX = try c.decodeIfPresent(Double.self, forKey: .offsetX) ?? 0
        offsetY = try c.decodeIfPresent(Double.self, forKey: .offsetY) ?? 0
    }
}
