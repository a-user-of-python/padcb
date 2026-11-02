import Foundation

/// PCB board state (part 4): everything the user has DONE to a board,
/// kept separately from the board model the connection table implies.
///
/// The split is the part-4 design:
/// - `PCBBoardModelBuilder` derives a `BoardModel` from a saved
///   connection table (components, pin↔pad bindings, nets) — the
///   schematic's truth, rebuilt from scratch on every open/sync.
/// - `BoardState` is the user's work on top of it: where components
///   were moved to, which were deleted from the board, the routed
///   traces, the drawn graphics. It persists as one plain-JSON
///   sidecar per table in Documents/Boards (see BoardStateStore).
/// - `PCBBoardMerger` folds a BoardState into a freshly built model.
///   Sync from Schematic is exactly "build a new model, merge the
///   saved state" — placements survive, new parts arrive at their
///   shelf positions, traces keep their net binding BY NAME, and
///   nothing is ever silently dropped: a trace whose net vanished
///   becomes unconnected and is listed in Problems.
///
/// Foundation only, like PCBBoardModel.swift, so the exact code the
/// editor runs compiles into the BoardFixture harness. Board
/// coordinates throughout: millimetres, x right, y DOWN.

// MARK: - Board work items

/// Which side of the board a footprint sits on (part 5). A footprint
/// starts on the front; "Flip Side" moves it to the back, MIRRORED
/// (KiCad's flip: local x negates through the footprint origin, pad
/// angles negate, layers swap F.* <-> B.*) so it behaves as it
/// physically would soldered on the other side.
enum BoardSide: String, Codable, Equatable {
    case front, back
}

/// One placed via (part 5): a plated hole that carries ONE net
/// between copper layers. A via spans every copper layer of the
/// board (through via), so it has a centre, an outer diameter and a
/// drill — no layer of its own.
struct BoardVia: Codable, Equatable, Identifiable {
    var id: UUID
    /// The net this via carries; nil = unconnected.
    var netName: String?
    /// Remembered net name when a merge finds the net gone (the
    /// BoardTrace rule: kept, shown unconnected, rebinds on return).
    var disconnectedNetName: String? = nil
    var center: FPPoint
    /// Outer (annular ring) diameter, mm.
    var diameter: Double
    /// Drill diameter, mm.
    var drill: Double

    /// Standard via sizes offered in the editor (diameter/drill, mm).
    static let sizePresets: [(diameter: Double, drill: Double)] = [
        (0.6, 0.3), (0.8, 0.4), (1.0, 0.5), (1.2, 0.6),
    ]
}

/// One copper fill area / zone (part 5): a closed polygon on ONE
/// copper layer that pours copper for ONE net.
struct BoardZone: Codable, Equatable, Identifiable {
    var id: UUID
    /// The net this zone pours; nil = unconnected.
    var netName: String?
    /// Remembered net name when a merge finds the net gone.
    var disconnectedNetName: String? = nil
    /// Copper layer, e.g. "F.Cu".
    var layer: String
    /// Polygon vertices in board coordinates, at least 3. The
    /// polygon closes implicitly (last point joins the first).
    var points: [FPPoint]
}

/// One routed copper track: a polyline on one copper layer, bound to
/// a net BY NAME. `width` is the copper width in mm — traces are
/// resizeable: the width is data, edited in the editor's detail
/// panel, redrawn immediately, and persisted with the board state.
struct BoardTrace: Codable, Equatable, Identifiable {
    var id: UUID
    /// The net this trace belongs to; nil = unconnected.
    var netName: String?
    /// When a merge finds the trace's net gone from the schematic,
    /// the name is REMEMBERED here (and netName cleared): the trace
    /// shows as unconnected with a Problems entry, and if a later
    /// sync brings the net back, the trace rebinds automatically.
    var disconnectedNetName: String? = nil
    /// Copper layer, e.g. "F.Cu".
    var layer: String
    /// Copper width in mm.
    var width: Double
    /// Polyline points in board coordinates, at least 2.
    var points: [FPPoint]

    /// Total polyline length in mm.
    var length: Double {
        guard points.count > 1 else { return 0 }
        var total = 0.0
        for index in 1..<points.count {
            total += points[index - 1].distance(to: points[index])
        }
        return total
    }
}

/// One drawn board graphic (Draw Line / Draw Arc / Draw Circle /
/// Text tools). Points by kind: line = [start, end];
/// arc = [start, mid, end] (the arc runs through all three);
/// circle = [centre] with `radius`; text = [anchor] with `text`.
struct BoardGraphicItem: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case line, arc, circle, text
    }

    var id: UUID
    var kind: Kind
    /// Drawing layer, e.g. "Dwgs.User", "Edge.Cuts", "F.SilkS".
    var layer: String
    var points: [FPPoint]
    /// Circle radius in mm (0 for other kinds).
    var radius: Double = 0
    /// Stroke width in mm (line/arc/circle).
    var strokeWidth: Double = 0.25
    /// Text payload (text kind only).
    var text: String = ""
    /// Text height in mm (text kind only).
    var textSize: Double = 1.5
}

// MARK: - Board state

/// The persisted board work for one connection table.
struct BoardState: Equatable {
    var formatVersion: Int = 1
    /// Component placements by reference: the board-space position
    /// of the footprint's local origin (the same `origin` the board
    /// model uses). A reference with no entry sits at the builder's
    /// shelf position.
    var placements: [String: FPPoint] = [:]
    /// References the user deleted from the board. The exclusion
    /// holds across opens; a Sync from Schematic restores them (the
    /// schematic is authoritative for the component set) and the
    /// sync feedback names them — see PCBBoardMerger.
    var excludedReferences: [String] = []
    var traces: [BoardTrace] = []
    var graphics: [BoardGraphicItem] = []
    /// References present the last time this state was merged. The
    /// merger diffs the next build against it to report arrivals and
    /// removals and to prune placements of vanished parts.
    var knownReferences: [String] = []

    // -- Part 5 additions (all decode as defaults when absent, so
    // a board file written by v4.0/v4.0.1 loads unchanged) --

    /// Placed vias.
    var vias: [BoardVia] = []
    /// Copper fill zones.
    var zones: [BoardZone] = []
    /// Component board sides by reference (absent = front).
    var sides: [String: BoardSide] = [:]
    /// Copper layer count for this board (2/4/6/8/16/32). The
    /// part-4 default layer stack was F + In1 + In2 + B, so the
    /// default here is 4: an old board keeps the exact layers it
    /// was drawn with.
    var copperLayerCount: Int = 4
    /// Snap grid spacing for this board, in mils (1 mil = 0.0254
    /// mm). 25 mil = 0.635 mm, KiCad's usual PCB grid.
    var gridMil: Double = 25
    /// Design clearance for this board, in mils: the minimum gap
    /// the net-touch check demands between different nets' copper.
    /// 8 mil is a common fab minimum.
    var clearanceMil: Double = 8

    // -- Part 5.2 additions (decode as defaults when absent) --

    /// Locked board items (traces, vias, zones, graphics) by id
    /// string: a locked item can be selected and inspected but
    /// not moved, reshaped or deleted until unlocked (KiCad's
    /// lock semantics, pcbnew BOARD_ITEM::IsLocked). Kept as id
    /// strings in the STATE — not as flags on the items — so the
    /// items' own Codable shapes never change.
    var lockedItemIDs: [String] = []
    /// Locked components by reference: a locked component cannot
    /// be moved, flipped or board-deleted.
    var lockedReferences: [String] = []

    static let empty = BoardState()

    /// Is this board item locked? (traces/vias/zones/graphics)
    func isLocked(_ id: UUID) -> Bool {
        lockedItemIDs.contains(id.uuidString)
    }

    /// Lock or unlock one board item.
    mutating func setLocked(_ id: UUID, _ locked: Bool) {
        if locked {
            if !isLocked(id) { lockedItemIDs.append(id.uuidString) }
        } else {
            lockedItemIDs.removeAll { $0 == id.uuidString }
        }
    }

    /// Is this component locked?
    func isLocked(reference: String) -> Bool {
        lockedReferences.contains(reference)
    }

    /// Lock or unlock one component.
    mutating func setLocked(reference: String, _ locked: Bool) {
        if locked {
            if !lockedReferences.contains(reference) {
                lockedReferences.append(reference)
            }
        } else {
            lockedReferences.removeAll { $0 == reference }
        }
    }
}

// Codable is hand-rolled on the decode side: EVERY field goes
// through decodeIfPresent so a file written before a field existed
// (v4.0/v4.0.1 boards have no vias/zones/sides/settings keys at
// all) decodes with the defaults above — additive format growth
// can never strand a user's board work. Encoding stays
// synthesized-equivalent (all fields written).
extension BoardState: Codable {
    private enum CodingKeys: String, CodingKey {
        case formatVersion, placements, excludedReferences, traces,
             graphics, knownReferences, vias, zones, sides,
             copperLayerCount, gridMil, clearanceMil,
             lockedItemIDs, lockedReferences
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try box.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        placements = try box.decodeIfPresent([String: FPPoint].self, forKey: .placements) ?? [:]
        excludedReferences = try box.decodeIfPresent([String].self, forKey: .excludedReferences) ?? []
        traces = try box.decodeIfPresent([BoardTrace].self, forKey: .traces) ?? []
        graphics = try box.decodeIfPresent([BoardGraphicItem].self, forKey: .graphics) ?? []
        knownReferences = try box.decodeIfPresent([String].self, forKey: .knownReferences) ?? []
        vias = try box.decodeIfPresent([BoardVia].self, forKey: .vias) ?? []
        zones = try box.decodeIfPresent([BoardZone].self, forKey: .zones) ?? []
        sides = try box.decodeIfPresent([String: BoardSide].self, forKey: .sides) ?? [:]
        copperLayerCount = try box.decodeIfPresent(Int.self, forKey: .copperLayerCount) ?? 4
        gridMil = try box.decodeIfPresent(Double.self, forKey: .gridMil) ?? 25
        clearanceMil = try box.decodeIfPresent(Double.self, forKey: .clearanceMil) ?? 8
        lockedItemIDs = try box.decodeIfPresent([String].self, forKey: .lockedItemIDs) ?? []
        lockedReferences = try box.decodeIfPresent([String].self, forKey: .lockedReferences) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(formatVersion, forKey: .formatVersion)
        try box.encode(placements, forKey: .placements)
        try box.encode(excludedReferences, forKey: .excludedReferences)
        try box.encode(traces, forKey: .traces)
        try box.encode(graphics, forKey: .graphics)
        try box.encode(knownReferences, forKey: .knownReferences)
        try box.encode(vias, forKey: .vias)
        try box.encode(zones, forKey: .zones)
        try box.encode(sides, forKey: .sides)
        try box.encode(copperLayerCount, forKey: .copperLayerCount)
        try box.encode(gridMil, forKey: .gridMil)
        try box.encode(clearanceMil, forKey: .clearanceMil)
        try box.encode(lockedItemIDs, forKey: .lockedItemIDs)
        try box.encode(lockedReferences, forKey: .lockedReferences)
    }
}

/// Plain-JSON sidecar persistence: Documents/Boards/<stem>.board.json
/// where <stem> is the connection table's file stem. A missing or
/// unreadable file is an empty state, never an error — the board
/// simply starts at the schematic's shelf layout.
enum BoardStateStore {
    static func url(forTableStem stem: String, in directory: URL? = nil) -> URL {
        let dir = directory ?? PadCBPaths.boardsDirectory
        let safe = stem.isEmpty ? "Untitled" : stem
        return dir.appendingPathComponent(safe).appendingPathExtension("board.json")
    }

