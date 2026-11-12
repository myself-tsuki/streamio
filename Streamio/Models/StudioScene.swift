//
//  StudioScene.swift
//  Streamio
//

import Foundation

/// A named arrangement of a video source plus its colour treatment, like an OBS scene.
nonisolated public struct StudioScene: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var videoSource: VideoSource
    public var isVideoVisible: Bool
    public var filter: FilterType
    public var adjustments: FilterParameters

    public init(id: UUID = UUID(), name: String, videoSource: VideoSource = .none, isVideoVisible: Bool = true,
                filter: FilterType = .passthrough, adjustments: FilterParameters = FilterParameters()) {
        self.id = id
        self.name = name
        self.videoSource = videoSource
        self.isVideoVisible = isVideoVisible
        self.filter = filter
        self.adjustments = adjustments
    }
}
