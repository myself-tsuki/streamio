//
//  RTMPClient.swift
//  Streamio
//
//  Publishing RTMP/RTMPS client built on Network.framework.
//
//  Every piece of mutable state is confined to `queue`; public entry points hop onto it.
//  The client implements the full publish handshake (connect → createStream → publish),
//  answers pings and acknowledgement windows, applies back-pressure by dropping
//  non-key video frames when the socket falls behind, and reconnects automatically.
//

import Foundation
import Network

nonisolated public final class RTMPClient: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var endpoint: RTMPEndpoint
        public var streamKey: String
        public var width: Int
        public var height: Int
        public var fps: Int
        public var videoBitrate: Int
        public var audioBitrate: Int
        public var audioSampleRate: Double
        public var videoFormat: FLVVideoFormat
        public var autoReconnect: Bool
        public var maxReconnectAttempts: Int
        public var reconnectDelay: Duration

        public init(endpoint: RTMPEndpoint, streamKey: String, width: Int, height: Int, fps: Int,
                    videoBitrate: Int, audioBitrate: Int, audioSampleRate: Double, videoFormat: FLVVideoFormat,
                    autoReconnect: Bool, maxReconnectAttempts: Int, reconnectDelay: Duration) {
            self.endpoint = endpoint
            self.streamKey = streamKey
            self.width = width
            self.height = height
            self.fps = fps
            self.videoBitrate = videoBitrate
            self.audioBitrate = audioBitrate
            self.audioSampleRate = audioSampleRate
            self.videoFormat = videoFormat
            self.autoReconnect = autoReconnect
            self.maxReconnectAttempts = maxReconnectAttempts
            self.reconnectDelay = reconnectDelay
        }
    }

    public struct Statistics: Equatable, Sendable {
        public var bytesSent: UInt64 = 0
        public var bitrateKbps: Double = 0
        public var sentVideoFrames = 0
        public var droppedVideoFrames = 0
        /// 0 = socket keeping up, 1 = send buffer at its drop threshold.
        public var congestion: Double = 0
    }

    public enum Event: Sendable {
        case status(StreamStatus)
        case statistics(Statistics)
    }

    private enum Phase {
        case idle
        case handshaking
        case connecting
        case creatingStream
        case publishing
        case live
    }

    /// Called on the client's private queue. Set before `connect`.
    public var onEvent: (@Sendable (Event) -> Void)?
    /// Asks the video encoder for an IDR frame (stream start, after drops).
    public var onKeyFrameRequest: (@Sendable () -> Void)?

    private let queue = DispatchQueue(label: "com.streamio.rtmp", qos: .userInitiated)

    // Connection
    private var configuration: Configuration?
    private var connection: NWConnection?
    private var generation = 0
    private var phase: Phase = .idle
    private var reader = RTMPChunkReader()
    private var handshakeBuffer = Data()
    private var outgoingChunkSize = 4096
    private var reconnectAttempts = 0
    private var userRequestedStop = false

    // Protocol bookkeeping
    private var nextTransactionID = 1.0
    private var connectTransactionID = 0.0
    private var createStreamTransactionID = 0.0
    private var messageStreamID: UInt32 = 1
    private var serverWindowAckSize: UInt32 = 2_500_000
    private var bytesReceived: UInt64 = 0
    private var lastAcknowledged: UInt64 = 0

    // Media
    private var videoSequenceHeader: Data?
    private var audioSequenceHeader: Data?
    private var timeBase: Double?
    private var lastVideoTimestamp: UInt32 = 0
    private var lastAudioTimestamp: UInt32 = 0
    private var waitingForKeyFrame = true

    // Flow control and statistics
    private var bytesInFlight = 0
    private var stats = Statistics()
    private var lastStatsBytes: UInt64 = 0
    private var lastStatsTime = ContinuousClock.now
    private var statsTimer: DispatchSourceTimer?

    public init() {}

    deinit {
        statsTimer?.cancel()
        connection?.cancel()
    }

    // MARK: - Public API

    public func connect(_ configuration: Configuration) {
        queue.async { [self] in
            self.configuration = configuration
            userRequestedStop = false
            reconnectAttempts = 0
            stats = Statistics()
            lastStatsBytes = 0
            openConnection()
            startStatsTimer()
        }
    }

    public func disconnect() {
        queue.async { [self] in
            userRequestedStop = true
            closeConnection(sendingUnpublish: phase == .live)
            statsTimer?.cancel()
            statsTimer = nil
            setStatus(.idle)
        }
    }

    /// `avcC` / `hvcC` decoder configuration record from the encoder.
    public func setVideoSequenceHeader(_ configurationRecord: Data) {
        queue.async { [self] in
            let format = configuration?.videoFormat ?? .avc
            let tag = FLVTag.videoSequenceHeader(format: format, configurationRecord: configurationRecord)
            let changed = videoSequenceHeader != tag
            videoSequenceHeader = tag
            if phase == .live, changed {
                sendMessage(type: .video, csid: RTMPChunkStream.video, timestamp: lastVideoTimestamp, payload: tag)
            }
        }
    }

    public func setAudioSequenceHeader(_ audioSpecificConfig: Data) {
        queue.async { [self] in
            let tag = FLVTag.makeAACSequenceHeader(config: audioSpecificConfig)
            audioSequenceHeader = tag
            if phase == .live {
                sendMessage(type: .audio, csid: RTMPChunkStream.audio, timestamp: lastAudioTimestamp, payload: tag)
            }
        }
    }

    /// Sends one encoded access unit. `pts`/`dts` are host-clock seconds.
    public func sendVideo(accessUnit: Data, pts: Double, dts: Double, isKeyFrame: Bool) {
        queue.async { [self] in
            guard phase == .live, let configuration else { return }

            if waitingForKeyFrame && !isKeyFrame {
                stats.droppedVideoFrames += 1
                return
            }
            if bytesInFlight > dropThreshold, !isKeyFrame {
                // Socket can't keep up: skip until the next IDR so the decoder never sees a broken GOP.
                stats.droppedVideoFrames += 1
                if !waitingForKeyFrame {
                    waitingForKeyFrame = true
                    onKeyFrameRequest?()
                }
                return
            }
            waitingForKeyFrame = false

            let timestamp = mediaTimestamp(for: dts, last: &lastVideoTimestamp)
            let composition = Int32(((pts - dts) * 1000).rounded())
            let tag = FLVTag.videoFrame(format: configuration.videoFormat, accessUnit: accessUnit,
                                        isKeyFrame: isKeyFrame, compositionTimeMs: composition)
            sendMessage(type: .video, csid: RTMPChunkStream.video, timestamp: timestamp, payload: tag)
            stats.sentVideoFrames += 1
        }
    }

    public func sendAudio(aacPacket: Data, pts: Double) {
        queue.async { [self] in
            guard phase == .live else { return }
            // Audio is tiny; only shed it when the socket is hopelessly behind.
            guard bytesInFlight < dropThreshold * 4 else { return }
            let timestamp = mediaTimestamp(for: pts, last: &lastAudioTimestamp)
            sendMessage(type: .audio, csid: RTMPChunkStream.audio, timestamp: timestamp,
                        payload: FLVTag.makeAACPacket(aacData: aacPacket))
        }
    }

    // MARK: - Connection lifecycle

    private var dropThreshold: Int {
        let bitrate = configuration?.videoBitrate ?? 4_500_000
        // About two seconds of video may sit in the send buffer before we start dropping.
        return max(512 * 1024, bitrate / 8 * 2)
    }

    private func openConnection() {
        guard let configuration else { return }
        closeConnection(sendingUnpublish: false)

        generation += 1
        let currentGeneration = generation
        phase = .handshaking
        reader = RTMPChunkReader()
        handshakeBuffer = Data()
        bytesInFlight = 0
        bytesReceived = 0
        lastAcknowledged = 0
        nextTransactionID = 1
        timeBase = nil
        lastVideoTimestamp = 0
        lastAudioTimestamp = 0
        waitingForKeyFrame = true
        setStatus(reconnectAttempts > 0 ? .reconnecting : .connecting)

        let endpoint = configuration.endpoint
        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else {
            fail("Invalid port \(endpoint.port)")
            return
        }

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        let parameters = endpoint.isSecure ? NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp) : NWParameters(tls: nil, tcp: tcp)
        parameters.serviceClass = .responsiveData

        let connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            self?.handleState(state, generation: currentGeneration)
        }
        connection.start(queue: queue)
    }

    private func closeConnection(sendingUnpublish: Bool) {
        guard let connection else { return }
        generation += 1
        if sendingUnpublish {
            sendUnpublish()
            // Let the unpublish commands flush before tearing the socket down.
            connection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
        } else {
            connection.cancel()
        }
        self.connection = nil
        phase = .idle
    }

    private func handleState(_ state: NWConnection.State, generation: Int) {
        guard generation == self.generation else { return }
        switch state {
        case .ready:
            startHandshake()
        case .waiting(let error):
            connectionLost("Network unavailable: \(error.localizedDescription)")
        case .failed(let error):
            connectionLost("Connection failed: \(error.localizedDescription)")
        default:
            break
        }
    }

    private func connectionLost(_ reason: String) {
        guard !userRequestedStop else { return }
        closeConnection(sendingUnpublish: false)

        guard let configuration, configuration.autoReconnect,
              reconnectAttempts < configuration.maxReconnectAttempts else {
            fail(reason)
            return
        }

        reconnectAttempts += 1
        setStatus(.reconnecting)
        let delay = configuration.reconnectDelay
        let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
        queue.asyncAfter(deadline: .now() + seconds * Double(reconnectAttempts)) { [weak self] in
            guard let self, !self.userRequestedStop else { return }
            self.openConnection()
        }
    }

    private func fail(_ message: String) {
        closeConnection(sendingUnpublish: false)
        statsTimer?.cancel()
        statsTimer = nil
        setStatus(.error(message))
    }

    private func setStatus(_ status: StreamStatus) {
        onEvent?(.status(status))
    }

    // MARK: - Handshake (RTMP spec §5.2)

    private func startHandshake() {
        var c0c1 = Data([0x03])
        c0c1.append(contentsOf: [UInt8](repeating: 0, count: 8)) // time + zero
        var random = [UInt8](repeating: 0, count: 1528)
        for index in random.indices {
            random[index] = UInt8.random(in: .min ... .max)
        }
        c0c1.append(contentsOf: random)
        sendRaw(c0c1)
        receiveLoop(generation: generation)
    }

    private func receiveLoop(generation: Int) {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] content, _, isComplete, error in
            guard let self, generation == self.generation else { return }
            if let content, !content.isEmpty {
                self.handleIncoming(content)
            }
            if let error {
                self.connectionLost("Connection error: \(error.localizedDescription)")
            } else if isComplete {
                self.connectionLost("Server closed the connection")
            } else {
                self.receiveLoop(generation: generation)
            }
        }
    }

    private func handleIncoming(_ data: Data) {
        bytesReceived += UInt64(data.count)
        sendAcknowledgementIfNeeded()

        guard phase != .handshaking else {
            handshakeBuffer.append(data)
            // S0 (1) + S1 (1536) + S2 (1536)
            guard handshakeBuffer.count >= 3073 else { return }
            guard handshakeBuffer[handshakeBuffer.startIndex] == 0x03 else {
                fail("Unsupported RTMP server version")
                return
            }
            let s1 = handshakeBuffer.subdata(in: 1..<1537)
            let leftover = handshakeBuffer.count > 3073 ? handshakeBuffer.subdata(in: 3073..<handshakeBuffer.count) : Data()
            handshakeBuffer = Data()
            sendRaw(s1) // C2 echoes S1
            beginSession()
            if !leftover.isEmpty {
                handleMessages(reader.append(leftover))
            }
            return
        }

        handleMessages(reader.append(data))
    }

    // MARK: - Commands

    private func beginSession() {
        guard let configuration else { return }
        phase = .connecting

        var chunkSize = Data()
        withUnsafeBytes(of: UInt32(outgoingChunkSize).bigEndian) { chunkSize.append(contentsOf: $0) }
        sendMessage(type: .setChunkSize, csid: RTMPChunkStream.control, timestamp: 0, payload: chunkSize, chunkSizeOverride: 128)

        connectTransactionID = takeTransactionID()
        let endpoint = configuration.endpoint
        let command: [AMF0Value] = [
            .string("connect"),
            .number(connectTransactionID),
            .object([
                AMF0Property("app", .string(endpoint.app)),
                AMF0Property("type", .string("nonprivate")),
                AMF0Property("flashVer", .string("FMLE/3.0 (compatible; Streamio)")),
                AMF0Property("swfUrl", .string(endpoint.tcUrl)),
                AMF0Property("tcUrl", .string(endpoint.tcUrl)),
                // Enhanced RTMP capability advertisement (HEVC support).
                AMF0Property("fourCcList", .strictArray([.string("avc1"), .string("hvc1")]))
            ])
        ]
        sendCommand(command, streamID: 0)
    }

    private func handleMessages(_ messages: [RTMPMessage]) {
        for message in messages {
            switch message.type {
            case .windowAckSize:
                if let size = message.leadingUInt32 { serverWindowAckSize = size }
            case .setPeerBandwidth:
                if let size = message.leadingUInt32 {
                    var payload = Data()
                    withUnsafeBytes(of: size.bigEndian) { payload.append(contentsOf: $0) }
                    sendMessage(type: .windowAckSize, csid: RTMPChunkStream.control, timestamp: 0, payload: payload)
                }
            case .userControl:
                handleUserControl(message.payload)
            case .commandAMF0:
                handleCommand(AMF0.decodeAll(message.payload))
            case .commandAMF3:
                // AMF3 command messages carry a leading format byte, then AMF0 data.
                handleCommand(AMF0.decodeAll(message.payload.dropFirst()))
            default:
                break
            }
        }
    }

    private func handleUserControl(_ payload: Data) {
        guard payload.count >= 6 else { return }
        let event = UInt16(payload[payload.startIndex]) << 8 | UInt16(payload[payload.startIndex + 1])
        if event == 6 { // PingRequest → PingResponse with the same timestamp
            var response = Data([0x00, 0x07])
            response.append(payload[(payload.startIndex + 2)..<(payload.startIndex + 6)])
            sendMessage(type: .userControl, csid: RTMPChunkStream.control, timestamp: 0, payload: response)
        }
    }

    private func handleCommand(_ values: [AMF0Value]) {
        guard let name = values.first?.stringValue else { return }
        let transactionID = values.count > 1 ? values[1].numberValue ?? 0 : 0

        switch name {
        case "_result":
            if transactionID == connectTransactionID, phase == .connecting {
                startPublishFlow()
            } else if transactionID == createStreamTransactionID, phase == .creatingStream {
                if values.count > 3, let id = values[3].numberValue {
                    messageStreamID = UInt32(id)
                }
                sendPublish()
            }

        case "_error":
            if transactionID == connectTransactionID || transactionID == createStreamTransactionID {
                let description = values.dropFirst(2).compactMap { $0["description"]?.stringValue }.first
                fail(description.map { "Server rejected the stream: \($0)" } ?? "Server rejected the connection")
            }

        case "onStatus":
            let info = values.dropFirst(2).first { $0["code"] != nil }
            let code = info?["code"]?.stringValue ?? ""
            if code == "NetStream.Publish.Start" {
                goLive()
            } else if code.contains("BadName") || code.contains("Failed") || code.contains("Rejected") || code.contains("Unauthorized") {
                let description = info?["description"]?.stringValue ?? code
                fail("Publish refused: \(description)")
            }

        default:
            break
        }
    }

    private func startPublishFlow() {
        guard let configuration else { return }
        let key = AMF0Value.string(configuration.streamKey)
        sendCommand([.string("releaseStream"), .number(takeTransactionID()), .null, key], streamID: 0)
        sendCommand([.string("FCPublish"), .number(takeTransactionID()), .null, key], streamID: 0)
        createStreamTransactionID = takeTransactionID()
        sendCommand([.string("createStream"), .number(createStreamTransactionID), .null], streamID: 0)
        phase = .creatingStream
    }

    private func sendPublish() {
        guard let configuration else { return }
        phase = .publishing
        sendCommand([.string("publish"), .number(0), .null, .string(configuration.streamKey), .string("live")],
                    streamID: messageStreamID)

        // Some ingest servers never send NetStream.Publish.Start; don't wait forever.
        let currentGeneration = generation
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.generation == currentGeneration, self.phase == .publishing else { return }
            self.goLive()
        }
    }

    private func goLive() {
        guard phase == .publishing, let configuration else { return }
        phase = .live
        reconnectAttempts = 0

        let metadata: [AMF0Value] = [
            .string("@setDataFrame"),
            .string("onMetaData"),
            .ecmaArray([
                AMF0Property("duration", .number(0)),
                AMF0Property("width", .number(Double(configuration.width))),
                AMF0Property("height", .number(Double(configuration.height))),
                AMF0Property("videocodecid", .number(configuration.videoFormat.metadataCodecID)),
                AMF0Property("videodatarate", .number(Double(configuration.videoBitrate) / 1000)),
                AMF0Property("framerate", .number(Double(configuration.fps))),
                AMF0Property("audiocodecid", .number(10)),
                AMF0Property("audiodatarate", .number(Double(configuration.audioBitrate) / 1000)),
                AMF0Property("audiosamplerate", .number(configuration.audioSampleRate)),
                AMF0Property("audiosamplesize", .number(16)),
                AMF0Property("stereo", .boolean(true)),
                AMF0Property("encoder", .string("Streamio"))
            ])
        ]
        sendMessage(type: .dataAMF0, csid: RTMPChunkStream.data, timestamp: 0, payload: AMF0.encode(metadata))

        if let videoSequenceHeader {
            sendMessage(type: .video, csid: RTMPChunkStream.video, timestamp: 0, payload: videoSequenceHeader)
        }
        if let audioSequenceHeader {
            sendMessage(type: .audio, csid: RTMPChunkStream.audio, timestamp: 0, payload: audioSequenceHeader)
        }
        waitingForKeyFrame = true
        onKeyFrameRequest?()
        setStatus(.streaming)
    }

    private func sendUnpublish() {
        guard let configuration else { return }
        sendMessage(type: .video, csid: RTMPChunkStream.video, timestamp: lastVideoTimestamp,
                    payload: FLVTag.videoEndOfSequence(format: configuration.videoFormat))
        sendCommand([.string("FCUnpublish"), .number(takeTransactionID()), .null, .string(configuration.streamKey)], streamID: 0)
        sendCommand([.string("deleteStream"), .number(takeTransactionID()), .null, .number(Double(messageStreamID))], streamID: 0)
    }

    private func takeTransactionID() -> Double {
        defer { nextTransactionID += 1 }
        return nextTransactionID
    }

    // MARK: - Sending

    private func sendCommand(_ values: [AMF0Value], streamID: UInt32) {
        sendMessage(type: .commandAMF0, csid: RTMPChunkStream.command, timestamp: 0, payload: AMF0.encode(values), streamID: streamID)
    }

    private func sendMessage(type: RTMPMessageType, csid: UInt32, timestamp: UInt32, payload: Data,
                             streamID: UInt32? = nil, chunkSizeOverride: Int? = nil) {
        let isMedia = type == .audio || type == .video || type == .dataAMF0
        let chunk = RTMPChunker.chunkMessage(
            csid: csid,
            typeId: type.rawValue,
            streamId: streamID ?? (isMedia ? messageStreamID : 0),
            timestamp: timestamp,
            payload: payload,
            chunkSize: chunkSizeOverride ?? outgoingChunkSize
        )
        sendRaw(chunk)
    }

    private func sendRaw(_ data: Data) {
        guard let connection else { return }
        let count = data.count
        let currentGeneration = generation
        bytesInFlight += count
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, currentGeneration == self.generation else { return }
            self.bytesInFlight -= count
            if let error {
                self.connectionLost("Send failed: \(error.localizedDescription)")
            } else {
                self.stats.bytesSent += UInt64(count)
            }
        })
    }

    private func sendAcknowledgementIfNeeded() {
        guard phase != .handshaking, bytesReceived - lastAcknowledged >= UInt64(serverWindowAckSize) else { return }
        lastAcknowledged = bytesReceived
        var payload = Data()
        withUnsafeBytes(of: UInt32(truncatingIfNeeded: bytesReceived).bigEndian) { payload.append(contentsOf: $0) }
        sendMessage(type: .acknowledgement, csid: RTMPChunkStream.control, timestamp: 0, payload: payload)
    }

    /// Converts a host-clock time to a monotonic stream timestamp in milliseconds.
    private func mediaTimestamp(for seconds: Double, last: inout UInt32) -> UInt32 {
        if timeBase == nil { timeBase = seconds }
        let elapsed = max(0, seconds - (timeBase ?? seconds))
        let value = max(last, UInt32(min(elapsed * 1000, Double(UInt32.max))))
        last = value
        return value
    }

    // MARK: - Statistics

    private func startStatsTimer() {
        statsTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            self?.publishStatistics()
        }
        timer.resume()
        statsTimer = timer
    }

    private func publishStatistics() {
        let now = ContinuousClock.now
        let elapsed = now - lastStatsTime
        let seconds = max(0.001, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
        let delta = stats.bytesSent - lastStatsBytes
        stats.bitrateKbps = Double(delta) * 8 / seconds / 1000
        stats.congestion = min(1, Double(bytesInFlight) / Double(dropThreshold))
        lastStatsBytes = stats.bytesSent
        lastStatsTime = now
        onEvent?(.statistics(stats))
    }
}