    static func load(tableStem: String, in directory: URL? = nil) -> BoardState {
        let url = url(forTableStem: tableStem, in: directory)
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(BoardState.self, from: data)
        else { return .empty }
        return state
    }

    static func save(_ state: BoardState, tableStem: String,
                     in directory: URL? = nil) throws {
        let dir = directory ?? PadCBPaths.boardsDirectory
        PadCBPaths.ensureDirectory(dir)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(state)
        try data.write(to: url(forTableStem: tableStem, in: dir),
                       options: [.atomic])
    }
}

// MARK: - Merge

/// What one merge did, beyond the merged model itself. The editor
/// turns the sync-relevant parts into the "Synced — …" feedback
/// line; arrivals/removals are computed on every merge but only
/// surfaced for syncs.
struct BoardMergeReport: Equatable {
    /// Excluded references a SYNC restored to the board.
    var reAddedReferences: [String] = []
    /// References in the new build that the saved state had never
    /// seen (new schematic parts; they keep their shelf positions).
    var arrivedReferences: [String] = []
    /// References the saved state knew that are gone from the new
    /// build (removed from the schematic; their placements are
    /// pruned from the saved state).
    var removedReferences: [String] = []
    /// Traces this merge disconnected (their net vanished).
    var disconnectedTraceIDs: [UUID] = []
    /// Traces this merge reconnected (their net came back).
    var reconnectedTraceIDs: [UUID] = []
}

enum PCBBoardMerger {

    /// Fold `state` into a freshly built `base` model.
    ///
    /// Rules (pinned — BoardFixture asserts them):
    /// - A component whose reference has a saved placement keeps it;
    ///   others keep the builder's shelf origin.
    /// - Excluded references stay off the board on a plain apply
    ///   (opening the editor). On a SYNC apply they are restored
    ///   (the saved table is the authority for what parts exist),
    ///   named in the report, and the exclusion is cleared.
    /// - Traces bind to nets BY NAME against the new model's net
    ///   set. A trace whose net is gone keeps existing: netName is
    ///   cleared, the name remembered in disconnectedNetName, and a
    ///   Problems line is added to the merged model. A trace whose
    ///   remembered net is back rebinds.
    /// - Graphics carry over verbatim.
    /// - `stateToSave` is the canonical state to persist after the
    ///   merge: placements pruned to references that still exist,
    ///   knownReferences updated to the new build's set, exclusions
    ///   as decided above, traces with their new binding state.
    static func apply(state: BoardState, to base: BoardModel, isSync: Bool)
        -> (model: BoardModel, report: BoardMergeReport, stateToSave: BoardState) {
        var report = BoardMergeReport()
        var model = base
        let baseReferences = base.components.map(\.reference)
        let baseReferenceSet = Set(baseReferences)
        let knownSet = Set(state.knownReferences)

        report.arrivedReferences = baseReferences.filter { !knownSet.contains($0) }
        report.removedReferences = state.knownReferences.filter {
            !baseReferenceSet.contains($0)
        }

        // -- Exclusions --
        let excludedSet = Set(state.excludedReferences)
        var survivingExclusions: [String] = []
        if isSync {
            report.reAddedReferences = baseReferences.filter {
                excludedSet.contains($0)
            }
            // Exclusions for parts no longer in the schematic are
            // stale and dropped with them; either way a sync leaves
            // no exclusions behind.
        } else {
            model.components = model.components.filter {
                !excludedSet.contains($0.reference)
            }
            survivingExclusions = state.excludedReferences.filter {
                baseReferenceSet.contains($0)
            }
        }

        // -- Placements + sides (part 5: a flipped component stays
        // flipped across opens and syncs — side is board state,
        // matched by reference exactly like placement) --
        for index in model.components.indices {
            let reference = model.components[index].reference
            if let placement = state.placements[reference] {
                model.components[index].origin = placement
            }
            if let side = state.sides[reference] {
                model.components[index].side = side
            }
        }

        // -- Traces: net binding by name --
        let validNets = Set(base.netNames)
        var traces: [BoardTrace] = []
        var problems: [String] = []
        for var trace in state.traces {
            if let net = trace.netName, !validNets.contains(net) {
                trace.disconnectedNetName = net
                trace.netName = nil
                report.disconnectedTraceIDs.append(trace.id)
            } else if trace.netName == nil,
                      let lost = trace.disconnectedNetName,
                      validNets.contains(lost) {
                trace.netName = lost
                trace.disconnectedNetName = nil
                report.reconnectedTraceIDs.append(trace.id)
            }
            if let lost = trace.disconnectedNetName {
                problems.append(
                    "Trace on \(trace.layer) (\(formatMM(trace.width)) mm) lost its net "
                    + "\(lost) — that net is no longer in the schematic, so the "
                    + "trace is unconnected. It has not been deleted.")
            }
            traces.append(trace)
        }

        // -- Vias + zones (part 5): the same net-binding rule --
        var vias: [BoardVia] = []
        for var via in state.vias {
            if let net = via.netName, !validNets.contains(net) {
                via.disconnectedNetName = net
                via.netName = nil
            } else if via.netName == nil,
                      let lost = via.disconnectedNetName,
                      validNets.contains(lost) {
                via.netName = lost
                via.disconnectedNetName = nil
            }
            if let lost = via.disconnectedNetName {
                problems.append(
                    "A via at (\(formatMM(via.center.x)), \(formatMM(via.center.y))) lost its net "
                    + "\(lost) — that net is no longer in the schematic, so the "
                    + "via is unconnected. It has not been deleted.")
            }
            vias.append(via)
        }
        var zones: [BoardZone] = []
        for var zone in state.zones {
            if let net = zone.netName, !validNets.contains(net) {
                zone.disconnectedNetName = net
                zone.netName = nil
            } else if zone.netName == nil,
                      let lost = zone.disconnectedNetName,
                      validNets.contains(lost) {
                zone.netName = lost
                zone.disconnectedNetName = nil
            }
            if let lost = zone.disconnectedNetName {
                problems.append(
                    "The copper fill on \(zone.layer) lost its net "
                    + "\(lost) — that net is no longer in the schematic, so the "
                    + "fill is unconnected. It has not been deleted.")
            }
            zones.append(zone)
        }

        // -- Items on copper layers the board no longer has (part
        // 5, layer-count reduction): traces/zones on a removed inner
        // layer are KEPT (never silently dropped), hidden by the
        // layer stack, and named here until the count is restored
        // or the item is deleted. --
        let liveLayers = Set(BoardLayers.copperLayers(count: state.copperLayerCount))
        for trace in traces where !liveLayers.contains(trace.layer) {
            problems.append(
                "A trace sits on \(trace.layer), which this board no longer has "
                + "(\(state.copperLayerCount) copper layers). It is kept but "
                + "hidden — raise the copper layer count or delete it.")
        }
        for zone in zones where !liveLayers.contains(zone.layer) {
            problems.append(
                "A copper fill sits on \(zone.layer), which this board no longer has "
                + "(\(state.copperLayerCount) copper layers). It is kept but "
                + "hidden — raise the copper layer count or delete it.")
        }

        model.traces = traces
        model.vias = vias
        model.zones = zones
        model.graphics = state.graphics
        model.boardProblems = problems

        // -- Canonical state to persist --
        var canonical = BoardState()
        canonical.formatVersion = state.formatVersion
        canonical.placements = state.placements.filter {
            baseReferenceSet.contains($0.key)
        }
        canonical.excludedReferences = survivingExclusions
        canonical.traces = traces
        canonical.graphics = state.graphics
        canonical.knownReferences = baseReferences
        canonical.vias = vias
        canonical.zones = zones
        canonical.sides = state.sides.filter {
            baseReferenceSet.contains($0.key)
        }
        canonical.copperLayerCount = state.copperLayerCount
        canonical.gridMil = state.gridMil
        canonical.clearanceMil = state.clearanceMil
        // Locks survive the merge for items/references that do;
        // locks naming vanished items are pruned like placements.
        let liveItemIDs = Set(traces.map(\.id.uuidString))
            .union(vias.map(\.id.uuidString))
            .union(zones.map(\.id.uuidString))
            .union(state.graphics.map(\.id.uuidString))
        canonical.lockedItemIDs = state.lockedItemIDs.filter {
            liveItemIDs.contains($0)
        }
        canonical.lockedReferences = state.lockedReferences.filter {
            baseReferenceSet.contains($0)
        }
        return (model, report, canonical)
    }

    /// "0.25" / "0.5" style mm formatting for problem lines.
    static func formatMM(_ value: Double) -> String {
        let text = String(format: "%.2f", value)
        return text.hasSuffix("0") ? String(text.dropLast()) : text
    }
}

// MARK: - Visibility (the drawing code's predicates)

/// Layer + object-class visibility. The PCB editor's canvas draws
/// through these predicates and nothing else, so asserting them here
/// asserts what the canvas shows — the SymbolDrawList arrangement:
/// the audited code IS the drawing code.
struct BoardVisibility: Equatable {
    /// Layers switched off in the Layers panel.
    var hiddenLayers: Set<String> = []
    var showFootprints = true
    var showTracks = true
    var showVias = true
    var showPads = true
    var showZones = true
    var showDrawings = true
    var showText = true
    var showDimensions = true
    /// Ratsnest lines for unrouted connections (part 5.2).
    var showRatsnest = true

    /// The board's copper layer count (part 5): the copper stack —
    /// and therefore the "*.Cu" wildcard and orphan-layer hiding —
    /// follows it. Defaults to the part-4 four-layer stack.
    var copperLayerCount: Int = 4

    /// The part-4 copper stack (count 4), kept for the editor's
    /// static references.
    static let copperLayers = ["F.Cu", "In1.Cu", "In2.Cu", "B.Cu"]

    /// This board's copper stack.
    var copperLayers: [String] {
        BoardLayers.copperLayers(count: copperLayerCount)
    }

    /// Is `layer` part of this board's layer stack at all? A layer
    /// outside the stack (e.g. In2.Cu on a 2-layer board) is never
    /// shown — items on it are kept but hidden (part 5).
    func layerExists(_ layer: String) -> Bool {
        BoardLayers.allLayers(copperCount: copperLayerCount).contains(layer)
    }

    /// Is one layer name shown? The KiCad wildcard "*.Cu" counts as
    /// shown when ANY of the board's copper layers is shown.
    func layerShown(_ layer: String) -> Bool {
        if layer == "*.Cu" {
            return copperLayers.contains { !hiddenLayers.contains($0) }
        }
        guard layerExists(layer) else { return false }
        return !hiddenLayers.contains(layer)
    }

    /// A footprint graphic (fp_line, fp_text, …): its layer must be
    /// shown and its object class on (text graphics file under Text,
    /// everything else under Drawings).
    func footprintGraphicShown(_ graphic: KiCadFootprintGraphic) -> Bool {
        guard layerShown(graphic.layer) else { return false }
        if case .text = graphic { return showText }
        return showDrawings
    }

    /// A pad shows when the Pads class is on and at least one of its
    /// COPPER layers is shown. Pads are copper objects: their mask /
    /// paste openings follow the pad, they don't keep it alive —
    /// with every copper layer hidden the pad is gone (BoardFixture
    /// caught exactly that). A through-hole pad lives on "*.Cu"
    /// (every copper layer), so hiding F.Cu alone must not hide it.
    func padShown(_ pad: KiCadFootprintPad) -> Bool {
        guard showPads else { return false }
        let copper = pad.layers.filter { $0 == "*.Cu" || $0.hasSuffix(".Cu") }
        if copper.isEmpty { return true }
        return copper.contains { layerShown($0) }
    }

    func traceShown(_ trace: BoardTrace) -> Bool {
        showTracks && layerShown(trace.layer)
    }

