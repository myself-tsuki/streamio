//
//  FilterParameters.swift
//  Streamio
//

import Foundation

nonisolated public struct FilterParameters: Equatable, Codable, Sendable {
    /// -0.5 … 0.5, neutral 0
    public var brightness: Float = 0
    /// 0.5 … 2.0, neutral 1
    public var contrast: Float = 1
    /// 0 … 2.0, neutral 1
    public var saturation: Float = 1
    /// 0 … 1, strength of the selected filter
    public var intensity: Float = 1

    public init(brightness: Float = 0, contrast: Float = 1, saturation: Float = 1, intensity: Float = 1) {
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.intensity = intensity
    }

    /// True when the adjustments leave the image unchanged.
    public var isNeutral: Bool {
        brightness == 0 && contrast == 1 && saturation == 1
    }
}
