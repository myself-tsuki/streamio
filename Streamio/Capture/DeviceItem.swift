//
//  DeviceItem.swift
//  Streamio
//

import Foundation

/// A camera or microphone as shown in pickers.
nonisolated struct DeviceItem: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let isDefault: Bool
}
