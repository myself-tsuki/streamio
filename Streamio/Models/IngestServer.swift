//
//  IngestServer.swift
//  Streamio
//

import Foundation

nonisolated public struct IngestServer: Identifiable, Hashable, Sendable {
    public var name: String
    public var url: String
    public var id: String { url }
}
