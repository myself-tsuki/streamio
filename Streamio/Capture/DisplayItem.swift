//
//  DisplayItem.swift
//  Streamio
//

import Foundation

/// A connected display as shown in pickers.
nonisolated struct DisplayItem: Identifiable, Hashable, Sendable {
    /// `CGDirectDisplayID`
    let id: UInt32
    let name: String
    let width: Int
    let height: Int
}
