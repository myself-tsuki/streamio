//
//  RTMPClient.swift
//  Streamio
//

import Foundation
import Network
import CoreMedia

public protocol RTMPClientDelegate: AnyObject {
    func rtmpClientDidChangeStatus(_ client: RTMPClient, status: StreamStatus)
    func rtmpClientDidUpdateStatistics(_ client: RTMPClient, bytesSent: UInt64, bitrateKbps: Double, droppedFrames: Int)
}

public final class RTMPClient: @unchecked Sendable {
    public weak var delegate: RTMPClientDelegate?

    public private(set) var status: StreamStatus = .idle {
        didSet {
            delegate?.rtmpClientDidChangeStatus(self, status: status)
        }
    }

    private var connection: NWConnection?
    private let networkQueue = DispatchQueue(label: "com.streamio.rtmpclient", qos: .userInitiated)

    // Stream parameters
    private var rtmpUrlString: String = "rtmp://a.rtmp.youtube.com/live2"
    private var streamKey: String = ""
    private var appName: String = "live2"
    private var host: String = "a.rtmp.youtube.com"
    private var port: UInt16 = 1935
    private var isSecure: Bool = false

    private var videoWidth: Int32 = 1920
    private var videoHeight: Int32 = 1080
    private var videoBitrate: Int = 4_500_000
    private var audioBitrate: Int = 128_000
    private var fps: Int = 30

    // RTMP Protocol State
    private var chunkSize: Int = 4096
    private var messageStreamId: UInt32 = 1
    private var currentTransactionId: Double = 1.0

    // Time tracking
    private var startTime: CMTime = .invalid
    private var hasPublished = false

    // Cached headers
    private var cachedAVCSequenceHeader: Data?
    private var cachedAACSequenceHeader: Data?

    // Statistics
    private var totalBytesSent: UInt64 = 0
    private var lastStatsBytes: UInt64 = 0
    private var lastStatsDate = Date()
    private var droppedFramesCount = 0
    private var statsTimer: Timer?

    public init() {}

    deinit {
        disconnect()
    }

    public func configure(
        rtmpUrl: String,
        streamKey: String,
        width: Int32,
        height: Int32,
        videoBitrate: Int,
        audioBitrate: Int,
        fps: Int
    ) {
        self.rtmpUrlString = rtmpUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        self.streamKey = streamKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.videoWidth = width
        self.videoHeight = height
        self.videoBitrate = videoBitrate
        self.audioBitrate = audioBitrate
        self.fps = fps

        parseUrl()
    }

    private func parseUrl() {
        guard let url = URL(string: rtmpUrlString) else { return }
        self.host = url.host ?? "a.rtmp.youtube.com"
        self.isSecure = (url.scheme?.lowercased() == "rtmps")
        self.port = UInt16(url.port ?? (isSecure ? 443 : 1935))

        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.appName = path.isEmpty ? "live2" : path
    }

    public func connect() {
        networkQueue.async { [weak self] in
            guard let self = self else { return }
            self.disconnectInternal()

            self.status = .connecting
            self.totalBytesSent = 0
            self.lastStatsBytes = 0
            self.droppedFramesCount = 0
            self.startTime = .invalid
            self.hasPublished = false
            self.currentTransactionId = 1.0

            let hostEndpoint = NWEndpoint.Host(self.host)
            guard let portEndpoint = NWEndpoint.Port(rawValue: self.port) else {
                self.status = .error("Invalid port: \(self.port)")
                return
            }

            let parameters: NWParameters
            if self.isSecure {
                parameters = .tls
            } else {
                parameters = .tcp
            }
            parameters.allowFastOpen = true

            let conn = NWConnection(host: hostEndpoint, port: portEndpoint, using: parameters)
            self.connection = conn

            conn.stateUpdateHandler = { [weak self] state in
                self?.handleStateUpdate(state)
            }

            conn.start(queue: self.networkQueue)
            self.startStatsTimer()
        }
    }

    private func handleStateUpdate(_ state: NWConnection.State) {
        switch state {
        case .ready:
            sendHandshake()
        case .failed(let error):
            self.status = .error("Connection failed: \(error.localizedDescription)")
            self.disconnect()
        case .cancelled:
            if self.status != .idle {
                self.status = .idle
            }
        default:
            break
        }
    }

