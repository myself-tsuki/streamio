//
//  StudioController.swift
//  Streamio
//
//  Main-actor state for the studio window: settings, scenes, mixer channels,
//  outputs. Pushes changes into `MediaPipeline` and turns pipeline events into UI state.
//

import AppKit
import AVFoundation
import Foundation
import Observation

@Observable
final class StudioController {
    // MARK: Settings (persisted)
    var service: StreamingService = .youtube { didSet { save(); loadStreamKey() } }
    var serverURL = "rtmps://a.rtmps.youtube.com:443/live2" { didSet { save() } }
    var streamKey = "" { didSet { if !isLoading { KeychainStore.setStreamKey(streamKey, for: service.rawValue) } } }
    var resolution: VideoResolution = .fhd1080 { didSet { save(); pushVideo(); reconfigureCapture() } }
    var frameRate: FrameRate = .fps30 { didSet { save(); pushVideo(); reconfigureCapture() } }
    var codec: VideoCodec = .h264 { didSet { save() } }
    var videoBitrateKbps: Double = 6000 { didSet { save(); pipeline.updateBitrate(Int(videoBitrateKbps) * 1000) } }
    var keyFrameInterval: Double = 2 { didSet { save() } }
    var audioBitrate: AudioBitrate = .kbps160 { didSet { save() } }
    var recordingFormat: RecordingFormat = .mp4 { didSet { save() } }
    var recordingDirectory: URL = URL.moviesDirectory { didSet { save() } }
    var autoReconnect = true { didSet { save() } }
    var showsCursor = true { didSet { save(); reconfigureCapture() } }
    var microphoneID = "" { didSet { save(); reconfigureCapture() } }
    var desktopAudioEnabled = true { didSet { save(); reconfigureCapture() } }
    var gains: [AudioChannelID: Float] = [.desktop: 0, .microphone: 0] { didSet { save(); pushAudio() } }
    var mutes: [AudioChannelID: Bool] = [.desktop: false, .microphone: false] { didSet { save(); pushAudio() } }

    // MARK: Scenes
    var scenes: [StudioScene] = [] { didSet { save() } }
    var selectedSceneID: UUID? { didSet { save(); applyScene() } }

    // MARK: Runtime state
    private(set) var streamStatus: StreamStatus = .idle
    private(set) var isRecording = false
    private(set) var lastRecordingURL: URL?
    var alertMessage: String?

    let stats = StudioStats()
    let meters = AudioMeterModel()
    let devices = CaptureDeviceManager()

    @ObservationIgnored private let pipeline = MediaPipeline()
    @ObservationIgnored private let monitor = SystemMonitor()
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private var isLoading = true
    @ObservationIgnored private let defaults = UserDefaults.standard

    var previewStore: PreviewFrameStore { pipeline.preview }

    var selectedScene: StudioScene? {
        get { scenes.first { $0.id == selectedSceneID } }
        set {
            guard let newValue, let index = scenes.firstIndex(where: { $0.id == newValue.id }) else { return }
            scenes[index] = newValue
            applyScene()
        }
    }

    var isOutputActive: Bool { streamStatus.isActive || isRecording }

    init() {
        load()
        if scenes.isEmpty {
            scenes = [StudioScene(name: String(localized: "Camera"), videoSource: devices.defaultCameraID.map { .camera(id: $0) } ?? .none)]
        }
        if selectedSceneID == nil || selectedScene == nil { selectedSceneID = scenes.first?.id }
        isLoading = false

        pipeline.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        pushAudio()
        applyScene()
        startStatsLoop()
    }

    // MARK: - Scenes

    func addScene() {
        let scene = StudioScene(name: String(localized: "Scene \(scenes.count + 1)"))
        scenes.append(scene)
        selectedSceneID = scene.id
    }

    func duplicate(_ scene: StudioScene) {
        var copy = scene
        copy = StudioScene(name: String(localized: "\(scene.name) Copy"), videoSource: copy.videoSource,
                           isVideoVisible: copy.isVideoVisible, filter: copy.filter, adjustments: copy.adjustments)
        scenes.append(copy)
    }

    func remove(_ scene: StudioScene) {
        guard scenes.count > 1 else { return }
        scenes.removeAll { $0.id == scene.id }
        if selectedSceneID == scene.id { selectedSceneID = scenes.first?.id }
    }

