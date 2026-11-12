//
//  StreamioTests.swift
//  StreamioTests
//

import Foundation
import Testing
@testable import Streamio

struct ProtocolTests {
    @Test func amf0RoundTrip() {
        let values: [AMF0Value] = [.string("connect"), .number(1), .object([AMF0Property("app", .string("live2"))]), .null,
                                   .strictArray([.string("hvc1")]), .boolean(true)]
        #expect(AMF0.decodeAll(AMF0.encode(values)) == values)
    }

    @Test func chunkerAndReaderAgree() {
        var reader = RTMPChunkReader()
        let payload = Data((0..<300).map { UInt8($0 % 251) })
        let chunks = RTMPChunker.chunkMessage(csid: 6, typeId: 9, streamId: 1, timestamp: 4242, payload: payload, chunkSize: 128)
        let messages = reader.append(chunks)
        #expect(messages == [RTMPMessage(typeId: 9, streamId: 1, timestamp: 4242, payload: payload)])
    }

    @Test func endpointParsing() {
        let endpoint = RTMPEndpoint(urlString: "rtmps://a.rtmps.youtube.com:443/live2")
        #expect(endpoint == RTMPEndpoint(host: "a.rtmps.youtube.com", port: 443, app: "live2", isSecure: true))
        #expect(RTMPEndpoint(urlString: "http://example.com/live") == nil)
    }

    @Test func audioSpecificConfigFor48kStereo() {
        #expect(FLVTag.audioSpecificConfig(sampleRate: 48_000, channels: 2) == Data([0x11, 0x90]))
    }

    @Test func ringBufferMixesAndOverflows() {
        var ring = AudioRingBuffer(capacity: 4)
        ring.write(left: [1, 2, 3, 4, 5, 6], right: [1, 2, 3, 4, 5, 6])
        var left = [Float](repeating: 0, count: 4), right = left
        left.withUnsafeMutableBufferPointer { l in right.withUnsafeMutableBufferPointer { r in _ = ring.mix(into: l, r, count: 4, gain: 1) } }
        #expect(left == [3, 4, 5, 6])
    }
}
