//
//  MixerDock.swift
//  Streamio
//
//  OBS-style audio mixer under the preview. Empty until the user adds a microphone or
//  Desktop Audio. Each strip has a post-fader meter, a -inf…+20 dB fader, mute, a
//  monitoring toggle (hear the source in headphones or speakers) and full properties.
//

import SwiftUI

struct AudioMixerDock: View {
    @Environment(StudioController.self) private var studio

    var body: some View {
        DockPanel(title: "Audio Mixer") {
            if studio.audioSources.isEmpty {
                HStack(spacing: Theme.spacingL) {
                    Image(systemName: "slider.vertical.3")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: Theme.spacingXS) {
                        Text("No audio sources")
                            .font(.subheadline.bold())
                        Text("Nothing is recorded until you add an input. Only the exact device you pick is used.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    AudioInputMenu()
                        .fixedSize()
                    Button("Add Desktop Audio", systemImage: "speaker.wave.2") { studio.addDesktopAudio() }
                }
                .buttonStyle(.glass)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: Theme.spacingM) {
                        ForEach(studio.audioSources) { config in
                            MixerChannelStrip(channel: config.channel)
                            if config.channel != studio.audioSources.last?.channel { Divider() }
                        }
                    }
                }
                .scrollIndicators(.automatic)
            }
        } accessory: {
            Menu {
                AudioInputMenu()
                Button("Desktop Audio", systemImage: "speaker.wave.2") { studio.addDesktopAudio() }
                    .disabled(studio.audioSource(.desktop) != nil)
            } label: {
                Label("Add Audio Source", systemImage: "plus")
            }
            .menuIndicator(.hidden)
            .help("Add an audio source")
        }
    }
}

struct MixerChannelStrip: View {
    @Environment(StudioController.self) private var studio
    let channel: AudioChannelID
    @State private var showsProperties = false

