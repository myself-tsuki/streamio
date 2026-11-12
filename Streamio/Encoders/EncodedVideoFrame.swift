//
//  EncodedVideoFrame.swift
//  Streamio
//

import CoreMedia
import Foundation

/// One compressed access unit produced by `VideoEncoder`.
nonisolated public struct EncodedVideoFrame: @unchecked Sendable {
    /// Length-prefixed NAL units (AVCC / HVCC layout), ready for FLV.
    public let accessUnit: Data
    /// Host-clock seconds.
    public let pts: Double
    public let dts: Double
    public let isKeyFrame: Bool
    /// The original compressed sample, used by the recorder in pass-through mode.
    public let sampleBuffer: CMSampleBuffer
}
