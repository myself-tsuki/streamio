//
//  VideoSource.swift
//  Streamio
//

import Foundation

/// What a scene source captures. Devices are bound by their exact ID: if that
/// device is missing, the source stays dark instead of falling back to another one.
nonisolated public enum VideoSource: Hashable, Codable, Sendable {
    /// `AVCaptureDevice.uniqueID`
    case camera(id: String)
    /// `CGDirectDisplayID`
    case display(id: UInt32)
    /// A still image (PNG, JPEG, HEIC…) such as a logo or "be right back" card.
    case image(path: String)

    public var systemImage: String {
        switch self {
        case .camera: "web.camera"
        case .display: "display"
        case .image: "photo"
        }
    }

    public var kindTitle: String {
        switch self {
        case .camera: String(localized: "Video Capture Device")
        case .display: String(localized: "Display Capture")
        case .image: String(localized: "Image")
        }
    }

    public var isCamera: Bool {
        if case .camera = self { true } else { false }
    }

    public var isDisplay: Bool {
        if case .display = self { true } else { false }
    }
}
