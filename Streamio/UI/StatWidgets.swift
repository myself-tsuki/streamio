//
//  StatWidgets.swift
//  Streamio
//
//  Widget faces: a small label, a big-number tile and a square speedometer. Each takes a
//  StatReading so the bottom bar and the preview grid draw exactly the same figures.
//

import SwiftUI

// MARK: - Readings

struct StatReading {
    enum Tone { case load, quality, neutral, live }

    var title: String
    var symbol: String
    var value: String
    var unit = ""
    /// 0...1 position on the speedometer, nil when the figure has no range.
    var fraction: Double?
    var tone = Tone.neutral
    var isWarning = false
}

extension StudioController {
    func reading(of metric: StatMetric, now: Date) -> StatReading {
        switch metric {
        case .live:
            return StatReading(title: streamStatus.isLive ? "LIVE" : streamStatus.label,
                               symbol: metric.symbol, value: Duration.clock(since: stats.streamStart, now: now),
                               tone: streamStatus.isLive ? .live : .neutral)
        case .rec:
            return StatReading(title: "REC", symbol: metric.symbol,
                               value: Duration.clock(since: stats.recordStart, now: now),
                               tone: isRecording ? .live : .neutral)
        case .fps:
            return StatReading(title: "FPS", symbol: metric.symbol, value: String(format: "%.1f", stats.fps),
                               unit: "/ \(frameRate.rawValue)", fraction: stats.fps / Double(max(1, frameRate.rawValue)),
                               tone: .quality)
        case .cameraFPS:
            return StatReading(title: "Camera", symbol: metric.symbol, value: String(format: "%.1f", stats.cameraFPS),
                               unit: "fps", fraction: stats.cameraFPS / Double(max(1, frameRate.rawValue)), tone: .quality)
        case .render:
            let budget = 1000 / Double(max(1, frameRate.rawValue))
            return StatReading(title: "Render", symbol: metric.symbol, value: String(format: "%.1f", stats.renderMilliseconds),
                               unit: "ms", fraction: stats.renderMilliseconds / budget, tone: .load)
        case .cpu:
            return StatReading(title: "CPU", symbol: metric.symbol, value: String(format: "%.0f", stats.cpuPercent),
                               unit: "%", fraction: stats.cpuPercent / 100, tone: .load)
        case .gpu:
            return StatReading(title: "GPU", symbol: metric.symbol, value: stats.gpuPercent.map { String(format: "%.0f", $0) } ?? "—",
                               unit: stats.gpuPercent == nil ? "" : "%", fraction: stats.gpuPercent.map { $0 / 100 } ?? 0, tone: .load)
        case .memory:
            let physical = Double(ProcessInfo.processInfo.physicalMemory)
            return StatReading(title: "Memory", symbol: metric.symbol,
                               value: ByteCountFormatter.string(fromByteCount: Int64(stats.memoryBytes), countStyle: .memory),
                               fraction: Double(stats.memoryBytes) / physical, tone: .load)
        case .bitrate:
            let active = max(1, destinations.filter { status(of: $0.id).isActive }.count)
            let kbps = stats.bitrateKbps
            return StatReading(title: "Bitrate", symbol: metric.symbol,
                               value: kbps >= 10_000 ? String(format: "%.1f", kbps / 1000) : String(format: "%.0f", kbps),
                               unit: kbps >= 10_000 ? "Mb/s" : "kb/s",
                               fraction: kbps / (videoBitrateKbps * Double(active) * 1.25),
                               tone: .neutral, isWarning: stats.congestion > 0.5)
        case .dropped:
            return StatReading(title: "Dropped", symbol: metric.symbol, value: "\(stats.droppedFrames)",
                               unit: String(format: "(%.1f%%)", stats.droppedPercent),
                               fraction: stats.droppedPercent / 10, tone: .load)
        case .disk:
            return StatReading(title: "Disk", symbol: metric.symbol,
                               value: stats.diskFreeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—",
                               unit: "free")
        case .ping:
            return StatReading(title: "Ping", symbol: metric.symbol,
                               value: stats.pingMilliseconds.map { String(format: "%.0f", $0) } ?? "—",
                               unit: stats.pingMilliseconds == nil ? "" : "ms",
                               fraction: (stats.pingMilliseconds ?? 0) / 250, tone: .load)
        }
    }
}

extension StatReading {
    /// Colour for the figure: green to red as load rises, red for on-air, accent otherwise.
    func tint(at fraction: Double? = nil) -> Color {
        if isWarning { return Theme.warning }
        let f = min(max(fraction ?? self.fraction ?? 0, 0), 1)
        switch tone {
        case .live: return Theme.live
        case .neutral: return .accentColor
        case .load: return f < 0.6 ? Theme.good : (f < 0.85 ? Theme.meterYellow : Theme.live)
        case .quality: return f > 0.9 ? Theme.good : (f > 0.6 ? Theme.meterYellow : Theme.live)
        }
    }

