//
//  PreviewFrameStore.swift
//  Streamio
//

import CoreVideo
import Foundation

/// Hand-off point between the video pipeline (writer) and the preview view (reader).
/// The preview only redraws when a new canvas frame has arrived.
nonisolated public final class PreviewFrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: CVPixelBuffer?
    private var generation: UInt64 = 0

    public init() {}

    public func publish(_ pixelBuffer: CVPixelBuffer?) {
        lock.withLock {
            frame = pixelBuffer
            generation &+= 1
        }
    }

    /// Returns the latest frame if it is newer than `seen`.
    public func frame(newerThan seen: UInt64) -> (CVPixelBuffer, UInt64)? {
        lock.withLock {
            guard generation != seen, let frame else { return nil }
            return (frame, generation)
        }
    }
}
