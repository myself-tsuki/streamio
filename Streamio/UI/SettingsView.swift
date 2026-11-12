//
//  SettingsView.swift
//  Streamio
//
//  Settings (⌘,), organised like OBS: Stream (multistream destinations), Output, Audio, Video, Advanced.
//

import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Stream", systemImage: "dot.radiowaves.left.and.right") { StreamSettingsPane() }
            Tab("Output", systemImage: "externaldrive") { OutputSettingsPane() }
            Tab("Audio", systemImage: "speaker.wave.2") { AudioSettingsPane() }
            Tab("Video", systemImage: "display") { VideoSettingsPane() }
            Tab("Advanced", systemImage: "gearshape.2") { AdvancedSettingsPane() }
        }
        .frame(width: 620, height: 560)
    }
}

/// Multistream destinations. Every enabled destination gets the same encoded stream.
struct StreamSettingsPane: View {
    @Environment(StudioController.self) private var studio

    var body: some View {
        Form {
            Section {
                Text("Streamio encodes once and sends the same packets to every enabled destination, so streaming to YouTube and Facebook together costs no extra CPU or GPU.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(studio.destinations) { destination in
                DestinationSettingsSection(destinationID: destination.id)
            }
            Section {
                Menu {
                    ForEach(StreamingService.allCases) { service in
                        Button(service.title) { studio.addDestination(service) }
                    }
                } label: {
                    Label("Add Destination", systemImage: "plus")
                }
                .fixedSize()
            }
        }
        .formStyle(.grouped)
    }
}

struct DestinationSettingsSection: View {
    @Environment(StudioController.self) private var studio
    let destinationID: UUID
    @State private var revealsKey = false

    var body: some View {
        if let current = studio.destinations.first(where: { $0.id == destinationID }) {
            // Looked up by ID on every access, so removing a destination can never index past the end.
            let destination = Binding<StreamDestination>(
                get: { studio.destinations.first { $0.id == destinationID } ?? current },
                set: { updated in
                    if let index = studio.destinations.firstIndex(where: { $0.id == destinationID }) {
                        studio.destinations[index] = updated
                    }
                }
            )
            let isActive = studio.status(of: destinationID).isActive
            let key = Binding(get: { studio.streamKey(for: destinationID) },
                              set: { studio.setStreamKey($0, for: destinationID) })
            Section {
                Toggle("Include When Going Live", isOn: destination.isEnabled)
                TextField("Name", text: destination.name)
                Picker("Service", selection: destination.service) {
                    ForEach(StreamingService.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: destination.wrappedValue.service) { _, service in
                    if let first = service.servers.first { destination.wrappedValue.serverURL = first.url }
                }
                if destination.wrappedValue.service.servers.isEmpty {
                    TextField("Server", text: destination.serverURL, prompt: Text(verbatim: "rtmp://example.com/live"))
                } else {
                    Picker("Server", selection: destination.serverURL) {
                        ForEach(destination.wrappedValue.service.servers) { Text($0.name).tag($0.url) }
                    }
                }
                LabeledContent("Stream Key") {
                    HStack {
                        if revealsKey {
                            TextField("Stream Key", text: key).labelsHidden()
                        } else {
                            SecureField("Stream Key", text: key).labelsHidden()
                        }
                        Button(revealsKey ? "Hide Key" : "Show Key", systemImage: revealsKey ? "eye.slash" : "eye") { revealsKey.toggle() }
                            .labelStyle(.iconOnly)
                            .help(revealsKey ? "Hide stream key" : "Show stream key")
                    }
                }
                HStack {
                    if let url = destination.wrappedValue.service.streamKeyHelpURL {
                        Link("Get Stream Key", destination: url)
                    }
                    Spacer()
                    Button("Remove Destination", role: .destructive) { studio.removeDestination(destinationID) }
                }
            } header: {
                Text(destination.wrappedValue.name)
            } footer: {
                Text("Stream keys are stored in the macOS keychain.")
            }
            .disabled(isActive)
        }
    }
}

struct AudioSettingsPane: View {
    @Environment(StudioController.self) private var studio
    @State private var outputs: [AudioOutputDevice] = []

