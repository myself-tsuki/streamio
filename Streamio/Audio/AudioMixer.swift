//
//  AudioMixer.swift
//  Streamio
//
//  Software mixer for the Desktop Audio and Mic/Aux channels.
//
//  Each source's sample buffers are converted to 48 kHz Float32 stereo, run through the
//  channel fader (gain + mute), metered post-fader like OBS, and queued in a ring buffer.
//  The microphone (or, without one, desktop audio) acts as the clock: whenever it delivers
//  N frames, N frames are pulled from every channel, summed and emitted.
//

import Accelerate
import AVFoundation
import CoreMedia

nonisolated public final class AudioMixer: @unchecked Sendable {
    public static let sampleRate: Double = 48_000
    public static let channelCount: AVAudioChannelCount = 2

    /// Float32, non-interleaved, 48 kHz stereo.
    public let outputFormat: AVAudioFormat

    public struct ChannelSettings: Equatable, Sendable {
        public var gain: Float = 1
        public var isMuted = false

        public init(gain: Float = 1, isMuted: Bool = false) {
            self.gain = gain
            self.isMuted = isMuted
        }
    }

    /// Mixed output on the delivering source's queue. Time is host-clock seconds.
    public var onMixedAudio: (@Sendable (AVAudioPCMBuffer, Double) -> Void)?
    /// Post-fader meter readings, at most `meterRate` times per second.
    public var onLevels: (@Sendable ([AudioChannelID: AudioLevels]) -> Void)?

    private struct MeterAccumulator {
        var peakLeft: Float = 0
        var peakRight: Float = 0
        var sumSquaresLeft: Float = 0
        var sumSquaresRight: Float = 0
        var frames = 0
    }

    private let lock = NSLock()
    private var rings: [AudioChannelID: AudioRingBuffer] = [:]
    private var settings: [AudioChannelID: ChannelSettings] = [:]
    private var converters: [AudioChannelID: AVAudioConverter] = [:]
    private var lastDelivery: [AudioChannelID: Double] = [:]
    private var meters: [AudioChannelID: MeterAccumulator] = [:]
    private var lastMeterPublish: Double = 0
    private let meterInterval: Double = 1.0 / 20.0
    /// Non-clock sources may run this far ahead before old audio is trimmed (100 ms).
    private let maxLatencyFrames = 4_800

    public init() {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: Self.channelCount) else {
            fatalError("48 kHz stereo Float32 must always be a valid audio format")
        }
        outputFormat = format
        for channel in AudioChannelID.allCases {
            rings[channel] = AudioRingBuffer(capacity: Int(Self.sampleRate) / 2)
            settings[channel] = ChannelSettings()
        }
    }

    public func setSettings(_ newSettings: ChannelSettings, for channel: AudioChannelID) {
        lock.withLock { settings[channel] = newSettings }
    }

    /// Forget a source that stopped (device removed, display capture ended).
    public func reset(_ channel: AudioChannelID) {
        lock.withLock {
            rings[channel]?.removeAll()
            converters[channel] = nil
            lastDelivery[channel] = nil
            meters[channel] = nil
        }
    }

    // MARK: - Ingest

    public func ingest(_ sampleBuffer: CMSampleBuffer, from channel: AudioChannelID) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let pcm = Self.makePCMBuffer(from: sampleBuffer, formatDescription: formatDescription) else { return }
        let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))

        lock.lock()
        defer { lock.unlock() }

        guard let stereo = convertToStereo(pcm, channel: channel),
              let left = stereo.floatChannelData?[0],
              let right = stereo.floatChannelData?[1] else { return }
        let frames = Int(stereo.frameLength)
        guard frames > 0 else { return }

        // Fader
        let channelSettings = settings[channel] ?? ChannelSettings()
        var gain = channelSettings.isMuted ? 0 : channelSettings.gain
        vDSP_vsmul(left, 1, &gain, left, 1, vDSP_Length(frames))
        vDSP_vsmul(right, 1, &gain, right, 1, vDSP_Length(frames))

        accumulateMeter(channel: channel, left: left, right: right, frames: frames)
        rings[channel]?.write(left: UnsafeBufferPointer(start: left, count: frames),
                              right: UnsafeBufferPointer(start: right, count: frames))
        lastDelivery[channel] = time

        if channel == clockChannel(now: time) {
            emitMix(frames: frames, time: time)
        }
        publishMetersIfNeeded(now: time)
    }

    /// The microphone drives the mix while it is delivering; otherwise desktop audio does.
    private func clockChannel(now: Double) -> AudioChannelID {
        if let micTime = lastDelivery[.microphone], now - micTime < 0.5 {
            return .microphone
        }
        return .desktop
    }

    private func emitMix(frames: Int, time: Double) {
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(frames)),
              let outLeft = output.floatChannelData?[0],
              let outRight = output.floatChannelData?[1] else { return }
        output.frameLength = AVAudioFrameCount(frames)
        vDSP_vclr(outLeft, 1, vDSP_Length(frames))
        vDSP_vclr(outRight, 1, vDSP_Length(frames))

        let leftBuffer = UnsafeMutableBufferPointer(start: outLeft, count: frames)
        let rightBuffer = UnsafeMutableBufferPointer(start: outRight, count: frames)
        for channel in AudioChannelID.allCases {
            guard var ring = rings[channel] else { continue }
            if ring.availableFrames > frames + maxLatencyFrames {
                ring.skip(ring.availableFrames - frames - maxLatencyFrames / 2)
            }
            ring.mix(into: leftBuffer, rightBuffer, count: frames, gain: 1)
            rings[channel] = ring
        }

        // Soft safety clip so summed channels never wrap.
        var low: Float = -1
        var high: Float = 1
        vDSP_vclip(outLeft, 1, &low, &high, outLeft, 1, vDSP_Length(frames))
        vDSP_vclip(outRight, 1, &low, &high, outRight, 1, vDSP_Length(frames))

        onMixedAudio?(output, time)
    }

    // MARK: - Metering

    private func accumulateMeter(channel: AudioChannelID, left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) {
        var accumulator = meters[channel] ?? MeterAccumulator()
        var peakLeft: Float = 0
        var peakRight: Float = 0
        var squaresLeft: Float = 0
        var squaresRight: Float = 0
        vDSP_maxmgv(left, 1, &peakLeft, vDSP_Length(frames))
        vDSP_maxmgv(right, 1, &peakRight, vDSP_Length(frames))
        vDSP_svesq(left, 1, &squaresLeft, vDSP_Length(frames))
        vDSP_svesq(right, 1, &squaresRight, vDSP_Length(frames))
        accumulator.peakLeft = max(accumulator.peakLeft, peakLeft)
        accumulator.peakRight = max(accumulator.peakRight, peakRight)
        accumulator.sumSquaresLeft += squaresLeft
        accumulator.sumSquaresRight += squaresRight
        accumulator.frames += frames
        meters[channel] = accumulator
    }

    private func publishMetersIfNeeded(now: Double) {
        guard now - lastMeterPublish >= meterInterval || now < lastMeterPublish else { return }
        lastMeterPublish = now

        var readings: [AudioChannelID: AudioLevels] = [:]
        for channel in AudioChannelID.allCases {
            guard let accumulator = meters[channel], accumulator.frames > 0,
                  let delivered = lastDelivery[channel], now - delivered < 0.5 else {
                readings[channel] = .silent
                continue
            }
            let frames = Float(accumulator.frames)
            readings[channel] = AudioLevels(
                peakLeft: AudioLevels.decibels(fromAmplitude: accumulator.peakLeft),
                peakRight: AudioLevels.decibels(fromAmplitude: accumulator.peakRight),
                rmsLeft: AudioLevels.decibels(fromAmplitude: (accumulator.sumSquaresLeft / frames).squareRoot()),
                rmsRight: AudioLevels.decibels(fromAmplitude: (accumulator.sumSquaresRight / frames).squareRoot())
            )
        }
        meters.removeAll(keepingCapacity: true)
        onLevels?(readings)
    }

    // MARK: - Format conversion

    private static func makePCMBuffer(from sampleBuffer: CMSampleBuffer, formatDescription: CMFormatDescription) -> AVAudioPCMBuffer? {
        let format = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }

    /// Converts any PCM input to 48 kHz Float32 non-interleaved stereo.
    /// Mono sources are duplicated to both sides; extra channels beyond two are dropped.
    private func convertToStereo(_ input: AVAudioPCMBuffer, channel: AudioChannelID) -> AVAudioPCMBuffer? {
        let inputFormat = input.format
        let sourceChannels = max(1, inputFormat.channelCount)

        let resampled: AVAudioPCMBuffer
        if inputFormat.commonFormat == .pcmFormatFloat32, !inputFormat.isInterleaved, inputFormat.sampleRate == Self.sampleRate {
            resampled = input
        } else {
            guard let intermediate = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate,
                                                   channels: sourceChannels, interleaved: false) else { return nil }
            var converter = converters[channel]
            if converter == nil || converter?.inputFormat != inputFormat {
                converter = AVAudioConverter(from: inputFormat, to: intermediate)
                converters[channel] = converter
            }
            guard let converter else { return nil }

            let ratio = Self.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 32
            guard let output = AVAudioPCMBuffer(pcmFormat: intermediate, frameCapacity: capacity) else { return nil }

            var supplied = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return input
            }
            guard status != .error, error == nil else { return nil }
            resampled = output
        }

        if sourceChannels == 2 {
            return resampled
        }

        // Map mono → stereo or multichannel → first two channels.
        guard let stereo = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: resampled.frameLength),
              let source = resampled.floatChannelData,
              let destination = stereo.floatChannelData else { return nil }
        stereo.frameLength = resampled.frameLength
        let byteCount = Int(resampled.frameLength) * MemoryLayout<Float>.size
        memcpy(destination[0], source[0], byteCount)
        memcpy(destination[1], source[sourceChannels > 1 ? 1 : 0], byteCount)
        return stereo
    }
}
