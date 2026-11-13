//
//  OverlaySources.swift
//  Streamio
//
//  Sources for corner overlays: extra cameras (a face cam next to the main camera) and looping
//  video files. Each one only keeps its newest frame; the canvas clock picks it up.
//

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore

/// One capture session per extra camera, video only. The main camera and the microphone stay on
/// `CaptureSessionController`.
nonisolated final class ExtraCameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    var onVideo: (@Sendable (String, CMSampleBuffer) -> Void)?
    var onError: (@Sendable (String) -> Void)?

    private final class Running {
        let session = AVCaptureSession()
        let output = AVCaptureVideoDataOutput()
        let queue: DispatchQueue
        init(id: String) { queue = DispatchQueue(label: "com.streamio.capture.extra.\(id)", qos: .userInteractive) }
    }

    private let lock = NSLock()
    private var running: [String: Running] = [:]
    private let sessionQueue = DispatchQueue(label: "com.streamio.capture.extra.session", qos: .userInitiated)

    /// Starts the cameras in `devices` (by unique ID) and stops every other one. A camera that is
    /// unplugged is simply absent from `devices`; it starts again when it returns.
    func configure(devices: [String: AVCaptureDevice], fps: Int) {
        sessionQueue.async { [self] in
            let current = lock.withLock { running }
            for (id, item) in current where devices[id] == nil {
                item.session.stopRunning()
                lock.withLock { running[id] = nil }
            }
            for (id, device) in devices where current[id] == nil {
                let item = Running(id: id)
                do {
                    let input = try AVCaptureDeviceInput(device: device)
                    item.session.beginConfiguration()
                    item.session.sessionPreset = .high
                    guard item.session.canAddInput(input) else {
                        item.session.commitConfiguration()
                        continue
                    }
                    item.session.addInput(input)
                    item.output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                    item.output.alwaysDiscardsLateVideoFrames = true
                    item.output.setSampleBufferDelegate(self, queue: item.queue)
                    if item.session.canAddOutput(item.output) { item.session.addOutput(item.output) }
                    item.session.commitConfiguration()
                    // An overlay is small on screen: 720p is plenty and spares USB bandwidth.
                    CaptureSessionController.applyBestFormat(to: device, width: 1280, height: 720, fps: fps)
                    lock.withLock { running[id] = item }
                    item.session.startRunning()
                } catch {
                    onError?(error.localizedDescription)
                }
            }
        }
    }

    func stopAll() {
        sessionQueue.async { [self] in
            let all = lock.withLock { () -> [Running] in
                let items = Array(running.values)
                running.removeAll()
                return items
            }
            for item in all { item.session.stopRunning() }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let id = lock.withLock { running.first { $0.value.output === output }?.key }
        if let id { onVideo?(id, sampleBuffer) }
    }
}

/// A silent, looping video file whose newest frame can be read at any time.
nonisolated final class VideoFilePlayer: @unchecked Sendable {
    private let player: AVPlayer
    private let output: AVPlayerItemVideoOutput
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var observer: NSObjectProtocol?

    init(path: String) {
        let item = AVPlayerItem(url: URL(fileURLWithPath: path))
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ])
        item.add(output)
        player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.actionAtItemEnd = .none
        observer = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: nil
        ) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }
        player.play()
    }

    deinit {
        player.pause()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// The current frame, or the last one if the player has not produced a new one yet.
    func currentFrame() -> CVPixelBuffer? {
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        lock.lock()
        defer { lock.unlock() }
        if output.hasNewPixelBuffer(forItemTime: time),
           let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
            latest = buffer
        }
        return latest
    }
}
