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

// Canvas placement: fill crops the long side, PiP keeps aspect and sits inside the margin.
let fill = CanvasPlacement.make(layout: .fill, pipScale: 0.3, contentWidth: 1440, contentHeight: 1080, canvasWidth: 1920, canvasHeight: 1080)
precondition(fill.width == 1920 && abs(fill.cropHeight - 0.75) < 0.0001 && abs(fill.cropY - 0.125) < 0.0001 && fill.cropWidth == 1, "fill \(fill)")
let fit = CanvasPlacement.make(layout: .fit, pipScale: 0.3, contentWidth: 1440, contentHeight: 1080, canvasWidth: 1920, canvasHeight: 1080)
precondition(fit.width == 1440 && fit.x == 240 && fit.height == 1080, "fit \(fit)")
let pip = CanvasPlacement.make(layout: .bottomRight, pipScale: 0.25, contentWidth: 1280, contentHeight: 720, canvasWidth: 1920, canvasHeight: 1080)
precondition(pip.width == 480 && pip.height == 270 && pip.x + pip.width == 1920 - 48 && pip.y + pip.height == 1080 - 48, "pip \(pip)")
let tall = CanvasPlacement.make(layout: .topLeft, pipScale: 0.3, contentWidth: 1080, contentHeight: 1920, canvasWidth: 1920, canvasHeight: 1080)
precondition(tall.height <= 1080 * 0.54 + 0.001 && tall.x == 48 && tall.y == 48, "tall \(tall)")

// Scenes start empty and round-trip through JSON with their sources.
var scene = StudioScene(name: "Main")
precondition(scene.sources.isEmpty && scene.cameraSource == nil, "empty scene")
scene.sources = [SceneSource(name: "Cam", input: .camera(id: "usb-1"), layout: .bottomRight),
                 SceneSource(name: "Screen", input: .display(id: 2)),
                 SceneSource(name: "Logo", input: .image(path: "/tmp/logo.png"), opacity: 0.8)]
let decoded = try! JSONDecoder().decode(StudioScene.self, from: try! JSONEncoder().encode(scene))
precondition(decoded == scene && decoded.cameraSource?.input == .camera(id: "usb-1") && decoded.displaySource?.name == "Screen", "scene codable")

// Monitoring modes and audio source defaults.
precondition(!MonitoringMode.monitorOnly.feedsOutput && MonitoringMode.monitorOnly.isMonitoring, "monitor only")
precondition(MonitoringMode.monitorAndOutput.feedsOutput && !MonitoringMode.off.isMonitoring, "monitor modes")
let mic = AudioSourceConfig(channel: .microphone, deviceID: "usb-mic")
precondition(mic.gainDecibels == 0 && !mic.isMuted && mic.monitoring == .off && mic.id == .microphone, "audio defaults")
precondition(AudioLevels.amplitude(fromDecibels: 20) > 9.99 && AudioLevels.amplitude(fromDecibels: 20) < 10.01, "+20 dB")

// Destinations get their own keychain account and default server.
let facebook = StreamDestination(name: "Facebook", service: .facebook)
precondition(facebook.serverURL.hasPrefix("rtmps://") && facebook.keychainAccount.hasPrefix("destination."), "destination")
print("PROTOCOL_CHECKS_OK")

// Face cam: a circle overlay is a centred square crop, nudges stay on the canvas, and two cameras
// give the lowest layer as the main one.
let face = CanvasPlacement.make(layout: .bottomRight, pipScale: 0.2, contentWidth: 1920, contentHeight: 1080,
                                canvasWidth: 1920, canvasHeight: 1080, squareCrop: SourceShape.circle.cropsToSquare, offsetX: 0, offsetY: 0)
precondition(face.width == face.height && face.width == 384 && abs(face.cropWidth - 0.5625) < 0.0001 && abs(face.cropX - 0.21875) < 0.0001, "face \(face)")
let nudged = CanvasPlacement.make(layout: .bottomRight, pipScale: 0.2, contentWidth: 1920, contentHeight: 1080,
                                  canvasWidth: 1920, canvasHeight: 1080, squareCrop: true, offsetX: 0.5, offsetY: 0.5)
precondition(nudged.x + nudged.width <= 1920 && nudged.y + nudged.height <= 1080, "nudge \(nudged)")
var twoCams = StudioScene(name: "Two")
twoCams.sources = [SceneSource(name: "Face", input: .camera(id: "face"), shape: .circle), SceneSource(name: "Main", input: .camera(id: "main"))]
precondition(twoCams.cameraSource?.name == "Main" && twoCams.extraCameraSources.map(\.name) == ["Face"], "two cameras")
let legacy = #"{"id":"\#(UUID().uuidString)","name":"Old","input":{"image":{"path":"/x.png"}},"isVisible":true,"layout":"fit","pipScale":0.3,"isMirrored":false,"opacity":1,"filter":"passthrough","adjustments":{"brightness":0,"contrast":1,"saturation":1,"intensity":1}}"#
let old = try! JSONDecoder().decode(SceneSource.self, from: Data(legacy.utf8))
precondition(old.shape == .rectangle && old.borderWidth == 0, "legacy source")
