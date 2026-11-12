//
//  StudioScene.swift
//  Streamio
//

import Foundation

/// A named stack of sources, like an OBS scene. `sources[0]` is the top layer.
nonisolated public struct StudioScene: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var sources: [SceneSource]

    public init(id: UUID = UUID(), name: String, sources: [SceneSource] = []) {
        self.id = id
        self.name = name
        self.sources = sources
    }

    /// One camera input per scene: the capture session owns a single camera at a time.
    public var cameraSource: SceneSource? { sources.first { $0.input.isCamera } }
    /// One display capture per scene.
    public var displaySource: SceneSource? { sources.first { $0.input.isDisplay } }

    public var systemImage: String {
        sources.first(where: \.isVisible)?.input.systemImage ?? "square.stack"
    }
}
