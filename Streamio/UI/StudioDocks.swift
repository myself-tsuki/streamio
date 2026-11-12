//
//  StudioDocks.swift
//  Streamio
//
//  The bottom dock row: Scenes, Sources, Audio Mixer and Controls, as in OBS Studio.
//

import SwiftUI

struct ScenesDock: View {
    @Environment(StudioController.self) private var studio
    @State private var renaming: StudioScene?
    @State private var newName = ""

    var body: some View {
        @Bindable var studio = studio
        DockPanel(title: "Scenes") {
            List(selection: $studio.selectedSceneID) {
                ForEach(studio.scenes) { scene in
                    Label(scene.name, systemImage: scene.videoSource.systemImage)
                        .tag(scene.id)
                        .contextMenu {
                            Button("Rename…") { beginRename(scene) }
                            Button("Duplicate") { studio.duplicate(scene) }
                            Divider()
                            Button("Delete", role: .destructive) { studio.remove(scene) }
                                .disabled(studio.scenes.count < 2)
                        }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        } accessory: {
            Button("Add Scene", systemImage: "plus", action: studio.addScene)
            Button("Remove Scene", systemImage: "minus", action: removeSelected)
                .disabled(studio.scenes.count < 2)
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
        guard var scene = renaming, !newName.isEmpty,
              let index = studio.scenes.firstIndex(where: { $0.id == scene.id }) else { return }
        scene.name = newName
        studio.scenes[index] = scene
    }

    private func removeSelected() {
        if let scene = studio.selectedScene { studio.remove(scene) }
    }
}

struct SourcesDock: View {
    @Environment(StudioController.self) private var studio

    var body: some View {
        let scene = studio.selectedScene
        DockPanel(title: "Sources") {
            VStack(alignment: .leading, spacing: Theme.spacingS) {
                if let scene {
                    HStack {
                        Label(studio.devices.name(for: scene.videoSource), systemImage: scene.videoSource.systemImage)
                            .lineLimit(1)
                        Spacer()
                        Button(scene.isVideoVisible ? "Hide Video" : "Show Video",
                               systemImage: scene.isVideoVisible ? "eye" : "eye.slash",
                               action: studio.toggleVideoVisibility)
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                    }
                }
                ForEach(AudioChannelID.allCases) { channel in
                    Label(channel.title, systemImage: channel.systemImage)
                        .foregroundStyle(.secondary)
                }
            }
        } accessory: {
            Menu("Choose Video Source", systemImage: "plus") {
                Section("Video Capture Device") {
                    ForEach(studio.devices.cameras) { camera in
                        Button(camera.name) { studio.setSource(.camera(id: camera.id)) }
                    }
                }
                Section("Display Capture") {
                    ForEach(studio.devices.displays) { display in
                        Button("\(display.name) (\(display.width)×\(display.height))") { studio.setSource(.display(id: display.id)) }
                    }
                }
                Divider()
                Button("No Video") { studio.setSource(.none) }
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

struct AudioMixerDock: View {
    @Environment(StudioController.self) private var studio

    var body: some View {
        DockPanel(title: "Audio Mixer") {
            VStack(spacing: Theme.spacingL) {
                ForEach(AudioChannelID.allCases) { channel in
                    MixerChannelStrip(channel: channel)
                }
            }
        }
    }
}

struct MixerChannelStrip: View {
    @Environment(StudioController.self) private var studio
    let channel: AudioChannelID

    var body: some View {
        let muted = studio.mutes[channel] ?? false
        let gain = Binding<Double>(
            get: { Double(studio.gains[channel] ?? 0) },
            set: { studio.gains[channel] = Float($0) }
        )
        VStack(alignment: .leading, spacing: Theme.spacingXS) {
            HStack {
                Text(channel.title).font(.subheadline.bold())
                Spacer()
                Text(gain.wrappedValue <= -60 ? "-inf dB" : "\(gain.wrappedValue, format: .number.precision(.fractionLength(1))) dB")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            LevelMeterView(levels: studio.meters.levels(for: channel), isMuted: muted)
            HStack(spacing: Theme.spacingS) {
                Slider(value: gain, in: -60...0) {
                    Text("\(channel.title) Volume")
                } ticks: {
                    SliderTick(value: -40)
                    SliderTick(value: -20)
                    SliderTick(value: -10)
                    SliderTick(value: 0)
                }
                .sliderNeutralValue(0)
                .labelsHidden()
                Button(muted ? "Unmute \(channel.title)" : "Mute \(channel.title)",
                       systemImage: muted ? "speaker.slash.fill" : "speaker.wave.2.fill") {
                    studio.toggleMute(channel)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(muted ? Theme.live : .primary)
                .frame(minWidth: 24, minHeight: 24)
                if channel == .microphone {
                    MicrophonePicker()
                } else {
                    @Bindable var studio = studio
                    Toggle("Capture Desktop Audio", isOn: $studio.desktopAudioEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                }
            }
        }
    }
}

struct MicrophonePicker: View {
    @Environment(StudioController.self) private var studio

    var body: some View {
        @Bindable var studio = studio
        Picker("Microphone", systemImage: "mic", selection: $studio.microphoneID) {
            Text("System Default").tag("")
            ForEach(studio.devices.microphones) { mic in
                Text(mic.name).tag(mic.id)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }
}

struct ControlsDock: View {
    @Environment(StudioController.self) private var studio

    var body: some View {
        DockPanel(title: "Controls") {
            VStack(spacing: Theme.spacingS) {
                Button(action: studio.toggleStreaming) {
                    Label(studio.streamStatus.isActive ? "Stop Streaming" : "Start Streaming",
                          systemImage: "dot.radiowaves.left.and.right")
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

                Button(action: studio.revealRecordings) {
                    Label("Show Recordings", systemImage: "folder").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)

                SettingsLink {
                    Label("Settings", systemImage: "gearshape").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
            .controlSize(.large)
        }
        .frame(width: Theme.controlsWidth)
    }
}
