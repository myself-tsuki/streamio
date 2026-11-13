//
//  StreamioApp.swift
//  Streamio
//

import AppKit
import Combine
import SwiftUI

@main
struct StreamioApp: App {
    @State private var studio = StudioController()
    @State private var permissions = PermissionsManager()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some Scene {
        // One studio window: capture devices can only be owned once.
        Window("Streamio", id: "studio") {
            Group {
                if permissions.allGranted {
                    StudioView()
                } else {
                    PermissionsView()
                }
            }
            .environment(studio)
            .environment(permissions)
            .onAppear { studio.setCaptureAuthorized(permissions.allGranted) }
            .onChange(of: permissions.allGranted) { _, granted in studio.setCaptureAuthorized(granted) }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                permissions.refresh()
            }
        }
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1440, height: 900)
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu("Broadcast") {
                Group {
                    Button(studio.streamStatus.isActive ? "Stop Streaming" : "Start Streaming", action: studio.toggleStreaming)
                        .keyboardShortcut("s", modifiers: [.command, .option])
                    Button(studio.isRecording ? "Stop Recording" : "Start Recording", action: studio.toggleRecording)
                        .keyboardShortcut("r", modifiers: [.command, .option])
                    Divider()
                    Button("Mute Mic/Aux") { studio.toggleMute(.microphone) }
                        .keyboardShortcut("m", modifiers: [.command, .option])
                        .disabled(studio.audioSource(.microphone) == nil)
                    Button("Mute Mic/Aux 2") { studio.toggleMute(.aux) }
                        .disabled(studio.audioSource(.aux) == nil)
                    Button("Mute Desktop Audio") { studio.toggleMute(.desktop) }
                        .keyboardShortcut("d", modifiers: [.command, .option])
                        .disabled(studio.audioSource(.desktop) == nil)
                }
                .disabled(!permissions.allGranted)
                Divider()
                Button("Show Diagnostics Log") {
                    NSWorkspace.shared.activateFileViewerSelecting([DiagnosticsLog.fileURL])
                }
                Button("Show Recordings", action: studio.revealRecordings)
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandMenu("Scenes") {
                Button("Previous Scene") { studio.selectAdjacentScene(offset: -1) }
                    .keyboardShortcut("[", modifiers: .command)
                Button("Next Scene") { studio.selectAdjacentScene(offset: 1) }
                    .keyboardShortcut("]", modifiers: .command)
                Divider()
                ForEach(Array(studio.scenes.prefix(9).enumerated()), id: \.element.id) { index, scene in
                    Button(scene.name) { studio.selectScene(number: index + 1) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
            CommandGroup(after: .toolbar) {
                Button(studio.isFullscreenPreview ? "Exit Fullscreen Preview" : "Fullscreen Preview",
                       action: studio.toggleFullscreenPreview)
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(!permissions.allGranted)
                Button(studio.isProgramPoppedOut ? "Bring Program Output Back" : "Pop Out Program Output") {
                    if studio.isProgramPoppedOut {
                        dismissWindow(id: "program")
                    } else {
                        openWindow(id: "program")
                        studio.moveProgramWindowToOtherScreen()
                    }
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!permissions.allGranted)
                Button(studio.showsStatsOverlay ? "Hide Preview Widgets" : "Show Preview Widgets") {
                    studio.showsStatsOverlay.toggle()
                }
                Button(studio.widgets.showsBar ? "Hide Bottom Bar" : "Show Bottom Bar") {
                    studio.widgets.showsBar.toggle()
                }
            }
        }

        // Program output on its own window, so the studio and the output can use two displays.
        Window(StudioController.programWindowTitle, id: "program") {
            ProgramWindowView()
                .environment(studio)
                .environment(permissions)
        }
        .defaultSize(width: 1280, height: 720)

        Settings {
            SettingsView()
                .environment(studio)
        }
    }
}
