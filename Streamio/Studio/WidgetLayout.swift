//
//  WidgetLayout.swift
//  Streamio
//
//  The user's widget setup: an ordered list for the bottom bar (which can be hidden) and a
//  placed list for the 12-column grid over the fullscreen / pop-out preview. Grid widgets can
//  be moved and resized in whole cells; they never overlap. Saved on change.
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
    private let defaults: UserDefaults?

    private struct Snapshot: Codable {
        var bar: [StatWidget]
        var showsBar: Bool
        var grid: [StatWidget]
    }

    /// `defaults: nil` keeps the layout in memory only (used by the checks).
    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        if let data = defaults?.data(forKey: Self.key),
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
        guard let defaults else { return }
        let snapshot = Snapshot(bar: bar, showsBar: showsBar, grid: grid)
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Self.key)
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

    /// A new style starts at that style's smallest size, then finds room near where it was.
    func setGridStyle(_ id: UUID, _ style: WidgetStyle, rows: Int) {
        guard let index = grid.firstIndex(where: { $0.id == id }) else { return }
        grid[index].style = style
        grid[index].width = nil
        grid[index].height = nil
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

    /// Where a widget dragged towards (column, row) would land. Lets the view draw the
    /// snapped outline while the drag is still going.
    func moveTarget(_ id: UUID, toColumn column: Int, row: Int, rows: Int) -> (column: Int, row: Int)? {
        guard let widget = grid.first(where: { $0.id == id }) else { return nil }
        return nearestFreeSpot(for: widget, near: (column, row), rows: rows)
    }

    /// The size a widget would take when resized towards (columns, rows) from its top-left
    /// corner: at least its style's smallest size, inside the grid and short of any neighbour.
    func resizeTarget(_ id: UUID, columns: Int, rows wantedRows: Int, rows: Int) -> (columns: Int, rows: Int)? {
        guard let widget = grid.first(where: { $0.id == id }) else { return nil }
        let spot = clamped(widget, rows: rows)
        let others = grid.filter { $0.id != id }
        let base = widget.style.gridSize
        let maxColumns = max(base.columns, Self.columns - spot.column)
        let maxRows = max(base.rows, rows - spot.row)
        let wanted = StatWidget.size(style: widget.style, columns: min(columns, maxColumns), rows: min(wantedRows, maxRows))

        // Largest size no bigger than asked for that fits where the widget stands.
        var best: (columns: Int, rows: Int)?
        var bestScore = (area: -1, distance: Int.max)
        for c in base.columns...max(base.columns, wanted.columns) {
            for r in base.rows...max(base.rows, wanted.rows) {
                let size = StatWidget.size(style: widget.style, columns: c, rows: r)
                guard size.columns == c, size.rows == r,
                      spot.column + c <= Self.columns, spot.row + r <= max(rows, base.rows),
                      !overlaps(spot.column, spot.row, size, others, rows: rows) else { continue }
                let distance = (wanted.columns - c) * (wanted.columns - c) + (wanted.rows - r) * (wanted.rows - r)
                let area = c * r
                if distance < bestScore.distance || (distance == bestScore.distance && area > bestScore.area) {
                    bestScore = (area, distance)
                    best = size
                }
            }
        }
        return best ?? fitted(widget, rows: rows)
    }

    func resize(_ id: UUID, columns: Int, rows wantedRows: Int, rows: Int) {
        guard let index = grid.firstIndex(where: { $0.id == id }),
              let size = resizeTarget(id, columns: columns, rows: wantedRows, rows: rows) else { return }
        let base = grid[index].style.gridSize
        grid[index].width = size.columns == base.columns ? nil : size.columns
        grid[index].height = size.rows == base.rows ? nil : size.rows
        let spot = clamped(grid[index], rows: rows)
        grid[index].column = spot.column
        grid[index].row = spot.row
    }

    /// Grows or shrinks by whole steps of the style's smallest size (1×, 2×, 3×…), keeping
    /// the widget's proportions.
    func step(_ id: UUID, by delta: Int, rows: Int) {
        guard let widget = grid.first(where: { $0.id == id }) else { return }
        let base = widget.style.gridSize
        let scale = max(1, widget.scale + delta)
        resize(id, columns: base.columns * scale, rows: base.rows * scale, rows: rows)
    }

    /// Whether a widget has room to grow one step, so the + button can be disabled.
    func canGrow(_ id: UUID, rows: Int) -> Bool {
        guard let widget = grid.first(where: { $0.id == id }) else { return false }
        let base = widget.style.gridSize
        let next = widget.scale + 1
        guard let size = resizeTarget(id, columns: base.columns * next, rows: base.rows * next, rows: rows) else { return false }
        let now = fitted(widget, rows: rows)
        return size.columns * size.rows > now.columns * now.rows
    }

    /// The cells a widget actually covers right now: its size, cut down to the grid when the
    /// window is too short for it.
    func fitted(_ widget: StatWidget, rows: Int) -> (columns: Int, rows: Int) {
        let size = widget.gridSize
        let base = widget.style.gridSize
        var columns = min(size.columns, Self.columns)
        var fittedRows = max(base.rows, min(size.rows, rows))
        if widget.style == .gauge {
            let side = max(base.columns, min(columns, fittedRows))
            columns = side
            fittedRows = side
        }
        return (columns, fittedRows)
    }

    func clamped(_ widget: StatWidget, rows: Int) -> (column: Int, row: Int) {
        let size = fitted(widget, rows: rows)
        return (min(max(0, widget.column), max(0, Self.columns - size.columns)),
                min(max(0, widget.row), max(0, rows - size.rows)))
    }

    private func nearestFreeSpot(for widget: StatWidget, near target: (column: Int, row: Int), rows: Int) -> (column: Int, row: Int) {
        let size = fitted(widget, rows: rows)
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
            let otherSize = fitted(other, rows: rows)
            return column < spot.column + otherSize.columns && spot.column < column + size.columns
                && row < spot.row + otherSize.rows && spot.row < row + size.rows
        }
    }
}