    var body: some View {
        if let config = studio.audioSource(channel) {
            let gain = Binding<Double>(
                get: { Double(studio.audioSource(channel)?.gainDecibels ?? 0) },
                set: { value in
                    guard var updated = studio.audioSource(channel) else { return }
                    updated.gainDecibels = Float(value)
                    studio.updateAudio(updated)
                }
            )
            let title = studio.audioTitle(channel)
            HStack(alignment: .center, spacing: Theme.spacingM) {
                VStack(alignment: .leading, spacing: Theme.spacingXS) {
                    HStack(spacing: Theme.spacingS) {
                        Image(systemName: channel.systemImage)
                            .foregroundStyle(.secondary)
                        Text(title)
                            .font(.subheadline.bold())
                            .lineLimit(1)
                        if StudioController.inputChannels.contains(channel) {
                            Text(channel == .aux ? "Mic/Aux 2" : "Mic/Aux")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if studio.isAudioDeviceMissing(channel) {
                            Label("Disconnected", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(Theme.warning)
                        }
                        if config.monitoring.isMonitoring {
                            Label(config.monitoring == .monitorOnly ? "Monitor only" : "Monitoring",
                                  systemImage: "headphones")
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                        }
                        Spacer()
                        Text(Self.decibelText(config.gainDecibels))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    LevelMeterView(levels: studio.meters.levels(for: channel), isMuted: config.isMuted)
                    MeterScale()
                    Slider(value: gain, in: Double(AudioSourceConfig.minimumGain)...Double(AudioSourceConfig.maximumGain)) {
                        Text("\(title) Volume")
                    }
                    .labelsHidden()
                    .accessibilityValue(Text(Self.decibelText(config.gainDecibels)))
                }

                VStack(spacing: Theme.spacingXS) {
                    Button(config.isMuted ? "Unmute \(title)" : "Mute \(title)",
                           systemImage: config.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill") {
                        studio.toggleMute(channel)
                    }
                    .foregroundStyle(config.isMuted ? Theme.live : Color.primary)
                    .help(config.isMuted ? "Unmute" : "Mute")

                    Button(config.monitoring.isMonitoring ? "Stop Monitoring \(title)" : "Monitor \(title)",
                           systemImage: config.monitoring.isMonitoring ? "headphones.circle.fill" : "headphones") {
                        studio.toggleMonitoring(channel)
                    }
                    .foregroundStyle(config.monitoring.isMonitoring ? Color.accentColor : Color.primary)
                    .help("Hear this source through your headphones or speakers")

                    Button("\(title) Properties", systemImage: "gearshape") { showsProperties = true }
                        .help("Volume, balance, mono, monitoring and device")
                        .popover(isPresented: $showsProperties, arrowEdge: .trailing) {
                            AudioPropertiesView(channel: channel)
                        }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.title3)
                .frame(width: 32)
            }
            .contextMenu {
                Button(config.isMuted ? "Unmute" : "Mute") { studio.toggleMute(channel) }
                Button("Properties…") { showsProperties = true }
                Divider()
                Button("Remove from Mixer", role: .destructive) { studio.removeAudio(channel) }
            }
        }
    }

    static func decibelText(_ value: Float) -> String {
        if value <= AudioSourceConfig.minimumGain { return "-inf dB" }
        let sign = value > 0.05 ? "+" : ""
        return sign + Double(value).formatted(.number.precision(.fractionLength(1))) + " dB"
    }
}

/// dBFS labels under the meter, OBS style.
struct MeterScale: View {
    private let marks: [Int] = [-60, -45, -30, -20, -9, 0]

    var body: some View {
        GeometryReader { proxy in
            ForEach(marks, id: \.self) { mark in
                Text("\(mark)")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .position(x: max(8, min(proxy.size.width - 6, position(mark, width: proxy.size.width))), y: 5)
            }
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }

    private func position(_ mark: Int, width: CGFloat) -> CGFloat {
        CGFloat(Float(mark) - AudioLevels.floor) / CGFloat(-AudioLevels.floor) * width
    }
}

/// OBS "Advanced Audio Properties" for one channel.
struct AudioPropertiesView: View {
    @Environment(StudioController.self) private var studio
    let channel: AudioChannelID
    @State private var outputs: [AudioOutputDevice] = []

    var body: some View {
        @Bindable var studio = studio
        if let current = studio.audioSource(channel) {
            let config = Binding<AudioSourceConfig>(
                get: { studio.audioSource(channel) ?? current },
                set: { studio.updateAudio($0) }
            )
            Form {
                Section("Volume") {
                    LabeledContent("Gain") {
                        HStack {
                            Slider(value: config.gainDecibels,
                                   in: AudioSourceConfig.minimumGain...AudioSourceConfig.maximumGain) { Text("Gain") }
                                .labelsHidden()
                            TextField("Gain in dB", value: Binding<Double>(
                                get: { Double(config.wrappedValue.gainDecibels) },
                                set: { config.wrappedValue.gainDecibels = Float(min(max($0, -60), 20)) }
                            ), format: .number.precision(.fractionLength(1)))
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                                .frame(width: 56)
                            Text("dB").foregroundStyle(.secondary)
                        }
                    }
                    Toggle("Mute", isOn: config.isMuted)
                    Button("Reset to 0 dB") { config.wrappedValue.gainDecibels = 0 }
                }
                Section("Channels") {
                    LabeledContent("Balance") {
                        HStack {
                            Text("L").foregroundStyle(.secondary)
                            Slider(value: config.balance, in: -1...1) { Text("Balance") }
                            .labelsHidden()
                            Text("R").foregroundStyle(.secondary)
                        }
                    }
                    Toggle("Downmix to Mono", isOn: config.isMono)
                }
                Section("Monitoring") {
                    Picker("Audio Monitoring", selection: config.monitoring) {
                        ForEach(MonitoringMode.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Monitor Output", selection: $studio.monitorDeviceUID) {
                        Text("System Default Output").tag("")
                        ForEach(outputs) { Text($0.name).tag($0.id) }
                        if !studio.monitorDeviceUID.isEmpty, !outputs.contains(where: { $0.id == studio.monitorDeviceUID }) {
                            Text("Disconnected Output").tag(studio.monitorDeviceUID)
                        }
                    }
                    Text("Monitoring plays this source to your headphones or speakers. It is never captured back into Desktop Audio.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if StudioController.inputChannels.contains(channel) {
                    Section("Device") {
                        Picker("Microphone", selection: config.deviceID) {
                            ForEach(studio.devices.microphones) { Text($0.name).tag($0.id) }
                            if studio.devices.microphone(id: current.deviceID) == nil {
                                Text("Disconnected Microphone").tag(current.deviceID)
                            }
                        }
                        Text("Only this microphone is used. If it is unplugged, the channel stays silent until it returns.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button("Remove from Mixer", role: .destructive) { studio.removeAudio(channel) }
                }
            }
            .formStyle(.grouped)
            .frame(width: 380)
            .fixedSize(horizontal: false, vertical: true)
            .onAppear { outputs = AudioOutputDevices.all() }
        }
    }
}