    /// A via spans the whole copper stack: it shows when the Vias
    /// class is on and at least one copper layer is shown.
    func viaShown(_ via: BoardVia) -> Bool {
        showVias && copperLayers.contains { !hiddenLayers.contains($0) }
    }

    func zoneShown(_ zone: BoardZone) -> Bool {
        showZones && layerShown(zone.layer)
    }

    func boardGraphicShown(_ item: BoardGraphicItem) -> Bool {
        guard layerShown(item.layer) else { return false }
        return item.kind == .text ? showText : showDrawings
    }
}

// MARK: - Selection filter

/// Which board items taps may select, by class. The filter panel's
/// rows map 1:1 onto PadCB's selectable classes.
struct BoardSelectionFilter: Equatable {
    enum ItemKind {
        case component, trace, graphic, text, via, zone
    }

    var components = true
    var traces = true
    var graphics = true
    var text = true
    var vias = true
    var zones = true

    /// The "All items" row: on exactly when every class is on.
    var allItems: Bool {
        components && traces && graphics && text && vias && zones
    }

    mutating func setAll(_ on: Bool) {
        components = on
        traces = on
        graphics = on
        text = on
        vias = on
        zones = on
    }

    func allows(_ kind: ItemKind) -> Bool {
        switch kind {
        case .component: return components
        case .trace: return traces
        case .graphic: return graphics
        case .text: return text
        case .via: return vias
        case .zone: return zones
        }
    }
}

// MARK: - Canvas metrics (zoom)

/// Zoom bookkeeping for the board canvas. Scale is points per mm;
/// 2.5 pt/mm reads as 100 % (the size a 2.54 mm grid reads naturally
/// on the iPad panel). Part 4 raised the ceiling from 30 pt/mm
/// (1200 %) to 150 pt/mm (6000 %) — "add more zoom, I can't get
/// that close" — for the Zoom In button and pinch alike.
enum BoardCanvasMetrics {
    static let baseScale = 2.5
    static let minScale = 0.3
    static let maxScale = 150.0
    static let zoomStep = 1.25

    static func clamped(_ scale: Double) -> Double {
        min(max(scale, minScale), maxScale)
    }

    static func percent(forScale scale: Double) -> Int {
        Int((scale / baseScale * 100).rounded())
    }
}

// MARK: - Geometry (hit-testing, routing, sampling)

/// Pure board geometry shared by the editor's canvas (drawing +
/// hit-testing) and the BoardFixture harness.
enum BoardGeometry {

    /// Board-space bounds of one placed component (its footprint's
    /// bounds at its origin, or the placeholder box). A back-side
    /// footprint's bounds are the MIRRORED front bounds.
    static func componentBounds(_ component: BoardComponent)
        -> (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        if let footprint = component.footprint {
            let b = footprint.bounds
            if component.side == .back {
                return (component.origin.x - b.maxX, component.origin.y + b.minY,
                        component.origin.x - b.minX, component.origin.y + b.maxY)
            }
            return (component.origin.x + b.minX, component.origin.y + b.minY,
                    component.origin.x + b.maxX, component.origin.y + b.maxY)
        }
        return (component.origin.x, component.origin.y,
                component.origin.x + component.boundsSize.w,
                component.origin.y + component.boundsSize.h)
    }

    /// The layer a front-side layer becomes when flipped to the
    /// back (and vice versa): F.* <-> B.*; "*.Cu" and unprefixed
    /// layers (Edge.Cuts, Dwgs.User…) do not change.
    static func flippedLayerName(_ layer: String) -> String {
        if layer.hasPrefix("F.") { return "B." + layer.dropFirst(2) }
        if layer.hasPrefix("B.") { return "F." + layer.dropFirst(2) }
        return layer
    }

    /// A footprint-local point in board space for this component,
    /// honouring its side: back-side local points are MIRRORED
    /// across the vertical axis through the origin (x negates).
    static func localToBoard(_ component: BoardComponent,
                             _ point: FPPoint) -> FPPoint {
        if component.side == .back {
            return FPPoint(x: component.origin.x - point.x,
                           y: component.origin.y + point.y)
        }
        return FPPoint(x: component.origin.x + point.x,
                       y: component.origin.y + point.y)
    }

    /// The pad as it physically sits for this component: for a
    /// back-side footprint the pad is mirrored (centre x negates,
    /// rotation negates — pads are 180°-symmetric, so negation is
    /// the mirror), the drill offset mirrors, and its layers swap
    /// front<->back. For a front-side component this is the pad
    /// itself. Every consumer (drawing, hit-testing, checks) works
    /// with THIS pad so the flip is true everywhere at once.
    static func boardPad(_ component: BoardComponent,
                         _ pad: KiCadFootprintPad) -> KiCadFootprintPad {
        guard component.side == .back else { return pad }
        var flipped = pad
        flipped.x = -pad.x
        flipped.rotation = -pad.rotation
        flipped.layers = pad.layers.map { flippedLayerName($0) }
        if var drill = pad.drill {
            drill.offsetX = -drill.offsetX
            flipped.drill = drill
        }
        // Custom-pad primitives live in pad-local coordinates; the
        // negated rotation above carries them with the mirror.
        return flipped
    }

    /// A footprint graphic as it sits for this component: points
    /// mirrored (x negates) and layer flipped for back-side parts.
    /// Text graphics also negate their rotation; the canvas draws
    /// back-side text with a horizontal mirror so the LETTERS read
    /// mirrored, as they do on a real board's back.
    static func boardGraphic(_ component: BoardComponent,
                             _ graphic: KiCadFootprintGraphic)
        -> KiCadFootprintGraphic {
        guard component.side == .back else { return graphic }
        func mirror(_ p: FPPoint) -> FPPoint { FPPoint(x: -p.x, y: p.y) }
        switch graphic {
        case .line(let a, let b, let layer, let w, let t, let f):
            return .line(start: mirror(a), end: mirror(b),
                         layer: flippedLayerName(layer),
                         strokeWidth: w, strokeType: t, fill: f)
        case .rect(let a, let b, let layer, let w, let t, let f):
            return .rect(start: mirror(a), end: mirror(b),
                         layer: flippedLayerName(layer),
                         strokeWidth: w, strokeType: t, fill: f)
        case .circle(let c, let r, let layer, let w, let t, let f):
            return .circle(center: mirror(c), radius: r,
                           layer: flippedLayerName(layer),
                           strokeWidth: w, strokeType: t, fill: f)
        case .arc(let a, let m, let b, let layer, let w, let t, let f):
            return .arc(start: mirror(a), mid: mirror(m), end: mirror(b),
                        layer: flippedLayerName(layer),
                        strokeWidth: w, strokeType: t, fill: f)
        case .poly(let points, let layer, let w, let t, let f):
            return .poly(points: points.map(mirror),
                         layer: flippedLayerName(layer),
                         strokeWidth: w, strokeType: t, fill: f)
        case .curve(let p1, let p2, let p3, let p4, let layer, let w, let t, let f):
            return .curve(p1: mirror(p1), p2: mirror(p2),
                          p3: mirror(p3), p4: mirror(p4),
                          layer: flippedLayerName(layer),
                          strokeWidth: w, strokeType: t, fill: f)
        case .text(var text):
            text.x = -text.x
            text.rotation = -text.rotation
            text.layer = flippedLayerName(text.layer)
            return .text(text)
        }
    }

    /// Board-space centre of one pad of a placed component. Pass
    /// the RAW pad (straight from `footprint.pads`): the mirror
    /// for a back-side component is applied here, exactly once.
    /// (For size/rotation/layers use `boardPad`, whose centre is
    /// the same point minus the origin.)
    static func padCenter(_ component: BoardComponent,
                          _ pad: KiCadFootprintPad) -> FPPoint {
        localToBoard(component, FPPoint(x: pad.x, y: pad.y))
    }

    /// Board-space outline corners of one pad (raw pad in, flipped
    /// as the component's side demands).
    static func padOutline(_ component: BoardComponent,
                           _ pad: KiCadFootprintPad) -> [FPPoint] {
        let effective = boardPad(component, pad)
        return effective.outlineCorners.map {
            FPPoint(x: component.origin.x + $0.x,
                    y: component.origin.y + $0.y)
        }
    }

    /// The net a pad carries, via the component's pin binding of the
    /// same number (nil when the pad has no pin or the pin no net).
    static func netName(_ component: BoardComponent,
                        _ pad: KiCadFootprintPad) -> String? {
        guard !pad.number.isEmpty else { return nil }
        return component.pins.first { $0.pinNumber == pad.number }?.netName
    }

    /// Nearest pad to a board point, for routing/highlight taps.
    /// A pad is hit when the point falls within the pad's outline
    /// (rotated-rectangle approximation via its outline corners'
    /// bounds) expanded by `tolerance` mm.
    static func padAt(_ model: BoardModel, point: FPPoint, tolerance: Double)
        -> (component: BoardComponent, pad: KiCadFootprintPad, netName: String?)? {
        var best: (component: BoardComponent, pad: KiCadFootprintPad,
                   netName: String?, distance: Double)? = nil
        for component in model.components {
            guard let footprint = component.footprint else { continue }
            for pad in footprint.pads {
                let effective = boardPad(component, pad)
                let centre = padCenter(component, pad)
                let halfW = effective.width / 2 + tolerance
                let halfH = effective.height / 2 + tolerance
                let local = FPPoint(x: point.x - centre.x, y: point.y - centre.y)
                    .rotated(degrees: -effective.rotation)
                guard abs(local.x) <= halfW, abs(local.y) <= halfH else { continue }
                let distance = centre.distance(to: point)
                if best == nil || distance < best!.distance {
                    best = (component, pad, netName(component, pad), distance)
                }
            }
        }
        guard let found = best else { return nil }
        return (found.component, found.pad, found.netName)
    }

    /// Component whose bounds contain the point (small tolerance).
    static func componentAt(_ model: BoardModel, point: FPPoint,
                            tolerance: Double = 0.5) -> BoardComponent? {
        for component in model.components.reversed() {
            let b = componentBounds(component)
            if point.x >= b.minX - tolerance, point.x <= b.maxX + tolerance,
               point.y >= b.minY - tolerance, point.y <= b.maxY + tolerance {
                return component
            }
        }
        return nil
    }

    /// Distance from a point to a segment.
    static func distance(point: FPPoint, segmentStart a: FPPoint,
                         segmentEnd b: FPPoint) -> Double {
        let abx = b.x - a.x, aby = b.y - a.y
        let lengthSquared = abx * abx + aby * aby
        if lengthSquared < 1e-12 { return point.distance(to: a) }
        var t = ((point.x - a.x) * abx + (point.y - a.y) * aby) / lengthSquared
        t = min(max(t, 0), 1)
        return point.distance(to: FPPoint(x: a.x + t * abx, y: a.y + t * aby))
    }

    /// A trace is hit when the point is within its copper (width/2)
    /// or the tap tolerance, whichever is larger.
    static func traceHit(_ trace: BoardTrace, point: FPPoint,
                         tolerance: Double) -> Bool {
        let reach = max(tolerance, trace.width / 2)
        guard trace.points.count > 1 else { return false }
        for index in 1..<trace.points.count {
            if distance(point: point, segmentStart: trace.points[index - 1],
                        segmentEnd: trace.points[index]) <= reach {
                return true
            }
        }
        return false
    }

    static func traceAt(_ model: BoardModel, point: FPPoint,
                        tolerance: Double) -> BoardTrace? {
        for trace in model.traces.reversed()
        where traceHit(trace, point: point, tolerance: tolerance) {
            return trace
        }
        return nil
    }

