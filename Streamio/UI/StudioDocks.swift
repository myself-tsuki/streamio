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
            ScrollView {
                LazyVStack(spacing: Theme.spacingXS) {
                    ForEach(Array(studio.scenes.enumerated()), id: \.element.id) { index, scene in
                        let isSelected = studio.selectedSceneID == scene.id
                        HStack {
                            Label(scene.name, systemImage: scene.systemImage)
                                .lineLimit(1)
                                .font(.body.weight(isSelected ? .semibold : .regular))
                            Spacer()
                            if index < 9 {
                                Text("⌘\(index + 1)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("Shortcut Command \(index + 1)")
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity)
                        .glassEffect(isSelected ? .regular.tint(Color.accentColor.opacity(0.35)) : .regular, in: .capsule)
                        .contentShape(.capsule)
                        .onTapGesture {
                            studio.selectedSceneID = scene.id
                        }
                        .contextMenu {
                            Button("Rename…") { beginRename(scene) }
                            Button("Duplicate") { studio.duplicate(scene) }
                            Divider()
                            Button("Delete", role: .destructive) { studio.remove(scene) }
                                .disabled(studio.scenes.count < 2)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.automatic)
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
                ScrollView {
                    LazyVStack(spacing: Theme.spacingS) {
                        ForEach(sources) { source in
                            let isSelected = studio.selectedSourceID == source.id
                            SourceRow(source: source, isSelected: isSelected)
                                .contentShape(.capsule)
                                .onTapGesture {
                                    studio.selectedSourceID = source.id
                                }
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
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.automatic)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    var isSelected: Bool = false

    var body: some View {
        let connected = studio.devices.isConnected(source.input)
        HStack(spacing: Theme.spacingS) {
            Image(systemName: source.input.systemImage)
                .frame(width: 20)
                .foregroundStyle(source.isVisible ? (isSelected ? Color.accentColor : Color.primary) : Color.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(source.name)
                    .lineLimit(1)
                    .font(.body.weight(isSelected ? .semibold : .regular))
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
        .padding(.horizontal, Theme.spacingM)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 38)
        .glassEffect(isSelected ? .regular.tint(Color.accentColor.opacity(0.35)) : .regular, in: .capsule)
        .contentShape(.capsule)
        .accessibilityElement(children: .combine)
    }
}

/// The "+" menu: video sources for the current scene and audio inputs for the mixer.
struct AddSourceMenu: View {
    @Environment(StudioController.self) private var studio
    let showsTitle: Bool

    var body: some View {
        Menu {
            Section("Camera (add a second one as a face cam)") {
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
            Button("Video File…", systemImage: "film") { studio.chooseVideoSource() }
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
        Menu("Audio Input Devices", systemImage: "mic") {
            if studio.devices.microphones.isEmpty {
                Text("No microphones connected")
            }
            ForEach(studio.devices.microphones) { microphone in
                Button {
                    studio.toggleMicrophone(deviceID: microphone.id)
                } label: {
                    if studio.isInMixer(deviceID: microphone.id) {
                        Label(microphone.name, systemImage: "checkmark")
                    } else {
                        Text(microphone.name)
                    }
                }
            }
            Text("Pick a device to add it, pick it again to remove it. Two inputs can run together.")
        }
    }
}

// MARK: - Controls

struct ControlsDock: View {
    @Environment(StudioController.self) private var studio

    var body: some View {
        DockPanel(title: "Controls") {
            GlassEffectContainer(spacing: Theme.spacingS) {
                VStack(spacing: Theme.spacingS) {
                    Button(action: studio.toggleStreaming) {
                        Label(studio.streamStatus.isActive ? "Stop Streaming" : "Start Streaming",
                              systemImage: studio.streamStatus.isActive ? "stop.fill" : "dot.radiowaves.left.and.right")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(studio.streamStatus.isActive ? Theme.live : .accentColor)

                    DestinationPickerPill()

                    Divider()
                        .padding(.vertical, Theme.spacingXS)

                    Button(action: studio.toggleRecording) {
                        Label(studio.isFinalizingRecording ? "Saving Recording…"
                                : (studio.isRecording ? "Stop Recording" : "Start Recording"),
                              systemImage: studio.isRecording ? "stop.circle.fill" : "record.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(studio.isFinalizingRecording)
                    .buttonStyle(.glass)
                    .tint(studio.isRecording ? Theme.live : nil)

                    HStack(spacing: Theme.spacingS) {
                        Button(action: studio.revealRecordings) {
                            Label("Recordings", systemImage: "folder").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        .help("Show recordings in Finder (Movies ▸ Streamio)")

                        Button {
                            studio.setFullscreenPreview(true)
                        } label: {
                            Label("Fullscreen", systemImage: "arrow.up.left.and.arrow.down.right").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        .help("Show only the program output, full screen (⇧⌘F)")
                    }

                    SettingsLink {
                        Label("Settings", systemImage: "gearshape").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
                .buttonBorderShape(.capsule)
                .controlSize(.large)
            }
        }
    }
}

/// The destinations selector under "Start Streaming": a Liquid Glass pill that opens a glass
/// popover of switches. A custom popover rather than a `Menu`, because macOS drops a menu
/// label's background and shape, which left the old selector as bare text.
struct DestinationPickerPill: View {
    @Environment(StudioController.self) private var studio
    @State private var isPresented = false

    var body: some View {
        let enabled = studio.destinations.filter(\.isEnabled)
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: Theme.spacingS) {
                Image(systemName: enabled.isEmpty ? "antenna.radiowaves.left.and.right.slash" : "antenna.radiowaves.left.and.right")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(enabled.isEmpty ? Color.secondary : Color.accentColor)
                    .frame(width: 30, height: 30)
                    .background(.fill.tertiary, in: .circle)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Go live on")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(summary(enabled))
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: Theme.spacingXS)
                if enabled.count > 1 {
                    Text("\(enabled.count)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.2), in: .capsule)
                        .accessibilityHidden(true)
                }
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isPresented ? 180 : 0))
            }
            .padding(.leading, 6)
            .padding(.trailing, Theme.spacingM)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(enabled.isEmpty ? .regular.interactive() : .regular.tint(Color.accentColor.opacity(0.12)).interactive(),
                     in: .capsule)
        .animation(.smooth(duration: 0.2), value: isPresented)
        .help("Choose where Start Streaming goes live")
        .accessibilityLabel("Destinations")
        .accessibilityValue(summary(enabled))
        .popover(isPresented: $isPresented, arrowEdge: .leading) {
            DestinationPickerList()
        }
    }

    private func summary(_ enabled: [StreamDestination]) -> String {
        switch enabled.count {
        case 0: studio.destinations.isEmpty ? String(localized: "Add a destination") : String(localized: "No destinations")
        case 1: enabled[0].name
        case 2: "\(enabled[0].name), \(enabled[1].name)"
        default: String(localized: "\(enabled.count) destinations")
        }
    }
}

/// The popover behind the destination pill: one switch per destination plus a way to Settings.
struct DestinationPickerList: View {
    @Environment(StudioController.self) private var studio

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingM) {
            Text("Destinations")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if studio.destinations.isEmpty {
                Text("Add YouTube, Facebook, Twitch or a custom RTMP server to start streaming.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                GlassEffectContainer(spacing: Theme.spacingXS) {
                    VStack(spacing: Theme.spacingXS) {
                        ForEach(studio.destinations) { destination in
                            DestinationRow(destination: destination)
                        }
                    }
                }
                Text("One encode is shared by every destination.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SettingsLink {
                Label(studio.destinations.isEmpty ? "Add Destination…" : "Manage Destinations…",
                      systemImage: studio.destinations.isEmpty ? "plus" : "slider.horizontal.3")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        }
        .padding(Theme.spacingL)
        .frame(width: 300)
    }
}

/// A round service glyph used in destination pills.
struct ServiceBadge: View {
    let service: StreamingService
    var isOn: Bool = true

    var body: some View {
        Image(systemName: service.systemImage)
            .font(.callout.weight(.semibold))
            .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
            .frame(width: 30, height: 30)
            .background(.fill.tertiary, in: .circle)
            .accessibilityHidden(true)
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
                        .fixedSize(horizontal: false, vertical: true)
                }
                GlassEffectContainer(spacing: Theme.spacingXS) {
                    VStack(spacing: Theme.spacingXS) {
                        ForEach(studio.destinations) { destination in
                            DestinationRow(destination: destination)
                        }
                    }
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

/// One destination as a glass pill: service glyph, name, live status and an include switch
/// (or a per-destination start/stop button while the stream is up).
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
            ServiceBadge(service: destination.service, isOn: enabled.wrappedValue)
            VStack(alignment: .leading, spacing: 0) {
                Text(destination.name)
                    .font(.callout.weight(.semibold))
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
                .lineLimit(1)
                .foregroundStyle(status == .idle ? Color.secondary : status.tint)
            }
            Spacer(minLength: 0)
            if studio.streamStatus.isActive || status.isActive {
                Button(status.isActive ? "Stop \(destination.name)" : "Go Live on \(destination.name)",
                       systemImage: status.isActive ? "stop.fill" : "play.fill") {
                    studio.toggleDestination(destination.id)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.small)
                .help(status.isActive ? "Stop this destination only" : "Add this destination to the live stream")
            } else {
                Toggle("Include \(destination.name) when going live", isOn: enabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, Theme.spacingM)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 44)
        .glassEffect(rowGlass(status: status, isOn: enabled.wrappedValue), in: .capsule)
    }

    private func rowGlass(status: StreamStatus, isOn: Bool) -> Glass {
        if status.isLive { return .regular.tint(Theme.live.opacity(0.3)) }
        if status.isActive { return .regular.tint(Theme.warning.opacity(0.25)) }
        return isOn ? .regular.tint(Color.accentColor.opacity(0.15)) : .regular
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
                        Slider(value: $binding.pipScale, in: 0.08...0.6) { Text("Size") }
                            .labelsHidden()
                    }
                    LabeledContent("Move Right") {
                        Slider(value: $binding.offsetX, in: -0.5...0.5) { Text("Move horizontally") }
                            .labelsHidden()
                    }
                    LabeledContent("Move Down") {
                        Slider(value: $binding.offsetY, in: -0.5...0.5) { Text("Move vertically") }
                            .labelsHidden()
                    }
                    Button("Reset Position") {
                        binding.offsetX = 0
                        binding.offsetY = 0
                    }
                    .disabled(binding.offsetX == 0 && binding.offsetY == 0)
                }
                Toggle("Mirror Horizontally", isOn: $binding.isMirrored)
                adjustment("Opacity", $binding.opacity, 0...1, neutral: 1)
            }
            Section("Shape and Border") {
                Picker("Shape", selection: $binding.shape) {
                    ForEach(SourceShape.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                }
                if binding.shape.cropsToSquare, !binding.layout.isPictureInPicture {
                    Text("Square shapes crop the picture. Choose a corner layout to use them as a small overlay.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Border") {
                    Slider(value: $binding.borderWidth, in: 0...0.1) { Text("Border thickness") }
                        .labelsHidden()
                }
                ColorPicker("Border Colour", selection: borderColor, supportsOpacity: false)
                    .disabled(binding.borderWidth == 0)
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

    private var borderColor: Binding<Color> {
        Binding(
            get: { Color(.sRGB, red: binding.borderColor.red, green: binding.borderColor.green, blue: binding.borderColor.blue) },
            set: { color in
                let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .white
                binding.borderColor = SourceColor(red: Double(resolved.redComponent), green: Double(resolved.greenComponent),
                                                  blue: Double(resolved.blueComponent))
            }
        )
    }

    private func adjustment(_ title: LocalizedStringKey, _ value: Binding<Float>, _ range: ClosedRange<Float>, neutral: Float) -> some View {
        LabeledContent(title) {
            Slider(value: value, in: range) { Text(title) }
            .labelsHidden()
        }
    }
}
