//
//  StreamManager.swift
//  Streamio
//

import Foundation
import SwiftUI
import AVFoundation
import CoreMedia
import Combine

public final class StreamManager: ObservableObject, CaptureSessionDelegate, VideoEncoderDelegate, AudioEncoderDelegate, RTMPClientDelegate, MetalPreviewRendererDelegate, @unchecked Sendable {
    // UI Published State
    @Published public var selectedResolution: VideoResolution = .res1080p
    @Published public var selectedFrameRate: FrameRate = .fps30
    @Published public var selectedVideoCodec: VideoCodec = .h264
    @Published public var videoBitrate: Int = 4_500_000
    @Published public var selectedAudioBitrate: AudioBitrate = .kbps128

    @Published public var selectedFilter: FilterType = .passthrough
    @Published public var filterParams = FilterParameters()

    @Published public var selectedVideoDeviceId: String = "" {
        didSet {
            deviceManager.selectedVideoDeviceId = selectedVideoDeviceId
            reconfigureCaptureDevices()
        }
    }
    @Published public var selectedAudioDeviceId: String = "" {
        didSet {
            deviceManager.selectedAudioDeviceId = selectedAudioDeviceId
            reconfigureCaptureDevices()
        }
    }

    @Published public var rtmpServerUrl: String = "rtmp://a.rtmp.youtube.com/live2"
    @Published public var streamKey: String = ""

    @Published public var streamStatus: StreamStatus = .idle
    @Published public var stats = StreamStats()

    @Published public var isRecording: Bool = false
    @Published public var lastRecordedURL: URL?
    @Published public var isAudioMuted: Bool = false

    // Dependencies
    public let deviceManager = CaptureDeviceManager()
    private let captureController = CaptureSessionController()
    private let videoEncoder = VideoEncoder()
    private let audioEncoder = AudioEncoder()
    private let rtmpClient = RTMPClient()
    private let recorder = StreamRecorder()

    // Preview
    private weak var previewCoordinator: MetalPreviewView.Coordinator?

    // FPS calculation
    private var frameCount: Int = 0
    private var lastFpsDate = Date()
    private var streamTimer: Timer?
    private var streamStartDate: Date?

    private var cancellables = Set<AnyCancellable>()

    public init() {
        setupBindings()
        setupDelegates()
        startPreview()
    }

