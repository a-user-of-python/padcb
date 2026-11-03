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
/// - Traces edit KiCad-style, segment by segment (part 5.1): a
///   tap selects the ONE segment under it, the selected track's
///   corners show as handles — drag a corner to bend the track,
///   drag a segment to move it (neighbours stretch), double-tap
///   adds a corner, and deleting a segment splits the track at
///   the gap (the checks flag the break, like KiCad).
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
/// The pointer stream's owner (part 5.2): the single
/// BoardPointerState + the per-channel diagnostics + the
/// coalescing throttle, behind an ObservableObject so hover
/// events invalidate ONLY the views that observe it (the canvas
/// host and the status-bar readout) instead of the whole editor
/// body. Diagnostics counts EVERY delivered event (the counters
/// stay an honest delivery record); the STATE applies the
/// throttled stream (at most one point per display interval,
/// latest wins) — KiCad's effect (cheap queries per motion
/// event) matched at PadCB's scale.
final class BoardPointerModel: ObservableObject {
    @Published private(set) var state = BoardPointerState()
    @Published private(set) var diagnostics = BoardHoverDiagnostics()
    private var throttle = BoardPointerThrottle()
    private var pendingChannel: BoardHoverChannel = .interaction

    func feedHoverMoved(_ point: FPPoint, channel: BoardHoverChannel) {
        diagnostics.record(channel, point: point)
        pendingChannel = channel
        if let admitted = throttle.offer(
            point, at: ProcessInfo.processInfo.systemUptime) {
            state.applyHoverMoved(admitted, channel: channel)
        }
    }

    func feedHoverEnded(channel: BoardHoverChannel) {
        diagnostics.record(channel, point: nil)
        throttle.end()
        state.applyHoverEnded(channel: channel)
    }

    /// Release a coalesced point whose window has elapsed (the
    /// canvas host calls this on a 60 Hz timer).
    func flushPending() {
        if let point = throttle.flush(
            at: ProcessInfo.processInfo.systemUptime) {
            state.applyHoverMoved(point, channel: pendingChannel)
        }
    }

    func feedTouchMoved(_ point: FPPoint) {
        state.apply(.touchMoved(point))
    }

    func feedTouchEnded() {
        state.apply(.touchEnded)
    }
}

/// Hosts the board canvas stack (part 5.2): observes the
/// pointer model so POINTER changes re-evaluate this small
/// subtree — and nothing else in the editor. The content
/// closure is rebuilt whenever the editor itself re-evaluates
/// (fresh inputs); between those passes the captured editor
/// value still reads live @State storage, so draws and
/// gestures always see current values.
private struct BoardCanvasHost<Content: View>: View {
    @ObservedObject var pointer: BoardPointerModel
    var onFlush: () -> Void = {}
    @ViewBuilder var content: (BoardPointerState) -> Content
    @State private var flushTimer = Timer.publish(
        every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        content(pointer.state)
            .onReceive(flushTimer) { _ in
                pointer.flushPending()
                onFlush()
            }
    }
}

/// Everything the STATIC board layer draws from, as one
/// Equatable token (part 5.2): the layer re-renders only when
/// the token changes. Pointer state is deliberately absent —
/// pointer-driven drawing lives on the preview layer above it.
private struct StaticBoardToken: Equatable {
    var renderVersion: Int
    var boardState: BoardState
    var visibility: BoardVisibility
    var selections: Set<PCBEditorView.BoardSelection>
    var primarySelection: PCBEditorView.BoardSelection?
    var highlightedNet: String?
    var activeLayer: String
    var showGrid: Bool
    var scale: Double
    var offset: CGPoint
    var movePreviewOrigins: [String: FPPoint]
    var moveViaPreview: FPPoint?
    var editDragTraceID: UUID?
    var editDragPreviewPoints: [FPPoint]?
    var ratsnestCount: Int
    /// Inactive-layer appearance mode (part 5.3, P9), raw value.
    /// BoardState itself is in the token, so teardrops (part 5.3)
    /// already invalidate the static layer through boardState +
    /// renderVersion — this field covers the mode switch itself.
    var inactiveLayerModeRaw: String
}

/// The static board layer (part 5.2, KiCad's VIEW/GAL layer
/// separation): a Canvas whose redraw is gated by token
/// equality, so Pencil hover — which changes none of these
/// inputs — never re-renders the board beneath the preview.
private struct StaticBoardLayer: View, Equatable {
    let token: StaticBoardToken
    let draw: (inout GraphicsContext, CGSize) -> Void

    static func == (lhs: StaticBoardLayer, rhs: StaticBoardLayer) -> Bool {
        lhs.token == rhs.token
    }

    var body: some View {
        Canvas { ctx, size in
            var c = ctx
            draw(&c, size)
        }
    }
}

/// The status bar's pointer readout (part 5.2): the ONLY
/// status-bar content that observes the pointer model, so the
/// cursor position and the hover diagnostics update without
/// re-evaluating the editor.
private struct BoardPointerReadoutView: View {
    @ObservedObject var pointer: BoardPointerModel

