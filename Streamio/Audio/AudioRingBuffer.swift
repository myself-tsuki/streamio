//
//  AudioRingBuffer.swift
//  Streamio
//
//  Fixed-capacity stereo FIFO used by the mixer to line up sources that deliver
//  audio in differently sized chunks. Not thread-safe: the mixer guards it with a lock.
//

import Foundation

nonisolated public struct AudioRingBuffer: Sendable {
    public let capacity: Int
    private var left: [Float]
    private var right: [Float]
    private var readIndex = 0
    public private(set) var availableFrames = 0

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        left = [Float](repeating: 0, count: self.capacity)
        right = [Float](repeating: 0, count: self.capacity)
    }

    /// Appends frames. When the buffer is full the oldest audio is discarded
    /// so latency never grows without bound.
    public mutating func write(left source: UnsafeBufferPointer<Float>, right sourceRight: UnsafeBufferPointer<Float>) {
        let count = min(source.count, sourceRight.count)
        guard count > 0 else { return }

        let start = count > capacity ? count - capacity : 0
        let framesToWrite = count - start
        let overflow = max(0, availableFrames + framesToWrite - capacity)
        if overflow > 0 {
            readIndex = (readIndex + overflow) % capacity
            availableFrames -= overflow
        }

        var writeIndex = (readIndex + availableFrames) % capacity
        for frame in start..<count {
            left[writeIndex] = source[frame]
            right[writeIndex] = sourceRight[frame]
            writeIndex += 1
            if writeIndex == capacity { writeIndex = 0 }
        }
        availableFrames += framesToWrite
    }

    public mutating func write(left source: [Float], right sourceRight: [Float]) {
        source.withUnsafeBufferPointer { l in
            sourceRight.withUnsafeBufferPointer { r in
                write(left: l, right: r)
            }
        }
    }

    /// Mixes up to `count` frames into the destination, scaled by `gain`.
    /// Returns how many frames were available; missing frames contribute silence.
    @discardableResult
    public mutating func mix(into destinationLeft: UnsafeMutableBufferPointer<Float>,
                             _ destinationRight: UnsafeMutableBufferPointer<Float>,
                             count: Int, gain: Float) -> Int {
        let frames = min(count, availableFrames, destinationLeft.count, destinationRight.count)
        var index = readIndex
        for frame in 0..<frames {
            destinationLeft[frame] += left[index] * gain
            destinationRight[frame] += right[index] * gain
            index += 1
            if index == capacity { index = 0 }
        }
        readIndex = index
        availableFrames -= frames
        return frames
    }

    /// Drops the oldest `count` frames (used to cap latency when a source runs ahead).
    public mutating func skip(_ count: Int) {
        let frames = min(max(0, count), availableFrames)
        readIndex = (readIndex + frames) % capacity
        availableFrames -= frames
    }

    public mutating func removeAll() {
        readIndex = 0
        availableFrames = 0
    }
}
