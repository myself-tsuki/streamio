//
//  StatWidgets.swift
//  Streamio
//
//  Widget faces: a small label, a big-number tile, a car-style speedometer and a microphone
//  level graph. Each takes a StatReading so the bottom bar and the preview grid draw exactly
//  the same figures.
//

import SwiftUI

// MARK: - Readings

/// Dial scale: 0...max with a numbered mark every `majorStep`.
struct GaugeScale {
    var max: Double
    var majorStep: Double
    /// Dial numbers are the value divided by this (6000 kb/s reads "6" with a ×1000 caption).
    var labelDivisor = 1.0
    var caption: String

    /// The smallest round step that needs at most `maxMajors` numbered marks to reach `raw`.
    static func nice(upTo raw: Double, maxMajors: Int = 10, labelDivisor: Double = 1, caption: String) -> GaugeScale {
        let steps: [Double] = [0.5, 1, 2, 5, 10, 20, 25, 50, 100, 200, 250, 500, 1000, 2000, 2500, 5000, 10_000, 20_000, 25_000, 50_000]
        let step = steps.first { (raw / $0).rounded(.up) <= Double(maxMajors) } ?? raw / Double(maxMajors)
        return GaugeScale(max: (raw / step).rounded(.up) * step, majorStep: step, labelDivisor: labelDivisor, caption: caption)
    }
}

/// A band of the dial from `from` up to the next zone, with the word that goes with its colour.
struct GaugeZone {
    var from: Double
    var color: Color
    var label: String
}

struct StatReading {
    var title: String
    var symbol: String
    var value: String
    var unit = ""
    /// Position on the dial, in the scale's own unit.
    var number: Double?
    var scale: GaugeScale?
    var zones: [GaugeZone] = []
    /// Nothing to judge yet (not streaming, no GPU figure): the dial stays neutral.
    var isIdle = false
    var isLive = false
    /// Something is badly wrong: the whole widget blinks red.
    var isAlert = false

    var fraction: Double {
        guard let number, let scale else { return 0 }
        return min(max(number / scale.max, 0), 1)
    }

    var zone: GaugeZone? {
        guard !isIdle, let number else { return nil }
        return zones.last { $0.from <= number } ?? zones.first
    }

    /// Colour of the figure: its zone, red for on-air, plain text when unjudged.
    var accent: Color {
        if isAlert { return Theme.zoneDanger }
        if isLive { return Theme.live }
        return zone?.color ?? .primary
    }
}

extension StudioController {
    private func zones(_ values: [(Double, Color, String)]) -> [GaugeZone] {
        values.map { GaugeZone(from: $0.0, color: $0.1, label: $0.2) }
    }

