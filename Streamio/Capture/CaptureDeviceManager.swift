//
//  CaptureDeviceManager.swift
//  Streamio
//

import Foundation
import AVFoundation
import Combine

public struct DeviceItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let isDefault: Bool
}

public final class CaptureDeviceManager: ObservableObject, @unchecked Sendable {
    @Published public var availableVideoDevices: [DeviceItem] = []
    @Published public var availableAudioDevices: [DeviceItem] = []
    @Published public var selectedVideoDeviceId: String = ""
    @Published public var selectedAudioDeviceId: String = ""

    public init() {
        refreshDevices()
        registerNotifications()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func registerNotifications() {
        NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasConnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshDevices()
        }

        NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasDisconnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshDevices()
        }
    }

    public func refreshDevices() {
        // Video devices discovery
        let videoDiscovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .externalUnknown,
                .continuityCamera
            ],
            mediaType: .video,
            position: .unspecified
        )

        let defaultVideo = AVCaptureDevice.default(for: .video)
        let videoList = videoDiscovery.devices.map { device in
            DeviceItem(
                id: device.uniqueID,
                name: device.localizedName,
                isDefault: device.uniqueID == defaultVideo?.uniqueID
            )
        }

        // Audio devices discovery
        let audioDiscovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInMicrophone,
                .externalUnknown
            ],
            mediaType: .audio,
            position: .unspecified
        )

        let defaultAudio = AVCaptureDevice.default(for: .audio)
        let audioList = audioDiscovery.devices.map { device in
            DeviceItem(
                id: device.uniqueID,
                name: device.localizedName,
                isDefault: device.uniqueID == defaultAudio?.uniqueID
            )
        }

        DispatchQueue.main.async {
            self.availableVideoDevices = videoList
            self.availableAudioDevices = audioList

            if self.selectedVideoDeviceId.isEmpty || !videoList.contains(where: { $0.id == self.selectedVideoDeviceId }) {
                self.selectedVideoDeviceId = defaultVideo?.uniqueID ?? videoList.first?.id ?? ""
            }

            if self.selectedAudioDeviceId.isEmpty || !audioList.contains(where: { $0.id == self.selectedAudioDeviceId }) {
                self.selectedAudioDeviceId = defaultAudio?.uniqueID ?? audioList.first?.id ?? ""
            }
        }
    }

    public func getAVCaptureDevice(for id: String, mediaType: AVMediaType) -> AVCaptureDevice? {
        guard !id.isEmpty else { return AVCaptureDevice.default(for: mediaType) }
        return AVCaptureDevice(uniqueID: id)
    }
}

