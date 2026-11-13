//
//  MediaPipeline.swift
//  Streamio
//
//  Wires capture → canvas compositor → preview / encoder → RTMP outputs + recorder,
//  and microphone + desktop audio → mixer → AAC → RTMP outputs + recorder (+ monitoring).
//  Runs entirely off the main actor; the UI talks to it through `StudioController`.
//
//  Video is clock-driven, like OBS: sources only drop their newest frame into a slot, and a
//  timer at the canvas frame rate composes whatever is current. A late or slow USB camera
//  therefore repeats its last frame instead of flashing black, and the encoder always gets
//  evenly spaced, monotonic timestamps.
//
//  One video encoder and one audio encoder feed every RTMP destination and the recorder,
//  so streaming to several services at once never encodes twice.
//

import AVFoundation
import CoreMedia
import Foundation

nonisolated final class MediaPipeline: @unchecked Sendable {
    /// Which capture slot a layer reads from.
    enum Input: Hashable, Sendable {
        case camera
        case display
        case image(String)
        /// A second (third…) camera by unique ID, shown as an overlay.
        case extraCamera(String)
        case video(String)
    }

    struct Layer: Equatable, Sendable {
        var input: Input
        var layout: SourceLayout
        var pipScale: Double
        var isMirrored: Bool
        var opacity: Float
        var filter: FilterType
        var params: FilterParameters
        var shape: SourceShape = .rectangle
        var borderWidth: Double = 0
        var borderColor: SourceColor = .white
        var offsetX: Double = 0
        var offsetY: Double = 0
    }

    struct VideoState: Equatable, Sendable {
        var canvasWidth = 1920
        var canvasHeight = 1080
        var fps = 30
        /// Visible layers, bottom first.
        var layers: [Layer] = []
    }

    struct FrameReport: Sendable {
        var outputFPS: Double
        var cameraFPS: Double
        var skippedFrames: Int
        var renderMilliseconds: Double
    }

    enum Event: Sendable {
        case stream(UUID, StreamStatus)
        case network(UUID, RTMPClient.Statistics)
        case recording(StreamRecorder.Event)
        case frames(FrameReport)
        case levels([AudioChannelID: AudioLevels])
        case captureError(String)
    }

    var onEvent: (@Sendable (Event) -> Void)?

    let preview = PreviewFrameStore()
    let mixer = AudioMixer()
    let monitor: AudioMonitor
    let camera = CaptureSessionController()
    let screen = ScreenCaptureController()
    let extraCameras = ExtraCameraCapture()
    private var videoPlayers: [String: VideoFilePlayer] = [:]
    private let videoEncoder = VideoEncoder()
    private let audioEncoder: AudioEncoder
    private let recorder = StreamRecorder()

    private struct SourceFrame {
        var buffer: CVPixelBuffer
        var arrival: Double
    }

    private let lock = NSLock()
    private var video = VideoState()
    private var clients: [UUID: RTMPClient] = [:]
    private var isRecording = false
    private var frames: [Input: SourceFrame] = [:]
    private var images: [String: CVPixelBuffer] = [:]
    private var loadingImages: Set<String> = []
    private var videoSequenceHeader: Data?
    private var audioSequenceHeader: Data?

    // Statistics (guarded by `lock`)
    private var renderedThisWindow = 0
    private var cameraFramesThisWindow = 0
    private var renderTimeThisWindow: Double = 0
    private var windowStart: Double = 0

    /// A display that stops delivering keeps its last frame on screen this long (OBS behaviour),
    /// then its layer is dropped.
    private let holdLastFrameSeconds: Double = 5
    /// A camera that stops delivering (loose cable) freezes for this long, then the "No signal"
    /// card takes over. Streaming and recording carry on underneath.
    private let cameraHoldSeconds: Double = 1.5
    /// With no frame at all (just switched, or unplugged before it ever delivered) wait this long
    /// before showing the card, so a normal camera start-up does not flash it.
    private let cameraStartGraceSeconds: Double = 2.5
    // Touched only from the clock queue.
    private var cameraMissingSince: Double?
    private lazy var signalSlate: CVPixelBuffer? = SignalSlate.makePixelBuffer()

    private let clockQueue = DispatchQueue(label: "com.streamio.canvas.clock", qos: .userInteractive)
    private let imageQueue = DispatchQueue(label: "com.streamio.canvas.images", qos: .utility)
    private var clock: DispatchSourceTimer?
    private var clockFPS = 0

    init() {
        audioEncoder = AudioEncoder(inputFormat: mixer.outputFormat)
        monitor = AudioMonitor(format: mixer.outputFormat)
        mixer.monitor = monitor
        monitor.onError = { [weak self] message in self?.onEvent?(.captureError(message)) }

        camera.onVideo = { [weak self] sample in self?.ingestVideo(sample, into: .camera) }
        camera.onAudio = { [weak self] sample in self?.mixer.ingest(sample, from: .microphone) }
        camera.onError = { [weak self] message in self?.onEvent?(.captureError(message)) }
        extraCameras.onVideo = { [weak self] id, sample in self?.ingestVideo(sample, into: .extraCamera(id)) }
        extraCameras.onError = { [weak self] message in self?.onEvent?(.captureError(message)) }
        screen.onVideo = { [weak self] sample in self?.ingestVideo(sample, into: .display) }
        screen.onAudio = { [weak self] sample in self?.mixer.ingest(sample, from: .desktop) }
        screen.onStop = { [weak self] message in
            self?.mixer.reset(.desktop)
            self?.clearFrame(.display)
            if let message { self?.onEvent?(.captureError(message)) }
        }

        mixer.onLevels = { [weak self] levels in self?.onEvent?(.levels(levels)) }
        mixer.onMixedAudio = { [weak self] buffer, time in
            guard let self else { return }
            let (streaming, recording) = lock.withLock { (!self.clients.isEmpty, self.isRecording) }
            if streaming { audioEncoder.encode(buffer, time: time) }
            if recording { recorder.appendAudio(buffer, time: time) }
        }

        videoEncoder.onFormat = { [weak self] record, _ in
            guard let self else { return }
            let targets = lock.withLock {
                self.videoSequenceHeader = record
                return Array(self.clients.values)
            }
            for client in targets { client.setVideoSequenceHeader(record) }
        }
        videoEncoder.onFrame = { [weak self] frame in
            guard let self else { return }
            let (targets, recording) = lock.withLock { (Array(self.clients.values), self.isRecording) }
            for client in targets {
                client.sendVideo(accessUnit: frame.accessUnit, pts: frame.pts, dts: frame.dts, isKeyFrame: frame.isKeyFrame)
            }
            if recording { recorder.appendVideo(frame) }
        }
        audioEncoder.onConfig = { [weak self] config in
            guard let self else { return }
            let targets = lock.withLock {
                self.audioSequenceHeader = config
                return Array(self.clients.values)
            }
            for client in targets { client.setAudioSequenceHeader(config) }
        }
        audioEncoder.onPacket = { [weak self] packet, pts in
            guard let self else { return }
            let targets = lock.withLock { Array(self.clients.values) }
            for client in targets { client.sendAudio(aacPacket: packet, pts: pts) }
        }

        recorder.onEvent = { [weak self] event in
            guard let self else { return }
            if case .started = event {} else {
                lock.withLock { self.isRecording = false }
                stopEncoderIfIdle()
            }
            onEvent?(.recording(event))
        }

        startClock(fps: video.fps)
    }

    // MARK: - Configuration

    func updateVideo(_ state: VideoState) {
        let (fpsChanged, missingImages) = lock.withLock { () -> (Bool, [String]) in
            let changed = video.fps != state.fps
            video = state
            var wantedVideos = Set<String>()
            for layer in state.layers {
                if case .video(let path) = layer.input {
                    wantedVideos.insert(path)
                    if videoPlayers[path] == nil { videoPlayers[path] = VideoFilePlayer(path: path) }
                }
            }
            for path in videoPlayers.keys where !wantedVideos.contains(path) { videoPlayers[path] = nil }
            var missing: [String] = []
            for layer in state.layers {
                if case .image(let path) = layer.input, images[path] == nil, !loadingImages.contains(path) {
                    loadingImages.insert(path)
                    missing.append(path)
                }
            }
            return (changed, missing)
        }
        for path in missingImages { loadImage(path) }
        if fpsChanged { startClock(fps: state.fps) }
    }

    func setChannel(_ channel: AudioChannelID, settings: AudioMixer.ChannelSettings) {
        mixer.setSettings(settings, for: channel)
    }

    func resetChannel(_ channel: AudioChannelID) {
        mixer.reset(channel)
    }

    /// Forget a slot's last frame (e.g. the scene switched to another camera).
    func clearFrame(_ input: Input) {
        lock.withLock { frames[input] = nil }
    }

    private func loadImage(_ path: String) {
        imageQueue.async { [weak self] in
            let buffer = MetalPipeline.makePixelBuffer(contentsOf: URL(fileURLWithPath: path))
            guard let self else { return }
            lock.withLock {
                self.loadingImages.remove(path)
                if let buffer { self.images[path] = buffer }
            }
            if buffer == nil {
                onEvent?(.captureError(String(localized: "Streamio could not open the image at \(path).")))
            }
        }
    }

    // MARK: - Streaming (one encode, many destinations)

    var hasActiveDestinations: Bool { lock.withLock { !clients.isEmpty } }

    func startDestination(_ id: UUID, configuration: RTMPClient.Configuration,
                          encoder: VideoEncoder.Settings, audioBitrate: AudioBitrate) throws {
        try ensureEncoder(encoder)
        if !audioEncoder.isRunning { audioEncoder.start(bitrate: audioBitrate) }

        let client = RTMPClient()
        client.onKeyFrameRequest = { [weak self] in self?.videoEncoder.requestKeyFrame() }
        client.onEvent = { [weak self] event in
            switch event {
            case .status(let status): self?.onEvent?(.stream(id, status))
            case .statistics(let stats): self?.onEvent?(.network(id, stats))
            }
        }
        let (previous, videoHeader, audioHeader) = lock.withLock { () -> (RTMPClient?, Data?, Data?) in
            let old = clients[id]
            clients[id] = client
            return (old, videoSequenceHeader, audioSequenceHeader)
        }
        previous?.disconnect()
        client.connect(configuration)
        // A destination joining a running encoder still needs the decoder configuration.
        if let videoHeader { client.setVideoSequenceHeader(videoHeader) }
        if let audioHeader { client.setAudioSequenceHeader(audioHeader) }
        videoEncoder.requestKeyFrame()
    }

    func stopDestination(_ id: UUID) {
        let (client, remaining) = lock.withLock { () -> (RTMPClient?, Int) in
            let removed = clients.removeValue(forKey: id)
            return (removed, clients.count)
        }
        client?.disconnect()
        if remaining == 0 {
            audioEncoder.stop()
            lock.withLock { audioSequenceHeader = nil }
            stopEncoderIfIdle()
        }
    }

    func stopAllDestinations() {
        let ids = lock.withLock { Array(clients.keys) }
        for id in ids { stopDestination(id) }
    }

    // MARK: - Recording

    func startRecording(_ settings: StreamRecorder.Settings, encoder: VideoEncoder.Settings) throws -> URL {
        try ensureEncoder(encoder)
        let url = try recorder.start(settings)
        lock.withLock { isRecording = true }
        videoEncoder.requestKeyFrame()
        return url
    }

    func stopRecording() {
        recorder.stop()
    }

    func updateBitrate(_ bitrate: Int) {
        videoEncoder.updateBitrate(bitrate)
    }

    private func ensureEncoder(_ settings: VideoEncoder.Settings) throws {
        if !videoEncoder.isRunning {
            lock.withLock { videoSequenceHeader = nil }
            try videoEncoder.start(settings)
        }
    }

    private func stopEncoderIfIdle() {
        let idle = lock.withLock { clients.isEmpty && !isRecording }
        if idle { videoEncoder.stop() }
    }

    // MARK: - Video path

    private static func hostSeconds() -> Double {
        CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
    }

    /// Sources only replace their slot. Arrival time (not the device timestamp) decides freshness,
    /// because USB cameras often stamp frames 100–300 ms in the past.
    private func ingestVideo(_ sample: CMSampleBuffer, into input: Input) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return }
        let now = Self.hostSeconds()
        lock.withLock {
            frames[input] = SourceFrame(buffer: pixelBuffer, arrival: now)
            if input == .camera { cameraFramesThisWindow += 1 }
        }
    }

    private func startClock(fps: Int) {
        clock?.cancel()
        clockFPS = max(fps, 1)
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: clockQueue)
        let interval = 1.0 / Double(clockFPS)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        clock = timer
    }

    private func tick() {
        let started = Self.hostSeconds()
        let pts = CMClockGetTime(CMClockGetHostTimeClock())
        let (state, slots, stills, players, outputting) = lock.withLock {
            (video, frames, images, videoPlayers, !clients.isEmpty || isRecording)
        }

        var layers: [CanvasLayer] = []
        layers.reserveCapacity(state.layers.count)
        for layer in state.layers {
            let buffer: CVPixelBuffer?
            switch layer.input {
            case .image(let path):
                buffer = stills[path]
            case .video(let path):
                buffer = players[path]?.currentFrame()
            case .extraCamera:
                // An overlay camera that drops out just disappears; the card is for the main camera.
                if let frame = slots[layer.input], started - frame.arrival < cameraHoldSeconds {
                    buffer = frame.buffer
                } else {
                    buffer = nil
                }
            case .camera, .display:
                if layer.input == .camera {
                    buffer = cameraBuffer(slots[.camera], now: started)
                } else if let frame = slots[layer.input], started - frame.arrival < holdLastFrameSeconds {
                    buffer = frame.buffer
                } else {
                    buffer = nil
                }
            }
            guard let buffer else { continue }
            let isSlate = buffer === signalSlate
            layers.append(CanvasLayer(source: buffer, layout: layer.layout, pipScale: layer.pipScale,
                                      isMirrored: isSlate ? false : layer.isMirrored, opacity: layer.opacity,
                                      filter: isSlate ? .passthrough : layer.filter, params: layer.params,
                                      shape: layer.shape, borderWidth: layer.borderWidth, borderColor: layer.borderColor,
                                      offsetX: layer.offsetX, offsetY: layer.offsetY))
        }

        guard let canvas = MetalPipeline.shared.composeCanvas(
            layers: layers, width: state.canvasWidth, height: state.canvasHeight
        ) else { return }
        preview.publish(canvas)

        if outputting {
            videoEncoder.encode(canvas, pts: pts, duration: CMTime(value: 1, timescale: CMTimeScale(max(state.fps, 1))))
        }
        report(renderSeconds: Self.hostSeconds() - started, now: started)
    }

    /// The camera's newest frame, or the "No signal" card once it has stopped delivering.
    private func cameraBuffer(_ frame: SourceFrame?, now: Double) -> CVPixelBuffer? {
        if let frame {
            cameraMissingSince = nil
            return now - frame.arrival < cameraHoldSeconds ? frame.buffer : signalSlate
        }
        let since = cameraMissingSince ?? now
        cameraMissingSince = since
        return now - since >= cameraStartGraceSeconds ? signalSlate : nil
    }

    private func report(renderSeconds: Double, now: Double) {
        let report: FrameReport? = lock.withLock {
            renderedThisWindow += 1
            renderTimeThisWindow += renderSeconds
            if windowStart == 0 { windowStart = now }
            let elapsed = now - windowStart
            guard elapsed >= 1 else { return nil }
            defer {
                renderedThisWindow = 0
                cameraFramesThisWindow = 0
                renderTimeThisWindow = 0
                windowStart = now
            }
            return FrameReport(
                outputFPS: Double(renderedThisWindow) / elapsed,
                cameraFPS: Double(cameraFramesThisWindow) / elapsed,
                skippedFrames: 0,
                renderMilliseconds: renderTimeThisWindow / Double(max(renderedThisWindow, 1)) * 1000
            )
        }
        if var report {
            report.skippedFrames = videoEncoder.skippedFrameCount
            onEvent?(.frames(report))
        }
    }
}
