//
//  StatWidget.swift
//  Streamio
//
//  What a widget can show (StatMetric), how it is drawn (WidgetStyle) and where it sits
//  (StatWidget). The same item type fills the bottom bar (ordered) and the preview grid
//  (placed by column and row).
//

import Foundation

nonisolated enum StatMetric: String, Codable, CaseIterable, Identifiable, Sendable {
    case live, rec, fps, cameraFPS, render, cpu, gpu, memory, bitrate, dropped, disk, ping, microphone, buffer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .live: "Stream"
        case .rec: "Recording"
        case .fps: "FPS"
        case .cameraFPS: "Camera FPS"
        case .render: "Render time"
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "Memory"
        case .bitrate: "Bitrate"
        case .dropped: "Dropped frames"
        case .disk: "Free disk"
        case .ping: "Ping"
        case .microphone: "Microphone level"
        case .buffer: "Send buffer"
        }
    }

    var symbol: String {
        switch self {
        case .live: "dot.radiowaves.left.and.right"
        case .rec: "record.circle"
        case .fps: "film"
        case .cameraFPS: "web.camera"
        case .render: "timer"
        case .cpu: "cpu"
        case .gpu: "rectangle.3.group"
        case .memory: "memorychip"
        case .bitrate: "speedometer"
        case .dropped: "exclamationmark.triangle"
        case .disk: "internaldrive"
        case .ping: "network"
        case .microphone: "mic.fill"
        case .buffer: "tray.full"
        }
    }

    /// Metrics with a meaningful 0...1 range can be drawn as a speedometer.
    var supportsGauge: Bool {
        switch self {
        case .live, .rec, .disk, .microphone: false
        default: true
        }
    }
}

nonisolated enum WidgetStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Small text label with an icon. Bottom bar only.
    case label
    /// Big number in a wide tile.
    case number
    /// Square speedometer tile.
    case gauge
    /// Level graph behind a small readout and a listen button. Microphone only.
    case graph

    var id: String { rawValue }

    var title: String {
        switch self {
        case .label: "Label"
        case .number: "Number"
        case .gauge: "Speedometer"
        case .graph: "Level graph"
        }
    }

    /// Smallest cells covered on the preview grid; widgets can be resized up from here.
    var gridSize: (columns: Int, rows: Int) {
        switch self {
        case .label, .number: (2, 1)
        case .gauge: (2, 2)
        case .graph: (2, 1)
        }
    }
}

nonisolated struct StatWidget: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var metric: StatMetric
    var style: WidgetStyle
    var column = 0
    var row = 0
    /// Columns and rows covered on the preview grid when resized; nil means the style's
    /// smallest size. Optional so layouts saved before resizing existed still decode.
    var width: Int?
    var height: Int?

    /// Cells this widget asks for on the preview grid. Never smaller than its style allows,
    /// and a speedometer always stays square so the dial keeps its shape.
    var gridSize: (columns: Int, rows: Int) {
        StatWidget.size(style: style, columns: width, rows: height)
    }

    /// Size multiple shown in the UI: 1 at the smallest size.
    var scale: Int {
        max(1, gridSize.rows / style.gridSize.rows)
    }

    static func size(style: WidgetStyle, columns: Int?, rows: Int?) -> (columns: Int, rows: Int) {
        let base = style.gridSize
        let wantedColumns = max(base.columns, columns ?? base.columns)
        let wantedRows = max(base.rows, rows ?? base.rows)
        if style == .gauge {
            let side = max(wantedColumns, wantedRows)
            return (side, side)
        }
        return (wantedColumns, wantedRows)
    }
}
