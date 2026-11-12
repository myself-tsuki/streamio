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

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        refreshDevices()
        let center = NotificationCenter.default
        for name in [NSNotification.Name.AVCaptureDeviceWasConnected, .AVCaptureDeviceWasDisconnected] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDevices() }
            })
        }
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDisplays() }
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

        let audioDiscovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
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

    func camera(id: String) -> AVCaptureDevice? {
        AVCaptureDevice(uniqueID: id)
    }

    func microphone(id: String) -> AVCaptureDevice? {
        id.isEmpty ? AVCaptureDevice.default(for: .audio) : AVCaptureDevice(uniqueID: id)
    }

    var defaultCameraID: String? {
        cameras.first(where: \.isDefault)?.id ?? cameras.first?.id
    }

    func name(for source: VideoSource) -> String {
        switch source {
        case .none:
            String(localized: "No Source")
        case .camera(let id):
            cameras.first { $0.id == id }?.name ?? String(localized: "Disconnected Camera")
        case .display(let id):
            displays.first { $0.id == id }?.name ?? String(localized: "Disconnected Display")
        }
    }
}
