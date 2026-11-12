//
//  StudioDocks.swift
//  Streamio
//
//  Left sidebar: Scenes and Sources. Right column: Controls, Destinations and Source
//  Properties. The Audio Mixer lives in MixerDock.swift, under the preview.
//

import SwiftUI

// MARK: - Scenes

struct ScenesDock: View {
    @Environment(StudioController.self) private var studio
    @State private var renaming: StudioScene?
    @State private var newName = ""

    var body: some View {
        @Bindable var studio = studio
        DockPanel(title: "Scenes") {
            List(selection: $studio.selectedSceneID) {
                ForEach(Array(studio.scenes.enumerated()), id: \.element.id) { index, scene in
                    HStack {
                        Label(scene.name, systemImage: scene.systemImage)
                            .lineLimit(1)
                        Spacer()
                        if index < 9 {
                            Text("⌘\(index + 1)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Shortcut Command \(index + 1)")
                        }
                    }
                    .tag(scene.id)
                    .contextMenu {
                        Button("Rename…") { beginRename(scene) }
                        Button("Duplicate") { studio.duplicate(scene) }
                        Divider()
                        Button("Delete", role: .destructive) { studio.remove(scene) }
                            .disabled(studio.scenes.count < 2)
                    }
                }
                .onMove { studio.moveScenes(from: $0, to: $1) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        } accessory: {
            Button("Add Scene", systemImage: "plus", action: studio.addScene)
                .help("Add scene")
            Button("Remove Scene", systemImage: "minus", action: removeSelected)
                .disabled(studio.scenes.count < 2)
                .help("Remove the selected scene")
        }
        .alert("Rename Scene", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename", action: commitRename)
            Button("Cancel", role: .cancel) {}
        }
    }

    private func beginRename(_ scene: StudioScene) {
        newName = scene.name
        renaming = scene
    }

    private func commitRename() {
        if let scene = renaming { studio.rename(scene, to: newName) }
    }

    private func removeSelected() {
        if let scene = studio.selectedScene { studio.remove(scene) }
    }
}

// MARK: - Sources

struct SourcesDock: View {
    @Environment(StudioController.self) private var studio

    var body: some View {
        @Bindable var studio = studio
        let sources = studio.selectedScene?.sources ?? []
        DockPanel(title: "Sources") {
            if sources.isEmpty {
                VStack(spacing: Theme.spacingS) {
                    Image(systemName: "plus.rectangle.on.rectangle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No sources in this scene")
                        .font(.subheadline.bold())
                    Text("Add a camera, display, image or audio input.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    AddSourceMenu(showsTitle: true)
                        .buttonStyle(.glass)
                        .fixedSize()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $studio.selectedSourceID) {
                    ForEach(sources) { source in
                        SourceRow(source: source)
                            .tag(source.id)
                            .contextMenu {
                                Button(source.isVisible ? "Hide" : "Show") { studio.toggleVisibility(source.id) }
                                Button("Move Up") { studio.moveSource(source.id, by: -1) }
                                    .disabled(sources.first?.id == source.id)
                                Button("Move Down") { studio.moveSource(source.id, by: 1) }
                                    .disabled(sources.last?.id == source.id)
                                Divider()
                                Button("Remove", role: .destructive) { studio.removeSource(source.id) }
                            }
                    }
                    .onMove { studio.moveSources(from: $0, to: $1) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onDeleteCommand {
                    if let id = studio.selectedSourceID { studio.removeSource(id) }
                }
            }
        } accessory: {
            AddSourceMenu(showsTitle: false)
            Button("Remove Source", systemImage: "minus") {
                if let id = studio.selectedSourceID { studio.removeSource(id) }
            }
            .disabled(studio.selectedSourceID == nil)
            .help("Remove the selected source")
            Button("Move Source Up", systemImage: "chevron.up") {
                if let id = studio.selectedSourceID { studio.moveSource(id, by: -1) }
            }
            .disabled(studio.selectedSourceID == nil || sources.first?.id == studio.selectedSourceID)
            .help("Move the selected source up a layer")
            Button("Move Source Down", systemImage: "chevron.down") {
                if let id = studio.selectedSourceID { studio.moveSource(id, by: 1) }
            }
            .disabled(studio.selectedSourceID == nil || sources.last?.id == studio.selectedSourceID)
            .help("Move the selected source down a layer")
        }
    }
}

struct SourceRow: View {
    @Environment(StudioController.self) private var studio
    let source: SceneSource

    var body: some View {
        let connected = studio.devices.isConnected(source.input)
        HStack(spacing: Theme.spacingS) {
            Image(systemName: source.input.systemImage)
                .frame(width: 20)
                .foregroundStyle(source.isVisible ? Color.primary : Color.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(source.name)
                    .lineLimit(1)
                    .foregroundStyle(source.isVisible ? Color.primary : Color.secondary)
                if !connected {
                    Label("Disconnected", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                } else if source.layout.isPictureInPicture {
                    Text("Picture in picture")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button(source.isVisible ? "Hide \(source.name)" : "Show \(source.name)",
                   systemImage: source.isVisible ? "eye" : "eye.slash") {
                studio.toggleVisibility(source.id)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .frame(minWidth: 24, minHeight: 24)
            .help(source.isVisible ? "Hide source" : "Show source")
        }
        .accessibilityElement(children: .combine)
    }
}

/// The "+" menu: video sources for the current scene and audio inputs for the mixer.
struct AddSourceMenu: View {
    @Environment(StudioController.self) private var studio
    let showsTitle: Bool

    var body: some View {
        Menu {
            Section("Video Capture Device") {
                if studio.devices.cameras.isEmpty {
                    Text("No cameras connected")
                }
                ForEach(studio.devices.cameras) { camera in
                    Button(camera.name) { studio.addSource(.camera(id: camera.id)) }
                        .disabled(!studio.canAdd(.camera(id: camera.id)))
                }
            }
            Section("Display Capture") {
                ForEach(studio.devices.displays) { display in
                    Button("\(display.name) (\(display.width)×\(display.height))") { studio.addSource(.display(id: display.id)) }
                        .disabled(!studio.canAdd(.display(id: display.id)))
                }
            }
            Button("Image…", systemImage: "photo") { studio.chooseImageSource() }
            Section("Audio") {
                AudioInputMenu()
                Button("Desktop Audio", systemImage: "speaker.wave.2") { studio.addDesktopAudio() }
                    .disabled(studio.audioSource(.desktop) != nil)
            }
        } label: {
            if showsTitle {
                Label("Add Source", systemImage: "plus").labelStyle(.titleAndIcon)
            } else {
                Label("Add Source", systemImage: "plus").labelStyle(.iconOnly)
            }
        }
        .menuIndicator(.hidden)
        .help("Add a source")
    }
}

/// Picks the one microphone the Mic/Aux channel records from.
struct AudioInputMenu: View {
    @Environment(StudioController.self) private var studio

    var body: some View {
        Menu("Audio Input Capture", systemImage: "mic") {
            if studio.devices.microphones.isEmpty {
                Text("No microphones connected")
            }
            ForEach(studio.devices.microphones) { microphone in
                Button {
                    studio.addMicrophone(deviceID: microphone.id)
                } label: {
                    if studio.audioSource(.microphone)?.deviceID == microphone.id {
                        Label(microphone.name, systemImage: "checkmark")
                    } else {
                        Text(microphone.name)
                    }
                }
            }
        }
    }
}

// MARK: - Controls

struct ControlsDock: View {
    @Environment(StudioController.self) private var studio

    var body: some View {
        let enabledCount = studio.destinations.filter(\.isEnabled).count
        DockPanel(title: "Controls") {
            VStack(spacing: Theme.spacingS) {
                Button(action: studio.toggleStreaming) {
                    VStack(spacing: 2) {
                        Label(studio.streamStatus.isActive ? "Stop Streaming" : "Start Streaming",
                              systemImage: studio.streamStatus.isActive ? "stop.fill" : "dot.radiowaves.left.and.right")
                        if !studio.streamStatus.isActive {
                            Text(enabledCount == 1 ? "to 1 destination" : "to \(enabledCount) destinations")
                                .font(.caption)
                                .opacity(0.85)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(studio.streamStatus.isActive ? Theme.live : .accentColor)

                Button(action: studio.toggleRecording) {
                    Label(studio.isRecording ? "Stop Recording" : "Start Recording",
                          systemImage: studio.isRecording ? "stop.circle.fill" : "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .tint(studio.isRecording ? Theme.live : nil)

                Button {
                    studio.setFullscreenPreview(true)
                } label: {
                    Label("Fullscreen Preview", systemImage: "arrow.up.left.and.arrow.down.right").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)

                HStack(spacing: Theme.spacingS) {
                    Button(action: studio.revealRecordings) {
                        Label("Recordings", systemImage: "folder").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .help("Show recordings in Finder")

                    SettingsLink {
                        Label("Settings", systemImage: "gearshape").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
            }
            .controlSize(.large)
        }
    }
}

// MARK: - Destinations (multistream)

struct DestinationsDock: View {
    @Environment(StudioController.self) private var studio

    var body: some View {
        DockPanel(title: "Destinations") {
            VStack(alignment: .leading, spacing: Theme.spacingS) {
                if studio.destinations.isEmpty {
                    Text("No destinations. Add YouTube, Facebook, Twitch or a custom RTMP server in Settings ▸ Stream.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(studio.destinations) { destination in
                    DestinationRow(destination: destination)
                }
                if studio.destinations.count > 1 {
                    Text("One encode is shared by every destination.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } accessory: {
            SettingsLink {
                Label("Manage Destinations", systemImage: "slider.horizontal.3")
            }
            .help("Add or edit destinations in Settings")
        }
    }
}

struct DestinationRow: View {
    @Environment(StudioController.self) private var studio
    let destination: StreamDestination

    var body: some View {
        let status = studio.status(of: destination.id)
        let enabled = Binding(
            get: { studio.destinations.first { $0.id == destination.id }?.isEnabled ?? false },
            set: { value in
                if let index = studio.destinations.firstIndex(where: { $0.id == destination.id }) {
                    studio.destinations[index].isEnabled = value
                }
            }
        )
        HStack(spacing: Theme.spacingS) {
            Toggle("Include \(destination.name) when going live", isOn: enabled)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(status.isActive)
            VStack(alignment: .leading, spacing: 1) {
                Text(destination.name)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                HStack(spacing: Theme.spacingXS) {
                    Image(systemName: status.systemImage)
                    Text(status.label)
                    if status.isLive, let network = studio.stats.network[destination.id] {
                        Text("· \(Int(network.bitrateKbps)) kb/s")
                            .monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(status == .idle ? Color.secondary : status.tint)
            }
            Spacer(minLength: 0)
            if studio.streamStatus.isActive || status.isActive {
                Button(status.isActive ? "Stop \(destination.name)" : "Go Live on \(destination.name)",
                       systemImage: status.isActive ? "stop.fill" : "play.fill") {
                    studio.toggleDestination(destination.id)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .frame(minWidth: 28, minHeight: 28)
                .help(status.isActive ? "Stop this destination only" : "Add this destination to the live stream")
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Source properties

struct SourcePropertiesDock: View {
    @Environment(StudioController.self) private var studio

    var body: some View {
        DockPanel(title: "Source Properties") {
            if let source = studio.selectedSource {
                SourcePropertiesForm(binding: Binding(get: { studio.selectedSource ?? source },
                                                      set: { studio.updateSource($0) }))
            } else {
                ContentUnavailableView("No Source Selected", systemImage: "cursorarrow.click.2",
                                       description: Text("Select a source in the sidebar to change its layout, filter and colour."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct SourcePropertiesForm: View {
    @Binding var binding: SceneSource

    init(binding: Binding<SceneSource>) {
        _binding = binding
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $binding.name)
                Toggle("Visible", isOn: $binding.isVisible)
            }
            Section("Transform") {
                Picker("Layout", selection: $binding.layout) {
                    ForEach(SourceLayout.allCases) { Text($0.title).tag($0) }
                }
                if binding.layout.isPictureInPicture {
                    LabeledContent("Size") {
                        Slider(value: $binding.pipScale, in: 0.1...0.6) { Text("Size") }
                            .labelsHidden()
                    }
                }
                Toggle("Mirror Horizontally", isOn: $binding.isMirrored)
                adjustment("Opacity", $binding.opacity, 0...1, neutral: 1)
            }
            Section("Filter") {
                Picker("Filter", selection: $binding.filter) {
                    ForEach(FilterType.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                }
                adjustment("Intensity", $binding.adjustments.intensity, 0...1, neutral: 1)
            }
            Section("Colour") {
                adjustment("Brightness", $binding.adjustments.brightness, -0.5...0.5, neutral: 0)
                adjustment("Contrast", $binding.adjustments.contrast, 0.5...2, neutral: 1)
                adjustment("Saturation", $binding.adjustments.saturation, 0...2, neutral: 1)
                Button("Reset Colour") { binding.adjustments = FilterParameters() }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding(.horizontal, -Theme.spacingM)
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
