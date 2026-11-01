import SwiftUI

/// PCB editor (part 4) — a WORKING editor modelled on KiCad 10's PCB
/// editor (pcbnew): merged title/table bar on top, menu strip, icon
/// strip, tool rail on the left, board canvas in the centre,
/// Layers / Objects / Components panels on the right, KiCad-style
/// status bar along the bottom.
///
/// Everything visible does something real:
/// - The board is built from a saved connection table (the same
///   tables the schematic editor writes on every save) and "Sync
///   from Schematic" merges a re-read of that table into the board
///   (see PCBBoardState.swift for the merge rules).
/// - Select: tap selects components / traces / graphics; dragging a
///   component MOVES it (drag elsewhere pans). Delete removes the
///   selected item (a deleted footprint is excluded; a later Sync
///   restores it and says so).
/// - Route Tracks lays real, resizeable copper traces with KiCad's
///   45° bend rule; Draw Line / Arc / Circle and Text place real
///   board graphics; Highlight Net lights every pad and trace of a
///   net. Layer eyes, object toggles and the selection filter all
///   drive BoardVisibility / BoardSelectionFilter — the same
///   predicates the BoardFixture harness asserts.
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
            }
        }
    }

    /// What the canvas has selected — exactly one board item.
    enum BoardSelection: Equatable {
        case component(String)
        case trace(UUID)
        case graphic(UUID)
    }

    private enum DragMode {
        case undecided, pan, moveComponent
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
    @State private var movingReference: String? = nil
    @State private var moveStartOrigin: FPPoint? = nil
    @State private var movePreviewOrigin: FPPoint? = nil
    @State private var pinchStartScale: Double? = nil
    @State private var cursorBoard: FPPoint? = nil
    @State private var canvasSize: CGSize = .zero
    @State private var showGrid = true
    @State private var highlightActiveLayer = false

    // Editor state
    @State private var activeTool: PCBTool = .select
    @State private var activePanelTab = "Layers"
    @State private var visibility = BoardVisibility()
    @State private var selectionFilter = BoardSelectionFilter()
    @State private var selection: BoardSelection? = nil
    @State private var highlightedNet: String? = nil
    @State private var activeCopperLayer = "F.Cu"
    @State private var drawLayer = "Dwgs.User"

    // Routing state (Route Tracks tool)
    @State private var routePoints: [FPPoint] = []
    @State private var routeNet: String? = nil
    @State private var currentTrackWidth: Double = 0.25
    @AppStorage("padcb.defaultTrackWidth") private var defaultTrackWidth: Double = 0.25

    // Draw-tool state: taps collected toward a line / arc / circle
    @State private var pendingPoints: [FPPoint] = []
    // Text placement
    @State private var textAnchor: FPPoint? = nil
    @State private var textDraft = ""
    @State private var showTextPrompt = false
    // Board statistics alert
    @State private var showStats = false

    private static let gridSize = 2.54 // mm, KiCad's default course grid
    private static let snapMM = 0.127  // placement/routing snap (5 mil)

    private static let layerRows: [(name: String, color: Color)] = [
        ("F.Cu", Color(red: 0.85, green: 0.25, blue: 0.2)),
        ("In1.Cu", Color(red: 0.9, green: 0.6, blue: 0.2)),
        ("In2.Cu", Color(red: 0.6, green: 0.75, blue: 0.25)),
        ("B.Cu", Color(red: 0.25, green: 0.45, blue: 0.9)),
        ("F.Adhes", Color(red: 0.7, green: 0.3, blue: 0.7)),
        ("B.Adhes", Color(red: 0.45, green: 0.3, blue: 0.7)),
        ("F.Paste", Color(red: 0.6, green: 0.6, blue: 0.65)),
        ("B.Paste", Color(red: 0.5, green: 0.55, blue: 0.7)),
        ("F.SilkS", Color(red: 0.95, green: 0.9, blue: 0.6)),
        ("B.SilkS", Color(red: 0.6, green: 0.75, blue: 0.75)),
        ("F.Mask", Color(red: 0.55, green: 0.2, blue: 0.55)),
        ("B.Mask", Color(red: 0.25, green: 0.35, blue: 0.6)),
        ("Dwgs.User", Color(red: 0.65, green: 0.65, blue: 0.65)),
        ("Edge.Cuts", Color(red: 0.95, green: 0.85, blue: 0.2)),
        ("F.CrtYd", Color(red: 0.8, green: 0.8, blue: 0.8)),
        ("B.CrtYd", Color(red: 0.55, green: 0.55, blue: 0.55)),
        ("F.Fab", Color(red: 0.75, green: 0.75, blue: 0.7)),
        ("B.Fab", Color(red: 0.5, green: 0.55, blue: 0.55)),
    ]

    private static let drawingLayers = ["Dwgs.User", "Edge.Cuts",
                                        "F.SilkS", "B.SilkS", "F.Fab", "B.Fab"]

    private var selectedComponent: BoardComponent? {
        guard case .component(let reference)? = selection else { return nil }
        return model?.components.first { $0.reference == reference }
    }

    private var selectedTrace: BoardTrace? {
        guard case .trace(let id)? = selection else { return nil }
        return model?.traces.first { $0.id == id }
    }

    private var selectedGraphic: BoardGraphicItem? {
        guard case .graphic(let id)? = selection else { return nil }
        return model?.graphics.first { $0.id == id }
    }

    private var problemCount: Int {
        guard let model else { return 0 }
        return model.globalAnomalies.count + model.boardProblems.count
            + model.components.reduce(0) { $0 + $1.anomalies.count }
    }

    private var routingActive: Bool { !routePoints.isEmpty }

    var body: some View {
        ZStack {
            Color(white: 0.08).ignoresSafeArea()
            VStack(spacing: 0) {
                tableBar
                menuStrip
                iconStrip
                Divider()
                centre
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
            Text("The text is drawn on \(drawLayer) at the tapped point.")
        }
        .alert("Board Statistics", isPresented: $showStats) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(statsText)
        }
    }

    private var statsText: String {
        guard let model else { return "No board loaded." }
        let connected = model.traces.filter { $0.netName != nil }.count
        return """
        \(model.components.count) components · \(model.netCount) nets
        \(model.traces.count) traces (\(connected) connected)
        \(model.graphics.count) board graphics
        \(problemCount) problems
        Board state: Documents/Boards/\(tableStem).board.json
        """
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
                selection = result.merged.components.first
                    .map { BoardSelection.component($0.reference) }
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
            // Selection survives only if its item still exists.
            if let selection, !selectionExists(selection, in: built.merged) {
                self.selection = built.merged.components.first
                    .map { BoardSelection.component($0.reference) }
            }
            if let highlightedNet,
               !built.merged.netNames.contains(highlightedNet) {
                self.highlightedNet = nil
            }
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
        if let selection, !selectionExists(selection, in: merged.model) {
            self.selection = nil
        }
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
        textAnchor = nil
    }

    private func handleEscapeKey() {
        if routingActive {
            cancelInProgress()
            setStatus("Routing cancelled.")
        } else if !pendingPoints.isEmpty {
            pendingPoints = []
            setStatus("Drawing cancelled.")
        } else if highlightedNet != nil {
            highlightedNet = nil
            setStatus("Net highlight cleared.")
        } else {
            selection = nil
        }
    }

    // MARK: - Menu strip (every item performs a real action)

    private func setTool(_ tool: PCBTool) {
        if tool != .route, routingActive { cancelInProgress() }
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
                Button("Delete Selection") { deleteSelection() }
                    .disabled(selection == nil)
                Button("Clear Net Highlight") { highlightedNet = nil }
                    .disabled(highlightedNet == nil)
            }
            Menu("View") {
                Button("Zoom In") { zoomIn() }
                Button("Zoom Out") { zoomOut() }
                Button("Fit Board") { fitBoard() }
                Divider()
                Button(showGrid ? "✓ Grid" : "Grid") { showGrid.toggle() }
                Button(highlightActiveLayer
                       ? "✓ Highlight Active Layer" : "Highlight Active Layer") {
                    highlightActiveLayer.toggle()
                }
                Button("Show All Layers & Objects") {
                    visibility = BoardVisibility()
                }
            }
            Menu("Place") {
                ForEach([PCBTool.route, .drawLine, .drawArc, .drawCircle, .text],
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
                Menu("Draw Layer") {
                    ForEach(Self.drawingLayers, id: \.self) { layer in
                        Button(drawLayer == layer ? "✓ \(layer)" : layer) {
                            drawLayer = layer
                        }
                    }
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
            iconButton("square.stack.3d.up", "Highlight layer",
                       active: highlightActiveLayer) {
                highlightActiveLayer.toggle()
            }
            Divider().frame(height: 26)
            Menu {
                ForEach(Self.drawingLayers, id: \.self) { layer in
                    Button(drawLayer == layer ? "✓ \(layer)" : layer) {
                        drawLayer = layer
                    }
                }
            } label: {
                VStack(spacing: 1) {
                    Image(systemName: "pencil.and.ruler")
                        .font(.system(size: 16, weight: .medium))
                        .lineLimit(1)
                    Text(drawLayer)
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
    // clipped mid-word on Sean's iPad.
    private var toolRail: some View {
        VStack(spacing: 2) {
            ForEach(Array(PCBTool.allCases.enumerated()), id: \.offset) { index, tool in
                if index == 3 {
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
        .onChange(of: selection) { _, newValue in
            if case .trace(let id)? = newValue,
               let trace = model.traces.first(where: { $0.id == id }) {
                widthDraft = PCBBoardMerger.formatMM(trace.width)
            }
        }
    }

    private var layersPanel: some View {
        VStack(alignment: .leading, spacing: 2) {
            panelHeader("Layers")
            ForEach(Self.layerRows, id: \.name) { row in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(row.color)
                        .frame(width: 16, height: 16)
                    Text(row.name)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                    if BoardVisibility.copperLayers.contains(row.name),
                       activeCopperLayer == row.name {
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
                    // Tapping a copper layer's row makes it the
                    // active routing layer (KiCad's convention).
                    if BoardVisibility.copperLayers.contains(row.name) {
                        activeCopperLayer = row.name
                    }
                }
            }
            Text("Eyes hide/show layers on the canvas. Tap a copper layer to make it the active routing layer.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
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
            Text("These filter the canvas immediately. (No vias, zones or dimensions exist on this board yet — their switches are live for when they do.)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(4)
        }
    }

    private func componentsPanel(model: BoardModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            panelHeader("Components")
            ForEach(model.components, id: \.reference) { component in
                Button {
                    selection = .component(component.reference)
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
                    .background(selection == .component(component.reference)
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

    private func problemsPanel(model: BoardModel) -> some View {
        let lines: [String] = model.boardProblems
            + model.globalAnomalies
            + model.components.flatMap { component in
                component.anomalies.map { "\(component.reference): \($0)" }
            }
        return VStack(alignment: .leading, spacing: 4) {
            panelHeader("Problems")
            if lines.isEmpty {
                Text("No problems: every pin has a pad and every pad has a pin.")
                    .font(.callout)
                    .foregroundStyle(.green.opacity(0.9))
                    .lineLimit(3)
            } else {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .lineLimit(4)
                }
            }
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
        if let component = selectedComponent {
            componentDetail(component)
        } else if let trace = selectedTrace {
            traceDetail(trace)
        } else if let graphic = selectedGraphic {
            graphicDetail(graphic)
        } else if routingActive {
            routingDetail
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Tap a component, track or graphic to select it. With Select active, drag a component to move it; Route Tracks starts by tapping a pad.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
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
                Text(pinRowText(pin))
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.92))
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
            detailRow("Length", "\(fmt(trace.length)) mm")
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
            Text("\(routePoints.count) point(s) laid on \(activeCopperLayer). Tap waypoints (they bend at 45°), then tap the target pad — or Finish to end the track here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(4)
            Text("Track width (mm)")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .padding(.top, 4)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()),
                                GridItem(.flexible()), GridItem(.flexible())],
                      spacing: 6) {
                ForEach(BoardGeometry.trackWidthPresets, id: \.self) { width in
                    Button {
                        currentTrackWidth = width
                        defaultTrackWidth = width
                    } label: {
                        Text(PCBBoardMerger.formatMM(width))
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(abs(currentTrackWidth - width) < 0.001
                                        ? Color.accentColor.opacity(0.4)
                                        : Color.white.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
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

    /// "pin 1 — IN_A — net NET_A — pad 1 (1.60×1.60 mm, drill 0.80)"
    private func pinRowText(_ pin: BoardPinBinding) -> String {
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
        return text
    }

    private func fmt(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 14) {
            Text(cursorText)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text("Grid \(fmt(Self.gridSize)) mm")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text("Zoom \(BoardCanvasMetrics.percent(forScale: scale))%")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Menu {
                ForEach(BoardVisibility.copperLayers, id: \.self) { layer in
                    Button(activeCopperLayer == layer ? "✓ \(layer)" : layer) {
                        activeCopperLayer = layer
                    }
                }
            } label: {
                Text(activeCopperLayer)
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
        guard let cursorBoard else { return "X —  Y —" }
        return "X \(fmt(cursorBoard.x)) mm  Y \(fmt(cursorBoard.y)) mm"
    }

    private var boardInfoText: String {
        guard let model else { return "No board loaded" }
        return "\(model.components.count) components · \(model.netCount) nets · "
            + "\(model.traces.count) tracks · \(problemCount) problems · \(model.tableTitle)"
    }

    // MARK: - Canvas transforms (board mm, y DOWN -> screen points)

    /// Draft text for the trace-width field (synced on selection).
    @State private var widthDraft = ""

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
            .onAppear { canvasSize = geo.size }
            .onChange(of: geo.size) { _, newSize in canvasSize = newSize }
        }
    }

    /// One drag gesture, tool-dependent: with Select, a drag that
    /// starts on a component moves it (live preview, committed on
    /// release); any other drag pans. A press that barely moves is
    /// a tap and goes to the active tool.
    private var canvasDrag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                cursorBoard = screenToBoard(value.location)
                if dragMode == .undecided {
                    dragStartOffset = offset
                    let startBoard = screenToBoard(value.startLocation)
                    if activeTool == .select, let model,
                       visibility.showFootprints, selectionFilter.allows(.component),
                       let component = BoardGeometry.componentAt(model, point: startBoard) {
                        dragMode = .moveComponent
                        movingReference = component.reference
                        moveStartOrigin = component.origin
                        movePreviewOrigin = component.origin
                        selection = .component(component.reference)
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
                case .moveComponent:
                    if let start = moveStartOrigin {
                        let moved = FPPoint(
                            x: start.x + Double(value.translation.width) / scale,
                            y: start.y + Double(value.translation.height) / scale)
                        movePreviewOrigin = BoardGeometry.snapped(moved, grid: Self.snapMM)
                    }
                case .undecided:
                    break
                }
            }
            .onEnded { value in
                cursorBoard = screenToBoard(value.location)
                let moved = hypot(value.translation.width, value.translation.height)
                if moved < 5 {
                    // A tap: undo the micro-pan; a tap that started a
                    // move already selected the component.
                    if dragMode == .pan, let start = dragStartOffset {
                        offset = start
                    }
                    if dragMode != .moveComponent {
                        handleTap(at: screenToBoard(value.location))
                    }
                } else if dragMode == .moveComponent,
                          let reference = movingReference,
                          let origin = movePreviewOrigin,
                          let start = moveStartOrigin, origin != start {
                    mutateBoard { state in
                        state.placements[reference] = origin
                    }
                    setStatus("\(reference) moved — its position is saved with the board.")
                }
                dragMode = .undecided
                dragStartOffset = nil
                movingReference = nil
                moveStartOrigin = nil
                movePreviewOrigin = nil
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
        case .drawLine, .drawArc, .drawCircle:
            handleDrawTap(point: point)
        case .text:
            textAnchor = BoardGeometry.snapped(point, grid: Self.snapMM)
            textDraft = ""
            showTextPrompt = true
        }
    }

    private func handleSelectTap(model: BoardModel, point: FPPoint) {
        let tolerance = tapToleranceMM
        if selectionFilter.allows(.trace),
           let trace = model.traces.reversed().first(where: {
               visibility.traceShown($0)
                   && BoardGeometry.traceHit($0, point: point, tolerance: tolerance)
           }) {
            selection = .trace(trace.id)
            return
        }
        if let graphic = model.graphics.reversed().first(where: {
            visibility.boardGraphicShown($0)
                && selectionFilter.allows($0.kind == .text ? .text : .graphic)
                && BoardGeometry.graphicHit($0, point: point, tolerance: tolerance)
        }) {
            selection = .graphic(graphic.id)
            return
        }
        if visibility.showFootprints, selectionFilter.allows(.component),
           let component = BoardGeometry.componentAt(model, point: point) {
            selection = .component(component.reference)
            return
        }
        selection = nil
    }

    private func handleHighlightTap(model: BoardModel, point: FPPoint) {
        guard visibility.showFootprints, visibility.showPads,
              let hit = BoardGeometry.padAt(model, point: point,
                                            tolerance: tapToleranceMM),
              visibility.padShown(hit.pad) else {
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
        if let trace = model.traces.reversed().first(where: {
            visibility.traceShown($0)
                && BoardGeometry.traceHit($0, point: point, tolerance: tolerance)
        }) {
            selection = .trace(trace.id)
            deleteSelection()
            return
        }
        if let graphic = model.graphics.reversed().first(where: {
            visibility.boardGraphicShown($0)
                && BoardGeometry.graphicHit($0, point: point, tolerance: tolerance)
        }) {
            selection = .graphic(graphic.id)
            deleteSelection()
            return
        }
        if visibility.showFootprints,
           let component = BoardGeometry.componentAt(model, point: point) {
            selection = .component(component.reference)
            deleteSelection()
        }
    }

    private func deleteSelection() {
        guard let selection else { return }
        switch selection {
        case .component(let reference):
            self.selection = nil
            mutateBoard { state in
                if !state.excludedReferences.contains(reference) {
                    state.excludedReferences.append(reference)
                }
            }
            setStatus("\(reference) removed from the board. Sync from Schematic brings it back.")
        case .trace(let id):
            self.selection = nil
            mutateBoard { state in
                state.traces.removeAll { $0.id == id }
            }
            setStatus("Track deleted.")
        case .graphic(let id):
            self.selection = nil
            mutateBoard { state in
                state.graphics.removeAll { $0.id == id }
            }
            setStatus("Graphic deleted.")
        }
    }

    // MARK: - Routing (Route Tracks)

    private func handleRouteTap(model: BoardModel, point: FPPoint) {
        let padHit = BoardGeometry.padAt(model, point: point,
                                          tolerance: tapToleranceMM)
        if !routingActive {
            guard let padHit else {
                setStatus("Tap a pad to start the track.", warning: true)
                return
            }
            routeNet = padHit.netName
            routePoints = [BoardGeometry.padCenter(padHit.component, padHit.pad)]
            if let net = padHit.netName {
                setStatus("Routing \(net) from \(padHit.component.reference) pad "
                          + "\(padHit.pad.number) on \(activeCopperLayer) — tap "
                          + "waypoints, then the target pad.")
            } else {
                setStatus("Routing an unconnected track from \(padHit.component.reference) "
                          + "pad \(padHit.pad.number) — tap waypoints, then a pad or Finish.")
            }
            return
        }
        if let padHit {
            if let routing = routeNet, let padNet = padHit.netName, routing != padNet {
                setStatus("That's net \(padNet) — this track is \(routing) and "
                          + "can't join a different net.", warning: true)
                return
            }
            if routeNet == nil { routeNet = padHit.netName }
            appendRoutePoint(BoardGeometry.padCenter(padHit.component, padHit.pad))
            finishRoute()
        } else {
            appendRoutePoint(BoardGeometry.snapped(point, grid: Self.snapMM))
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
                               layer: activeCopperLayer,
                               width: currentTrackWidth, points: cleaned)
        mutateBoard { state in state.traces.append(trace) }
        selection = .trace(trace.id)
        cancelInProgress()
        setStatus("Track added on \(trace.layer) — \(trace.netName ?? "unconnected"), "
                  + "\(PCBBoardMerger.formatMM(trace.width)) mm wide. "
                  + "Select it any time to change its width.")
    }

    // MARK: - Drawing tools (line / arc / circle / text)

    private func handleDrawTap(point: FPPoint) {
        pendingPoints.append(BoardGeometry.snapped(point, grid: Self.snapMM))
        switch activeTool {
        case .drawLine where pendingPoints.count == 2:
            createGraphic(BoardGraphicItem(id: UUID(), kind: .line,
                                           layer: drawLayer, points: pendingPoints))
        case .drawCircle where pendingPoints.count == 2:
            let radius = pendingPoints[0].distance(to: pendingPoints[1])
            if radius > 0.05 {
                createGraphic(BoardGraphicItem(id: UUID(), kind: .circle,
                                               layer: drawLayer,
                                               points: [pendingPoints[0]],
                                               radius: radius))
            } else {
                pendingPoints = []
                setStatus("Circle too small — tap its centre, then a point on its edge.",
                          warning: true)
            }
        case .drawArc where pendingPoints.count == 3:
            createGraphic(BoardGraphicItem(id: UUID(), kind: .arc,
                                           layer: drawLayer, points: pendingPoints))
        default:
            break
        }
    }

    private func createGraphic(_ item: BoardGraphicItem) {
        mutateBoard { state in state.graphics.append(item) }
        selection = .graphic(item.id)
        pendingPoints = []
        setStatus("\(item.kind.rawValue.capitalized) drawn on \(item.layer).")
    }

    private func placeText() {
        let text = textDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let anchor = textAnchor, !text.isEmpty else {
            textAnchor = nil
            return
        }
        createGraphic(BoardGraphicItem(id: UUID(), kind: .text, layer: drawLayer,
                                       points: [anchor], text: text, textSize: 1.5))
        textAnchor = nil
    }

    // MARK: - Board drawing

    private func displayOrigin(_ component: BoardComponent) -> FPPoint {
        if movingReference == component.reference, let preview = movePreviewOrigin {
            return preview
        }
        return component.origin
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
        // Copper.
        for trace in model.traces where visibility.traceShown(trace) {
            drawTrace(&ctx, trace: trace)
        }
        // Components (their own graphics + pads, visibility-filtered).
        for component in model.components {
            drawComponent(&ctx, component: component,
                          selected: selection == .component(component.reference))
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
        drawPreviews(&ctx)
    }

    private func drawGridDots(_ ctx: inout GraphicsContext, size: CGSize) {
        var step = Self.gridSize
        while step * scale < 9 { step *= 2 }
        // Deep zoom (part 4): subdivide so the grid stays useful all
        // the way to 6000 % instead of dots 380 pt apart.
        while step * scale > 90, step > 0.16 { step /= 2 }
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
        Self.layerRows.first { $0.name == layer }?.color
            ?? Color(red: 0.85, green: 0.3, blue: 0.25)
    }

    private func drawTrace(_ ctx: inout GraphicsContext, trace: BoardTrace) {
        guard trace.points.count > 1 else { return }
        var path = Path()
        for (index, point) in trace.points.enumerated() {
            let screen = boardToScreen(point)
            if index == 0 { path.move(to: screen) } else { path.addLine(to: screen) }
        }
        let width = max(1.2, CGFloat(trace.width * scale))
        let style = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)

        if selection == .trace(trace.id) {
            ctx.stroke(path, with: .color(.white.opacity(0.85)),
                       style: StrokeStyle(lineWidth: width + 3, lineCap: .round,
                                          lineJoin: .round))
        }
        var color = copperColor(trace.layer)
        var alpha = 1.0
        if trace.netName == nil {
            color = trace.disconnectedNetName != nil
                ? Color(white: 0.55) : copperColor(trace.layer)
            alpha = 0.75
        }
        if trace.layer != activeCopperLayer { alpha *= 0.55 }
        if let highlightedNet {
            alpha *= (trace.netName == highlightedNet) ? 1.0 : 0.18
        }
        var strokeStyle = style
        if trace.disconnectedNetName != nil {
            strokeStyle.dash = [8, 5]
        }
        ctx.opacity = alpha
        ctx.stroke(path, with: .color(color), style: strokeStyle)
        ctx.opacity = 1
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
            ctx.draw(Text(item.text)
                .font(.system(size: max(7, CGFloat(item.textSize * scale))))
                .foregroundColor(color),
                     at: boardToScreen(anchor), anchor: .center)
        }
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

    private func drawPreviews(_ ctx: inout GraphicsContext) {
        // Routing: laid points + the 45° preview to the cursor.
        if routingActive {
            var points = routePoints
            if let cursor = cursorBoard, let last = points.last {
                if let corner = BoardGeometry.routeCorner(from: last, to: cursor) {
                    points.append(corner)
                }
                points.append(cursor)
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
        }
        // Draw tools: the shape so far, to the cursor.
        if !pendingPoints.isEmpty, let cursor = cursorBoard {
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

        // Footprint graphics, layer/object-filtered (the Layers eyes
        // and Objects toggles drive BoardVisibility — the same
        // predicates BoardFixture asserts).
        for graphic in footprint.graphics
        where visibility.footprintGraphicShown(graphic) {
            drawGraphic(&ctx, graphic: graphic, origin: component.origin)
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
        for pad in footprint.pads where visibility.padShown(pad) {
            drawPad(&ctx, pad: pad, component: component)
        }
        if visibility.showText,
           visibility.layerShown("F.SilkS") || visibility.layerShown("F.Fab") {
            drawReferenceLabel(&ctx, component: component, rect: rect)
        }
    }

    private func drawReferenceLabel(_ ctx: inout GraphicsContext,
                                    component: BoardComponent, rect: CGRect) {
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
            ctx.draw(Text(text.text)
                .font(.system(size: fontSize))
                .foregroundColor(color),
                     at: map(FPPoint(x: text.x, y: text.y)), anchor: .center)
        }
    }

    /// Pad fill colour by layer/type — the same convention as the
    /// footprint browser's padColor (a copy lives here so this view
    /// stays self-contained).
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
        let centreBoard = BoardGeometry.padCenter(component, pad)
        let centre = boardToScreen(centreBoard)
        let w = CGFloat(pad.width * scale)
        let h = CGFloat(pad.height * scale)

        // Dimming: a net highlight dims every pad not on the net;
        // "Highlight layer" dims pads that don't touch the active
        // copper layer.
        var alpha = 1.0
        let net = BoardGeometry.netName(component, pad)
        if let highlightedNet, net != highlightedNet { alpha *= 0.3 }
        if highlightActiveLayer,
           !pad.layers.contains(activeCopperLayer),
           !pad.layers.contains("*.Cu") {
            alpha *= 0.4
        }

        var pctx = ctx
        pctx.opacity = alpha
        pctx.translateBy(x: centre.x, y: centre.y)
        pctx.rotate(by: .degrees(pad.rotation))
        let rect = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
        let color = padColor(pad)
        switch pad.shape {
        case .circle, .oval:
            pctx.fill(Path(ellipseIn: rect), with: .color(color))
        case .roundrect:
            let ratio = CGFloat(pad.roundrectRatio ?? 0.25)
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
        if let drill = pad.drill {
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
        if !pad.number.isEmpty {
            let fontSize = max(7, min(w, h) * 0.55)
            pctx.draw(Text(pad.number)
                .font(.system(size: fontSize, weight: .bold))
                .foregroundColor(.black.opacity(0.75)),
                      at: .zero, anchor: .center)
        }

        // Net name beside/under the pad (unrotated, in board space):
        // the correspondence this whole app exists to display.
        if !pad.number.isEmpty, let net {
            ctx.draw(Text(net)
                .font(.system(size: max(7, min(11, scale * 1.1)), weight: .semibold))
                .foregroundColor(Color(red: 0.55, green: 0.95, blue: 0.85)
                    .opacity(alpha)),
                     at: CGPoint(x: centre.x, y: centre.y + h / 2 + 2),
                     anchor: UnitPoint(x: 0.5, y: 0))
        }
    }
}
