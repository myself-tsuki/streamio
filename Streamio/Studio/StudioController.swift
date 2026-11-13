//
//  StudioController.swift
//  Streamio
//
//  Main-actor state for the studio window: settings, scenes and their sources, mixer
//  channels, stream destinations and outputs. Pushes changes into `MediaPipeline` and
//  turns pipeline events into UI state.
//

import AppKit
import AVFoundation
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

@Observable
final class StudioController {
    // MARK: Settings (persisted)
    var destinations: [StreamDestination] = [] { didSet { save() } }
    var resolution: VideoResolution = .fhd1080 { didSet { save(); pushVideo(); reconfigureCapture() } }
    var frameRate: FrameRate = .fps30 { didSet { save(); pushVideo(); reconfigureCapture() } }
    var codec: VideoCodec = .h264 { didSet { save() } }
    var videoBitrateKbps: Double = 6000 { didSet { save(); pipeline.updateBitrate(Int(videoBitrateKbps) * 1000) } }
    var keyFrameInterval: Double = 2 { didSet { save() } }
    var audioBitrate: AudioBitrate = .kbps160 { didSet { save() } }
    var recordingFormat: RecordingFormat = .mp4 { didSet { save() } }
    var recordingDirectory: URL = StudioController.defaultRecordingDirectory { didSet { save() } }

    /// ~/Movies/Streamio. Created on demand when recording starts or the folder is revealed.
    nonisolated static var defaultRecordingDirectory: URL {
        URL.moviesDirectory.appending(path: "Streamio", directoryHint: .isDirectory)
    }

    /// Earlier builds saved plain ~/Movies; move those users into the Streamio subfolder.
    private static func migratedRecordingDirectory(_ url: URL) -> URL {
        url.standardizedFileURL.path(percentEncoded: false).trimmingSuffix("/")
            == URL.moviesDirectory.standardizedFileURL.path(percentEncoded: false).trimmingSuffix("/")
            ? defaultRecordingDirectory : url
    }
    var autoReconnect = true { didSet { save() } }
    var showsCursor = true { didSet { save(); reconfigureCapture() } }
    /// Mixer channels the user added. Empty by default: nothing is captured until a source is added.
    var audioSources: [AudioSourceConfig] = [] {
        didSet {
            save()
            pushAudio()
            if audioSources.map(\.deviceID) != oldValue.map(\.deviceID)
                || audioSources.map(\.channel) != oldValue.map(\.channel) {
                reconfigureCapture()
            }
        }
    }
    /// Core Audio UID of the monitoring output; "" follows the system default output.
    var monitorDeviceUID = "" { didSet { save(); pushAudio() } }

    // MARK: Scenes
    var scenes: [StudioScene] = [] { didSet { save(); applyScene() } }
    var selectedSceneID: UUID? { didSet { save(); selectedSourceID = nil; applyScene() } }
    var selectedSourceID: UUID?

    // MARK: Runtime state
    private(set) var destinationStatus: [UUID: StreamStatus] = [:]
    private(set) var isRecording = false
    /// Stop was pressed and the file is being closed. The UI shows it at once.
    private(set) var isFinalizingRecording = false
    /// Last capture problem that did not interrupt the broadcast (cable glitch while live).
    private(set) var captureNotice: String?
    private(set) var lastRecordingURL: URL?
    private(set) var isCaptureAuthorized = false
    private(set) var isFullscreenPreview = false
    var showsStatsOverlay = true
    var alertMessage: String?

    let stats = StudioStats()
    let widgets = WidgetLayout()
    let meters = AudioMeterModel()
    let devices = CaptureDeviceManager()

    @ObservationIgnored private let pipeline = MediaPipeline()
    @ObservationIgnored private let monitor = SystemMonitor()
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private var isPinging = false
    @ObservationIgnored private var isLoading = true
    private var streamKeys: [UUID: String] = [:]
    @ObservationIgnored private var activeCameraID: String?
    @ObservationIgnored private var activeDisplayID: UInt32?
    @ObservationIgnored private var lastCaptureKey: CaptureKey?
    @ObservationIgnored private var enteredNativeFullScreen = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let defaults = UserDefaults.standard

