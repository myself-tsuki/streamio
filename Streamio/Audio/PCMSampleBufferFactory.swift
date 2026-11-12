//
//  PCMSampleBufferFactory.swift
//  Streamio
//

import AVFoundation
import CoreMedia

/// Wraps mixer output in `CMSampleBuffer`s for `AVAssetWriter`.
nonisolated enum PCMSampleBufferFactory {
    static func makeSampleBuffer(from buffer: AVAudioPCMBuffer, time: Double) -> CMSampleBuffer? {
        let frames = CMItemCount(buffer.frameLength)
        guard frames > 0 else { return nil }

        let sampleRate = CMTimeScale(buffer.format.sampleRate)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: sampleRate),
            presentationTimeStamp: CMTime(seconds: time, preferredTimescale: sampleRate),
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: buffer.format.formatDescription,
            sampleCount: frames,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard createStatus == noErr, let sampleBuffer else { return nil }

        let dataStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: buffer.audioBufferList
        )
        return dataStatus == noErr ? sampleBuffer : nil
    }
}
