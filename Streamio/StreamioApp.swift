//
//  StreamioApp.swift
//  Streamio
//

import SwiftUI

@main
struct StreamioApp: App {
    @State private var studio = StudioController()

    var body: some Scene {
        // One studio window: capture devices can only be owned once.
        Window("Streamio", id: "studio") {
            StudioView()
                .environment(studio)
        }
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1440, height: 900)
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu("Broadcast") {
                Button(studio.streamStatus.isActive ? "Stop Streaming" : "Start Streaming", action: studio.toggleStreaming)
                    .keyboardShortcut("s", modifiers: [.command, .option])
                Button(studio.isRecording ? "Stop Recording" : "Start Recording", action: studio.toggleRecording)
                    .keyboardShortcut("r", modifiers: [.command, .option])
                Divider()
                Button("Mute Mic/Aux") { studio.toggleMute(.microphone) }
                    .keyboardShortcut("m", modifiers: [.command, .option])
                Button("Mute Desktop Audio") { studio.toggleMute(.desktop) }
                    .keyboardShortcut("d", modifiers: [.command, .option])
                Divider()
                Button("Previous Scene") { studio.selectAdjacentScene(offset: -1) }
                    .keyboardShortcut("[", modifiers: .command)
                Button("Next Scene") { studio.selectAdjacentScene(offset: 1) }
                    .keyboardShortcut("]", modifiers: .command)
                Button("Show Recordings", action: studio.revealRecordings)
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environment(studio)
        }
    }
}
