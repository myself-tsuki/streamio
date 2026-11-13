//
//  StudioView.swift
//  Streamio
//
//  Root window, laid out like OBS Studio: scenes and sources in the left sidebar, the program
//  preview on top with the audio mixer under it, broadcast controls, destinations and source
//  properties on the right, and a customizable stats bar along the foot. Fullscreen mode and
//  the pop-out window show the program output with widgets over it (see StudioStage).
//

import SwiftUI

struct StudioView: View {
    @Environment(StudioController.self) private var studio
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var showsSidebar = true
    @State private var showsCustomizer = false

    var body: some View {
        Group {
            if studio.isFullscreenPreview {
                StudioStage(mode: .fullscreen)
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
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Customize Widgets", systemImage: "slider.horizontal.3") { showsCustomizer.toggle() }
                    .popover(isPresented: $showsCustomizer, arrowEdge: .bottom) {
                        WidgetCustomizer(initialTab: .bar).environment(studio)
                    }
                    .help("Choose what the bottom bar and the preview widgets show")
                Button(studio.isProgramPoppedOut ? "Bring Preview Back" : "Pop Out Preview",
                       systemImage: studio.isProgramPoppedOut ? "arrow.uturn.backward" : "rectangle.on.rectangle") {
                    if studio.isProgramPoppedOut {
                        dismissWindow(id: "program")
                    } else {
                        openWindow(id: "program")
                        studio.moveProgramWindowToOtherScreen()
                    }
                }
                .help(studio.isProgramPoppedOut ? "Put the preview back in this window"
                                                : "Open the program output in its own window, for a second display")
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
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        if studio.isProgramPoppedOut {
            poppedOutPlaceholder
        } else {
            programPane
        }
    }

    /// The video is in its own window; this is the way back.
    private var poppedOutPlaceholder: some View {
        VStack(spacing: Theme.spacingM) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("The preview is in its own window")
                .font(.title3.weight(.semibold))
            Button("Bring Preview Back", systemImage: "arrow.uturn.backward") {
                dismissWindow(id: "program")
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.previewRadius))
    }

    private var programPane: some View {
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
        let missingInputs = StudioController.inputChannels.filter { studio.isAudioDeviceMissing($0) }
        let micMissing = !missingInputs.isEmpty
        if !missing.isEmpty || micMissing || studio.captureNotice != nil {
            VStack(alignment: .leading, spacing: Theme.spacingXS) {
                ForEach(missing) { source in
                    Label("\(source.name) is disconnected. Waiting for this device.", systemImage: "exclamationmark.triangle.fill")
                }
                ForEach(missingInputs) { channel in
                    Label("\(studio.audioTitle(channel)) is disconnected. Waiting for this device.", systemImage: "mic.slash.fill")
                }
                if !missing.isEmpty || micMissing, studio.isOutputActive {
                    Text("The broadcast keeps running and shows \u{201C}No signal\u{201D} until the device is back.")
                        .font(.footnote)
                } else if let notice = studio.captureNotice {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
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

// MARK: - Stats

struct StudioStatusBar: View {
    @Environment(StudioController.self) private var studio

    var body: some View {
        if studio.widgets.showsBar {
            StatsBar(style: .statusBar)
        }
    }
}

/// The customizable bar of live figures at the foot of the studio and over the fullscreen
/// and pop-out program. It holds whichever widgets the user picked, as small labels,
/// big-number tiles or speedometers (see WidgetLayout). Right-click to hide it.
struct StatsBar: View {
    enum Style { case statusBar, overlay }

    @Environment(StudioController.self) private var studio
    let style: Style

    var body: some View {
        let items = studio.widgets.bar.filter { widget in
            // A camera counter means nothing without a camera in the scene.
            widget.metric != .cameraFPS || studio.selectedScene?.cameraSource != nil
        }
        let hasTiles = items.contains { $0.style != .label }
        let radius: CGFloat = hasTiles ? 28 : 100

        ScrollView(.horizontal) {
            HStack(spacing: Theme.spacingL) {
                if items.isEmpty {
                    Text("Bar is empty. Add widgets with Customize Widgets.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(items) { widget in
                    StatWidgetFace(widget: widget, unit: Self.tileHeight, chrome: false)
                        .frame(width: width(of: widget), height: height(of: widget))
                }
            }
            .padding(.horizontal, Theme.spacingL)
            .padding(.vertical, hasTiles ? Theme.spacingS : (style == .overlay ? Theme.spacingM : Theme.spacingS))
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .center)
        }
        .scrollIndicators(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .glassEffect(.regular, in: .rect(cornerRadius: radius))
        .contextMenu {
            Button("Hide Bottom Bar") { studio.widgets.showsBar = false }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Studio statistics")
    }

    private static let tileHeight: CGFloat = 52
    private static let gaugeSide: CGFloat = 124

    private func width(of widget: StatWidget) -> CGFloat? {
        switch widget.style {
        case .label: nil
        case .number: 132
        case .graph: 132
        case .gauge: widget.metric.supportsGauge ? Self.gaugeSide : 132
        }
    }

    private func height(of widget: StatWidget) -> CGFloat? {
        switch widget.style {
        case .label: nil
        case .number, .graph: Self.tileHeight
        case .gauge: widget.metric.supportsGauge ? Self.gaugeSide : Self.tileHeight
        }
    }
}