    func selectAdjacentScene(offset: Int) {
        guard let index = scenes.firstIndex(where: { $0.id == selectedSceneID }), !scenes.isEmpty else { return }
        selectedSceneID = scenes[(index + offset + scenes.count) % scenes.count].id
    }

    func setSource(_ source: VideoSource) {
        guard var scene = selectedScene else { return }
        scene.videoSource = source
        selectedScene = scene
    }

    func toggleVideoVisibility() {
        guard var scene = selectedScene else { return }
        scene.isVideoVisible.toggle()
        selectedScene = scene
    }

    // MARK: - Outputs

    func toggleStreaming() {
        if streamStatus.isActive {
            pipeline.stopStreaming()
            streamStatus = .idle
            stats.streamStart = nil
            return
        }
        guard let endpoint = RTMPEndpoint(urlString: serverURL) else {
            alertMessage = String(localized: "The server URL must start with rtmp:// or rtmps:// and include an app path.")
            return
        }
        let key = streamKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            alertMessage = String(localized: "Add your stream key in Settings ▸ Stream before going live.")
            return
        }
        let configuration = RTMPClient.Configuration(
            endpoint: endpoint, streamKey: key, width: resolution.width, height: resolution.height,
            fps: frameRate.rawValue, videoBitrate: Int(videoBitrateKbps) * 1000, audioBitrate: audioBitrate.rawValue,
            audioSampleRate: AudioMixer.sampleRate, videoFormat: codec.flvFormat,
            autoReconnect: autoReconnect, maxReconnectAttempts: 10, reconnectDelay: .seconds(2)
        )
        do {
            try pipeline.startStreaming(configuration, encoder: encoderSettings, audioBitrate: audioBitrate)
            streamStatus = .connecting
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func toggleRecording() {
        if isRecording {
            pipeline.stopRecording()
            return
        }
        do {
            let settings = StreamRecorder.Settings(directory: recordingDirectory, format: recordingFormat, audioBitrate: audioBitrate)
            lastRecordingURL = try pipeline.startRecording(settings, encoder: encoderSettings)
            isRecording = true
            stats.recordStart = .now
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func toggleMute(_ channel: AudioChannelID) {
        mutes[channel] = !(mutes[channel] ?? false)
    }

    func revealRecordings() {
        if let lastRecordingURL, FileManager.default.fileExists(atPath: lastRecordingURL.path(percentEncoded: false)) {
            NSWorkspace.shared.activateFileViewerSelecting([lastRecordingURL])
        } else {
            NSWorkspace.shared.open(recordingDirectory)
        }
    }

    private var encoderSettings: VideoEncoder.Settings {
        VideoEncoder.Settings(width: resolution.width, height: resolution.height, fps: frameRate.rawValue,
                              bitrate: Int(videoBitrateKbps) * 1000, codec: codec, keyFrameIntervalSeconds: keyFrameInterval)
    }

    // MARK: - Pipeline sync

    private func applyScene() {
        guard !isLoading else { return }
        pushVideo()
        reconfigureCapture()
    }

    private func pushVideo() {
        guard !isLoading else { return }
        let scene = selectedScene
        pipeline.updateVideo(.init(
            canvasWidth: resolution.width, canvasHeight: resolution.height, fps: frameRate.rawValue,
            filter: scene?.filter ?? .passthrough, params: scene?.adjustments ?? FilterParameters(),
            isVisible: scene?.isVideoVisible ?? true, hasSource: (scene?.videoSource ?? .none) != .none
        ))
    }

    private func pushAudio() {
        guard !isLoading else { return }
        for channel in AudioChannelID.allCases {
            pipeline.setChannel(channel, gainDecibels: gains[channel] ?? 0, muted: mutes[channel] ?? false)
        }
    }

    private func reconfigureCapture() {
        guard !isLoading else { return }
        let source = selectedScene?.videoSource ?? .none
        var cameraDevice: AVCaptureDevice?
        if case .camera(let id) = source { cameraDevice = devices.camera(id: id) }
        pipeline.camera.configure(camera: cameraDevice, microphone: devices.microphone(id: microphoneID),
                                  canvasWidth: resolution.width, canvasHeight: resolution.height, fps: frameRate.rawValue)

        var displayID: CGDirectDisplayID?
        if case .display(let id) = source { displayID = id }
        let request = ScreenCaptureController.Request(
            displayID: displayID, captureAudio: desktopAudioEnabled, canvasWidth: resolution.width,
            canvasHeight: resolution.height, fps: frameRate.rawValue, showsCursor: showsCursor
        )
        let screen = pipeline.screen
        Task {
            do {
                try await screen.apply(request)
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Events

    private func handle(_ event: MediaPipeline.Event) {
        switch event {
        case .stream(let status):
            guard streamStatus.isActive || status == .idle || status.errorMessage != nil else { return }
            streamStatus = status
            if status.isLive, stats.streamStart == nil { stats.streamStart = .now }
            if !status.isActive { stats.streamStart = nil }
            if let message = status.errorMessage { alertMessage = message; pipeline.stopStreaming() }
        case .network(let network):
            stats.bitrateKbps = network.bitrateKbps
            stats.bytesSent = network.bytesSent
            stats.droppedFrames = network.droppedVideoFrames
            stats.sentFrames = network.sentVideoFrames
            stats.congestion = network.congestion
        case .recording(let recording):
            switch recording {
            case .started(let url):
                lastRecordingURL = url
            case .finished(let url):
                lastRecordingURL = url
                isRecording = false
                stats.recordStart = nil
            case .failed(let message):
                isRecording = false
                stats.recordStart = nil
                alertMessage = message
            }
        case .frames(let fps, let skipped):
            stats.fps = fps
            stats.skippedFrames = skipped
        case .levels(let readings):
            meters.apply(readings)
        case .captureError(let message):
            alertMessage = message
        }
    }

    private func startStatsLoop() {
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                let usage = monitor.sample()
                stats.cpuPercent = usage.cpuPercent
                stats.gpuPercent = usage.gpuPercent
                stats.memoryBytes = usage.memoryBytes
                stats.diskFreeBytes = SystemMonitor.availableCapacity(at: recordingDirectory)
                if isRecording, let url = lastRecordingURL,
                   let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    stats.recordedBytes = Int64(size)
                }
                if !isOutputActive { stats.bitrateKbps = 0 }
            }
        }
    }

    // MARK: - Persistence

    private struct Snapshot: Codable {
        var service: StreamingService, serverURL: String, resolution: VideoResolution, frameRate: FrameRate
        var codec: VideoCodec, videoBitrateKbps: Double, keyFrameInterval: Double, audioBitrate: AudioBitrate
        var recordingFormat: RecordingFormat, recordingDirectory: URL, autoReconnect: Bool, showsCursor: Bool
        var microphoneID: String, desktopAudioEnabled: Bool
        var gains: [AudioChannelID: Float], mutes: [AudioChannelID: Bool]
        var scenes: [StudioScene], selectedSceneID: UUID?
    }

    private func save() {
        guard !isLoading else { return }
        let snapshot = Snapshot(service: service, serverURL: serverURL, resolution: resolution, frameRate: frameRate,
                                codec: codec, videoBitrateKbps: videoBitrateKbps, keyFrameInterval: keyFrameInterval,
                                audioBitrate: audioBitrate, recordingFormat: recordingFormat,
                                recordingDirectory: recordingDirectory, autoReconnect: autoReconnect,
                                showsCursor: showsCursor, microphoneID: microphoneID,
                                desktopAudioEnabled: desktopAudioEnabled, gains: gains, mutes: mutes,
                                scenes: scenes, selectedSceneID: selectedSceneID)
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: "studio.settings.v2")
        }
    }

    private func load() {
        defer { loadStreamKey() }
        guard let data = defaults.data(forKey: "studio.settings.v2"),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        service = snapshot.service
        serverURL = snapshot.serverURL
        resolution = snapshot.resolution
        frameRate = snapshot.frameRate
        codec = snapshot.codec
        videoBitrateKbps = snapshot.videoBitrateKbps
        keyFrameInterval = snapshot.keyFrameInterval
        audioBitrate = snapshot.audioBitrate
        recordingFormat = snapshot.recordingFormat
        recordingDirectory = snapshot.recordingDirectory
        autoReconnect = snapshot.autoReconnect
        showsCursor = snapshot.showsCursor
        microphoneID = snapshot.microphoneID
        desktopAudioEnabled = snapshot.desktopAudioEnabled
        gains = snapshot.gains
        mutes = snapshot.mutes
        scenes = snapshot.scenes
        selectedSceneID = snapshot.selectedSceneID
    }

    private func loadStreamKey() {
        let wasLoading = isLoading
        isLoading = true
        streamKey = KeychainStore.streamKey(for: service.rawValue)
        isLoading = wasLoading
    }
}
