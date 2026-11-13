//
//  StudioStage.swift
//  Streamio
//
//  The program output with its widgets: used for the fullscreen preview and for the
//  pop-out window that can sit on a second display. Widgets live on a 12-column grid of
//  square cells; the bottom bar floats at the foot.
//

import SwiftUI

struct StudioStage: View {
    enum Mode { case fullscreen, popout }

    @Environment(StudioController.self) private var studio
    @FocusState private var isFocused: Bool
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var showsCustomizer = false
    let mode: Mode

    var body: some View {
        let layout = studio.widgets
        ZStack {
            Color.black.ignoresSafeArea()
            ProgramView(cornerRadius: 0) { toggleFullScreen() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay {
            if studio.showsStatsOverlay {
                WidgetGridView()
                    .padding(.horizontal, Theme.spacingL)
                    .padding(.top, 72)
                    .padding(.bottom, layout.showsBar ? 104 : Theme.spacingL)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topLeading) { OnAirBadges().padding(Theme.spacingL) }
        .overlay(alignment: .topTrailing) { controls.padding(Theme.spacingL) }
        .overlay(alignment: .top) {
            if studio.showsStatsOverlay && layout.isEditing {
                WidgetEditHint()
                    .padding(.top, Theme.spacingL)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: layout.isEditing)
        .overlay(alignment: .bottom) {
            if layout.showsBar {
                StatsBar(style: .overlay)
                    .padding(Theme.spacingL)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: studio.showsStatsOverlay)
        .animation(.easeOut(duration: 0.2), value: layout.showsBar)
        .environment(\.colorScheme, .dark)
        .toolbar(.hidden, for: .windowToolbar)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onExitCommand {
            // Esc finishes editing first, then leaves fullscreen.
            if layout.isEditing {
                layout.isEditing = false
            } else if mode == .fullscreen {
                studio.setFullscreenPreview(false)
            }
        }
        .onKeyPress("i") {
            studio.showsStatsOverlay.toggle()
            return .handled
        }
        .onKeyPress("e") {
            layout.isEditing.toggle()
            return .handled
        }
        .onDisappear { layout.isEditing = false }
    }

    private var controls: some View {
        let layout = studio.widgets
        return GlassEffectContainer(spacing: Theme.spacingS) {
            HStack(spacing: Theme.spacingS) {
                if studio.showsStatsOverlay {
                    Button(layout.isEditing ? "Done Editing" : "Edit Widgets",
                           systemImage: layout.isEditing ? "checkmark" : "square.grid.2x2") {
                        layout.isEditing.toggle()
                    }
                    .help("Move, resize, restyle or remove widgets on the preview (E)")
                }
                Button("Customize Widgets", systemImage: "slider.horizontal.3") { showsCustomizer.toggle() }
                    .popover(isPresented: $showsCustomizer, arrowEdge: .bottom) {
                        WidgetCustomizer(initialTab: .preview).environment(studio)
                    }
                    .help("Add, remove and restyle widgets and the bottom bar")
                Button(studio.showsStatsOverlay ? "Hide Widgets" : "Show Widgets", systemImage: studio.showsStatsOverlay ? "eye" : "eye.slash") {
                    studio.showsStatsOverlay.toggle()
                }
                .help("Show or hide the widgets (I)")
                switch mode {
                case .fullscreen:
                    Button("Exit Fullscreen", systemImage: "arrow.down.right.and.arrow.up.left") {
                        studio.setFullscreenPreview(false)
                    }
                    .help("Exit fullscreen (Esc)")
                case .popout:
                    Button("Toggle Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") { toggleFullScreen() }
                        .help("Full screen on this display")
                    Button("Return Preview to Studio", systemImage: "arrow.uturn.backward") {
                        dismissWindow(id: "program")
                    }
                    .help("Close this window and put the preview back in the studio window")
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .controlSize(.large)
        }
    }

    private func toggleFullScreen() {
        switch mode {
        case .fullscreen: studio.setFullscreenPreview(false)
        case .popout: NSApp.keyWindow?.toggleFullScreen(nil)
        }
    }
}

/// The pop-out window's content. Capture needs the permission gate first.
struct ProgramWindowView: View {
    @Environment(StudioController.self) private var studio
    @Environment(PermissionsManager.self) private var permissions

    var body: some View {
        Group {
            if permissions.allGranted {
                StudioStage(mode: .popout)
            } else {
                ContentUnavailableView("Grant access in the studio window first", systemImage: "lock.fill")
            }
        }
        .frame(minWidth: 480, minHeight: 300)
        .containerBackground(.black, for: .window)
        .onAppear { studio.isProgramPoppedOut = true }
        .onDisappear { studio.isProgramPoppedOut = false }
        // Closing the window with its red button must also hand the preview back.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if (note.object as? NSWindow)?.title == StudioController.programWindowTitle { studio.isProgramPoppedOut = false }
        }
    }
}

// MARK: - Grid

struct WidgetGridView: View {
    @Environment(StudioController.self) private var studio

    var body: some View {
        let layout = studio.widgets
        GeometryReader { geo in
            let cell = geo.size.width / CGFloat(WidgetLayout.columns)
            let rows = max(1, Int(geo.size.height / cell))
            ZStack(alignment: .topLeading) {
                if layout.isEditing {
                    // Cell guides: a faint cross at every cell corner, so snapping is predictable.
                    Canvas { context, _ in
                        var marks = Path()
                        for row in 0...rows {
                            for column in 0...WidgetLayout.columns {
                                let x = CGFloat(column) * cell, y = CGFloat(row) * cell
                                marks.move(to: CGPoint(x: x - 4, y: y))
                                marks.addLine(to: CGPoint(x: x + 4, y: y))
                                marks.move(to: CGPoint(x: x, y: y - 4))
                                marks.addLine(to: CGPoint(x: x, y: y + 4))
                            }
                        }
                        context.stroke(marks, with: .color(.white.opacity(0.35)), lineWidth: 1)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .transition(.opacity)
                }
                ForEach(layout.grid) { widget in
                    GridWidgetView(widget: widget, cell: cell, rows: rows)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .animation(.easeOut(duration: 0.15), value: layout.isEditing)
            .onChange(of: rows, initial: true) { layout.rows = rows }
        }
    }
}

/// One widget on the preview grid. In edit mode the tile follows the pointer while an
/// accent outline shows the cells it will snap to; the corner grip resizes it.
private struct GridWidgetView: View {
    @Environment(StudioController.self) private var studio
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let widget: StatWidget
    let cell: CGFloat
    let rows: Int
    @State private var drag = CGSize.zero
    @State private var resize = CGSize.zero
    @State private var isResizing = false

    private static let inset: CGFloat = 5

    var body: some View {
        let layout = studio.widgets
        let spot = layout.clamped(widget, rows: rows)
        let size = layout.fitted(widget, rows: rows)
        let isActive = drag != .zero || isResizing
        let face = liveFrame(size: size, spot: spot)
        let target = snapTarget(layout: layout, spot: spot, size: size)
        let snap: Animation? = reduceMotion ? nil : .smooth(duration: 0.12)

        ZStack(alignment: .topLeading) {
            if layout.isEditing && isActive {
                SnapGhost(label: isResizing ? "\(target.size.columns) × \(target.size.rows)" : nil)
                    .frame(width: CGFloat(target.size.columns) * cell - Self.inset * 2,
                           height: CGFloat(target.size.rows) * cell - Self.inset * 2)
                    .offset(x: CGFloat(target.spot.column) * cell + Self.inset,
                            y: CGFloat(target.spot.row) * cell + Self.inset)
                    .animation(snap, value: target.spot.column)
                    .animation(snap, value: target.spot.row)
                    .animation(snap, value: target.size.columns)
                    .animation(snap, value: target.size.rows)
                    .allowsHitTesting(false)
            }

            StatWidgetFace(widget: widget, unit: min(face.height, face.width / 2))
                .frame(width: face.width, height: face.height)
                .opacity(isActive ? 0.85 : 1)
                .overlay {
                    if layout.isEditing {
                        RoundedRectangle(cornerRadius: faceRadius(face), style: .continuous)
                            .strokeBorder(.white.opacity(isActive ? 1 : 0.7),
                                          style: StrokeStyle(lineWidth: 1.5, dash: isActive ? [] : [6, 4]))
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if layout.isEditing && !isActive { editButtons(size: size) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if layout.isEditing { resizeGrip(layout: layout, size: size) }
                }
                .contentShape(.rect)
                .pointerStyle(movePointer(isEditing: layout.isEditing))
                .offset(x: CGFloat(spot.column) * cell + Self.inset + drag.width,
                        y: CGFloat(spot.row) * cell + Self.inset + drag.height)
                .gesture(moveGesture(layout: layout, spot: spot), including: layout.isEditing ? .all : .subviews)
        }
        .zIndex(isActive ? 1 : 0)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Make Larger") { grow(layout, by: 1) }
        .accessibilityAction(named: "Make Smaller") { grow(layout, by: -1) }
    }

    /// Size of the tile on screen: its cells, plus the live resize drag (never under the
    /// style's smallest size, never past the grid).
    private func liveFrame(size: (columns: Int, rows: Int), spot: (column: Int, row: Int)) -> CGSize {
        let width = CGFloat(size.columns) * cell - Self.inset * 2
        let height = CGFloat(size.rows) * cell - Self.inset * 2
        guard isResizing else { return CGSize(width: width, height: height) }
        let base = widget.style.gridSize
        let minWidth = CGFloat(base.columns) * cell - Self.inset * 2
        let minHeight = CGFloat(base.rows) * cell - Self.inset * 2
        let maxWidth = CGFloat(WidgetLayout.columns - spot.column) * cell - Self.inset * 2
        let maxHeight = CGFloat(max(base.rows, rows - spot.row)) * cell - Self.inset * 2
        var live = CGSize(width: min(max(minWidth, width + resize.width), maxWidth),
                          height: min(max(minHeight, height + resize.height), maxHeight))
        if widget.style == .gauge {
            let side = min(max(live.width, live.height), maxWidth, maxHeight)
            live = CGSize(width: side, height: side)
        }
        return live
    }

    private func movePointer(isEditing: Bool) -> PointerStyle? {
        guard isEditing else { return nil }
        return drag == .zero ? PointerStyle.grabIdle : PointerStyle.grabActive
    }

    private func faceRadius(_ face: CGSize) -> CGFloat {
        widget.style == .gauge ? 28 : min(face.height, face.width / 2) * 0.3
    }

    /// Cells the widget will occupy when the current drag ends.
    private func snapTarget(layout: WidgetLayout, spot: (column: Int, row: Int), size: (columns: Int, rows: Int))
        -> (spot: (column: Int, row: Int), size: (columns: Int, rows: Int)) {
        if isResizing {
            let wanted = wantedCells(size: size)
            return (spot, layout.resizeTarget(widget.id, columns: wanted.columns, rows: wanted.rows, rows: rows) ?? size)
        }
        if drag != .zero {
            let column = Int((CGFloat(spot.column) + drag.width / cell).rounded())
            let row = Int((CGFloat(spot.row) + drag.height / cell).rounded())
            return (layout.moveTarget(widget.id, toColumn: column, row: row, rows: rows) ?? spot, size)
        }
        return (spot, size)
    }

    private func wantedCells(size: (columns: Int, rows: Int)) -> (columns: Int, rows: Int) {
        let columns = Int((CGFloat(size.columns) + resize.width / cell).rounded())
        let wantedRows = Int((CGFloat(size.rows) + resize.height / cell).rounded())
        if widget.style == .gauge {
            // A dial grows along whichever edge was pulled further.
            let side = abs(resize.width) >= abs(resize.height) ? columns : wantedRows
            return (side, side)
        }
        return (columns, wantedRows)
    }

    private func editButtons(size: (columns: Int, rows: Int)) -> some View {
        let layout = studio.widgets
        let canGrow = layout.canGrow(widget.id, rows: rows)
        let isSmallest = size == widget.style.gridSize
        return GlassEffectContainer(spacing: Theme.spacingXS) {
            HStack(spacing: Theme.spacingXS) {
                if widget.metric.supportsGauge {
                    Button(widget.style == .gauge ? "Show \(widget.metric.title) as Number" : "Show \(widget.metric.title) as Speedometer",
                           systemImage: widget.style == .gauge ? "number" : "gauge.with.needle") {
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
                            layout.setGridStyle(widget.id, widget.style == .gauge ? .number : .gauge, rows: rows)
                        }
                    }
                    .help(widget.style == .gauge ? "Show as a number" : "Show as a speedometer")
                }
                Button("Make \(widget.metric.title) Smaller", systemImage: "minus") { grow(layout, by: -1) }
                    .disabled(isSmallest)
                    .help(isSmallest ? "Already the smallest size" : "Smaller (or drag the corner)")
                Button("Make \(widget.metric.title) Larger", systemImage: "plus") { grow(layout, by: 1) }
                    .disabled(!canGrow)
                    .help(canGrow ? "Larger (or drag the corner)" : "No room to grow here; move it first")
                Button("Remove \(widget.metric.title)", systemImage: "xmark") {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { layout.grid.removeAll { $0.id == widget.id } }
                }
                .help("Remove from the preview")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .controlSize(.small)
        }
        .padding(Theme.spacingS)
    }

    private func resizeGrip(layout: WidgetLayout, size: (columns: Int, rows: Int)) -> some View {
        ResizeGrip()
            .frame(width: 28, height: 28)
            .contentShape(.rect)
            .padding(Theme.spacingXS)
            .pointerStyle(.frameResize(position: .bottomTrailing))
            .help("Drag to resize")
            .accessibilityLabel("Resize \(widget.metric.title)")
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        isResizing = true
                        resize = value.translation
                    }
                    .onEnded { _ in
                        let wanted = wantedCells(size: size)
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) {
                            layout.resize(widget.id, columns: wanted.columns, rows: wanted.rows, rows: rows)
                            resize = .zero
                            isResizing = false
                        }
                    }
            )
    }

    private func grow(_ layout: WidgetLayout, by delta: Int) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { layout.step(widget.id, by: delta, rows: rows) }
    }

    private func moveGesture(layout: WidgetLayout, spot: (column: Int, row: Int)) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard !isResizing else { return }
                drag = value.translation
            }
            .onEnded { value in
                guard !isResizing else { return }
                let column = Int((CGFloat(spot.column) + value.translation.width / cell).rounded())
                let row = Int((CGFloat(spot.row) + value.translation.height / cell).rounded())
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) {
                    layout.move(widget.id, toColumn: column, row: row, rows: rows)
                    drag = .zero
                }
            }
    }
}

/// Where a dragged widget will land: the cells it snaps to, with its size while resizing.
private struct SnapGhost: View {
    var label: String?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        shape.fill(Color.accentColor.opacity(0.22))
            .overlay { shape.strokeBorder(Color.accentColor, lineWidth: 2) }
            .overlay {
                if let label {
                    Text(label)
                        .font(.headline.monospacedDigit())
                        .padding(.horizontal, Theme.spacingS)
                        .padding(.vertical, Theme.spacingXS)
                        .background(.black.opacity(0.7), in: .capsule)
                        .foregroundStyle(.white)
                }
            }
            .accessibilityHidden(true)
    }
}

/// Two short diagonal strokes in the corner, the usual "pull here" mark.
private struct ResizeGrip: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            for step in [0.35, 0.65] {
                path.move(to: CGPoint(x: size.width * step, y: size.height - 4))
                path.addLine(to: CGPoint(x: size.width - 4, y: size.height * step))
            }
            context.stroke(path, with: .color(.black.opacity(0.55)), style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
            context.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
    }
}

/// Floating hint while editing, so moving and resizing need no guesswork.
struct WidgetEditHint: View {
    @Environment(StudioController.self) private var studio

    var body: some View {
        HStack(spacing: Theme.spacingL) {
            Label("Drag to move", systemImage: "hand.draw")
            Label("Drag the corner to resize", systemImage: "arrow.down.right")
            Button("Done") { studio.widgets.isEditing = false }
                .buttonStyle(.glassProminent)
                .help("Finish editing (E or Esc)")
        }
        .font(.callout)
        .padding(.leading, Theme.spacingL)
        .padding(.trailing, Theme.spacingS)
        .padding(.vertical, Theme.spacingS)
        .glassEffect(.regular, in: .capsule)
    }
}

// MARK: - Customizer

struct WidgetCustomizer: View {
    enum Tab: String, CaseIterable, Identifiable {
        case bar = "Bottom Bar"
        case preview = "Preview Widgets"
        var id: String { rawValue }
    }

    @Environment(StudioController.self) private var studio
    @State private var tab: Tab

    init(initialTab: Tab) {
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        @Bindable var studio = studio
        @Bindable var layout = studio.widgets
        let current = $tab

        VStack(alignment: .leading, spacing: Theme.spacingM) {
            Picker("Customize", selection: current) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if current.wrappedValue == .bar {
                Toggle("Show bottom bar", isOn: $layout.showsBar)
                list(items: $layout.bar, allowsLabel: true)
            } else {
                Toggle("Show widgets on the preview", isOn: $studio.showsStatsOverlay)
                list(items: $layout.grid, allowsLabel: false)
                Text("Pick a size here, or use Edit Widgets in fullscreen or the pop-out window to drag them into place and pull a corner to resize.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack {
                addMenu(isBar: current.wrappedValue == .bar)
                Spacer()
                Button("Reset All") { layout.reset() }
            }
        }
        .padding(Theme.spacingL)
        .frame(width: 440)
    }

    private func list(items: Binding<[StatWidget]>, allowsLabel: Bool) -> some View {
        List {
            if items.wrappedValue.isEmpty {
                Text(allowsLabel ? "The bar is empty. Add a widget below." : "No widgets. Add one below.")
                    .foregroundStyle(.secondary)
            }
            ForEach(items) { $item in
                HStack {
                    Label(item.metric.title, systemImage: item.metric.symbol)
                    Spacer()
                    Picker("Style of \(item.metric.title)", selection: $item.style) {
                        ForEach(styles(for: item.metric, allowsLabel: allowsLabel)) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    if !allowsLabel { sizeMenu(for: item) }
                    Button("Remove \(item.metric.title)", systemImage: "minus.circle.fill") {
                        items.wrappedValue.removeAll { $0.id == item.id }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                }
            }
            .onMove { items.wrappedValue.move(fromOffsets: $0, toOffset: $1) }
        }
        .frame(height: 280)
        .onChange(of: items.wrappedValue.map(\.style)) {
            if !allowsLabel { fitGrid() }
        }
    }

    /// A style change can make a grid widget overlap its neighbour; let the layout re-seat it.
    private func fitGrid() {
        let layout = studio.widgets
        for widget in layout.grid {
            layout.move(widget.id, toColumn: widget.column, row: widget.row, rows: layout.rows)
            let size = widget.gridSize
            layout.resize(widget.id, columns: size.columns, rows: size.rows, rows: layout.rows)
        }
    }

    /// Preset sizes for a preview widget, in whole steps of its smallest size.
    private func sizeMenu(for item: StatWidget) -> some View {
        let layout = studio.widgets
        let base = item.style.gridSize
        let current = layout.fitted(item, rows: layout.rows)
        let names = ["Small", "Medium", "Large", "Extra large"]
        return Menu {
            ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                let scale = index + 1
                Button("\(name)  \(base.columns * scale) × \(base.rows * scale)") {
                    withAnimation(.smooth(duration: 0.25)) {
                        layout.resize(item.id, columns: base.columns * scale, rows: base.rows * scale, rows: layout.rows)
                    }
                }
            }
        } label: {
            Text("\(current.columns) × \(current.rows)").monospacedDigit()
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Size on the preview, in grid cells. Larger sizes shrink to fit the free space.")
        .accessibilityLabel("Size of \(item.metric.title)")
    }

    private func styles(for metric: StatMetric, allowsLabel: Bool) -> [WidgetStyle] {
        if metric == .microphone { return [.graph] }
        var styles: [WidgetStyle] = allowsLabel ? [.label, .number] : [.number]
        if metric.supportsGauge { styles.append(.gauge) }
        return styles
    }

    private func addMenu(isBar: Bool) -> some View {
        let layout = studio.widgets
        return Menu("Add Widget", systemImage: "plus") {
            ForEach(StatMetric.allCases) { metric in
                Menu(metric.title) {
                    ForEach(styles(for: metric, allowsLabel: isBar)) { style in
                        Button(style.title) {
                            if isBar {
                                layout.addToBar(metric, style: style)
                            } else {
                                layout.addToGrid(metric, style: style, rows: layout.rows)
                            }
                        }
                    }
                }
            }
        }
        .fixedSize()
    }
}
