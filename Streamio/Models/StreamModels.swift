//
//  StreamModels.swift
//  Streamio
//

import Foundation
import AVFoundation

public enum VideoResolution: String, CaseIterable, Identifiable, Sendable {
    case res4K = "4K UHD (3840x2160)"
    case res1080p = "1080p FHD (1920x1080)"
    case res720p = "720p HD (1280x720)"
    case res540p = "540p SD (960x540)"

    public var id: String { rawValue }

    public var dimensions: (width: Int32, height: Int32) {
        switch self {
        case .res4K: return (3840, 2160)
        case .res1080p: return (1920, 1080)
        case .res720p: return (1280, 720)
        case .res540p: return (960, 540)
        }
    }

    public var preset: AVCaptureSession.Preset {
        switch self {
        case .res4K: return .hd4K3840x2160
        case .res1080p: return .hd1920x1080
        case .res720p: return .hd1280x720
        case .res540p: return .iFrame960x540
        }
    }

    public var defaultBitrate: Int {
        switch self {
        case .res4K: return 15_000_000
        case .res1080p: return 6_000_000
        case .res720p: return 3_500_000
        case .res540p: return 1_800_000
        }
    }
}

public enum FrameRate: Int, CaseIterable, Identifiable, Sendable {
    case fps24 = 24
    case fps30 = 30
    case fps60 = 60

    public var id: Int { rawValue }
    public var label: String { "\(rawValue) fps" }
}

public enum VideoCodec: String, CaseIterable, Identifiable, Sendable {
    case h264 = "H.264 (AVC)"
    case hevc = "H.265 (HEVC)"

    public var id: String { rawValue }

    public var cmCodecType: CMVideoCodecType {
        switch self {
        case .h264: return kCMVideoCodecType_H264
        case .hevc: return kCMVideoCodecType_HEVC
        }
    }
}

public enum AudioBitrate: Int, CaseIterable, Identifiable, Sendable {
    case kbps96 = 96_000
    case kbps128 = 128_000
    case kbps160 = 160_000
    case kbps192 = 192_000
    case kbps320 = 320_000

    public var id: Int { rawValue }
    public var label: String { "\(rawValue / 1000) kbps" }
}

public enum FilterType: String, CaseIterable, Identifiable, Sendable {
    case passthrough = "Normal"
    case mono = "Noir / Monochrome"
    case sepia = "Warm Sepia"
    case cyberpunk = "Cyberpunk Neon"
    case vignette = "Studio Vignette"
    case comic = "Comic / Posterize"
    case invert = "Inverted Color"
    case greenScreen = "Chroma Key (Green)"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .passthrough: return "camera.filters"
        case .mono: return "circle.lefthalf.filled"
        case .sepia: return "sun.dust.fill"
        case .cyberpunk: return "wand.and.stars"
        case .vignette: return "oval.portrait.fill"
        case .comic: return "paintpalette.fill"
        case .invert: return "circle.dashed"
        case .greenScreen: return "leaf.fill"
        }
    }
}

public struct FilterParameters: Sendable {
    public var brightness: Float = 0.0      // -1.0 to 1.0
    public var contrast: Float = 1.0        // 0.25 to 2.0
    public var saturation: Float = 1.0      // 0.0 to 2.0
    public var filterIntensity: Float = 1.0 // 0.0 to 1.0

    public init(brightness: Float = 0.0, contrast: Float = 1.0, saturation: Float = 1.0, filterIntensity: Float = 1.0) {
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.filterIntensity = filterIntensity
    }
}

public enum StreamStatus: Equatable, Sendable {
    case idle
    case connecting
    case streaming
    case reconnecting
    case error(String)

    public var label: String {
        switch self {
        case .idle: return "Ready"
        case .connecting: return "Connecting..."
        case .streaming: return "LIVE"
        case .reconnecting: return "Reconnecting..."
        case .error(let msg): return "Error: \(msg)"
        }
    }

    public var isLive: Bool {
        if case .streaming = self { return true }
        return false
    }
}

public struct StreamStats: Sendable {
    public var currentFps: Double = 0.0
    public var outputBitrateKbps: Double = 0.0
    public var droppedFrames: Int = 0
    public var streamedBytes: UInt64 = 0
    public var streamingDuration: TimeInterval = 0.0

    public var isRecording: Bool = false
    public var recordingDuration: TimeInterval = 0.0
    public var recordedBytes: UInt64 = 0

    public var audioLevelLeft: Float = -60.0  // dB (-60 to 0)
    public var audioLevelRight: Float = -60.0 // dB (-60 to 0)

    public init() {}
}