    var previewStore: PreviewFrameStore { pipeline.preview }

    var selectedScene: StudioScene? {
        get { scenes.first { $0.id == selectedSceneID } }
        set {
            guard let newValue, let index = scenes.firstIndex(where: { $0.id == newValue.id }) else { return }
            scenes[index] = newValue
        }
    }

    var selectedSource: SceneSource? {
        get { selectedScene?.sources.first { $0.id == selectedSourceID } }
        set {
            guard let newValue else { return }
            updateSource(newValue)
        }
    }

    /// Combined state of every destination: live if any is live.
    var streamStatus: StreamStatus {
        let values = Array(destinationStatus.values)
        if values.contains(.streaming) { return .streaming }
        if values.contains(.reconnecting) { return .reconnecting }
        if values.contains(.connecting) { return .connecting }
        return .idle
    }

    var isOutputActive: Bool { streamStatus.isActive || isRecording }

    init() {
        load()
        if scenes.isEmpty { scenes = [StudioScene(name: String(localized: "Scene"))] }
        if selectedSceneID == nil || selectedScene == nil { selectedSceneID = scenes.first?.id }
        if destinations.isEmpty { destinations = [StreamDestination(name: "YouTube", service: .youtube)] }
        for destination in destinations {
            streamKeys[destination.id] = KeychainStore.streamKey(for: destination.keychainAccount)
        }
        isLoading = false
        save()

        pipeline.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        devices.onChange = { [weak self] in self?.reconfigureCapture(force: true) }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.enteredNativeFullScreen else { return }
                self.enteredNativeFullScreen = false
                self.isFullscreenPreview = false
            }
        })
        pushAudio()
        pushVideo()
        startStatsLoop()
    }

    // MARK: - Permissions

    /// Capture starts only once camera, microphone and screen recording are all allowed.
    func setCaptureAuthorized(_ authorized: Bool) {
        guard authorized != isCaptureAuthorized else { return }
        isCaptureAuthorized = authorized
        if authorized {
            devices.refreshDevices()
            devices.refreshDisplays()
            pushAudio()
            pushVideo()
            reconfigureCapture(force: true)
        } else {
            stopAllStreams()
            if isRecording { pipeline.stopRecording() }
            pipeline.camera.configure(camera: nil, microphone: nil, canvasWidth: resolution.width,
                                      canvasHeight: resolution.height, fps: frameRate.rawValue)
            lastCaptureKey = nil
            let screen = pipeline.screen
            Task { await screen.stop() }
        }
    }

    // MARK: - Scenes

    func addScene() {
        let scene = StudioScene(name: String(localized: "Scene \(scenes.count + 1)"))
        scenes.append(scene)
        selectedSceneID = scene.id
    }

    func duplicate(_ scene: StudioScene) {
        let sources = scene.sources.map {
            SceneSource(name: $0.name, input: $0.input, isVisible: $0.isVisible, layout: $0.layout, pipScale: $0.pipScale,
                        isMirrored: $0.isMirrored, opacity: $0.opacity, filter: $0.filter, adjustments: $0.adjustments)
        }
        scenes.append(StudioScene(name: String(localized: "\(scene.name) Copy"), sources: sources))
    }

    func rename(_ scene: StudioScene, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = scenes.firstIndex(where: { $0.id == scene.id }) else { return }
        scenes[index].name = trimmed
    }

    func remove(_ scene: StudioScene) {
        guard scenes.count > 1 else { return }
        scenes.removeAll { $0.id == scene.id }
        if selectedSceneID == scene.id { selectedSceneID = scenes.first?.id }
    }

    func moveScenes(from offsets: IndexSet, to destination: Int) {
        scenes.move(fromOffsets: offsets, toOffset: destination)
    }

    func selectAdjacentScene(offset: Int) {
        guard let index = scenes.firstIndex(where: { $0.id == selectedSceneID }), !scenes.isEmpty else { return }
        selectedSceneID = scenes[(index + offset + scenes.count) % scenes.count].id
    }

    func selectScene(number: Int) {
        guard scenes.indices.contains(number - 1) else { return }
        selectedSceneID = scenes[number - 1].id
    }

    // MARK: - Video sources

    func canAdd(_ input: VideoSource) -> Bool {
        guard let scene = selectedScene else { return false }
        switch input {
        case .camera: return scene.cameraSource == nil
        case .display: return scene.displaySource == nil
        case .image: return true
        }
    }

    func addSource(_ input: VideoSource) {
        guard var scene = selectedScene else { return }
        guard canAdd(input) else {
            alertMessage = input.isCamera
                ? String(localized: "This scene already has a camera. Remove it first, or add the other camera to a new scene.")
                : String(localized: "This scene already has a display capture. Remove it first, or use a new scene.")
            return
        }
        let isEmpty = scene.sources.isEmpty
        var source = SceneSource(name: devices.name(for: input), input: input)
        switch input {
        case .camera:
            source.layout = isEmpty ? .fit : .bottomRight
        case .display:
            source.layout = .fit
        case .image:
            source.layout = isEmpty ? .fit : .topRight
            source.pipScale = isEmpty ? 0.3 : 0.15
        }
        // New sources go on top, like OBS.
        scene.sources.insert(source, at: 0)
        selectedScene = scene
        selectedSourceID = source.id
    }

    func chooseImageSource() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose an image to add to this scene")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addSource(.image(path: url.path(percentEncoded: false)))
    }

    func removeSource(_ id: UUID) {
        guard var scene = selectedScene else { return }
        scene.sources.removeAll { $0.id == id }
        selectedScene = scene
        if selectedSourceID == id { selectedSourceID = nil }
    }

    func moveSources(from offsets: IndexSet, to destination: Int) {
        guard var scene = selectedScene else { return }
        scene.sources.move(fromOffsets: offsets, toOffset: destination)
        selectedScene = scene
    }

    func moveSource(_ id: UUID, by offset: Int) {
        guard var scene = selectedScene, let index = scene.sources.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard scene.sources.indices.contains(target) else { return }
        scene.sources.swapAt(index, target)
        selectedScene = scene
    }

    func toggleVisibility(_ id: UUID) {
        guard var scene = selectedScene, let index = scene.sources.firstIndex(where: { $0.id == id }) else { return }
        scene.sources[index].isVisible.toggle()
        selectedScene = scene
    }

    func updateSource(_ source: SceneSource) {
        guard var scene = selectedScene, let index = scene.sources.firstIndex(where: { $0.id == source.id }) else { return }
        scene.sources[index] = source
        selectedScene = scene
    }

    // MARK: - Audio sources

    func audioSource(_ channel: AudioChannelID) -> AudioSourceConfig? {
        audioSources.first { $0.channel == channel }
    }

    func addMicrophone(deviceID: String) {
        if let index = audioSources.firstIndex(where: { $0.channel == .microphone }) {
            audioSources[index].deviceID = deviceID
        } else {
            audioSources.append(AudioSourceConfig(channel: .microphone, deviceID: deviceID))
        }
    }

    func addDesktopAudio() {
        guard audioSource(.desktop) == nil else { return }
        audioSources.insert(AudioSourceConfig(channel: .desktop), at: 0)
    }

    func removeAudio(_ channel: AudioChannelID) {
        audioSources.removeAll { $0.channel == channel }
    }

    func updateAudio(_ config: AudioSourceConfig) {
        guard let index = audioSources.firstIndex(where: { $0.channel == config.channel }) else { return }
        audioSources[index] = config
    }

    func toggleMute(_ channel: AudioChannelID) {
        guard var config = audioSource(channel) else { return }
        config.isMuted.toggle()
        updateAudio(config)
    }

    func toggleMonitoring(_ channel: AudioChannelID) {
        guard var config = audioSource(channel) else { return }
        config.monitoring = config.monitoring.isMonitoring ? .off : .monitorAndOutput
        updateAudio(config)
    }

    func audioTitle(_ channel: AudioChannelID) -> String {
        guard channel == .microphone, let config = audioSource(.microphone) else { return channel.title }
        return devices.microphoneName(id: config.deviceID)
    }

    func isAudioDeviceMissing(_ channel: AudioChannelID) -> Bool {
        guard channel == .microphone, let config = audioSource(.microphone) else { return false }
        return devices.microphone(id: config.deviceID) == nil
    }

    // MARK: - Destinations

    func streamKey(for id: UUID) -> String { streamKeys[id] ?? "" }

    func setStreamKey(_ key: String, for id: UUID) {
        guard let destination = destinations.first(where: { $0.id == id }) else { return }
        streamKeys[id] = key
        KeychainStore.setStreamKey(key, for: destination.keychainAccount)
    }

    func addDestination(_ service: StreamingService) {
        destinations.append(StreamDestination(name: service.title, service: service))
    }

    func removeDestination(_ id: UUID) {
        stopDestination(id)
        setStreamKey("", for: id)
        streamKeys[id] = nil
        destinations.removeAll { $0.id == id }
    }

    func status(of id: UUID) -> StreamStatus { destinationStatus[id] ?? .idle }

    // MARK: - Outputs

    /// Starts every enabled destination, or stops all of them.
    func toggleStreaming() {
        if streamStatus.isActive {
            stopAllStreams()
            return
        }
        let enabled = destinations.filter(\.isEnabled)
        guard !enabled.isEmpty else {
            alertMessage = String(localized: "Turn on at least one destination in the Destinations dock, or add one in Settings ▸ Stream.")
            return
        }
        var problems: [String] = []
        for destination in enabled {
            if let problem = startDestination(destination) { problems.append(problem) }
        }
        if !problems.isEmpty { alertMessage = problems.joined(separator: "\n") }
    }

    func toggleDestination(_ id: UUID) {
        if status(of: id).isActive {
            stopDestination(id)
        } else if let destination = destinations.first(where: { $0.id == id }), let problem = startDestination(destination) {
            alertMessage = problem
        }
    }

    /// Returns a message describing why the destination could not start, or nil.
    @discardableResult
    private func startDestination(_ destination: StreamDestination) -> String? {
        guard isCaptureAuthorized else {
            return String(localized: "Grant all permissions before going live.")
        }
        guard let endpoint = RTMPEndpoint(urlString: destination.serverURL) else {
            return String(localized: "\(destination.name): the server URL must start with rtmp:// or rtmps:// and include an app path.")
        }
        let key = streamKey(for: destination.id).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            return String(localized: "\(destination.name): add the stream key in Settings ▸ Stream.")
        }
        let configuration = RTMPClient.Configuration(
            endpoint: endpoint, streamKey: key, width: resolution.width, height: resolution.height,
            fps: frameRate.rawValue, videoBitrate: Int(videoBitrateKbps) * 1000, audioBitrate: audioBitrate.rawValue,
            audioSampleRate: AudioMixer.sampleRate, videoFormat: codec.flvFormat,
            autoReconnect: autoReconnect, maxReconnectAttempts: 10, reconnectDelay: .seconds(2)
        )
        do {
            try pipeline.startDestination(destination.id, configuration: configuration,
                                          encoder: encoderSettings, audioBitrate: audioBitrate)
            destinationStatus[destination.id] = .connecting
            return nil
        } catch {
            return "\(destination.name): \(error.localizedDescription)"
        }
    }

    func stopDestination(_ id: UUID) {
        pipeline.stopDestination(id)
        destinationStatus[id] = .idle
        stats.network[id] = nil
        refreshStreamClock()
    }

    private func stopAllStreams() {
        pipeline.stopAllDestinations()
        for id in destinationStatus.keys { destinationStatus[id] = .idle }
        stats.network.removeAll()
        refreshStreamClock()
    }

    private func refreshStreamClock() {
        let status = streamStatus
        if status.isLive, stats.streamStart == nil { stats.streamStart = .now }
        if !status.isActive { stats.streamStart = nil }
        stats.aggregateNetwork()
    }

    func toggleRecording() {
        if isFinalizingRecording { return }
        if isRecording {
            isFinalizingRecording = true
            pipeline.stopRecording()
            return
        }
        guard isCaptureAuthorized else {
            alertMessage = String(localized: "Grant all permissions before recording.")
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

    func revealRecordings() {
        if let lastRecordingURL, FileManager.default.fileExists(atPath: lastRecordingURL.path(percentEncoded: false)) {
            NSWorkspace.shared.activateFileViewerSelecting([lastRecordingURL])
        } else {
            try? FileManager.default.createDirectory(at: recordingDirectory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(recordingDirectory)
        }
    }

    // MARK: - Fullscreen preview

    func toggleFullscreenPreview() {
        setFullscreenPreview(!isFullscreenPreview)
    }

    /// Shows only the program output, filling the screen, with the stats bar over it.
    func setFullscreenPreview(_ fullscreen: Bool) {
        guard fullscreen != isFullscreenPreview else { return }
        isFullscreenPreview = fullscreen
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let isNativeFullScreen = window.styleMask.contains(.fullScreen)
        if fullscreen, !isNativeFullScreen {
            enteredNativeFullScreen = true
            window.toggleFullScreen(nil)
        } else if !fullscreen, enteredNativeFullScreen {
            enteredNativeFullScreen = false
            if isNativeFullScreen { window.toggleFullScreen(nil) }
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
        let sources = selectedScene?.sources ?? []
        let layers: [MediaPipeline.Layer] = sources.reversed().filter(\.isVisible).map { source in
            let input: MediaPipeline.Input = switch source.input {
            case .camera: .camera
            case .display: .display
            case .image(let path): .image(path)
            }
            return MediaPipeline.Layer(input: input, layout: source.layout, pipScale: source.pipScale,
                                       isMirrored: source.isMirrored, opacity: source.opacity,
                                       filter: source.filter, params: source.adjustments)
        }
        pipeline.updateVideo(.init(canvasWidth: resolution.width, canvasHeight: resolution.height,
                                   fps: frameRate.rawValue, layers: layers))
    }

    private func pushAudio() {
        guard !isLoading else { return }
        for channel in AudioChannelID.allCases {
            if let config = audioSource(channel) {
                pipeline.setChannel(channel, settings: .init(
                    gain: AudioLevels.amplitude(fromDecibels: config.gainDecibels), isMuted: config.isMuted,
                    balance: config.balance, isMono: config.isMono, monitoring: config.monitoring
                ))
            } else {
                pipeline.setChannel(channel, settings: .init(gain: 0, isMuted: true))
                pipeline.resetChannel(channel)
            }
        }
        let monitored = Set(audioSources.filter { $0.monitoring.isMonitoring }.map(\.channel))
        pipeline.monitor.configure(channels: isCaptureAuthorized ? monitored : [], deviceUID: monitorDeviceUID)
    }

    /// Binds capture to exactly the devices the user added. A missing device is left
    /// unused (its source goes dark) and picked up again as soon as it is reconnected.
    /// Everything capture depends on. Filter or layout edits do not touch the devices,
    /// so they never re-lock the camera (re-locking a USB camera mid-stream makes it blink).
    private struct CaptureKey: Equatable {
        var cameraID: String?
        var microphoneID: String?
        var displayID: UInt32?
        var desktopAudio: Bool
        var width: Int
        var height: Int
        var fps: Int
        var showsCursor: Bool
    }

    private func reconfigureCapture(force: Bool = false) {
        guard !isLoading, isCaptureAuthorized else { return }
        let scene = selectedScene
        var keyCameraID: String?
        if let source = scene?.cameraSource, case .camera(let id) = source.input { keyCameraID = id }
        var keyDisplayID: UInt32?
        if let source = scene?.displaySource, case .display(let id) = source.input { keyDisplayID = id }
        let key = CaptureKey(cameraID: keyCameraID, microphoneID: audioSource(.microphone)?.deviceID, displayID: keyDisplayID,
                             desktopAudio: audioSource(.desktop) != nil, width: resolution.width, height: resolution.height,
                             fps: frameRate.rawValue, showsCursor: showsCursor)
        guard force || key != lastCaptureKey else { return }
        lastCaptureKey = key

        var cameraID: String?
        if let source = scene?.cameraSource, case .camera(let id) = source.input { cameraID = id }
        let cameraDevice = cameraID.flatMap { devices.camera(id: $0) }
        if cameraID != activeCameraID {
            pipeline.clearFrame(.camera)
            activeCameraID = cameraID
        }
        let microphoneDevice = audioSource(.microphone).flatMap { devices.microphone(id: $0.deviceID) }
        pipeline.camera.configure(camera: cameraDevice, microphone: microphoneDevice,
                                  canvasWidth: resolution.width, canvasHeight: resolution.height, fps: frameRate.rawValue)

        var displayID: CGDirectDisplayID?
        if let source = scene?.displaySource, case .display(let id) = source.input,
           devices.displays.contains(where: { $0.id == id }) {
            displayID = id
        }
        if displayID != activeDisplayID {
            pipeline.clearFrame(.display)
            activeDisplayID = displayID
        }
        let request = ScreenCaptureController.Request(
            displayID: displayID, captureAudio: audioSource(.desktop) != nil, canvasWidth: resolution.width,
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
        case .stream(let id, let status):
            // Ignore late callbacks from a destination the user already stopped.
            guard destinationStatus[id]?.isActive == true else { return }
            if let message = status.errorMessage {
                let name = destinations.first { $0.id == id }?.name ?? String(localized: "Stream")
                pipeline.stopDestination(id)
                destinationStatus[id] = .error(message)
                stats.network[id] = nil
                alertMessage = "\(name): \(message)"
            } else {
                destinationStatus[id] = status
            }
            refreshStreamClock()
        case .network(let id, let network):
            guard destinationStatus[id]?.isActive == true else { return }
            stats.network[id] = network
            stats.aggregateNetwork()
        case .recording(let recording):
            switch recording {
            case .started(let url):
                lastRecordingURL = url
            case .finished(let url):
                lastRecordingURL = url
                isRecording = false
                isFinalizingRecording = false
                stats.recordStart = nil
            case .failed(let message):
                isRecording = false
                isFinalizingRecording = false
                stats.recordStart = nil
                alertMessage = message
            }
        case .frames(let report):
            stats.fps = report.outputFPS
            if captureNotice != nil, !isOutputActive { captureNotice = nil }
            stats.cameraFPS = report.cameraFPS
            stats.skippedFrames = report.skippedFrames
            stats.renderMilliseconds = report.renderMilliseconds
        case .levels(let readings):
            meters.apply(readings)
        case .captureError(let message):
            // While on air or recording, a device glitch must not pop a modal over the studio:
            // the output carries on with a "No signal" card and the device is picked up again
            // when it returns.
            if isRecording || streamStatus.isActive {
                captureNotice = message
            } else {
                alertMessage = message
            }
        }
    }

    private func startStatsLoop() {
        statsTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if tick % 3 == 0 { refreshPing() }
                tick += 1
                let usage = monitor.sample()
                stats.cpuPercent = usage.cpuPercent
                stats.gpuPercent = usage.gpuPercent
                stats.memoryBytes = usage.memoryBytes
                stats.diskFreeBytes = SystemMonitor.availableCapacity(at: recordingDirectory)
                if isRecording, let url = lastRecordingURL,
                   let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    stats.recordedBytes = Int64(size)
                }
                if !streamStatus.isActive { stats.bitrateKbps = 0 }
            }
        }
    }

    /// Pings the live destination, or the first enabled one while idle.
    private func refreshPing() {
        guard !isPinging else { return }
        let target = destinations.first { status(of: $0.id).isActive } ?? destinations.first { $0.isEnabled }
        guard let endpoint = target.flatMap({ RTMPEndpoint(urlString: $0.serverURL) }) else {
            stats.pingMilliseconds = nil
            return
        }
        isPinging = true
        Task { [weak self] in
            let result = await PingProbe.measure(host: endpoint.host, port: endpoint.port)
            self?.stats.pingMilliseconds = result
            self?.isPinging = false
        }
    }

    // MARK: - Pop-out window

    static let programWindowTitle = "Program Output"

    /// Moves the pop-out window to another display when one is connected, so the studio
    /// stays on one screen and the program output fills the other.
    func moveProgramWindowToOtherScreen() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            let windows = NSApp.windows
            guard let popout = windows.first(where: { $0.title == Self.programWindowTitle }),
                  let studioWindow = windows.first(where: { $0.title != Self.programWindowTitle && $0.canBecomeMain && $0.isVisible }),
                  let other = NSScreen.screens.first(where: { $0 != studioWindow.screen }) else { return }
            var frame = popout.frame
            let area = other.visibleFrame
            frame.size.width = min(max(frame.width, 960), area.width)
            frame.size.height = min(max(frame.height, 540), area.height)
            frame.origin = CGPoint(x: area.midX - frame.width / 2, y: area.midY - frame.height / 2)
            popout.setFrame(frame, display: true, animate: true)
        }
    }

    // MARK: - Persistence

    private static let settingsKey = "studio.settings.v3"
    private static let legacySettingsKey = "studio.settings.v2"

    private struct Snapshot: Codable {
        var destinations: [StreamDestination]
        var resolution: VideoResolution, frameRate: FrameRate, codec: VideoCodec
        var videoBitrateKbps: Double, keyFrameInterval: Double, audioBitrate: AudioBitrate
        var recordingFormat: RecordingFormat, recordingDirectory: URL, autoReconnect: Bool, showsCursor: Bool
        var audioSources: [AudioSourceConfig], monitorDeviceUID: String
        var scenes: [StudioScene], selectedSceneID: UUID?
    }

    /// The v2 fields worth keeping. Its scenes and audio defaults are dropped on purpose:
    /// v3 starts with no sources, so nothing is captured until the user adds it.
    private struct LegacySnapshot: Codable {
        var service: StreamingService, serverURL: String, resolution: VideoResolution, frameRate: FrameRate
        var codec: VideoCodec, videoBitrateKbps: Double, keyFrameInterval: Double, audioBitrate: AudioBitrate
        var recordingFormat: RecordingFormat, recordingDirectory: URL, autoReconnect: Bool, showsCursor: Bool
    }

    private func save() {
        guard !isLoading else { return }
        let snapshot = Snapshot(destinations: destinations, resolution: resolution, frameRate: frameRate, codec: codec,
                                videoBitrateKbps: videoBitrateKbps, keyFrameInterval: keyFrameInterval,
                                audioBitrate: audioBitrate, recordingFormat: recordingFormat,
                                recordingDirectory: recordingDirectory, autoReconnect: autoReconnect,
                                showsCursor: showsCursor, audioSources: audioSources, monitorDeviceUID: monitorDeviceUID,
                                scenes: scenes, selectedSceneID: selectedSceneID)
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Self.settingsKey)
        }
    }

    private func load() {
        if let data = defaults.data(forKey: Self.settingsKey),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            destinations = snapshot.destinations
            resolution = snapshot.resolution
            frameRate = snapshot.frameRate
            codec = snapshot.codec
            videoBitrateKbps = snapshot.videoBitrateKbps
            keyFrameInterval = snapshot.keyFrameInterval
            audioBitrate = snapshot.audioBitrate
            recordingFormat = snapshot.recordingFormat
            recordingDirectory = Self.migratedRecordingDirectory(snapshot.recordingDirectory)
            autoReconnect = snapshot.autoReconnect
            showsCursor = snapshot.showsCursor
            audioSources = snapshot.audioSources
            monitorDeviceUID = snapshot.monitorDeviceUID
            scenes = snapshot.scenes
            selectedSceneID = snapshot.selectedSceneID
            return
        }
        guard let data = defaults.data(forKey: Self.legacySettingsKey),
              let legacy = try? JSONDecoder().decode(LegacySnapshot.self, from: data) else { return }
        let destination = StreamDestination(name: legacy.service.title, service: legacy.service, serverURL: legacy.serverURL)
        let oldKey = KeychainStore.streamKey(for: legacy.service.rawValue)
        if !oldKey.isEmpty { KeychainStore.setStreamKey(oldKey, for: destination.keychainAccount) }
        destinations = [destination]
        resolution = legacy.resolution
        frameRate = legacy.frameRate
        codec = legacy.codec
        videoBitrateKbps = legacy.videoBitrateKbps
        keyFrameInterval = legacy.keyFrameInterval
        audioBitrate = legacy.audioBitrate
        recordingFormat = legacy.recordingFormat
        recordingDirectory = Self.migratedRecordingDirectory(legacy.recordingDirectory)
        autoReconnect = legacy.autoReconnect
        showsCursor = legacy.showsCursor
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