    var body: some View {
        HStack(spacing: 14) {
            Text(cursorText)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            // Hover delivery diagnostics (parts 5.0.2–5.0.3):
            // per-channel event counts + last hover point, live.
            // Deliberate debug UI — a follow-up strips it once
            // delivery is proven on Sean's hardware.
            Text(pointer.diagnostics.summary)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var cursorText: String {
        guard let point = pointer.state.currentPoint
        else { return "X —  Y —" }
        return "X \(String(format: "%.2f", point.x)) mm"
            + "  Y \(String(format: "%.2f", point.y)) mm"
    }
}

struct PCBEditorView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var footprintStore: FootprintStore
    @EnvironmentObject private var crossProbe: CrossProbe
    @EnvironmentObject private var liveSession: LiveSessionRegistry
    @Environment(\.dismiss) private var dismiss

    /// Cross-editor navigation (part 5.3): HomeView passes a
    /// closure that pushes the named editor ("schematic") so
    /// "Show in Schematic" can cross-probe. Defaults to a no-op
    /// for the exercise root, which has no sibling editor.
    var navigate: (String) -> Void = { _ in }

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
        case measure = "Measure"

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
            case .measure: return "ruler"
            }
        }
    }

    /// What the canvas has selected — one board item. The editor
    /// keeps a SET of these (multi-select, part 5) plus a primary
    /// (the most recently tapped) whose detail the panel shows.
    enum BoardSelection: Equatable, Hashable {
        case component(String)
        case trace(UUID)
        /// One segment of a trace (part 5.1): segment index runs
        /// points[index] → points[index + 1].
        case segment(UUID, Int)
        /// One vertex (corner) of a trace (part 5.1).
        case vertex(UUID, Int)
        case graphic(UUID)
        case via(UUID)
        case zone(UUID)
    }

    private enum DragMode {
        case undecided, pan, moveComponents, moveVia, moveVertex, moveSegment
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
    /// Trace segment editing drags (part 5.1): the trace being
    /// reshaped, the vertex/segment index grabbed, the points at
    /// drag start, and the live preview points (committed through
    /// mutateBoard on release = one undo step, like every move).
    @State private var editDragTraceID: UUID? = nil
    @State private var editDragIndex: Int = 0
    @State private var editDragStartPoints: [FPPoint] = []
    @State private var editDragPreviewPoints: [FPPoint]? = nil
    /// Double-tap disambiguation (part 5.1): when a segment tap
    /// FRESHLY selects a trace that was not being edited (primary
    /// was not that trace's segment/vertex/whole), the tap is
    /// remembered; a double-tap landing on that same segment
    /// within the window selects the WHOLE trace (Sean's item 1),
    /// while a double-tap on a trace already being edited inserts
    /// a vertex there (item 4). Both of Sean's sentences hold —
    /// they just can't both own a double-tap on an untouched
    /// trace, so the first double-tap opens the trace up and
    /// later ones add corners.
    @State private var freshSegmentTap: (traceID: UUID, index: Int, time: Date)? = nil
    /// When handleDoubleTap last promoted a trace to whole-track
    /// selection: the double-tap's second press may reach the tap
    /// path AFTER the promotion (gesture delivery order between
    /// the drag gesture and the tap gesture is not guaranteed),
    /// and that late tap must not narrow the selection straight
    /// back to a segment.
    @State private var wholeTracePromotion: (traceID: UUID, time: Date)? = nil
    /// In Multi mode, the component a press started on: if the
    /// press ends as a tap, it toggles; if it becomes a drag, the
    /// selected group moves. (Decided at drag end — see canvasDrag.)
    @State private var dragTapReference: String? = nil
    @State private var pinchStartScale: Double? = nil
    /// The canvas's ONE pointer stream (part 5.0.1), owned by an
    /// observable model since part 5.2: hover (UIKit recognizer)
    /// and touch (drag gesture) both feed `BoardPointerState`;
    /// previews follow its `currentPoint` — the touch point
    /// while a touch is down, else the hover point. (v5.0 kept
    /// two optionals and preferred the touch one forever once
    /// set, which froze the hover preview at the first tap —
    /// see PCBBoardState.swift.) The model also owns the
    /// per-channel delivery diagnostics (parts 5.0.2–5.0.3) and
    /// the coalescing throttle (part 5.2): as an ObservableObject
    /// it publishes ONLY to the canvas host and the status-bar
    /// readout, so a hover event no longer re-evaluates the
    /// whole editor body — the v5.1 "ui shakes back and forth"
    /// judder (Sean, 2026-11-02 08:44).
    @StateObject private var pointerModel = BoardPointerModel()
    /// The stateful route head (part 5.2): carries the preview's
    /// endpoint / anchor / corner across hover events with
    /// hysteresis, KiCad-placer style. Resolved on pointer
    /// EVENTS (never during drawing) into `routePreviewCache`.
    @State private var routeHead = BoardRouteHead()
    @State private var routePreviewCache: BoardRoutePreview? = nil
    /// Spatial index over the merged model (part 5.2), rebuilt
    /// wherever the checks are recomputed — never per event.
    @State private var spatialIndex: BoardSpatialIndex? = nil
    /// Ratsnest segments for the current model (part 5.2),
    /// recomputed with the checks.
    @State private var ratsnestSegments: [RatsnestSegment] = []
    /// Static-canvas invalidation counter (part 5.2): bumped by
    /// refreshChecks, i.e. on every model/checks change, so the
    /// equatable static layer redraws exactly then.
    @State private var boardRenderVersion = 0
    /// The measuring tool's two points (part 5.2).
    @State private var measure = BoardMeasure()
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

    // -- Part 5.3 state --
    /// Inactive-layer appearance (P9): how items NOT on the active
    /// layer draw. View state only, like the highlight toggle it
    /// generalises.
    enum InactiveLayerMode: String, CaseIterable {
        case normal = "Normal"
        case dim = "Dim"
        case hide = "Hide"
    }
    @State private var inactiveLayerMode: InactiveLayerMode = .normal
    // Move Exactly (P1) sheet drafts.
    @State private var showMoveExactly = false
    @State private var moveDeltaXDraft = "0"
    @State private var moveDeltaYDraft = "0"
    @State private var movePolar = false
    @State private var moveDistanceDraft = "0"
    @State private var moveAngleDraft = "0"
    @State private var moveRotationDraft = "0"
    // Cleanup sheets (P4/P5): option toggles mirror
    // BoardCleanupOptions' defaults (all on).
    @State private var showCleanupTracks = false
    @State private var cleanupDangling = true
    @State private var cleanupNullSegments = true
    @State private var cleanupMergeCollinear = true
    @State private var cleanupDuplicateVias = true
    @State private var cleanupDisconnected = true
    @State private var showCleanupGraphics = false
    // Global Deletions (P13) sheet: every class starts OFF.
    @State private var showGlobalDelete = false
    @State private var globalDeleteTracks = false
    @State private var globalDeleteVias = false
    @State private var globalDeleteZones = false
    @State private var globalDeleteGraphics = false
    @State private var globalDeleteTeardrops = false
    @State private var globalDeleteIncludeLocked = false
    // Swap Layers (P15) confirmation.
    @State private var showSwapLayersConfirm = false
    // Clipboard (P11): the in-app slice + the armed paste tap.
    @State private var clipboardSlice: BoardClipboardSlice? = nil
    @State private var pasteArmed = false
    // PCB Find (P12) sheet.
    @State private var showFind = false
    @State private var findQuery = ""
    // Select Unconnected (P3): the "Next" stepper position.
    @State private var nextUnconnectedIndex = 0
    // Netclasses (P16) sheet drafts.
    @State private var showNetClasses = false
    @State private var netClassNameDraft = ""
    @State private var netClassWidthDraft = "0.25"
    @State private var netClassClearanceDraft = "0.2"
    @State private var netClassEditingName: String? = nil

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

    /// The primary selection as ONE segment of a trace (part 5.1),
    /// resolved against the live model (nil when the trace or the
    /// segment index no longer exists).
    private var selectedSegment: (trace: BoardTrace, index: Int)? {
        guard case .segment(let id, let index)? = primarySelection,
              let trace = model?.traces.first(where: { $0.id == id }),
              index >= 0, index < trace.segmentCount else { return nil }
        return (trace, index)
    }

    /// The primary selection as ONE vertex of a trace (part 5.1).
    private var selectedVertex: (trace: BoardTrace, index: Int)? {
        guard case .vertex(let id, let index)? = primarySelection,
              let trace = model?.traces.first(where: { $0.id == id }),
              trace.points.indices.contains(index) else { return nil }
        return (trace, index)
    }

    /// The trace being segment-edited, if any: the primary
    /// selection is that trace whole, one of its segments, or one
    /// of its vertices. Its vertices show as handles and its
    /// segments/vertices are draggable.
    private var editTraceID: UUID? {
        switch primarySelection {
        case .trace(let id): return id
        case .segment(let id, _): return id
        case .vertex(let id, _): return id
        default: return nil
        }
    }

    private var editTrace: BoardTrace? {
        guard let id = editTraceID else { return nil }
        return model?.traces.first { $0.id == id }
    }

    /// The selected segments across the whole selection set
    /// (multi-select, part 5.1), resolved against the live model.
    private var selectedSegments: [(trace: BoardTrace, index: Int)] {
        guard let model else { return [] }
        return selections.compactMap { item in
            guard case .segment(let id, let index) = item,
                  let trace = model.traces.first(where: { $0.id == id }),
                  index >= 0, index < trace.segmentCount
            else { return nil }
            return (trace, index)
        }
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
        freshSegmentTap = nil
    }

    /// The selection as the model transforms' id set (part 5.3):
    /// traces / vias / zones / graphics / teardrops by id
    /// uuidString (a segment or vertex stands for its whole
    /// trace), footprints by reference — exactly the identity
    /// BoardTransforms / BoardClipboard key on.
    private var selectionItemIDs: Set<String> {
        var ids = Set<String>()
        for item in selections {
            switch item {
            case .component(let reference):
                ids.insert(reference)
            case .trace(let id), .segment(let id, _), .vertex(let id, _):
                ids.insert(id.uuidString)
            case .graphic(let id), .via(let id), .zone(let id):
                ids.insert(id.uuidString)
            }
        }
        return ids
    }

    /// Every geometry point of the current selection, resolved
    /// against the live model: footprint bounds corners (plus,
    /// when `includePads`, every pad outline of selected
    /// footprints — Zoom to Selection's contract), trace points
    /// (a segment contributes its two ends, a vertex itself),
    /// via discs, zone and graphic points.
    private func selectionGeometryPoints(includePads: Bool) -> [FPPoint] {
        guard let model else { return [] }
        var points: [FPPoint] = []
        for item in selections {
            switch item {
            case .component(let reference):
                guard let component = model.components.first(
                    where: { $0.reference == reference }) else { continue }
                let b = BoardGeometry.componentBounds(component)
                points.append(FPPoint(x: b.minX, y: b.minY))
                points.append(FPPoint(x: b.maxX, y: b.maxY))
                if includePads, let footprint = component.footprint {
                    for pad in footprint.pads {
                        points += BoardGeometry.padOutline(component, pad)
                    }
                }
            case .trace(let id):
                if let trace = model.traces.first(where: { $0.id == id }) {
                    points += trace.points
                }
            case .segment(let id, let index):
                if let trace = model.traces.first(where: { $0.id == id }),
                   trace.points.indices.contains(index),
                   trace.points.indices.contains(index + 1) {
                    points.append(trace.points[index])
                    points.append(trace.points[index + 1])
                }
            case .vertex(let id, let index):
                if let trace = model.traces.first(where: { $0.id == id }),
                   trace.points.indices.contains(index) {
                    points.append(trace.points[index])
                }
            case .via(let id):
                if let via = model.vias.first(where: { $0.id == id }) {
                    points.append(FPPoint(x: via.center.x - via.diameter / 2,
                                          y: via.center.y - via.diameter / 2))
                    points.append(FPPoint(x: via.center.x + via.diameter / 2,
                                          y: via.center.y + via.diameter / 2))
                }
            case .zone(let id):
                if let zone = model.zones.first(where: { $0.id == id }) {
                    points += zone.points
                }
            case .graphic(let id):
                if let item = model.graphics.first(where: { $0.id == id }) {
                    points += item.points
                    if item.kind == .circle, let centre = item.points.first {
                        points.append(FPPoint(x: centre.x - item.radius,
                                              y: centre.y - item.radius))
                        points.append(FPPoint(x: centre.x + item.radius,
                                              y: centre.y + item.radius))
                    }
                }
            }
        }
        return points
    }

    /// The centre of the selection's bounds (Move Exactly's
    /// rotation centre, part 5.3 P1), from item geometry.
    private var selectionBoundsCentre: FPPoint? {
        let points = selectionGeometryPoints(includePads: false)
        guard let first = points.first else { return nil }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for point in points {
            minX = min(minX, point.x); minY = min(minY, point.y)
            maxX = max(maxX, point.x); maxY = max(maxY, point.y)
        }
        return FPPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
    }

    /// The net Select All Tracks in Net (P2) works on: the net of
    /// the primary selected trace/via, else of any selected
    /// trace/via, else the highlighted net, else nil (disabled).
    private var netSelectionContext: String? {
        guard let model else { return highlightedNet }
        func net(of item: BoardSelection) -> String? {
            switch item {
            case .trace(let id), .segment(let id, _), .vertex(let id, _):
                return model.traces.first { $0.id == id }?.netName
            case .via(let id):
                return model.vias.first { $0.id == id }?.netName
            default:
                return nil
            }
        }
        if let primarySelection, let net = net(of: primarySelection) {
            return net
        }
        for item in selections {
            if let net = net(of: item) { return net }
        }
        return highlightedNet
    }

    /// "3 objects · 2 traces · 25.40 mm · 1000 mil total" — the
    /// traces subtotal Sean pinned: shown whenever the selection
    /// contains traces, in single AND mixed selections. Part 5.1
    /// adds the same treatment for individual segments:
    /// "· 3 segments · 42.6 mm · 1677.2 mil total".
    private var selectionSummaryText: String? {
        guard !selections.isEmpty else { return nil }
        var text = selections.count == 1 ? "1 object" : "\(selections.count) objects"
        let traces = selectedTraces
        if !traces.isEmpty {
            let total = traces.reduce(0) { $0 + $1.length }
            text += " · \(traces.count) trace\(traces.count == 1 ? "" : "s")"
                + " · \(BoardUnits.formatLength(mm: total)) total"
        }
        let segments = selectedSegments
        if !segments.isEmpty {
            let total = segments.reduce(0) { $0 + $1.trace.segmentLength($1.index) }
            text += " · \(segments.count) segment\(segments.count == 1 ? "" : "s")"
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
        .sheet(isPresented: $showMoveExactly) {
            moveExactlySheet
        }
        .sheet(isPresented: $showCleanupTracks) {
            cleanupTracksSheet
        }
        .sheet(isPresented: $showCleanupGraphics) {
            cleanupGraphicsSheet
        }
        .sheet(isPresented: $showGlobalDelete) {
            globalDeleteSheet
        }
        .sheet(isPresented: $showNetClasses) {
            netClassesSheet
        }
        .sheet(isPresented: $showFind) {
            findSheet
        }
        .alert("Swap Front/Back Copper?", isPresented: $showSwapLayersConfirm) {
            Button("Swap Layers") { swapLayers() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every trace, fill, teardrop and copper graphic swaps front ↔ back (inner layers mirror through the stack), and every footprint flips side.")
        }
        // Cross-probe (part 5.3, S8/P-side): a "Show on Board"
        // from the schematic lands here. Consumption is retried
        // when the canvas gets a size (a probe set before this
        // editor opened can only centre once the canvas exists);
        // the target is cleared only on a successful consume.
        .onAppear { consumeCrossProbe() }
        .onChange(of: crossProbe.target) { _, _ in consumeCrossProbe() }
        .onChange(of: canvasSize) { _, _ in consumeCrossProbe() }
        .onDisappear { liveSession.clearPCB() }
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
        // Static-layer invalidation (part 5.2): every caller of
        // refreshChecks has just changed the model or the
        // checks, so the equatable static canvas redraws.
        boardRenderVersion &+= 1
        guard let model else {
            connectivity = [:]
            clearanceViolations = []
            spatialIndex = nil
            ratsnestSegments = []
            return
        }
        connectivity = BoardConnectivity.analyze(
            model: model, copperCount: boardState.copperLayerCount)
        // Part 5.3: the boardState overloads, so netclass
        // clearances (P16) take effect live (the board clearance
        // in boardState IS manufacturingSettings.clearanceMil —
        // the settings are derived from it).
        clearanceViolations = BoardClearance.violations(
            model: model, copperCount: boardState.copperLayerCount,
            boardState: boardState)
        // Part 5.2: the spatial index and the ratsnest rebuild
        // with the checks — once per edit/commit, never per
        // pointer event. Part 5.3 (P8): nets hidden in the Nets
        // panel contribute no ratsnest segments.
        spatialIndex = BoardSpatialIndex.build(model)
        ratsnestSegments = BoardRatsnest.segments(
            model: model, copperCount: boardState.copperLayerCount,
            hiddenNets: Set(boardState.ratsnestHiddenNets))
        // Part 5.3: publish the live session for the external
        // display at this same choke point (title = the board's
        // table title, as the table bar shows it).
        liveSession.publishPCB(title: model.tableTitle,
                               state: boardState, model: model)
    }

    // MARK: - Cross-probe + centring (part 5.3)

    /// Consume a cross-probe target naming a footprint: select
    /// the component (the same selection state the Components
    /// panel writes) and centre the canvas on its placement,
    /// using the same offset math as Fit Board. Only a target
    /// that resolves — model loaded, reference present, canvas
    /// sized — is cleared; anything else stays pending for the
    /// next trigger (appear / target change / canvas size).
    private func consumeCrossProbe() {
        guard case .footprint(let reference)? = crossProbe.target,
              let model,
              model.components.contains(where: { $0.reference == reference }),
              canvasSize.width > 10, canvasSize.height > 10
        else { return }
        selectOnly(.component(reference))
        centreOnComponent(reference)
        crossProbe.target = nil
        setStatus("Showing \(reference) — cross-probed from the schematic.")
    }

    /// Centre the canvas on a board point at the current scale
    /// (Fit Board's offset formula, minus the rescale).
    private func centreOnBoardPoint(_ point: FPPoint) {
        guard canvasSize.width > 10, canvasSize.height > 10 else { return }
        offset = CGPoint(x: canvasSize.width / 2 - CGFloat(point.x * scale),
                         y: canvasSize.height / 2 - CGFloat(point.y * scale))
    }

    private func centreOnComponent(_ reference: String) {
        guard let component = model?.components.first(
            where: { $0.reference == reference }) else { return }
        let b = BoardGeometry.componentBounds(component)
        centreOnBoardPoint(FPPoint(x: (b.minX + b.maxX) / 2,
                                   y: (b.minY + b.maxY) / 2))
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
        case .segment(let id, let index):
            return model.traces.contains {
                $0.id == id && index >= 0 && index < $0.segmentCount
            }
        case .vertex(let id, let index):
            return model.traces.contains {
                $0.id == id && $0.points.indices.contains(index)
            }
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
        routeHead.reset()
        routePreviewCache = nil
        pendingPoints = []
        zonePoints = []
        textAnchor = nil
    }

    private func handleEscapeKey() {
        if pasteArmed {
            // An armed paste (part 5.3, P11) cancels first.
            pasteArmed = false
            setStatus("Paste cancelled.")
        } else if routingActive {
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
        // Switching tools also disarms a pending paste (P11).
        pasteArmed = false
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
                Button("Update Footprints from Library") {
                    updateFootprintsFromLibrary()
                }
                .disabled(model == nil)
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
                Button("Copy") { copySelectionToClipboard() }
                    .disabled(selections.isEmpty)
                Button("Paste") {
                    pasteArmed = true
                    setStatus("Tap to paste — tap the board where the copied items should land (Esc cancels).")
                }
                .disabled(clipboardSlice == nil)
                Divider()
                Button("Move Exactly…") { showMoveExactly = true }
                    .disabled(selections.isEmpty)
                Button("Select All Tracks in Net") { selectAllOnNet(deselect: false) }
                    .disabled(netSelectionContext == nil)
                Button("Deselect All Tracks in Net") { selectAllOnNet(deselect: true) }
                    .disabled(netSelectionContext == nil)
                Divider()
                Button(flipActionTitle) { flipSelection() }
                    .disabled(!canFlipSelection)
                Button("Swap Front/Back Copper") { showSwapLayersConfirm = true }
                    .disabled(model == nil)
                Button("Delete Selection") { deleteSelection() }
                    .disabled(selections.isEmpty)
                Button("Clear Net Highlight") { highlightedNet = nil }
                    .disabled(highlightedNet == nil)
            }
            Menu("View") {
                Button("Zoom In") { zoomIn() }
                Button("Zoom Out") { zoomOut() }
                Button("Fit Board") { fitBoard() }
                Button("Zoom to Selection") { zoomToSelection() }
                    .disabled(selections.isEmpty)
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
                Menu("Inactive Layers") {
                    ForEach(InactiveLayerMode.allCases, id: \.rawValue) { mode in
                        Button(inactiveLayerMode == mode
                               ? "✓ \(mode.rawValue)" : mode.rawValue) {
                            inactiveLayerMode = mode
                        }
                    }
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
                Button("Find…") { showFind = true }
                    .disabled(model == nil)
                Divider()
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
                Divider()
                Button("Select Unconnected Footprints") { selectUnconnectedFootprints() }
                    .disabled(model == nil)
                Button("Next Unconnected Footprint") { selectNextUnconnectedFootprint() }
                    .disabled(model == nil)
                Divider()
                Button("Cleanup Tracks & Vias…") { showCleanupTracks = true }
                    .disabled(model == nil)
                Button("Cleanup Graphics…") { showCleanupGraphics = true }
                    .disabled(model == nil)
                Divider()
                Button("Add Teardrops") { addTeardrops() }
                    .disabled(model == nil)
                Menu("Remove Teardrops") {
                    Button("All") {
                        mutateBoard { state in
                            state = BoardTeardrops.removingAll(from: state)
                        }
                        setStatus("All teardrops removed.")
                    }
                    Button("For Highlighted Net") {
                        if let highlightedNet {
                            mutateBoard { state in
                                state = BoardTeardrops.removing(from: state,
                                                                 net: highlightedNet)
                            }
                            setStatus("Teardrops removed for \(highlightedNet).")
                        }
                    }
                    .disabled(highlightedNet == nil)
                }
                Divider()
                Button("Global Deletions…") { showGlobalDelete = true }
                    .disabled(model == nil)
            }
            Menu("Preferences") {
                Button("Netclasses…") { showNetClasses = true }
                Divider()
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
                Text("Nets").lineLimit(1).tag("Nets")
            }
            .pickerStyle(.segmented)
            .padding(10)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if activePanelTab == "Objects" {
                        objectsPanel
                    } else if activePanelTab == "Components" {
                        componentsPanel(model: model)
                    } else if activePanelTab == "Nets" {
                        netsPanel(model: model)
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
            checkRow("Ratsnest", isOn: visibility.showRatsnest) {
                visibility.showRatsnest.toggle()
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

    /// The net inspector (part 5.2, pcbnew's net inspector):
    /// every net from the connectivity walk — pads routed of
    /// total, routed length, unrouted count. Tapping a row
    /// highlights the net (tap again to clear).
    private func netsPanel(model: BoardModel) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            panelHeader("Nets")
            let nets = connectivity.values.sorted { $0.netName < $1.netName }
            if nets.isEmpty {
                Text("No nets on this board yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            ForEach(nets, id: \.netName) { net in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(net.netName)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text("\(net.routedPadCount)/\(net.padCount) pads")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Text(BoardUnits.formatLength(mm: net.traceLength))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        if !net.unroutedPads.isEmpty {
                            Text("\(net.unroutedPads.count) open")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        // Per-net ratsnest eye (part 5.3, P8):
                        // a real Button beside the row's tap area
                        // (the row itself is a tap gesture, like
                        // the Layers panel, so the buttons inside
                        // it stay tappable).
                        Button {
                            toggleRatsnestHidden(net.netName)
                        } label: {
                            Image(systemName: boardState.ratsnestHiddenNets
                                  .contains(net.netName) ? "eye.slash" : "eye")
                                .font(.callout)
                                .foregroundStyle(.white.opacity(0.8))
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    }
                    // Netclass assignment (part 5.3, P16).
                    HStack(spacing: 8) {
                        Text("Class")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Menu {
                            Button(boardState.netClassByNet[net.netName] == nil
                                   ? "✓ No class" : "No class") {
                                assignNetClass(net.netName, className: nil)
                            }
                            ForEach(boardState.netClasses, id: \.name) { netClass in
                                Button(boardState.netClassByNet[net.netName] == netClass.name
                                       ? "✓ \(netClass.name)" : netClass.name) {
                                    assignNetClass(net.netName,
                                                   className: netClass.name)
                                }
                            }
                        } label: {
                            Text(boardState.netClassByNet[net.netName] ?? "No class")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(highlightedNet == net.netName
                            ? Color.accentColor.opacity(0.30)
                            : Color.white.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
                .onTapGesture {
                    highlightedNet = highlightedNet == net.netName
                        ? nil : net.netName
                }
            }
            Text("Tap a net to highlight it on the board; tap again to clear. \"Open\" counts pads that reach no other pad — the ratsnest lines show where they still need to go. The eye hides that net's ratsnest lines; Class assigns a netclass (Preferences ▸ Netclasses edits them).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(6)
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
            if measure.a != nil {
                measureDetail
                Divider()
            }
            if selections.count > 1, let summary = selectionSummaryText {
                Text(summary)
                    .font(.callout.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                Text("The item below is the last one tapped. Delete removes the whole selection. Dragging moves the selected components together; a selected track segment or corner drags on its own.")
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
                // Part 5.2: duplicate + align/distribute +
                // mass edit for the whole selection.
                Button { duplicateSelection() } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                if selectedComponentReferencesOrdered.count >= 2 {
                    Text("Align footprints")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .padding(.top, 2)
                    HStack(spacing: 6) {
                        Button("Left") { applyAlignment(.left) }
                        Button("Right") { applyAlignment(.right) }
                        Button("Top") { applyAlignment(.top) }
                        Button("Bottom") { applyAlignment(.bottom) }
                    }
                    .buttonStyle(.bordered)
                    .font(.callout)
                    HStack(spacing: 6) {
                        Button("Centre ↔") { applyAlignment(.centreX) }
                        Button("Centre ↕") { applyAlignment(.centreY) }
                    }
                    .buttonStyle(.bordered)
                    .font(.callout)
                    if selectedComponentReferencesOrdered.count >= 3 {
                        HStack(spacing: 6) {
                            Button("Space ↔ evenly") {
                                applyDistribution(horizontal: true)
                            }
                            Button("Space ↕ evenly") {
                                applyDistribution(horizontal: false)
                            }
                        }
                        .buttonStyle(.bordered)
                        .font(.callout)
                    }
                    Text("Alignment uses the footprints' pad outlines; Centre anchors on the first footprint listed. Locked footprints never move.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                if selectedTraces.count > 1 {
                    Text("All \(selectedTraces.count) selected tracks")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .padding(.top, 2)
                    HStack(spacing: 6) {
                        TextField("Width (mm)", text: $widthDraft)
                            .keyboardType(.decimalPad)
                            .textFieldStyle(.roundedBorder)
                        Button("Apply to All") {
                            applyWidthToSelectedTraces()
                        }
                        .buttonStyle(.bordered)
                    }
                    HStack(spacing: 6) {
                        ForEach(BoardLayers.copperLayers(
                            count: boardState.copperLayerCount), id: \.self) { layer in
                            Button(layer) { applyLayerToSelectedTraces(layer) }
                                .buttonStyle(.bordered)
                                .font(.caption)
                        }
                    }
                }
                Divider()
            }
            if let component = selectedComponent {
                componentDetail(component)
            } else if let segment = selectedSegment {
                segmentDetail(segment.trace, index: segment.index)
            } else if let vertex = selectedVertex {
                vertexDetail(vertex.trace, index: vertex.index)
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

    /// The measure tool's readout card (part 5.2).
    private var measureDetail: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Measure")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
            if let a = measure.a {
                detailRow("From", "\(fmt(a.x)), \(fmt(a.y)) mm")
            }
            if let b = measure.b {
                detailRow("To", "\(fmt(b.x)), \(fmt(b.y)) mm")
            }
            if let distance = measure.distance, let delta = measure.delta {
                detailRow("Distance", BoardUnits.formatLength(mm: distance))
                detailRow("Δx / Δy", "\(fmt(delta.x)) / \(fmt(delta.y)) mm")
            } else {
                Text("Tap the second point on the board.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Button("Clear Measurement") { measure.clear() }
                .buttonStyle(.bordered)
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
            // Cross-probe (part 5.3): jump to this part's symbol
            // in the schematic editor.
            Button {
                crossProbe.target = .symbol(reference: component.reference)
                navigate("schematic")
            } label: {
                Label("Show in Schematic", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
            }
            .buttonStyle(.bordered)
            Button {
                updateFootprintsFromLibrary(onlyReference: component.reference)
            } label: {
                Label("Update Footprint from Library", systemImage: "arrow.clockwise")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
            }
            .buttonStyle(.bordered)
            Button {
                unrouteComponent(component.reference)
            } label: {
                Label("Unroute Footprint", systemImage: "point.bottomleft.forward.to.point.topright.scurvepath")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
            }
            .buttonStyle(.bordered)
            lockRow(.component(component.reference))

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

    /// One segment of a track (part 5.1): the readout Sean asked
    /// for — net, layer, width, and THIS segment's length — plus
    /// the whole-track context and the way out to whole-track
    /// selection.
    private func segmentDetail(_ trace: BoardTrace, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Track Segment")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
            detailRow("Segment", "\(index + 1) of \(trace.segmentCount)")
            detailRow("Net", trace.netName
                      ?? trace.disconnectedNetName.map { "was \($0) — unconnected" }
                      ?? "Unconnected")
            detailRow("Layer", trace.layer)
            detailRow("Width", "\(PCBBoardMerger.formatMM(trace.width)) mm")
            detailRow("Segment Length",
                      BoardUnits.formatLength(mm: trace.segmentLength(index)))
            detailRow("Whole Track", BoardUnits.formatLength(mm: trace.length))
            Text("Drag this segment to move it — the segments next to it stretch to follow. Drag a round corner handle to bend the track. Double-tap a segment of this track to add a corner there.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(4)
            Button {
                selectOnly(.trace(trace.id))
            } label: {
                Label("Select Whole Track", systemImage: "square.stack.3d.up")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
            }
            .buttonStyle(.bordered)
            .padding(.top, 2)
            deleteSelectionButton("Delete Segment")
        }
    }

    /// One corner (vertex) of a track (part 5.1).
    private func vertexDetail(_ trace: BoardTrace, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Track Corner")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
            detailRow("Corner", "\(index + 1) of \(trace.points.count)")
            detailRow("Net", trace.netName
                      ?? trace.disconnectedNetName.map { "was \($0) — unconnected" }
                      ?? "Unconnected")
            detailRow("Layer", trace.layer)
            detailRow("Position",
                      "\(fmt(trace.points[index].x)), \(fmt(trace.points[index].y)) mm")
            Text("Drag the corner to bend the track — the two segments at this corner follow. Deleting the corner joins its segments into one straight run.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(4)
            Button {
                selectOnly(.trace(trace.id))
            } label: {
                Label("Select Whole Track", systemImage: "square.stack.3d.up")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
            }
            .buttonStyle(.bordered)
            .padding(.top, 2)
            deleteSelectionButton("Delete Corner")
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
            HStack(spacing: 8) {
                lockRow(.trace(trace.id))
                duplicateButtonRow()
            }
            Button {
                unrouteTrace(trace)
            } label: {
                Label("Unroute from Here", systemImage: "point.bottomleft.forward.to.point.topright.scurvepath")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
            }
            .buttonStyle(.bordered)
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
            Text("Width changes redraw immediately and are saved with the board. Tap one segment of this track to edit just that piece — drag its corners to reshape the track.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
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
            HStack(spacing: 8) {
                lockRow(.via(via.id))
                duplicateButtonRow()
            }
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
            HStack(spacing: 8) {
                lockRow(.zone(zone.id))
                duplicateButtonRow()
            }
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
            HStack(spacing: 8) {
                lockRow(.graphic(graphic.id))
                duplicateButtonRow()
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

    /// The Duplicate button shared by the item detail cards
    /// (part 5.2).
    private func duplicateButtonRow() -> some View {
        Button { duplicateSelection() } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
                .font(.callout.weight(.semibold))
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
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
        // Part 5.3: the boardState overload (netclass-aware rule
        // 1) and finding exclusions (P7): rows, pass/fail headers
        // and the summary all run on the VISIBLE findings —
        // excluded findings stop counting until restored.
        let report = model.map {
            BoardManufacturing.check(model: $0,
                                     copperCount: boardState.copperLayerCount,
                                     settings: manufacturingSettings,
                                     connectivity: connectivity,
                                     boardState: boardState)
        }
        let partition = report.map {
            BoardManufacturing.visibleFindings(
                $0.findings, excluding: boardState.manufacturingExclusions)
        }
        let visibleKeys = Set(partition?.visible.map(\.key) ?? [])
        let staleKeys = report.map {
            BoardManufacturing.staleExclusions(
                boardState.manufacturingExclusions, findings: $0.findings)
        } ?? []
        let visibleFailedCount = report?.rules.filter { rule in
            rule.findings.contains { visibleKeys.contains($0.key) }
        }.count ?? 0
        return NavigationStack {
            List {
                Section {
                    Text(report.map { _ in
                        visibleFailedCount == 0
                            ? "All \(report?.rules.count ?? 0) rules pass — this board is inside the current manufacturing limits."
                            : "\(visibleFailedCount) of \(report?.rules.count ?? 0) rules fail. The failing rules list what and where below."
                    } ?? "No board loaded.")
                        .font(.callout)
                } header: {
                    Text("Result")
                }
                Section {
                    Text("Limits in force: clearance \(BoardUnits.formatMil(manufacturingSettings.clearanceMil)) mil · min track \(BoardUnits.formatMil(manufacturingSettings.minTraceWidthMil)) mil · min via drill \(BoardUnits.formatMil(manufacturingSettings.minViaDrillMil)) mil · min via diameter \(BoardUnits.formatMil(manufacturingSettings.minViaDiameterMil)) mil · min annular ring \(BoardUnits.formatMil(manufacturingSettings.minAnnularRingMil)) mil. Clearance is adjustable in Preferences.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Settings")
                }
                if let report {
                    ForEach(Array(report.rules.enumerated()), id: \.offset) { _, rule in
                        let visibleFindings = rule.findings.filter {
                            visibleKeys.contains($0.key)
                        }
                        Section {
                            if visibleFindings.isEmpty {
                                Text("Pass — nothing to report.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(Array(visibleFindings.prefix(12).enumerated()),
                                        id: \.offset) { _, finding in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text(finding.message)
                                            .font(.callout)
                                        Spacer(minLength: 0)
                                        Button("Exclude") {
                                            excludeManufacturingFinding(finding.key)
                                        }
                                        .font(.callout.weight(.semibold))
                                        .lineLimit(1)
                                    }
                                }
                                if visibleFindings.count > 12 {
                                    Text("…and \(visibleFindings.count - 12) more")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } header: {
                            HStack(spacing: 6) {
                                Image(systemName: visibleFindings.isEmpty
                                      ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(visibleFindings.isEmpty
                                                     ? .green : .red)
                                Text(rule.name)
                            }
                        }
                    }
                    if let partition, !partition.excluded.isEmpty {
                        Section {
                            ForEach(Array(partition.excluded.enumerated()),
                                    id: \.offset) { _, finding in
                                HStack(alignment: .top, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(finding.message)
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                        if let note = boardState
                                            .manufacturingExclusionNotes[finding.key],
                                           !note.isEmpty {
                                            Text(note)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                    Button("Restore") {
                                        restoreManufacturingFinding(finding.key)
                                    }
                                    .font(.callout.weight(.semibold))
                                    .lineLimit(1)
                                }
                            }
                        } header: {
                            Text("Excluded (\(partition.excluded.count))")
                        } footer: {
                            Text("Excluded findings don't count toward the result. Restore one to count it again.")
                        }
                    }
                    if !staleKeys.isEmpty {
                        Section {
                            ForEach(Array(staleKeys.enumerated()),
                                    id: \.offset) { _, key in
                                HStack(alignment: .top, spacing: 8) {
                                    Text("\(key) — no longer matches any finding")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                    Spacer(minLength: 0)
                                    Button("Remove") {
                                        restoreManufacturingFinding(key)
                                    }
                                    .font(.callout.weight(.semibold))
                                    .lineLimit(1)
                                }
                            }
                        } header: {
                            Text("Stale exclusions")
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

    /// Exclude one manufacturing finding by its stable key (P7).
    private func excludeManufacturingFinding(_ key: String) {
        mutateBoard { state in
            if !state.manufacturingExclusions.contains(key) {
                state.manufacturingExclusions.append(key)
            }
        }
        setStatus("Finding excluded — it no longer counts in the Manufacturing Check.")
    }

    /// Restore an excluded finding (or drop a stale exclusion
    /// key): the key leaves the board's exclusion list.
    private func restoreManufacturingFinding(_ key: String) {
        mutateBoard { state in
            state.manufacturingExclusions.removeAll { $0 == key }
            state.manufacturingExclusionNotes[key] = nil
        }
        setStatus("Finding restored — it counts in the Manufacturing Check again.")
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
                                    connectivity: connectivity,
                                    boardState: boardState),
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
            // Cursor position + hover diagnostics (part 5.2):
            // the only status-bar content observing the pointer
            // model, in its own subview.
            BoardPointerReadoutView(pointer: pointerModel)
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
        frameBoardRect(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    /// Frame one board rectangle in the canvas: Fit Board's
    /// scale/offset math, shared with Zoom to Selection (P17).
    private func frameBoardRect(minX: Double, minY: Double,
                                maxX: Double, maxY: Double) {
        guard canvasSize.width > 10, canvasSize.height > 10 else { return }
        let w = max(maxX - minX, 1), h = max(maxY - minY, 1)
        let newScale = BoardCanvasMetrics.clamped(
            min((Double(canvasSize.width) - 32) / w,
                (Double(canvasSize.height) - 32) / h))
        scale = newScale
        offset = CGPoint(x: canvasSize.width / 2 - CGFloat((minX + maxX) / 2 * newScale),
                         y: canvasSize.height / 2 - CGFloat((minY + maxY) / 2 * newScale))
    }

    // MARK: - Board canvas + gestures

    /// THE hover entry point (parts 5.0.2–5.0.3, restructured
    /// 5.2): every delivery channel funnels through these two
    /// helpers — the event is recorded against its channel in
    /// the diagnostics, then applied to the ONE pointer stream
    /// (via the pointer model: per-channel arbitration +
    /// coalescing throttle live there now). Arbitration,
    /// previews and tap resolution are therefore identical no
    /// matter which channel delivered the event. `PADCB-HOVER`
    /// log markers mirror the counters for the simulator hover
    /// exercise: first event per channel, then every 50th.
    private func feedHoverMoved(_ boardPoint: FPPoint,
                                channel: BoardHoverChannel) {
        let before = pointerModel.diagnostics.count(channel)
        pointerModel.feedHoverMoved(boardPoint, channel: channel)
        if before == 0 {
            padcbHoverPrint("PADCB-HOVER first ch=\(channel.rawValue)"
                + " summary=\(pointerModel.diagnostics.summary)")
        } else if (before + 1) % 50 == 0 {
            padcbHoverPrint("PADCB-HOVER ch=\(channel.rawValue)"
                + " count=\(before + 1)"
                + " summary=\(pointerModel.diagnostics.summary)")
        }
        refreshRoutePreview()
    }

    private func feedHoverEnded(channel: BoardHoverChannel) {
        let before = pointerModel.diagnostics.count(channel)
        pointerModel.feedHoverEnded(channel: channel)
        if before == 0 {
            padcbHoverPrint("PADCB-HOVER first ch=\(channel.rawValue) (end)"
                + " summary=\(pointerModel.diagnostics.summary)")
        }
        refreshRoutePreview()
    }

    /// Re-resolve the routing head against the CURRENT pointer
    /// and cache it for the preview layer (part 5.2). Runs on
    /// pointer events and route-state changes — never during
    /// drawing — so the stateful head (BoardRouteHead) mutates
    /// only in event context, exactly like KiCad's Move().
    private func refreshRoutePreview() {
        guard routingActive, let model, let last = routePoints.last,
              let point = pointerModel.state.currentPoint else {
            routePreviewCache = nil
            return
        }
        routePreviewCache = routeHead.resolve(
            model, from: last, pointer: point, routeNet: routeNet,
            snapEnabled: snapEnabled, gridMil: boardState.gridMil,
            tolerance: tapToleranceMM)
    }

    /// The static layer's invalidation token (part 5.2): every
    /// value the static drawing reads, in one Equatable bundle.
    private var staticToken: StaticBoardToken {
        StaticBoardToken(
            renderVersion: boardRenderVersion,
            boardState: boardState,
            visibility: visibility,
            selections: selections,
            primarySelection: primarySelection,
            highlightedNet: highlightedNet,
            activeLayer: activeLayer,
            showGrid: showGrid,
            scale: scale,
            offset: offset,
            movePreviewOrigins: movePreviewOrigins,
            moveViaPreview: moveViaPreview,
            editDragTraceID: editDragTraceID,
            editDragPreviewPoints: editDragPreviewPoints,
            ratsnestCount: ratsnestSegments.count,
            inactiveLayerModeRaw: inactiveLayerMode.rawValue)
    }

    /// The alpha an item on `layer` draws at under the inactive-
    /// layer mode (part 5.3, P9): 1 when the layer IS the active
    /// layer (or the mode is Normal), 0.35 in Dim, nil in Hide
    /// (the caller skips the item). Traces and pads layer their
    /// legacy dimming on top of / in place of this — see
    /// drawAllTraces and padInactiveFactor.
    private func inactiveFactor(forLayer layer: String) -> Double? {
        switch inactiveLayerMode {
        case .normal: return 1
        case .dim: return layer == activeLayer ? 1 : 0.35
        case .hide: return layer == activeLayer ? 1 : nil
        }
    }

    /// A pad's inactive factor: pads count as "on" the active
    /// layer when they touch it or span every copper layer
    /// ("*.Cu") — the membership rule the old Highlight Active
    /// Layer dimming used, now serving all three modes. In
    /// Normal mode the legacy opt-in dimming (0.4, only under
    /// the Highlight Active Layer toggle) is preserved exactly.
    private func padInactiveFactor(_ pad: KiCadFootprintPad) -> Double? {
        let touches = pad.layers.contains(activeLayer)
            || pad.layers.contains("*.Cu")
        switch inactiveLayerMode {
        case .normal:
            return (highlightActiveLayer && !touches) ? 0.4 : 1
        case .dim:
            return touches ? 1 : 0.35
        case .hide:
            return touches ? 1 : nil
        }
    }

    private func boardCanvas(model: BoardModel) -> some View {
        BoardCanvasHost(pointer: pointerModel,
                        onFlush: { refreshRoutePreview() }) { pointer in
            canvasStack(model: model, pointer: pointer)
        }
    }

    private func canvasStack(model: BoardModel,
                             pointer: BoardPointerState) -> some View {
        GeometryReader { geo in
            ZStack {
                // Static layer (part 5.2): the whole board,
                // redrawn only when its token changes — Pencil
                // hover never touches it.
                StaticBoardLayer(token: staticToken, draw: { ctx, size in
                    drawStaticBoard(ctx: ctx, size: size, model: model)
                })
                .equatable()
                // Preview layer: pointer-driven drawing only
                // (route head, hover highlight, tool previews,
                // measure) — cheap paths over indexed queries.
                Canvas { ctx, size in
                    drawPreviews(ctx: ctx, size: size, model: model,
                                 pointer: pointer)
                }
            }
            .background(Color(red: 0.043, green: 0.055, blue: 0.043)) // #0B0E0B-ish
            .contentShape(Rectangle())
            // Apple Pencil hover (part 5.0.3): ONE dedicated UIKit
            // interaction view sits FRONTMOST over the canvas rect
            // (top layer of this stack) and is the hit view for
            // hover AND touches alike; its UIHoverGestureRecognizer
            // is attached DIRECTLY to it — Apple's canonical
            // pattern. v5.0.1's hit-test-transparent overlay (own
            // recognizer dead by construction) + lent ancestor
            // recognizers delivered nothing on Sean's hardware,
            // and v5.0.2's three worked-around channels (selective
            // hit test, background probe walking to the hosting
            // root, SwiftUI feed) still didn't reach his Pencil
            // Pro — so this round owns the hierarchy instead of
            // working around it. No lent recognizers, no ancestor
            // walks, no background probe. The view consumes
            // NOTHING but hover: it overrides no touch handler, so
            // UIKit's default responder forwarding passes every
            // touch through, and the editor's gestures — attached
            // BELOW to the COMPOSITE (canvas + interaction view),
            // an ancestor of the interaction view in the gesture
            // delivery chain — receive the touches normally.
            // Channel 1 = the interaction view's recognizer.
            .overlay {
                BoardInteractionView { location in
                    if let location {
                        feedHoverMoved(screenToBoard(location),
                                       channel: .interaction)
                    } else {
                        feedHoverEnded(channel: .interaction)
                    }
                }
            }
            // The canvas gestures apply to the composite view
            // (canvas + interaction view), NOT to the canvas
            // alone: their recognizers sit on a container that
            // CONTAINS the interaction view, so touches whose hit
            // view IS the interaction view are delivered to them
            // through the standard gesture system. (In v5.0.1/
            // v5.0.2 the gestures were attached inside the canvas
            // subtree and the overlay lived in a sibling subtree —
            // outside that delivery chain.)
            .gesture(canvasDrag)
            .simultaneousGesture(canvasMagnify)
            // Double-tap (part 5.1): whole-track select on a
            // freshly opened trace, corner insert on one being
            // edited — see handleDoubleTap. The two constituent
            // presses ALSO reach the drag gesture as ordinary
            // taps; both paths are written to compose (the taps
            // select the segment, the double-tap then upgrades
            // or inserts).
            .onTapGesture(count: 2) { location in
                handleDoubleTap(at: screenToBoard(location))
            }
            // Channel 2 (SwiftUI fallback): .onContinuousHover on
            // the canvas container — the v5.0 feed, kept as an
            // independent counted fallback. No pencil = no events
            // on either channel = the plain touch behaviour.
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    feedHoverMoved(screenToBoard(location),
                                   channel: .swiftUI)
                case .ended:
                    feedHoverEnded(channel: .swiftUI)
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
                pointerModel.feedTouchMoved(screenToBoard(value.location))
                refreshRoutePreview()
                if dragMode == .undecided {
                    // Once per drag (this block runs on the first
                    // change only): exercise-only proof that the
                    // SwiftUI drag gesture still receives touches
                    // whose hit view is the frontmost interaction
                    // view (part 5.0.3).
                    padcbProbePrint("PADCB-GESTURE drag began")
                    dragStartOffset = offset
                    let startBoard = screenToBoard(value.startLocation)
                    // A via's hit area is tiny and precise, so it
                    // wins over a footprint's broad bounds.
                    if activeTool == .select, let model,
                       selectionFilter.allows(.via),
                       let via = (spatialIndex?.viaAt(
                                   model, point: startBoard,
                                   tolerance: tapToleranceMM)
                                  ?? BoardGeometry.viaAt(
                                      model, point: startBoard,
                                      tolerance: tapToleranceMM)),
                       visibility.viaShown(via) {
                        if boardState.isLocked(via.id) {
                            // Locked via (part 5.2): the press
                            // pans instead of dragging it.
                            dragMode = .pan
                            setStatus("That via is locked — unlock it (Lock button in its details) to move it.")
                        } else {
                            dragMode = .moveVia
                            movingViaID = via.id
                            moveViaStart = via.center
                            moveViaPreview = via.center
                        }
                    } else if activeTool == .select,
                              selectionFilter.allows(.trace),
                              let active = editTrace,
                              visibility.traceShown(active),
                              beginTraceEditDrag(trace: active, at: startBoard) {
                        // A corner or segment of the track being
                        // edited claimed the press (part 5.1) —
                        // dragMode and the edit-drag state were
                        // set by the helper. Checked BEFORE
                        // components: endpoints sit on pads, inside
                        // footprint bounds, and must not drag the
                        // component instead.
                    } else if activeTool == .select, let model,
                              visibility.showFootprints,
                              selectionFilter.allows(.component),
                              let component = (spatialIndex?.componentAt(
                                                  model, point: startBoard)
                                               ?? BoardGeometry.componentAt(
                                                  model, point: startBoard)) {
                        if boardState.isLocked(reference: component.reference) {
                            // Locked footprint (part 5.2): the
                            // press pans; taps still select it so
                            // it can be unlocked from its details.
                            dragMode = .pan
                            setStatus("\(component.reference) is locked — unlock it (Lock button in its details) to move it.")
                        } else if multiSelect
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
                            // Locked members never join a group
                            // move (part 5.2).
                            for reference in Array(moveStartOrigins.keys)
                            where boardState.isLocked(reference: reference) {
                                moveStartOrigins.removeValue(forKey: reference)
                                movePreviewOrigins.removeValue(forKey: reference)
                            }
                        }
                    } else {
                        dragMode = .pan
                    }
                }
                let dragDelta = FPPoint(
                    x: Double(value.translation.width) / scale,
                    y: Double(value.translation.height) / scale)
                switch dragMode {
                case .pan:
                    if let start = dragStartOffset {
                        offset = CGPoint(x: start.x + value.translation.width,
                                         y: start.y + value.translation.height)
                    }
                case .moveVertex:
                    // The grabbed corner follows the pointer,
                    // snapped to the grid like every other move;
                    // its two segments follow through the shared
                    // point (the preview IS the edited polyline).
                    if editDragStartPoints.indices.contains(editDragIndex) {
                        let start = editDragStartPoints[editDragIndex]
                        var preview = editDragStartPoints
                        preview[editDragIndex] = snapPoint(FPPoint(
                            x: start.x + dragDelta.x,
                            y: start.y + dragDelta.y))
                        editDragPreviewPoints = preview
                    }
                case .moveSegment:
                    // Both endpoints move by ONE delta, derived by
                    // snapping the segment's first endpoint — the
                    // segment keeps its exact length and angle, and
                    // the neighbours stretch (part 5.1).
                    let index = editDragIndex
                    if editDragStartPoints.count > index + 1 {
                        let startA = editDragStartPoints[index]
                        let snappedA = snapPoint(FPPoint(
                            x: startA.x + dragDelta.x,
                            y: startA.y + dragDelta.y))
                        let applied = FPPoint(x: snappedA.x - startA.x,
                                              y: snappedA.y - startA.y)
                        var preview = editDragStartPoints
                        preview[index] = FPPoint(
                            x: preview[index].x + applied.x,
                            y: preview[index].y + applied.y)
                        preview[index + 1] = FPPoint(
                            x: preview[index + 1].x + applied.x,
                            y: preview[index + 1].y + applied.y)
                        editDragPreviewPoints = preview
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
                pointerModel.feedTouchEnded()
                refreshRoutePreview()
                let moved = hypot(value.translation.width, value.translation.height)
                // Exercise-only: the drag's outcome in one line —
                // moved < 5 = a tap reached the tool handlers;
                // mode .pan + moved ≥ 5 = a pan; the offset/scale
                // snapshot shows the effect (part 5.0.3).
                padcbProbePrint("PADCB-GESTURE drag ended"
                    + " moved=\(String(format: "%.1f", moved))"
                    + " mode=\(dragMode)"
                    + " offset=(\(String(format: "%.1f", offset.x)), \(String(format: "%.1f", offset.y)))"
                    + " scale=\(String(format: "%.2f", scale))")
                if moved < 5 {
                    // A tap. A pan-tap undoes its micro-pan and goes
                    // to the active tool; a move-mode tap resolves
                    // its deferred selection (Multi toggles; the
                    // single-select case was applied at drag start).
                    if dragMode == .pan, let start = dragStartOffset {
                        offset = start
                        handleTap(at: screenToBoard(value.location))
                    } else if dragMode == .moveVertex || dragMode == .moveSegment {
                        // A press that didn't travel is a tap:
                        // resolve it through the normal tap path
                        // (corner select / segment select).
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
                } else if dragMode == .moveVertex || dragMode == .moveSegment,
                          let id = editDragTraceID,
                          let preview = editDragPreviewPoints,
                          preview != editDragStartPoints {
                    // One mutateBoard for the whole drag = one
                    // undo step (part 5.1), like every other move.
                    let cornerDrag = dragMode == .moveVertex
                    mutateBoard { state in
                        if let position = state.traces.firstIndex(
                            where: { $0.id == id }) {
                            state.traces[position].points = preview
                        }
                    }
                    setStatus(cornerDrag
                              ? "Corner moved — the track's new shape is saved with the board."
                              : "Segment moved — its neighbours stretched to follow. Saved with the board.")
                }
                dragMode = .undecided
                dragStartOffset = nil
                moveStartOrigins = [:]
                movePreviewOrigins = [:]
                movingViaID = nil
                moveViaStart = nil
                moveViaPreview = nil
                dragTapReference = nil
                editDragTraceID = nil
                editDragStartPoints = []
                editDragPreviewPoints = nil
            }
    }

    /// Trace-edit drag claim (part 5.1): a press on a corner of
    /// the track being edited starts a corner drag; a press on
    /// the selected segment (or on any segment, when the whole
    /// track is selected) starts a segment drag. Sets the drag
    /// mode + edit-drag state and returns true when claimed.
    private func beginTraceEditDrag(trace: BoardTrace, at startBoard: FPPoint) -> Bool {
        // Locked tracks don't bend (part 5.2).
        if boardState.isLocked(trace.id) { return false }
        if let vertex = BoardGeometry.vertexHit(
            trace, point: startBoard,
            tolerance: max(tapToleranceMM, 4.5 / scale)) {
            dragMode = .moveVertex
            editDragTraceID = trace.id
            editDragIndex = vertex.index
            editDragStartPoints = trace.points
            editDragPreviewPoints = trace.points
            return true
        }
        let grabbed: Int?
        if case .segment(let id, let index)? = primarySelection, id == trace.id {
            grabbed = BoardGeometry.segmentHit(
                trace, point: startBoard, tolerance: tapToleranceMM)?.index == index
                ? index : nil
        } else if case .trace(let id)? = primarySelection, id == trace.id {
            grabbed = BoardGeometry.segmentHit(
                trace, point: startBoard, tolerance: tapToleranceMM)?.index
        } else {
            grabbed = nil
        }
        guard let grabbed else { return false }
        dragMode = .moveSegment
        editDragTraceID = trace.id
        editDragIndex = grabbed
        editDragStartPoints = trace.points
        editDragPreviewPoints = trace.points
        return true
    }

    private var canvasMagnify: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if pinchStartScale == nil {
                    pinchStartScale = scale
                    // Exercise-only delivery proof (part 5.0.3).
                    padcbProbePrint("PADCB-GESTURE magnify began")
                }
                if let start = pinchStartScale {
                    scale = BoardCanvasMetrics.clamped(start * Double(value))
                }
            }
            .onEnded { _ in
                padcbProbePrint("PADCB-GESTURE magnify ended"
                    + " scale=\(String(format: "%.2f", scale))")
                pinchStartScale = nil
            }
    }

    // MARK: - Tap handling per tool

    private func handleTap(at point: FPPoint) {
        guard let model else { return }
        // An armed paste (part 5.3, P11) takes the next Select-
        // tool tap as its landing point.
        if pasteArmed, activeTool == .select {
            commitPaste(at: point)
            return
        }
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
        case .measure:
            // Measure tool (part 5.2): two taps mark a distance;
            // a third tap starts a new measurement.
            measure.tap(snapPoint(point))
            if let distance = measure.distance, let delta = measure.delta {
                setStatus("Measured \(fmt(distance)) mm — Δx \(fmt(delta.x)) mm, "
                          + "Δy \(fmt(delta.y)) mm. Tap again to start over.")
            } else {
                setStatus("Measure: first point set — tap the second point.")
            }
        }
    }

    /// "NET_A segment 2 of 4 on F.Cu — 12.70 mm · 500 mil long":
    /// the tapped segment named in full (part 5.1: net, layer and
    /// THAT segment's length; the width rides in the detail panel).
    private func segmentStatusText(_ trace: BoardTrace, _ index: Int) -> String {
        let net = trace.netName ?? trace.disconnectedNetName ?? "Unconnected"
        return "\(net) segment \(index + 1) of \(trace.segmentCount) on \(trace.layer)"
            + " — \(BoardUnits.formatLength(mm: trace.segmentLength(index))) long."
            + " Drag it or a corner to reshape the track."
    }

    /// Double-tap on the canvas (Select tool, part 5.1). Sean's
    /// two sentences: a double-tap selects the WHOLE trace, and a
    /// double-tap on a segment inserts a vertex. They can't both
    /// own the same gesture on an untouched trace, so: a
    /// double-tap whose first tap FRESHLY opened the trace (see
    /// freshSegmentTap) selects the whole trace; a double-tap on
    /// a trace already being edited inserts a vertex at the
    /// tapped segment — projected onto the segment, then snapped,
    /// so the new corner sits on the copper and on the grid.
    private func handleDoubleTap(at point: FPPoint) {
        guard activeTool == .select, let model,
              selectionFilter.allows(.trace) else { return }
        guard let hit = spatialIndex?.segmentAt(
                  model, point: point, tolerance: tapToleranceMM,
                  allowedTraceIDs: Set(model.traces
                      .filter { visibility.traceShown($0) }.map(\.id)))
                  ?? BoardGeometry.segmentAt(
                      model.traces.filter { visibility.traceShown($0) },
                      point: point, tolerance: tapToleranceMM)
        else { return }
        if let fresh = freshSegmentTap,
           fresh.traceID == hit.trace.id, fresh.index == hit.index,
           Date().timeIntervalSince(fresh.time) < 0.6,
           editTraceID == hit.trace.id {
            freshSegmentTap = nil
            wholeTracePromotion = (hit.trace.id, Date())
            selectOnly(.trace(hit.trace.id))
            setStatus("Whole track selected — \(BoardUnits.formatLength(mm: hit.trace.length)) on \(hit.trace.layer). Tap one segment to edit just that piece.")
            return
        }
        guard editTraceID == hit.trace.id else {
            // Not editing this trace and not a fresh open: the
            // double-tap just re-selects the segment (the two
            // plain taps already did) — nothing more to do.
            return
        }
        let a = hit.trace.points[hit.index]
        let b = hit.trace.points[hit.index + 1]
        let inserted = snapPoint(
            BoardGeometry.closestPointOnSegment(point, from: a, to: b))
        let traceID = hit.trace.id, segment = hit.index
        mutateBoard { state in
            if let position = state.traces.firstIndex(where: { $0.id == traceID }) {
                state.traces[position] = BoardGeometry.traceWithVertexInserted(
                    state.traces[position], segment: segment, at: inserted)
            }
        }
        selectOnly(.vertex(traceID, segment + 1))
        setStatus("Corner added — drag it to shape the track.")
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
        // Vertex handles of the track being edited (part 5.1):
        // endpoints sit ON pads, inside footprint bounds, so the
        // handles are checked before traces and components alike.
        if selectionFilter.allows(.trace), let active = editTrace,
           visibility.traceShown(active),
           let vertex = BoardGeometry.vertexHit(
               active, point: point,
               tolerance: max(tolerance, 4.5 / scale)) {
            selectOnly(.vertex(active.id, vertex.index))
            setStatus("Corner \(vertex.index + 1) of \(active.points.count) — drag it to bend the track, or Delete to join its segments straight.")
            return
        }
        // Traces select SEGMENT by segment (part 5.1): the
        // nearest segment under the tap, across the visible
        // traces — never the whole track from a plain tap.
        if selectionFilter.allows(.trace),
           let hit = spatialIndex?.segmentAt(
               model, point: point, tolerance: tolerance,
               allowedTraceIDs: Set(model.traces
                   .filter { visibility.traceShown($0) }.map(\.id)))
               ?? BoardGeometry.segmentAt(
                   model.traces.filter { visibility.traceShown($0) },
                   point: point, tolerance: tolerance) {
            if multiSelect {
                toggleSelection(.segment(hit.trace.id, hit.index))
            } else if case .trace(let selectedID)? = primarySelection,
                      selectedID == hit.trace.id,
                      let promotion = wholeTracePromotion,
                      promotion.traceID == hit.trace.id,
                      Date().timeIntervalSince(promotion.time) < 0.6 {
                // The second press of the double-tap that just
                // promoted this trace, delivered late: keep the
                // whole-track selection it produced.
                return
            } else {
                // A tap that OPENS a fresh track (it wasn't being
                // edited) arms the double-tap whole-track path;
                // the second tap of that double-tap leaves the
                // flag standing for handleDoubleTap; taps within
                // an editing session disarm it (their double-taps
                // insert vertices instead).
                if let fresh = freshSegmentTap,
                   fresh.traceID == hit.trace.id,
                   fresh.index == hit.index,
                   Date().timeIntervalSince(fresh.time) < 0.6 {
                    // In-flight double-tap: leave the flag.
                } else if editTraceID != hit.trace.id {
                    freshSegmentTap = (hit.trace.id, hit.index, Date())
                } else {
                    freshSegmentTap = nil
                }
                selectOnly(.segment(hit.trace.id, hit.index))
            }
            if selections.contains(.segment(hit.trace.id, hit.index)) {
                setStatus(segmentStatusText(hit.trace, hit.index))
            }
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
           let component = spatialIndex?.componentAt(model, point: point)
               ?? BoardGeometry.componentAt(model, point: point) {
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
        // The Delete tool works at selection's granularity
        // (part 5.1): the tapped SEGMENT goes and the track
        // splits at the gap — KiCad's delete does the same.
        if let hit = spatialIndex?.segmentAt(
            model, point: point, tolerance: tolerance,
            allowedTraceIDs: Set(model.traces
                .filter { visibility.traceShown($0) }.map(\.id)))
            ?? BoardGeometry.segmentAt(
                model.traces.filter { visibility.traceShown($0) },
                point: point, tolerance: tolerance) {
            selectOnly(.segment(hit.trace.id, hit.index))
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
           let component = spatialIndex?.componentAt(model, point: point)
               ?? BoardGeometry.componentAt(model, point: point) {
            selectOnly(.component(component.reference))
            deleteSelection()
        }
    }

    /// Delete the WHOLE selection (part 5: group delete covers
    /// components, traces, vias, zones and graphics together.
    /// Part 5.1: segments and corners join in — a deleted segment
    /// SPLITS its track at the gap (same net/layer/width on both
    /// pieces; the connectivity checks flag the break, which is
    /// the honest result, not a bug), and a deleted corner joins
    /// its two segments into one straight run).
    private func deleteSelection() {
        guard !selections.isEmpty else { return }
        // Locked items refuse deletion (part 5.2): the whole
        // delete stops with a clear message rather than quietly
        // deleting around the locked item.
        let lockedSelected = selections.contains { item in
            switch item {
            case .component(let reference):
                return boardState.isLocked(reference: reference)
            case .trace(let id), .via(let id), .zone(let id),
                 .graphic(let id):
                return boardState.isLocked(id)
            case .segment(let id, _), .vertex(let id, _):
                return boardState.isLocked(id)
            }
        }
        if lockedSelected {
            setStatus("Something in the selection is locked — unlock it first (Lock button in its details) to delete it.",
                      warning: true)
            return
        }
        let doomed = selections
        clearSelection()
        var removedComponents: [String] = []
        var counts: [String] = []
        var splitHappened = false
        // Segment/corner deletions, keyed by trace. A whole-trace
        // deletion of the same id wins over its segment edits.
        let doomedTraceIDs = Set(doomed.compactMap { item -> UUID? in
            if case .trace(let id) = item { return id }
            return nil
        })
        var segmentDeletes: [UUID: Set<Int>] = [:]
        var vertexDelete: (traceID: UUID, index: Int)? = nil
        for item in doomed {
            switch item {
            case .segment(let id, let index) where !doomedTraceIDs.contains(id):
                segmentDeletes[id, default: []].insert(index)
            case .vertex(let id, let index) where !doomedTraceIDs.contains(id):
                // At most one: corner taps always select singly.
                if vertexDelete == nil { vertexDelete = (id, index) }
            default:
                break
            }
        }
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
                case .segment, .vertex:
                    break // handled below, in index order
                }
            }
            // Corner first: removing it merges its two segments,
            // so the doomed segment indices of the same trace
            // remap before the split runs.
            if let vertexDelete,
               let position = state.traces.firstIndex(
                   where: { $0.id == vertexDelete.traceID }) {
                let trace = state.traces[position]
                let v = vertexDelete.index
                if let edited = BoardGeometry.traceWithVertexRemoved(
                    trace, vertex: v) {
                    state.traces[position] = edited
                } else {
                    state.traces.remove(at: position)
                }
                counts.append("corner")
                if let doomed = segmentDeletes[vertexDelete.traceID] {
                    var remapped = Set<Int>()
                    for s in doomed {
                        if v == 0 {
                            // Point 0 and segment 0 went together;
                            // later segments shift down one.
                            if s > 0 { remapped.insert(s - 1) }
                        } else if v == trace.points.count - 1 {
                            // The last point and last segment went
                            // together; earlier segments keep index.
                            if s < v - 1 { remapped.insert(s) }
                        } else if s < v - 1 {
                            remapped.insert(s)
                        } else if s == v - 1 || s == v {
                            // Either half of the merged segment was
                            // doomed: the merged segment is doomed.
                            remapped.insert(v - 1)
                        } else {
                            remapped.insert(s - 1)
                        }
                    }
                    segmentDeletes[vertexDelete.traceID] = remapped
                }
            }
            // Segment splits: each trace's doomed set is applied
            // in ONE pass over its original indices.
            for (id, indices) in segmentDeletes {
                guard let position = state.traces.firstIndex(
                    where: { $0.id == id }) else { continue }
                let pieces = BoardGeometry.tracesByRemovingSegments(
                    state.traces[position], indices: indices)
                if pieces.count != 1
                    || pieces.first?.points != state.traces[position].points {
                    splitHappened = true
                }
                state.traces.replaceSubrange(position...position, with: pieces)
                for _ in indices { counts.append("segment") }
            }
        }
        var parts: [String] = []
        if !removedComponents.isEmpty {
            parts.append("\(removedComponents.joined(separator: ", ")) removed from the board (Sync from Schematic brings them back)")
        }
        if !counts.isEmpty {
            parts.append("\(counts.count) item(s) deleted (\(counts.joined(separator: ", ")))")
        }
        if splitHappened {
            parts.append("the track is split at the gap — Problems flags the break until it's routed again")
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
            case .trace(let id), .segment(let id, _), .vertex(let id, _):
                // A segment or corner stands for its whole trace
                // here: the layer belongs to the trace, so flipping
                // with a segment selected flips its track.
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
        // Locked items refuse flipping (part 5.2).
        if parts.components.contains(where: {
            boardState.isLocked(reference: $0)
        }) || parts.traces.contains(where: { boardState.isLocked($0.id) }) {
            setStatus("Something selected is locked — unlock it first (Lock button in its details) to flip it.",
                      warning: true)
            return
        }
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

    // MARK: - Placement actions (part 5.2)

    /// Selected component references, PRIMARY first (the align
    /// centre anchor), then the rest in model order.
    private var selectedComponentReferencesOrdered: [String] {
        guard let model else { return [] }
        var refs: [String] = []
        if case .component(let ref)? = primarySelection,
           model.components.contains(where: { $0.reference == ref }) {
            refs.append(ref)
        }
        for component in model.components
        where selections.contains(.component(component.reference))
            && !refs.contains(component.reference) {
            refs.append(component.reference)
        }
        return refs
    }

    private func applyAlignment(_ mode: BoardAlignMode) {
        guard let model else { return }
        let refs = selectedComponentReferencesOrdered
        let moves = BoardPlacementTools.alignedOrigins(
            model, references: refs, mode: mode,
            lockedReferences: Set(boardState.lockedReferences))
        guard !moves.isEmpty else {
            setStatus("Nothing to align — the selected footprints are already there (locked ones never move).")
            return
        }
        mutateBoard { state in
            for (reference, origin) in moves {
                state.placements[reference] = origin
            }
        }
        setStatus("\(moves.count) footprint(s) aligned — saved with the board.")
    }

    private func applyDistribution(horizontal: Bool) {
        guard let model else { return }
        let refs = selectedComponentReferencesOrdered
        let moves = BoardPlacementTools.distributedOrigins(
            model, references: refs, horizontal: horizontal,
            lockedReferences: Set(boardState.lockedReferences))
        guard !moves.isEmpty else {
            setStatus("Nothing to distribute — pick at least three unlocked footprints that aren't already evenly spaced.")
            return
        }
        mutateBoard { state in
            for (reference, origin) in moves {
                state.placements[reference] = origin
            }
        }
        setStatus("\(moves.count) footprint(s) spaced evenly — saved with the board.")
    }

    /// Duplicate the selected board items (part 5.2): traces
    /// (a selected segment duplicates its whole trace), vias,
    /// zones, graphics — offset by one grid step; the copies
    /// become the selection. Components aren't duplicated
    /// (they're schematic-owned; a board-only copy would break
    /// the model).
    private func duplicateSelection() {
        let traceIDs = Set(selectedTraces.map(\.id))
            .union(selectedSegments.map(\.trace.id))
        let viaIDs = Set(selections.compactMap { selection -> UUID? in
            if case .via(let id) = selection { return id }
            return nil
        })
        let zoneIDs = Set(selections.compactMap { selection -> UUID? in
            if case .zone(let id) = selection { return id }
            return nil
        })
        let graphicIDs = Set(selections.compactMap { selection -> UUID? in
            if case .graphic(let id) = selection { return id }
            return nil
        })
        guard !traceIDs.isEmpty || !viaIDs.isEmpty
                || !zoneIDs.isEmpty || !graphicIDs.isEmpty else {
            setStatus("Select a track, via, fill or graphic to duplicate — footprints come from the schematic and can't be copied here.",
                      warning: true)
            return
        }
        let offset = FPPoint(x: gridMM, y: gridMM)
        var copies: (traces: [BoardTrace], vias: [BoardVia],
                     zones: [BoardZone], graphics: [BoardGraphicItem])?
        mutateBoard { state in
            copies = state.duplicatedItems(traceIDs: traceIDs,
                                           viaIDs: viaIDs,
                                           zoneIDs: zoneIDs,
                                           graphicIDs: graphicIDs,
                                           offset: offset)
        }
        guard let copies else { return }
        var newSelection: Set<BoardSelection> = []
        for trace in copies.traces { newSelection.insert(.trace(trace.id)) }
        for via in copies.vias { newSelection.insert(.via(via.id)) }
        for zone in copies.zones { newSelection.insert(.zone(zone.id)) }
        for graphic in copies.graphics {
            newSelection.insert(.graphic(graphic.id))
        }
        selections = newSelection
        primarySelection = newSelection.first
        let count = copies.traces.count + copies.vias.count
            + copies.zones.count + copies.graphics.count
        setStatus("\(count) item(s) duplicated, offset by one grid step — saved with the board.")
    }

    /// Lock/unlock one item (part 5.2): locked items refuse
    /// delete, drag and flip until unlocked.
    private func toggleLock(_ selection: BoardSelection) {
        let locked: Bool
        switch selection {
        case .component(let reference):
            locked = boardState.isLocked(reference: reference)
            mutateBoard { state in
                state.setLocked(reference: reference, !locked)
            }
        case .trace(let id):
            locked = boardState.isLocked(id)
            mutateBoard { state in state.setLocked(id, !locked) }
        case .via(let id):
            locked = boardState.isLocked(id)
            mutateBoard { state in state.setLocked(id, !locked) }
        case .zone(let id):
            locked = boardState.isLocked(id)
            mutateBoard { state in state.setLocked(id, !locked) }
        case .graphic(let id):
            locked = boardState.isLocked(id)
            mutateBoard { state in state.setLocked(id, !locked) }
        case .segment, .vertex:
            return
        }
        setStatus(locked
                  ? "Unlocked — it can be moved and deleted again."
                  : "Locked — it can't be moved, flipped or deleted until you unlock it.")
    }

    private func lockRow(_ selection: BoardSelection) -> some View {
        let locked: Bool = {
            switch selection {
            case .component(let reference):
                return boardState.isLocked(reference: reference)
            case .trace(let id), .via(let id), .zone(let id),
                 .graphic(let id):
                return boardState.isLocked(id)
            case .segment, .vertex:
                return false
            }
        }()
        return Button {
            toggleLock(selection)
        } label: {
            Label(locked ? "Unlock" : "Lock",
                  systemImage: locked ? "lock.fill" : "lock.open")
                .font(.callout.weight(.semibold))
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
    }

    /// Mass width edit (part 5.2): set every selected trace to
    /// the typed width in ONE undo step.
    private func applyWidthToSelectedTraces() {
        guard let width = Double(widthDraft.trimmingCharacters(
            in: .whitespaces)), width > 0 else {
            setStatus("Type a width in mm first (for example 0.25), then Apply to All.",
                      warning: true)
            return
        }
        let ids = Set(selectedTraces.map(\.id))
        guard ids.count > 1 else { return }
        mutateBoard { state in
            for index in state.traces.indices
            where ids.contains(state.traces[index].id) {
                state.traces[index].width = width
            }
        }
        setStatus("\(ids.count) tracks set to \(PCBBoardMerger.formatMM(width)) mm wide — saved with the board.")
    }

    /// Mass layer edit (part 5.2): move every selected trace to
    /// one copper layer in ONE undo step.
    private func applyLayerToSelectedTraces(_ layer: String) {
        let ids = Set(selectedTraces.map(\.id))
        guard ids.count > 1 else { return }
        mutateBoard { state in
            for index in state.traces.indices
            where ids.contains(state.traces[index].id) {
                state.traces[index].layer = layer
            }
        }
        setStatus("\(ids.count) tracks moved to \(layer) — saved with the board.")
    }

    // MARK: - Part 5.3 actions (selection ops, cleanup, clipboard, find)

    /// Select / deselect everything carrying the context net
    /// (P2): traces and vias by id, footprints by reference —
    /// BoardNetQueries is the membership source.
    private func selectAllOnNet(deselect: Bool) {
        guard let model, let net = netSelectionContext else { return }
        let query = BoardNetQueries.itemIDs(onNet: net, state: boardState,
                                            model: model)
        var items = Set<BoardSelection>()
        for id in query.traceIDs {
            if let uuid = UUID(uuidString: id) { items.insert(.trace(uuid)) }
        }
        for id in query.viaIDs {
            if let uuid = UUID(uuidString: id) { items.insert(.via(uuid)) }
        }
        for reference in query.references {
            items.insert(.component(reference))
        }
        if deselect {
            selections.subtract(items)
            // Segments/vertices of the net's traces go too.
            selections = selections.filter { item in
                switch item {
                case .segment(let id, _), .vertex(let id, _):
                    return !query.traceIDs.contains(id.uuidString)
                default:
                    return true
                }
            }
            if let primarySelection, !selections.contains(primarySelection) {
                self.primarySelection = selections.first
            }
            setStatus("Deselected \(items.count) item(s) on \(net).")
        } else {
            selections.formUnion(items)
            primarySelection = items.first ?? primarySelection
            setStatus("Selected \(query.traceIDs.count) track(s), "
                      + "\(query.viaIDs.count) via(s) and "
                      + "\(query.references.count) footprint(s) on \(net).")
        }
    }

    /// Select every footprint with at least one unrouted pad
    /// (P3), per BoardConnectivity via BoardNetQueries.
    private func selectUnconnectedFootprints() {
        guard let model else { return }
        let references = BoardNetQueries.unconnectedReferences(
            model: model, copperCount: boardState.copperLayerCount)
        selections = Set(references.map { BoardSelection.component($0) })
        primarySelection = references.first.map { BoardSelection.component($0) }
        nextUnconnectedIndex = 0
        setStatus("\(references.count) unconnected footprints")
    }

    /// Step through the unconnected footprints one at a time
    /// (P3): select + centre each, wrapping around the list.
    private func selectNextUnconnectedFootprint() {
        guard let model else { return }
        let references = BoardNetQueries.unconnectedReferences(
            model: model, copperCount: boardState.copperLayerCount)
        guard !references.isEmpty else {
            setStatus("No unconnected footprints — every pad reaches its net.")
            return
        }
        let index = references.indices.contains(nextUnconnectedIndex)
            ? nextUnconnectedIndex : 0
        let reference = references[index]
        selectOnly(.component(reference))
        centreOnComponent(reference)
        nextUnconnectedIndex = (index + 1) % references.count
        setStatus("Unconnected footprint \(index + 1) of \(references.count): \(reference).")
    }

    // MARK: Move Exactly (P1)

    private var moveExactlySheet: some View {
        let rotation = Double(moveRotationDraft) ?? 0
        let selectionHasFootprints = selections.contains { item in
            if case .component = item { return true }
            return false
        }
        return NavigationStack {
            List {
                Section {
                    Picker("Coordinates", selection: $movePolar) {
                        Text("Cartesian").lineLimit(1).tag(false)
                        Text("Polar").lineLimit(1).tag(true)
                    }
                    .pickerStyle(.segmented)
                    if movePolar {
                        HStack(spacing: 8) {
                            Text("Distance (mm)").lineLimit(1)
                            Spacer(minLength: 0)
                            TextField("Distance", text: $moveDistanceDraft)
                                .keyboardType(.numbersAndPunctuation)
                                .multilineTextAlignment(.trailing)
                        }
                        HStack(spacing: 8) {
                            Text("Angle (°)").lineLimit(1)
                            Spacer(minLength: 0)
                            TextField("Angle", text: $moveAngleDraft)
                                .keyboardType(.numbersAndPunctuation)
                                .multilineTextAlignment(.trailing)
                        }
                    } else {
                        HStack(spacing: 8) {
                            Text("ΔX (mm)").lineLimit(1)
                            Spacer(minLength: 0)
                            TextField("ΔX", text: $moveDeltaXDraft)
                                .keyboardType(.numbersAndPunctuation)
                                .multilineTextAlignment(.trailing)
                        }
                        HStack(spacing: 8) {
                            Text("ΔY (mm)").lineLimit(1)
                            Spacer(minLength: 0)
                            TextField("ΔY", text: $moveDeltaYDraft)
                                .keyboardType(.numbersAndPunctuation)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    HStack(spacing: 8) {
                        Text("Rotation (°)").lineLimit(1)
                        Spacer(minLength: 0)
                        TextField("Rotation", text: $moveRotationDraft)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("Move Exactly")
                } footer: {
                    Text("Rotation is around the selection's centre. Board Y runs down, so angles turn clockwise on screen, as in KiCad.")
                }
                if selectionHasFootprints, rotation != 0 {
                    Section {
                        Text("Footprints move but do not spin — PadCB footprints have no rotation.")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
                Section {
                    Button("Apply") { applyMoveExactly() }
                        .font(.callout.weight(.semibold))
                }
            }
            .navigationTitle("Move Exactly")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showMoveExactly = false }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    /// One undo step: rotate (when asked) around the selection
    /// bounds centre, then translate — BoardTransforms composed
    /// in that order. Footprint origins are seeded into
    /// `placements` first: BoardTransforms moves footprints via
    /// their placements, and a never-moved part has no entry yet
    /// (its origin lives only in the merged model).
    private func applyMoveExactly() {
        guard let centre = selectionBoundsCentre else {
            showMoveExactly = false
            return
        }
        let rotation = Double(moveRotationDraft) ?? 0
        let delta: FPPoint
        if movePolar {
            let distance = Double(moveDistanceDraft) ?? 0
            let angle = Double(moveAngleDraft) ?? 0
            delta = FPPoint(x: distance, y: 0).rotated(degrees: angle)
        } else {
            delta = FPPoint(x: Double(moveDeltaXDraft) ?? 0,
                            y: Double(moveDeltaYDraft) ?? 0)
        }
        let ids = selectionItemIDs
        let modelComponents = model?.components ?? []
        mutateBoard { state in
            for component in modelComponents
            where ids.contains(component.reference)
                && state.placements[component.reference] == nil {
                state.placements[component.reference] = component.origin
            }
            var result = state
            if rotation != 0 {
                result = BoardTransforms.rotated(state: result, itemIDs: ids,
                                                  centre: centre,
                                                  degrees: rotation)
            }
            if delta.x != 0 || delta.y != 0 {
                result = BoardTransforms.translated(state: result, itemIDs: ids,
                                                    dx: delta.x, dy: delta.y)
            }
            state = result
        }
        showMoveExactly = false
        setStatus("Selection moved exactly — Δ \(fmt(delta.x)), \(fmt(delta.y)) mm"
                  + (rotation != 0 ? ", rotated \(fmt(rotation))°" : "")
                  + ". Saved with the board.")
    }

    // MARK: Cleanup sheets (P4/P5)

    private var cleanupOptions: BoardCleanupOptions {
        BoardCleanupOptions(removeDangling: cleanupDangling,
                            removeNullSegments: cleanupNullSegments,
                            mergeCollinear: cleanupMergeCollinear,
                            removeDuplicateVias: cleanupDuplicateVias,
                            removeDisconnected: cleanupDisconnected)
    }

    /// Plain labels for the cleanup report keys, in display order.
    private static let cleanupTrackLabels: [(key: String, label: String)] = [
        ("danglingTracks", "Dangling tracks"),
        ("nullSegments", "Zero-length segments collapsed"),
        ("mergedSegments", "Collinear segments merged"),
        ("duplicateVias", "Duplicate vias removed"),
        ("disconnectedItems", "Disconnected items removed"),
    ]

    private var cleanupTracksSheet: some View {
        // Dry-run preview: the pure cleaner over the CURRENT
        // state — nothing commits until Apply.
        let preview = model.map {
            BoardCleanup.cleanTracksAndVias(state: boardState, model: $0,
                                            options: cleanupOptions).report
        }
        return NavigationStack {
            List {
                Section {
                    Toggle("Remove dangling tracks", isOn: $cleanupDangling)
                    Toggle("Remove zero-length segments", isOn: $cleanupNullSegments)
                    Toggle("Merge collinear segments", isOn: $cleanupMergeCollinear)
                    Toggle("Remove duplicate vias", isOn: $cleanupDuplicateVias)
                    Toggle("Remove disconnected items", isOn: $cleanupDisconnected)
                } header: {
                    Text("Cleanup Tracks & Vias")
                } footer: {
                    Text("Locked items are never touched.")
                }
                Section {
                    if let preview {
                        let rows = Self.cleanupTrackLabels.filter {
                            (preview[$0.key] ?? 0) > 0
                        }
                        if rows.isEmpty {
                            Text("Nothing to clean up with these options.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                                HStack(spacing: 8) {
                                    Text(row.label).font(.callout).lineLimit(1)
                                    Spacer(minLength: 0)
                                    Text("\(preview[row.key] ?? 0)")
                                        .font(.callout.weight(.semibold))
                                        .lineLimit(1)
                                }
                            }
                        }
                    } else {
                        Text("No board loaded.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Preview")
                }
                Section {
                    Button("Apply Cleanup") { applyCleanupTracks() }
                        .font(.callout.weight(.semibold))
                }
            }
            .navigationTitle("Cleanup Tracks & Vias")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showCleanupTracks = false }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    /// Apply = ONE mutateBoard: the cleaner recomputes against
    /// the closure's state, so preview and commit can't drift.
    private func applyCleanupTracks() {
        guard let model else { showCleanupTracks = false; return }
        let options = cleanupOptions
        var report: [String: Int] = [:]
        mutateBoard { state in
            let result = BoardCleanup.cleanTracksAndVias(
                state: state, model: model, options: options)
            state = result.state
            report = result.report
        }
        showCleanupTracks = false
        let total = report.values.reduce(0, +)
        setStatus(total == 0
                  ? "Cleanup ran — nothing needed cleaning."
                  : "Cleanup removed/merged \(total) item(s) — saved with the board.")
    }

    private var cleanupGraphicsSheet: some View {
        let preview = BoardCleanup.cleanGraphics(state: boardState).report
        let rows: [(key: String, label: String)] = [
            ("duplicateGraphics", "Duplicate graphics removed"),
            ("mergedGraphics", "Collinear graphics merged"),
        ]
        return NavigationStack {
            List {
                Section {
                    Text("Removes exact-duplicate graphics and merges collinear touching line graphics on the same layer. Locked items are never touched.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Cleanup Graphics")
                }
                Section {
                    let visibleRows = rows.filter { (preview[$0.key] ?? 0) > 0 }
                    if visibleRows.isEmpty {
                        Text("Nothing to clean up.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(visibleRows.enumerated()), id: \.offset) { _, row in
                            HStack(spacing: 8) {
                                Text(row.label).font(.callout).lineLimit(1)
                                Spacer(minLength: 0)
                                Text("\(preview[row.key] ?? 0)")
                                    .font(.callout.weight(.semibold))
                                    .lineLimit(1)
                            }
                        }
                    }
                } header: {
                    Text("Preview")
                }
                Section {
                    Button("Apply Cleanup") { applyCleanupGraphics() }
                        .font(.callout.weight(.semibold))
                }
            }
            .navigationTitle("Cleanup Graphics")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showCleanupGraphics = false }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func applyCleanupGraphics() {
        var report: [String: Int] = [:]
        mutateBoard { state in
            let result = BoardCleanup.cleanGraphics(state: state)
            state = result.state
            report = result.report
        }
        showCleanupGraphics = false
        let total = report.values.reduce(0, +)
        setStatus(total == 0
                  ? "Cleanup ran — nothing needed cleaning."
                  : "Cleanup removed/merged \(total) graphic(s) — saved with the board.")
    }

    // MARK: Teardrops (P6)

    private func addTeardrops() {
        guard let model else {
            setStatus("No board loaded — teardrops need a board.", warning: true)
            return
        }
        mutateBoard { state in
            state.teardrops = BoardTeardrops.generate(state: state, model: model)
        }
        setStatus("\(boardState.teardrops.count) teardrops on the board — real copper, saved with the board.")
    }

    // MARK: Global Deletions (P13)

    private var globalDeleteSheet: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Tracks", isOn: $globalDeleteTracks)
                    Toggle("Vias", isOn: $globalDeleteVias)
                    Toggle("Zones", isOn: $globalDeleteZones)
                    Toggle("Graphics", isOn: $globalDeleteGraphics)
                    Toggle("Teardrops", isOn: $globalDeleteTeardrops)
                } header: {
                    Text("Delete every item of these classes")
                }
                Section {
                    Toggle("Include locked items", isOn: $globalDeleteIncludeLocked)
                } footer: {
                    Text("Locked items are kept unless this is on. One undo step either way.")
                }
                Section {
                    Button(role: .destructive) { applyGlobalDelete() } label: {
                        Text("Delete")
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                    }
                    .disabled(!globalDeleteTracks && !globalDeleteVias
                              && !globalDeleteZones && !globalDeleteGraphics
                              && !globalDeleteTeardrops)
                }
            }
            .navigationTitle("Global Deletions")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showGlobalDelete = false }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func applyGlobalDelete() {
        var classes = Set<BoardGlobalDeleteClass>()
        if globalDeleteTracks { classes.insert(.tracks) }
        if globalDeleteVias { classes.insert(.vias) }
        if globalDeleteZones { classes.insert(.zones) }
        if globalDeleteGraphics { classes.insert(.graphics) }
        if globalDeleteTeardrops { classes.insert(.teardrops) }
        guard !classes.isEmpty else { return }
        let includeLocked = globalDeleteIncludeLocked
        var counts: [String: Int] = [:]
        mutateBoard { state in
            let result = BoardGlobalDelete.apply(state: state, classes: classes,
                                                 includeLocked: includeLocked)
            state = result.state
            counts = result.counts
        }
        showGlobalDelete = false
        var parts: [String] = []
        for (key, label) in [("tracks", "tracks"), ("vias", "vias"),
                             ("zones", "zones"), ("graphics", "graphics"),
                             ("teardrops", "teardrops")] {
            if let count = counts[key], count > 0 {
                parts.append("\(count) \(label)")
            }
        }
        setStatus(parts.isEmpty
                  ? "Global deletions ran — nothing of those classes to delete."
                  : "Deleted \(parts.joined(separator: ", ")) — saved with the board.")
    }

    // MARK: Swap Layers (P15)

    private func swapLayers() {
        mutateBoard { state in
            state = BoardLayerSwap.swapped(state: state)
        }
        setStatus("Front and back copper swapped — footprints flipped too. Saved with the board.")
    }

    // MARK: Unroute (P14)

    private func unrouteComponent(_ reference: String) {
        guard let model else { return }
        var removedTraces = 0, removedVias = 0
        mutateBoard { state in
            let result = BoardUnroute.removingRouting(
                forReference: reference, state: state, model: model)
            state = result.state
            removedTraces = result.removedTraces
            removedVias = result.removedVias
        }
        setStatus("Removed \(removedTraces) tracks, \(removedVias) vias connected to \(reference).")
    }

    private func unrouteTrace(_ trace: BoardTrace) {
        guard let model else { return }
        var removedTraces = 0, removedVias = 0
        mutateBoard { state in
            let result = BoardUnroute.removingRouting(
                fromTraceID: trace.id, state: state, model: model)
            state = result.state
            removedTraces = result.removedTraces
            removedVias = result.removedVias
        }
        setStatus("Removed \(removedTraces) tracks, \(removedVias) vias from that track.")
    }

    // MARK: Clipboard (P11)

    private func copySelectionToClipboard() {
        let slice = BoardClipboard.extract(state: boardState,
                                           itemIDs: selectionItemIDs)
        guard !slice.isEmpty else {
            setStatus("Nothing to copy — footprints come from the schematic and aren't copied; select tracks, vias, fills, graphics or teardrops.",
                      warning: true)
            return
        }
        clipboardSlice = slice
        let count = slice.traces.count + slice.vias.count + slice.zones.count
            + slice.graphics.count + slice.teardrops.count
        setStatus("Copied \(count) items — choose Paste, then tap where they should land.")
    }

    /// The armed paste's commit: ONE mutateBoard, the pasted
    /// items become the new selection, paste disarms.
    private func commitPaste(at point: FPPoint) {
        guard let slice = clipboardSlice else {
            pasteArmed = false
            return
        }
        var newIDs: [String] = []
        mutateBoard { state in
            let result = BoardClipboard.pasted(
                into: state, slice: slice,
                anchorOffset: FPPoint(x: point.x - slice.boundsOrigin.x,
                                      y: point.y - slice.boundsOrigin.y))
            state = result.state
            newIDs = result.newIDs
        }
        pasteArmed = false
        var pasted = Set<BoardSelection>()
        for idString in newIDs {
            guard let uuid = UUID(uuidString: idString),
                  let item = boardSelection(forItemUUID: uuid) else { continue }
            pasted.insert(item)
        }
        selections = pasted
        primarySelection = pasted.first
        setStatus("Pasted \(newIDs.count) items — they are the new selection.")
    }

    /// Resolve a bare item UUID to its selection case (teardrops
    /// have no selection case and resolve to nil).
    private func boardSelection(forItemUUID uuid: UUID) -> BoardSelection? {
        guard let model else { return nil }
        if model.traces.contains(where: { $0.id == uuid }) { return .trace(uuid) }
        if model.vias.contains(where: { $0.id == uuid }) { return .via(uuid) }
        if model.zones.contains(where: { $0.id == uuid }) { return .zone(uuid) }
        if model.graphics.contains(where: { $0.id == uuid }) { return .graphic(uuid) }
        return nil
    }

    // MARK: PCB Find (P12)

    private var findSheet: some View {
        let hits = model.map { BoardFind.hits(model: $0, query: findQuery) } ?? []
        return NavigationStack {
            List {
                Section {
                    TextField("Reference, value or net name", text: $findQuery)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    if findQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("Type to search this board's footprints and nets.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else if hits.isEmpty {
                        Text("No matches on this board.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(hits.enumerated()), id: \.offset) { _, hit in
                            Button {
                                applyFindHit(hit)
                                showFind = false
                            } label: {
                                HStack(spacing: 8) {
                                    Text(hit.text)
                                        .font(.callout.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                    Text(hit.kind == .net
                                         ? "net · at \(hit.reference)"
                                         : (hit.kind == .value
                                            ? "value · \(hit.reference)"
                                            : "reference"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text("Results")
                }
            }
            .navigationTitle("Find")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showFind = false }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func applyFindHit(_ hit: BoardFindHit) {
        switch hit.kind {
        case .reference, .value:
            selectOnly(.component(hit.reference))
            centreOnComponent(hit.reference)
            setStatus("Found \(hit.reference) — selected and centred.")
        case .net:
            highlightedNet = hit.text
            centreOnComponent(hit.reference)
            setStatus("Highlighting \(hit.text) — centred on \(hit.reference).")
        }
    }

    // MARK: Update Footprints from Library (P10)

    /// Re-pull footprint geometry from the CURRENT library —
    /// for every component, or (onlyReference) just one — then
    /// re-merge the board state over the refreshed base model,
    /// the same stack handling Sync uses: this is a model
    /// refresh, not a board edit, so it runs OUTSIDE mutateBoard
    /// and RESETS the undo stacks (the old snapshots describe a
    /// model that no longer exists).
    private func updateFootprintsFromLibrary(onlyReference: String? = nil) {
        guard let baseModel, let model else { return }
        let refreshed = PCBBoardModelBuilder.refreshed(model: baseModel,
                                                       store: footprintStore)
        var newBase = refreshed
        if let onlyReference {
            // Compose a base where ONLY that component's entry
            // comes from the refreshed model.
            newBase = baseModel
            if let index = newBase.components.firstIndex(
                where: { $0.reference == onlyReference }),
               let fresh = refreshed.components.first(
                where: { $0.reference == onlyReference }) {
                newBase.components[index] = fresh
            }
        }
        // Pad binding diff for the single-component case,
        // compared on the merged models (what's on screen).
        var padReport = ""
        if let onlyReference,
           let before = model.components.first(
            where: { $0.reference == onlyReference }) {
            let beforePads = Set((before.footprint?.pads ?? [])
                .map(\.number).filter { !$0.isEmpty })
            let mergedPreview = PCBBoardMerger.apply(
                state: boardState, to: newBase, isSync: false).model
            if let after = mergedPreview.components.first(
                where: { $0.reference == onlyReference }) {
                let afterPads = Set((after.footprint?.pads ?? [])
                    .map(\.number).filter { !$0.isEmpty })
                let added = afterPads.subtracting(beforePads).count
                let removed = beforePads.subtracting(afterPads).count
                padReport = " — \(added) pad(s) added, \(removed) removed for \(onlyReference)"
            }
        }
        let merged = PCBBoardMerger.apply(state: boardState, to: newBase,
                                          isSync: false)
        self.baseModel = newBase
        boardState = merged.stateToSave
        self.model = merged.model
        try? BoardStateStore.save(boardState, tableStem: tableStem)
        undoStack = []
        redoStack = []
        cancelInProgress()
        selections = selections.filter {
            selectionExists($0, in: merged.model)
        }
        if let primarySelection,
           !selectionExists(primarySelection, in: merged.model) {
            self.primarySelection = selections.first
        }
        visibility.copperLayerCount = merged.stateToSave.copperLayerCount
        refreshChecks()
        if let onlyReference {
            setStatus("\(onlyReference) footprint updated from the library\(padReport). Undo history was reset by the refresh.")
        } else {
            setStatus("Footprints updated from the library — placements, sides and routing kept. Undo history was reset by the refresh.")
        }
    }

    // MARK: Netclasses (P16)

    private func toggleRatsnestHidden(_ net: String) {
        mutateBoard { state in
            if state.ratsnestHiddenNets.contains(net) {
                state.ratsnestHiddenNets.removeAll { $0 == net }
            } else {
                state.ratsnestHiddenNets.append(net)
            }
        }
    }

    private func assignNetClass(_ net: String, className: String?) {
        mutateBoard { state in
            state.assignNetClass(net: net, className: className)
        }
        setStatus(className.map {
            "\(net) is now in netclass \($0) — routing starts at its width and its clearance applies."
        } ?? "\(net) has no netclass now.")
    }

    private var netClassesSheet: some View {
        NavigationStack {
            List {
                if boardState.netClasses.isEmpty {
                    Section {
                        Text("No netclasses yet. Add one below — a class gives its nets a starting track width and their own clearance.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ForEach(boardState.netClasses, id: \.name) { netClass in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(netClass.name)
                                        .font(.callout.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    Text("Width \(PCBBoardMerger.formatMM(netClass.trackWidthMM)) mm · clearance \(PCBBoardMerger.formatMM(netClass.clearanceMM)) mm")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Button("Edit") {
                                    netClassEditingName = netClass.name
                                    netClassNameDraft = netClass.name
                                    netClassWidthDraft = PCBBoardMerger.formatMM(netClass.trackWidthMM)
                                    netClassClearanceDraft = PCBBoardMerger.formatMM(netClass.clearanceMM)
                                }
                                .font(.callout.weight(.semibold))
                                .lineLimit(1)
                                Button("Delete", role: .destructive) {
                                    mutateBoard { state in
                                        state.deleteNetClass(named: netClass.name)
                                    }
                                    if netClassEditingName == netClass.name {
                                        netClassEditingName = nil
                                        netClassNameDraft = ""
                                    }
                                    setStatus("Netclass \(netClass.name) deleted — its nets are unassigned.")
                                }
                                .font(.callout.weight(.semibold))
                                .lineLimit(1)
                            }
                        }
                    } header: {
                        Text("Netclasses")
                    }
                }
                Section {
                    TextField("Name", text: $netClassNameDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack(spacing: 8) {
                        Text("Track width (mm)").lineLimit(1)
                        Spacer(minLength: 0)
                        TextField("Width", text: $netClassWidthDraft)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack(spacing: 8) {
                        Text("Clearance (mm)").lineLimit(1)
                        Spacer(minLength: 0)
                        TextField("Clearance", text: $netClassClearanceDraft)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    Button(netClassEditingName == nil ? "Add Class" : "Save Class") {
                        saveNetClassDraft()
                    }
                    .font(.callout.weight(.semibold))
                    if netClassEditingName != nil {
                        Button("Stop Editing") {
                            netClassEditingName = nil
                            netClassNameDraft = ""
                        }
                        .font(.callout)
                    }
                } header: {
                    Text(netClassEditingName == nil ? "Add a class" : "Edit class")
                } footer: {
                    Text("Renaming a class keeps its nets — they are reassigned to the new name in the same step.")
                }
            }
            .navigationTitle("Netclasses")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showNetClasses = false }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    /// Add a class, or save an edit. A rename is upsert-new +
    /// reassign the old class's nets + delete-old, inside ONE
    /// mutateBoard (one undo step).
    private func saveNetClassDraft() {
        let name = netClassNameDraft.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty,
              let width = Double(netClassWidthDraft), width > 0,
              let clearance = Double(netClassClearanceDraft), clearance >= 0
        else {
            setStatus("A netclass needs a name, a width over 0 and a clearance of 0 or more.",
                      warning: true)
            return
        }
        let newClass = NetClass(name: name, trackWidthMM: width,
                                clearanceMM: clearance)
        if let oldName = netClassEditingName, oldName != name {
            mutateBoard { state in
                state.upsertNetClass(newClass)
                let netsToMove = state.netClassByNet
                    .filter { $0.value == oldName }.map(\.key)
                for net in netsToMove {
                    state.assignNetClass(net: net, className: name)
                }
                state.deleteNetClass(named: oldName)
            }
            setStatus("Netclass \(oldName) renamed to \(name) — its nets kept the class.")
        } else {
            mutateBoard { state in state.upsertNetClass(newClass) }
            setStatus("Netclass \(name) saved — width \(PCBBoardMerger.formatMM(width)) mm, clearance \(PCBBoardMerger.formatMM(clearance)) mm.")
        }
        netClassEditingName = nil
        netClassNameDraft = ""
    }

    // MARK: Zoom to Selection (P17)

    /// Frame exactly the current selection (Fit Board's math
    /// over the selection's own bounds, pads included).
    private func zoomToSelection() {
        let points = selectionGeometryPoints(includePads: true)
        guard let first = points.first else {
            setStatus("Select something first — Zoom to Selection frames the selection.",
                      warning: true)
            return
        }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for point in points {
            minX = min(minX, point.x); minY = min(minY, point.y)
            maxX = max(maxX, point.x); maxY = max(maxY, point.y)
        }
        frameBoardRect(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
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
        // Geometry (pad snap, grid snap, net refusal) resolves
        // through the route head (part 5.2): while routing, the
        // tap commits the SAME stateful resolution the hover
        // preview renders — hysteresis included — so the segment
        // Sean sees while hovering is the segment the tap
        // commits; starting a route uses the pure resolution.
        switch routeHead.tapResolution(
            model, from: routePoints.last, point: point,
            routingActive: routingActive, routeNet: routeNet,
            snapEnabled: snapEnabled, gridMil: boardState.gridMil,
            tolerance: tapToleranceMM) {
        case .needsPad:
            setStatus("Tap a pad to start the track.", warning: true)
        case .startPad(let target):
            routeHead.reset()
            routeNet = target.netName
            routePoints = [target.center]
            // Netclass width (part 5.3, P16): a route on a net
            // with a class starts at the class's track width.
            if let net = target.netName,
               let classWidth = BoardNetClasses.defaultTrackWidthMM(
                   forNet: net, boardState: boardState) {
                currentTrackWidth = classWidth
            }
            refreshRoutePreview()
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
            appendRoutePoint(target.center,
                              corner: routePreviewCache?.corner)
            finishRoute()
        case .appendPoint(let snapped):
            appendRoutePoint(snapped, corner: routePreviewCache?.corner)
        }
    }

    /// Append a point to the in-progress track, inserting the
    /// 45° corner. `corner` carries the preview's corner when
    /// the caller resolved one through the head (part 5.2);
    /// other callers get the pure routeCorner.
    private func appendRoutePoint(_ point: FPPoint, corner: FPPoint? = nil) {
        guard let last = routePoints.last else {
            routePoints = [point]
            refreshRoutePreview()
            return
        }
        if let corner = corner ?? BoardGeometry.routeCorner(from: last, to: point) {
            routePoints.append(corner)
        }
        if point != last { routePoints.append(point) }
        refreshRoutePreview()
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

    /// The points a trace is DRAWN with: the live preview points
    /// while a corner/segment drag is reshaping it (part 5.1),
    /// else its saved points.
    private func displayTracePoints(_ trace: BoardTrace) -> [FPPoint] {
        if editDragTraceID == trace.id, let preview = editDragPreviewPoints {
            return preview
        }
        return trace.points
    }

    /// True when the primary selection is a corner of this trace
    /// (part 5.1): the whole track gets the selection underlay as
    /// context, the corner itself is marked by its handle.
    private func isVertexPrimary(_ traceID: UUID) -> Bool {
        if case .vertex(let id, _)? = primarySelection { return id == traceID }
        return false
    }

    /// The STATIC board layer's drawing (part 5.2): everything
    /// except the pointer-driven previews, which live on their
    /// own layer above (drawPreviews). Reads no pointer state.
    private func drawStaticBoard(ctx: GraphicsContext, size: CGSize, model: BoardModel) {
        var ctx = ctx
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .color(Color(red: 0.043, green: 0.055, blue: 0.043)))
        if showGrid { drawGridDots(&ctx, size: size) }

        // Board graphics (drawings) under everything else.
        for item in model.graphics where item.kind != .text
            && visibility.boardGraphicShown(item) {
            // Inactive-layer mode (part 5.3, P9): off-active
            // graphics dim or vanish with the mode.
            guard let factor = inactiveFactor(forLayer: item.layer)
            else { continue }
            var graphicCtx = ctx
            graphicCtx.opacity = factor
            drawBoardGraphic(&graphicCtx, item: item)
        }
        // Copper fills (part 5) under traces and pads, with the
        // clearance gap cut around foreign-net copper.
        for zone in model.zones where visibility.zoneShown(zone) {
            drawZone(&ctx, zone: zone, model: model)
        }
        // Teardrops (part 5.3, P6): real copper polygons in
        // their layer's colour, translucent like the zones,
        // under the traces they flare from.
        drawTeardrops(&ctx, model: model)
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
            guard let factor = inactiveFactor(forLayer: item.layer)
            else { continue }
            var graphicCtx = ctx
            graphicCtx.opacity = factor
            drawBoardGraphic(&graphicCtx, item: item)
        }
        // Selection overlay for a chosen graphic.
        if let graphic = selectedGraphic,
           visibility.boardGraphicShown(graphic) {
            drawGraphicOverlay(&ctx, item: graphic)
        }
        // Ratsnest (part 5.2): the unrouted connections, under
        // the preview layer's work.
        if visibility.showRatsnest { drawRatsnest(&ctx, model: model) }
    }

    /// Teardrop polygons (part 5.3, P6): filled in their layer's
    /// copper colour at zone-like translucency, dimmed with
    /// their net under a net highlight, and subject to the
    /// inactive-layer mode like every other copper item. They
    /// live in BoardState (and the merged model's teardrops), so
    /// the static token's boardState + renderVersion already
    /// force a redraw whenever they change.
    private func drawTeardrops(_ ctx: inout GraphicsContext, model: BoardModel) {
        for teardrop in model.teardrops where teardrop.points.count >= 3 {
            guard visibility.layerShown(teardrop.layer) else { continue }
            guard let factor = inactiveFactor(forLayer: teardrop.layer)
            else { continue }
            var path = Path()
            for (index, point) in teardrop.points.enumerated() {
                let screen = boardToScreen(point)
                if index == 0 { path.move(to: screen) }
                else { path.addLine(to: screen) }
            }
            path.closeSubpath()
            var alpha = 0.65 * factor
            if let highlightedNet, teardrop.netName != highlightedNet {
                alpha *= 0.4
            }
            ctx.opacity = alpha
            ctx.fill(path, with: .color(copperColor(teardrop.layer)))
            ctx.opacity = 1
        }
    }

    /// Ratsnest lines (part 5.2): one thin line per MST link
    /// between unconnected pad groups, computed by
    /// BoardRatsnest alongside the checks. With a net
    /// highlighted, only that net's lines draw.
    private func drawRatsnest(_ ctx: inout GraphicsContext, model: BoardModel) {
        guard !ratsnestSegments.isEmpty else { return }
        var path = Path()
        for segment in ratsnestSegments {
            if let highlightedNet, segment.netName != highlightedNet {
                continue
            }
            path.move(to: boardToScreen(segment.from))
            path.addLine(to: boardToScreen(segment.to))
        }
        ctx.stroke(path, with: .color(Color(red: 0.55, green: 0.85, blue: 1.0)
                                      .opacity(0.5)),
                   style: StrokeStyle(lineWidth: 0.8))
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
            // Inactive-layer mode (part 5.3, P9) for traces:
            // Normal keeps the legacy always-on 0.55 dimming of
            // off-active traces; Dim uses the uniform 0.35;
            // Hide skips off-active traces entirely (selection
            // underlay included).
            let traceFactor: Double
            switch inactiveLayerMode {
            case .normal:
                traceFactor = trace.layer != activeLayer ? 0.55 : 1
            case .dim:
                traceFactor = trace.layer != activeLayer ? 0.35 : 1
            case .hide:
                if trace.layer != activeLayer { continue }
                traceFactor = 1
            }
            let isSelected = selections.contains(.trace(trace.id))
                || isVertexPrimary(trace.id)
            var path = Path()
            for (index, point) in displayTracePoints(trace).enumerated() {
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
            alpha *= traceFactor
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
        // Selected segments (part 5.1) draw OVER the batched
        // pass with a hot core, so ONE segment reads as the
        // selection — not the whole track running under it.
        for selected in selectedSegments {
            let trace = selected.trace
            guard visibility.traceShown(trace) else { continue }
            if inactiveLayerMode == .hide, trace.layer != activeLayer {
                continue
            }
            let points = displayTracePoints(trace)
            var path = Path()
            path.move(to: boardToScreen(points[selected.index]))
            path.addLine(to: boardToScreen(points[selected.index + 1]))
            let width = max(1.2, CGFloat(trace.width * scale))
            ctx.stroke(path, with: .color(.white.opacity(0.9)),
                       style: StrokeStyle(lineWidth: width + 5, lineCap: .round))
            ctx.stroke(path, with: .color(Color(red: 1.0, green: 0.85, blue: 0.2)),
                       style: StrokeStyle(lineWidth: width + 1.5, lineCap: .round))
        }
    }

    // MARK: Vias + zones drawing (part 5)

    private func drawVia(_ ctx: inout GraphicsContext, via: BoardVia) {
        // Inactive-layer mode (part 5.3, P9): a via spans every
        // copper layer, so it counts as "on" the active layer
        // whenever the active layer is copper at all.
        let viaFactor: Double?
        switch inactiveLayerMode {
        case .normal: viaFactor = 1
        case .dim: viaFactor = BoardLayers.isCopper(activeLayer) ? 1 : 0.35
        case .hide: viaFactor = BoardLayers.isCopper(activeLayer) ? 1 : nil
        }
        guard let viaFactor else { return }
        let centreBoard = displayViaCenter(via)
        let centre = boardToScreen(centreBoard)
        let r = CGFloat(via.diameter / 2 * scale)
        let drillR = CGFloat(via.drill / 2 * scale)
        var alpha = viaFactor
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
        // Inactive-layer mode (part 5.3, P9) for fills.
        guard let zoneFactor = inactiveFactor(forLayer: zone.layer)
        else { return }
        var path = Path()
        for (index, point) in zone.points.enumerated() {
            let screen = boardToScreen(point)
            if index == 0 { path.move(to: screen) } else { path.addLine(to: screen) }
        }
        path.closeSubpath()
        var alpha = 0.45 * zoneFactor
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

    /// The PREVIEW layer's drawing (part 5.2): everything the
    /// pointer drives — the routing head, zone/draw previews,
    /// the hover highlight, vertex handles, the measure readout.
    /// The pointer arrives as a parameter from the canvas host
    /// (the one pointer stream: the touch point while a touch
    /// is down, else the Apple Pencil hover point).
    private func drawPreviews(ctx: GraphicsContext, size: CGSize,
                              model: BoardModel, pointer: BoardPointerState) {
        var ctx = ctx
        let pointerPoint = pointer.currentPoint
        // Routing: laid points + the 45° preview head to the
        // pointer. The head comes from the CACHE the pointer
        // events maintain (BoardRouteHead — the stateful,
        // hysteresis-carrying resolution, part 5.2), and a tap
        // commits through the same head, so the segment Sean
        // sees while hovering is the segment the tap commits.
        if routingActive {
            var points = routePoints
            let preview = routePreviewCache
            if let preview {
                if let corner = preview.corner { points.append(corner) }
                points.append(preview.endPoint)
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
            if let pointerPoint { points.append(snapPoint(pointerPoint)) }
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
        if !pendingPoints.isEmpty, let pointerPoint {
            let cursor = snapPoint(pointerPoint)
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
        if !routingActive, !pointer.touchActive, let pointerPoint,
           let hover = spatialIndex?.hoverTarget(
               model, point: pointerPoint, tolerance: tapToleranceMM)
               ?? BoardGeometry.hoverTarget(
                   model, point: pointerPoint, tolerance: tapToleranceMM) {
            switch hover {
            case .pad(let target):
                drawPadHoverRing(&ctx, target: target, refused: false)
            case .trace(let id):
                if activeTool == .select,
                   let segment = spatialIndex?.segmentAt(
                       model, point: pointerPoint, tolerance: tapToleranceMM,
                       allowedTraceIDs: Set(model.traces
                           .filter { visibility.traceShown($0) }
                           .map(\.id)))
                       ?? BoardGeometry.segmentAt(
                           model.traces.filter { visibility.traceShown($0) },
                           point: pointerPoint, tolerance: tapToleranceMM),
                   segment.trace.id == id {
                    // Segment hover (part 5.1): in the Select
                    // tool the segment is the unit of work, so
                    // the hover light covers just the segment a
                    // tap would select — the v5.0.1 whole-trace
                    // hover light, narrowed to the segment.
                    let points = segment.trace.points
                    var path = Path()
                    path.move(to: boardToScreen(points[segment.index]))
                    path.addLine(to: boardToScreen(points[segment.index + 1]))
                    ctx.stroke(path, with: .color(.white.opacity(0.55)),
                               style: StrokeStyle(
                                   lineWidth: max(1.2, CGFloat(segment.trace.width * scale)) + 3,
                                   lineCap: .round))
                } else if let trace = model.traces.first(where: { $0.id == id }),
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
        // Vertex handles (part 5.1): while a track is being
        // edited in the Select tool, its corners show as round
        // handles — drag one to bend the track. The chosen corner
        // (when the primary selection IS a corner) is orange and
        // larger. Handles follow the live drag preview points.
        if activeTool == .select, let id = editTraceID,
           let trace = model.traces.first(where: { $0.id == id }),
           visibility.traceShown(trace) {
            let points = displayTracePoints(trace)
            for (index, point) in points.enumerated() {
                let screen = boardToScreen(point)
                let isChosen = selectedVertex?.trace.id == id
                    && selectedVertex?.index == index
                let radius: CGFloat = isChosen ? 5.5 : 4
                let rect = CGRect(x: screen.x - radius, y: screen.y - radius,
                                  width: 2 * radius, height: 2 * radius)
                ctx.fill(Path(ellipseIn: rect),
                         with: .color(isChosen ? .orange : .white))
                ctx.stroke(Path(ellipseIn: rect),
                           with: .color(.black.opacity(0.65)),
                           style: StrokeStyle(lineWidth: 1))
            }
        }
        // Measure tool (part 5.2): the two tapped points, their
        // line, and the distance/delta label.
        if let a = measure.a {
            var path = Path()
            let screenA = boardToScreen(a)
            path.addEllipse(in: CGRect(x: screenA.x - 4, y: screenA.y - 4,
                                       width: 8, height: 8))
            if let b = measure.b {
                let screenB = boardToScreen(b)
                path.move(to: screenA)
                path.addLine(to: screenB)
                path.addEllipse(in: CGRect(x: screenB.x - 4,
                                           y: screenB.y - 4,
                                           width: 8, height: 8))
            }
            ctx.stroke(path, with: .color(.yellow),
                       style: StrokeStyle(lineWidth: 1.4))
            if let distance = measure.distance, let delta = measure.delta,
               let b = measure.b {
                let mid = boardToScreen(FPPoint(x: (a.x + b.x) / 2,
                                                y: (a.y + b.y) / 2))
                let text = Text("\(fmt(distance)) mm"
                                + "  (Δx \(fmt(delta.x)), Δy \(fmt(delta.y)))")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.yellow)
                ctx.draw(text, at: CGPoint(x: mid.x, y: mid.y - 14),
                         anchor: .center)
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
                // Inactive-layer mode (part 5.3, P9) applies to
                // footprint graphics too, by their effective layer.
                guard let factor = inactiveFactor(forLayer: effective.layer)
                else { continue }
                var graphicCtx = ctx
                graphicCtx.opacity = factor
                drawGraphic(&graphicCtx, graphic: effective,
                            origin: component.origin)
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
        // the inactive-layer factor (part 5.3, P9 — which folds
        // in the old "Highlight layer" 0.4 dimming in Normal
        // mode, and skips the pad entirely in Hide mode when it
        // doesn't touch the active layer) does the rest.
        var alpha = 1.0
        let net = BoardGeometry.netName(component, pad)
        if let highlightedNet, net != highlightedNet { alpha *= 0.3 }
        guard let factor = padInactiveFactor(effective) else { return }
        alpha *= factor

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

/// Diagnostics output for the hover channels (part 5.0.2):
/// always to stdout; when the process was launched with
/// `-padcbHoverCheck` (the simulator hover exercise), ALSO
/// appended to Documents/hover-markers.txt — the exercise reads
/// the counters back from the app container, immune to stdio
/// buffering in the console stream. A normal launch never
/// touches the file.
/// Exercise-only probe output (part 5.0.3): unlike
/// `padcbHoverPrint` (which always prints to stdout), this does
/// NOTHING unless the process was launched with
/// `-padcbHoverCheck`, so production gesture handlers can call
/// it unconditionally. Used to prove — in the simulator exercise
/// — that the SwiftUI canvas gestures still receive touches
/// whose hit view is the frontmost interaction view, and that
/// the interaction view IS the hit-test result over the canvas.
func padcbProbePrint(_ message: String) {
    guard ProcessInfo.processInfo.arguments
        .contains("-padcbHoverCheck") else { return }
    padcbHoverPrint(message)
}

func padcbHoverPrint(_ message: String) {
    print(message)
    guard ProcessInfo.processInfo.arguments
        .contains("-padcbHoverCheck") else { return }
    let url = PadCBPaths.documentsDirectory
        .appendingPathComponent("hover-markers.txt")
    let line = message + "\n"
    if let handle = try? FileHandle(forWritingTo: url) {
        _ = handle.seekToEndOfFile()
        if let data = line.data(using: .utf8) { handle.write(data) }
        try? handle.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Board interaction surface (part 5.0.3)

/// The PCB canvas's ONE UIKit interaction view — frontmost over
/// the canvas rect, the hit view for hover AND touches alike,
/// with the UIHoverGestureRecognizer attached DIRECTLY to it.
/// This is channel 1, the primary hover delivery channel.
///
/// Why this shape (the third round of hover delivery):
/// - v5.0.1: a hit-test-transparent overlay (hitTest → nil). Its
///   own recognizer was DEAD BY CONSTRUCTION — a view excluded
///   from hit-testing is excluded from HOVER hit-testing too —
///   and recognizers lent to its first ancestors were a gamble
///   on SwiftUI's private hierarchy (CONTRACTS.md, "Part 5.0.2
///   forensics").
/// - v5.0.2: three worked-around channels — the overlay made
///   hover-only-hit-testable, a background probe walking to the
///   hosting root, SwiftUI's feed. Sean's Pencil Pro STILL
///   reported no hover (2026-11-01 21:37).
/// - v5.0.3: stop working around the hierarchy; OWN it. This
///   view is the top layer of the canvas stack, so it is the
///   deepest hit view over the canvas rect BY CONSTRUCTION.
///   `hitTest` returns SELF for every event whose point is
///   inside the canvas bounds — hover events and touch events
///   alike, with NO branching on the event type — so iPadOS
///   hover hit-testing lands here for the same reason touch
///   hit-testing does, and the recognizer attached directly to
///   this view (Apple's canonical pattern: the recognizer on
///   the canvas surface view itself) is in the hit chain.
///
/// Touches: this view consumes NOTHING. It overrides no touch
/// handler (touchesBegan/Moved/Ended/Cancelled), so UIView's
/// default implementation forwards every touch up the responder
/// chain untouched, and it carries NO touch gesture recognizer
/// (the hover recognizer never cancels touches). The editor's
/// SwiftUI drag + magnification gestures are attached to the
/// COMPOSITE view (canvas + this view) — an ancestor of this
/// view — so they receive these touches through the standard
/// gesture-delivery phase, exactly as they received touches
/// whose hit view was the canvas itself. The simulator exercise
/// proves this with PADCB-GESTURE markers (tap, pan, pinch)
/// plus the PADCB-PROBE hit-test line below. The rail, panels
/// and Finish button live OUTSIDE the canvas rect and are never
/// under this view.
///
/// Callbacks deliver canvas-space points (or nil when the hover
/// leaves the canvas or ends); the editor tags them
/// `.interaction`, converts to board coordinates, and feeds the
/// one pointer stream. Hover outside the canvas bounds reports
/// nil — no prospective path is drawn off the grid.
private struct BoardInteractionView: UIViewRepresentable {
    var onHover: (CGPoint?) -> Void

    func makeUIView(context: Context) -> InteractionView {
        let view = InteractionView()
        view.onHover = onHover
        return view
    }

    func updateUIView(_ view: InteractionView, context: Context) {
        view.onHover = onHover
    }

    static func dismantleUIView(_ view: InteractionView,
                                coordinator: ()) {
        view.detach()
    }

    final class InteractionView: UIView {
        var onHover: ((CGPoint?) -> Void)?
        private var hoverRecognizer: UIHoverGestureRecognizer?
        private var hoverInside = false
        private var armedLogged = false
        private var probeLogged = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            // The recognizer on the surface view itself — no
            // lending, no ancestor walks.
            let recognizer = UIHoverGestureRecognizer(
                target: self, action: #selector(handleHover(_:)))
            addGestureRecognizer(recognizer)
            hoverRecognizer = recognizer
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        /// THE hit view over the canvas — for hover AND touch
        /// events alike. No event-type branching: a point inside
        /// the canvas bounds hits this view, a point outside
        /// falls through to whatever is beyond the canvas. (The
        /// exercise's hit-test probe passes a NIL event and must
        /// get this same answer — with no branching, it does.)
        override func hitTest(_ point: CGPoint,
                              with event: UIEvent?) -> UIView? {
            bounds.contains(point) ? self : nil
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil && !armedLogged {
                armedLogged = true
                padcbHoverPrint("PADCB-HOVER armed ch=1"
                    + " (interaction view, frontmost over canvas)")
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            runHitTestProbeIfNeeded()
        }

        /// Structural proof for the simulator exercise: this
        /// view IS the window's hit-test result at the canvas
        /// centre, and the hover recognizer is attached to it.
        /// `hitTest` does not branch on the event, so the answer
        /// with a nil event is the hover answer too — by
        /// construction, not by analogy.
        private func runHitTestProbeIfNeeded() {
            guard !probeLogged, window != nil,
                  bounds.width > 0, bounds.height > 0 else { return }
            probeLogged = true
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                let centre = CGPoint(x: self.bounds.midX,
                                     y: self.bounds.midY)
                let windowPoint = self.convert(centre, to: window)
                let hit = window.hitTest(windowPoint, with: nil)
                let recognizers = (self.gestureRecognizers ?? [])
                    .map { String(describing: type(of: $0)) }
                padcbHoverPrint("PADCB-PROBE hitTest(centre)="
                    + (hit.map { String(describing: type(of: $0)) }
                        ?? "nil")
                    + " isInteractionView=\(hit === self)"
                    + " recognizers=\(recognizers)")
            }
        }

        func detach() {
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

#if DEBUG
// MARK: - Simulator hover exercise seed (part 5.0.2, DEBUG only)

/// Support for the simulator hover exercise (tools/hover_check.py):
/// a Debug build launched with `-padcbHoverCheck` seeds a tiny
/// fixture connection table through the REAL encrypted store (if
/// none exists) and opens the PCB editor straight onto it, so the
/// exercise can drive the actual editor canvas with the host
/// mouse. Compiled out of Release builds (the hover-check
/// workflow passes SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG;
/// the IPA build does not), and unreachable without the launch
/// argument even in Debug.
enum HoverCheckSeed {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-padcbHoverCheck")
    }

    static func seedIfNeeded() {
        let existing = ConnectionTableStore.availableTables()
        padcbHoverPrint("PADCB-HOVER seed: \(existing.count) table(s) present")
        guard existing.isEmpty else { return }
        let r1 = UUID()
        let r2 = UUID()
        func endpoint(_ id: UUID, _ ref: String, _ pin: String) -> ConnectionEndpoint {
            ConnectionEndpoint(instanceID: id, reference: ref, unit: 1,
                               library: "Device", symbolName: "R",
                               pinNumber: pin, pinName: "~",
                               pinType: "passive")
        }
        func component(_ id: UUID, _ ref: String) -> ConnectionComponent {
            ConnectionComponent(
                instanceID: id, reference: ref, unit: 1,
                library: "Device", symbolName: "R", value: "10k",
                footprintReference: "Resistor_SMD:R_0603_1608Metric",
                resolvedFootprintKey: "Resistor_SMD:R_0603_1608Metric",
                footprintMatchKind: "property")
        }
        let table = ConnectionTable(
            formatVersion: ConnectionTable.currentFormatVersion,
            schematicTitle: "HoverCheck",
            sourceFileName: "HoverCheck.kicad_sch",
            generatedAt: Date(),
            components: [component(r1, "R1"), component(r2, "R2")],
            nets: [
                ConnectionNet(name: "NET_A", aliases: [],
                              endpoints: [endpoint(r1, "R1", "1"),
                                          endpoint(r2, "R2", "1")]),
                ConnectionNet(name: "NET_B", aliases: [],
                              endpoints: [endpoint(r1, "R1", "2"),
                                          endpoint(r2, "R2", "2")]),
            ],
            unresolvedSymbols: [])
        do {
            let url = try ConnectionTableStore.save(
                table,
                forSchematicFile: URL(fileURLWithPath: "HoverCheck.kicad_sch"))
            padcbHoverPrint("PADCB-HOVER seeded fixture table: \(url.lastPathComponent)")
        } catch {
            padcbHoverPrint("PADCB-HOVER seed FAILED: \(error)")
        }
    }
}

/// Root for the hover exercise: seed first, then the real PCB
/// editor (its own tasks bootstrap the stores and load the table
/// through the normal path).
struct HoverCheckRootView: View {
    @State private var seeded = false

    var body: some View {
        Group {
            if seeded {
                PCBEditorView()
            } else {
                ZStack {
                    Color(white: 0.08).ignoresSafeArea()
                    Text("Seeding hover-check board…")
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .task {
            HoverCheckSeed.seedIfNeeded()
            seeded = true
        }
    }
}
#endif
