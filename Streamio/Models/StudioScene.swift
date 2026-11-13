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

    /// The main camera: the lowest camera layer, the one added first. It shares the capture
    /// session with the microphone. Any other camera in the scene is an overlay (a face cam).
    public var cameraSource: SceneSource? { sources.last { $0.input.isCamera } }
    /// Cameras beyond the main one, each captured on its own.
    public var extraCameraSources: [SceneSource] {
        guard let main = cameraSource else { return [] }
        return sources.filter { $0.input.isCamera && $0.id != main.id }
    }
    /// One display capture per scene.
    public var displaySource: SceneSource? { sources.first { $0.input.isDisplay } }

    public var systemImage: String {
        sources.first(where: \.isVisible)?.input.systemImage ?? "square.stack"
    }
}