    // MARK: - RTMP Handshake
    private func sendHandshake() {
        var c0c1 = Data()
        c0c1.append(0x03) // C0: RTMP version 3

        // C1: 1536 bytes
        var timeBytes: UInt32 = 0
        c0c1.append(Data(bytes: &timeBytes, count: 4)) // 4 bytes timestamp (0)
        var zeroBytes: UInt32 = 0
        c0c1.append(Data(bytes: &zeroBytes, count: 4)) // 4 bytes zero

        // 1528 random bytes
        var randomBytes = [UInt8](repeating: 0, count: 1528)
        _ = SecRandomCopyBytes(kSecRandomDefault, 1528, &randomBytes)
        c0c1.append(contentsOf: randomBytes)

        sendRaw(c0c1)

        // Read S0 + S1 + S2 (1 + 1536 + 1536 = 3073 bytes)
        receiveExact(count: 3073) { [weak self] data in
            guard let self = self, let sData = data, sData.count == 3073 else {
                self?.status = .error("Handshake failed to receive S0-S2")
                return
            }

            // Verify S0
            guard sData[0] == 0x03 else {
                self.status = .error("Unsupported RTMP server version")
                return
            }

            // S1 is from byte 1..<1537
            let s1 = sData.subdata(in: 1..<1537)
            // Send C2 = echo of S1
            self.sendRaw(s1)

            // Handshake complete, send connect command
            self.startRTMPConnectSession()
        }
    }

    private func startRTMPConnectSession() {
        // 1. Set Chunk Size to 4096
        sendSetChunkSize(4096)

        // 2. Send 'connect' command (AMF0)
        sendConnectCommand()

        // 3. Listen for responses
        listenForServerMessages()
    }

    private func sendSetChunkSize(_ size: UInt32) {
        self.chunkSize = Int(size)
        var payload = Data()
        var sizeBE = size.bigEndian
        payload.append(Data(bytes: &sizeBE, count: 4))

        let chunk = RTMPChunker.chunkMessage(
            csid: 2,
            typeId: 1, // Set Chunk Size
            streamId: 0,
            timestamp: 0,
            payload: payload,
            chunkSize: chunkSize
        )
        sendRaw(chunk)
    }

    private func sendConnectCommand() {
        var amfPayload = Data()

        // Command name
        AMF0.encode(.string("connect"), into: &amfPayload)
        // Transaction ID
        currentTransactionId = 1.0
        AMF0.encode(.number(currentTransactionId), into: &amfPayload)

        let tcUrl = "\(isSecure ? "rtmps" : "rtmp")://\(host):\(port)/\(appName)"

        // Command Object
        let cmdObj: [String: AMF0Value] = [
            "app": .string(appName),
            "flashVer": .string("FMLE/3.0 (compatible; FMSc/1.0)"),
            "tcUrl": .string(tcUrl),
            "fpad": .boolean(false),
            "capabilities": .number(15.0),
            "audioCodecs": .number(3191.0),
            "videoCodecs": .number(252.0),
            "videoFunction": .number(1.0)
        ]
        AMF0.encode(.object(cmdObj), into: &amfPayload)

        let chunk = RTMPChunker.chunkMessage(
            csid: 3,
            typeId: 20, // AMF0 Command
            streamId: 0,
            timestamp: 0,
            payload: amfPayload,
            chunkSize: chunkSize
        )
        sendRaw(chunk)

        // Also send FMLE-style releaseStream and FCPublish (required by YouTube RTMP ingest)
        sendReleaseStream()
        sendFCPublish()
        sendCreateStream()
    }

    private func sendReleaseStream() {
        var amf = Data()
        AMF0.encode(.string("releaseStream"), into: &amf)
        currentTransactionId += 1
        AMF0.encode(.number(currentTransactionId), into: &amf)
        AMF0.encode(.null, into: &amf)
        AMF0.encode(.string(streamKey), into: &amf)

        let chunk = RTMPChunker.chunkMessage(
            csid: 3,
            typeId: 20,
            streamId: 0,
            timestamp: 0,
            payload: amf,
            chunkSize: chunkSize
        )
        sendRaw(chunk)
    }

