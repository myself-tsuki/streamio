//
//  PermissionsManager.swift
//  Streamio
//
//  Camera, microphone and Screen & System Audio Recording are all required. They are
//  requested together at launch, and the studio stays locked until every one is granted.
//

import AppKit
import AVFoundation
import CoreGraphics
import Observation

@Observable
final class PermissionsManager {
    enum Kind: String, CaseIterable, Identifiable {
        case camera
        case microphone
        case screen

        var id: String { rawValue }

        var title: String {
            switch self {
            case .camera: String(localized: "Camera")
            case .microphone: String(localized: "Microphone")
            case .screen: String(localized: "Screen & System Audio Recording")
            }
        }

        var purpose: String {
            switch self {
            case .camera: String(localized: "Capture webcams, USB cameras and Continuity Camera.")
            case .microphone: String(localized: "Capture microphones and USB audio interfaces.")
            case .screen: String(localized: "Capture displays and Desktop Audio.")
            }
        }

        var systemImage: String {
            switch self {
            case .camera: "web.camera"
            case .microphone: "mic"
            case .screen: "rectangle.inset.filled.and.person.filled"
            }
        }

        var settingsURL: URL? {
            let anchor = switch self {
            case .camera: "Privacy_Camera"
            case .microphone: "Privacy_Microphone"
            case .screen: "Privacy_ScreenCapture"
            }
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
        }
    }

    enum State: Equatable {
        case notDetermined
        case granted
        case denied
    }

    private(set) var states: [Kind: State] = [:]
    private(set) var isRequesting = false

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let screenAskedKey = "permissions.screen.asked"

    var allGranted: Bool { Kind.allCases.allSatisfy { states[$0] == .granted } }

    init() {
        refresh()
    }

    func state(_ kind: Kind) -> State { states[kind] ?? .notDetermined }

    func refresh() {
        var next: [Kind: State] = [:]
        next[.camera] = Self.captureState(for: .video)
        next[.microphone] = Self.captureState(for: .audio)
        if CGPreflightScreenCaptureAccess() {
            next[.screen] = .granted
        } else {
            next[.screen] = defaults.bool(forKey: screenAskedKey) ? .denied : .notDetermined
        }
        if next != states { states = next }
    }

    /// Asks for everything still undecided, one system prompt after another.
    func requestAll() async {
        guard !isRequesting else { return }
        isRequesting = true
        defer {
            isRequesting = false
            refresh()
        }
        for kind in Kind.allCases where state(kind) == .notDetermined {
            await request(kind)
        }
    }

    /// Prompts when macOS still can; otherwise opens the matching System Settings pane.
    func request(_ kind: Kind) async {
        switch kind {
        case .camera, .microphone:
            let media: AVMediaType = kind == .camera ? .video : .audio
            if AVCaptureDevice.authorizationStatus(for: media) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: media)
            } else {
                openSettings(kind)
            }
        case .screen:
            if defaults.bool(forKey: screenAskedKey) {
                openSettings(kind)
            } else {
                defaults.set(true, forKey: screenAskedKey)
                _ = CGRequestScreenCaptureAccess()
            }
        }
        refresh()
    }

    func openSettings(_ kind: Kind) {
        if let url = kind.settingsURL { NSWorkspace.shared.open(url) }
    }

    /// macOS applies a new Screen Recording grant only to a fresh process.
    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    private static func captureState(for media: AVMediaType) -> State {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }
}
