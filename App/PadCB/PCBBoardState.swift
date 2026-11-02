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

    static let empty = BoardState()
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
             copperLayerCount, gridMil, clearanceMil
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
struct BoardPointerState: Equatable {
    /// Last hover position (pencil or pointer), nil when the
    /// pointer is not over the canvas.
    private(set) var hoverPoint: FPPoint? = nil
    /// Last touch position while a touch is down.
    private(set) var touchPoint: FPPoint? = nil
    /// True between a touch's first move and its end.
    private(set) var touchActive = false

    /// The point previews follow: the touch point while a touch
    /// is down, else the hover point.
    var currentPoint: FPPoint? { touchActive ? touchPoint : hoverPoint }

    mutating func apply(_ event: BoardPointerEvent) {
        switch event {
        case .hoverMoved(let point):
            hoverPoint = point
        case .hoverEnded:
            hoverPoint = nil
        case .touchMoved(let point):
            touchPoint = point
            touchActive = true
        case .touchEnded:
            touchActive = false
            touchPoint = nil
        }
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
