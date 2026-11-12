//
//  LiveBadgeView.swift
//  Streamio
//

import SwiftUI

public struct LiveBadgeView: View {
    @ObservedObject var streamManager: StreamManager

    public var body: some View {
        HStack(spacing: 12) {
            // Live Status Indicator
            if streamManager.streamStatus.isLive {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text("LIVE")
                        .font(.system(size: 11, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                    Text(formatTime(streamManager.stats.streamingDuration))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.9))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.red.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else if streamManager.streamStatus == .connecting {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 8, height: 8)
                    Text("CONNECTING")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.orange)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.7))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            // Simultaneous Recording Indicator
            if streamManager.isRecording {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text("REC")
                        .font(.system(size: 11, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                    Text(formatTime(streamManager.stats.recordingDuration))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.9))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.red.opacity(0.75))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            // Real-time Stats Badges
            HStack(spacing: 8) {
                // FPS
                HStack(spacing: 4) {
                    Text("FPS")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                    Text(String(format: "%.0f", streamManager.stats.currentFps))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.primary)
                }

                Divider().frame(height: 12)

                // Bitrate
                HStack(spacing: 4) {
                    Text("BITRATE")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                    Text(String(format: "%.0f kbps", streamManager.stats.outputBitrateKbps))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(streamManager.stats.outputBitrateKbps > 0 ? .green : .primary)
                }

                if streamManager.stats.droppedFrames > 0 {
                    Divider().frame(height: 12)
                    HStack(spacing: 4) {
                        Text("DROP")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)
                        Text("\(streamManager.stats.droppedFrames)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.orange)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Material.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func formatTime(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
}