    private func sendFCPublish() {
        var amf = Data()
        AMF0.encode(.string("FCPublish"), into: &amf)
        currentTransactionId += 1
        AMF0.encode(.number(currentTransactionId), into: &amf)
        AMF0.encode(.null, into: &amf)
        AMF0.encode(.string(streamKey), into: &amf)

        let chunk = RTMPChunker.chunkMessage(
            csid: 3,
            typeId: 20,
            streamId: 0,
            timestamp: 0,
            payload: amf,
            chunkSize: chunkSize
        )
        sendRaw(chunk)
    }

    private func sendCreateStream() {
        var amf = Data()
        AMF0.encode(.string("createStream"), into: &amf)
        currentTransactionId += 1
        AMF0.encode(.number(currentTransactionId), into: &amf)
        AMF0.encode(.null, into: &amf)

        let chunk = RTMPChunker.chunkMessage(
            csid: 3,
            typeId: 20,
            streamId: 0,
            timestamp: 0,
            payload: amf,
            chunkSize: chunkSize
        )
        sendRaw(chunk)
    }

    private func sendPublish() {
        var amf = Data()
        AMF0.encode(.string("publish"), into: &amf)
        currentTransactionId += 1
        AMF0.encode(.number(0.0), into: &amf)
        AMF0.encode(.null, into: &amf)
        AMF0.encode(.string(streamKey), into: &amf)
        AMF0.encode(.string("live"), into: &amf)

        let chunk = RTMPChunker.chunkMessage(
            csid: 3,
            typeId: 20,
            streamId: messageStreamId,
            timestamp: 0,
            payload: amf,
            chunkSize: chunkSize
        )
        sendRaw(chunk)

        sendMetaData()

        self.hasPublished = true
        self.status = .streaming

        // Send cached sequence headers if already available
        if let avcHeader = cachedAVCSequenceHeader {
            sendVideoData(avcHeader, timestampMs: 0)
        }
        if let aacHeader = cachedAACSequenceHeader {
            sendAudioData(aacHeader, timestampMs: 0)
        }
    }

    private func sendMetaData() {
        var amf = Data()
        AMF0.encode(.string("@setDataFrame"), into: &amf)
        AMF0.encode(.string("onMetaData"), into: &amf)

        let metaObj: [String: AMF0Value] = [
            "duration": .number(0),
            "width": .number(Double(videoWidth)),
            "height": .number(Double(videoHeight)),
            "videocodecid": .number(7.0), // AVC
            "videodatarate": .number(Double(videoBitrate) / 1000.0),
            "framerate": .number(Double(fps)),
            "audiocodecid": .number(10.0), // AAC
            "audiodatarate": .number(Double(audioBitrate) / 1000.0),
            "audiosamplerate": .number(44100.0),
            "audiosamplesize": .number(16.0),
            "stereo": .boolean(true)
        ]
        AMF0.encode(.ecmaArray(metaObj), into: &amf)

        let chunk = RTMPChunker.chunkMessage(
            csid: 4,
            typeId: 18, // AMF0 Data
            streamId: messageStreamId,
            timestamp: 0,
            payload: amf,
            chunkSize: chunkSize
        )
        sendRaw(chunk)
    }

    // MARK: - Media Ingestion
    public func setAVCSequenceHeader(sps: Data, pps: Data) {
        let tag = FLVTag.makeAVCSequenceHeader(sps: sps, pps: pps)
        self.cachedAVCSequenceHeader = tag
        if hasPublished {
            sendVideoData(tag, timestampMs: 0)
        }
    }

    public func setAACSequenceHeader(config: Data) {
        let tag = FLVTag.makeAACSequenceHeader(config: config)
        self.cachedAACSequenceHeader = tag
        if hasPublished {
            sendAudioData(tag, timestampMs: 0)
        }
    }