    static func graphicHit(_ item: BoardGraphicItem, point: FPPoint,
                           tolerance: Double) -> Bool {
        switch item.kind {
        case .line:
            guard item.points.count == 2 else { return false }
            return distance(point: point, segmentStart: item.points[0],
                            segmentEnd: item.points[1]) <= tolerance
        case .arc:
            guard item.points.count == 3 else { return false }
            let samples = arcSamplePoints(start: item.points[0],
                                          mid: item.points[1],
                                          end: item.points[2])
            guard samples.count > 1 else { return false }
            for index in 1..<samples.count {
                if distance(point: point, segmentStart: samples[index - 1],
                            segmentEnd: samples[index]) <= tolerance {
                    return true
                }
            }
            return false
        case .circle:
            guard let centre = item.points.first else { return false }
            return abs(centre.distance(to: point) - item.radius) <= tolerance
        case .text:
            guard let anchor = item.points.first else { return false }
            return anchor.distance(to: point) <= max(tolerance, item.textSize)
        }
    }

    static func graphicAt(_ model: BoardModel, point: FPPoint,
                          tolerance: Double) -> BoardGraphicItem? {
        for item in model.graphics.reversed()
        where graphicHit(item, point: point, tolerance: tolerance) {
            return item
        }
        return nil
    }

    /// A via is hit when the point falls within its annular ring
    /// (or the tap tolerance, whichever reaches further).
    static func viaHit(_ via: BoardVia, point: FPPoint,
                       tolerance: Double) -> Bool {
        via.center.distance(to: point) <= max(tolerance, via.diameter / 2)
    }

    static func viaAt(_ model: BoardModel, point: FPPoint,
                      tolerance: Double) -> BoardVia? {
        for via in model.vias.reversed()
        where viaHit(via, point: point, tolerance: tolerance) {
            return via
        }
        return nil
    }

    /// Point-in-polygon (even-odd ray cast). The polygon closes
    /// implicitly. Points exactly on an edge count as inside.
    static func pointInPolygon(_ point: FPPoint, polygon: [FPPoint]) -> Bool {
        guard polygon.count >= 3 else { return false }
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[(index + 1) % polygon.count]
            if distance(point: point, segmentStart: a, segmentEnd: b) < 1e-9 {
                return true
            }
        }
        var inside = false
        var previous = polygon[polygon.count - 1]
        for current in polygon {
            if (current.y > point.y) != (previous.y > point.y) {
                let crossX = (previous.x - current.x) * (point.y - current.y)
                    / (previous.y - current.y) + current.x
                if point.x < crossX { inside.toggle() }
            }
            previous = current
        }
        return inside
    }

    /// A zone is hit when the point is inside its polygon (or
    /// within the tap tolerance of its outline).
    static func zoneHit(_ zone: BoardZone, point: FPPoint,
                        tolerance: Double) -> Bool {
        if pointInPolygon(point, polygon: zone.points) { return true }
        guard zone.points.count >= 2 else { return false }
        for index in zone.points.indices {
            let a = zone.points[index]
            let b = zone.points[(index + 1) % zone.points.count]
            if distance(point: point, segmentStart: a, segmentEnd: b) <= tolerance {
                return true
            }
        }
        return false
    }

    static func zoneAt(_ model: BoardModel, point: FPPoint,
                       tolerance: Double) -> BoardZone? {
        for zone in model.zones.reversed()
        where zoneHit(zone, point: point, tolerance: tolerance) {
            return zone
        }
        return nil
    }

    /// KiCad-style 45° routing: the corner to insert between `from`
    /// and `to` so both resulting segments are axis-aligned or
    /// exactly 45°. Returns nil when the direct segment already is
    /// one of those (axis-aligned or a perfect diagonal).
    static func routeCorner(from: FPPoint, to: FPPoint) -> FPPoint? {
        let dx = to.x - from.x, dy = to.y - from.y
        if abs(dx) < 1e-9 || abs(dy) < 1e-9 { return nil }
        if abs(abs(dx) - abs(dy)) < 1e-9 { return nil }
        let step = min(abs(dx), abs(dy))
        return FPPoint(x: from.x + (dx > 0 ? step : -step),
                       y: from.y + (dy > 0 ? step : -step))
    }

    /// Snap a board point to a grid (mm).
    static func snapped(_ point: FPPoint, grid: Double) -> FPPoint {
        guard grid > 0 else { return point }
        return FPPoint(x: (point.x / grid).rounded() * grid,
                       y: (point.y / grid).rounded() * grid)
    }

    /// Sample an arc through three points via the circumcentre
    /// (y-down board coordinates). Degenerate (collinear) input
    /// degrades to the three points themselves.
    static func arcSamplePoints(start a: FPPoint, mid m: FPPoint,
                                end e: FPPoint) -> [FPPoint] {
        var points: [FPPoint] = [a]
        let d = 2 * (a.x * (m.y - e.y) + m.x * (e.y - a.y) + e.x * (a.y - m.y))
        if abs(d) < 1e-9 {
            points.append(m)
            points.append(e)
            return points
        }
        let aSq = a.x * a.x + a.y * a.y
        let mSq = m.x * m.x + m.y * m.y
        let eSq = e.x * e.x + e.y * e.y
        let cx = (aSq * (m.y - e.y) + mSq * (e.y - a.y) + eSq * (a.y - m.y)) / d
        let cy = (aSq * (e.x - m.x) + mSq * (a.x - e.x) + eSq * (m.x - a.x)) / d
        let r = hypot(a.x - cx, a.y - cy)
        let a0 = atan2(a.y - cy, a.x - cx)
        let am = atan2(m.y - cy, m.x - cx)
        let a1 = atan2(e.y - cy, e.x - cx)
        func norm(_ v: Double) -> Double {
            var v = v.truncatingRemainder(dividingBy: 2 * Double.pi)
            if v < 0 { v += 2 * Double.pi }
            return v
        }
        let sweepPos = norm(a1 - a0)
        let midPos = norm(am - a0)
        let sweep = midPos <= sweepPos + 1e-9 ? sweepPos : -(2 * Double.pi - sweepPos)
        let steps = max(4, Int(abs(sweep) / (Double.pi / 36)) + 1)
        for i in 1...steps {
            let t = a0 + sweep * Double(i) / Double(steps)
            points.append(FPPoint(x: cx + r * cos(t), y: cy + r * sin(t)))
        }
        return points
    }

    /// Standard track widths offered in the editor (mm).
    static let trackWidthPresets: [Double] = [0.15, 0.2, 0.25, 0.3, 0.4, 0.5, 0.75, 1.0]
}

// MARK: - Pointer stream + routing interaction (part 5.0.1)

/// One pointer event for the PCB canvas. Hover and touch are TWO
/// SOURCES FEEDING ONE STREAM: the UIKit hover recognizer reports
/// `.hoverMoved` / `.hoverEnded`; the canvas drag gesture reports
/// `.touchMoved` / `.touchEnded`. Everything downstream (previews,
/// the status-bar readout, anchor resolution) reads the single
/// `BoardPointerState`, never a source directly.
///
/// Why this exists (the v5.0 hover failure, diagnosed 2026-11-01):
/// v5.0 kept TWO optional points — `cursorBoard` (touch) and
/// `hoverBoard` (pencil hover) — and the preview read
/// `cursorBoard ?? hoverBoard`. But `cursorBoard` was WRITTEN on
/// every touch (drag change AND drag end) and NEVER cleared, so
/// the tap that STARTS a route froze it at the start pad forever
/// and every later hover position was masked: the prospective
/// segment never followed the hovering pencil. Here the touch
/// point wins ONLY while a touch is actually down
/// (`touchActive`), and `.touchEnded` clears it — hover resumes
/// the instant the finger/pencil lifts.
enum BoardPointerEvent: Equatable {
    case hoverMoved(FPPoint)
    case hoverEnded
    case touchMoved(FPPoint)
    case touchEnded
}

/// The canvas's single pointer state (see BoardPointerEvent).
///
/// Part 5.2 — PER-CHANNEL HOVER SLOTS. Sean's v5.1 device report
/// (2026-11-02 08:44): "whenever I use hover the ui shakes back
/// and forth" — the failure mode had changed from v5.0's silence
/// to OSCILLATION, because on his hardware BOTH delivery channels
/// are live at once and the v5.0.1–5.1 state kept ONE shared
/// hover point: an `.hoverEnded` from EITHER channel nilled it,
/// even while the other channel was mid-stream and about to
/// re-deliver the same physical hover. SwiftUI's
/// `.onContinuousHover` restarts its phase whenever its hosting
/// view re-evaluates — which every hover event caused — so its
/// end/active churn repeatedly cleared and restored the point
/// the interaction channel was steadily delivering: the preview,
/// the hover highlight and the cursor readout blinked at several
/// Hz. The state now keeps ONE SLOT PER CHANNEL: a move writes
/// its own channel's slot, an end clears ONLY its own channel's
/// slot, and the live hover point is the FRESHEST live slot.
/// `BoardHoverDiagnostics` (the counters) is unchanged — Sean's
/// acceptance spec keeps the channel counters visible.
struct BoardPointerState: Equatable {
    /// Live hover point per channel (a channel absent here has
    /// ended or never delivered).
    private(set) var hoverSlots: [BoardHoverChannel: FPPoint] = [:]
    /// Freshness clock value of each live channel's latest move.
    private(set) var hoverFreshness: [BoardHoverChannel: UInt64] = [:]
    /// Monotonic clock stamping hover moves (ordering only).
    private var hoverClock: UInt64 = 0
    /// Last touch position while a touch is down.
    private(set) var touchPoint: FPPoint? = nil
    /// True between a touch's first move and its end.
    private(set) var touchActive = false

    /// The live hover point: the freshest live channel's slot,
    /// or nil when every channel has ended.
    var hoverPoint: FPPoint? {
        guard let freshest = hoverFreshness.max(by: { $0.value < $1.value })?.key
        else { return nil }
        return hoverSlots[freshest]
    }

    /// The point previews follow: the touch point while a touch
    /// is down, else the hover point.
    var currentPoint: FPPoint? { touchActive ? touchPoint : hoverPoint }

    /// Record a hover move ON ITS OWN CHANNEL: the other
    /// channel's slot is untouched, so an interleaved stream can
    /// never erase this channel's point.
    mutating func applyHoverMoved(_ point: FPPoint,
                                  channel: BoardHoverChannel) {
        hoverClock &+= 1
        hoverSlots[channel] = point
        hoverFreshness[channel] = hoverClock
    }

    /// Record a hover end ON ITS OWN CHANNEL: only that channel's
    /// slot clears. The other channel, if live, keeps supplying
    /// the hover point — an end can no longer blink the stream.
    mutating func applyHoverEnded(channel: BoardHoverChannel) {
        hoverSlots[channel] = nil
        hoverFreshness[channel] = nil
    }

    /// The untagged stream (kept for the touch events and for
    /// callers that predate channels): an untagged hover event
    /// belongs to the interaction channel, the primary feed.
    mutating func apply(_ event: BoardPointerEvent) {
        switch event {
        case .hoverMoved(let point):
            applyHoverMoved(point, channel: .interaction)
        case .hoverEnded:
            applyHoverEnded(channel: .interaction)
        case .touchMoved(let point):
            touchPoint = point
            touchActive = true
        case .touchEnded:
            touchActive = false
            touchPoint = nil
        }
    }
}