    func reading(of metric: StatMetric, now: Date) -> StatReading {
        let rate = Double(max(1, frameRate.rawValue))
        switch metric {
        case .live:
            return StatReading(title: streamStatus.isLive ? "LIVE" : streamStatus.label,
                               symbol: metric.symbol, value: Duration.clock(since: stats.streamStart, now: now),
                               isLive: streamStatus.isLive)
        case .rec:
            return StatReading(title: "REC", symbol: metric.symbol,
                               value: Duration.clock(since: stats.recordStart, now: now), isLive: isRecording)
        case .fps, .cameraFPS:
            let value = metric == .fps ? stats.fps : stats.cameraFPS
            var reading = StatReading(
                title: metric == .fps ? "FPS" : "Camera", symbol: metric.symbol, value: String(format: "%.1f", value),
                unit: metric == .fps ? "/ \(frameRate.rawValue)" : "fps", number: value,
                scale: .nice(upTo: rate * 1.25, maxMajors: 6, caption: "fps"),
                zones: zones([(0, Theme.zoneDanger, "LOW"), (rate * 0.8, Theme.zoneCaution, "DIP"), (rate * 0.95, Theme.zoneNormal, "OK")]))
            if metric == .fps { reading.isAlert = isOutputActive && value < rate * 0.6 }
            return reading
        case .render:
            let budget = 1000 / rate
            return StatReading(title: "Render", symbol: metric.symbol, value: String(format: "%.1f", stats.renderMilliseconds),
                               unit: "ms", number: stats.renderMilliseconds,
                               scale: .nice(upTo: budget * 1.5, maxMajors: 6, caption: "ms"),
                               zones: zones([(0, Theme.zoneNormal, "OK"), (budget * 0.7, Theme.zoneCaution, "BUSY"), (budget * 0.95, Theme.zoneDanger, "SLOW")]))
        case .cpu:
            return StatReading(title: "CPU", symbol: metric.symbol, value: String(format: "%.0f", stats.cpuPercent), unit: "%",
                               number: stats.cpuPercent, scale: .nice(upTo: 100, maxMajors: 5, caption: "% load"),
                               zones: zones([(0, Theme.zoneNormal, "OK"), (60, Theme.zoneCaution, "BUSY"), (85, Theme.zoneDanger, "HOT")]),
                               isAlert: isOutputActive && stats.cpuPercent >= 95)
        case .gpu:
            let value = stats.gpuPercent
            return StatReading(title: "GPU", symbol: metric.symbol, value: value.map { String(format: "%.0f", $0) } ?? "—",
                               unit: value == nil ? "" : "%", number: value ?? 0, scale: .nice(upTo: 100, maxMajors: 5, caption: "% load"),
                               zones: zones([(0, Theme.zoneNormal, "OK"), (60, Theme.zoneCaution, "BUSY"), (85, Theme.zoneDanger, "HOT")]),
                               isIdle: value == nil, isAlert: isOutputActive && (value ?? 0) >= 95)
        case .memory:
            let percent = Double(stats.memoryBytes) / Double(ProcessInfo.processInfo.physicalMemory) * 100
            return StatReading(title: "Memory", symbol: metric.symbol,
                               value: ByteCountFormatter.string(fromByteCount: Int64(stats.memoryBytes), countStyle: .memory),
                               number: percent, scale: .nice(upTo: 100, maxMajors: 5, caption: "% of RAM"),
                               zones: zones([(0, Theme.zoneNormal, "OK"), (50, Theme.zoneCaution, "HIGH"), (75, Theme.zoneDanger, "FULL")]))
        case .bitrate:
            // The safe range follows the bitrate you set, times the destinations that are on air.
            let active = max(1, destinations.filter { status(of: $0.id).isActive }.count)
            let target = videoBitrateKbps * Double(active)
            let kbps = stats.bitrateKbps
            let warmedUp = stats.streamStart.map { now.timeIntervalSince($0) > 8 } ?? false
            return StatReading(
                title: "Bitrate", symbol: metric.symbol,
                value: kbps >= 10_000 ? String(format: "%.1f", kbps / 1000) : String(format: "%.0f", kbps),
                unit: kbps >= 10_000 ? "Mb/s" : "kb/s", number: kbps,
                scale: .nice(upTo: target * 1.6, labelDivisor: 1000, caption: "×1000 kb/s"),
                zones: zones([(0, Theme.zoneDanger, "LOW"), (target * 0.6, Theme.zoneCaution, "DIP"),
                              (target * 0.8, Theme.zoneNormal, "OK"), (target * 1.3, Theme.zoneHigh, "HIGH")]),
                isIdle: !streamStatus.isActive,
                isAlert: streamStatus.isActive && warmedUp && kbps < target * 0.6)
        case .dropped:
            return StatReading(title: "Dropped", symbol: metric.symbol, value: "\(stats.droppedFrames)",
                               unit: String(format: "(%.1f%%)", stats.droppedPercent), number: stats.droppedPercent,
                               scale: .nice(upTo: 10, maxMajors: 5, caption: "% dropped"),
                               zones: zones([(0, Theme.zoneNormal, "OK"), (1, Theme.zoneCaution, "LOSS"), (3, Theme.zoneDanger, "BAD")]),
                               isAlert: streamStatus.isActive && stats.droppedPercent >= 5)
        case .disk:
            return StatReading(title: "Disk", symbol: metric.symbol,
                               value: stats.diskFreeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—",
                               unit: "free")
        case .ping:
            let ping = stats.pingMilliseconds
            return StatReading(title: "Ping", symbol: metric.symbol, value: ping.map { String(format: "%.0f", $0) } ?? "—",
                               unit: ping == nil ? "" : "ms", number: ping ?? 0, scale: .nice(upTo: 250, maxMajors: 5, caption: "ms"),
                               zones: zones([(0, Theme.zoneNormal, "OK"), (100, Theme.zoneCaution, "SLOW"), (180, Theme.zoneDanger, "HIGH")]),
                               isIdle: ping == nil)
        case .microphone:
            return StatReading(title: "Microphone", symbol: metric.symbol, value: "")
        }
    }
}

