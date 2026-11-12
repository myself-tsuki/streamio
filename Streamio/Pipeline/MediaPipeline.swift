//
//  MediaPipeline.swift
//  Streamio
//
//  Wires capture → canvas compositor → preview / encoder → RTMP + recorder,
//  and microphone + desktop audio → mixer → AAC → RTMP + recorder.
//  Runs entirely off the main actor; the UI talks to it through `StudioController`.
//

import AVFoundation
import CoreMedia
import Foundation

nonisolated final class MediaPipeline: @unchecked Sendable {
    struct VideoState: Equatable, Sendable {
        var canvasWidth = 1920
        var canvasHeight = 1080
        var fps = 30
        var filter: FilterType = .passthrough
        var params = FilterParameters()
        var isVisible = true
        var hasSource = false
    }

    enum Event: Sendable {
        case stream(StreamStatus)
        case network(RTMPClient.Statistics)
        case recording(StreamRecorder.Event)
        case frames(fps: Double, skipped: Int)
        case levels([AudioChannelID: AudioLevels])
        case captureError(String)
    }

    var onEvent: (@Sendable (Event) -> Void)?

    let preview = PreviewFrameStore()
    let mixer = AudioMixer()
    let camera = CaptureSessionController()
    let screen = ScreenCaptureController()
    private let videoEncoder = VideoEncoder()
    private let audioEncoder: AudioEncoder
    private let rtmp = RTMPClient()
    private let recorder = StreamRecorder()

    private let lock = NSLock()
    private var video = VideoState()
    private var isStreaming = false
    private var isRecording = false
    private var lastSourceFrameTime: Double = 0
    private var framesThisSecond = 0
    private var fpsWindowStart: Double = 0

    private let clockQueue = DispatchQueue(label: "com.streamio.canvas.clock", qos: .userInteractive)
    private var clock: DispatchSourceTimer?

    init() {
        audioEncoder = AudioEncoder(inputFormat: mixer.outputFormat)

        camera.onVideo = { [weak self] sample in self?.ingestVideo(sample) }
        camera.onAudio = { [weak self] sample in self?.mixer.ingest(sample, from: .microphone) }
        camera.onError = { [weak self] message in self?.onEvent?(.captureError(message)) }
        screen.onVideo = { [weak self] sample in self?.ingestVideo(sample) }
        screen.onAudio = { [weak self] sample in self?.mixer.ingest(sample, from: .desktop) }
        screen.onStop = { [weak self] message in
            self?.mixer.reset(.desktop)
            if let message { self?.onEvent?(.captureError(message)) }
        }

        mixer.onLevels = { [weak self] levels in self?.onEvent?(.levels(levels)) }
        mixer.onMixedAudio = { [weak self] buffer, time in
            guard let self else { return }
            let (streaming, recording) = lock.withLock { (isStreaming, isRecording) }
            if streaming { audioEncoder.encode(buffer, time: time) }
            if recording { recorder.appendAudio(buffer, time: time) }
        }

        videoEncoder.onFormat = { [weak self] record, _ in self?.rtmp.setVideoSequenceHeader(record) }
        videoEncoder.onFrame = { [weak self] frame in
            guard let self else { return }
            let (streaming, recording) = lock.withLock { (isStreaming, isRecording) }
            if streaming { rtmp.sendVideo(accessUnit: frame.accessUnit, pts: frame.pts, dts: frame.dts, isKeyFrame: frame.isKeyFrame) }
            if recording { recorder.appendVideo(frame) }
        }
        audioEncoder.onConfig = { [weak self] config in self?.rtmp.setAudioSequenceHeader(config) }
        audioEncoder.onPacket = { [weak self] packet, pts in self?.rtmp.sendAudio(aacPacket: packet, pts: pts) }

        rtmp.onKeyFrameRequest = { [weak self] in self?.videoEncoder.requestKeyFrame() }
        rtmp.onEvent = { [weak self] event in
            switch event {
            case .status(let status): self?.onEvent?(.stream(status))
            case .statistics(let stats): self?.onEvent?(.network(stats))
            }
        }
        recorder.onEvent = { [weak self] event in
            guard let self else { return }
            if case .started = event {} else {
                lock.withLock { isRecording = false }
                stopEncoderIfIdle()
            }
            onEvent?(.recording(event))
        }

        startClock(fps: video.fps)
    }

    // MARK: - Configuration

    func updateVideo(_ state: VideoState) {
        let fpsChanged = lock.withLock {
            defer { video = state }
            return video.fps != state.fps
        }
        if fpsChanged { startClock(fps: state.fps) }
    }

    func setChannel(_ channel: AudioChannelID, gainDecibels: Float, muted: Bool) {
        mixer.setSettings(.init(gain: AudioLevels.amplitude(fromDecibels: gainDecibels), isMuted: muted), for: channel)
    }

    // MARK: - Outputs

    func startStreaming(_ configuration: RTMPClient.Configuration, encoder: VideoEncoder.Settings, audioBitrate: AudioBitrate) throws {
        try ensureEncoder(encoder)
        audioEncoder.start(bitrate: audioBitrate)
        lock.withLock { isStreaming = true }
        rtmp.connect(configuration)
    }

    func stopStreaming() {
        lock.withLock { isStreaming = false }
        rtmp.disconnect()
        audioEncoder.stop()
        stopEncoderIfIdle()
    }

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
            try videoEncoder.start(settings)
        }
    }

    private func stopEncoderIfIdle() {
        let idle = lock.withLock { !isStreaming && !isRecording }
        if idle { videoEncoder.stop() }
    }

    // MARK: - Video path

    private func ingestVideo(_ sample: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return }
        let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
        let state = lock.withLock {
            lastSourceFrameTime = time
            return video
        }
        guard state.isVisible, state.hasSource else { return }
        render(source: pixelBuffer, state: state, pts: CMSampleBufferGetPresentationTimeStamp(sample))
    }

    private func render(source: CVPixelBuffer?, state: VideoState, pts: CMTime) {
        guard let canvas = MetalPipeline.shared.composeCanvas(
            source: source, width: state.canvasWidth, height: state.canvasHeight,
            filter: state.filter, params: state.params
        ) else { return }
        preview.publish(canvas)

        let duration = CMTime(value: 1, timescale: CMTimeScale(state.fps))
        if lock.withLock({ isStreaming || isRecording }) {
            videoEncoder.encode(canvas, pts: pts, duration: duration)
        }
        countFrame(at: CMTimeGetSeconds(pts))
    }

    /// Emits black canvas frames when the source is hidden, missing or stalled,
    /// so the stream never freezes (OBS always outputs video).
    private func startClock(fps: Int) {
        clock?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: clockQueue)
        let interval = 1.0 / Double(max(fps, 1))
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            let (state, last) = lock.withLock { (video, lastSourceFrameTime) }
            let stalled = CMTimeGetSeconds(now) - last > interval * 3
            if !state.hasSource || !state.isVisible || stalled {
                render(source: nil, state: state, pts: now)
            }
        }
        timer.resume()
        clock = timer
    }

    private func countFrame(at time: Double) {
        let report: (Double, Int)? = lock.withLock {
            framesThisSecond += 1
            if fpsWindowStart == 0 { fpsWindowStart = time }
            let elapsed = time - fpsWindowStart
            guard elapsed >= 1 else { return nil }
            defer { framesThisSecond = 0; fpsWindowStart = time }
            return (Double(framesThisSecond) / elapsed, 0)
        }
        if let report {
            onEvent?(.frames(fps: report.0, skipped: videoEncoder.skippedFrameCount))
        }
    }
}
