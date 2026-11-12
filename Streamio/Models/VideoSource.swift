//
//  VideoSource.swift
//  Streamio
//

import Foundation

/// The video input feeding a scene.
nonisolated public enum VideoSource: Hashable, Codable, Sendable {
    case none
    /// `AVCaptureDevice.uniqueID`
    case camera(id: String)
    /// `CGDirectDisplayID`
    case display(id: UInt32)

    public var systemImage: String {
        switch self {
        case .none: "rectangle.dashed"
        case .camera: "web.camera"
        case .display: "display"
        }
    }
}