// MARK: - Blink alert

/// Glass chrome plus the red blink that says "look at this now", like a car's warning light.
struct WidgetChrome: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var enabled: Bool
    var tint: Color?
    var radius: CGFloat
    var isAlert = false
    @State private var pulse = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Group {
            if enabled {
                content.glassEffect(.regular.tint(isAlert ? Theme.zoneDanger.opacity(0.35) : tint), in: shape)
            } else {
                content
            }
        }
        .overlay {
            if isAlert {
                shape.fill(Theme.zoneDanger.opacity(reduceMotion ? 0.4 : (pulse ? 0.6 : 0.08)))
                    .overlay { shape.strokeBorder(Theme.zoneDanger.opacity(pulse || reduceMotion ? 1 : 0.4), lineWidth: 2) }
                    .allowsHitTesting(false)
            }
        }
        .animation(isAlert && !reduceMotion ? .easeInOut(duration: 0.4).repeatForever(autoreverses: true) : .default, value: pulse)
        .onChange(of: isAlert, initial: true) { pulse = isAlert }
    }
}

// MARK: - Label and number

/// "CPU 23 %": the compact text form used in the bottom bar.
struct LabelWidgetView: View {
    let reading: StatReading

    var body: some View {
        Label { Text("\(reading.title) \(reading.value)\(reading.unit.isEmpty ? "" : " \(reading.unit)")") }
            icon: { Image(systemName: reading.symbol) }
            .font(.callout.monospacedDigit())
            .foregroundStyle(reading.isAlert || reading.isLive ? reading.accent : Color.primary)
            .lineLimit(1)
            .modifier(WidgetChrome(enabled: false, tint: nil, radius: 8, isAlert: reading.isAlert))
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
            HStack(spacing: height * 0.08) {
                Label(reading.title, systemImage: reading.symbol)
                    .font(.system(size: max(12, height * 0.17), weight: .medium))
                    .foregroundStyle(.secondary)
                if let zone = reading.zone {
                    Text(zone.label)
                        .font(.system(size: max(11, height * 0.14), weight: .bold))
                        .foregroundStyle(reading.accent)
                }
            }
            .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: height * 0.05) {
                Text(reading.value)
                    .font(.system(size: height * 0.46, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(reading.number == nil && !reading.isLive ? Color.primary : reading.accent)
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
        .modifier(WidgetChrome(enabled: chrome, tint: reading.isLive ? Theme.live.opacity(0.3) : nil,
                               radius: height * 0.3, isAlert: reading.isAlert))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Speedometer

/// Car-style dial: numbered scale, minor ticks, a coloured safe-range band, a tapered needle on
/// a metal hub and a digital readout, all on a dark face set into the glass tile.
struct GaugeWidgetView: View {
    let reading: StatReading
    var chrome = true

    private static let sweep = 270.0
    private static let start = -135.0

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let r = s * 0.46
            let accent = reading.accent

            ZStack {
                Canvas { context, size in
                    drawDial(context: &context, size: size, radius: r)
                }
                .accessibilityHidden(true)

                // Title and status above the hub.
                VStack(spacing: 0) {
                    Text(reading.title.uppercased())
                        .font(.system(size: max(8, r * 0.13), weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                    if let zone = reading.zone {
                        Text(zone.label)
                            .font(.system(size: max(9, r * 0.15), weight: .bold))
                            .foregroundStyle(accent)
                    } else if reading.isIdle {
                        Text("IDLE")
                            .font(.system(size: max(9, r * 0.15), weight: .bold))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                .lineLimit(1)
                .offset(y: -r * 0.36)

                // Needle: tapered, with a short tail, lit in the colour of the zone it is in.
                NeedleShape()
                    .fill(LinearGradient(colors: [accent, accent.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                    .frame(width: r * 0.1, height: r * 1.6)
                    .shadow(color: accent.opacity(0.7), radius: r * 0.06)
                    .rotationEffect(.degrees(Self.start + Self.sweep * reading.fraction))
                    .animation(.smooth(duration: 0.55), value: reading.fraction)

                // Hub
                Circle()
                    .fill(RadialGradient(colors: [.white.opacity(0.95), Color(white: 0.35)], center: .topLeading,
                                         startRadius: 0, endRadius: r * 0.2))
                    .overlay { Circle().strokeBorder(.black.opacity(0.5), lineWidth: 1) }
                    .frame(width: r * 0.2, height: r * 0.2)

                // Scale caption and digital readout in the open gap at the bottom.
                VStack(spacing: r * 0.04) {
                    Text(reading.scale?.caption ?? "")
                        .font(.system(size: max(8, r * 0.12), weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                    HStack(alignment: .firstTextBaseline, spacing: r * 0.04) {
                        Text(reading.value)
                            .font(.system(size: r * 0.25, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(reading.isIdle ? Color.white.opacity(0.7) : accent)
                            .contentTransition(.numericText())
                        if !reading.unit.isEmpty {
                            Text(reading.unit)
                                .font(.system(size: max(8, r * 0.12), weight: .medium))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, r * 0.14)
                    .padding(.vertical, r * 0.04)
                    .frame(minWidth: r * 0.9)
                    .background(.black.opacity(0.5), in: .rect(cornerRadius: r * 0.1))
                    .overlay { RoundedRectangle(cornerRadius: r * 0.1).strokeBorder(.white.opacity(0.14), lineWidth: 1) }
                }
                .offset(y: r * 0.62)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .modifier(WidgetChrome(enabled: chrome, tint: nil, radius: 28, isAlert: reading.isAlert))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(reading.title)
        .accessibilityValue("\(reading.value) \(reading.unit) \(reading.zone?.label ?? "")")
    }

    /// Point on a circle, `fraction` of the way along the 270° sweep (0 at bottom-left, clockwise).
    private static func point(center: CGPoint, radius: CGFloat, fraction: Double) -> CGPoint {
        let angle = (start + sweep * fraction) * .pi / 180
        return CGPoint(x: center.x + radius * CGFloat(sin(angle)), y: center.y - radius * CGFloat(cos(angle)))
    }

    private static func arc(center: CGPoint, radius: CGFloat, from: Double, to: Double) -> Path {
        var path = Path()
        let steps = max(2, Int((to - from) * sweep / 2))
        for step in 0...steps {
            let p = point(center: center, radius: radius, fraction: from + (to - from) * Double(step) / Double(steps))
            if step == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }

    private func drawDial(context: inout GraphicsContext, size: CGSize, radius r: CGFloat) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let face = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)

        // Dark dial face, deeper toward the rim, with a bezel catching light.
        context.fill(Path(ellipseIn: face), with: .radialGradient(
            Gradient(colors: [.black.opacity(0.42), .black.opacity(0.7)]), center: center, startRadius: 0, endRadius: r))
        context.stroke(Path(ellipseIn: face), with: .linearGradient(
            Gradient(colors: [.white.opacity(0.75), .white.opacity(0.08), .white.opacity(0.3)]),
            startPoint: CGPoint(x: face.minX, y: face.minY), endPoint: CGPoint(x: face.maxX, y: face.maxY)),
            lineWidth: max(1.5, r * 0.04))

        guard let scale = reading.scale else { return }

        // Safe-range band along the rim.
        let bandRadius = r * 0.9
        let bandWidth = max(2, r * 0.06)
        let sorted = reading.zones.sorted { $0.from < $1.from }
        for (index, zone) in sorted.enumerated() {
            let from = min(max(zone.from / scale.max, 0), 1)
            let to = index + 1 < sorted.count ? min(max(sorted[index + 1].from / scale.max, 0), 1) : 1
            guard to > from else { continue }
            let lit = reading.isIdle ? 0.35 : 0.9
            context.stroke(Self.arc(center: center, radius: bandRadius, from: from, to: to),
                           with: .color(zone.color.opacity(lit)), style: StrokeStyle(lineWidth: bandWidth, lineCap: .butt))
        }

        // Ticks and numbers.
        let majors = Int((scale.max / scale.majorStep).rounded())
        guard majors > 0 else { return }
        let minorsPerMajor = 5
        let tickOuter = r * 0.8
        for index in 0...(majors * minorsPerMajor) {
            let fraction = Double(index) / Double(majors * minorsPerMajor)
            let isMajor = index % minorsPerMajor == 0
            var tick = Path()
            tick.move(to: Self.point(center: center, radius: tickOuter, fraction: fraction))
            tick.addLine(to: Self.point(center: center, radius: tickOuter - r * (isMajor ? 0.12 : 0.06), fraction: fraction))
            context.stroke(tick, with: .color(.white.opacity(isMajor ? 0.95 : 0.45)),
                           style: StrokeStyle(lineWidth: max(1, r * (isMajor ? 0.035 : 0.018)), lineCap: .round))
        }
        let showEveryLabel = r > 52 || majors <= 6
        for index in 0...majors where showEveryLabel || index % 2 == 0 {
            let value = Double(index) * scale.majorStep / scale.labelDivisor
            let text = value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)
            let position = Self.point(center: center, radius: r * 0.55, fraction: Double(index) / Double(majors))
            context.draw(Text(text).font(.system(size: max(8, r * 0.14), weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.92)), at: position)
        }
    }
}

/// Tapered pointer, tip up, pivoting on the middle of its frame (tail below the pivot).
struct NeedleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let mid = rect.midX
        let pivotY = rect.midY
        path.move(to: CGPoint(x: mid, y: rect.minY))
        path.addLine(to: CGPoint(x: mid + rect.width / 2, y: pivotY))
        path.addLine(to: CGPoint(x: mid + rect.width * 0.28, y: pivotY + rect.height * 0.12))
        path.addLine(to: CGPoint(x: mid - rect.width * 0.28, y: pivotY + rect.height * 0.12))
        path.addLine(to: CGPoint(x: mid - rect.width / 2, y: pivotY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Microphone graph

/// Rolling level graph of the microphone with a monitor button and output picker, so the mic
/// can be heard in headphones or speakers right from the widget.
struct MicGraphWidgetView: View {
    @Environment(StudioController.self) private var studio
    let height: CGFloat
    var chrome = true

    var body: some View {
        @Bindable var studio = studio
        let config = studio.audioSource(.microphone)
        let missing = studio.isAudioDeviceMissing(.microphone)
        let history = studio.meters.microphoneHistory
        let current = history.last ?? AudioLevels.floor
        let isMonitoring = config?.monitoring.isMonitoring ?? false
        let isMuted = config?.isMuted ?? false
        let state = config == nil ? "No mic" : (missing ? "Unplugged" : (isMuted ? "Muted" : (current <= -59 ? "—" : String(format: "%.0f dB", current))))

        HStack(spacing: height * 0.12) {
            VStack(alignment: .leading, spacing: 0) {
                Label("Mic", systemImage: missing || config == nil ? "mic.slash.fill" : (isMuted ? "mic.slash" : "mic.fill"))
                    .font(.system(size: max(12, height * 0.17), weight: .medium))
                    .foregroundStyle(.secondary)
                Text(state)
                    .font(.system(size: max(13, height * 0.24), weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(missing ? Theme.zoneDanger : (current > -6 && !isMuted ? Theme.zoneDanger : Color.primary))
                    .minimumScaleFactor(0.6)
            }
            .lineLimit(1)
            .frame(minWidth: height * 0.95, alignment: .leading)

            MicGraph(history: history, dimmed: isMuted || missing || config == nil)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, height * 0.2)

            HStack(spacing: 2) {
                Button(isMonitoring ? "Stop Listening" : "Listen to Microphone",
                       systemImage: isMonitoring ? "headphones.circle.fill" : "headphones") {
                    studio.toggleMonitoring(.microphone)
                }
                .foregroundStyle(isMonitoring ? Color.accentColor : Color.primary)
                .disabled(config == nil)
                .help(isMonitoring ? "Stop listening to the microphone" : "Listen to the microphone through the monitor output")

                Menu {
                    Picker("Listen Through", selection: $studio.monitorDeviceUID) {
                        Text("System Default Output").tag("")
                        ForEach(AudioOutputDevices.all()) { Text($0.name).tag($0.id) }
                    }
                } label: {
                    Label("Choose headphones or speakers", systemImage: "speaker.wave.2")
                }
                .menuIndicator(.visible)
                .help("Choose where the microphone is played: headphones or speakers")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.system(size: max(14, height * 0.3)))
        }
        .padding(.horizontal, height * 0.2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(WidgetChrome(enabled: chrome, tint: isMonitoring ? Color.accentColor.opacity(0.25) : nil,
                               radius: height * 0.3))
    }
}

/// Mirrored bars, newest on the right: the shape of the voice over the last few seconds.
struct MicGraph: View {
    let history: [Float]
    var dimmed = false

    var body: some View {
        Canvas { context, size in
            let count = history.count
            guard count > 0 else { return }
            let slot = size.width / CGFloat(count)
            let barWidth = max(1.5, slot * 0.62)
            let mid = size.height / 2
            // Baseline so a silent mic still reads as a graph, not an empty box.
            context.fill(Path(CGRect(x: 0, y: mid - 0.5, width: size.width, height: 1)), with: .color(.primary.opacity(0.2)))
            for (index, db) in history.enumerated() {
                let level = CGFloat(min(max((db - AudioLevels.floor) / -AudioLevels.floor, 0), 1))
                let half = max(0.5, level * mid)
                let color: Color = db > -6 ? Theme.zoneDanger : (db > -18 ? Theme.zoneCaution : Theme.zoneNormal)
                let x = CGFloat(index) * slot + (slot - barWidth) / 2
                let age = 0.35 + 0.65 * Double(index) / Double(count)
                context.fill(Path(roundedRect: CGRect(x: x, y: mid - half, width: barWidth, height: half * 2),
                                  cornerRadius: barWidth / 2),
                             with: .color(color.opacity((dimmed ? 0.3 : 1) * age)))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Dispatcher

/// One widget drawn at the right size for its style.
struct StatWidgetFace: View {
    @Environment(StudioController.self) private var studio
    let widget: StatWidget
    /// Height of one grid cell, or the bar height for bar widgets.
    let unit: CGFloat
    var chrome = true

    var body: some View {
        if widget.metric == .microphone {
            MicGraphWidgetView(height: unit, chrome: chrome)
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let reading = studio.reading(of: widget.metric, now: context.date)
                switch widget.style {
                case .label:
                    LabelWidgetView(reading: reading)
                case .gauge where widget.metric.supportsGauge:
                    GaugeWidgetView(reading: reading, chrome: chrome)
                default:
                    NumberWidgetView(reading: reading, height: unit, chrome: chrome)
                }
            }
        }
    }
}
