//
//  AudioMeterModel.swift
//  Streamio
//
//  20 Hz meter readings, isolated so only the meter views redraw.
//

import Foundation
import Observation

@Observable
final class AudioMeterModel {
    var desktop = AudioLevels.silent
    var microphone = AudioLevels.silent
    /// Recent microphone peaks in dB (oldest first, ~10 per second) for the level-graph widget.
    private(set) var microphoneHistory = [Float](repeating: AudioLevels.floor, count: AudioMeterModel.historyCount)
    static let historyCount = 60
    @ObservationIgnored private var historyTick = 0

    func levels(for channel: AudioChannelID) -> AudioLevels {
        channel == .desktop ? desktop : microphone
    }

    func apply(_ readings: [AudioChannelID: AudioLevels]) {
        // Peaks fall ~1.5 dB per update (≈30 dB/s), like OBS's default meter decay.
        desktop = desktop.decayed(toward: readings[.desktop] ?? .silent, fall: 1.5)
        microphone = microphone.decayed(toward: readings[.microphone] ?? .silent, fall: 1.5)
        historyTick += 1
        if historyTick % 2 == 0 {
            microphoneHistory.removeFirst()
            microphoneHistory.append(max(microphone.maxPeak, AudioLevels.floor))
        }
    }
}
