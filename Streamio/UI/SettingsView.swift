//
//  SettingsView.swift
//  Streamio
//
//  Settings (⌘,), organised like OBS: Stream, Output, Audio, Video, Advanced.
//

import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Stream", systemImage: "dot.radiowaves.left.and.right") { StreamSettingsPane() }
            Tab("Output", systemImage: "externaldrive") { OutputSettingsPane() }
            Tab("Video", systemImage: "display") { VideoSettingsPane() }
            Tab("Advanced", systemImage: "gearshape.2") { AdvancedSettingsPane() }
        }
        .frame(width: 560, height: 460)
    }
}

struct StreamSettingsPane: View {
    @Environment(StudioController.self) private var studio
    @State private var revealsKey = false

    var body: some View {
        @Bindable var studio = studio
        Form {
            Picker("Service", selection: $studio.service) {
                ForEach(StreamingService.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: studio.service) { _, service in
                if let first = service.servers.first { studio.serverURL = first.url }
            }
            if studio.service.servers.isEmpty {
                TextField("Server", text: $studio.serverURL, prompt: Text(verbatim: "rtmp://example.com/live"))
            } else {
                Picker("Server", selection: $studio.serverURL) {
                    ForEach(studio.service.servers) { Text($0.name).tag($0.url) }
                }
            }
            LabeledContent("Stream Key") {
                HStack {
                    if revealsKey {
                        TextField("Stream Key", text: $studio.streamKey).labelsHidden()
                    } else {
                        SecureField("Stream Key", text: $studio.streamKey).labelsHidden()
                    }
                    Button(revealsKey ? "Hide Key" : "Show Key", systemImage: revealsKey ? "eye.slash" : "eye") { revealsKey.toggle() }
                        .labelStyle(.iconOnly)
                }
            }
            if let url = studio.service.streamKeyHelpURL {
                Link("Get Stream Key", destination: url)
            }
            Text("Your stream key is stored in the macOS keychain.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .disabled(studio.streamStatus.isActive)
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