/// Which DELIVERY channel a hover event arrived on (parts
/// 5.0.2–5.0.3).
///
/// v5.0.1's model was proven but its ONE delivery path (a
/// hit-test-transparent overlay + recognizers lent to its first
/// ancestors) delivered nothing on Sean's hardware: a view whose
/// hitTest returns nil is excluded from hover hit-testing too,
/// so the overlay's own recognizer was dead by construction, and
/// the lent recognizers' placement in the live hit chain was a
/// gamble on SwiftUI's private hierarchy (see CONTRACTS.md,
/// "Part 5.0.2 forensics"). v5.0.2 fed the SAME
/// `BoardPointerState` entry point from three tagged channels —
/// and Sean's hardware STILL reported no hover (2026-11-01
/// 21:37), so v5.0.3 stops working around the view hierarchy and
/// OWNS it: ONE dedicated UIKit interaction view sits FRONTMOST
/// over the canvas rect and is the hit view for hover AND touches
/// alike, with the UIHoverGestureRecognizer attached DIRECTLY to
/// it (Apple's canonical pattern — the recognizer on the canvas
/// surface view itself). No lent recognizers, no ancestor walks,
/// no selectively-transparent hit test:
/// - interaction: the frontmost interaction view's own
///   UIHoverGestureRecognizer (the primary channel).
/// - swiftUI: SwiftUI's `.onContinuousHover` on the canvas
///   container (the v5.0 feed, kept as a counted fallback).
enum BoardHoverChannel: Int, Equatable, CaseIterable {
    case interaction = 1
    case swiftUI = 2
}

/// Per-channel hover delivery counters (part 5.0.2): the
/// on-screen proof mechanism. Every hover event the editor
/// accepts is recorded against its channel BEFORE it is applied
/// to `BoardPointerState`, so the status-bar line
/// ("Hover 1: n · 2: n · (x, y)") shows live counts per
/// channel plus the last hover point in board mm. A channel whose
/// counter stays at 0 while the pencil hovers is a dead channel
/// on that hardware; all-zero means hover never reached the app.
struct BoardHoverDiagnostics: Equatable {
    /// Event counts, indexed by `BoardHoverChannel.rawValue`
    /// (slot 0 unused).
    private(set) var counts: [Int] = [0, 0, 0]
    /// The most recent hover position from a `hoverMoved` event
    /// (any channel), in board mm. `hoverEnded` does NOT clear
    /// it — it is the LAST point, a historical diagnostic.
    private(set) var lastPoint: FPPoint? = nil
    /// The channel of the most recently recorded event.
    private(set) var lastChannel: BoardHoverChannel? = nil

    mutating func record(_ channel: BoardHoverChannel,
                         point: FPPoint?) {
        counts[channel.rawValue] += 1
        lastChannel = channel
        if let point { lastPoint = point }
    }

    func count(_ channel: BoardHoverChannel) -> Int {
        counts[channel.rawValue]
    }

    var totalCount: Int { counts[1] + counts[2] }

    /// The status-bar line, e.g. "Hover 1: 0 · 2: 0 · (–, –)"
    /// before any event, "Hover 1: 340 · 2: 5 · (12.3, 4.5)"
    /// once events flow. The en dash marks "no point yet".
    var summary: String {
        let pointText: String
        if let lastPoint {
            pointText = String(format: "(%.1f, %.1f)",
                               lastPoint.x, lastPoint.y)
        } else {
            pointText = "(–, –)"
        }
        return "Hover 1: \(counts[1]) · 2: \(counts[2])"
            + " · \(pointText)"
    }
}

/// A pad resolved as a pointer target: everything the editor
/// needs to anchor on it, highlight it, and talk about it.
struct BoardPadTarget: Equatable {
    var reference: String
    var padNumber: String
    var netName: String?
    /// Board-space pad centre (side-aware — a flipped part's pad
    /// centre is its mirrored centre).
    var center: FPPoint
    /// Effective pad size (mm), for the hover highlight ring.
    var width: Double
    var height: Double
}

/// What the pointer is over, for KiCad-style hover highlighting.
enum BoardHoverTarget: Equatable {
    case pad(BoardPadTarget)
    case trace(UUID)
}

/// The resolved live preview of an in-progress track — KiCad's
/// router "head" (pns_line_placer.h: `Move(aP, aEndItem)` re-routes
/// the volatile head to the pointer point on every motion event,
/// taking the item under the pointer as the end anchor). The
/// endpoint is the PAD CENTRE when a pad is within tolerance
/// (end-item anchoring), else the grid-snapped pointer.
struct BoardRoutePreview: Equatable {
    /// Where the head lands if the user anchors right now.
    var endPoint: FPPoint
    /// The 45° corner between the last anchored point and
    /// `endPoint` (nil when the direct segment is already legal).
    var corner: FPPoint?
    /// The pad the endpoint is anchored to, if any.
    var target: BoardPadTarget?
    /// True when the target pad carries a DIFFERENT net than the
    /// track being routed — KiCad refuses the join, and so does
    /// the tap (same rule, same function family: see routeTap).
    var joinRefused: Bool
}

/// The resolution of a tap in the Route Tracks tool. The view maps
/// each case to its status copy and side effects; ALL the geometry
/// (pad snap, grid snap, net refusal) is decided here so a tap and
/// the hover preview can never disagree — the preview's endpoint
/// IS the point a tap would anchor.
enum BoardRouteTap: Equatable {
    /// Not routing yet: start the track on this pad.
    case startPad(BoardPadTarget)
    /// Routing: a free waypoint (grid-snapped per the settings).
    case appendPoint(FPPoint)
    /// Routing: the tap lands on a pad — anchor its centre and
    /// finish the track there.
    case finishAtPad(BoardPadTarget)
    /// Routing: the tap lands on a pad of a different net (the
    /// net's name) — refused, nothing is appended.
    case refusedForeignNet(String)
    /// Not routing yet and no pad under the tap: nothing to start.
    case needsPad
}

extension BoardGeometry {

    /// The pad under a board point as a BoardPadTarget (nil when
    /// no pad is within `tolerance`).
    static func padTarget(_ model: BoardModel, point: FPPoint,
                          tolerance: Double) -> BoardPadTarget? {
        guard let hit = padAt(model, point: point, tolerance: tolerance)
        else { return nil }
        let effective = boardPad(hit.component, hit.pad)
        return BoardPadTarget(
            reference: hit.component.reference,
            padNumber: hit.pad.number,
            netName: hit.netName,
            center: padCenter(hit.component, hit.pad),
            width: effective.width, height: effective.height)
    }

    /// What a hovering pointer highlights: a pad wins over a
    /// trace (pads are the precise targets; a trace is the
    /// fallback when no pad is near).
    static func hoverTarget(_ model: BoardModel, point: FPPoint,
                            tolerance: Double) -> BoardHoverTarget? {
        if let target = padTarget(model, point: point, tolerance: tolerance) {
            return .pad(target)
        }
        if let trace = traceAt(model, point: point, tolerance: tolerance) {
            return .trace(trace.id)
        }
        return nil
    }

    /// Resolve the live route preview for a pointer position
    /// (KiCad's `Move`): pad-anchored when a pad is within
    /// tolerance, grid-snapped otherwise.
    static func routePreview(_ model: BoardModel, from last: FPPoint,
                             pointer: FPPoint, routeNet: String?,
                             snapEnabled: Bool, gridMil: Double,
                             tolerance: Double) -> BoardRoutePreview {
        if let target = padTarget(model, point: pointer, tolerance: tolerance) {
            let refused = routeNet != nil && target.netName != nil
                && target.netName != routeNet
            return BoardRoutePreview(
                endPoint: target.center,
                corner: routeCorner(from: last, to: target.center),
                target: target, joinRefused: refused)
        }
        let end = snapEnabled ? BoardGrid.snap(pointer, gridMil: gridMil)
                              : pointer
        return BoardRoutePreview(
            endPoint: end,
            corner: routeCorner(from: last, to: end),
            target: nil, joinRefused: false)
    }

    /// Resolve a Route Tracks tap (KiCad's `FixRoute`: a click
    /// commits the head at the pointer, anchored on the end item).
    /// The answer for any point is built from the same pad/snap
    /// resolution as `routePreview`, so the point the preview
    /// shows is the point the tap commits.
    static func routeTap(_ model: BoardModel, point: FPPoint,
                         routingActive: Bool, routeNet: String?,
                         snapEnabled: Bool, gridMil: Double,
                         tolerance: Double) -> BoardRouteTap {
        let target = padTarget(model, point: point, tolerance: tolerance)
        guard routingActive else {
            guard let target else { return .needsPad }
            return .startPad(target)
        }
        if let target {
            if let routing = routeNet, let padNet = target.netName,
               routing != padNet {
                return .refusedForeignNet(padNet)
            }
            return .finishAtPad(target)
        }
        return .appendPoint(snapEnabled
                             ? BoardGrid.snap(point, gridMil: gridMil)
                             : point)
    }
}

// MARK: - Stateful route head + pointer coalescing (part 5.2)
//
// Sean's v5.1 device report (2026-11-02 08:44): "whenever I use
// hover the ui shakes back and forth". The pure resolution above
// (routePreview / routeTap) re-derives EVERYTHING from the
// instantaneous pointer, so three boundary effects oscillate at
// hover-event rates:
//
// - SNAP BOUNDARY: a hovering pencil's position noise straddles
//   a grid cell edge; the snapped endpoint alternates between
//   two grid points per event, and the 45° corner (a pure
//   function of from + endpoint) jitters with it — at high zoom
//   one grid step is ~95 pt on screen.
// - PAD RIM: at a pad's tolerance rim the endpoint alternates
//   between the pad centre and the snapped free point — jumps
//   of up to a full tolerance.
// - DIAGONAL: near |dx| = |dy| the short axis remainder flips
//   vertical ↔ horizontal and the corner appears/vanishes as
//   the endpoint dithers across the diagonal through `from`.
//
// KiCad's placer has none of this because its head is STATEFUL:
// pns_line_placer.cpp's buildInitialLine constructs the head
// from the placer's CARRIED direction (m_direction.
// BuildInitialTrace(...)), and Move() re-routes a persistent
// head/tail pair — the corner posture is routing history, not
// a fresh derivation per motion event. BoardRouteHead is the
// same idea at PadCB's scale: it carries the last resolved
// endpoint, anchored pad and corner, and applies hysteresis —
//   R1 PAD STICKINESS: a carried anchor survives until the
//      pointer leaves a widened tolerance around that pad (a
//      DIFFERENT pad freshly targeted always wins).
//   R2 SNAP STICKINESS: a carried snapped endpoint survives
//      while the pointer stays inside its grid cell widened by
//      `snapHysteresis` of a step on every side.
//   R3 CORNER CARRY: a carried corner that is still a legal
//      45° corner for the new endpoint is kept verbatim, so
//      the long first segment does not move at all.
// A tap resolves through the same head (tapResolution), so the
// preview Sean sees is still exactly what a tap commits —
// KiCad's FixRoute commits the head as shown. With no carried
// state (fresh head, or a tap with no preceding hover) the
// resolution is EXACTLY the pure functions above.

extension BoardPadTarget {
    /// Stable identity for stickiness comparisons.
    var key: String { "\(reference)\u{1}\(padNumber)" }
}

struct BoardRouteHead: Equatable {
    /// The last resolved endpoint (pad centre or snapped point).
    private(set) var endPoint: FPPoint? = nil
    /// The last resolved pad anchor's key, if anchored.
    private(set) var targetKey: String? = nil
    /// The last resolved corner, if the head had one.
    private(set) var cornerPoint: FPPoint? = nil

    /// R1: the anchor tolerance multiplier for stickiness.
    static let padHysteresisFactor = 1.6
    /// R2: how far past a snap cell's edge (fraction of one grid
    /// step) the pointer may wander before the endpoint moves.
    static let snapHysteresis = 0.30

