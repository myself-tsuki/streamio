//
//  CaptureDeviceManager.swift
//  Streamio
//
//  Live lists of cameras, microphones and displays for the pickers.
//

import AppKit
import AVFoundation
import Observation
import ScreenCaptureKit

@Observable
final class CaptureDeviceManager {
    private(set) var cameras: [DeviceItem] = []
    private(set) var microphones: [DeviceItem] = []
    private(set) var displays: [DisplayItem] = []

    /// Called after any camera, microphone or display is plugged in or removed.
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        refreshDevices()
        let center = NotificationCenter.default
        for name in [NSNotification.Name.AVCaptureDeviceWasConnected, .AVCaptureDeviceWasDisconnected] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshDevices()
                    self?.onChange?()
                }
            })
        }
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshDisplays()
                self?.onChange?()
            }
        })
        refreshDisplays()
    }

    func refreshDevices() {
        let videoTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera]
        let videoDiscovery = AVCaptureDevice.DiscoverySession(deviceTypes: videoTypes, mediaType: .video, position: .unspecified)
        let defaultCamera = AVCaptureDevice.default(for: .video)?.uniqueID
        cameras = videoDiscovery.devices.map {
            DeviceItem(id: $0.uniqueID, name: $0.localizedName, isDefault: $0.uniqueID == defaultCamera)
        }

        let audioDiscovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
        let defaultMicrophone = AVCaptureDevice.default(for: .audio)?.uniqueID
        microphones = audioDiscovery.devices.map {
            DeviceItem(id: $0.uniqueID, name: $0.localizedName, isDefault: $0.uniqueID == defaultMicrophone)
        }
    }

    /// Display names come from NSScreen; ScreenCaptureKit permission is not needed to list them.
    func refreshDisplays() {
        displays = NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let pixels = screen.convertRectToBacking(screen.frame).size
            return DisplayItem(id: number.uint32Value, name: screen.localizedName,
                               width: Int(pixels.width), height: Int(pixels.height))
        }
    }

    /// Exact device lookup. A missing device returns nil: Streamio never substitutes another one.
    func camera(id: String) -> AVCaptureDevice? {
        guard !id.isEmpty, cameras.contains(where: { $0.id == id }) else { return nil }
        return AVCaptureDevice(uniqueID: id)
    }

    /// Exact device lookup, like `camera(id:)`. No "system default" fallback.
    func microphone(id: String) -> AVCaptureDevice? {
        guard !id.isEmpty, microphones.contains(where: { $0.id == id }) else { return nil }
        return AVCaptureDevice(uniqueID: id)
    }

    func isConnected(_ source: VideoSource) -> Bool {
        switch source {
        case .camera(let id): cameras.contains { $0.id == id }
        case .display(let id): displays.contains { $0.id == id }
        case .image(let path), .video(let path): FileManager.default.fileExists(atPath: path)
        }
    }

    func cameraName(id: String) -> String {
        cameras.first { $0.id == id }?.name ?? String(localized: "Disconnected Camera")
    }

    func microphoneName(id: String) -> String {
        microphones.first { $0.id == id }?.name ?? String(localized: "Disconnected Microphone")
    }

    func name(for source: VideoSource) -> String {
        switch source {
        case .camera(let id):
            cameraName(id: id)
        case .display(let id):
            displays.first { $0.id == id }?.name ?? String(localized: "Disconnected Display")
        case .image(let path), .video(let path):
            URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        }
    }
}