    var body: some View {
        @Bindable var studio = studio
        Form {
            Section("Audio Sources") {
                if studio.audioSources.isEmpty {
                    Text("No audio sources yet. Add them from the Audio Mixer or the Sources “+” menu.")
                        .foregroundStyle(.secondary)
                }
                ForEach(studio.audioSources) { config in
                    LabeledContent(studio.audioTitle(config.channel)) {
                        Text(config.channel.title).foregroundStyle(.secondary)
                    }
                }
                AudioInputMenu()
                    .fixedSize()
                Button("Add Desktop Audio") { studio.addDesktopAudio() }
                    .disabled(studio.audioSource(.desktop) != nil)
            }
            Section("Monitoring") {
                Picker("Monitoring Device", selection: $studio.monitorDeviceUID) {
                    Text("System Default Output").tag("")
                    ForEach(outputs) { Text($0.name).tag($0.id) }
                    if !studio.monitorDeviceUID.isEmpty, !outputs.contains(where: { $0.id == studio.monitorDeviceUID }) {
                        Text("Disconnected Output").tag(studio.monitorDeviceUID)
                    }
                }
                Text("Turn monitoring on per source with the headphones button in the mixer.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { outputs = AudioOutputDevices.all() }
    }
}

struct OutputSettingsPane: View {
    @Environment(StudioController.self) private var studio

    var body: some View {
        @Bindable var studio = studio
        Form {
            Section("Streaming") {
                Picker("Encoder", selection: $studio.codec) {
                    ForEach(VideoCodec.allCases) { Text($0.title).tag($0) }
                }
                .disabled(studio.isOutputActive)
                LabeledContent("Video Bitrate") {
                    Slider(value: $studio.videoBitrateKbps, in: 1000...20000, step: 250) {
                        Text("Video Bitrate")
                    } ticks: {
                        SliderTick(value: Double(studio.resolution.recommendedBitrate / 1000))
                    }
                    .labelsHidden()
                }
                Text("\(Int(studio.videoBitrateKbps)) kbps · recommended \(studio.resolution.recommendedBitrate / 1000) kbps")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Picker("Audio Bitrate", selection: $studio.audioBitrate) {
                    ForEach(AudioBitrate.allCases) { Text($0.title).tag($0) }
                }
                .disabled(studio.isOutputActive)
            }
            Section("Recording") {
                Picker("Format", selection: $studio.recordingFormat) {
                    ForEach(RecordingFormat.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Folder") {
                    Text(studio.recordingDirectory.path(percentEncoded: false)).lineLimit(1).truncationMode(.middle)
                }
                Text("Recordings reuse the stream encoder, so each frame is encoded only once.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct VideoSettingsPane: View {
    @Environment(StudioController.self) private var studio

    var body: some View {
        @Bindable var studio = studio
        Form {
            Picker("Output Resolution", selection: $studio.resolution) {
                ForEach(VideoResolution.allCases) { Text($0.title).tag($0) }
            }
            Picker("Frame Rate", selection: $studio.frameRate) {
                ForEach(FrameRate.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Show Cursor in Display Capture", isOn: $studio.showsCursor)
        }
        .formStyle(.grouped)
        .disabled(studio.isOutputActive)
    }
}

struct AdvancedSettingsPane: View {
    @Environment(StudioController.self) private var studio

    var body: some View {
        @Bindable var studio = studio
        Form {
            Toggle("Reconnect Automatically", isOn: $studio.autoReconnect)
            LabeledContent("Keyframe Interval") {
                Stepper(value: $studio.keyFrameInterval, in: 1...10, step: 1) {
                    Text("\(Int(studio.keyFrameInterval)) s")
                }
            }
        }
        .formStyle(.grouped)
        .disabled(studio.isOutputActive)
    }
}