    /// Forget all carried state (route start/finish, tool
    /// change, board change).
    mutating func reset() {
        endPoint = nil
        targetKey = nil
        cornerPoint = nil
    }

    /// Is `corner` a legal 45° corner between `from` and `to`
    /// (both segments axis-aligned or exactly diagonal)?
    static func isLegalCorner(_ corner: FPPoint, from: FPPoint,
                              to: FPPoint) -> Bool {
        func legal(_ a: FPPoint, _ b: FPPoint) -> Bool {
            let dx = abs(b.x - a.x), dy = abs(b.y - a.y)
            return dx < 1e-9 || dy < 1e-9 || abs(dx - dy) < 1e-9
        }
        return legal(from, corner) && legal(corner, to)
    }

    /// Resolve the preview for `pointer`, applying the carried
    /// hysteresis. `from` is the last anchored route point.
    mutating func resolve(_ model: BoardModel, from: FPPoint,
                          pointer: FPPoint, routeNet: String?,
                          snapEnabled: Bool, gridMil: Double,
                          tolerance: Double) -> BoardRoutePreview {
        var resolved = BoardGeometry.routePreview(
            model, from: from, pointer: pointer, routeNet: routeNet,
            snapEnabled: snapEnabled, gridMil: gridMil,
            tolerance: tolerance)

        // R1 — pad stickiness.
        if let carriedKey = targetKey, resolved.target?.key != carriedKey,
           resolved.target == nil {
            if let sticky = BoardGeometry.padTarget(
                model, point: pointer,
                tolerance: tolerance * Self.padHysteresisFactor),
               sticky.key == carriedKey {
                let refused = routeNet != nil && sticky.netName != nil
                    && sticky.netName != routeNet
                resolved = BoardRoutePreview(
                    endPoint: sticky.center, corner: nil,
                    target: sticky, joinRefused: refused)
            }
        }

        // R2 — snap stickiness (free endpoints only: an anchored
        // carried endpoint is R1's business, never frozen here).
        let gridMM = BoardUnits.mm(fromMil: gridMil)
        if resolved.target == nil, targetKey == nil, snapEnabled,
           gridMM > 0, let carried = endPoint {
            let reach = gridMM * (0.5 + Self.snapHysteresis)
            if abs(pointer.x - carried.x) <= reach
                && abs(pointer.y - carried.y) <= reach {
                resolved = BoardRoutePreview(
                    endPoint: carried, corner: nil,
                    target: nil, joinRefused: false)
            }
        }

        // R3 — corner carry, else the pure corner.
        if let carriedCorner = cornerPoint,
           Self.isLegalCorner(carriedCorner, from: from, to: resolved.endPoint) {
            resolved.corner = carriedCorner
        } else {
            resolved.corner = BoardGeometry.routeCorner(
                from: from, to: resolved.endPoint)
        }

        endPoint = resolved.endPoint
        targetKey = resolved.target?.key
        cornerPoint = resolved.corner
        return resolved
    }

    /// Resolve a Route Tracks tap THROUGH this head: while
    /// routing, the tap commits the head exactly as previewed
    /// (same endpoint, same refusal rule). Before routing, the
    /// tap is the pure routeTap answer verbatim (a start must
    /// land on the pad actually tapped, no stickiness).
    mutating func tapResolution(_ model: BoardModel, from: FPPoint?,
                                point: FPPoint, routingActive: Bool,
                                routeNet: String?, snapEnabled: Bool,
                                gridMil: Double, tolerance: Double)
        -> BoardRouteTap {
        guard routingActive, let from else {
            return BoardGeometry.routeTap(
                model, point: point, routingActive: routingActive,
                routeNet: routeNet, snapEnabled: snapEnabled,
                gridMil: gridMil, tolerance: tolerance)
        }
        let preview = resolve(model, from: from, pointer: point,
                              routeNet: routeNet, snapEnabled: snapEnabled,
                              gridMil: gridMil, tolerance: tolerance)
        if let target = preview.target {
            if preview.joinRefused, let padNet = target.netName {
                return .refusedForeignNet(padNet)
            }
            return .finishAtPad(target)
        }
        return .appendPoint(preview.endPoint)
    }
}

/// Pointer-update coalescing (part 5.2): hover recognizers can
/// deliver faster than the display refreshes; without coalescing
/// every event re-renders the board. The throttle admits at most
/// one point per `interval`; offers inside the window collapse
/// into `pending` (latest wins), which the view flushes on its
/// display cadence. Pure and clock-injected so the fixture can
/// drive it deterministically; the view supplies CACurrentMediaTime.
struct BoardPointerThrottle: Equatable {
    /// Minimum seconds between admitted points (default 60 Hz —
    /// the iPad Air M3 panel rate; ProMotion devices simply get
    /// the same stable cadence).
    var interval: Double = 1.0 / 60.0
    private(set) var lastFlushTime: Double = -Double.infinity
    private(set) var pending: FPPoint? = nil

    var hasPending: Bool { pending != nil }

    /// Offer a point at `time`: returns it when the window has
    /// elapsed (admit now), else stores it as pending (nil).
    mutating func offer(_ point: FPPoint, at time: Double) -> FPPoint? {
        if time - lastFlushTime >= interval {
            lastFlushTime = time
            pending = nil
            return point
        }
        pending = point
        return nil
    }

    /// Release the pending point when the window has elapsed
    /// (the view calls this once per display tick).
    mutating func flush(at time: Double) -> FPPoint? {
        guard let pending, time - lastFlushTime >= interval
        else { return nil }
        self.pending = nil
        lastFlushTime = time
        return pending
    }

    /// The stream ended: no trailing point is owed.
    mutating func end() { pending = nil }
}

// MARK: - Trace segment editing (part 5.1)
//
// Sean (2026-11-01 21:39): "when you click on a trace, it selects
// the entire thing — make it into different lines that go from
// one point to another, kind of like KiCad does." KiCad's model:
// a track is a chain of individual SEGMENTS joined at vertices
// (corners); you select and edit it segment by segment. The
// persisted form does NOT change — a trace stays one polyline
// (`BoardTrace.points`) — but every editing operation below works
// at segment/vertex granularity, exactly like the routing code
// above works at pad granularity.
//
// All of it is pure point algebra on BoardTrace values, so the
// BoardFixture harness proves the same functions the editor's
// gestures call. Snapping is the CALLER's job (the editor snaps
// the drag target with BoardGrid before calling, like every other
// move); these functions take final points.

/// One segment of a trace: segment `index` runs from
/// `points[index]` to `points[index + 1]`.
struct BoardSegmentRef: Equatable, Hashable {
    var traceID: UUID
    var index: Int
}

/// One vertex (corner point) of a trace: `points[index]`.
struct BoardVertexRef: Equatable, Hashable {
    var traceID: UUID
    var index: Int
}

extension BoardTrace {
    /// How many segments the polyline has (points − 1).
    var segmentCount: Int { max(0, points.count - 1) }

    /// Length of segment `index` in mm.
    func segmentLength(_ index: Int) -> Double {
        points[index].distance(to: points[index + 1])
    }
}

extension BoardGeometry {

    /// The point of segment a→b closest to `point` — the
    /// projection, clamped to the segment's ends.
    static func closestPointOnSegment(_ point: FPPoint,
                                      from a: FPPoint,
                                      to b: FPPoint) -> FPPoint {
        let abx = b.x - a.x, aby = b.y - a.y
        let lengthSquared = abx * abx + aby * aby
        if lengthSquared < 1e-12 { return a }
        var t = ((point.x - a.x) * abx + (point.y - a.y) * aby) / lengthSquared
        t = min(max(t, 0), 1)
        return FPPoint(x: a.x + t * abx, y: a.y + t * aby)
    }

    /// The nearest segment of ONE trace within reach of `point`,
    /// or nil. Reach is the segment analogue of `traceHit`: the
    /// tap tolerance or half the copper width, whichever reaches
    /// further. On an exact tie the LOWEST index wins (a tap on a
    /// shared vertex belongs to the segment that ends there as
    /// much as the one that starts there — the editor checks
    /// vertices first when it cares).
    static func segmentHit(_ trace: BoardTrace, point: FPPoint,
                           tolerance: Double)
        -> (index: Int, distance: Double)? {
        let reach = max(tolerance, trace.width / 2)
        guard trace.points.count > 1 else { return nil }
        var best: (index: Int, distance: Double)? = nil
        for index in 0..<trace.segmentCount {
            let d = distance(point: point,
                             segmentStart: trace.points[index],
                             segmentEnd: trace.points[index + 1])
            guard d <= reach else { continue }
            if best == nil || d < best!.distance - 1e-12 {
                best = (index, d)
            }
        }
        return best
    }

    /// The nearest segment across a set of traces (the editor
    /// passes the VISIBLE ones): the smallest distance wins, and
    /// on a tie the trace LATER in the array wins — later traces
    /// draw on top, so the tap belongs to the one Sean sees.
    static func segmentAt(_ traces: [BoardTrace], point: FPPoint,
                          tolerance: Double)
        -> (trace: BoardTrace, index: Int, distance: Double)? {
        var best: (trace: BoardTrace, index: Int, distance: Double)? = nil
        for trace in traces {
            guard let hit = segmentHit(trace, point: point,
                                       tolerance: tolerance)
            else { continue }
            if best == nil || hit.distance <= best!.distance + 1e-12 {
                best = (trace, hit.index, hit.distance)
            }
        }
        return best
    }

    /// The nearest vertex of one trace within `tolerance`, or
    /// nil. Vertices are points, so there is no width term — the
    /// editor passes a handle-sized tolerance.
    static func vertexHit(_ trace: BoardTrace, point: FPPoint,
                          tolerance: Double)
        -> (index: Int, distance: Double)? {
        var best: (index: Int, distance: Double)? = nil
        for (index, vertex) in trace.points.enumerated() {
            let d = vertex.distance(to: point)
            guard d <= tolerance else { continue }
            if best == nil || d < best!.distance - 1e-12 {
                best = (index, d)
            }
        }
        return best
    }

    // -- Edit algebra (pure: trace in, trace out) --

    /// Move one vertex to a new point. The two adjacent segments
    /// follow (they share the point); an endpoint move stretches
    /// its one segment. Nothing else about the trace changes.
    static func traceWithVertexMoved(_ trace: BoardTrace, vertex: Int,
                                     to point: FPPoint) -> BoardTrace {
        guard trace.points.indices.contains(vertex) else { return trace }
        var edited = trace
        edited.points[vertex] = point
        return edited
    }

    /// Translate one segment by `delta`: BOTH its endpoints move
    /// by the same delta, so the segment keeps its length and
    /// angle, and the neighbouring segments stretch straight to
    /// the new endpoints (KiCad's segment drag).
    static func traceWithSegmentMoved(_ trace: BoardTrace, segment: Int,
                                      by delta: FPPoint) -> BoardTrace {
        guard segment >= 0, segment < trace.segmentCount else { return trace }
        var edited = trace
        edited.points[segment] = FPPoint(x: edited.points[segment].x + delta.x,
                                         y: edited.points[segment].y + delta.y)
        edited.points[segment + 1] = FPPoint(
            x: edited.points[segment + 1].x + delta.x,
            y: edited.points[segment + 1].y + delta.y)
        return edited
    }

    /// Insert a vertex on `segment` at `point`, splitting it into
    /// two segments. The caller resolves `point` (the editor
    /// projects the tap onto the segment, then snaps).
    static func traceWithVertexInserted(_ trace: BoardTrace, segment: Int,
                                        at point: FPPoint) -> BoardTrace {
        guard segment >= 0, segment < trace.segmentCount else { return trace }
        var edited = trace
        edited.points.insert(point, at: segment + 1)
        return edited
    }

