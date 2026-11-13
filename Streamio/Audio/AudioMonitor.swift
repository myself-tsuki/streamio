//
//  AudioMonitor.swift
//  Streamio
//
//  Plays monitored channels (post-fader, like OBS) to headphones or speakers.
//  The mixer pushes audio in; an AVAudioSourceNode pulls it out on the output device's clock.
//  Streamio's own output is excluded from Desktop Audio capture, so monitoring never feeds back.
//

import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

nonisolated public final class AudioMonitor: @unchecked Sendable {
    private let format: AVAudioFormat
    private let lock = NSLock()
    private var rings: [AudioChannelID: AudioRingBuffer] = [:]
    private var monitored: Set<AudioChannelID> = []
    /// Keep monitoring latency low: trim anything queued beyond ~60 ms.
    private let maxLatencyFrames = 2_880
    private let controlQueue = DispatchQueue(label: "com.streamio.audio.monitor", qos: .userInitiated)
    private var engine: AVAudioEngine?
    private var engineDeviceUID: String?
    private var configObserver: NSObjectProtocol?

    public var onError: (@Sendable (String) -> Void)?

    public init(format: AVAudioFormat) {
        self.format = format
        for channel in AudioChannelID.allCases {
            rings[channel] = AudioRingBuffer(capacity: Int(AudioMixer.sampleRate) / 2)
        }
    }

    /// Starts, retargets or stops playback. `deviceUID` "" means the system default output.
    public func configure(channels: Set<AudioChannelID>, deviceUID: String) {
        lock.withLock {
            for channel in AudioChannelID.allCases where !channels.contains(channel) {
                rings[channel]?.removeAll()
            }
            monitored = channels
        }
        controlQueue.async { [self] in
            if channels.isEmpty {
                stopEngine()
            } else if engine == nil || engineDeviceUID != deviceUID || engine?.isRunning == false {
                stopEngine()
                startEngine(deviceUID: deviceUID)
            }
        }
    }

    /// Called by the mixer with post-fader samples.
    public func write(_ channel: AudioChannelID, left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) {
        lock.withLock {
            guard monitored.contains(channel) else { return }
            rings[channel]?.write(left: UnsafeBufferPointer(start: left, count: frames),
                                  right: UnsafeBufferPointer(start: right, count: frames))
        }
    }

    // MARK: - Engine

    private func startEngine(deviceUID: String) {
        let newEngine = AVAudioEngine()

        // Pick the output device first; changing it after the graph is wired can leave the engine silent.
        if let deviceID = AudioOutputDevices.deviceID(forUID: deviceUID),
           let unit = newEngine.outputNode.audioUnit {
            var device = deviceID
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        }

        let source = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, bufferList in
            self?.render(frameCount: Int(frameCount), bufferList: bufferList)
            return noErr
        }
        newEngine.attach(source)
        newEngine.connect(source, to: newEngine.mainMixerNode, format: format)
        newEngine.mainMixerNode.outputVolume = 1

        newEngine.prepare()
        do {
            try newEngine.start()
            engine = newEngine
            engineDeviceUID = deviceUID
            // Plugging in or switching headphones (or a Bluetooth route change) stops the engine
            // without telling anyone. Restart it so monitoring comes back by itself.
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: newEngine, queue: nil
            ) { [weak self] _ in
                self?.controlQueue.async {
                    guard let self, let uid = self.engineDeviceUID, !self.lock.withLock({ self.monitored.isEmpty }) else { return }
                    self.stopEngine()
                    self.startEngine(deviceUID: uid)
                }
            }
        } catch {
            onError?(String(localized: "Audio monitoring could not start: \(error.localizedDescription)"))
        }
    }

    private func stopEngine() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine?.stop()
        engine = nil
        engineDeviceUID = nil
    }

    private func render(frameCount: Int, bufferList: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        for buffer in buffers {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        guard buffers.count >= 2,
              let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
              let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return }
        let capacity = min(frameCount, Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size,
                           Int(buffers[1].mDataByteSize) / MemoryLayout<Float>.size)
        let leftBuffer = UnsafeMutableBufferPointer(start: left, count: capacity)
        let rightBuffer = UnsafeMutableBufferPointer(start: right, count: capacity)

        lock.withLock {
            for channel in monitored {
                guard let available = rings[channel]?.availableFrames else { continue }
                if available > capacity + maxLatencyFrames {
                    rings[channel]?.skip(available - capacity - maxLatencyFrames / 2)
                }
                rings[channel]?.mix(into: leftBuffer, rightBuffer, count: capacity, gain: 1)
            }
        }
        for index in 0..<capacity {
            leftBuffer[index] = max(-1, min(1, leftBuffer[index]))
            rightBuffer[index] = max(-1, min(1, rightBuffer[index]))
        }
    }
}
