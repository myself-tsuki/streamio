//
//  ContentView.swift
//  Streamio
//

import SwiftUI

struct ContentView: View {
    @StateObject private var streamManager = StreamManager()
    @State private var isShowingStreamKey: Bool = false
    @State private var activeTab: SidebarTab = .stream

    enum SidebarTab: String, CaseIterable, Identifiable {
        case stream = "Broadcast"
        case devices = "Devices"
        case video = "Output"
        case filters = "Metal FX"

        var id: String { rawValue }

        var iconName: String {
            switch self {
            case .stream: return "antenna.radiowaves.left.and.right"
            case .devices: return "video.badge.waveform"
            case .video: return "slider.horizontal.3"
            case .filters: return "camera.filters"
            }
        }
    }

    var body: some View {
        HSplitView {
            // MARK: - Left Area: Live Metal Preview & Broadcast Deck
            VStack(spacing: 0) {
                // Video Preview Area
                ZStack {
                    Color.black

                    MetalPreviewView(
                        filter: streamManager.selectedFilter,
                        filterParams: streamManager.filterParams,
                        previewRendererDelegate: streamManager
                    )
                    .aspectRatio(16/9, contentMode: .fit)

                    // Top Status Overlay
                    VStack {
                        HStack {
                            LiveBadgeView(streamManager: streamManager)
                            Spacer()
                            // Current Active Filter Pill
                            HStack(spacing: 5) {
                                Image(systemName: streamManager.selectedFilter.iconName)
                                Text(streamManager.selectedFilter.rawValue)
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Material.ultraThinMaterial)
                            .clipShape(Capsule())
                        }
                        .padding(14)
                        Spacer()
                    }

                    // Error Banner if needed
                    if case .error(let errorMsg) = streamManager.streamStatus {
                        VStack {
                            Spacer()
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.yellow)
                                Text(errorMsg)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.white)
                                Spacer()
                            }
                            .padding(10)
                            .background(Color.red.opacity(0.85))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .padding(14)
                        }
                    }
                }
                .frame(minWidth: 640, minHeight: 360)

                Divider()

                // Bottom Broadcast Control Bar
                HStack(spacing: 16) {
                    // Go Live Button
                    Button(action: {
                        streamManager.toggleStreaming()
                    }) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(streamManager.streamStatus.isLive ? Color.white : Color.red)
                                .frame(width: 10, height: 10)
                            Text(streamManager.streamStatus.isLive ? "END STREAM" : "GO LIVE")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(streamManager.streamStatus.isLive ? .red : .accentColor)

                    // Simultaneous Record Button
                    Button(action: {
                        streamManager.toggleRecording()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: streamManager.isRecording ? "stop.circle.fill" : "record.circle")
                                .foregroundColor(streamManager.isRecording ? .red : .primary)
                            Text(streamManager.isRecording ? "STOP REC" : "RECORD")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)

                    // Open Recordings Folder
                    Button(action: {
                        streamManager.openRecordingsFolder()
                    }) {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("Open Recordings Folder")

                    Divider().frame(height: 24)

                    // Mute / Audio Control
                    Button(action: {
                        streamManager.isAudioMuted.toggle()
                    }) {
                        Image(systemName: streamManager.isAudioMuted ? "mic.slash.fill" : "mic.fill")
                            .foregroundColor(streamManager.isAudioMuted ? .red : .primary)
                    }
                    .buttonStyle(.borderless)
                    .help(streamManager.isAudioMuted ? "Unmute Microphone" : "Mute Microphone")

                    // Live VU Meter
                    AudioVUMeterView(
                        levelLeftDb: streamManager.stats.audioLevelLeft,
                        levelRightDb: streamManager.stats.audioLevelRight,
                        isMuted: streamManager.isAudioMuted
                    )
                    .frame(width: 120)

                    Spacer()

                    // Quick Device Labels
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(streamManager.deviceManager.availableVideoDevices.first(where: { $0.id == streamManager.deviceManager.selectedVideoDeviceId })?.name ?? "No Camera")
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                        Text("\(streamManager.selectedResolution.dimensions.width)x\(streamManager.selectedResolution.dimensions.height) @ \(streamManager.selectedFrameRate.rawValue)fps")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Material.bar)
            }

