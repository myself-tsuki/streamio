import Foundation
let values: [AMF0Value] = [.string("connect"), .number(1), .object([AMF0Property("app", .string("live2"))]), .null, .strictArray([.string("hvc1")]), .boolean(true), .ecmaArray([AMF0Property("w", .number(1920))])]
precondition(AMF0.decodeAll(AMF0.encode(values)) == values, "amf")
var reader = RTMPChunkReader()
let payload = Data((0..<300).map { UInt8($0 % 251) })
var wire = RTMPChunker.chunkMessage(csid: 6, typeId: 9, streamId: 1, timestamp: 4242, payload: payload, chunkSize: 128)
wire += RTMPChunker.chunkMessage(csid: 3, typeId: 20, streamId: 0, timestamp: 0x01FF_FFFF, payload: AMF0.encode(values), chunkSize: 128)
var got: [RTMPMessage] = []
for byte in wire { got += reader.append(Data([byte])) } // byte-at-a-time stress
precondition(got.count == 2 && got[0].payload == payload && got[0].timestamp == 4242, "chunk")
precondition(got[1].timestamp == 0x01FF_FFFF && AMF0.decodeAll(got[1].payload) == values, "ext ts")
precondition(RTMPEndpoint(urlString: "rtmp://live.twitch.tv/app")?.port == 1935, "endpoint")
precondition(RTMPEndpoint(urlString: "rtmps://a.rtmps.youtube.com:443/live2")?.tcUrl == "rtmps://a.rtmps.youtube.com:443/live2")
precondition(FLVTag.audioSpecificConfig(sampleRate: 48000, channels: 2) == Data([0x11, 0x90]), "asc")
precondition(FLVTag.videoFrame(format: .hevc, accessUnit: Data([9]), isKeyFrame: true, compositionTimeMs: 0).prefix(5) == Data([0x93, 0x68, 0x76, 0x63, 0x31]), "ertmp")
var ring = AudioRingBuffer(capacity: 4)
ring.write(left: [1,2,3,4,5,6], right: [1,2,3,4,5,6])
var l = [Float](repeating: 0, count: 4), r = l
l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in _ = ring.mix(into: lp, rp, count: 4, gain: 1) } }
precondition(l == [3,4,5,6], "ring \(l)")
precondition(AudioLevels.decibels(fromAmplitude: 1) == 0 && AudioLevels.amplitude(fromDecibels: -60) == 0, "levels")
print("PROTOCOL_CHECKS_OK")
