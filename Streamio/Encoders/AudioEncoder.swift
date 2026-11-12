//
//  AudioEncoder.swift
//  Streamio
//

import Foundation
import AVFoundation
import AudioToolbox
import CoreMedia

public protocol AudioEncoderDelegate: AnyObject {
    func audioEncoder(_ encoder: AudioEncoder, didOutputAudioSpecificConfig config: Data)
    func audioEncoder(_ encoder: AudioEncoder, didOutputAACPacket aacData: Data, pts: CMTime)
}

public final class AudioEncoder: @unchecked Sendable {
    public weak var delegate: AudioEncoderDelegate?

    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var bitrate: AudioBitrate = .kbps128
    private var sampleRate: Double = 44100.0
    private var hasSentConfig = false
    private let encoderQueue = DispatchQueue(label: "com.streamio.audioencoder", qos: .userInitiated)

    public init() {}

    public func configure(bitrate: AudioBitrate, sampleRate: Double = 44100.0) {
        encoderQueue.async { [weak self] in
            guard let self = self else { return }
            self.bitrate = bitrate
            self.sampleRate = sampleRate
            self.converter = nil
            self.hasSentConfig = false
            self.setupOutputFormat()
        }
    }

    private func setupOutputFormat() {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: UInt32(MPEG4ObjectID.AAC_LC.rawValue),
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 0,
            mReserved: 0
        )

        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            print("Failed to initialize AVAudioFormat for AAC")
            return
        }
        self.outputFormat = format
    }

    /// Generates standard 2-byte AudioSpecificConfig for AAC-LC
    private func createAudioSpecificConfig(sampleRate: Double, channelCount: UInt32) -> Data {
        let objectType: UInt8 = 2 // AAC-LC

        let sampleRates: [Double] = [
            96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350
        ]

        var frequencyIndex: UInt8 = 4 // default 44100
        for (idx, rate) in sampleRates.enumerated() {
            if abs(rate - sampleRate) < 100 {
                frequencyIndex = UInt8(idx)
                break
            }
        }

        let channelConfig = UInt8(min(channelCount, 8))

        // 5 bits objectType, 4 bits frequencyIndex, 4 bits channelConfig, 3 bits 0
        let byte1 = (objectType << 3) | ((frequencyIndex >> 1) & 0x07)
        let byte2 = ((frequencyIndex & 0x01) << 7) | ((channelConfig & 0x0F) << 3)

        return Data([byte1, byte2])
    }

    public func encode(sampleBuffer: CMSampleBuffer) {
        encoderQueue.async { [weak self] in
            guard let self = self else { return }

            guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
                  var inAsbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else {
                return
            }

            guard let inputFormat = AVAudioFormat(streamDescription: &inAsbd) else { return }

            if self.outputFormat == nil {
                self.setupOutputFormat()
            }
            guard let outputFormat = self.outputFormat else { return }

            if self.converter == nil || self.converter?.inputFormat != inputFormat {
                self.converter = AVAudioConverter(from: inputFormat, to: outputFormat)
                self.converter?.bitRate = self.bitrate.rawValue
            }

            guard let converter = self.converter else { return }

            // Ensure AudioSpecificConfig sent once
            if !self.hasSentConfig {
                let config = self.createAudioSpecificConfig(sampleRate: self.sampleRate, channelCount: 2)
                self.delegate?.audioEncoder(self, didOutputAudioSpecificConfig: config)
                self.hasSentConfig = true
            }

            // Convert CMSampleBuffer to AVAudioPCMBuffer
            guard let pcmBuffer = self.sampleBufferToPCMBuffer(sampleBuffer: sampleBuffer, inputFormat: inputFormat) else {
                return
            }

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            // Convert to AAC
            let outBuffer = AVAudioCompressedBuffer(
                format: outputFormat,
                packetCapacity: 16,
                maximumPacketSize: 1024 * 4
            )

            var error: NSError?
            var allConsumed = false

            let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
                if !allConsumed {
                    outStatus.pointee = .haveData
                    allConsumed = true
                    return pcmBuffer
                } else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
            }

            if status != .error && error == nil && outBuffer.byteLength > 0 {
                let rawData = Data(bytes: outBuffer.data, count: Int(outBuffer.byteLength))
                self.delegate?.audioEncoder(self, didOutputAACPacket: rawData, pts: pts)
            }
        }
    }

    private func sampleBufferToPCMBuffer(sampleBuffer: CMSampleBuffer, inputFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0 else { return nil }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(numSamples)) else {
            return nil
        }
        pcmBuffer.frameLength = AVAudioFrameCount(numSamples)

        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?

        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )

        guard status == noErr, let ptr = dataPointer else { return nil }

        let channelCount = Int(inputFormat.channelCount)
        if inputFormat.isInterleaved {
            memcpy(pcmBuffer.audioBufferList.pointee.mBuffers.mData, ptr, totalLength)
        } else {
            let bytesPerChannel = totalLength / max(1, channelCount)
            for channel in 0..<channelCount {
                if let channelData = pcmBuffer.floatChannelData?[channel] {
                    memcpy(channelData, ptr.advanced(by: channel * bytesPerChannel), bytesPerChannel)
                } else if let channelData = pcmBuffer.int16ChannelData?[channel] {
                    memcpy(channelData, ptr.advanced(by: channel * bytesPerChannel), bytesPerChannel)
                }
            }
        }

        return pcmBuffer
    }
}

