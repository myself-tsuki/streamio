//
//  StudioView.swift
//  Streamio
//
//  Root window: program preview on top, OBS-style docks below, live status bar at the foot,
//  scene properties in a native inspector. The window background is a behind-window blur,
//  so the desktop shows through the glass.
//

import SwiftUI

struct StudioView: View {
    @Environment(StudioController.self) private var studio
    @State private var showsInspector = true

    var body: some View {
        @Bindable var studio = studio
        VStack(spacing: Theme.spacingM) {
            PreviewPane()
                .layoutPriority(1)
            GlassEffectContainer(spacing: Theme.spacingM) {
                HStack(spacing: Theme.spacingM) {
                    ScenesDock()
                    SourcesDock()
                    AudioMixerDock()
                        .frame(minWidth: 300)
                    ControlsDock()
                }
                .frame(height: Theme.dockHeight)
            }
            StudioStatusBar()
        }
        .padding(Theme.spacingM)
        .frame(minWidth: 1100, minHeight: 720)
        .containerBackground(.ultraThinMaterial, for: .window)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .navigationTitle(studio.selectedScene?.name ?? "Streamio")
        .inspector(isPresented: $showsInspector) {
            SceneInspector()
                .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Scene Properties", systemImage: "sidebar.trailing") { showsInspector.toggle() }
            }
        }
        .alert("Streamio", isPresented: Binding(get: { studio.alertMessage != nil }, set: { if !$0 { studio.alertMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(studio.alertMessage ?? "")
        }
    }
}

struct PreviewPane: View {
    @Environment(StudioController.self) private var studio

    var body: some View {
        ZStack(alignment: .topLeading) {
            MetalPreviewView(store: studio.previewStore, fps: studio.frameRate.rawValue)
                .aspectRatio(CGFloat(studio.resolution.width) / CGFloat(studio.resolution.height), contentMode: .fit)
                .background(.black, in: .rect(cornerRadius: Theme.previewRadius))
                .clipShape(.rect(cornerRadius: Theme.previewRadius))
                .overlay {
                    if studio.selectedScene?.videoSource == VideoSource.none {
                        ContentUnavailableView("No Video Source", systemImage: "rectangle.dashed",
                                               description: Text("Add a camera or display from the Sources dock."))
                            .foregroundStyle(.white)
                    }
                }
                .overlay(alignment: .topLeading) { OnAirBadges().padding(Theme.spacingM) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

struct StudioStatusBar: View {
    @Environment(StudioController.self) private var studio

    var body: some View {
        let stats = studio.stats
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: Theme.spacingL) {
                metric("Dropped", "\(stats.droppedFrames) (\(stats.droppedPercent, format: .number.precision(.fractionLength(1)))%)", "exclamationmark.triangle")
                Divider()
                metric(studio.streamStatus.isLive ? "LIVE" : studio.streamStatus.label,
                       Duration.clock(since: stats.streamStart, now: context.date), "dot.radiowaves.left.and.right")
                    .foregroundStyle(studio.streamStatus.isLive ? Theme.live : .primary)
                metric("REC", Duration.clock(since: stats.recordStart, now: context.date), "record.circle")
                    .foregroundStyle(studio.isRecording ? Theme.live : .primary)
                Spacer()
                metric("CPU", "\(stats.cpuPercent, format: .number.precision(.fractionLength(1)))%", "cpu")
                metric("GPU", stats.gpuPercent.map { "\(Int($0))%" } ?? "—", "rectangle.3.group")
                metric("Memory", stats.memoryBytes.formatted(.byteCount(style: .memory)), "memorychip")
                metric("FPS", "\(stats.fps, format: .number.precision(.fractionLength(2))) / \(studio.frameRate.rawValue)", "film")
                metric("Bitrate", "\(Int(stats.bitrateKbps)) kb/s", "speedometer")
                    .foregroundStyle(stats.congestion > 0.5 ? Color.yellow : .primary)
            }
            .font(.callout.monospacedDigit())
            .lineLimit(1)
        }
        .padding(.horizontal, Theme.spacingL)
        .padding(.vertical, Theme.spacingS)
        .glassEffect(.regular, in: .capsule)
    }

    private func metric(_ title: String, _ value: String, _ symbol: String) -> some View {
        Label { Text("\(title) \(value)") } icon: { Image(systemName: symbol) }
            .accessibilityElement(children: .combine)
    }
}

struct SceneInspector: View {
    @Environment(StudioController.self) private var studio

    var body: some View {
        @Bindable var studio = studio
        if let scene = studio.selectedScene {
            let binding = Binding<StudioScene>(get: { scene }, set: { studio.selectedScene = $0 })
            Form {
                Section("Scene") {
                    TextField("Name", text: binding.name)
                    Toggle("Show Video", isOn: binding.isVideoVisible)
                }
                Section("Filter") {
                    Picker("Filter", selection: binding.filter) {
                        ForEach(FilterType.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                    }
                    adjustment("Intensity", binding.adjustments.intensity, 0...1, neutral: 1)
                }
                Section("Colour") {
                    adjustment("Brightness", binding.adjustments.brightness, -0.5...0.5, neutral: 0)
                    adjustment("Contrast", binding.adjustments.contrast, 0.5...2, neutral: 1)
                    adjustment("Saturation", binding.adjustments.saturation, 0...2, neutral: 1)
                    Button("Reset Adjustments") { binding.wrappedValue.adjustments = FilterParameters() }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        } else {
            ContentUnavailableView("No Scene Selected", systemImage: "square.stack")
        }
    }

    private func adjustment(_ title: LocalizedStringKey, _ value: Binding<Float>, _ range: ClosedRange<Float>, neutral: Float) -> some View {
        LabeledContent(title) {
            Slider(value: value, in: range) { Text(title) } ticks: {
                SliderTick(value: neutral)
            }
            .sliderNeutralValue(neutral)
            .labelsHidden()
        }
    }
}
