import SwiftUI
import UIKit

/// PCB editor (parts 4 + 5) — a WORKING editor modelled on KiCad
/// 10's PCB editor (pcbnew): merged title/table bar on top, menu
/// strip, icon strip, tool rail on the left, board canvas in the
/// centre, Layers / Objects / Components panels on the right,
/// KiCad-style status bar along the bottom.
///
/// Everything visible does something real:
/// - The board is built from a saved connection table (the same
///   tables the schematic editor writes on every save) and "Sync
///   from Schematic" merges a re-read of that table into the board
///   (see PCBBoardState.swift for the merge rules).
/// - Select: tap selects components / traces / vias / zones /
///   graphics; the Multi toggle makes taps ADD to the selection
///   (mixed selections allowed; a trace subtotal shows whenever
///   traces are selected). Dragging a selected component moves the
///   selected components together. Delete removes the selection.
/// - Route Tracks lays real, resizeable copper traces with KiCad's
///   45° bend rule; a width slider lives at the bottom while the
///   tool is active; Apple Pencil hover previews the next segment.
///   Place Via and Fill Zone add real vias and copper fills. Draw
///   Line / Arc / Circle and Text place real board graphics on the
///   ACTIVE layer (any layer can be active; routing and vias still
///   need a copper layer and say so).
/// - Flip Side / Change Layer moves footprints and traces between
///   F.Cu and B.Cu only; footprints mirror KiCad-style (pads,
///   silkscreen and text mirror; pin↔pad bindings stay exact).
/// - The snap grid is adjustable IN MILS and applies to every
///   placement and move; the copper layer count is configurable
///   per board (items on removed layers are kept, hidden and
///   listed in Problems — never silently dropped).
/// - Checking, three tiers: the clearance (net-touch) check feeds
///   Problems live; "Manufacturing Check" runs a deterministic
///   rule set; "Theory Check" runs deterministic heuristics plus
///   an optional, fully on-device AI pass (see PCBDesignChecks).
/// - All board work persists per schematic table as a JSON sidecar
///   in Documents/Boards and reloads on open.
///
/// Board coordinates are KiCad PCB coordinates: millimetres, x
/// right, y DOWN — the canvas maps them straight to the screen
/// (NO y-flip; flipping would mirror every footprint).
struct PCBEditorView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var footprintStore: FootprintStore
    @Environment(\.dismiss) private var dismiss

    /// The left-rail tools (also the Place/Tools menu targets).
    enum PCBTool: String, CaseIterable {
        case select = "Select"
        case highlightNet = "Highlight Net"
        case delete = "Delete"
        case route = "Route Tracks"
        case drawLine = "Draw Line"
        case drawArc = "Draw Arc"
        case drawCircle = "Draw Circle"
        case text = "Text"
        case placeVia = "Place Via"
        case fillZone = "Fill Zone"

        var icon: String {
            switch self {
            case .select: return "cursorarrow"
            case .highlightNet: return "bolt"
            case .delete: return "trash"
            case .route: return "point.3.connected.trianglepath.dotted"
            case .drawLine: return "line.diagonal"
            case .drawArc: return "moon"
            case .drawCircle: return "circle"
            case .text: return "textformat"
            case .placeVia: return "circle.circle"
            case .fillZone: return "hexagon"
            }
        }
    }

    /// What the canvas has selected — one board item. The editor
    /// keeps a SET of these (multi-select, part 5) plus a primary
    /// (the most recently tapped) whose detail the panel shows.
    enum BoardSelection: Equatable, Hashable {
        case component(String)
        case trace(UUID)
        case graphic(UUID)
        case via(UUID)
        case zone(UUID)
    }

    private enum DragMode {
        case undecided, pan, moveComponents, moveVia
    }

    /// Which chooser the net-picker sheet is serving.
    private enum NetChoicePurpose {
        case via(FPPoint)
        case zone
    }

    // Table / model state. `baseModel` is the builder's output for
    // the loaded table; `model` is baseModel + the merged board
    // state — everything on screen reads `model`.
    @State private var tables: [URL] = []
    @State private var selectedURL: URL? = nil
    @State private var baseModel: BoardModel? = nil
    @State private var boardState = BoardState.empty
    @State private var model: BoardModel? = nil
    @State private var tableStem = ""
    @State private var loadError: String? = nil
    @State private var isLoading = false
    @State private var isSyncing = false
    @State private var statusMessage: String? = nil
    @State private var statusIsWarning = false
    @State private var suppressTaskLoad = false
    @State private var undoStack: [BoardState] = []
    @State private var redoStack: [BoardState] = []

    // Canvas state (scale = points per mm; 2.5 pt/mm reads as 100 %)
    @State private var scale: Double = BoardCanvasMetrics.baseScale
    @State private var offset: CGPoint = CGPoint(x: 30, y: 30)
    @State private var dragStartOffset: CGPoint? = nil
    @State private var dragMode: DragMode = .undecided
    /// Group move (part 5): every selected component's start origin,
    /// and the live preview origins while dragging.
    @State private var moveStartOrigins: [String: FPPoint] = [:]
    @State private var movePreviewOrigins: [String: FPPoint] = [:]
    @State private var movingViaID: UUID? = nil
    @State private var moveViaStart: FPPoint? = nil
    @State private var moveViaPreview: FPPoint? = nil
    /// In Multi mode, the component a press started on: if the
    /// press ends as a tap, it toggles; if it becomes a drag, the
    /// selected group moves. (Decided at drag end — see canvasDrag.)
    @State private var dragTapReference: String? = nil
    @State private var pinchStartScale: Double? = nil
    /// The canvas's ONE pointer stream (part 5.0.1): hover (UIKit
    /// recognizer) and touch (drag gesture) both feed
    /// `BoardPointerState`; previews follow its `currentPoint` —
    /// the touch point while a touch is down, else the hover
    /// point. (v5.0 kept two optionals and preferred the touch one
    /// forever once set, which froze the hover preview at the
    /// first tap — see PCBBoardState.swift.)
    @State private var pointerState = BoardPointerState()
    @State private var canvasSize: CGSize = .zero
    @State private var showGrid = true
    @State private var highlightActiveLayer = false

    // Editor state
    @State private var activeTool: PCBTool = .select
    @State private var activePanelTab = "Layers"
    @State private var visibility = BoardVisibility()
    @State private var selectionFilter = BoardSelectionFilter()
    @State private var selections: Set<BoardSelection> = []
    @State private var primarySelection: BoardSelection? = nil
    @State private var multiSelect = false
    @State private var highlightedNet: String? = nil
    /// The ACTIVE layer (part 5): any layer can be active — draw
    /// tools draw here; routing/vias require a copper layer.
    @State private var activeLayer = "F.Cu"
    /// Snap-to-grid master switch (the spacing itself is board
    /// state: `boardState.gridMil`, adjustable in mils).
    @State private var snapEnabled = true

    // Routing state (Route Tracks tool)
    @State private var routePoints: [FPPoint] = []
    @State private var routeNet: String? = nil
    @State private var currentTrackWidth: Double = 0.25
    @AppStorage("padcb.defaultTrackWidth") private var defaultTrackWidth: Double = 0.25

    // Via placement state
    @State private var currentViaDiameter = 0.8
    @State private var currentViaDrill = 0.4

    // Zone drawing state: vertices collected toward a fill.
    @State private var zonePoints: [FPPoint] = []

    // Draw-tool state: taps collected toward a line / arc / circle
    @State private var pendingPoints: [FPPoint] = []
    // Text placement
    @State private var textAnchor: FPPoint? = nil
    @State private var textDraft = ""
    @State private var showTextPrompt = false
    // Board statistics alert
    @State private var showStats = false
    // Checker sheets + net picker + custom-value alerts (part 5)
    @State private var showManufacturing = false
    @State private var showTheory = false
    @State private var netChoicePurpose: NetChoicePurpose? = nil
    @State private var showGridCustom = false
    @State private var showClearanceCustom = false
    @State private var customValueDraft = ""

    // Checker caches, recomputed whenever the model changes
    // (connectivity feeds pin status + Inspect; clearance feeds
    // Problems). See refreshChecks().
    @State private var connectivity: [String: NetConnectivity] = [:]
    @State private var clearanceViolations: [ClearanceViolation] = []

    /// Per-layer display colours. Copper rows are generated from
    /// the board's copper count (inner layers cycle the palette);
    /// the named rows keep the part-4 colours.
    private static let namedLayerColors: [String: Color] = [
        "F.Cu": Color(red: 0.85, green: 0.25, blue: 0.2),
        "B.Cu": Color(red: 0.25, green: 0.45, blue: 0.9),
        "F.Adhes": Color(red: 0.7, green: 0.3, blue: 0.7),
        "B.Adhes": Color(red: 0.45, green: 0.3, blue: 0.7),
        "F.Paste": Color(red: 0.6, green: 0.6, blue: 0.65),
        "B.Paste": Color(red: 0.5, green: 0.55, blue: 0.7),
        "F.SilkS": Color(red: 0.95, green: 0.9, blue: 0.6),
        "B.SilkS": Color(red: 0.6, green: 0.75, blue: 0.75),
        "F.Mask": Color(red: 0.55, green: 0.2, blue: 0.55),
        "B.Mask": Color(red: 0.25, green: 0.35, blue: 0.6),
        "Dwgs.User": Color(red: 0.65, green: 0.65, blue: 0.65),
        "Edge.Cuts": Color(red: 0.95, green: 0.85, blue: 0.2),
        "F.CrtYd": Color(red: 0.8, green: 0.8, blue: 0.8),
        "B.CrtYd": Color(red: 0.55, green: 0.55, blue: 0.55),
        "F.Fab": Color(red: 0.75, green: 0.75, blue: 0.7),
        "B.Fab": Color(red: 0.5, green: 0.55, blue: 0.55),
    ]
    private static let innerCopperPalette: [Color] = [
        Color(red: 0.9, green: 0.6, blue: 0.2),
        Color(red: 0.6, green: 0.75, blue: 0.25),
        Color(red: 0.3, green: 0.7, blue: 0.6),
        Color(red: 0.65, green: 0.45, blue: 0.85),
    ]

    /// Colour for an inner copper layer ("In3.Cu"): cycles the
    /// inner palette by layer number.
    private static func innerCopperColor(_ name: String) -> Color {
        let digits = name.dropFirst(2).dropLast(3) // "In3.Cu" -> "3"
        let number = Int(digits) ?? 1
        return innerCopperPalette[(number - 1) % innerCopperPalette.count]
    }

    /// The Layers-panel rows for the CURRENT board: its copper
    /// stack first, then the fixed non-copper layers.
    private var layerRows: [(name: String, color: Color)] {
        let copper = BoardLayers.copperLayers(count: boardState.copperLayerCount)
        return copper.map { name in
            (name, Self.namedLayerColors[name] ?? Self.innerCopperColor(name))
        } + BoardLayers.nonCopperLayers.map { name in
            (name, Self.namedLayerColors[name] ?? .gray)
        }
    }

    private func layerColor(_ name: String) -> Color {
        Self.namedLayerColors[name] ?? layerRows.first { $0.name == name }?.color
            ?? Color(red: 0.85, green: 0.3, blue: 0.25)
    }

    // MARK: - Selection helpers (multi-select, part 5)

    private var selectedComponent: BoardComponent? {
        guard case .component(let reference)? = primarySelection else { return nil }
        return model?.components.first { $0.reference == reference }
    }

    private var selectedTrace: BoardTrace? {
        guard case .trace(let id)? = primarySelection else { return nil }
        return model?.traces.first { $0.id == id }
    }

    private var selectedGraphic: BoardGraphicItem? {
        guard case .graphic(let id)? = primarySelection else { return nil }
        return model?.graphics.first { $0.id == id }
    }

    private var selectedVia: BoardVia? {
        guard case .via(let id)? = primarySelection else { return nil }
        return model?.vias.first { $0.id == id }
    }

    private var selectedZone: BoardZone? {
        guard case .zone(let id)? = primarySelection else { return nil }
        return model?.zones.first { $0.id == id }
    }

    private var selectedTraces: [BoardTrace] {
        guard let model else { return [] }
        return model.traces.filter {
            selections.contains(.trace($0.id))
        }
    }

    private func selectOnly(_ item: BoardSelection?) {
        selections = item.map { [$0] } ?? []
        primarySelection = item
    }

    private func toggleSelection(_ item: BoardSelection) {
        if selections.contains(item) {
            selections.remove(item)
            if primarySelection == item { primarySelection = selections.first }
        } else {
            selections.insert(item)
            primarySelection = item
        }
    }

    /// Tap semantics shared by the select tool: with Multi on, taps
    /// toggle; off, a tap replaces the selection (v4 behaviour).
    private func applyTapSelection(_ item: BoardSelection) {
        if multiSelect { toggleSelection(item) } else { selectOnly(item) }
    }

    private func clearSelection() {
        selections = []
        primarySelection = nil
    }

    /// "3 objects · 2 traces · 25.40 mm · 1000 mil total" — the
    /// traces subtotal Sean pinned: shown whenever the selection
    /// contains traces, in single AND mixed selections.
    private var selectionSummaryText: String? {
        guard !selections.isEmpty else { return nil }
        var text = selections.count == 1 ? "1 object" : "\(selections.count) objects"
        let traces = selectedTraces
        if !traces.isEmpty {
            let total = traces.reduce(0) { $0 + $1.length }
            text += " · \(traces.count) trace\(traces.count == 1 ? "" : "s")"
                + " · \(BoardUnits.formatLength(mm: total)) total"
        }
        return text
    }

    private var problemCount: Int {
        guard let model else { return 0 }
        return model.globalAnomalies.count + model.boardProblems.count
            + model.components.reduce(0) { $0 + $1.anomalies.count }
            + clearanceViolations.count
    }

    private var routingActive: Bool { !routePoints.isEmpty }
    private var zoneActive: Bool { !zonePoints.isEmpty }

    /// The snap grid in board state is in MILS (Sean's unit); the
    /// canvas works in mm.
    private var gridMM: Double { BoardUnits.mm(fromMil: boardState.gridMil) }

    /// Snap a placement point to the user's grid when snapping is
    /// on. Pad centres are NEVER routed through here (they stay
    /// exact — see the routing code).
    private func snapPoint(_ point: FPPoint) -> FPPoint {
        snapEnabled ? BoardGrid.snap(point, gridMil: boardState.gridMil) : point
    }

    var body: some View {
        ZStack {
            Color(white: 0.08).ignoresSafeArea()
            VStack(spacing: 0) {
                tableBar
                menuStrip
                iconStrip
                Divider()
                centre
                if activeTool == .route {
                    Divider()
                    routeWidthBar
                }
                Divider()
                statusBar
            }
        }
        // Part 4 (Sean): no separate navigation-title row — the back
        // button and "PCB Editor" live in the table bar below, and
        // the reclaimed row goes to the canvas.
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(.dark)
        .focusable()
        .onKeyPress(.escape) { handleEscapeKey(); return .handled }
        .onKeyPress(.delete) { deleteSelection(); return .handled }
        .task {
            currentTrackWidth = defaultTrackWidth
            libraryStore.bootstrap()
            footprintStore.bootstrap()
            tables = ConnectionTableStore.availableTables()
            if selectedURL == nil { selectedURL = tables.first }
        }
        .task(id: selectedURL) {
            await loadSelected()
        }
        .alert("Place Text", isPresented: $showTextPrompt) {
            TextField("Text", text: $textDraft)
            Button("Place") { placeText() }
            Button("Cancel", role: .cancel) { textAnchor = nil }
        } message: {
            Text("The text is drawn on \(activeLayer) at the tapped point.")
        }
        .alert("Board Statistics", isPresented: $showStats) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(statsText)
        }
        .alert("Custom Grid Spacing", isPresented: $showGridCustom) {
            TextField("Spacing in mils", text: $customValueDraft)
                .keyboardType(.decimalPad)
            Button("Set Grid") {
                if let mils = Double(customValueDraft), mils > 0, mils <= 1000 {
                    setGridMil(mils)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Snap grid spacing, in mils (1 mil = 0.0254 mm).")
        }
        .alert("Custom Clearance", isPresented: $showClearanceCustom) {
            TextField("Clearance in mils", text: $customValueDraft)
                .keyboardType(.decimalPad)
            Button("Set Clearance") {
                if let mils = Double(customValueDraft), mils > 0, mils <= 200 {
                    setClearanceMil(mils)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Minimum gap between different nets' copper, in mils. The clearance check and the fill rendering use it.")
        }
        .sheet(isPresented: $showManufacturing) {
            manufacturingSheet
        }
        .sheet(isPresented: $showTheory) {
            theorySheet
        }
        .sheet(isPresented: Binding(
            get: { netChoicePurpose != nil },
            set: { if !$0 { netChoicePurpose = nil } }
        )) {
            netPickerSheet
        }
    }

    private var statsText: String {
        guard let model else { return "No board loaded." }
        let connected = model.traces.filter { $0.netName != nil }.count
        var text = """
        \(model.components.count) components · \(model.netCount) nets
        \(model.traces.count) traces (\(connected) connected)
        \(model.vias.count) vias · \(model.zones.count) copper fills
        \(model.graphics.count) board graphics
        \(problemCount) problems
        """
        let routedNets = model.netNames.filter {
            (connectivity[$0]?.traceLength ?? 0) > 0
        }.sorted()
        if !routedNets.isEmpty {
            text += "\n\nRouted length per net:"
            for net in routedNets {
                let info = connectivity[net]!
                text += "\n\(net): \(BoardUnits.formatLength(mm: info.traceLength))"
                    + " · \(info.routedPadCount)/\(info.padCount) pads routed"
            }
        }
        text += "\n\nBoard state: Documents/Boards/\(tableStem).board.json"
        return text
    }

    // MARK: - Checker caches

    /// Recompute connectivity + clearance from the current model.
    /// Called after every model change (load, sync, mutation) so
    /// pin status, Problems and Inspect always read fresh truth.
    private func refreshChecks() {
        guard let model else {
            connectivity = [:]
            clearanceViolations = []
            return
        }
        connectivity = BoardConnectivity.analyze(
            model: model, copperCount: boardState.copperLayerCount)
        clearanceViolations = BoardClearance.violations(
            model: model, copperCount: boardState.copperLayerCount,
            clearanceMM: BoardUnits.mm(fromMil: boardState.clearanceMil))
    }

    private var manufacturingSettings: ManufacturingSettings {
        ManufacturingSettings(clearanceMil: boardState.clearanceMil)
    }

    // MARK: - Centre (empty / loading / error / editor)

    @ViewBuilder
    private var centre: some View {
        if tables.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "circuitboard")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                Text("No connection tables yet")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("Save a schematic first — every save also writes an encrypted connection table, and the PCB editor builds its board from that table.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                Text(loadError)
                    .font(.callout)
                    .foregroundStyle(.red.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let model {
            HStack(spacing: 0) {
                toolRail
                Divider()
                boardCanvas(model: model)
                Divider()
                rightPanel(model: model)
                    .frame(width: 320)
            }
        } else {
            VStack(spacing: 10) {
                ProgressView().tint(.white)
                Text("Decrypting connection table…")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Table bar (merged title row + entry flow, part 4)

    private var tableBar: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.12), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            Text("PCB Editor")
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Divider().frame(height: 22)
            Text("Board from:")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            if tables.isEmpty {
                Text("No connection tables yet — save a schematic first…")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            } else {
                Picker("Board from", selection: $selectedURL) {
                    ForEach(tables, id: \.path) { url in
                        Text(url.deletingPathExtension().lastPathComponent)
                            .lineLimit(1)
                            .tag(Optional(url))
                    }
                }
                .pickerStyle(.menu)
                .fixedSize(horizontal: true, vertical: false)
                if isLoading {
                    ProgressView().tint(.white)
                }
                Spacer(minLength: 8)
                if let statusMessage {
                    Text(statusMessage)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(statusIsWarning
                            ? .orange.opacity(0.95) : .green.opacity(0.9))
                        .lineLimit(1)
                }
                if let model {
                    Text("\(model.sourceFileName) · \(model.tableTitle)")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(white: 0.11))
    }

    private func setStatus(_ message: String?, warning: Bool = false) {
        statusMessage = message
        statusIsWarning = warning
    }

    // MARK: - Loading + board-state merge

    /// The resolvers the model builder needs, captured from the
    /// environment stores (the same lookups opening has always used).
    private func buildBoard(from url: URL) async throws
        -> (base: BoardModel, merged: BoardModel, canonical: BoardState) {
        let libStore = libraryStore
        let fpStore = footprintStore
        let stem = url.deletingPathExtension().lastPathComponent
        return try await Task.detached(priority: .userInitiated) {
            let table = try ConnectionTableStore.load(from: url)
            let base = PCBBoardModelBuilder.build(
                table: table,
                resolveSymbol: { library, name in
                    libStore.symbol(library: library, name: name)
                },
                resolveFootprint: { key in
                    guard let entry = fpStore.entry(forResolutionKey: key),
                          let parsed = fpStore.footprint(for: entry)
                    else { return nil }
                    return (entry: entry, parsed: parsed)
                })
            let saved = BoardStateStore.load(tableStem: stem)
            let merged = PCBBoardMerger.apply(state: saved, to: base, isSync: false)
            return (base: base, merged: merged.model, canonical: merged.stateToSave)
        }.value
    }

    private func loadSelected() async {
        // A sync that just rebuilt the board AND moved the picker to
        // the table it built sets this flag: the selection change must
        // not trigger a second, identical load.
        if suppressTaskLoad {
            suppressTaskLoad = false
            return
        }
        setStatus(nil)
        model = nil
        baseModel = nil
        loadError = nil
        guard let url = selectedURL else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await buildBoard(from: url)
            // A detached task is not cancelled when the picker moves
            // on; drop the result if the selection has changed.
            if selectedURL == url {
                baseModel = result.base
                boardState = result.canonical
                model = result.merged
                tableStem = url.deletingPathExtension().lastPathComponent
                try? BoardStateStore.save(result.canonical, tableStem: tableStem)
                undoStack = []
                redoStack = []
                cancelInProgress()
                highlightedNet = nil
                visibility.copperLayerCount = result.canonical.copperLayerCount
                if !BoardLayers.layerExists(activeLayer,
                                             copperCount: result.canonical.copperLayerCount) {
                    activeLayer = "F.Cu"
                }
                refreshChecks()
                selectOnly(result.merged.components.first
                    .map { BoardSelection.component($0.reference) })
            }
        } catch {
            if selectedURL == url {
                loadError = "Could not open that table: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Sync from Schematic (v3.1, merge semantics part 4)

    /// KiCad's "Update PCB from Schematic", PadCB-style: re-read the
    /// SAVED connection table for the schematic on the board and
    /// merge it into the board in place. The saved table is the only
    /// source — sync never reaches into a live, unsaved editing
    /// session. The merge keeps placements, traces and graphics
    /// (PCBBoardMerger's pinned rules); parts deleted from the board
    /// are restored by a sync and named in the feedback line.
    private func syncFromSchematic() async {
        guard !isSyncing else { return }
        isSyncing = true
        isLoading = true
        defer {
            isSyncing = false
            isLoading = false
        }

        // A save since opening may have rewritten the loaded
        // schematic's .pct in place (same file, new bytes) or added a
        // new schematic's table — rescan before choosing.
        tables = ConnectionTableStore.availableTables()

        // Target: the table for the schematic currently on the board
        // (tables are one file per schematic, so that file's current
        // bytes ARE its newest state). With no board loaded, the
        // newest table overall — the same choice opening makes.
        let target: URL?
        if let current = selectedURL,
           tables.contains(where: { $0.path == current.path }) {
            target = current
        } else {
            target = tables.first
        }
        guard let url = target else {
            setStatus("Nothing to sync — save a schematic first.", warning: true)
            return
        }

        let libStore = libraryStore
        let fpStore = footprintStore
        let stem = url.deletingPathExtension().lastPathComponent
        let priorState = boardState
        do {
            let built = try await Task.detached(priority: .userInitiated) { () throws
                -> (base: BoardModel, merged: BoardModel,
                    canonical: BoardState, report: BoardMergeReport) in
                let table = try ConnectionTableStore.load(from: url)
                let base = PCBBoardModelBuilder.build(
                    table: table,
                    resolveSymbol: { library, name in
                        libStore.symbol(library: library, name: name)
                    },
                    resolveFootprint: { key in
                        guard let entry = fpStore.entry(forResolutionKey: key),
                              let parsed = fpStore.footprint(for: entry)
                        else { return nil }
                        return (entry: entry, parsed: parsed)
                    })
                let merged = PCBBoardMerger.apply(state: priorState, to: base, isSync: true)
                return (base: base, merged: merged.model,
                        canonical: merged.stateToSave, report: merged.report)
            }.value
            let previous = model
            baseModel = built.base
            boardState = built.canonical
            model = built.merged
            tableStem = stem
            try? BoardStateStore.save(built.canonical, tableStem: stem)
            loadError = nil
            cancelInProgress()
            if selectedURL != url {
                // Keep the picker on the table now on the board,
                // without .task(id:) rebuilding what sync just built.
                suppressTaskLoad = true
                selectedURL = url
            }
            // Selection survives only for items that still exist.
            selections = selections.filter { selectionExists($0, in: built.merged) }
            if let primarySelection,
               !selectionExists(primarySelection, in: built.merged) {
                self.primarySelection = selections.first
            }
            if selections.isEmpty {
                selectOnly(built.merged.components.first
                    .map { BoardSelection.component($0.reference) })
            }
            if let highlightedNet,
               !built.merged.netNames.contains(highlightedNet) {
                self.highlightedNet = nil
            }
            refreshChecks()
            setStatus(Self.syncSummary(previous: previous, current: built.merged,
                                       report: built.report))
        } catch {
            if model == nil {
                loadError = "Sync failed: \(error.localizedDescription)"
            }
            setStatus("Sync failed: \(error.localizedDescription)", warning: true)
        }
    }

    private func selectionExists(_ selection: BoardSelection,
                                 in model: BoardModel) -> Bool {
        switch selection {
        case .component(let reference):
            return model.components.contains { $0.reference == reference }
        case .trace(let id):
            return model.traces.contains { $0.id == id }
        case .graphic(let id):
            return model.graphics.contains { $0.id == id }
        case .via(let id):
            return model.vias.contains { $0.id == id }
        case .zone(let id):
            return model.zones.contains { $0.id == id }
        }
    }

    /// "Synced — 12 components, 8 nets", plus the model diff and the
    /// merge report (re-added parts, arrivals, disconnected traces).
    private static func syncSummary(previous: BoardModel?, current: BoardModel,
                                    report: BoardMergeReport) -> String {
        var text = "Synced — \(current.components.count) components, \(current.netCount) nets"
        var parts: [String] = []
        if let previous, previous.sourceFileName == current.sourceFileName {
            let diff = PCBBoardModelBuilder.diff(from: previous, to: current)
            if !diff.addedReferences.isEmpty {
                parts.append("\(diff.addedReferences.count) added")
            }
            if !diff.removedReferences.isEmpty {
                parts.append("\(diff.removedReferences.count) removed")
            }
            if !diff.changedReferences.isEmpty {
                parts.append("\(diff.changedReferences.count) changed")
            }
            if diff.oldNetCount != diff.newNetCount {
                parts.append("nets \(diff.oldNetCount) → \(diff.newNetCount)")
            }
        }
        if !report.reAddedReferences.isEmpty {
            parts.append("re-added \(report.reAddedReferences.joined(separator: ", "))")
        }
        if !report.disconnectedTraceIDs.isEmpty {
            parts.append("\(report.disconnectedTraceIDs.count) trace(s) lost their net")
        }
        if !report.reconnectedTraceIDs.isEmpty {
            parts.append("\(report.reconnectedTraceIDs.count) trace(s) reconnected")
        }
        if parts.isEmpty, previous != nil,
           previous?.sourceFileName == current.sourceFileName {
            parts.append("no changes")
        }
        return parts.isEmpty ? text : text + " · " + parts.joined(separator: ", ")
    }

    // MARK: - Board mutation (undoable, persisted)

    /// Apply one edit to the board state: record undo, fold the edit
    /// through the merger (so the on-screen model and the saved
    /// state can never disagree), persist.
    private func mutateBoard(_ change: (inout BoardState) -> Void) {
        guard let baseModel else { return }
        undoStack.append(boardState)
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
        var edited = boardState
        change(&edited)
        applyEditedState(edited)
    }

    private func applyEditedState(_ edited: BoardState) {
        guard let baseModel else { return }
        let merged = PCBBoardMerger.apply(state: edited, to: baseModel, isSync: false)
        boardState = merged.stateToSave
        model = merged.model
        try? BoardStateStore.save(boardState, tableStem: tableStem)
        visibility.copperLayerCount = merged.stateToSave.copperLayerCount
        selections = selections.filter {
            selectionExists($0, in: merged.model)
        }
        if let primarySelection,
           !selectionExists(primarySelection, in: merged.model) {
            self.primarySelection = selections.first
        }
        refreshChecks()
    }

    private func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(boardState)
        applyEditedState(previous)
        setStatus("Undid the last board edit.")
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(boardState)
        applyEditedState(next)
        setStatus("Redid the board edit.")
    }

    private func cancelInProgress() {
        routePoints = []
        routeNet = nil
        pendingPoints = []
        zonePoints = []
        textAnchor = nil
    }

    private func handleEscapeKey() {
        if routingActive {
            cancelInProgress()
            setStatus("Routing cancelled.")
        } else if zoneActive {
            zonePoints = []
            setStatus("Fill cancelled.")
        } else if !pendingPoints.isEmpty {
            pendingPoints = []
            setStatus("Drawing cancelled.")
        } else if highlightedNet != nil {
            highlightedNet = nil
            setStatus("Net highlight cleared.")
        } else {
            clearSelection()
        }
    }

    // MARK: - Board settings (grid / clearance / copper count)

    private func setGridMil(_ mils: Double) {
        mutateBoard { $0.gridMil = mils }
        setStatus("Snap grid set to \(BoardUnits.formatMil(mils)) mil "
                  + "(\(PCBBoardMerger.formatMM(BoardUnits.mm(fromMil: mils))) mm).")
    }

    private func setClearanceMil(_ mils: Double) {
        mutateBoard { $0.clearanceMil = mils }
        setStatus("Clearance set to \(BoardUnits.formatMil(mils)) mil — "
                  + "the clearance check re-ran.")
    }

    private func setCopperLayerCount(_ count: Int) {
        mutateBoard { $0.copperLayerCount = count }
        if !BoardLayers.layerExists(activeLayer, copperCount: count) {
            activeLayer = "F.Cu"
        }
        let orphans = model?.boardProblems.filter {
            $0.contains("which this board no longer has") } ?? []
        if orphans.isEmpty {
            setStatus("Board now has \(count) copper layers.")
        } else {
            setStatus("Board now has \(count) copper layers — "
                      + "\(orphans.count) item(s) sit on layers outside the stack; "
                      + "they're kept, hidden, and listed in Problems.",
                      warning: true)
        }
    }

    // MARK: - Menu strip (every item performs a real action)

    private func setTool(_ tool: PCBTool) {
        if tool != .route, routingActive { cancelInProgress() }
        if tool != .fillZone, zoneActive { zonePoints = [] }
        if tool != activeTool { pendingPoints = [] }
        activeTool = tool
    }

    private var menuStrip: some View {
        HStack(spacing: 2) {
            Menu("File") {
                Button("Sync from Schematic") {
                    Task { await syncFromSchematic() }
                }
                .disabled(isSyncing)
                Button("Rescan Tables") { rescanTables() }
                Button("Save Board Now") {
                    try? BoardStateStore.save(boardState, tableStem: tableStem)
                    setStatus("Board saved to Documents/Boards/\(tableStem).board.json.")
                }
                .disabled(model == nil)
            }
            Menu("Edit") {
                Button("Undo") { undo() }
                    .disabled(undoStack.isEmpty)
                Button("Redo") { redo() }
                    .disabled(redoStack.isEmpty)
                Divider()
                Button(flipActionTitle) { flipSelection() }
                    .disabled(!canFlipSelection)
                Button("Delete Selection") { deleteSelection() }
                    .disabled(selections.isEmpty)
                Button("Clear Net Highlight") { highlightedNet = nil }
                    .disabled(highlightedNet == nil)
            }
            Menu("View") {
                Button("Zoom In") { zoomIn() }
                Button("Zoom Out") { zoomOut() }
                Button("Fit Board") { fitBoard() }
                Divider()
                Button(showGrid ? "✓ Grid" : "Grid") { showGrid.toggle() }
                Button(snapEnabled ? "✓ Snap to Grid" : "Snap to Grid") {
                    snapEnabled.toggle()
                }
                Button(multiSelect ? "✓ Multi-Select" : "Multi-Select") {
                    multiSelect.toggle()
                }
                Button(highlightActiveLayer
                       ? "✓ Highlight Active Layer" : "Highlight Active Layer") {
                    highlightActiveLayer.toggle()
                }
                Button("Show All Layers & Objects") {
                    visibility = BoardVisibility(
                        copperLayerCount: boardState.copperLayerCount)
                }
            }
            Menu("Place") {
                ForEach([PCBTool.route, .drawLine, .drawArc, .drawCircle,
                         .text, .placeVia, .fillZone],
                        id: \.rawValue) { tool in
                    Button(activeTool == tool ? "✓ \(tool.rawValue)" : tool.rawValue) {
                        setTool(tool)
                    }
                }
            }
            Menu("Route") {
                Button("Start Routing") { setTool(.route) }
                Button("Finish Track") { finishRoute() }
                    .disabled(!routingActive)
                Button("Cancel Routing") {
                    cancelInProgress()
                    setStatus("Routing cancelled.")
                }
                .disabled(!routingActive)
                Divider()
                Menu("Track Width") {
                    ForEach(BoardGeometry.trackWidthPresets, id: \.self) { width in
                        Button(currentTrackWidth == width
                               ? "✓ \(PCBBoardMerger.formatMM(width)) mm"
                               : "\(PCBBoardMerger.formatMM(width)) mm") {
                            currentTrackWidth = width
                            defaultTrackWidth = width
                        }
                    }
                }
            }
            Menu("Inspect") {
                Button("Highlight Net") { setTool(.highlightNet) }
                Button("Clear Highlight") { highlightedNet = nil }
                    .disabled(highlightedNet == nil)
                Divider()
                Button("Manufacturing Check") { showManufacturing = true }
                    .disabled(model == nil)
                Button("Theory Check") { showTheory = true }
                    .disabled(model == nil)
                Button("Show Problems") { activePanelTab = "Components" }
                Button("Board Statistics") { showStats = true }
                    .disabled(model == nil)
            }
            Menu("Tools") {
                ForEach([PCBTool.select, .highlightNet, .delete], id: \.rawValue) { tool in
                    Button(activeTool == tool ? "✓ \(tool.rawValue)" : tool.rawValue) {
                        setTool(tool)
                    }
                }
            }
            Menu("Preferences") {
                Menu("Grid Spacing") {
                    ForEach(BoardGrid.presetMils, id: \.self) { mils in
                        Button(boardState.gridMil == mils
                               ? "✓ \(BoardUnits.formatMil(mils)) mil"
                               : "\(BoardUnits.formatMil(mils)) mil") {
                            setGridMil(mils)
                        }
                    }
                    Divider()
                    Button("Custom…") {
                        customValueDraft = BoardUnits.formatMil(boardState.gridMil)
                        showGridCustom = true
                    }
                }
                Menu("Clearance") {
                    ForEach([4.0, 6.0, 8.0, 10.0, 12.0, 20.0], id: \.self) { mils in
                        Button(boardState.clearanceMil == mils
                               ? "✓ \(BoardUnits.formatMil(mils)) mil"
                               : "\(BoardUnits.formatMil(mils)) mil") {
                            setClearanceMil(mils)
                        }
                    }
                    Divider()
                    Button("Custom…") {
                        customValueDraft = BoardUnits.formatMil(boardState.clearanceMil)
                        showClearanceCustom = true
                    }
                }
                Menu("Copper Layers") {
                    ForEach(BoardLayers.copperCountChoices, id: \.self) { count in
                        Button(boardState.copperLayerCount == count
                               ? "✓ \(count) layers" : "\(count) layers") {
                            setCopperLayerCount(count)
                        }
                    }
                }
                Menu("Default Track Width") {
                    ForEach(BoardGeometry.trackWidthPresets, id: \.self) { width in
                        Button(defaultTrackWidth == width
                               ? "✓ \(PCBBoardMerger.formatMM(width)) mm"
                               : "\(PCBBoardMerger.formatMM(width)) mm") {
                            defaultTrackWidth = width
                            currentTrackWidth = width
                        }
                    }
                }
                Menu("Active Layer") {
                    ForEach(BoardLayers.allLayers(
                        copperCount: boardState.copperLayerCount), id: \.self) { layer in
                        Button(activeLayer == layer ? "✓ \(layer)" : layer) {
                            activeLayer = layer
                        }
                    }
                }
                Button(snapEnabled ? "✓ Snap to Grid" : "Snap to Grid") {
                    snapEnabled.toggle()
                }
                Button(showGrid ? "✓ Grid" : "Grid") { showGrid.toggle() }
            }
            Spacer(minLength: 0)
            Text(activeTool.rawValue)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
        }
        .font(.callout)
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(Color(white: 0.13))
    }

    private func rescanTables() {
        tables = ConnectionTableStore.availableTables()
        if selectedURL == nil { selectedURL = tables.first }
        setStatus("Table list refreshed — \(tables.count) saved schematic(s) found.")
    }

    // MARK: - Icon strip

    private var iconStrip: some View {
        HStack(spacing: 4) {
            iconButton("folder", "Open table") { rescanTables() }
            iconButton("arrow.triangle.2.circlepath", "Sync from Schematic",
                       disabled: isSyncing) {
                Task { await syncFromSchematic() }
            }
            Divider().frame(height: 26)
            iconButton("minus.magnifyingglass", "Zoom Out") { zoomOut() }
            iconButton("plus.magnifyingglass", "Zoom In") { zoomIn() }
            iconButton("arrow.up.left.and.arrow.down.right", "Fit") { fitBoard() }
            Divider().frame(height: 26)
            iconButton("grid", "Grid", active: showGrid) { showGrid.toggle() }
            iconButton("grid.circle", "Snap", active: snapEnabled) {
                snapEnabled.toggle()
            }
            iconButton("square.stack.3d.up", "Highlight layer",
                       active: highlightActiveLayer) {
                highlightActiveLayer.toggle()
            }
            Divider().frame(height: 26)
            Menu {
                ForEach(BoardLayers.allLayers(
                    copperCount: boardState.copperLayerCount), id: \.self) { layer in
                    Button(activeLayer == layer ? "✓ \(layer)" : layer) {
                        activeLayer = layer
                    }
                }
            } label: {
                VStack(spacing: 1) {
                    Image(systemName: "pencil.and.ruler")
                        .font(.system(size: 16, weight: .medium))
                        .lineLimit(1)
                    Text(activeLayer)
                        .font(.caption2)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            if routingActive {
                Divider().frame(height: 26)
                iconButton("checkmark.circle", "Finish") { finishRoute() }
                iconButton("xmark.circle", "Cancel") {
                    cancelInProgress()
                    setStatus("Routing cancelled.")
                }
            }
            if zoneActive {
                Divider().frame(height: 26)
                iconButton("checkmark.circle", "Finish fill",
                           disabled: zonePoints.count < 3) { finishZone() }
                iconButton("xmark.circle", "Cancel") {
                    zonePoints = []
                    setStatus("Fill cancelled.")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(white: 0.13))
    }

    private func iconButton(_ icon: String, _ label: String,
                            active: Bool = false,
                            disabled: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .lineLimit(1)
                Text(label)
                    .font(.caption2)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(active ? Color.accentColor : .white.opacity(0.9))
            .opacity(disabled ? 0.45 : 1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(active ? Color.accentColor.opacity(0.22) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    // MARK: - Left tool rail

    // Part 4 layout fix: the rail is 96 pt wide and labels may wrap
    // to two lines — at the old 72 pt with single-line fixed-size
    // labels, "Highlight Net", "Route Tracks" and "Draw Circle" were
    // clipped mid-word on Sean's iPad. Part 5 adds the Multi toggle
    // at the top and the Place Via / Fill Zone tools at the bottom.
    private var toolRail: some View {
        VStack(spacing: 2) {
            Button {
                multiSelect.toggle()
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: multiSelect
                          ? "checkmark.square.fill" : "square.dashed")
                        .font(.system(size: 17, weight: .medium))
                        .lineLimit(1)
                    Text("Multi")
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                .foregroundStyle(multiSelect ? Color.white : .white.opacity(0.75))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .padding(.horizontal, 2)
                .background(multiSelect
                            ? Color.accentColor.opacity(0.35) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Divider().padding(.vertical, 4)
            ForEach(Array(PCBTool.allCases.enumerated()), id: \.offset) { index, tool in
                if index == 3 || index == 8 {
                    Divider().padding(.vertical, 4)
                }
                Button {
                    setTool(tool)
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: tool.icon)
                            .font(.system(size: 17, weight: .medium))
                            .lineLimit(1)
                        Text(tool.rawValue)
                            .font(.caption2)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                    .foregroundStyle(activeTool == tool ? Color.white : .white.opacity(0.75))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 2)
                    .background(activeTool == tool
                                ? Color.accentColor.opacity(0.35) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .frame(width: 96)
        .background(Color(white: 0.10))
    }

    // MARK: - Route width bar (part 5: slider at the bottom)

    /// Shown while Route Tracks is active: a live width slider
    /// (Sean asked for it at the BOTTOM) with mm + mils readout.
    /// The detail panel's numeric control still works too.
    private var routeWidthBar: some View {
        HStack(spacing: 12) {
            Text("Track width")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Slider(value: Binding(
                get: { currentTrackWidth },
                set: { currentTrackWidth = $0; defaultTrackWidth = $0 }
            ), in: 0.1...2.0, step: 0.01)
            Text(BoardUnits.formatLength(mm: currentTrackWidth))
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            if routingActive {
                Button("Finish Track") { finishRoute() }
                    .buttonStyle(.borderedProminent)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(white: 0.11))
    }

    // MARK: - Right panels

    private func rightPanel(model: BoardModel) -> some View {
        VStack(spacing: 0) {
            Picker("Panel", selection: $activePanelTab) {
                Text("Layers").lineLimit(1).tag("Layers")
                Text("Objects").lineLimit(1).tag("Objects")
                Text("Components").lineLimit(1).tag("Components")
            }
            .pickerStyle(.segmented)
            .padding(10)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if activePanelTab == "Objects" {
                        objectsPanel
                    } else if activePanelTab == "Components" {
                        componentsPanel(model: model)
                    } else {
                        layersPanel
                    }
                    Divider()
                    selectionFilterPanel
                    Divider()
                    detailPanel
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(white: 0.10))
        .onChange(of: primarySelection) { _, newValue in
            if case .trace(let id)? = newValue,
               let trace = model.traces.first(where: { $0.id == id }) {
                widthDraft = PCBBoardMerger.formatMM(trace.width)
            }
            if case .via(let id)? = newValue,
               let via = model.vias.first(where: { $0.id == id }) {
                viaDiameterDraft = PCBBoardMerger.formatMM(via.diameter)
                viaDrillDraft = PCBBoardMerger.formatMM(via.drill)
            }
        }
    }

    private var layersPanel: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                panelHeader("Layers")
                Spacer(minLength: 0)
                Menu {
                    ForEach(BoardLayers.copperCountChoices, id: \.self) { count in
                        Button(boardState.copperLayerCount == count
                               ? "✓ \(count) layers" : "\(count) layers") {
                            setCopperLayerCount(count)
                        }
                    }
                } label: {
                    Text("\(boardState.copperLayerCount) copper")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                }
            }
            ForEach(layerRows, id: \.name) { row in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(row.color)
                        .frame(width: 16, height: 16)
                    Text(row.name)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                    if activeLayer == row.name {
                        Text("ACTIVE")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color.accentColor)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button {
                        if visibility.hiddenLayers.contains(row.name) {
                            visibility.hiddenLayers.remove(row.name)
                        } else {
                            visibility.hiddenLayers.insert(row.name)
                        }
                    } label: {
                        Image(systemName: visibility.hiddenLayers.contains(row.name)
                              ? "eye.slash" : "eye")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .onTapGesture {
                    // Tapping a row makes it the ACTIVE layer (part
                    // 5: any layer can be active — draw tools draw
                    // here; routing and vias need copper).
                    activeLayer = row.name
                }
            }
            Text("Eyes hide/show layers. Tap a row to make it the active layer — drawings and text land there; routing and vias need a copper layer. The copper count is this board's; items stranded on removed layers stay on the board, hidden, and are listed in Problems.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(6)
        }
    }

    private var objectsPanel: some View {
        VStack(alignment: .leading, spacing: 2) {
            panelHeader("Objects")
            checkRow("Footprints", isOn: visibility.showFootprints) {
                visibility.showFootprints.toggle()
            }
            checkRow("Tracks", isOn: visibility.showTracks) {
                visibility.showTracks.toggle()
            }
            checkRow("Vias", isOn: visibility.showVias) {
                visibility.showVias.toggle()
            }
            checkRow("Pads", isOn: visibility.showPads) {
                visibility.showPads.toggle()
            }
            checkRow("Zones", isOn: visibility.showZones) {
                visibility.showZones.toggle()
            }
            checkRow("Drawings", isOn: visibility.showDrawings) {
                visibility.showDrawings.toggle()
            }
            checkRow("Text", isOn: visibility.showText) {
                visibility.showText.toggle()
            }
            checkRow("Dimensions", isOn: visibility.showDimensions) {
                visibility.showDimensions.toggle()
            }
            Text("These filter the canvas immediately. Vias and fills are placed with the Place Via and Fill Zone tools. (PadCB doesn't draw dimensions yet — that switch is ready for when it does.)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(5)
        }
    }

    private func componentsPanel(model: BoardModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            panelHeader("Components")
            ForEach(model.components, id: \.reference) { component in
                Button {
                    selectOnly(.component(component.reference))
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 8) {
                            Text(component.reference)
                                .font(.callout.weight(.bold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                            Text(component.value)
                                .font(.callout)
                                .foregroundStyle(.white.opacity(0.75))
                                .lineLimit(1)
                            if component.side == .back {
                                Text("BACK")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(Color(red: 0.45, green: 0.65, blue: 1))
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        if let key = component.footprintKey {
                            Text(key)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else {
                            Text("NO FOOTPRINT")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(selections.contains(.component(component.reference))
                                ? Color.accentColor.opacity(0.30) : Color.white.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if !model.excludedPowerReferences.isEmpty {
                Text("Off-board power symbols: \(model.excludedPowerReferences.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            problemsPanel(model: model)
        }
    }

    /// One Problems line; clearance entries carry canvas
    /// highlights so tapping one selects the offending copper.
    private struct ProblemEntry {
        var text: String
        var highlights: [CheckHighlight] = []
    }

    private func problemEntries(model: BoardModel) -> [ProblemEntry] {
        var entries = model.boardProblems.map { ProblemEntry(text: $0) }
        entries += model.globalAnomalies.map { ProblemEntry(text: $0) }
        entries += model.components.flatMap { component in
            component.anomalies.map {
                ProblemEntry(text: "\(component.reference): \($0)")
            }
        }
        entries += clearanceViolations.map {
            ProblemEntry(text: "Clearance: \($0.message)", highlights: $0.highlights)
        }
        return entries
    }

    private func problemsPanel(model: BoardModel) -> some View {
        let entries = problemEntries(model: model)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                panelHeader("Problems")
                Spacer(minLength: 0)
                Button("Manufacturing Check") { showManufacturing = true }
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
            }
            if entries.isEmpty {
                Text("No problems: every pin has a pad, every pad has a pin, and no two nets' copper comes within \(BoardUnits.formatMil(boardState.clearanceMil)) mil.")
                    .font(.callout)
                    .foregroundStyle(.green.opacity(0.9))
                    .lineLimit(4)
            } else {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    if entry.highlights.isEmpty {
                        Text(entry.text)
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .lineLimit(4)
                    } else {
                        Button {
                            selections = Set(entry.highlights.map(selectionForHighlight))
                            primarySelection = entry.highlights.first
                                .map(selectionForHighlight)
                            setStatus("Clearance problem selected on the canvas.")
                        } label: {
                            Text(entry.text)
                                .font(.callout)
                                .foregroundStyle(.orange)
                                .multilineTextAlignment(.leading)
                                .lineLimit(4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func selectionForHighlight(_ highlight: CheckHighlight) -> BoardSelection {
        switch highlight {
        case .component(let reference): return .component(reference)
        case .trace(let id): return .trace(id)
        case .via(let id): return .via(id)
        case .zone(let id): return .zone(id)
        }
    }

    private var selectionFilterPanel: some View {
        VStack(alignment: .leading, spacing: 2) {
            panelHeader("Selection Filter")
            checkRow("All items", isOn: selectionFilter.allItems) {
                selectionFilter.setAll(!selectionFilter.allItems)
            }
            checkRow("Footprints", isOn: selectionFilter.components) {
                selectionFilter.components.toggle()
            }
            checkRow("Tracks", isOn: selectionFilter.traces) {
                selectionFilter.traces.toggle()
            }
            checkRow("Vias", isOn: selectionFilter.vias) {
                selectionFilter.vias.toggle()
            }
            checkRow("Zones", isOn: selectionFilter.zones) {
                selectionFilter.zones.toggle()
            }
            checkRow("Graphics", isOn: selectionFilter.graphics) {
                selectionFilter.graphics.toggle()
            }
            checkRow("Text", isOn: selectionFilter.text) {
                selectionFilter.text.toggle()
            }
            Text("Only checked kinds can be selected by tapping the canvas.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private func checkRow(_ name: String, isOn: Bool,
                          toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.callout)
                    .foregroundStyle(isOn ? Color.accentColor : .white.opacity(0.6))
                    .lineLimit(1)
                Text(name)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func panelHeader(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .foregroundStyle(.white)
            .lineLimit(1)
    }

    // MARK: - Detail panel (selection-driven)

    @ViewBuilder
    private var detailPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            if selections.count > 1, let summary = selectionSummaryText {
                Text(summary)
                    .font(.callout.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                Text("The item below is the last one tapped. Delete removes the whole selection; dragging moves the selected components together (tracks stay put).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                HStack(spacing: 8) {
                    Button("Flip Side") { flipSelection() }
                        .buttonStyle(.bordered)
                        .disabled(!canFlipSelection)
                    Button(role: .destructive) { deleteSelection() } label: {
                        Label("Delete All", systemImage: "trash")
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                }
                Divider()
            }
            if let component = selectedComponent {
                componentDetail(component)
            } else if let trace = selectedTrace {
                traceDetail(trace)
            } else if let via = selectedVia {
                viaDetail(via)
            } else if let zone = selectedZone {
                zoneDetail(zone)
            } else if let graphic = selectedGraphic {
                graphicDetail(graphic)
            } else if routingActive {
                routingDetail
            } else if zoneActive {
                zoneDetailPending
            } else {
                Text("Tap a component, track, via, fill or graphic to select it. Turn on Multi to select several at once. With Select active, drag a component to move it; Route Tracks starts by tapping a pad.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(5)
            }
        }
    }

    private var zoneDetailPending: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Drawing a fill")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text("\(zonePoints.count) corner(s) placed on \(activeLayer). Tap more corners, then Finish (in the top strip) and pick the fill's net.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(4)
            Button("Finish Fill") { finishZone() }
                .buttonStyle(.borderedProminent)
                .disabled(zonePoints.count < 3)
        }
    }

    private func componentDetail(_ component: BoardComponent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(component.reference)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Text(component.value)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            detailRow("Symbol", component.symbolKey)
            detailRow("Footprint", component.footprintKey ?? "— none —")
            detailRow("Chosen by", matchKindWords(component.matchKind))
            detailRow("Position", "\(fmt(component.origin.x)), \(fmt(component.origin.y)) mm")
            detailRow("Side", component.side == .front
                      ? "Front (F.Cu)" : "Back (B.Cu) — mirrored")
            Button {
                flipSelection()
            } label: {
                Label(component.side == .front ? "Flip to Back (B.Cu)"
                      : "Flip to Front (F.Cu)", systemImage: "arrow.2.squarepath")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
            }
            .buttonStyle(.bordered)
            .padding(.top, 2)

            Text("Pins → pads")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .padding(.top, 4)
            if component.pins.isEmpty {
                Text("No pins could be derived for this component.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            ForEach(Array(component.pins.enumerated()), id: \.offset) { _, pin in
                let status = BoardPinStatus.status(of: pin, in: component,
                                                   connectivity: connectivity)
                Text(pinRowText(pin, status: status))
                    .font(.callout)
                    .foregroundStyle(pinRowColor(status))
                    .lineLimit(2)
            }
            ForEach(Array(component.anomalies.enumerated()), id: \.offset) { _, anomaly in
                Text(anomaly)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }
            ForEach(Array(component.notes.enumerated()), id: \.offset) { _, note in
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            deleteSelectionButton("Remove from Board")
        }
    }

    private func pinRowColor(_ status: PinConnectionStatus) -> Color {
        switch status {
        case .connected: return .white.opacity(0.92)
        case .disconnected: return .orange.opacity(0.95)
        case .unrouted: return Color(red: 1, green: 0.85, blue: 0.3)
        }
    }

    private func traceDetail(_ trace: BoardTrace) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Track")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
            detailRow("Net", trace.netName
                      ?? trace.disconnectedNetName.map { "was \($0) — unconnected" }
                      ?? "Unconnected")
            detailRow("Layer", trace.layer)
            detailRow("Length", BoardUnits.formatLength(mm: trace.length))
            if BoardLayers.flipDestinations.contains(trace.layer) {
                Button {
                    flipSelection()
                } label: {
                    Label("Move to \(trace.layer == "F.Cu" ? "B.Cu" : "F.Cu")",
                          systemImage: "arrow.2.squarepath")
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .padding(.top, 2)
            } else {
                Text("This track is on an inner layer — Flip Side only moves tracks between F.Cu and B.Cu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Text("Width (mm)")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .padding(.top, 4)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()),
                                GridItem(.flexible()), GridItem(.flexible())],
                      spacing: 6) {
                ForEach(BoardGeometry.trackWidthPresets, id: \.self) { width in
                    Button {
                        setTraceWidth(trace, width)
                    } label: {
                        Text(PCBBoardMerger.formatMM(width))
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(abs(trace.width - width) < 0.001
                                        ? Color.accentColor.opacity(0.4)
                                        : Color.white.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 8) {
                TextField("Width", text: $widthDraft)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.decimalPad)
                    .onSubmit {
                        if let width = Double(widthDraft), width > 0.01, width < 25 {
                            setTraceWidth(trace, width)
                        }
                    }
                Text("mm")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text("Width changes redraw immediately and are saved with the board.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            deleteSelectionButton("Delete Track")
        }
    }

    private func viaDetail(_ via: BoardVia) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Via")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
            detailRow("Net", via.netName
                      ?? via.disconnectedNetName.map { "was \($0) — unconnected" }
                      ?? "Unconnected")
            detailRow("Position", "\(fmt(via.center.x)), \(fmt(via.center.y)) mm")
            detailRow("Spans", "All \(boardState.copperLayerCount) copper layers")
            Text("Size (mm)")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .padding(.top, 4)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()),
                                GridItem(.flexible()), GridItem(.flexible())],
                      spacing: 6) {
                ForEach(Array(BoardVia.sizePresets.enumerated()), id: \.offset) { _, preset in
                    Button {
                        setViaSize(via, diameter: preset.diameter, drill: preset.drill)
                    } label: {
                        Text("\(PCBBoardMerger.formatMM(preset.diameter))/\(PCBBoardMerger.formatMM(preset.drill))")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(abs(via.diameter - preset.diameter) < 0.001
                                        ? Color.accentColor.opacity(0.4)
                                        : Color.white.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 8) {
                Text("Ø").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                TextField("Diameter", text: $viaDiameterDraft)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.decimalPad)
                    .onSubmit { applyViaDrafts(via) }
                Text("drill").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                TextField("Drill", text: $viaDrillDraft)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.decimalPad)
                    .onSubmit { applyViaDrafts(via) }
            }
            Text("Diameter/drill in mm. A via connects its net across every copper layer — it can't be flipped to one side.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            deleteSelectionButton("Delete Via")
        }
    }

    private func zoneDetail(_ zone: BoardZone) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Copper Fill")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
            detailRow("Net", zone.netName
                      ?? zone.disconnectedNetName.map { "was \($0) — unconnected" }
                      ?? "Unconnected")
            detailRow("Layer", zone.layer)
            detailRow("Corners", "\(zone.points.count)")
            Text("The fill renders under tracks and pads, keeping the board clearance (\(BoardUnits.formatMil(boardState.clearanceMil)) mil) around other nets' copper.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(4)
            deleteSelectionButton("Delete Fill")
        }
    }

    private func graphicDetail(_ graphic: BoardGraphicItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(graphic.kind == .text ? "Text" : "Graphic")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
            detailRow("Kind", graphic.kind.rawValue.capitalized)
            detailRow("Layer", graphic.layer)
            if graphic.kind == .text {
                detailRow("Text", graphic.text)
            }
            if graphic.kind == .circle {
                detailRow("Radius", "\(fmt(graphic.radius)) mm")
            }
            deleteSelectionButton("Delete Graphic")
        }
    }

    private var routingDetail: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Routing \(routeNet ?? "an unconnected track")")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(2)
            Text("\(routePoints.count) point(s) laid on \(activeLayer). Tap waypoints (they bend at 45°), then tap the target pad — or Finish to end the track here. The width slider is at the bottom of the screen.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(5)
            HStack(spacing: 8) {
                Button("Finish Track") { finishRoute() }
                    .buttonStyle(.borderedProminent)
                Button("Cancel") {
                    cancelInProgress()
                    setStatus("Routing cancelled.")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func deleteSelectionButton(_ title: String) -> some View {
        Button(role: .destructive) {
            deleteSelection()
        } label: {
            Label(title, systemImage: "trash")
                .font(.callout.weight(.semibold))
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.red.opacity(0.9))
        .padding(.top, 6)
    }

    private func setTraceWidth(_ trace: BoardTrace, _ width: Double) {
        mutateBoard { state in
            if let index = state.traces.firstIndex(where: { $0.id == trace.id }) {
                state.traces[index].width = width
            }
        }
        widthDraft = PCBBoardMerger.formatMM(width)
        setStatus("Track width set to \(PCBBoardMerger.formatMM(width)) mm.")
    }

    private func setViaSize(_ via: BoardVia, diameter: Double, drill: Double) {
        mutateBoard { state in
            if let index = state.vias.firstIndex(where: { $0.id == via.id }) {
                state.vias[index].diameter = diameter
                state.vias[index].drill = drill
            }
        }
        viaDiameterDraft = PCBBoardMerger.formatMM(diameter)
        viaDrillDraft = PCBBoardMerger.formatMM(drill)
        currentViaDiameter = diameter
        currentViaDrill = drill
        setStatus("Via size set to \(PCBBoardMerger.formatMM(diameter)) mm "
                  + "with a \(PCBBoardMerger.formatMM(drill)) mm drill.")
    }

    private func applyViaDrafts(_ via: BoardVia) {
        guard let diameter = Double(viaDiameterDraft),
              let drill = Double(viaDrillDraft),
              diameter > 0.1, drill > 0.05, drill < diameter else {
            setStatus("Via sizes need a drill smaller than the diameter.", warning: true)
            return
        }
        setViaSize(via, diameter: diameter, drill: drill)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: 74, alignment: .leading)
            Text(value)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    private func matchKindWords(_ kind: String?) -> String {
        switch kind {
        case "instanceChoice": return "Chosen for this placed part"
        case "property": return "Symbol Footprint property"
        case "filterExact": return "Footprint filter match"
        case let other?: return other
        case nil: return "—"
        }
    }

    /// "pin 1 — IN_A — net NET_A — pad 1 (…)" with the part-5
    /// connection status appended: DISCONNECTED when the pin has
    /// no net at all, UNROUTED when its net exists but no copper
    /// reaches the pad.
    private func pinRowText(_ pin: BoardPinBinding,
                            status: PinConnectionStatus) -> String {
        var text = "pin \(pin.pinNumber)"
        if !pin.pinName.isEmpty { text += " — \(pin.pinName)" }
        text += " — net \(pin.netName ?? "—")"
        if let pad = pin.pad {
            text += " — pad \(pad.number) (\(fmt(pad.width))×\(fmt(pad.height)) mm"
            if let drill = pad.drill {
                text += ", drill \(fmt(drill.width))"
                if drill.isOval { text += "×\(fmt(drill.height))" }
            }
            text += ")"
        } else {
            text += " — pad —"
        }
        switch status {
        case .disconnected: text += " — DISCONNECTED"
        case .unrouted(let net): text += " — UNROUTED (\(net) has no copper path here)"
        case .connected: break
        }
        return text
    }

    private func fmt(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    // MARK: - Checker sheets (part 5)

    private var manufacturingSheet: some View {
        let report = model.map {
            BoardManufacturing.check(model: $0,
                                     copperCount: boardState.copperLayerCount,
                                     settings: manufacturingSettings,
                                     connectivity: connectivity)
        }
        return NavigationStack {
            List {
                Section {
                    Text(report.map {
                        $0.allPassed
                            ? "All \($0.rules.count) rules pass — this board is inside the current manufacturing limits."
                            : "\($0.failedCount) of \($0.rules.count) rules fail. The failing rules list what and where below."
                    } ?? "No board loaded.")
                        .font(.callout)
                } header: {
                    Text("Result")
                }
                Section {
                    Text("Limits in force: clearance \(BoardUnits.formatMil(manufacturingSettings.clearanceMil)) mil · min track \(BoardUnits.formatMil(manufacturingSettings.minTraceWidthMil)) mil · min via drill \(BoardUnits.formatMil(manufacturingSettings.minViaDrillMil)) mil · min via diameter \(BoardUnits.formatMil(manufacturingSettings.minViaDiameterMil)) mil. Clearance is adjustable in Preferences.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Settings")
                }
                if let report {
                    ForEach(Array(report.rules.enumerated()), id: \.offset) { _, rule in
                        Section {
                            if rule.violations.isEmpty {
                                Text("Pass — nothing to report.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(Array(rule.violations.prefix(12).enumerated()),
                                        id: \.offset) { _, violation in
                                    Text(violation)
                                        .font(.callout)
                                }
                                if rule.violations.count > 12 {
                                    Text("…and \(rule.violations.count - 12) more")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } header: {
                            HStack(spacing: 6) {
                                Image(systemName: rule.passed
                                      ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(rule.passed ? .green : .red)
                                Text(rule.name)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Manufacturing Check")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showManufacturing = false }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Theory check sheet (heuristics + optional on-device AI)

    @State private var aiReviewText: String? = nil
    @State private var aiBusy = false

    private var theorySheet: some View {
        let findings = model.map {
            BoardTheory.findings(model: $0, connectivity: connectivity)
        } ?? []
        let availability = PCBTheoryAI.availability
        return NavigationStack {
            List {
                Section {
                    if findings.isEmpty {
                        Text("The deterministic checks found nothing theory-shaped to flag: no loose power pins, no single-pin nets, no ground/supply mixups, no unrouted nets.")
                            .font(.callout)
                    } else {
                        ForEach(Array(findings.enumerated()), id: \.offset) { _, finding in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: finding.severity == .warning
                                      ? "exclamationmark.triangle.fill" : "info.circle")
                                    .foregroundStyle(finding.severity == .warning
                                                     ? .orange : .secondary)
                                Text(finding.message)
                                    .font(.callout)
                            }
                        }
                    }
                } header: {
                    Text("Theory check (deterministic)")
                } footer: {
                    Text("These findings come from fixed rules over the connection table and the board — same input, same output, every time.")
                }
                Section {
                    switch availability {
                    case .available:
                        Text("An on-device model is available. It receives ONLY the short text summary below — generated on this iPad from the board — and runs entirely on-device. Nothing is uploaded.")
                            .font(.callout)
                        if let model {
                            let summary = BoardSummaryText.make(
                                model: model, connectivity: connectivity,
                                manufacturing: BoardManufacturing.check(
                                    model: model,
                                    copperCount: boardState.copperLayerCount,
                                    settings: manufacturingSettings,
                                    connectivity: connectivity),
                                theory: findings)
                            DisclosureGroup("The exact summary it sees") {
                                Text(summary)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                            Button {
                                aiBusy = true
                                aiReviewText = nil
                                Task {
                                    aiReviewText = await PCBTheoryAI.review(summary: summary)
                                    aiBusy = false
                                }
                            } label: {
                                Label("Ask on-device AI", systemImage: "sparkles")
                            }
                            .disabled(aiBusy)
                            if aiBusy {
                                ProgressView("Thinking on-device…")
                            }
                            if let aiReviewText {
                                Text(aiReviewText)
                                    .font(.callout)
                                    .textSelection(.enabled)
                            }
                        }
                    case .unavailable(let reason):
                        Text("On-device AI isn't available: \(reason) The deterministic findings above still work.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("On-device AI (experimental, advisory)")
                } footer: {
                    Text("AI suggestions are advisory only — the deterministic checks are the authority.")
                }
            }
            .navigationTitle("Theory Check")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showTheory = false }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Net picker sheet (via + zone placement)

    private var netPickerSheet: some View {
        NavigationStack {
            List {
                if let model {
                    if model.netNames.isEmpty {
                        Text("This board has no nets — the schematic's pins aren't connected to anything yet.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.netNames, id: \.self) { net in
                        Button(net) { chooseNet(net) }
                            .font(.callout.weight(.semibold))
                    }
                }
            }
            .navigationTitle(netChoicePurpose.map {
                switch $0 {
                case .via: return "Via — choose a net"
                case .zone: return "Fill — choose a net"
                }
            } ?? "Choose a net")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { netChoicePurpose = nil }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func chooseNet(_ net: String) {
        guard let purpose = netChoicePurpose else { return }
        netChoicePurpose = nil
        switch purpose {
        case .via(let point):
            placeVia(net: net, at: point)
        case .zone:
            commitZone(net: net)
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 14) {
            Text(cursorText)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text("Grid \(BoardUnits.formatMil(boardState.gridMil)) mil (\(PCBBoardMerger.formatMM(gridMM)) mm)")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(snapEnabled ? "Snap on" : "Snap off")
                .font(.callout)
                .foregroundStyle(snapEnabled ? .white.opacity(0.6) : .orange.opacity(0.9))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text("Zoom \(BoardCanvasMetrics.percent(forScale: scale))%")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Menu {
                ForEach(BoardLayers.allLayers(
                    copperCount: boardState.copperLayerCount), id: \.self) { layer in
                    Button(activeLayer == layer ? "✓ \(layer)" : layer) {
                        activeLayer = layer
                    }
                }
            } label: {
                Text(activeLayer)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Spacer(minLength: 0)
            Text(boardInfoText)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(white: 0.11))
    }

    private var cursorText: String {
        guard let point = pointerState.currentPoint else { return "X —  Y —" }
        return "X \(fmt(point.x)) mm  Y \(fmt(point.y)) mm"
    }

    private var boardInfoText: String {
        guard let model else { return "No board loaded" }
        return "\(model.components.count) components · \(model.netCount) nets · "
            + "\(model.traces.count) tracks · \(problemCount) problems · \(model.tableTitle)"
    }

    // MARK: - Canvas transforms (board mm, y DOWN -> screen points)

    /// Draft text for the trace-width field (synced on selection).
    @State private var widthDraft = ""
    /// Draft text for the via diameter / drill fields.
    @State private var viaDiameterDraft = ""
    @State private var viaDrillDraft = ""

    private func boardToScreen(_ p: FPPoint) -> CGPoint {
        CGPoint(x: offset.x + CGFloat(p.x * scale),
                y: offset.y + CGFloat(p.y * scale))
    }

    private func screenToBoard(_ s: CGPoint) -> FPPoint {
        FPPoint(x: Double((s.x - offset.x)) / scale,
                y: Double((s.y - offset.y)) / scale)
    }

    /// Finger tolerance in board mm (≈3.5 screen points, at least
    /// 0.8 mm so pads stay tappable zoomed out).
    private var tapToleranceMM: Double { max(0.8, 3.5 / scale) }

    // MARK: - Zoom (part 4: ceiling 150 pt/mm = 6000 %)

    private func setScale(_ newScale: Double, anchor: CGPoint) {
        let clamped = BoardCanvasMetrics.clamped(newScale)
        guard clamped != scale else { return }
        let anchorBoard = screenToBoard(anchor)
        scale = clamped
        offset = CGPoint(x: anchor.x - CGFloat(anchorBoard.x * clamped),
                         y: anchor.y - CGFloat(anchorBoard.y * clamped))
    }

    private var canvasCentre: CGPoint {
        CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
    }

    private func zoomIn() {
        setScale(scale * BoardCanvasMetrics.zoomStep, anchor: canvasCentre)
    }

    private func zoomOut() {
        setScale(scale / BoardCanvasMetrics.zoomStep, anchor: canvasCentre)
    }

    private func fitBoard() {
        guard let model, canvasSize.width > 10, canvasSize.height > 10 else { return }
        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude
        func include(_ p: FPPoint) {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        for component in model.components {
            let b = BoardGeometry.componentBounds(component)
            include(FPPoint(x: b.minX, y: b.minY))
            include(FPPoint(x: b.maxX, y: b.maxY))
        }
        for trace in model.traces { for point in trace.points { include(point) } }
        for via in model.vias {
            include(FPPoint(x: via.center.x - via.diameter / 2,
                            y: via.center.y - via.diameter / 2))
            include(FPPoint(x: via.center.x + via.diameter / 2,
                            y: via.center.y + via.diameter / 2))
        }
        for zone in model.zones { for point in zone.points { include(point) } }
        for item in model.graphics {
            for point in item.points { include(point) }
            if item.kind == .circle {
                include(FPPoint(x: item.points[0].x - item.radius,
                                y: item.points[0].y - item.radius))
                include(FPPoint(x: item.points[0].x + item.radius,
                                y: item.points[0].y + item.radius))
            }
        }
        guard minX <= maxX, minY <= maxY else { return }
        let w = max(maxX - minX, 1), h = max(maxY - minY, 1)
        let newScale = BoardCanvasMetrics.clamped(
            min((Double(canvasSize.width) - 32) / w,
                (Double(canvasSize.height) - 32) / h))
        scale = newScale
        offset = CGPoint(x: canvasSize.width / 2 - CGFloat((minX + maxX) / 2 * newScale),
                         y: canvasSize.height / 2 - CGFloat((minY + maxY) / 2 * newScale))
    }

    // MARK: - Board canvas + gestures

    private func boardCanvas(model: BoardModel) -> some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                drawBoard(ctx: ctx, size: size, model: model)
            }
            .background(Color(red: 0.043, green: 0.055, blue: 0.043)) // #0B0E0B-ish
            .contentShape(Rectangle())
            .gesture(canvasDrag)
            .simultaneousGesture(canvasMagnify)
            // Apple Pencil hover (part 5.0.1): a UIKit
            // UIHoverGestureRecognizer bridge (CanvasHoverView)
            // feeds the SAME pointer stream the touch path uses.
            // v5.0 used SwiftUI's .onContinuousHover here AND the
            // preview preferred a never-cleared touch point, so
            // the hover preview froze at the first tap (see
            // PCBBoardState.swift). No pencil = no events = the
            // plain touch behaviour, unchanged.
            .overlay {
                CanvasHoverView { location in
                    if let location {
                        pointerState.apply(
                            .hoverMoved(screenToBoard(location)))
                    } else {
                        pointerState.apply(.hoverEnded)
                    }
                }
            }
            .onAppear { canvasSize = geo.size }
            .onChange(of: geo.size) { _, newSize in canvasSize = newSize }
        }
    }

    /// One drag gesture, tool-dependent: with Select, a drag that
    /// starts on a component moves the selected components (live
    /// preview, committed on release); a drag starting on a via
    /// moves the via; any other drag pans. A press that barely
    /// moves is a tap and goes to the active tool.
    private var canvasDrag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                pointerState.apply(.touchMoved(screenToBoard(value.location)))
                if dragMode == .undecided {
                    dragStartOffset = offset
                    let startBoard = screenToBoard(value.startLocation)
                    // A via's hit area is tiny and precise, so it
                    // wins over a footprint's broad bounds.
                    if activeTool == .select, let model,
                       selectionFilter.allows(.via),
                       let via = BoardGeometry.viaAt(model, point: startBoard,
                                                     tolerance: tapToleranceMM),
                       visibility.viaShown(via) {
                        dragMode = .moveVia
                        movingViaID = via.id
                        moveViaStart = via.center
                        moveViaPreview = via.center
                    } else if activeTool == .select, let model,
                              visibility.showFootprints,
                              selectionFilter.allows(.component),
                              let component = BoardGeometry.componentAt(
                                  model, point: startBoard) {
                        if multiSelect
                            && !selections.contains(.component(component.reference)) {
                            // Multi: pressing an UNSELECTED part is
                            // a tap (toggle) or a pan — never a move.
                            dragMode = .pan
                        } else {
                            dragMode = .moveComponents
                            dragTapReference = component.reference
                            if !multiSelect {
                                selectOnly(.component(component.reference))
                            }
                            moveStartOrigins = [:]
                            movePreviewOrigins = [:]
                            for item in selections {
                                if case .component(let reference) = item,
                                   let member = model.components.first(
                                       where: { $0.reference == reference }) {
                                    moveStartOrigins[reference] = member.origin
                                    movePreviewOrigins[reference] = member.origin
                                }
                            }
                            if moveStartOrigins.isEmpty {
                                moveStartOrigins[component.reference] = component.origin
                                movePreviewOrigins[component.reference] = component.origin
                            }
                        }
                    } else {
                        dragMode = .pan
                    }
                }
                switch dragMode {
                case .pan:
                    if let start = dragStartOffset {
                        offset = CGPoint(x: start.x + value.translation.width,
                                         y: start.y + value.translation.height)
                    }
                case .moveComponents:
                    let delta = FPPoint(
                        x: Double(value.translation.width) / scale,
                        y: Double(value.translation.height) / scale)
                    // Snap the drag ANCHOR (the first member) to the
                    // grid; the whole group follows by the same
                    // delta so relative positions never distort.
                    if let anchor = moveStartOrigins.keys.sorted().first,
                       let start = moveStartOrigins[anchor] {
                        let snappedAnchor = snapPoint(FPPoint(x: start.x + delta.x,
                                                              y: start.y + delta.y))
                        let applied = FPPoint(x: snappedAnchor.x - start.x,
                                              y: snappedAnchor.y - start.y)
                        for (reference, origin) in moveStartOrigins {
                            movePreviewOrigins[reference] = FPPoint(
                                x: origin.x + applied.x, y: origin.y + applied.y)
                        }
                    }
                case .moveVia:
                    if let start = moveViaStart {
                        let moved = FPPoint(
                            x: start.x + Double(value.translation.width) / scale,
                            y: start.y + Double(value.translation.height) / scale)
                        moveViaPreview = snapPoint(moved)
                    }
                case .undecided:
                    break
                }
            }
            .onEnded { value in
                // The touch is up: the pointer stream falls back
                // to hover (part 5.0.1). The tap resolution below
                // uses the gesture's own end location, as before.
                pointerState.apply(.touchEnded)
                let moved = hypot(value.translation.width, value.translation.height)
                if moved < 5 {
                    // A tap. A pan-tap undoes its micro-pan and goes
                    // to the active tool; a move-mode tap resolves
                    // its deferred selection (Multi toggles; the
                    // single-select case was applied at drag start).
                    if dragMode == .pan, let start = dragStartOffset {
                        offset = start
                        handleTap(at: screenToBoard(value.location))
                    } else if dragMode == .moveComponents {
                        if multiSelect, let reference = dragTapReference {
                            toggleSelection(.component(reference))
                        }
                    } else if dragMode == .moveVia, let id = movingViaID {
                        applyTapSelection(.via(id))
                    }
                } else if dragMode == .moveComponents {
                    let changes = movePreviewOrigins.filter { preview in
                        moveStartOrigins[preview.key] != preview.value
                    }
                    if !changes.isEmpty {
                        mutateBoard { state in
                            for (reference, origin) in changes {
                                state.placements[reference] = origin
                            }
                        }
                        setStatus(changes.count == 1
                                  ? "\(changes.keys.first!) moved — its position is saved with the board."
                                  : "\(changes.count) components moved together — saved with the board.")
                    }
                } else if dragMode == .moveVia,
                          let id = movingViaID, let centre = moveViaPreview,
                          let start = moveViaStart, centre != start {
                    mutateBoard { state in
                        if let index = state.vias.firstIndex(where: { $0.id == id }) {
                            state.vias[index].center = centre
                        }
                    }
                    if !multiSelect { selectOnly(.via(id)) }
                    setStatus("Via moved — saved with the board.")
                }
                dragMode = .undecided
                dragStartOffset = nil
                moveStartOrigins = [:]
                movePreviewOrigins = [:]
                movingViaID = nil
                moveViaStart = nil
                moveViaPreview = nil
                dragTapReference = nil
            }
    }

    private var canvasMagnify: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if pinchStartScale == nil { pinchStartScale = scale }
                if let start = pinchStartScale {
                    scale = BoardCanvasMetrics.clamped(start * Double(value))
                }
            }
            .onEnded { _ in pinchStartScale = nil }
    }

    // MARK: - Tap handling per tool

    private func handleTap(at point: FPPoint) {
        guard let model else { return }
        switch activeTool {
        case .select:
            handleSelectTap(model: model, point: point)
        case .highlightNet:
            handleHighlightTap(model: model, point: point)
        case .delete:
            handleDeleteTap(model: model, point: point)
        case .route:
            handleRouteTap(model: model, point: point)
        case .placeVia:
            handleViaTap(model: model, point: point)
        case .fillZone:
            handleZoneTap(point: point)
        case .drawLine, .drawArc, .drawCircle:
            handleDrawTap(point: point)
        case .text:
            textAnchor = snapPoint(point)
            textDraft = ""
            showTextPrompt = true
        }
    }

    private func handleSelectTap(model: BoardModel, point: FPPoint) {
        let tolerance = tapToleranceMM
        if selectionFilter.allows(.via),
           let via = model.vias.reversed().first(where: {
               visibility.viaShown($0)
                   && BoardGeometry.viaHit($0, point: point, tolerance: tolerance)
           }) {
            applyTapSelection(.via(via.id))
            return
        }
        if selectionFilter.allows(.trace),
           let trace = model.traces.reversed().first(where: {
               visibility.traceShown($0)
                   && BoardGeometry.traceHit($0, point: point, tolerance: tolerance)
           }) {
            applyTapSelection(.trace(trace.id))
            return
        }
        if selectionFilter.allows(.zone),
           let zone = model.zones.reversed().first(where: {
               visibility.zoneShown($0)
                   && BoardGeometry.zoneHit($0, point: point, tolerance: tolerance)
           }) {
            applyTapSelection(.zone(zone.id))
            return
        }
        if let graphic = model.graphics.reversed().first(where: {
            visibility.boardGraphicShown($0)
                && selectionFilter.allows($0.kind == .text ? .text : .graphic)
                && BoardGeometry.graphicHit($0, point: point, tolerance: tolerance)
        }) {
            applyTapSelection(.graphic(graphic.id))
            return
        }
        if visibility.showFootprints, selectionFilter.allows(.component),
           let component = BoardGeometry.componentAt(model, point: point) {
            applyTapSelection(.component(component.reference))
            return
        }
        // Empty space: a plain tap clears; with Multi on the
        // selection is kept (Esc clears) so building a selection
        // never loses it to a stray tap.
        if !multiSelect { clearSelection() }
    }

    private func handleHighlightTap(model: BoardModel, point: FPPoint) {
        guard visibility.showFootprints, visibility.showPads,
              let hit = BoardGeometry.padAt(model, point: point,
                                            tolerance: tapToleranceMM),
              visibility.padShown(BoardGeometry.boardPad(hit.component, hit.pad))
        else {
            highlightedNet = nil
            setStatus("Net highlight cleared.")
            return
        }
        if let net = hit.netName {
            highlightedNet = net
            setStatus("Highlighting \(net) — its pads and tracks are lit; everything else is dimmed.")
        } else {
            highlightedNet = nil
            setStatus("\(hit.component.reference) pad \(hit.pad.number) is on no net.",
                      warning: true)
        }
    }

    private func handleDeleteTap(model: BoardModel, point: FPPoint) {
        let tolerance = tapToleranceMM
        if let via = model.vias.reversed().first(where: {
            visibility.viaShown($0)
                && BoardGeometry.viaHit($0, point: point, tolerance: tolerance)
        }) {
            selectOnly(.via(via.id))
            deleteSelection()
            return
        }
        if let trace = model.traces.reversed().first(where: {
            visibility.traceShown($0)
                && BoardGeometry.traceHit($0, point: point, tolerance: tolerance)
        }) {
            selectOnly(.trace(trace.id))
            deleteSelection()
            return
        }
        if let zone = model.zones.reversed().first(where: {
            visibility.zoneShown($0)
                && BoardGeometry.zoneHit($0, point: point, tolerance: tolerance)
        }) {
            selectOnly(.zone(zone.id))
            deleteSelection()
            return
        }
        if let graphic = model.graphics.reversed().first(where: {
            visibility.boardGraphicShown($0)
                && BoardGeometry.graphicHit($0, point: point, tolerance: tolerance)
        }) {
            selectOnly(.graphic(graphic.id))
            deleteSelection()
            return
        }
        if visibility.showFootprints,
           let component = BoardGeometry.componentAt(model, point: point) {
            selectOnly(.component(component.reference))
            deleteSelection()
        }
    }

    /// Delete the WHOLE selection (part 5: group delete covers
    /// components, traces, vias, zones and graphics together).
    private func deleteSelection() {
        guard !selections.isEmpty else { return }
        let doomed = selections
        clearSelection()
        var removedComponents: [String] = []
        var counts: [String] = []
        mutateBoard { state in
            for item in doomed {
                switch item {
                case .component(let reference):
                    if !state.excludedReferences.contains(reference) {
                        state.excludedReferences.append(reference)
                        removedComponents.append(reference)
                    }
                case .trace(let id):
                    if state.traces.contains(where: { $0.id == id }) {
                        state.traces.removeAll { $0.id == id }
                        counts.append("track")
                    }
                case .graphic(let id):
                    if state.graphics.contains(where: { $0.id == id }) {
                        state.graphics.removeAll { $0.id == id }
                        counts.append("graphic")
                    }
                case .via(let id):
                    if state.vias.contains(where: { $0.id == id }) {
                        state.vias.removeAll { $0.id == id }
                        counts.append("via")
                    }
                case .zone(let id):
                    if state.zones.contains(where: { $0.id == id }) {
                        state.zones.removeAll { $0.id == id }
                        counts.append("fill")
                    }
                }
            }
        }
        var parts: [String] = []
        if !removedComponents.isEmpty {
            parts.append("\(removedComponents.joined(separator: ", ")) removed from the board (Sync from Schematic brings them back)")
        }
        if !counts.isEmpty {
            parts.append("\(counts.count) item(s) deleted (\(counts.joined(separator: ", ")))")
        }
        setStatus(parts.isEmpty ? "Nothing deleted." : parts.joined(separator: " · "))
    }

    // MARK: - Flip Side / Change Layer (part 5, Sean 18:32)

    /// The flip destinations are pinned: exactly F.Cu and B.Cu
    /// (BoardLayers.flipDestinations, asserted by BoardFixture).
    private var flippableSelections: (components: [String], traces: [BoardTrace]) {
        guard let model else { return ([], []) }
        var components: [String] = []
        var traces: [BoardTrace] = []
        for item in selections {
            switch item {
            case .component(let reference): components.append(reference)
            case .trace(let id):
                if let trace = model.traces.first(where: { $0.id == id }),
                   BoardLayers.flipDestinations.contains(trace.layer) {
                    traces.append(trace)
                }
            case .graphic, .via, .zone: break
            }
        }
        return (components, traces)
    }

    private var canFlipSelection: Bool {
        let parts = flippableSelections
        return !parts.components.isEmpty || !parts.traces.isEmpty
    }

    private var flipActionTitle: String {
        let parts = flippableSelections
        if parts.components.count == 1, parts.traces.isEmpty,
           let model,
           let component = model.components.first(
               where: { $0.reference == parts.components[0] }) {
            return component.side == .front ? "Flip to Back (B.Cu)" : "Flip to Front (F.Cu)"
        }
        return "Flip Side / Change Layer"
    }

    /// Footprints mirror to the other side (their `sides` entry
    /// toggles — pad geometry derives from the side, so pin↔pad
    /// bindings stay exact); traces keep their coordinates and only
    /// change layer. Vias span layers, zones and non-copper
    /// graphics aren't copper objects — they're skipped and the
    /// status line says so.
    private func flipSelection() {
        let parts = flippableSelections
        guard !parts.components.isEmpty || !parts.traces.isEmpty else {
            setStatus("Nothing to flip — vias span all layers, and fills and drawings aren't flipped. Select a footprint or an F.Cu/B.Cu track.",
                      warning: true)
            return
        }
        let traceIDs = Set(parts.traces.map(\.id))
        mutateBoard { state in
            for reference in parts.components {
                state.sides[reference] =
                    (state.sides[reference] ?? .front) == .front ? .back : .front
            }
            for index in state.traces.indices where traceIDs.contains(state.traces[index].id) {
                state.traces[index].layer =
                    BoardGeometry.flippedLayerName(state.traces[index].layer)
            }
        }
        var summary: [String] = []
        if !parts.components.isEmpty {
            summary.append("\(parts.components.joined(separator: ", ")) flipped "
                           + "to the \(parts.components.first.map { reference in model?.components.first { $0.reference == reference }?.side == .back ? "back" : "front" } ?? "")")
        }
        if !parts.traces.isEmpty {
            summary.append("\(parts.traces.count) track(s) moved between F.Cu and B.Cu (coordinates unchanged)")
        }
        let skipped = selections.count - parts.components.count - parts.traces.count
        if skipped > 0 {
            summary.append("\(skipped) item(s) skipped — only footprints and F.Cu/B.Cu tracks flip")
        }
        setStatus(summary.joined(separator: " · "))
    }

    // MARK: - Routing (Route Tracks)

    private func handleRouteTap(model: BoardModel, point: FPPoint) {
        if !routingActive {
            // Routing needs copper (part 5): say so instead of
            // quietly laying a track on silk.
            guard BoardLayers.isCopper(activeLayer) else {
                setStatus("Routing needs a copper layer — the active layer is \(activeLayer). Switch to F.Cu or B.Cu first.",
                          warning: true)
                return
            }
        }
        // All geometry (pad snap, grid snap, net refusal) is
        // resolved by BoardGeometry.routeTap — the SAME resolution
        // the hover preview renders (part 5.0.1), so the segment
        // Sean sees while hovering is the segment the tap commits.
        switch BoardGeometry.routeTap(model: model, point: point,
                                      routingActive: routingActive,
                                      routeNet: routeNet,
                                      snapEnabled: snapEnabled,
                                      gridMil: boardState.gridMil,
                                      tolerance: tapToleranceMM) {
        case .needsPad:
            setStatus("Tap a pad to start the track.", warning: true)
        case .startPad(let target):
            routeNet = target.netName
            routePoints = [target.center]
            if let net = target.netName {
                setStatus("Routing \(net) from \(target.reference) pad "
                          + "\(target.padNumber) on \(activeLayer) — tap "
                          + "waypoints, then the target pad.")
            } else {
                setStatus("Routing an unconnected track from \(target.reference) "
                          + "pad \(target.padNumber) — tap waypoints, then a pad or Finish.")
            }
        case .refusedForeignNet(let padNet):
            setStatus("That's net \(padNet) — this track is \(routeNet ?? "") and "
                      + "can't join a different net.", warning: true)
        case .finishAtPad(let target):
            if routeNet == nil { routeNet = target.netName }
            appendRoutePoint(target.center)
            finishRoute()
        case .appendPoint(let snapped):
            appendRoutePoint(snapped)
        }
    }

    /// Append a point to the in-progress track, inserting the 45°
    /// corner KiCad's router would make.
    private func appendRoutePoint(_ point: FPPoint) {
        guard let last = routePoints.last else {
            routePoints = [point]
            return
        }
        if let corner = BoardGeometry.routeCorner(from: last, to: point) {
            routePoints.append(corner)
        }
        if point != last { routePoints.append(point) }
    }

    private func finishRoute() {
        guard routingActive else { return }
        var cleaned: [FPPoint] = []
        for point in routePoints where cleaned.last != point {
            cleaned.append(point)
        }
        guard cleaned.count >= 2 else {
            cancelInProgress()
            setStatus("Track discarded — it needs at least two points.", warning: true)
            return
        }
        let trace = BoardTrace(id: UUID(), netName: routeNet,
                               layer: activeLayer,
                               width: currentTrackWidth, points: cleaned)
        mutateBoard { state in state.traces.append(trace) }
        selectOnly(.trace(trace.id))
        cancelInProgress()
        setStatus("Track added on \(trace.layer) — \(trace.netName ?? "unconnected"), "
                  + "\(PCBBoardMerger.formatMM(trace.width)) mm wide, "
                  + "\(BoardUnits.formatLength(mm: trace.length)) long. "
                  + "Select it any time to change its width.")
    }

    // MARK: - Vias (Place Via)

    private func handleViaTap(model: BoardModel, point: FPPoint) {
        guard BoardLayers.isCopper(activeLayer) else {
            setStatus("Vias need a copper layer — the active layer is \(activeLayer). Switch to a copper layer first.",
                      warning: true)
            return
        }
        let snapped = snapPoint(point)
        // Net resolution: a tapped pad's net wins; else the
        // highlighted net; else ask.
        if let hit = BoardGeometry.padAt(model, point: point,
                                         tolerance: tapToleranceMM) {
            if let net = hit.netName {
                placeVia(net: net, at: snapped)
            } else {
                setStatus("\(hit.component.reference) pad \(hit.pad.number) is on no net — pick the via's net.",
                          warning: true)
                netChoicePurpose = .via(snapped)
            }
            return
        }
        if let highlightedNet {
            placeVia(net: highlightedNet, at: snapped)
            return
        }
        if model.netNames.count == 1, let only = model.netNames.first {
            placeVia(net: only, at: snapped)
            return
        }
        if model.netNames.isEmpty {
            setStatus("This board has no nets yet — a via needs a net.", warning: true)
            return
        }
        netChoicePurpose = .via(snapped)
    }

    private func placeVia(net: String, at point: FPPoint) {
        let via = BoardVia(id: UUID(), netName: net, center: point,
                           diameter: currentViaDiameter, drill: currentViaDrill)
        mutateBoard { state in state.vias.append(via) }
        selectOnly(.via(via.id))
        setStatus("Via placed on \(net) — \(PCBBoardMerger.formatMM(via.diameter)) mm, "
                  + "drill \(PCBBoardMerger.formatMM(via.drill)) mm, spanning all copper layers.")
    }

    // MARK: - Copper fill zones (Fill Zone)

    private func handleZoneTap(point: FPPoint) {
        guard BoardLayers.isCopper(activeLayer) else {
            setStatus("A copper fill needs a copper layer — the active layer is \(activeLayer). Switch to a copper layer first.",
                      warning: true)
            return
        }
        zonePoints.append(snapPoint(point))
    }

    private func finishZone() {
        guard zonePoints.count >= 3 else {
            setStatus("A fill needs at least three corners.", warning: true)
            return
        }
        guard let model, !model.netNames.isEmpty else {
            setStatus("This board has no nets — a fill needs a net.", warning: true)
            return
        }
        netChoicePurpose = .zone
    }

    private func commitZone(net: String) {
        guard zonePoints.count >= 3 else { return }
        let zone = BoardZone(id: UUID(), netName: net, layer: activeLayer,
                             points: zonePoints)
        mutateBoard { state in state.zones.append(zone) }
        selectOnly(.zone(zone.id))
        zonePoints = []
        setStatus("Copper fill added on \(zone.layer) for \(net) — it renders under tracks and pads, keeping the board clearance around other nets.")
    }

    // MARK: - Drawing tools (line / arc / circle / text)

    private func handleDrawTap(point: FPPoint) {
        pendingPoints.append(snapPoint(point))
        switch activeTool {
        case .drawLine where pendingPoints.count == 2:
            createGraphic(BoardGraphicItem(id: UUID(), kind: .line,
                                           layer: activeLayer, points: pendingPoints))
        case .drawCircle where pendingPoints.count == 2:
            let radius = pendingPoints[0].distance(to: pendingPoints[1])
            if radius > 0.05 {
                createGraphic(BoardGraphicItem(id: UUID(), kind: .circle,
                                               layer: activeLayer,
                                               points: [pendingPoints[0]],
                                               radius: radius))
            } else {
                pendingPoints = []
                setStatus("Circle too small — tap its centre, then a point on its edge.",
                          warning: true)
            }
        case .drawArc where pendingPoints.count == 3:
            createGraphic(BoardGraphicItem(id: UUID(), kind: .arc,
                                           layer: activeLayer, points: pendingPoints))
        default:
            break
        }
    }

    private func createGraphic(_ item: BoardGraphicItem) {
        mutateBoard { state in state.graphics.append(item) }
        selectOnly(.graphic(item.id))
        pendingPoints = []
        setStatus("\(item.kind.rawValue.capitalized) drawn on \(item.layer).")
    }

    private func placeText() {
        let text = textDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let anchor = textAnchor, !text.isEmpty else {
            textAnchor = nil
            return
        }
        createGraphic(BoardGraphicItem(id: UUID(), kind: .text, layer: activeLayer,
                                       points: [anchor], text: text, textSize: 1.5))
        textAnchor = nil
    }

    // MARK: - Board drawing

    private func displayOrigin(_ component: BoardComponent) -> FPPoint {
        if let preview = movePreviewOrigins[component.reference] {
            return preview
        }
        return component.origin
    }

    private func displayViaCenter(_ via: BoardVia) -> FPPoint {
        if movingViaID == via.id, let preview = moveViaPreview {
            return preview
        }
        return via.center
    }

    private func drawBoard(ctx: GraphicsContext, size: CGSize, model: BoardModel) {
        var ctx = ctx
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .color(Color(red: 0.043, green: 0.055, blue: 0.043)))
        if showGrid { drawGridDots(&ctx, size: size) }

        // Board graphics (drawings) under everything else.
        for item in model.graphics where item.kind != .text
            && visibility.boardGraphicShown(item) {
            drawBoardGraphic(&ctx, item: item)
        }
        // Copper fills (part 5) under traces and pads, with the
        // clearance gap cut around foreign-net copper.
        for zone in model.zones where visibility.zoneShown(zone) {
            drawZone(&ctx, zone: zone, model: model)
        }
        // Copper traces, batched by style (part 5, item 3).
        drawAllTraces(&ctx, model: model)
        // Vias (part 5) sit on the copper they connect.
        for via in model.vias where visibility.viaShown(via) {
            drawVia(&ctx, via: via)
        }
        // Components (their own graphics + pads, visibility-filtered).
        for component in model.components {
            drawComponent(&ctx, component: component,
                          selected: selections.contains(.component(component.reference)))
        }
        // Board text items.
        for item in model.graphics where item.kind == .text
            && visibility.boardGraphicShown(item) {
            drawBoardGraphic(&ctx, item: item)
        }
        // Selection overlay for a chosen graphic.
        if let graphic = selectedGraphic,
           visibility.boardGraphicShown(graphic) {
            drawGraphicOverlay(&ctx, item: graphic)
        }
        // In-progress previews.
        drawPreviews(&ctx, model: model)
    }

    private func drawGridDots(_ ctx: inout GraphicsContext, size: CGSize) {
        // The dot grid follows the USER's snap grid (part 5): the
        // base step is the grid itself, doubled/halved only to stay
        // readable at the current zoom (v4 behaviour, new base).
        var step = gridMM
        while step * scale < 9 { step *= 2 }
        while step * scale > 90, step > 0.02 { step /= 2 }
        let topLeft = screenToBoard(.zero)
        let bottomRight = screenToBoard(CGPoint(x: size.width, y: size.height))
        var path = Path()
        var x = (topLeft.x / step).rounded(.down) * step
        while x <= bottomRight.x {
            var y = (topLeft.y / step).rounded(.down) * step
            while y <= bottomRight.y {
                let c = boardToScreen(FPPoint(x: x, y: y))
                path.addEllipse(in: CGRect(x: c.x - 0.7, y: c.y - 0.7, width: 1.4, height: 1.4))
                y += step
            }
            x += step
        }
        ctx.fill(path, with: .color(.white.opacity(0.16)))
    }

    private func copperColor(_ layer: String) -> Color {
        layerColor(layer)
    }

    // MARK: Trace drawing — batched (part 5, item 3)
    //
    // Part 4 stroked every segment of every trace as its own
    // GraphicsContext call. Part 5 builds ONE Path per
    // (colour, alpha, width, dash) bucket across the whole board
    // and strokes each bucket once — same pixels, a fraction of
    // the draw calls. Selected traces keep their individual white
    // underlay pass (there are only ever a few).

    private struct TraceStyleKey: Hashable {
        var colorName: String
        var alphaSteps: Int
        var widthSteps: Int
        var dashed: Bool
    }

    private func drawAllTraces(_ ctx: inout GraphicsContext, model: BoardModel) {
        var buckets: [TraceStyleKey: Path] = [:]
        var bucketOrder: [TraceStyleKey] = []
        for trace in model.traces where visibility.traceShown(trace) {
            guard trace.points.count > 1 else { continue }
            let isSelected = selections.contains(.trace(trace.id))
            var path = Path()
            for (index, point) in trace.points.enumerated() {
                let screen = boardToScreen(point)
                if index == 0 { path.move(to: screen) } else { path.addLine(to: screen) }
            }
            let width = max(1.2, CGFloat(trace.width * scale))
            if isSelected {
                ctx.stroke(path, with: .color(.white.opacity(0.85)),
                           style: StrokeStyle(lineWidth: width + 3, lineCap: .round,
                                              lineJoin: .round))
            }
            var colorName = trace.layer
            var alpha = 1.0
            if trace.netName == nil {
                if trace.disconnectedNetName != nil { colorName = "__grey" }
                alpha = 0.75
            }
            if trace.layer != activeLayer { alpha *= 0.55 }
            if let highlightedNet {
                alpha *= (trace.netName == highlightedNet) ? 1.0 : 0.18
            }
            let key = TraceStyleKey(
                colorName: colorName,
                alphaSteps: Int((alpha * 100).rounded()),
                widthSteps: Int((width * 10).rounded()),
                dashed: trace.disconnectedNetName != nil)
            if buckets[key] == nil { bucketOrder.append(key) }
            buckets[key]?.addPath(path)
            if buckets[key] == nil { buckets[key] = path }
        }
        for key in bucketOrder {
            guard let path = buckets[key] else { continue }
            let color = key.colorName == "__grey"
                ? Color(white: 0.55) : copperColor(key.colorName)
            var style = StrokeStyle(
                lineWidth: CGFloat(key.widthSteps) / 10,
                lineCap: .round, lineJoin: .round)
            if key.dashed { style.dash = [8, 5] }
            ctx.opacity = Double(key.alphaSteps) / 100
            ctx.stroke(path, with: .color(color), style: style)
            ctx.opacity = 1
        }
    }

    // MARK: Vias + zones drawing (part 5)

    private func drawVia(_ ctx: inout GraphicsContext, via: BoardVia) {
        let centreBoard = displayViaCenter(via)
        let centre = boardToScreen(centreBoard)
        let r = CGFloat(via.diameter / 2 * scale)
        let drillR = CGFloat(via.drill / 2 * scale)
        var alpha = 1.0
        if let highlightedNet, via.netName != highlightedNet { alpha *= 0.3 }
        ctx.opacity = alpha
        // Annulus in the F.Cu colour (a via lives on every copper
        // layer at once), drill in board background.
        ctx.fill(Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r,
                                        width: 2 * r, height: 2 * r)),
                 with: .color(copperColor("F.Cu")))
        ctx.fill(Path(ellipseIn: CGRect(x: centre.x - drillR, y: centre.y - drillR,
                                        width: 2 * drillR, height: 2 * drillR)),
                 with: .color(Color(red: 0.043, green: 0.055, blue: 0.043)))
        ctx.opacity = 1
        if selections.contains(.via(via.id)) {
            ctx.stroke(Path(ellipseIn: CGRect(x: centre.x - r - 3, y: centre.y - r - 3,
                                              width: 2 * r + 6, height: 2 * r + 6)),
                       with: .color(.white.opacity(0.9)),
                       style: StrokeStyle(lineWidth: 1.6, dash: [6, 4]))
        }
        if let net = via.netName {
            ctx.draw(Text(net)
                .font(.system(size: max(7, min(11, scale * 1.1)), weight: .semibold))
                .foregroundColor(Color(red: 0.55, green: 0.95, blue: 0.85)
                    .opacity(alpha)),
                     at: CGPoint(x: centre.x, y: centre.y + r + 2),
                     anchor: UnitPoint(x: 0.5, y: 0))
        }
    }

    /// A copper fill: the polygon filled in its layer colour UNDER
    /// everything else copper, with the board clearance cut around
    /// foreign-net copper (pads, traces, vias on the same layer).
    /// The cuts are clipped to the polygon, so nothing outside the
    /// fill is touched. Same-net copper needs no gap and gets none.
    private func drawZone(_ ctx: inout GraphicsContext, zone: BoardZone,
                          model: BoardModel) {
        guard zone.points.count >= 3 else { return }
        var path = Path()
        for (index, point) in zone.points.enumerated() {
            let screen = boardToScreen(point)
            if index == 0 { path.move(to: screen) } else { path.addLine(to: screen) }
        }
        path.closeSubpath()
        var alpha = 0.45
        if let highlightedNet, zone.netName != highlightedNet { alpha *= 0.4 }
        ctx.opacity = alpha
        ctx.fill(path, with: .color(copperColor(zone.layer)))
        ctx.opacity = 1

        // Clearance cuts, clipped to the fill. (GraphicsContext
        // is a value type — the clipped copy leaves the caller's
        // context untouched.)
        let clearance = BoardUnits.mm(fromMil: boardState.clearanceMil)
        var cutCtx = ctx
        cutCtx.clip(to: path)
        let background = Color(red: 0.043, green: 0.055, blue: 0.043)
        for component in model.components {
            guard let footprint = component.footprint else { continue }
            var display = component
            display.origin = displayOrigin(component)
            for pad in footprint.pads where !pad.number.isEmpty {
                let effective = BoardGeometry.boardPad(display, pad)
                guard effective.layers.contains(zone.layer)
                        || effective.layers.contains("*.Cu") else { continue }
                let padNet = BoardGeometry.netName(component, pad)
                guard padNet != zone.netName else { continue }
                let corners = BoardGeometry.padOutline(display, pad)
                guard corners.count >= 3 else { continue }
                var outline = Path()
                for (index, corner) in corners.enumerated() {
                    let screen = boardToScreen(corner)
                    if index == 0 { outline.move(to: screen) }
                    else { outline.addLine(to: screen) }
                }
                outline.closeSubpath()
                cutCtx.stroke(outline, with: .color(background),
                              style: StrokeStyle(
                                  lineWidth: CGFloat(2 * clearance * scale),
                                  lineCap: .round, lineJoin: .round))
                cutCtx.fill(outline, with: .color(background))
            }
        }
        for trace in model.traces
        where trace.layer == zone.layer && trace.netName != zone.netName
            && trace.points.count > 1 {
            var line = Path()
            for (index, point) in trace.points.enumerated() {
                let screen = boardToScreen(point)
                if index == 0 { line.move(to: screen) } else { line.addLine(to: screen) }
            }
            cutCtx.stroke(line, with: .color(background),
                          style: StrokeStyle(
                              lineWidth: CGFloat((trace.width + 2 * clearance) * scale),
                              lineCap: .round, lineJoin: .round))
        }
        for via in model.vias where via.netName != zone.netName {
            let centre = boardToScreen(via.center)
            let r = CGFloat((via.diameter / 2 + clearance) * scale)
            cutCtx.fill(Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r,
                                               width: 2 * r, height: 2 * r)),
                        with: .color(background))
        }

        ctx.stroke(path, with: .color(copperColor(zone.layer).opacity(0.9)),
                   style: StrokeStyle(lineWidth: 1.2))
        if selections.contains(.zone(zone.id)) {
            ctx.stroke(path, with: .color(.white.opacity(0.9)),
                       style: StrokeStyle(lineWidth: 1.8, dash: [7, 4]))
        }
    }

    private func drawBoardGraphic(_ ctx: inout GraphicsContext,
                                  item: BoardGraphicItem) {
        let color = graphicColor(item.layer)
        switch item.kind {
        case .line, .arc, .circle:
            if let path = graphicPath(item) {
                ctx.stroke(path, with: .color(color),
                           style: StrokeStyle(
                               lineWidth: max(0.9, CGFloat(item.strokeWidth * scale)),
                               lineCap: .round, lineJoin: .round))
            }
        case .text:
            guard let anchor = item.points.first, !item.text.isEmpty else { return }
            let screenAnchor = boardToScreen(anchor)
            // Text on a back layer reads mirrored, as it does on a
            // real board viewed from the front.
            if item.layer.hasPrefix("B.") {
                drawMirroredText(&ctx, item.text,
                                 size: max(7, CGFloat(item.textSize * scale)),
                                 color: color, at: screenAnchor,
                                 anchor: .center, axisX: screenAnchor.x)
            } else {
                ctx.draw(Text(item.text)
                    .font(.system(size: max(7, CGFloat(item.textSize * scale))))
                    .foregroundColor(color),
                         at: screenAnchor, anchor: .center)
            }
        }
    }

    /// Draw text as the mirror image of drawing it at `point` with
    /// `anchor` unmirrored, mirrored around the vertical line
    /// x = axisX — how back-side lettering actually looks through
    /// the board. (The transform does all the work; the point and
    /// anchor stay exactly as the front-side call would use.)
    private func drawMirroredText(_ ctx: inout GraphicsContext, _ text: String,
                                  size: CGFloat, color: Color, at point: CGPoint,
                                  anchor: UnitPoint, axisX: CGFloat,
                                  bold: Bool = false) {
        // GraphicsContext is a value type: a copy carries its own
        // transform state, so mirroring never leaks into the
        // caller's context.
        var mctx = ctx
        mctx.translateBy(x: 2 * axisX, y: 0)
        mctx.scaleBy(x: -1, y: 1)
        mctx.draw(Text(text)
            .font(.system(size: size, weight: bold ? .bold : .regular))
            .foregroundColor(color),
                 at: point, anchor: anchor)
    }

    private func drawGraphicOverlay(_ ctx: inout GraphicsContext,
                                    item: BoardGraphicItem) {
        if let path = graphicPath(item) {
            ctx.stroke(path, with: .color(.orange),
                       style: StrokeStyle(lineWidth: 1.6, lineCap: .round,
                                          lineJoin: .round, dash: [6, 4]))
        } else if item.kind == .text, let anchor = item.points.first {
            let centre = boardToScreen(anchor)
            let r = max(10, CGFloat(item.textSize * scale) / 2 + 4)
            ctx.stroke(Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r,
                                              width: 2 * r, height: 2 * r)),
                       with: .color(.orange),
                       style: StrokeStyle(lineWidth: 1.6, dash: [6, 4]))
        }
    }

    /// The screen-space path of a line / arc / circle graphic.
    private func graphicPath(_ item: BoardGraphicItem) -> Path? {
        switch item.kind {
        case .line:
            guard item.points.count == 2 else { return nil }
            var path = Path()
            path.move(to: boardToScreen(item.points[0]))
            path.addLine(to: boardToScreen(item.points[1]))
            return path
        case .arc:
            guard item.points.count == 3 else { return nil }
            let samples = BoardGeometry.arcSamplePoints(
                start: item.points[0], mid: item.points[1], end: item.points[2])
            var path = Path()
            for (index, point) in samples.enumerated() {
                let screen = boardToScreen(point)
                if index == 0 { path.move(to: screen) } else { path.addLine(to: screen) }
            }
            return path
        case .circle:
            guard let centre = item.points.first else { return nil }
            let c = boardToScreen(centre)
            let r = CGFloat(item.radius * scale)
            return Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r,
                                          width: 2 * r, height: 2 * r))
        case .text:
            return nil
        }
    }

    private func drawPreviews(_ ctx: inout GraphicsContext, model: BoardModel) {
        // The pointer for previews comes from the ONE pointer
        // stream (part 5.0.1): the touch point while a touch is
        // down, else the Apple Pencil hover point.
        let pointer = pointerState.currentPoint
        // Routing: laid points + the 45° preview head to the
        // pointer. The head is resolved by BoardGeometry.routePreview
        // — KiCad's Move(aP, aEndItem): pad-anchored (the exact pad
        // centre) when a pad is within tolerance, grid-snapped
        // otherwise, and IDENTICAL to what a tap would commit
        // (routeTap shares the resolution).
        if routingActive {
            var points = routePoints
            var preview: BoardRoutePreview? = nil
            if let pointer, let last = points.last {
                let resolved = BoardGeometry.routePreview(
                    model: model, from: last, pointer: pointer,
                    routeNet: routeNet, snapEnabled: snapEnabled,
                    gridMil: boardState.gridMil, tolerance: tapToleranceMM)
                preview = resolved
                if let corner = resolved.corner { points.append(corner) }
                points.append(resolved.endPoint)
            }
            var path = Path()
            for (index, point) in points.enumerated() {
                let screen = boardToScreen(point)
                if index == 0 { path.move(to: screen) } else { path.addLine(to: screen) }
            }
            ctx.stroke(path, with: .color(Color.accentColor.opacity(0.9)),
                       style: StrokeStyle(
                           lineWidth: max(1.5, CGFloat(currentTrackWidth * scale)),
                           lineCap: .round, lineJoin: .round))
            for point in routePoints {
                let screen = boardToScreen(point)
                ctx.fill(Path(ellipseIn: CGRect(x: screen.x - 3, y: screen.y - 3,
                                                width: 6, height: 6)),
                         with: .color(.white))
            }
            // KiCad-style end-item feedback: the pad the head is
            // anchored to lights up — red when joining it would
            // cross nets (the tap would be refused).
            if let target = preview?.target {
                drawPadHoverRing(&ctx, target: target,
                                 refused: preview?.joinRefused ?? false)
            }
        }
        // Zone drawing: vertices so far + preview edge.
        if zoneActive {
            var points = zonePoints
            if let pointer { points.append(snapPoint(pointer)) }
            var path = Path()
            for (index, point) in points.enumerated() {
                let screen = boardToScreen(point)
                if index == 0 { path.move(to: screen) } else { path.addLine(to: screen) }
            }
            if zonePoints.count >= 3 { path.closeSubpath() }
            ctx.stroke(path, with: .color(.white.opacity(0.85)),
                       style: StrokeStyle(lineWidth: 1.4, dash: [5, 4]))
            for point in zonePoints {
                let screen = boardToScreen(point)
                ctx.fill(Path(ellipseIn: CGRect(x: screen.x - 3, y: screen.y - 3,
                                                width: 6, height: 6)),
                         with: .color(.white))
            }
        }
        // Draw tools: the shape so far, to the pointer.
        if !pendingPoints.isEmpty, let pointer {
            let cursor = snapPoint(pointer)
            var path = Path()
            switch activeTool {
            case .drawLine:
                path.move(to: boardToScreen(pendingPoints[0]))
                path.addLine(to: boardToScreen(cursor))
            case .drawCircle:
                let centre = boardToScreen(pendingPoints[0])
                let r = CGFloat(pendingPoints[0].distance(to: cursor) * scale)
                path.addEllipse(in: CGRect(x: centre.x - r, y: centre.y - r,
                                           width: 2 * r, height: 2 * r))
            case .drawArc:
                if pendingPoints.count == 2 {
                    let samples = BoardGeometry.arcSamplePoints(
                        start: pendingPoints[0], mid: pendingPoints[1], end: cursor)
                    for (index, point) in samples.enumerated() {
                        let screen = boardToScreen(point)
                        if index == 0 { path.move(to: screen) }
                        else { path.addLine(to: screen) }
                    }
                } else {
                    path.move(to: boardToScreen(pendingPoints[0]))
                    path.addLine(to: boardToScreen(cursor))
                }
            default:
                break
            }
            ctx.stroke(path, with: .color(.white.opacity(0.8)),
                       style: StrokeStyle(lineWidth: 1.4, dash: [5, 4]))
        }
        // Hover highlight (part 5.0.1): when the pointer HOVERS
        // (no touch down) and no track is in progress, the pad or
        // trace under the pencil lights up — KiCad's hover
        // feedback, so Sean can see what a tap would act on.
        if !routingActive, !pointerState.touchActive, let pointer,
           let hover = BoardGeometry.hoverTarget(
               model: model, point: pointer, tolerance: tapToleranceMM) {
            switch hover {
            case .pad(let target):
                drawPadHoverRing(&ctx, target: target, refused: false)
            case .trace(let id):
                if let trace = model.traces.first(where: { $0.id == id }),
                   trace.points.count > 1 {
                    var path = Path()
                    for (index, point) in trace.points.enumerated() {
                        let screen = boardToScreen(point)
                        if index == 0 { path.move(to: screen) }
                        else { path.addLine(to: screen) }
                    }
                    ctx.stroke(path, with: .color(.white.opacity(0.55)),
                               style: StrokeStyle(
                                   lineWidth: max(1.2, CGFloat(trace.width * scale)) + 3,
                                   lineCap: .round, lineJoin: .round))
                }
            }
        }
    }

    /// The hover ring around a pad target: warm yellow normally,
    /// red when anchoring there would be refused (foreign net).
    private func drawPadHoverRing(_ ctx: inout GraphicsContext,
                                  target: BoardPadTarget, refused: Bool) {
        let centre = boardToScreen(target.center)
        let w = CGFloat(target.width * scale) + 9
        let h = CGFloat(target.height * scale) + 9
        let rect = CGRect(x: centre.x - w / 2, y: centre.y - h / 2,
                          width: w, height: h)
        let colour = refused ? Color.red
                             : Color(red: 1.0, green: 0.85, blue: 0.2)
        ctx.stroke(Path(roundedRect: rect, cornerRadius: 4),
                   with: .color(colour),
                   style: StrokeStyle(lineWidth: 2))
    }

    private func drawComponent(_ ctx: inout GraphicsContext,
                               component: BoardComponent, selected: Bool) {
        guard visibility.showFootprints else { return }
        var component = component
        component.origin = displayOrigin(component)
        let b = BoardGeometry.componentBounds(component)
        let topLeft = boardToScreen(FPPoint(x: b.minX, y: b.minY))
        let rect = CGRect(x: topLeft.x, y: topLeft.y,
                          width: CGFloat(b.maxX - b.minX) * scale,
                          height: CGFloat(b.maxY - b.minY) * scale)

        if selected {
            ctx.stroke(Path(rect.insetBy(dx: -4, dy: -4)), with: .color(.orange),
                       style: StrokeStyle(lineWidth: 1.6, dash: [6, 4]))
        }

        guard let footprint = component.footprint else {
            // Unresolved footprint: dashed placeholder box.
            ctx.stroke(Path(rect), with: .color(.orange.opacity(0.8)),
                       style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
            ctx.draw(Text("NO FOOTPRINT")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.orange),
                     at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
            drawReferenceLabel(&ctx, component: component, rect: rect)
            return
        }

        // Footprint graphics, layer/object-filtered — flipped
        // parts draw their EFFECTIVE (mirrored) graphics, so the
        // visibility predicates and colours follow the side the
        // part actually sits on.
        for graphic in footprint.graphics {
            let effective = BoardGeometry.boardGraphic(component, graphic)
            if visibility.footprintGraphicShown(effective) {
                drawGraphic(&ctx, graphic: effective, origin: component.origin)
            }
        }
        // Highlight halo under the highlighted net's pads.
        if let highlightedNet {
            for pin in component.pins where pin.netName == highlightedNet {
                guard let pad = pin.pad else { continue }
                let centre = boardToScreen(BoardGeometry.padCenter(component, pad))
                let r = max(CGFloat(pad.width), CGFloat(pad.height)) * scale * 0.85
                ctx.fill(Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r,
                                                width: 2 * r, height: 2 * r)),
                         with: .color(Color(red: 1.0, green: 0.85, blue: 0.2)
                            .opacity(0.35)))
            }
        }
        // Pads with numbers + net names, visibility-filtered.
        for pad in footprint.pads
        where visibility.padShown(BoardGeometry.boardPad(component, pad)) {
            drawPad(&ctx, pad: pad, component: component)
        }
        if visibility.showText,
           visibility.layerShown(component.side == .front ? "F.SilkS" : "B.SilkS")
            || visibility.layerShown(component.side == .front ? "F.Fab" : "B.Fab") {
            drawReferenceLabel(&ctx, component: component, rect: rect)
        }
    }

    private func drawReferenceLabel(_ ctx: inout GraphicsContext,
                                    component: BoardComponent, rect: CGRect) {
        // A back-side part's reference/value read mirrored (they
        // live on the back silkscreen in reality): same points and
        // anchors as the front calls, mirrored around the bounds'
        // vertical centreline.
        if component.side == .back {
            drawMirroredText(&ctx, component.reference, size: 12, color: .white,
                             at: CGPoint(x: rect.minX, y: rect.minY - 3),
                             anchor: UnitPoint(x: 0, y: 1), axisX: rect.midX,
                             bold: true)
            if !component.value.isEmpty {
                drawMirroredText(&ctx, component.value, size: 10,
                                 color: .white.opacity(0.6),
                                 at: CGPoint(x: rect.minX, y: rect.maxY + 3),
                                 anchor: UnitPoint(x: 0, y: 0), axisX: rect.midX)
            }
            return
        }
        ctx.draw(Text(component.reference)
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(.white),
                 at: CGPoint(x: rect.minX, y: rect.minY - 3),
                 anchor: UnitPoint(x: 0, y: 1))
        if !component.value.isEmpty {
            ctx.draw(Text(component.value)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.6)),
                     at: CGPoint(x: rect.minX, y: rect.maxY + 3),
                     anchor: UnitPoint(x: 0, y: 0))
        }
    }

    private func graphicColor(_ layer: String) -> Color {
        if layer.contains("CrtYd") { return .white.opacity(0.30) }
        if layer.contains("SilkS") { return Color(red: 0.95, green: 0.9, blue: 0.6) }
        if layer.contains("Fab") { return .gray.opacity(0.85) }
        if layer.contains("Mask") { return .purple.opacity(0.6) }
        if layer.contains("Paste") { return .white.opacity(0.55) }
        if layer.contains("Cu") { return .orange }
        if layer.contains("Edge") { return .yellow }
        return .white.opacity(0.6)
    }

    private func drawGraphic(_ ctx: inout GraphicsContext,
                             graphic: KiCadFootprintGraphic, origin: FPPoint) {
        let color = graphicColor(graphic.layer)
        let lineWidth = max(0.9, CGFloat(0.12) * scale)
        func map(_ p: FPPoint) -> CGPoint {
            boardToScreen(FPPoint(x: origin.x + p.x, y: origin.y + p.y))
        }
        switch graphic {
        case .line(let a, let b, _, _, _, _):
            var path = Path()
            path.move(to: map(a))
            path.addLine(to: map(b))
            ctx.stroke(path, with: .color(color), lineWidth: lineWidth)
        case .rect(let a, let b, _, _, _, let fill):
            let pa = map(a), pb = map(b)
            let rect = CGRect(x: min(pa.x, pb.x), y: min(pa.y, pb.y),
                              width: abs(pb.x - pa.x), height: abs(pb.y - pa.y))
            let path = Path(rect)
            if fill == "solid" { ctx.fill(path, with: .color(color.opacity(0.25))) }
            ctx.stroke(path, with: .color(color), lineWidth: lineWidth)
        case .circle(let center, let radius, _, _, _, let fill):
            let c = map(center)
            let r = CGFloat(radius * scale)
            let path = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            if fill == "solid" { ctx.fill(path, with: .color(color.opacity(0.25))) }
            ctx.stroke(path, with: .color(color), lineWidth: lineWidth)
        case .arc(let a, let m, let b, _, _, _, _):
            var path = Path()
            for (i, point) in BoardGeometry.arcSamplePoints(start: a, mid: m, end: b).enumerated() {
                if i == 0 { path.move(to: map(point)) } else { path.addLine(to: map(point)) }
            }
            ctx.stroke(path, with: .color(color), lineWidth: lineWidth)
        case .poly(let points, _, _, _, let fill):
            guard points.count >= 2 else { return }
            var path = Path()
            for (i, point) in points.enumerated() {
                if i == 0 { path.move(to: map(point)) } else { path.addLine(to: map(point)) }
            }
            path.closeSubpath()
            if fill == "solid" { ctx.fill(path, with: .color(color.opacity(0.25))) }
            ctx.stroke(path, with: .color(color), lineWidth: lineWidth)
        case .curve(let p1, let p2, let p3, let p4, _, _, _, _):
            var path = Path()
            path.move(to: map(p1))
            path.addCurve(to: map(p4), control1: map(p2), control2: map(p3))
            ctx.stroke(path, with: .color(color), lineWidth: lineWidth)
        case .text(let text):
            guard !text.hidden, !text.text.isEmpty else { return }
            let fontSize = max(7, CGFloat(text.size * scale))
            let anchorPoint = map(FPPoint(x: text.x, y: text.y))
            // Back-layer footprint text renders mirrored.
            if text.layer.hasPrefix("B.") {
                drawMirroredText(&ctx, text.text, size: fontSize, color: color,
                                 at: anchorPoint, anchor: .center,
                                 axisX: anchorPoint.x)
            } else {
                ctx.draw(Text(text.text)
                    .font(.system(size: fontSize))
                    .foregroundColor(color),
                         at: anchorPoint, anchor: .center)
            }
        }
    }

    /// Pad fill colour by layer/type — the same convention as the
    /// footprint browser's padColor (a copy lives here so this view
    /// stays self-contained). Called with the EFFECTIVE pad, so a
    /// flipped part's pads take their new side's colours.
    private func padColor(_ pad: KiCadFootprintPad) -> Color {
        if pad.type == .npThruHole { return .gray.opacity(0.8) }
        let hasFront = pad.layers.contains { $0.hasPrefix("F.") || $0 == "*.Cu" }
        let hasBack = pad.layers.contains { $0.hasPrefix("B.") || $0 == "*.Cu" }
        if pad.isThroughHole { return Color(red: 0.85, green: 0.55, blue: 0.2) }
        if hasFront && hasBack { return Color(red: 0.8, green: 0.4, blue: 0.7) }
        if hasBack && !hasFront { return Color(red: 0.3, green: 0.5, blue: 0.9) }
        return Color(red: 0.9, green: 0.45, blue: 0.25)
    }

    private func drawPad(_ ctx: inout GraphicsContext,
                         pad: KiCadFootprintPad, component: BoardComponent) {
        // The EFFECTIVE pad: for a flipped part this is the
        // mirrored pad (centre, rotation, layers, drill offset all
        // follow the side) — pin 1 still draws as pad 1.
        let effective = BoardGeometry.boardPad(component, pad)
        let centreBoard = BoardGeometry.padCenter(component, pad)
        let centre = boardToScreen(centreBoard)
        let w = CGFloat(effective.width * scale)
        let h = CGFloat(effective.height * scale)

        // Dimming: a net highlight dims every pad not on the net;
        // "Highlight layer" dims pads that don't touch the active
        // layer.
        var alpha = 1.0
        let net = BoardGeometry.netName(component, pad)
        if let highlightedNet, net != highlightedNet { alpha *= 0.3 }
        if highlightActiveLayer,
           !effective.layers.contains(activeLayer),
           !effective.layers.contains("*.Cu") {
            alpha *= 0.4
        }

        var pctx = ctx
        pctx.opacity = alpha
        pctx.translateBy(x: centre.x, y: centre.y)
        pctx.rotate(by: .degrees(effective.rotation))
        let rect = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
        let color = padColor(effective)
        switch effective.shape {
        case .circle, .oval:
            pctx.fill(Path(ellipseIn: rect), with: .color(color))
        case .roundrect:
            let ratio = CGFloat(effective.roundrectRatio ?? 0.25)
            let radius = min(w, h) / 2 * min(max(ratio, 0), 0.5) * 2
            pctx.fill(Path(roundedRect: rect, cornerRadius: radius), with: .color(color))
        case .trapezoid, .custom:
            // Approximation: the bounding rectangle (the browser draws
            // true trapezoid / custom primitives; the board only
            // needs the pad's extent, number and net).
            pctx.fill(Path(rect), with: .color(color.opacity(0.9)))
        case .rect:
            pctx.fill(Path(rect), with: .color(color))
        }
        if let drill = effective.drill {
            let dw = CGFloat(drill.width * scale)
            let dh = CGFloat(drill.height * scale)
            let drillRect = CGRect(x: CGFloat(drill.offsetX * scale) - dw / 2,
                                   y: CGFloat(drill.offsetY * scale) - dh / 2,
                                   width: dw, height: dh)
            pctx.fill(Path(ellipseIn: drillRect),
                      with: .color(Color(red: 0.043, green: 0.055, blue: 0.043)))
            pctx.stroke(Path(ellipseIn: drillRect), with: .color(.white.opacity(0.5)),
                        lineWidth: 1)
        }
        if !effective.number.isEmpty {
            let fontSize = max(7, min(w, h) * 0.55)
            if component.side == .back {
                // Pad numbers mirror with the part.
                pctx.scaleBy(x: -1, y: 1)
            }
            pctx.draw(Text(effective.number)
                .font(.system(size: fontSize, weight: .bold))
                .foregroundColor(.black.opacity(0.75)),
                      at: .zero, anchor: .center)
        }

        // Net name beside/under the pad (unrotated, in board space):
        // the correspondence this whole app exists to display.
        if !effective.number.isEmpty, let net {
            ctx.draw(Text(net)
                .font(.system(size: max(7, min(11, scale * 1.1)), weight: .semibold))
                .foregroundColor(Color(red: 0.55, green: 0.95, blue: 0.85)
                    .opacity(alpha)),
                     at: CGPoint(x: centre.x, y: centre.y + h / 2 + 2),
                     anchor: UnitPoint(x: 0.5, y: 0))
        }
    }
}

// MARK: - Apple Pencil hover bridge (part 5.0.1)

/// UIKit hover delivery for the PCB canvas.
///
/// Apple Pencil hover reaches apps through UIHoverGestureRecognizer
/// (Apple's input team built Pencil hover on the pointer APIs —
/// UIPointerInteraction / UIHoverGestureRecognizer; iPadOS 16.4+
/// extended the recognizer to report the pencil tip's location).
/// This view is the canvas's hover source:
///
/// - It exactly overlays the canvas and NEVER hit-tests
///   (`hitTest` -> nil), so every touch falls through to the
///   SwiftUI canvas and its drag/pinch gestures, untouched.
/// - It carries a UIHoverGestureRecognizer of its own, and —
///   because hover events are delivered to the recognizers of the
///   HIT view and its ANCESTORS, and a hit-test-transparent view
///   is never the hit view — it also lends recognizers to its
///   first ancestors (the container views it shares with the
///   canvas), which ARE in the delivery chain. Every recognizer
///   reports locations converted into THIS view's coordinates,
///   and positions outside this view's bounds are reported as
///   "hover ended", so stray events from hovering the panels
///   can't leak in. Duplicate reports from several recognizers
///   are identical values, applied idempotently.
/// - Callbacks deliver canvas-space points (or nil when the
///   hover ends); the editor converts to board coordinates and
///   feeds BoardPointerState — the same stream the touch path
///   feeds. No pencil / no hover hardware = no events, and the
///   editor behaves exactly as the plain touch editor.
private struct CanvasHoverView: UIViewRepresentable {
    var onHover: (CGPoint?) -> Void

    func makeUIView(context: Context) -> HoverView {
        let view = HoverView()
        view.onHover = onHover
        return view
    }

    func updateUIView(_ view: HoverView, context: Context) {
        view.onHover = onHover
    }

    static func dismantleUIView(_ view: HoverView, coordinator: ()) {
        view.detach()
    }

    final class HoverView: UIView {
        var onHover: ((CGPoint?) -> Void)?
        private var ownRecognizer: UIHoverGestureRecognizer?
        private var lentRecognizers: [ObjectIdentifier: UIHoverGestureRecognizer] = [:]
        private var hoverInside = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            let recognizer = UIHoverGestureRecognizer(
                target: self, action: #selector(handleHover(_:)))
            addGestureRecognizer(recognizer)
            ownRecognizer = recognizer
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        /// Transparent to touches: the canvas below receives
        /// every touch; this view exists for hover geometry only.
        override func hitTest(_ point: CGPoint,
                              with event: UIEvent?) -> UIView? { nil }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            lendRecognizersToAncestors()
        }

        /// Attach one hover recognizer to each of the first few
        /// ancestors (they are the canvas view's ancestors too, so
        /// they sit in the hover delivery chain). Idempotent.
        private func lendRecognizersToAncestors() {
            var ancestor = superview
            var depth = 0
            while let view = ancestor, depth < 3 {
                let key = ObjectIdentifier(view)
                if lentRecognizers[key] == nil {
                    let recognizer = UIHoverGestureRecognizer(
                        target: self, action: #selector(handleHover(_:)))
                    view.addGestureRecognizer(recognizer)
                    lentRecognizers[key] = recognizer
                }
                ancestor = view.superview
                depth += 1
            }
        }

        func detach() {
            let lent = lentRecognizers
            lentRecognizers = [:]
            for (_, recognizer) in lent {
                recognizer.view?.removeGestureRecognizer(recognizer)
            }
            onHover = nil
        }

        @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed:
                let location = recognizer.location(in: self)
                if bounds.contains(location) {
                    hoverInside = true
                    onHover?(location)
                } else if hoverInside {
                    hoverInside = false
                    onHover?(nil)
                }
            case .ended, .cancelled, .failed:
                hoverInside = false
                onHover?(nil)
            default:
                break
            }
        }
    }
}
