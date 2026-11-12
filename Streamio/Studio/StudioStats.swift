//
//  StudioStats.swift
//  Streamio
//
//  Status-bar and fullscreen-overlay figures. Kept apart from the controller so 1 Hz
//  updates only invalidate the views that show them, not the whole window.
//

import Foundation
import Observation

@Observable
final class StudioStats {
    /// Canvas frames rendered per second (what the encoder receives).
    var fps: Double = 0
    /// Frames per second actually arriving from the camera.
    var cameraFPS: Double = 0
    /// Average GPU compose time per frame.
    var renderMilliseconds: Double = 0
    var skippedFrames = 0
    var droppedFrames = 0
    var sentFrames = 0
    /// Total upload across every destination.
    var bitrateKbps: Double = 0
    var bytesSent: UInt64 = 0
    var congestion: Double = 0
    var network: [UUID: RTMPClient.Statistics] = [:]
    var cpuPercent: Double = 0
    var gpuPercent: Double?
    var memoryBytes: UInt64 = 0
    var diskFreeBytes: Int64?
    var streamStart: Date?
    var recordStart: Date?
    var recordedBytes: Int64 = 0

    var droppedPercent: Double {
        let total = droppedFrames + sentFrames
        return total == 0 ? 0 : Double(droppedFrames) / Double(total) * 100
    }

    func aggregateNetwork() {
        let values = Array(network.values)
        bitrateKbps = values.reduce(0) { $0 + $1.bitrateKbps }
        bytesSent = values.reduce(0) { $0 + $1.bytesSent }
        droppedFrames = values.reduce(0) { $0 + $1.droppedVideoFrames }
        sentFrames = values.reduce(0) { $0 + $1.sentVideoFrames }
        congestion = values.map(\.congestion).max() ?? 0
    }
}
