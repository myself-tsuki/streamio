//
//  RTMPEndpoint.swift
//  Streamio
//

import Foundation

/// A parsed `rtmp://` or `rtmps://` ingest URL.
nonisolated public struct RTMPEndpoint: Equatable, Sendable {
    public var host: String
    public var port: UInt16
    public var app: String
    public var isSecure: Bool

    /// The `tcUrl` sent in the connect command: scheme, host, port and app, without the stream key.
    public var tcUrl: String {
        "\(isSecure ? "rtmps" : "rtmp")://\(host):\(port)/\(app)"
    }

    public init(host: String, port: UInt16, app: String, isSecure: Bool) {
        self.host = host
        self.port = port
        self.app = app
        self.isSecure = isSecure
    }

    /// Returns nil when the URL is not a usable RTMP(S) address.
    public init?(urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "rtmp" || scheme == "rtmps",
              let host = components.host, !host.isEmpty else {
            return nil
        }

        let secure = scheme == "rtmps"
        let path = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty else { return nil }

        var app = path
        if let query = components.percentEncodedQuery, !query.isEmpty {
            app += "?\(query)"
        }

        let port = components.port.flatMap { UInt16(exactly: $0) } ?? (secure ? 443 : 1935)
        self.init(host: host, port: port, app: app, isSecure: secure)
    }
}