    public func sendVideoSample(nalu: Data, pts: CMTime, isKeyFrame: Bool) {
        guard hasPublished else { return }

        if !startTime.isValid {
            startTime = pts
        }

        let elapsedSeconds = CMTimeGetSeconds(CMTimeSubtract(pts, startTime))
        let timestampMs = UInt32(max(0.0, elapsedSeconds) * 1000.0)

        let flvPacket = FLVTag.makeAVCPacket(naluData: nalu, isKeyFrame: isKeyFrame, compositionTimeMs: 0)
        sendVideoData(flvPacket, timestampMs: timestampMs)
    }

    public func sendAudioSample(aacData: Data, pts: CMTime) {
        guard hasPublished else { return }

        if !startTime.isValid {
            startTime = pts
        }

        let elapsedSeconds = CMTimeGetSeconds(CMTimeSubtract(pts, startTime))
        let timestampMs = UInt32(max(0.0, elapsedSeconds) * 1000.0)

        let flvPacket = FLVTag.makeAACPacket(aacData: aacData)
        sendAudioData(flvPacket, timestampMs: timestampMs)
    }

    private func sendVideoData(_ payload: Data, timestampMs: UInt32) {
        let chunk = RTMPChunker.chunkMessage(
            csid: 6,
            typeId: 9, // Video Message
            streamId: messageStreamId,
            timestamp: timestampMs,
            payload: payload,
            chunkSize: chunkSize
        )
        sendRaw(chunk)
    }

    private func sendAudioData(_ payload: Data, timestampMs: UInt32) {
        let chunk = RTMPChunker.chunkMessage(
            csid: 4,
            typeId: 8, // Audio Message
            streamId: messageStreamId,
            timestamp: timestampMs,
            payload: payload,
            chunkSize: chunkSize
        )
        sendRaw(chunk)
    }

    // MARK: - Incoming Message Loop
    private func listenForServerMessages() {
        guard let conn = connection else { return }

        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }

            if let data = content, !data.isEmpty {
                self.parseIncomingRTMPData(data)
            }

            if isComplete {
                self.disconnect()
            } else if error == nil {
                self.listenForServerMessages()
            }
        }
    }

    private func parseIncomingRTMPData(_ data: Data) {
        // Inspect for _result, onStatus, NetStream.Publish.Start
        var offset = 0
        while offset < data.count {
            if let str = AMF0.decode(data: data, offset: &offset) {
                if case .string(let cmdName) = str {
                    if cmdName == "_result" {
                        // Response to createStream or connect
                        if !self.hasPublished {
                            self.sendPublish()
                        }
                    } else if cmdName == "onStatus" {
                        // Stream status
                        if !self.hasPublished {
                            self.sendPublish()
                        }
                    }
                }
            } else {
                offset += 1
            }
        }
    }

    // MARK: - Raw Network Helpers
    private func sendRaw(_ data: Data) {
        guard let conn = connection else {
            droppedFramesCount += 1
            return
        }

        conn.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                print("RTMP send error: \(error)")
                self?.droppedFramesCount += 1
            } else {
                self?.totalBytesSent += UInt64(data.count)
            }
        })
    }

    private func receiveExact(count: Int, completion: @escaping (Data?) -> Void) {
        guard let conn = connection else {
            completion(nil)
            return
        }

        conn.receive(minimumIncompleteLength: count, maximumLength: count) { content, _, isComplete, error in
            if let error = error {
                print("RTMP receive error: \(error)")
                completion(nil)
            } else {
                completion(content)
            }
        }
    }

    private func startStatsTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                let now = Date()
                let interval = now.timeIntervalSince(self.lastStatsDate)
                let bytesDiff = self.totalBytesSent - self.lastStatsBytes
                let bitrateKbps = (Double(bytesDiff) * 8.0) / (interval * 1000.0)

                self.lastStatsDate = now
                self.lastStatsBytes = self.totalBytesSent

                self.delegate?.rtmpClientDidUpdateStatistics(
                    self,
                    bytesSent: self.totalBytesSent,
                    bitrateKbps: max(0.0, bitrateKbps),
                    droppedFrames: self.droppedFramesCount
                )
            }
        }
    }

    public func disconnect() {
        networkQueue.async { [weak self] in
            self?.disconnectInternal()
        }
    }

    private func disconnectInternal() {
        statsTimer?.invalidate()
        statsTimer = nil
        connection?.cancel()
        connection = nil
        hasPublished = false
        status = .idle
    }
}

