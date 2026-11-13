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
        .onExitCommand { if mode == .fullscreen { studio.setFullscreenPreview(false) } }
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
                    .help("Drag widgets onto grid cells, change their style or remove them (E)")
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
                    Canvas { context, _ in
                        for row in 0..<rows {
                            for column in 0..<WidgetLayout.columns {
                                let rect = CGRect(x: CGFloat(column) * cell + cell / 2 - 1.5, y: CGFloat(row) * cell + cell / 2 - 1.5,
                                                  width: 3, height: 3)
                                context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.4)))
                            }
                        }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                ForEach(layout.grid) { widget in
                    GridWidgetView(widget: widget, cell: cell, rows: rows)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .onChange(of: rows, initial: true) { layout.rows = rows }
        }
    }
}

private struct GridWidgetView: View {
    @Environment(StudioController.self) private var studio
    let widget: StatWidget
    let cell: CGFloat
    let rows: Int
    @State private var drag = CGSize.zero

    var body: some View {
        let layout = studio.widgets
        let spot = layout.clamped(widget, rows: rows)
        let size = widget.style.gridSize
        let inset: CGFloat = 5
        let width = CGFloat(size.columns) * cell - inset * 2
        let height = CGFloat(size.rows) * cell - inset * 2

        StatWidgetFace(widget: widget, unit: cell - inset * 2)
            .frame(width: width, height: height)
            .overlay {
                if layout.isEditing {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(.white.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                }
            }
            .overlay(alignment: .topTrailing) {
                if layout.isEditing { editButtons }
            }
            .offset(x: CGFloat(spot.column) * cell + inset + drag.width,
                    y: CGFloat(spot.row) * cell + inset + drag.height)
            .zIndex(drag == .zero ? 0 : 1)
            .gesture(dragGesture(layout: layout, spot: spot), including: layout.isEditing ? .all : .subviews)
    }

    private var editButtons: some View {
        let layout = studio.widgets
        return HStack(spacing: Theme.spacingXS) {
            if widget.metric.supportsGauge {
                Button(widget.style == .gauge ? "Show as Number" : "Show as Speedometer",
                       systemImage: widget.style == .gauge ? "number" : "gauge.with.needle") {
                    withAnimation(.smooth(duration: 0.25)) {
                        layout.setGridStyle(widget.id, widget.style == .gauge ? .number : .gauge, rows: rows)
                    }
                }
            }
            Button("Remove \(widget.metric.title)", systemImage: "xmark") {
                withAnimation(.smooth(duration: 0.25)) { layout.grid.removeAll { $0.id == widget.id } }
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.glass)
        .controlSize(.small)
        .padding(Theme.spacingS)
    }

    private func dragGesture(layout: WidgetLayout, spot: (column: Int, row: Int)) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { drag = $0.translation }
            .onEnded { value in
                let column = Int((CGFloat(spot.column) + value.translation.width / cell).rounded())
                let row = Int((CGFloat(spot.row) + value.translation.height / cell).rounded())
                withAnimation(.smooth(duration: 0.2)) {
                    layout.move(widget.id, toColumn: column, row: row, rows: rows)
                    drag = .zero
                }
            }
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
                Text("Drag them into place with Edit Widgets in fullscreen or the pop-out window.")
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
        .frame(width: 380)
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
        for widget in layout.grid { layout.move(widget.id, toColumn: widget.column, row: widget.row, rows: layout.rows) }
    }

    private func styles(for metric: StatMetric, allowsLabel: Bool) -> [WidgetStyle] {
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
