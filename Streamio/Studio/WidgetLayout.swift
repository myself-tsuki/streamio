//
//  WidgetLayout.swift
//  Streamio
//
//  The user's widget setup: an ordered list for the bottom bar (which can be hidden) and a
//  placed list for the 12-column grid over the fullscreen / pop-out preview. Saved on change.
//

import Foundation
import Observation

@Observable
final class WidgetLayout {
    static let columns = 12
    private static let key = "studio.widgets.v1"

    /// Widgets in the bottom bar, left to right.
    var bar: [StatWidget] { didSet { save() } }
    var showsBar: Bool { didSet { save() } }
    /// Widgets placed on the preview grid.
    var grid: [StatWidget] { didSet { save() } }
    /// Drag, resize and remove widgets right on the preview.
    var isEditing = false
    /// Rows the grid currently fits; set by the grid view so add and move can stay inside it.
    @ObservationIgnored var rows = 6

    private struct Snapshot: Codable {
        var bar: [StatWidget]
        var showsBar: Bool
        var grid: [StatWidget]
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            bar = snapshot.bar
            showsBar = snapshot.showsBar
            grid = snapshot.grid
        } else {
            bar = Self.defaultBar
            showsBar = true
            grid = Self.defaultGrid
        }
    }

    static var defaultBar: [StatWidget] {
        [.live, .rec, .fps, .cameraFPS, .cpu, .gpu, .memory, .bitrate, .dropped]
            .map { StatWidget(metric: $0, style: .label) }
    }

    static var defaultGrid: [StatWidget] {
        [StatWidget(metric: .bitrate, style: .gauge, column: 10, row: 0),
         StatWidget(metric: .cpu, style: .number, column: 10, row: 2),
         StatWidget(metric: .gpu, style: .number, column: 10, row: 3),
         StatWidget(metric: .ping, style: .number, column: 10, row: 4)]
    }

    func reset() {
        bar = Self.defaultBar
        showsBar = true
        grid = Self.defaultGrid
    }

    private func save() {
        let snapshot = Snapshot(bar: bar, showsBar: showsBar, grid: grid)
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    // MARK: Bar

    func addToBar(_ metric: StatMetric, style: WidgetStyle) {
        bar.append(StatWidget(metric: metric, style: style))
        showsBar = true
    }

    func setBarStyle(_ id: UUID, _ style: WidgetStyle) {
        guard let index = bar.firstIndex(where: { $0.id == id }) else { return }
        bar[index].style = style
    }

    // MARK: Grid

    /// Adds a widget at the first free spot, or the top-left corner when the grid is full.
    func addToGrid(_ metric: StatMetric, style: WidgetStyle, rows: Int) {
        var widget = StatWidget(metric: metric, style: style)
        let spot = nearestFreeSpot(for: widget, near: (0, 0), rows: rows)
        widget.column = spot.column
        widget.row = spot.row
        grid.append(widget)
    }

    func setGridStyle(_ id: UUID, _ style: WidgetStyle, rows: Int) {
        guard let index = grid.firstIndex(where: { $0.id == id }) else { return }
        grid[index].style = style
        let spot = nearestFreeSpot(for: grid[index], near: (grid[index].column, grid[index].row), rows: rows)
        grid[index].column = spot.column
        grid[index].row = spot.row
    }

    /// Snaps a dropped widget to the nearest cell where it fits without overlapping another.
    func move(_ id: UUID, toColumn column: Int, row: Int, rows: Int) {
        guard let index = grid.firstIndex(where: { $0.id == id }) else { return }
        let spot = nearestFreeSpot(for: grid[index], near: (column, row), rows: rows)
        grid[index].column = spot.column
        grid[index].row = spot.row
    }

    func clamped(_ widget: StatWidget, rows: Int) -> (column: Int, row: Int) {
        let size = widget.style.gridSize
        return (min(max(0, widget.column), max(0, Self.columns - size.columns)),
                min(max(0, widget.row), max(0, rows - size.rows)))
    }

    private func nearestFreeSpot(for widget: StatWidget, near target: (column: Int, row: Int), rows: Int) -> (column: Int, row: Int) {
        let size = widget.style.gridSize
        let maxColumn = max(0, Self.columns - size.columns)
        let maxRow = max(0, rows - size.rows)
        let others = grid.filter { $0.id != widget.id }
        let wantedColumn = min(max(0, target.column), maxColumn)
        let wantedRow = min(max(0, target.row), maxRow)

        var best: (column: Int, row: Int)?
        var bestDistance = Int.max
        for row in 0...maxRow {
            for column in 0...maxColumn where !overlaps(column, row, size, others, rows: rows) {
                let distance = (column - wantedColumn) * (column - wantedColumn) + (row - wantedRow) * (row - wantedRow)
                if distance < bestDistance {
                    bestDistance = distance
                    best = (column, row)
                }
            }
        }
        return best ?? (wantedColumn, wantedRow)
    }

    private func overlaps(_ column: Int, _ row: Int, _ size: (columns: Int, rows: Int), _ others: [StatWidget], rows: Int) -> Bool {
        others.contains { other in
            let spot = clamped(other, rows: rows)
            let otherSize = other.style.gridSize
            return column < spot.column + otherSize.columns && spot.column < column + size.columns
                && row < spot.row + otherSize.rows && spot.row < row + size.rows
        }
    }
}
