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
struct BoardState: Codable, Equatable {
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

    static let empty = BoardState()
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

        // -- Placements --
        for index in model.components.indices {
            if let placement = state.placements[model.components[index].reference] {
                model.components[index].origin = placement
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
        model.traces = traces
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

    static let copperLayers = ["F.Cu", "In1.Cu", "In2.Cu", "B.Cu"]

    /// Is one layer name shown? The KiCad wildcard "*.Cu" counts as
    /// shown when ANY copper layer is shown.
    func layerShown(_ layer: String) -> Bool {
        if layer == "*.Cu" {
            return Self.copperLayers.contains { !hiddenLayers.contains($0) }
        }
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
        case component, trace, graphic, text
    }

    var components = true
    var traces = true
    var graphics = true
    var text = true

    /// The "All items" row: on exactly when every class is on.
    var allItems: Bool { components && traces && graphics && text }

    mutating func setAll(_ on: Bool) {
        components = on
        traces = on
        graphics = on
        text = on
    }

    func allows(_ kind: ItemKind) -> Bool {
        switch kind {
        case .component: return components
        case .trace: return traces
        case .graphic: return graphics
        case .text: return text
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
    /// bounds at its origin, or the placeholder box).
    static func componentBounds(_ component: BoardComponent)
        -> (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        if let footprint = component.footprint {
            let b = footprint.bounds
            return (component.origin.x + b.minX, component.origin.y + b.minY,
                    component.origin.x + b.maxX, component.origin.y + b.maxY)
        }
        return (component.origin.x, component.origin.y,
                component.origin.x + component.boundsSize.w,
                component.origin.y + component.boundsSize.h)
    }

    /// Board-space centre of one pad of a placed component.
    static func padCenter(_ component: BoardComponent,
                          _ pad: KiCadFootprintPad) -> FPPoint {
        FPPoint(x: component.origin.x + pad.x, y: component.origin.y + pad.y)
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
                let centre = padCenter(component, pad)
                let halfW = pad.width / 2 + tolerance
                let halfH = pad.height / 2 + tolerance
                let local = FPPoint(x: point.x - centre.x, y: point.y - centre.y)
                    .rotated(degrees: -pad.rotation)
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