    private func setupBindings() {
        // Sync initial device IDs
        self.selectedVideoDeviceId = deviceManager.selectedVideoDeviceId
        self.selectedAudioDeviceId = deviceManager.selectedAudioDeviceId

        deviceManager.$selectedVideoDeviceId
            .sink { [weak self] id in
                if self?.selectedVideoDeviceId != id {
                    self?.selectedVideoDeviceId = id
                }
            }
            .store(in: &cancellables)

        deviceManager.$selectedAudioDeviceId
            .sink { [weak self] id in
                if self?.selectedAudioDeviceId != id {
                    self?.selectedAudioDeviceId = id
                }
            }
            .store(in: &cancellables)

        captureController.onAudioLevelsUpdated = { [weak self] leftDb, rightDb in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.isAudioMuted {
                    self.stats.audioLevelLeft = -60.0
                    self.stats.audioLevelRight = -60.0
                } else {
                    self.stats.audioLevelLeft = leftDb
                    self.stats.audioLevelRight = rightDb
                }
            }
        }
    }

    private func setupDelegates() {
        captureController.delegate = self
        videoEncoder.delegate = self
        audioEncoder.delegate = self
        rtmpClient.delegate = self
    }

    public func registerPreviewCoordinator(_ coordinator: MetalPreviewView.Coordinator) {
        self.previewCoordinator = coordinator
    }

    public func startPreview() {
        reconfigureCaptureDevices()
    }

    public func reconfigureCaptureDevices() {
        let videoDev = deviceManager.getAVCaptureDevice(for: deviceManager.selectedVideoDeviceId, mediaType: .video)
        let audioDev = deviceManager.getAVCaptureDevice(for: deviceManager.selectedAudioDeviceId, mediaType: .audio)

        captureController.configureSession(
            videoDevice: videoDev,
            audioDevice: audioDev,
            resolution: selectedResolution,
            frameRate: selectedFrameRate
        )
    }

    // MARK: - Streaming Actions
    public func toggleStreaming() {
        if streamStatus.isLive || streamStatus == .connecting {
            stopStreaming()
        } else {
            startStreaming()
        }
    }

    public func startStreaming() {
        guard !streamKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self.streamStatus = .error("Please enter your YouTube Stream Key")
            return
        }

        let dims = selectedResolution.dimensions

        // Configure Encoders
        videoEncoder.configure(
            width: dims.width,
            height: dims.height,
            bitrate: videoBitrate,
            fps: selectedFrameRate.rawValue,
            codec: selectedVideoCodec
        )

        audioEncoder.configure(
            bitrate: selectedAudioBitrate,
            sampleRate: 44100.0
        )

        // Configure RTMP Client
        rtmpClient.configure(
            rtmpUrl: rtmpServerUrl,
            streamKey: streamKey,
            width: dims.width,
            height: dims.height,
            videoBitrate: videoBitrate,
            audioBitrate: selectedAudioBitrate.rawValue,
            fps: selectedFrameRate.rawValue
        )

        rtmpClient.connect()
        streamStartDate = Date()

        startStatsTimer()
    }

    public func stopStreaming() {
        rtmpClient.disconnect()
        videoEncoder.stop()
        streamStartDate = nil
        streamTimer?.invalidate()
        streamTimer = nil
        streamStatus = .idle
        stats.outputBitrateKbps = 0.0
        stats.streamingDuration = 0.0
    }

    // MARK: - Recording Actions
    public func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    public func startRecording() {
        let dims = selectedResolution.dimensions
        do {
            let url = try recorder.startRecording(
                width: dims.width,
                height: dims.height,
                bitrate: videoBitrate,
                fps: selectedFrameRate.rawValue
            )
            self.isRecording = true
            self.stats.isRecording = true
            self.lastRecordedURL = url
        } catch {
            print("Failed to start recording: \(error)")
        }
    }

    public func stopRecording() {
        recorder.stopRecording { [weak self] url in
            DispatchQueue.main.async {
                self?.isRecording = false
                self?.stats.isRecording = false
                self?.stats.recordingDuration = 0.0
                self?.lastRecordedURL = url
            }
        }
    }

    public func openRecordingsFolder() {
        if let lastURL = lastRecordedURL {
            NSWorkspace.shared.activateFileViewerSelecting([lastURL])
        } else if let moviesURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first {
            NSWorkspace.shared.open(moviesURL)
        }
    }

    private func startStatsTimer() {
        streamTimer?.invalidate()
        streamTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if let start = self.streamStartDate {
                self.stats.streamingDuration = Date().timeIntervalSince(start)
            }
            if self.isRecording {
                self.stats.recordingDuration = self.recorder.recordingDuration
                self.stats.recordedBytes = self.recorder.recordedBytes
            }
        }
    }

    // MARK: - CaptureSessionDelegate
    public func captureSession(_ controller: CaptureSessionController, didOutputVideoSampleBuffer sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)

        // 1. Send raw pixel buffer to Metal preview view
        previewCoordinator?.updateFrame(pixelBuffer)

        // Measure FPS
        frameCount += 1
        let now = Date()
        let interval = now.timeIntervalSince(lastFpsDate)
        if interval >= 1.0 {
            DispatchQueue.main.async {
                self.stats.currentFps = Double(self.frameCount) / interval
                self.frameCount = 0
                self.lastFpsDate = now
            }
        }

        // 2. If Streaming or Recording, apply Metal Filter and pass to encoders
        let shouldEncode = streamStatus.isLive || isRecording
        if shouldEncode {
            let processedBuffer: CVPixelBuffer
            if selectedFilter == .passthrough &&
               filterParams.brightness == 0.0 &&
               filterParams.contrast == 1.0 &&
               filterParams.saturation == 1.0 {
                processedBuffer = pixelBuffer
            } else {
                processedBuffer = MetalPipeline.shared.processFrame(
                    sourcePixelBuffer: pixelBuffer,
                    filter: selectedFilter,
                    params: filterParams
                ) ?? pixelBuffer
            }

            if streamStatus.isLive {
                videoEncoder.encode(pixelBuffer: processedBuffer, presentationTimeStamp: pts, duration: duration)
            }

            if isRecording {
                recorder.appendVideoPixelBuffer(processedBuffer, at: pts)
            }
        }
    }

    public func captureSession(_ controller: CaptureSessionController, didOutputAudioSampleBuffer sampleBuffer: CMSampleBuffer) {
        if isAudioMuted { return }

        if streamStatus.isLive {
            audioEncoder.encode(sampleBuffer: sampleBuffer)
        }

        if isRecording {
            recorder.appendAudioSampleBuffer(sampleBuffer)
        }
    }

    // MARK: - VideoEncoderDelegate
    public func videoEncoder(_ encoder: VideoEncoder, didOutputSPS sps: Data, pps: Data) {
        rtmpClient.setAVCSequenceHeader(sps: sps, pps: pps)
    }

    public func videoEncoder(_ encoder: VideoEncoder, didOutputNALU nalu: Data, pts: CMTime, dts: CMTime, isKeyFrame: Bool) {
        rtmpClient.sendVideoSample(nalu: nalu, pts: pts, isKeyFrame: isKeyFrame)
    }

    // MARK: - AudioEncoderDelegate
    public func audioEncoder(_ encoder: AudioEncoder, didOutputAudioSpecificConfig config: Data) {
        rtmpClient.setAACSequenceHeader(config: config)
    }

    public func audioEncoder(_ encoder: AudioEncoder, didOutputAACPacket aacData: Data, pts: CMTime) {
        rtmpClient.sendAudioSample(aacData: aacData, pts: pts)
    }

    // MARK: - RTMPClientDelegate
    public func rtmpClientDidChangeStatus(_ client: RTMPClient, status: StreamStatus) {
        DispatchQueue.main.async {
            self.streamStatus = status
        }
    }

    public func rtmpClientDidUpdateStatistics(_ client: RTMPClient, bytesSent: UInt64, bitrateKbps: Double, droppedFrames: Int) {
        DispatchQueue.main.async {
            self.stats.streamedBytes = bytesSent
            self.stats.outputBitrateKbps = bitrateKbps
            self.stats.droppedFrames = droppedFrames
        }
    }
}