    /// Remove one vertex: its two neighbouring segments join
    /// straight (an endpoint removal just shortens the trace).
    /// Returns nil when the trace would be left with fewer than
    /// 2 points — a 2-point trace loses its only segment, so the
    /// trace itself goes (the editor maps nil to removal, the
    /// same way KiCad deletes a track whose last segment goes).
    static func traceWithVertexRemoved(_ trace: BoardTrace, vertex: Int)
        -> BoardTrace? {
        guard trace.points.indices.contains(vertex) else { return trace }
        var edited = trace
        edited.points.remove(at: vertex)
        return edited.points.count >= 2 ? edited : nil
    }

    /// Remove a SET of segments from one trace, splitting it at
    /// the gaps: each maximal run of surviving segments becomes
    /// its own trace with the SAME net (or remembered net), layer
    /// and width. The FIRST surviving piece keeps the original
    /// trace id (selection/identity continuity); later pieces get
    /// fresh ids. Removing every segment removes the trace.
    /// Indices are the trace's CURRENT segment indices.
    static func tracesByRemovingSegments(_ trace: BoardTrace,
                                         indices: Set<Int>) -> [BoardTrace] {
        let count = trace.segmentCount
        guard count > 0 else { return [trace] }
        var pieces: [BoardTrace] = []
        var runStart: Int? = nil
        func closeRun(upToSegment end: Int) {
            guard let start = runStart else { return }
            var piece = trace
            piece.points = Array(trace.points[start...(end + 1)])
            if !pieces.isEmpty { piece.id = UUID() }
            pieces.append(piece)
            runStart = nil
        }
        for segment in 0..<count {
            if indices.contains(segment) {
                closeRun(upToSegment: segment - 1)
            } else if runStart == nil {
                runStart = segment
            }
        }
        closeRun(upToSegment: count - 1)
        return pieces
    }
}

// MARK: - Placement tools: align / distribute / duplicate / measure (part 5.2)
//
// From KiCad's pcbnew placement tools (placement_tool.cpp:
// Align / Distribute / Duplicate). All pure algebra over the
// merged model + placements, so the fixture proves the exact
// functions the editor's buttons call; the editor folds the
// results into ONE mutateBoard step.

enum BoardAlignMode {
    case left, right, top, bottom, centreX, centreY
}

enum BoardPlacementTools {

    /// A component's practical extent: the bbox of its pads'
    /// outlines (rotation/side true). Components without pads
    /// fall back to the footprint-bounds box.
    static func extent(_ component: BoardComponent)
        -> (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        guard let footprint = component.footprint, !footprint.pads.isEmpty
        else { return BoardGeometry.componentBounds(component) }
        var minX = Double.greatestFiniteMagnitude, minY = minX
        var maxX = -minX, maxY = -minX
        for pad in footprint.pads {
            for p in BoardGeometry.padOutline(component, pad) {
                minX = min(minX, p.x); minY = min(minY, p.y)
                maxX = max(maxX, p.x); maxY = max(maxY, p.y)
            }
        }
        return (minX, minY, maxX, maxY)
    }

    /// New origins aligning the given components (looked up in
    /// `model` by reference). Edge modes align to the selection's
    /// extreme edge; centre modes align to the FIRST listed
    /// reference's centre (the anchor — KiCad aligns to a
    /// reference item). Only references that actually move are
    /// returned. Locked references never move (the editor also
    /// refuses, this is the model-level guarantee).
    static func alignedOrigins(_ model: BoardModel, references: [String],
                               mode: BoardAlignMode,
                               lockedReferences: Set<String>)
        -> [String: FPPoint] {
        let components = references.compactMap { ref in
            model.components.first { $0.reference == ref }
        }
        guard components.count > 1 else { return [:] }
        let extents = components.map { extent($0) }
        var result: [String: FPPoint] = [:]
        func move(_ component: BoardComponent, dx: Double, dy: Double) {
            guard !lockedReferences.contains(component.reference)
            else { return }
            let newOrigin = FPPoint(x: component.origin.x + dx,
                                    y: component.origin.y + dy)
            if newOrigin != component.origin {
                result[component.reference] = newOrigin
            }
        }
        switch mode {
        case .left:
            let target = extents.map(\.minX).min()!
            for (c, e) in zip(components, extents) { move(c, dx: target - e.minX, dy: 0) }
        case .right:
            let target = extents.map(\.maxX).max()!
            for (c, e) in zip(components, extents) { move(c, dx: target - e.maxX, dy: 0) }
        case .top:
            let target = extents.map(\.minY).min()!
            for (c, e) in zip(components, extents) { move(c, dx: 0, dy: target - e.minY) }
        case .bottom:
            let target = extents.map(\.maxY).max()!
            for (c, e) in zip(components, extents) { move(c, dx: 0, dy: target - e.maxY) }
        case .centreX:
            let anchor = (extents[0].minX + extents[0].maxX) / 2
            for (c, e) in zip(components, extents) {
                move(c, dx: anchor - (e.minX + e.maxX) / 2, dy: 0)
            }
        case .centreY:
            let anchor = (extents[0].minY + extents[0].maxY) / 2
            for (c, e) in zip(components, extents) {
                move(c, dx: 0, dy: anchor - (e.minY + e.maxY) / 2)
            }
        }
        return result
    }

    /// New origins distributing the given components' CENTRES
    /// evenly along one axis between the two extreme components
    /// (which stay put — KiCad's distribute). Needs 3+ references;
    /// locked components keep their origin but still occupy
    /// their slot in the spacing (they are physical parts).
    static func distributedOrigins(_ model: BoardModel, references: [String],
                                   horizontal: Bool,
                                   lockedReferences: Set<String>)
        -> [String: FPPoint] {
        let components = references.compactMap { ref in
            model.components.first { $0.reference == ref }
        }
        guard components.count > 2 else { return [:] }
        let centres: [(component: BoardComponent, centre: Double, origin: FPPoint)] =
            components.map { c in
                let e = extent(c)
                return (c, horizontal ? (e.minX + e.maxX) / 2 : (e.minY + e.maxY) / 2,
                        c.origin)
            }
        let sorted = centres.sorted { $0.centre < $1.centre }
        let first = sorted.first!.centre, last = sorted.last!.centre
        guard last > first else { return [:] }
        let step = (last - first) / Double(sorted.count - 1)
        var result: [String: FPPoint] = [:]
        for (index, entry) in sorted.enumerated() {
            let target = first + step * Double(index)
            let delta = target - entry.centre
            if abs(delta) < 1e-9 { continue }
            guard !lockedReferences.contains(entry.component.reference)
            else { continue }
            result[entry.component.reference] = horizontal
                ? FPPoint(x: entry.origin.x + delta, y: entry.origin.y)
                : FPPoint(x: entry.origin.x, y: entry.origin.y + delta)
        }
        return result
    }
}

extension BoardState {
    /// Offset copies of the named board items with FRESH ids
    /// (KiCad duplicate: the copy is a new item, offset so it
    /// doesn't sit exactly on the original). Nets, layers,
    /// widths and zone/via parameters carry over verbatim;
    /// remembered-net state (disconnectedNetName) carries too —
    /// the copies are the same electrical intent, displaced.
    func duplicatedItems(traceIDs: Set<UUID>, viaIDs: Set<UUID>,
                         zoneIDs: Set<UUID>, graphicIDs: Set<UUID>,
                         offset: FPPoint)
        -> (traces: [BoardTrace], vias: [BoardVia],
            zones: [BoardZone], graphics: [BoardGraphicItem]) {
        func shifted(_ points: [FPPoint]) -> [FPPoint] {
            points.map { FPPoint(x: $0.x + offset.x, y: $0.y + offset.y) }
        }
        var newTraces: [BoardTrace] = []
        for trace in traces where traceIDs.contains(trace.id) {
            var copy = trace
            copy.id = UUID()
            copy.points = shifted(trace.points)
            newTraces.append(copy)
        }
        var newVias: [BoardVia] = []
        for via in vias where viaIDs.contains(via.id) {
            var copy = via
            copy.id = UUID()
            copy.center = FPPoint(x: via.center.x + offset.x,
                                  y: via.center.y + offset.y)
            newVias.append(copy)
        }
        var newZones: [BoardZone] = []
        for zone in zones where zoneIDs.contains(zone.id) {
            var copy = zone
            copy.id = UUID()
            copy.points = shifted(zone.points)
            newZones.append(copy)
        }
        var newGraphics: [BoardGraphicItem] = []
        for item in graphics where graphicIDs.contains(item.id) {
            var copy = item
            copy.id = UUID()
            copy.points = shifted(item.points)
            newGraphics.append(copy)
        }
        return (newTraces, newVias, newZones, newGraphics)
    }
}

/// The measuring tool's state (KiCad's measure / "Tape Measure"):
/// two tapped points; a third tap starts a new measurement.
struct BoardMeasure: Equatable {
    private(set) var a: FPPoint? = nil
    private(set) var b: FPPoint? = nil

    mutating func tap(_ point: FPPoint) {
        if a == nil || b != nil {
            a = point
            b = nil
        } else {
            b = point
        }
    }

    mutating func clear() { a = nil; b = nil }

    /// The measured distance, once both points exist.
    var distance: Double? {
        guard let a, let b else { return nil }
        return a.distance(to: b)
    }

    /// Axis deltas (b − a), once both points exist.
    var delta: FPPoint? {
        guard let a, let b else { return nil }
        return FPPoint(x: b.x - a.x, y: b.y - a.y)
    }
}

// MARK: - Spatial index for hit-testing (part 5.2)
//
// Part B of the v5.2 pass (KiCad-inspired: pcbnew hit-testing
// runs over an R-tree of board items, never a whole-board scan).
// Every hover redraw in v5.1 re-ran padAt / traceAt / segmentAt
// as LINEAR scans over the whole board — at Pencil hover rates
// that put the full pad/segment algebra on the pointer path.
// BoardSpatialIndex is a uniform-grid index (2 mm cells) over
// the merged model: each query gathers only the items whose
// cells the query region touches, then applies the EXACT
// BoardGeometry tests and winner rules to those candidates, so
// results are identical to the linear scans by construction
// (the BoardFixture harness proves set- and winner-equality
// against the linear functions over synthetic boards at several
// tolerances, and prints the timing ratio).
//
// Correctness invariant (per item kind): an item is inserted
// into every cell its HIT REGION's axis-aligned bounds touch,
// where the hit region already includes the item's own reach
// (trace width/2, via radius, circle radius, text size). A query
// visits every cell intersecting the square of half-side
// `tolerance * padReachFactor` (pads) or `tolerance` (others)
// around the point; any item the linear test would pass has its
// hit region intersecting that square (a passed test puts the
// point inside the region grown by at most tolerance — √2 ·
// tolerance for the rotated pad test), so its cells are visited
// and the exact test runs. Candidate iteration always follows
// the linear functions' order/tie rules.

struct BoardSpatialIndex {
    /// Grid cell size in mm.
    static let cellSize = 2.0
    /// Pad queries widen the visited square by this factor:
    /// the pad test runs in the pad's ROTATED frame, so a
    /// passing point can sit up to √2 · tolerance outside the
    /// outline bounds on a world axis; 1.5 covers it.
    static let padReachFactor = 1.5

    private struct Cell: Hashable { var x: Int; var y: Int }
    private struct PadRef: Hashable { var component: Int; var pad: Int }
    private struct SegmentRef: Hashable { var trace: Int; var segment: Int }

