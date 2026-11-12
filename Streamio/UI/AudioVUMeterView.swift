//
//  AudioVUMeterView.swift
//  Streamio
//

import SwiftUI

public struct AudioVUMeterView: View {
    public var levelLeftDb: Float
    public var levelRightDb: Float
    public var isMuted: Bool

    // Normalize -60dB...0dB to 0.0...1.0
    private func normalize(db: Float) -> CGFloat {
        if isMuted { return 0.0 }
        let clamped = max(-60.0, min(0.0, db))
        return CGFloat((clamped + 60.0) / 60.0)
    }

    public var body: some View {
        VStack(spacing: 3) {
            channelBar(fraction: normalize(db: levelLeftDb), label: "L")
            channelBar(fraction: normalize(db: levelRightDb), label: "R")
        }
    }

    private func channelBar(fraction: CGFloat, label: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 10)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background track
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.black.opacity(0.4))
                        .frame(height: 6)

                    // VU Meter Gradient
                    RoundedRectangle(cornerRadius: 2)
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [.green, .yellow, .red]),
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geometry.size.width * fraction, height: 6)
                        .animation(.linear(duration: 0.08), value: fraction)
                }
            }
            .frame(height: 6)
        }
    }
}

