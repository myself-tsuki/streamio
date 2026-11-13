//
//  PingProbe.swift
//  Streamio
//
//  Round-trip time to an ingest server, measured as the time a TCP connection takes to
//  open. No ICMP, so it needs no special permission.
//

import Foundation
import Network

nonisolated enum PingProbe {
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func run(_ body: () -> Void) {
            lock.lock()
            let first = !done
            done = true
            lock.unlock()
            if first { body() }
        }
    }

    /// Milliseconds to open a TCP connection, or nil when the host is unreachable.
    static func measure(host: String, port: UInt16, timeout: TimeInterval = 3) async -> Double? {
        guard let port = NWEndpoint.Port(rawValue: port) else { return nil }
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
            let once = Once()
            let start = DispatchTime.now()
            let queue = DispatchQueue(label: "streamio.ping")

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let nanos = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
                    once.run {
                        connection.cancel()
                        continuation.resume(returning: Double(nanos) / 1_000_000)
                    }
                case .failed, .cancelled:
                    once.run { continuation.resume(returning: nil) }
                default:
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) {
                once.run {
                    connection.cancel()
                    continuation.resume(returning: nil)
                }
            }
            connection.start(queue: queue)
        }
    }
}
