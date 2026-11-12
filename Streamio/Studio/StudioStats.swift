//
//  StudioStats.swift
//  Streamio
//
//  Status-bar figures. Kept apart from the controller so 1 Hz updates only
//  invalidate the status bar, not the whole window.
//

import Foundation
import Observation

@Observable
final class StudioStats {
    var fps: Double = 0
    var skippedFrames = 0
    var droppedFrames = 0
    var sentFrames = 0
    var bitrateKbps: Double = 0
    var bytesSent: UInt64 = 0
    var congestion: Double = 0
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
}
