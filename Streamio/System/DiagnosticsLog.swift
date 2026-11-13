//
//  DiagnosticsLog.swift
//  Streamio
//
//  A small text log of what the audio, capture, recording and network code is doing, so a
//  problem seen during a live show can be explained afterwards. One line per event, written to
//  ~/Library/Logs/Streamio/diagnostics.log (trimmed when it grows past 2 MB).
//

import Foundation

nonisolated enum DiagnosticsLog {
    private static let queue = DispatchQueue(label: "com.streamio.diagnostics", qos: .utility)
    private static let maxBytes = 2_000_000

    static var fileURL: URL {
        URL.libraryDirectory.appending(path: "Logs/Streamio/diagnostics.log")
    }

    /// Appends "12:03:41.512 [audio] message". Safe to call from any thread.
    static func log(_ category: String, _ message: String) {
        let stamp = Date.now
        queue.async {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            let line = "\(formatter.string(from: stamp)) [\(category)] \(message)\n"
            let url = fileURL
            let manager = FileManager.default
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !manager.fileExists(atPath: url.path(percentEncoded: false)) {
                manager.createFile(atPath: url.path(percentEncoded: false), contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            if let size = try? handle.seekToEnd(), size > UInt64(maxBytes) {
                try? handle.truncate(atOffset: 0)
            }
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }
}
