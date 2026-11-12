//
//  ScreenCaptureController.swift
//  Streamio
//
//  ScreenCaptureKit capture for Display Capture scenes and the Desktop Audio channel.
//  Desktop audio needs a running SCStream even when the scene shows a camera, so the
//  stream is kept alive at a tiny size whenever only audio is wanted.
//

import CoreMedia
import Foundation
import ScreenCaptureKit

nonisolated public final class ScreenCaptureController: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public struct Request: Equatable, Sendable {
        /// Display to show, or nil when only desktop audio is needed.
        public var displayID: CGDirectDisplayID?
        public var captureAudio: Bool
        public var canvasWidth: Int
        public var canvasHeight: Int
        public var fps: Int
        public var showsCursor: Bool

        public var isEmpty: Bool { displayID == nil && !captureAudio }
    }

    public enum CaptureError: LocalizedError {
        case permissionDenied
        case displayUnavailable

        public var errorDescription: String? {
            switch self {
            case .permissionDenied:
                String(localized: "Streamio needs Screen & System Audio Recording permission. Enable it in System Settings ▸ Privacy & Security, then try again.")
            case .displayUnavailable:
                String(localized: "The selected display is no longer connected.")
            }
        }
    }

    public var onVideo: (@Sendable (CMSampleBuffer) -> Void)?
    public var onAudio: (@Sendable (CMSampleBuffer) -> Void)?
    public var onStop: (@Sendable (String?) -> Void)?

    private let videoQueue = DispatchQueue(label: "com.streamio.screen.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "com.streamio.screen.audio", qos: .userInteractive)
    private let lock = NSLock()
    private var stream: SCStream?
    private var activeRequest: Request?

    public override init() {
        super.init()
    }

    /// Starts, reconfigures or stops capture to match `request`.
    public func apply(_ request: Request) async throws {
        let current = lock.withLock { activeRequest }
        guard current != request else { return }

        await stop()
        guard !request.isEmpty else { return }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.permissionDenied
        }

        // A chosen display is used exactly; never silently swap in another screen.
        let display: SCDisplay?
        if let displayID = request.displayID {
            display = content.displays.first { $0.displayID == displayID }
        } else {
            display = content.displays.first { $0.displayID == CGMainDisplayID() } ?? content.displays.first
        }
        guard let display else {
            throw CaptureError.displayUnavailable
        }

        // Keep Streamio's own windows out of the picture to avoid a hall-of-mirrors preview.
        let ownApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

        let configuration = SCStreamConfiguration()
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 5
        configuration.showsCursor = request.showsCursor
        if request.displayID != nil {
            let fitted = Self.aspectFit(width: display.width, height: display.height,
                                        intoWidth: request.canvasWidth, height: request.canvasHeight)
            configuration.width = fitted.width
            configuration.height = fitted.height
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(request.fps))
        } else {
            // Audio only: the smallest legal video at the lowest rate.
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        }
        configuration.capturesAudio = request.captureAudio
        configuration.sampleRate = Int(AudioMixer.sampleRate)
        configuration.channelCount = Int(AudioMixer.channelCount)
        configuration.excludesCurrentProcessAudio = true

        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if request.captureAudio {
            try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        try await newStream.startCapture()

        lock.withLock {
            stream = newStream
            activeRequest = request
        }
    }

    public func stop() async {
        let current: SCStream? = lock.withLock {
            defer { stream = nil; activeRequest = nil }
            return stream
        }
        try? await current?.stopCapture()
    }

    static func aspectFit(width: Int, height: Int, intoWidth maxWidth: Int, height maxHeight: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (maxWidth, maxHeight) }
        let scale = min(Double(maxWidth) / Double(width), Double(maxHeight) / Double(height))
        // Even dimensions keep the encoder's chroma subsampling happy.
        let fittedWidth = Int((Double(width) * scale).rounded()) & ~1
        let fittedHeight = Int((Double(height) * scale).rounded()) & ~1
        return (max(2, fittedWidth), max(2, fittedHeight))
    }

    // MARK: - SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            guard lock.withLock({ activeRequest?.displayID != nil }), Self.isCompleteFrame(sampleBuffer) else { return }
            onVideo?(sampleBuffer)
        case .audio:
            onAudio?(sampleBuffer)
        default:
            break
        }
    }

    // MARK: - SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        let wasCurrent = lock.withLock {
            guard self.stream === stream else { return false }
            self.stream = nil
            activeRequest = nil
            return true
        }
        if wasCurrent {
            onStop?(error.localizedDescription)
        }
    }

    /// Idle frames repeat the previous image without pixels; skip everything but complete frames.
    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else { return false }
        return status == .complete
    }
}
