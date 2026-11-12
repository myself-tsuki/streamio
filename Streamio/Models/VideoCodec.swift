//
//  VideoCodec.swift
//  Streamio
//

import AVFoundation
import CoreMedia

nonisolated public enum VideoCodec: String, CaseIterable, Identifiable, Codable, Sendable {
    case h264
    case hevc

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .h264: String(localized: "H.264 (Hardware)")
        case .hevc: String(localized: "HEVC (Hardware)")
        }
    }

    public var cmCodecType: CMVideoCodecType {
        switch self {
        case .h264: kCMVideoCodecType_H264
        case .hevc: kCMVideoCodecType_HEVC
        }
    }

    public var flvFormat: FLVVideoFormat {
        switch self {
        case .h264: .avc
        case .hevc: .hevc
        }
    }

    public var assetWriterCodec: AVVideoCodecType {
        switch self {
        case .h264: .h264
        case .hevc: .hevc
        }
    }
}
