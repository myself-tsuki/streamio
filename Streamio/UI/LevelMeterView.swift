//
//  LevelMeterView.swift
//  Streamio
//

import SwiftUI

/// OBS-style stereo meter: green to -20 dB, yellow to -9 dB, red above; dim track behind,
/// bright fill for RMS, thin tick for peak. Drawn with Canvas so updates stay cheap.
struct LevelMeterView: View {
    let levels: AudioLevels
    let isMuted: Bool

    var body: some View {
        Canvas { context, size in
            let barHeight = (size.height - 2) / 2
            draw(&context, y: 0, width: size.width, height: barHeight, rms: levels.rmsLeft, peak: levels.peakLeft)
            draw(&context, y: barHeight + 2, width: size.width, height: barHeight, rms: levels.rmsRight, peak: levels.peakRight)
        }
        .frame(height: 12)
        .saturation(isMuted ? 0 : 1)
        .accessibilityElement()
        .accessibilityLabel("Level")
        .accessibilityValue(isMuted ? Text("Muted") : Text("\(Int(levels.maxPeak)) dB"))
    }

    private func position(_ db: Float, width: CGFloat) -> CGFloat {
        CGFloat((max(AudioLevels.floor, min(0, db)) - AudioLevels.floor) / -AudioLevels.floor) * width
    }

    private func draw(_ context: inout GraphicsContext, y: CGFloat, width: CGFloat, height: CGFloat, rms: Float, peak: Float) {
        let yellowStart = position(-20, width: width)
        let redStart = position(-9, width: width)
        let zones: [(CGFloat, CGFloat, Color)] = [
            (0, yellowStart, Theme.meterGreen), (yellowStart, redStart, Theme.meterYellow), (redStart, width, Theme.meterRed)
        ]
        let fill = position(rms, width: width)
        for (start, end, color) in zones {
            context.fill(Path(CGRect(x: start, y: y, width: end - start, height: height)), with: .color(color.opacity(0.22)))
            let lit = min(end, fill) - start
            if lit > 0 {
                context.fill(Path(CGRect(x: start, y: y, width: lit, height: height)), with: .color(color))
            }
        }
        let peakX = position(peak, width: width)
        if peak > AudioLevels.floor {
            context.fill(Path(CGRect(x: max(0, peakX - 2), y: y, width: 2, height: height)), with: .color(.primary))
        }
    }
}