    /// Only on-air and warning states colour the glass; the rest stays clear.
    var glassTint: Color? {
        if isWarning { return Theme.warning.opacity(0.3) }
        return tone == .live ? Theme.live.opacity(0.3) : nil
    }
}

// MARK: - Faces

/// "CPU 23 %": the compact text form used in the bottom bar.
struct LabelWidgetView: View {
    let reading: StatReading

    var body: some View {
        Label { Text("\(reading.title) \(reading.value)\(reading.unit.isEmpty ? "" : " \(reading.unit)")") }
            icon: { Image(systemName: reading.symbol) }
            .font(.callout.monospacedDigit())
            .foregroundStyle(reading.isWarning ? Theme.warning : (reading.tone == .live ? Theme.live : .primary))
            .lineLimit(1)
            .accessibilityElement(children: .combine)
    }
}

/// Big figure with a small caption. `height` drives every size so it scales with the grid cell.
struct NumberWidgetView: View {
    let reading: StatReading
    let height: CGFloat
    var chrome = true

    var body: some View {
        VStack(alignment: .leading, spacing: height * 0.02) {
            Label(reading.title, systemImage: reading.symbol)
                .font(.system(size: max(12, height * 0.17), weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: height * 0.05) {
                Text(reading.value)
                    .font(.system(size: height * 0.46, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(reading.fraction == nil && reading.tone != .live ? Color.primary : reading.tint())
                    .contentTransition(.numericText())
                if !reading.unit.isEmpty {
                    Text(reading.unit)
                        .font(.system(size: max(12, height * 0.2), weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.4)
        }
        .padding(.horizontal, height * 0.18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .modifier(WidgetChrome(enabled: chrome, tint: reading.glassTint, radius: height * 0.3))
        .accessibilityElement(children: .combine)
    }
}

/// Square speedometer: 270° dial, ticks, a needle and the figure in the gap at the bottom.
struct GaugeWidgetView: View {
    let reading: StatReading
    var chrome = true

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let fraction = min(max(reading.fraction ?? 0, 0), 1)
            let tint = reading.tint(at: fraction)
            let line = s * 0.07
            let dial = s * 0.8

            ZStack {
                Circle().trim(from: 0, to: 0.75)
                    .stroke(.primary.opacity(0.14), style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(135))
                    .frame(width: dial, height: dial)
                Circle().trim(from: 0, to: 0.75 * fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(135))
                    .frame(width: dial, height: dial)
                ForEach(0...10, id: \.self) { tick in
                    Capsule()
                        .fill(.primary.opacity(tick % 5 == 0 ? 0.55 : 0.28))
                        .frame(width: s * 0.015, height: s * (tick % 5 == 0 ? 0.05 : 0.03))
                        .offset(y: -(dial / 2 - line * 1.25 - s * 0.03))
                        .rotationEffect(.degrees(-135 + 27 * Double(tick)))
                }
                Capsule()
                    .fill(tint)
                    .frame(width: s * 0.03, height: dial * 0.36)
                    .offset(y: -dial * 0.18)
                    .rotationEffect(.degrees(-135 + 270 * fraction))
                Circle().fill(.primary).frame(width: s * 0.07, height: s * 0.07)

                VStack(spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: s * 0.02) {
                        Text(reading.value)
                            .font(.system(size: s * 0.17, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        if !reading.unit.isEmpty {
                            Text(reading.unit)
                                .font(.system(size: max(10, s * 0.09), weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    Text(reading.title)
                        .font(.system(size: max(10, s * 0.09), weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: dial * 0.6)
                .offset(y: dial * 0.36)
            }
            .animation(.smooth(duration: 0.6), value: fraction)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .modifier(WidgetChrome(enabled: chrome, tint: reading.glassTint, radius: 0, usesFraction: true))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(reading.title)
        .accessibilityValue("\(reading.value) \(reading.unit)")
    }
}

struct WidgetChrome: ViewModifier {
    var enabled: Bool
    var tint: Color?
    var radius: CGFloat
    var usesFraction = false

    func body(content: Content) -> some View {
        if enabled {
            // The gauge is square: its corner radius follows its own size.
            content.glassEffect(.regular.tint(tint), in: .rect(cornerRadius: usesFraction ? 28 : radius))
        } else {
            content
        }
    }
}

/// One widget drawn at the right size for its style.
struct StatWidgetFace: View {
    @Environment(StudioController.self) private var studio
    let widget: StatWidget
    /// Height of one grid cell, or the bar height for bar widgets.
    let unit: CGFloat
    var chrome = true

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let reading = studio.reading(of: widget.metric, now: context.date)
            switch widget.style {
            case .label:
                LabelWidgetView(reading: reading)
            case .number:
                NumberWidgetView(reading: reading, height: unit, chrome: chrome)
            case .gauge:
                if widget.metric.supportsGauge {
                    GaugeWidgetView(reading: reading, chrome: chrome)
                } else {
                    NumberWidgetView(reading: reading, height: unit, chrome: chrome)
                }
            }
        }
    }
}
