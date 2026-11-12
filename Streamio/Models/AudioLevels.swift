//
//  AudioLevels.swift
//  Streamio
//

import Foundation

/// Stereo meter reading in dBFS (-60 … 0).
nonisolated public struct AudioLevels: Equatable, Sendable {
    public static let floor: Float = -60
    public static let silent = AudioLevels(peakLeft: floor, peakRight: floor, rmsLeft: floor, rmsRight: floor)

    public var peakLeft: Float
    public var peakRight: Float
    public var rmsLeft: Float
    public var rmsRight: Float

    public init(peakLeft: Float, peakRight: Float, rmsLeft: Float, rmsRight: Float) {
        self.peakLeft = peakLeft
        self.peakRight = peakRight
        self.rmsLeft = rmsLeft
        self.rmsRight = rmsRight
    }

    public var maxPeak: Float { max(peakLeft, peakRight) }

    /// Linear amplitude → clamped dBFS.
    public static func decibels(fromAmplitude amplitude: Float) -> Float {
        guard amplitude > 0 else { return floor }
        return Swift.max(floor, Swift.min(0, 20 * log10(amplitude)))
    }

    /// Fader gain in dB → linear multiplier. -60 dB and below is silence, like OBS's -inf.
    public static func amplitude(fromDecibels decibels: Float) -> Float {
        decibels <= floor ? 0 : pow(10, decibels / 20)
    }

    /// Meter ballistics: peaks fall by at most `fall` dB per update; RMS follows directly.
    public func decayed(toward next: AudioLevels, fall: Float) -> AudioLevels {
        AudioLevels(
            peakLeft: Swift.max(next.peakLeft, peakLeft - fall),
            peakRight: Swift.max(next.peakRight, peakRight - fall),
            rmsLeft: next.rmsLeft,
            rmsRight: next.rmsRight
        )
    }
}