            // MARK: - Right Area: Studio Inspector & Controls
            VStack(spacing: 0) {
                // Section Picker Tabs
                Picker("", selection: $activeTab) {
                    ForEach(SidebarTab.allCases) { tab in
                        Label(tab.rawValue, systemImage: tab.iconName).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(12)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch activeTab {
                        case .stream:
                            streamConfigSection
                        case .devices:
                            devicesConfigSection
                        case .video:
                            outputConfigSection
                        case .filters:
                            metalFiltersSection
                        }
                    }
                    .padding(16)
                }
            }
            .frame(minWidth: 320, idealWidth: 340, maxWidth: 420)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 960, minHeight: 600)
    }

    // MARK: - Broadcast / RTMP Section
    private var streamConfigSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("YouTube RTMP Destination", systemImage: "antenna.radiowaves.left.and.right")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("RTMP Server URL")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("Server URL", text: $streamManager.rtmpServerUrl)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("YouTube Stream Key")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(action: { isShowingStreamKey.toggle() }) {
                        Image(systemName: isShowingStreamKey ? "eye.slash" : "eye")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                }

                if isShowingStreamKey {
                    TextField("Enter Stream Key", text: $streamManager.streamKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                } else {
                    SecureField("Enter Stream Key", text: $streamManager.streamKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Broadcast Status")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Text("Connection:")
                        .font(.subheadline)
                    Spacer()
                    Text(streamManager.streamStatus.label)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(streamManager.streamStatus.isLive ? .green : .secondary)
                }

                HStack {
                    Text("Data Transferred:")
                        .font(.subheadline)
                    Spacer()
                    Text(formatBytes(streamManager.stats.streamedBytes))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Current Bitrate:")
                        .font(.subheadline)
                    Spacer()
                    Text(String(format: "%.0f kbps", streamManager.stats.outputBitrateKbps))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            .padding(10)
            .background(Color.black.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Simultaneous Recording")
                    .font(.headline)

                HStack {
                    Text("Status:")
                        .font(.subheadline)
                    Spacer()
                    Text(streamManager.isRecording ? "Recording Active" : "Stopped")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(streamManager.isRecording ? .red : .secondary)
                }

                if streamManager.isRecording {
                    HStack {
                        Text("Duration:")
                            .font(.subheadline)
                        Spacer()
                        Text(String(format: "%.0fs", streamManager.stats.recordingDuration))
                            .font(.system(size: 12, design: .monospaced))
                    }
                    HStack {
                        Text("File Size:")
                            .font(.subheadline)
                        Spacer()
                        Text(formatBytes(streamManager.stats.recordedBytes))
                            .font(.system(size: 12, design: .monospaced))
                    }
                }
            }
            .padding(10)
            .background(Color.black.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Hardware Devices Section
    private var devicesConfigSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Hardware Devices", systemImage: "video.badge.waveform")
                    .font(.headline)
                Spacer()
                Button(action: {
                    streamManager.deviceManager.refreshDevices()
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh connected devices")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Video Input (Camera)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Picker("", selection: $streamManager.selectedVideoDeviceId) {
                    if streamManager.deviceManager.availableVideoDevices.isEmpty {
                        Text("No cameras found").tag("")
                    } else {
                        ForEach(streamManager.deviceManager.availableVideoDevices) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                }
                .pickerStyle(.menu)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Audio Input (Microphone)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Picker("", selection: $streamManager.selectedAudioDeviceId) {
                    if streamManager.deviceManager.availableAudioDevices.isEmpty {
                        Text("No microphones found").tag("")
                    } else {
                        ForEach(streamManager.deviceManager.availableAudioDevices) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                }
                .pickerStyle(.menu)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Live Audio Monitoring")
                    .font(.caption)
                    .foregroundColor(.secondary)

                AudioVUMeterView(
                    levelLeftDb: streamManager.stats.audioLevelLeft,
                    levelRightDb: streamManager.stats.audioLevelRight,
                    isMuted: streamManager.isAudioMuted
                )
                .frame(height: 24)

                HStack {
                    Text(String(format: "L: %.1f dB", streamManager.stats.audioLevelLeft))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "R: %.1f dB", streamManager.stats.audioLevelRight))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            .padding(10)
            .background(Color.black.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Output & Encoding Section
    private var outputConfigSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Encoding & Output Settings", systemImage: "slider.horizontal.3")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Resolution")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("", selection: $streamManager.selectedResolution) {
                    ForEach(VideoResolution.allCases) { res in
                        Text(res.rawValue).tag(res)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: streamManager.selectedResolution) { _, _ in
                    streamManager.reconfigureCaptureDevices()
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Framerate")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("", selection: $streamManager.selectedFrameRate) {
                    ForEach(FrameRate.allCases) { rate in
                        Text(rate.label).tag(rate)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: streamManager.selectedFrameRate) { _, _ in
                    streamManager.reconfigureCaptureDevices()
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Video Codec")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("", selection: $streamManager.selectedVideoCodec) {
                    ForEach(VideoCodec.allCases) { codec in
                        Text(codec.rawValue).tag(codec)
                    }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Video Bitrate")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(streamManager.videoBitrate / 1000) kbps")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                }
                Slider(
                    value: Binding(
                        get: { Double(streamManager.videoBitrate) },
                        set: { streamManager.videoBitrate = Int($0) }
                    ),
                    in: 1_000_000...15_000_000,
                    step: 250_000
                )
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Audio Bitrate")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("", selection: $streamManager.selectedAudioBitrate) {
                    ForEach(AudioBitrate.allCases) { rate in
                        Text(rate.label).tag(rate)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    // MARK: - Metal Filters Section
    private var metalFiltersSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Metal Shading FX & Filters", systemImage: "camera.filters")
                .font(.headline)

            Text("Active Filter Preset")
                .font(.caption)
                .foregroundColor(.secondary)

            // Grid of Filter Presets
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(FilterType.allCases) { filter in
                    Button(action: {
                        streamManager.selectedFilter = filter
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: filter.iconName)
                            Text(filter.rawValue)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(streamManager.selectedFilter == filter ? Color.accentColor.opacity(0.3) : Color.black.opacity(0.15))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(streamManager.selectedFilter == filter ? Color.accentColor : Color.clear, lineWidth: 1.5)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            // Real-time Metal parameter sliders
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Filter Intensity")
                        .font(.caption)
                    Spacer()
                    Text(String(format: "%.0f%%", streamManager.filterParams.filterIntensity * 100))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Slider(value: $streamManager.filterParams.filterIntensity, in: 0.0...1.0)

                HStack {
                    Text("Brightness")
                        .font(.caption)
                    Spacer()
                    Text(String(format: "%+.0f%%", streamManager.filterParams.brightness * 100))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Slider(value: $streamManager.filterParams.brightness, in: -0.5...0.5)

                HStack {
                    Text("Contrast")
                        .font(.caption)
                    Spacer()
                    Text(String(format: "%.2fx", streamManager.filterParams.contrast))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Slider(value: $streamManager.filterParams.contrast, in: 0.5...2.0)

                HStack {
                    Text("Saturation")
                        .font(.caption)
                    Spacer()
                    Text(String(format: "%.2fx", streamManager.filterParams.saturation))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Slider(value: $streamManager.filterParams.saturation, in: 0.0...2.0)

                Button("Reset Adjustments") {
                    streamManager.filterParams = FilterParameters()
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .padding(.top, 4)
            }
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
