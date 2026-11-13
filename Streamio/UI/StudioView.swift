//
//  StudioView.swift
//  Streamio
//
//  Root window, laid out like OBS Studio: scenes and sources in the left sidebar, the program
//  preview on top with the audio mixer under it, broadcast controls, destinations and source
//  properties on the right, and live stats along the foot. Fullscreen mode shows only the
//  program output with the stats bar floating over it.
//

import SwiftUI

struct StudioView: View {
    @Environment(StudioController.self) private var studio
    @State private var showsSidebar = true

    var body: some View {
        Group {
            if studio.isFullscreenPreview {
                FullscreenProgramView()
            } else {
                studioLayout
            }
        }
        .frame(minWidth: 1180, minHeight: 760)
        .alert("Streamio", isPresented: Binding(get: { studio.alertMessage != nil }, set: { if !$0 { studio.alertMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(studio.alertMessage ?? "")
        }
    }

    private var studioLayout: some View {
        VStack(spacing: Theme.spacingM) {
            GlassEffectContainer(spacing: Theme.spacingM) {
                HStack(alignment: .top, spacing: Theme.spacingM) {
                    if showsSidebar {
                        VStack(spacing: Theme.spacingM) {
                            ScenesDock()
                                .frame(minHeight: 120, idealHeight: 140, maxHeight: 160)
                            SourcesDock()
                                .frame(maxHeight: .infinity)
                                .layoutPriority(1)
                        }
                        .frame(width: Theme.sidebarWidth)
                        .frame(maxHeight: .infinity)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    }

                    VStack(spacing: Theme.spacingM) {
                        PreviewPane()
                            .layoutPriority(1)
                        AudioMixerDock()
                            .frame(height: Theme.mixerHeight)
                    }
                    .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)

                    VStack(spacing: Theme.spacingM) {
                        ControlsDock()
                            .fixedSize(horizontal: false, vertical: true)
                        DestinationsDock()
                            .fixedSize(horizontal: false, vertical: true)
                        SourcePropertiesDock()
                            .frame(maxHeight: .infinity)
                    }
                    .frame(width: Theme.controlsWidth)
                    .frame(maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            StudioStatusBar()
        }
        .padding(Theme.spacingM)
        .containerBackground(.ultraThinMaterial, for: .window)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .navigationTitle(studio.selectedScene?.name ?? "Streamio")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(showsSidebar ? "Hide Scenes and Sources" : "Show Scenes and Sources", systemImage: "sidebar.leading") {
                    withAnimation(.smooth(duration: 0.25)) { showsSidebar.toggle() }
                }
                .help("Show or hide the Scenes and Sources sidebar")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Fullscreen Preview", systemImage: "arrow.up.left.and.arrow.down.right") {
                    studio.setFullscreenPreview(true)
                }
                .help("Show only the program output, full screen (⇧⌘F)")
            }
        }
    }
}

// MARK: - Program preview

struct PreviewPane: View {
    @Environment(StudioController.self) private var studio

    var body: some View {
        ProgramView(cornerRadius: Theme.previewRadius) { studio.setFullscreenPreview(true) }
            .overlay {
                if let scene = studio.selectedScene, !scene.sources.contains(where: \.isVisible) {
                    VStack(spacing: Theme.spacingM) {
                        ContentUnavailableView(
                            scene.sources.isEmpty ? "This scene has no sources" : "Every source is hidden",
                            systemImage: "rectangle.dashed",
                            description: Text(scene.sources.isEmpty
                                ? "Add a camera, display or image from the Sources dock in the sidebar."
                                : "Show a source with its eye button in the Sources dock.")
                        )
                        if scene.sources.isEmpty {
                            AddSourceMenu(showsTitle: true)
                                .buttonStyle(.glass)
                                .fixedSize()
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(Theme.spacingL)
                }
            }
            .overlay(alignment: .topLeading) { OnAirBadges().padding(Theme.spacingM) }
            .overlay(alignment: .bottomLeading) { SourceWarnings().padding(Theme.spacingM) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The program output, letterboxed at the canvas aspect ratio.
struct ProgramView: View {
    @Environment(StudioController.self) private var studio
    var cornerRadius: CGFloat
    var onDoubleClick: () -> Void

    var body: some View {
        MetalPreviewView(store: studio.previewStore, fps: studio.frameRate.rawValue)
            .aspectRatio(CGFloat(studio.resolution.width) / CGFloat(studio.resolution.height), contentMode: .fit)
            .background(.black, in: .rect(cornerRadius: cornerRadius))
            .clipShape(.rect(cornerRadius: cornerRadius))
            .overlay {
                // The Metal view is AppKit; a SwiftUI layer on top catches the double-click.
                Color.clear
                    .contentShape(.rect)
                    .onTapGesture(count: 2, perform: onDoubleClick)
            }
    }
}

/// Names any source whose device is unplugged. Streamio waits for that exact device
/// instead of switching to another one.
struct SourceWarnings: View {
    @Environment(StudioController.self) private var studio

    var body: some View {
        let missing = (studio.selectedScene?.sources ?? []).filter { $0.isVisible && !studio.devices.isConnected($0.input) }
        let micMissing = studio.isAudioDeviceMissing(.microphone)
        if !missing.isEmpty || micMissing {
            VStack(alignment: .leading, spacing: Theme.spacingXS) {
                ForEach(missing) { source in
                    Label("\(source.name) is disconnected. Waiting for this device.", systemImage: "exclamationmark.triangle.fill")
                }
                if micMissing {
                    Label("\(studio.audioTitle(.microphone)) is disconnected. Waiting for this device.", systemImage: "mic.slash.fill")
                }
            }
            .font(.callout)
            .padding(.horizontal, Theme.spacingM)
            .padding(.vertical, Theme.spacingS)
            .glassEffect(.regular.tint(Theme.warning.opacity(0.35)), in: .rect(cornerRadius: Theme.rowRadius + 4))
        }
    }
}

struct OnAirBadges: View {
    @Environment(StudioController.self) private var studio

    var body: some View {
        GlassEffectContainer(spacing: Theme.spacingS) {
            HStack(spacing: Theme.spacingS) {
                if studio.streamStatus.isActive {
                    Label(studio.streamStatus.label, systemImage: "dot.radiowaves.left.and.right")
                        .padding(.horizontal, Theme.spacingM).padding(.vertical, Theme.spacingXS)
                        .glassEffect(.regular.tint(Theme.live.opacity(studio.streamStatus.isLive ? 0.6 : 0.25)), in: .capsule)
                }
                if studio.isRecording {
                    Label("REC", systemImage: "record.circle")
                        .padding(.horizontal, Theme.spacingM).padding(.vertical, Theme.spacingXS)
                        .glassEffect(.regular.tint(Theme.live.opacity(0.45)), in: .capsule)
                }
            }
            .font(.callout.bold())
        }
    }
}

// MARK: - Fullscreen

struct FullscreenProgramView: View {
    @Environment(StudioController.self) private var studio
    @FocusState private var isFocused: Bool

    var body: some View {
        @Bindable var studio = studio
        ZStack {
            Color.black.ignoresSafeArea()
            ProgramView(cornerRadius: 0) { studio.setFullscreenPreview(false) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
        }
        .overlay(alignment: .topLeading) { OnAirBadges().padding(Theme.spacingL) }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: Theme.spacingS) {
                Button(studio.showsStatsOverlay ? "Hide Stats" : "Show Stats", systemImage: "chart.bar.xaxis") {
                    studio.showsStatsOverlay.toggle()
                }
                .help("Show or hide the stats bar (I)")
                Button("Exit Fullscreen", systemImage: "arrow.down.right.and.arrow.up.left") {
                    studio.setFullscreenPreview(false)
                }
                .help("Exit fullscreen (Esc)")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .controlSize(.large)
            .padding(Theme.spacingL)
        }
        .overlay(alignment: .bottom) {
            if studio.showsStatsOverlay {
                StatsBar(style: .overlay)
                    .padding(Theme.spacingL)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: studio.showsStatsOverlay)
        .environment(\.colorScheme, .dark)
        .toolbar(.hidden, for: .windowToolbar)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onExitCommand { studio.setFullscreenPreview(false) }
        .onKeyPress("i") {
            studio.showsStatsOverlay.toggle()
            return .handled
        }
    }
}

// MARK: - Stats

struct StudioStatusBar: View {
    var body: some View {
        StatsBar(style: .statusBar)
    }
}

/// Live figures shown at the foot of the studio and over the fullscreen program:
/// stream and recording timers, output and camera FPS, render time, CPU, GPU, memory,
/// total and per-destination bitrate, dropped frames and free disk space.
struct StatsBar: View {
    enum Style { case statusBar, overlay }

    @Environment(StudioController.self) private var studio
    let style: Style

    var body: some View {
        let stats = studio.stats
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: Theme.spacingL) {
                metric(studio.streamStatus.isLive ? "LIVE" : studio.streamStatus.label,
                       Duration.clock(since: stats.streamStart, now: context.date), "dot.radiowaves.left.and.right")
                    .foregroundStyle(studio.streamStatus.isLive ? Theme.live : .primary)
                metric("REC", Duration.clock(since: stats.recordStart, now: context.date), "record.circle")
                    .foregroundStyle(studio.isRecording ? Theme.live : .primary)
                Divider().frame(height: 14)
                metric("FPS", "\(String(format: "%.1f", stats.fps)) / \(studio.frameRate.rawValue)", "film")
                if studio.selectedScene?.cameraSource != nil {
                    metric("Camera", "\(String(format: "%.1f", stats.cameraFPS)) fps", "web.camera")
                }
                if style == .overlay {
                    metric("Render", "\(String(format: "%.1f", stats.renderMilliseconds)) ms", "timer")
                }
                Spacer(minLength: Theme.spacingS)
                metric("CPU", String(format: "%.1f%%", stats.cpuPercent), "cpu")
                metric("GPU", stats.gpuPercent.map { "\(Int($0))%" } ?? "—", "rectangle.3.group")
                metric("Memory", ByteCountFormatter.string(fromByteCount: Int64(stats.memoryBytes), countStyle: .memory), "memorychip")
                Divider().frame(height: 14)
                metric("Bitrate", "\(Int(stats.bitrateKbps)) kb/s", "speedometer")
                    .foregroundStyle(stats.congestion > 0.5 ? Theme.warning : .primary)
                if style == .overlay {
                    ForEach(studio.destinations.filter { studio.status(of: $0.id).isActive }) { destination in
                        metric(destination.name, "\(Int(stats.network[destination.id]?.bitrateKbps ?? 0)) kb/s",
                               studio.status(of: destination.id).systemImage)
                            .foregroundStyle(studio.status(of: destination.id).tint)
                    }
                }
                metric("Dropped", "\(stats.droppedFrames) (\(String(format: "%.1f", stats.droppedPercent))%)",
                       "exclamationmark.triangle")
                if style == .overlay, let free = stats.diskFreeBytes {
                    metric("Disk", "\(ByteCountFormatter.string(fromByteCount: Int64(free), countStyle: .file)) free", "internaldrive")
                }
            }
            .font(style == .overlay ? .body.monospacedDigit() : .callout.monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, Theme.spacingL)
        .padding(.vertical, style == .overlay ? Theme.spacingM : Theme.spacingS)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Studio statistics")
    }

    private func metric(_ title: String, _ value: String, _ symbol: String) -> some View {
        Label { Text("\(title) \(value)") } icon: { Image(systemName: symbol) }
            .accessibilityElement(children: .combine)
    }
}