    private var padCells: [Cell: [PadRef]] = [:]
    private var segmentCells: [Cell: [SegmentRef]] = [:]
    private var traceCells: [Cell: [Int]] = [:]
    private var viaCells: [Cell: [Int]] = [:]
    private var componentCells: [Cell: [Int]] = [:]
    private var zoneCells: [Cell: [Int]] = [:]
    private var graphicCells: [Cell: [Int]] = [:]

    private static func cell(of value: Double) -> Int {
        Int(floor(value / cellSize))
    }

    private static func cells(minX: Double, minY: Double,
                              maxX: Double, maxY: Double) -> [Cell] {
        var result: [Cell] = []
        for cx in cell(of: minX)...cell(of: maxX) {
            for cy in cell(of: minY)...cell(of: maxY) {
                result.append(Cell(x: cx, y: cy))
            }
        }
        return result
    }

    private func queryCells(point: FPPoint, halfSide: Double) -> [Cell] {
        Self.cells(minX: point.x - halfSide, minY: point.y - halfSide,
                   maxX: point.x + halfSide, maxY: point.y + halfSide)
    }

    /// Build the index over a merged model. O(items); the editor
    /// rebuilds it wherever it recomputes the checks (mutation
    /// points only — never on the pointer path).
    static func build(_ model: BoardModel) -> BoardSpatialIndex {
        var index = BoardSpatialIndex()
        for (ci, component) in model.components.enumerated() {
            let b = BoardGeometry.componentBounds(component)
            for cell in cells(minX: b.minX, minY: b.minY,
                              maxX: b.maxX, maxY: b.maxY) {
                index.componentCells[cell, default: []].append(ci)
            }
            guard let footprint = component.footprint else { continue }
            for (pi, pad) in footprint.pads.enumerated() {
                let outline = BoardGeometry.padOutline(component, pad)
                guard let first = outline.first else { continue }
                var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
                for p in outline {
                    minX = min(minX, p.x); minY = min(minY, p.y)
                    maxX = max(maxX, p.x); maxY = max(maxY, p.y)
                }
                for cell in cells(minX: minX, minY: minY, maxX: maxX, maxY: maxY) {
                    index.padCells[cell, default: []].append(
                        PadRef(component: ci, pad: pi))
                }
            }
        }
        for (ti, trace) in model.traces.enumerated() {
            guard trace.points.count > 1 else { continue }
            let reach = trace.width / 2
            var traceMinX = Double.greatestFiniteMagnitude
            var traceMinY = traceMinX, traceMaxX = -traceMinX, traceMaxY = -traceMinX
            for segment in 0..<trace.segmentCount {
                let a = trace.points[segment], b = trace.points[segment + 1]
                let minX = min(a.x, b.x) - reach, minY = min(a.y, b.y) - reach
                let maxX = max(a.x, b.x) + reach, maxY = max(a.y, b.y) + reach
                traceMinX = min(traceMinX, minX); traceMinY = min(traceMinY, minY)
                traceMaxX = max(traceMaxX, maxX); traceMaxY = max(traceMaxY, maxY)
                for cell in cells(minX: minX, minY: minY, maxX: maxX, maxY: maxY) {
                    index.segmentCells[cell, default: []].append(
                        SegmentRef(trace: ti, segment: segment))
                }
            }
            for cell in cells(minX: traceMinX, minY: traceMinY,
                              maxX: traceMaxX, maxY: traceMaxY) {
                index.traceCells[cell, default: []].append(ti)
            }
        }
        for (vi, via) in model.vias.enumerated() {
            let r = via.diameter / 2
            for cell in cells(minX: via.center.x - r, minY: via.center.y - r,
                              maxX: via.center.x + r, maxY: via.center.y + r) {
                index.viaCells[cell, default: []].append(vi)
            }
        }
        for (zi, zone) in model.zones.enumerated() {
            guard let first = zone.points.first else { continue }
            var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
            for p in zone.points {
                minX = min(minX, p.x); minY = min(minY, p.y)
                maxX = max(maxX, p.x); maxY = max(maxY, p.y)
            }
            for cell in cells(minX: minX, minY: minY, maxX: maxX, maxY: maxY) {
                index.zoneCells[cell, default: []].append(zi)
            }
        }
        for (gi, item) in model.graphics.enumerated() {
            // The item's hit region bounds (see the type comment):
            // circle → centre ± radius; text → anchor ± text size;
            // line/arc → the points' bounds.
            var minX = Double.greatestFiniteMagnitude
            var minY = minX, maxX = -minX, maxY = -minX
            func include(_ p: FPPoint, pad: Double = 0) {
                minX = min(minX, p.x - pad); minY = min(minY, p.y - pad)
                maxX = max(maxX, p.x + pad); maxY = max(maxY, p.y + pad)
            }
            switch item.kind {
            case .circle:
                if let centre = item.points.first {
                    include(centre, pad: item.radius)
                }
            case .text:
                if let anchor = item.points.first {
                    include(anchor, pad: item.textSize)
                }
            case .line, .arc:
                for p in item.points { include(p) }
            }
            guard minX <= maxX else { continue }
            for cell in cells(minX: minX, minY: minY, maxX: maxX, maxY: maxY) {
                index.graphicCells[cell, default: []].append(gi)
            }
        }
        return index
    }

    // MARK: Queries (BoardGeometry-identical results)

    func padAt(_ model: BoardModel, point: FPPoint, tolerance: Double)
        -> (component: BoardComponent, pad: KiCadFootprintPad, netName: String?)? {
        var candidates = Set<PadRef>()
        for cell in queryCells(point: point,
                               halfSide: tolerance * Self.padReachFactor) {
            for ref in padCells[cell] ?? [] { candidates.insert(ref) }
        }
        var best: (component: BoardComponent, pad: KiCadFootprintPad,
                   netName: String?, distance: Double)? = nil
        var bestRef: PadRef? = nil
        for ref in candidates {
            let component = model.components[ref.component]
            guard let footprint = component.footprint else { continue }
            let pad = footprint.pads[ref.pad]
            let effective = BoardGeometry.boardPad(component, pad)
            let centre = BoardGeometry.padCenter(component, pad)
            let halfW = effective.width / 2 + tolerance
            let halfH = effective.height / 2 + tolerance
            let local = FPPoint(x: point.x - centre.x, y: point.y - centre.y)
                .rotated(degrees: -effective.rotation)
            guard abs(local.x) <= halfW, abs(local.y) <= halfH else { continue }
            let distance = centre.distance(to: point)
            // The linear scan's winner on an exact distance tie is
            // the FIRST pad in model order (its comparison is a
            // strict <); replicate that over the unordered
            // candidate set.
            let winsTie = bestRef != nil && distance == best!.distance
                && (ref.component, ref.pad) < (bestRef!.component, bestRef!.pad)
            if best == nil || distance < best!.distance || winsTie {
                best = (component, pad, BoardGeometry.netName(component, pad),
                        distance)
                bestRef = ref
            }
        }
        guard let found = best else { return nil }
        return (found.component, found.pad, found.netName)
    }

    func padTarget(_ model: BoardModel, point: FPPoint,
                   tolerance: Double) -> BoardPadTarget? {
        guard let hit = padAt(model, point: point, tolerance: tolerance)
        else { return nil }
        let effective = BoardGeometry.boardPad(hit.component, hit.pad)
        return BoardPadTarget(
            reference: hit.component.reference,
            padNumber: hit.pad.number,
            netName: hit.netName,
            center: BoardGeometry.padCenter(hit.component, hit.pad),
            width: effective.width, height: effective.height)
    }

    func traceAt(_ model: BoardModel, point: FPPoint,
                 tolerance: Double) -> BoardTrace? {
        var candidates = Set<Int>()
        for cell in queryCells(point: point, halfSide: tolerance) {
            for ti in traceCells[cell] ?? [] { candidates.insert(ti) }
        }
        for ti in candidates.sorted(by: >) {
            let trace = model.traces[ti]
            if BoardGeometry.traceHit(trace, point: point, tolerance: tolerance) {
                return trace
            }
        }
        return nil
    }

    func hoverTarget(_ model: BoardModel, point: FPPoint,
                     tolerance: Double) -> BoardHoverTarget? {
        if let target = padTarget(model, point: point, tolerance: tolerance) {
            return .pad(target)
        }
        if let trace = traceAt(model, point: point, tolerance: tolerance) {
            return .trace(trace.id)
        }
        return nil
    }

    /// Indexed twin of BoardGeometry.segmentAt over the model's
    /// traces, optionally restricted to a set of trace ids (the
    /// editor passes its VISIBLE traces). Same winner rules:
    /// per-trace nearest segment, smallest distance wins, ties
    /// go to the trace later in model order.
    func segmentAt(_ model: BoardModel, point: FPPoint, tolerance: Double,
                   allowedTraceIDs: Set<UUID>? = nil)
        -> (trace: BoardTrace, index: Int, distance: Double)? {
        var candidates = Set<Int>()
        for cell in queryCells(point: point, halfSide: tolerance) {
            for ref in segmentCells[cell] ?? [] { candidates.insert(ref.trace) }
        }
        var best: (trace: BoardTrace, index: Int, distance: Double)? = nil
        for ti in candidates.sorted() {
            let trace = model.traces[ti]
            if let allowedTraceIDs, !allowedTraceIDs.contains(trace.id) {
                continue
            }
            guard let hit = BoardGeometry.segmentHit(
                trace, point: point, tolerance: tolerance) else { continue }
            if best == nil || hit.distance <= best!.distance + 1e-12 {
                best = (trace, hit.index, hit.distance)
            }
        }
        return best
    }

    func componentAt(_ model: BoardModel, point: FPPoint,
                     tolerance: Double = 0.5) -> BoardComponent? {
        var candidates = Set<Int>()
        for cell in queryCells(point: point, halfSide: tolerance) {
            for ci in componentCells[cell] ?? [] { candidates.insert(ci) }
        }
        for ci in candidates.sorted(by: >) {
            let component = model.components[ci]
            let b = BoardGeometry.componentBounds(component)
            if point.x >= b.minX - tolerance, point.x <= b.maxX + tolerance,
               point.y >= b.minY - tolerance, point.y <= b.maxY + tolerance {
                return component
            }
        }
        return nil
    }

    func viaAt(_ model: BoardModel, point: FPPoint,
               tolerance: Double) -> BoardVia? {
        var candidates = Set<Int>()
        for cell in queryCells(point: point, halfSide: tolerance) {
            for vi in viaCells[cell] ?? [] { candidates.insert(vi) }
        }
        for vi in candidates.sorted(by: >) {
            let via = model.vias[vi]
            if BoardGeometry.viaHit(via, point: point, tolerance: tolerance) {
                return via
            }
        }
        return nil
    }

    func zoneAt(_ model: BoardModel, point: FPPoint,
                tolerance: Double) -> BoardZone? {
        var candidates = Set<Int>()
        for cell in queryCells(point: point, halfSide: tolerance) {
            for zi in zoneCells[cell] ?? [] { candidates.insert(zi) }
        }
        for zi in candidates.sorted(by: >) {
            let zone = model.zones[zi]
            if BoardGeometry.zoneHit(zone, point: point, tolerance: tolerance) {
                return zone
            }
        }
        return nil
    }

    func graphicAt(_ model: BoardModel, point: FPPoint,
                   tolerance: Double) -> BoardGraphicItem? {
        var candidates = Set<Int>()
        for cell in queryCells(point: point, halfSide: tolerance) {
            for gi in graphicCells[cell] ?? [] { candidates.insert(gi) }
        }
        for gi in candidates.sorted(by: >) {
            let item = model.graphics[gi]
            if BoardGeometry.graphicHit(item, point: point, tolerance: tolerance) {
                return item
            }
        }
        return nil
    }
}
