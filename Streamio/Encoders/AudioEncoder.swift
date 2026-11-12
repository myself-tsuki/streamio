//
//  AudioEncoder.swift
//  Streamio
//
//  AAC-LC encoder for the mixed program audio. Input is the mixer's 48 kHz Float32
//  stereo; output is one raw AAC packet (1024 frames) at a time with its timestamp.
//

import AVFoundation
import AudioToolbox
import Foundation

nonisolated public final class AudioEncoder: @unchecked Sendable {
    public static let framesPerPacket = 1024

    /// AudioSpecificConfig, emitted once per `start`.
    public var onConfig: (@Sendable (Data) -> Void)?
    /// Raw AAC packet and its host-clock presentation time.
    public var onPacket: (@Sendable (Data, Double) -> Void)?

    private let lock = NSLock()
    private let inputFormat: AVAudioFormat
    private var aacFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var fifo = AudioRingBuffer(capacity: 48_000)
    /// Host time of the first frame currently in `fifo`.
    private var fifoTime: Double?
    /// Times of chunks handed to the converter but not yet returned as packets (encoder delay).
    private var pendingTimes: [Double] = []
    private var chunk: AVAudioPCMBuffer?

    public init(inputFormat: AVAudioFormat) {
        self.inputFormat = inputFormat
    }

    public func start(bitrate: AudioBitrate) {
        lock.withLock {
            var description = AudioStreamBasicDescription(
                mSampleRate: inputFormat.sampleRate,
                mFormatID: kAudioFormatMPEG4AAC,
                mFormatFlags: AudioFormatFlags(MPEG4ObjectID.AAC_LC.rawValue),
                mBytesPerPacket: 0,
                mFramesPerPacket: UInt32(Self.framesPerPacket),
                mBytesPerFrame: 0,
                mChannelsPerFrame: inputFormat.channelCount,
                mBitsPerChannel: 0,
                mReserved: 0
            )
            guard let format = AVAudioFormat(streamDescription: &description),
                  let newConverter = AVAudioConverter(from: inputFormat, to: format) else { return }
            newConverter.bitRate = bitrate.rawValue
            aacFormat = format
            converter = newConverter
            fifo.removeAll()
            fifoTime = nil
            pendingTimes.removeAll()
            chunk = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(Self.framesPerPacket))
        }
        onConfig?(FLVTag.audioSpecificConfig(sampleRate: inputFormat.sampleRate, channels: Int(inputFormat.channelCount)))
    }

    public func stop() {
        lock.withLock {
            converter = nil
            aacFormat = nil
            chunk = nil
        }
    }

    public var isRunning: Bool { lock.withLock { converter != nil } }

    public func encode(_ buffer: AVAudioPCMBuffer, time: Double) {
        var packets: [(Data, Double)] = []

        lock.withLock {
            guard converter != nil,
                  let left = buffer.floatChannelData?[0],
                  let right = buffer.floatChannelData?[buffer.format.channelCount > 1 ? 1 : 0] else { return }
            let frames = Int(buffer.frameLength)

            // Resynchronise if the incoming time drifts more than 50 ms from the FIFO's clock.
            let sampleRate = inputFormat.sampleRate
            let expected = (fifoTime ?? time) + Double(fifo.availableFrames) / sampleRate
            if fifoTime == nil || abs(expected - time) > 0.05 {
                fifoTime = time - Double(fifo.availableFrames) / sampleRate
            }

            fifo.write(left: UnsafeBufferPointer(start: left, count: frames),
                       right: UnsafeBufferPointer(start: right, count: frames))

            while fifo.availableFrames >= Self.framesPerPacket {
                // Every pass consumes one chunk from the FIFO, so the loop always terminates.
                if let packet = encodeNextChunk() {
                    packets.append(packet)
                }
            }
        }

        for (data, pts) in packets {
            onPacket?(data, pts)
        }
    }

    /// Encodes one 1024-frame chunk. Returns nil while the encoder is still filling its look-ahead.
    private func encodeNextChunk() -> (Data, Double)? {
        guard let converter, let aacFormat, let chunk,
              let left = chunk.floatChannelData?[0],
              let right = chunk.floatChannelData?[1] else {
            fifo.skip(Self.framesPerPacket)
            return nil
        }

        let frames = Self.framesPerPacket
        chunk.frameLength = AVAudioFrameCount(frames)
        memset(left, 0, frames * MemoryLayout<Float>.size)
        memset(right, 0, frames * MemoryLayout<Float>.size)
        fifo.mix(into: UnsafeMutableBufferPointer(start: left, count: frames),
                 UnsafeMutableBufferPointer(start: right, count: frames),
                 count: frames, gain: 1)

        let chunkTime = fifoTime ?? 0
        fifoTime = chunkTime + Double(frames) / inputFormat.sampleRate
        pendingTimes.append(chunkTime)

        let output = AVAudioCompressedBuffer(
            format: aacFormat,
            packetCapacity: 1,
            maximumPacketSize: max(converter.maximumOutputPacketSize, 1536)
        )

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return chunk
        }

        guard status != .error, error == nil, output.packetCount > 0, output.byteLength > 0 else {
            return nil
        }

        let size: Int
        let offset: Int
        if let description = output.packetDescriptions?.pointee {
            size = Int(description.mDataByteSize)
            offset = Int(description.mStartOffset)
        } else {
            size = Int(output.byteLength)
            offset = 0
        }
        let data = Data(bytes: output.data.advanced(by: offset), count: size)
        let pts = pendingTimes.isEmpty ? chunkTime : pendingTimes.removeFirst()
        return (data, pts)
    }
}
