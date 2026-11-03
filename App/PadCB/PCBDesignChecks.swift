import Foundation

/// PCB design data + checks (part 5): units, the configurable
/// layer stack, the snap grid, and the three checking tiers —
/// net-touch/clearance, the manufacturing rule set, and the
/// design-theory heuristics — plus the compact board summary the
/// optional on-device AI pass reads.
///
/// Foundation only, like PCBBoardState.swift, so the exact code
/// the editor runs compiles into the BoardFixture harness.
/// Board coordinates throughout: millimetres, x right, y DOWN.
/// User-facing sizes are mils (1 mil = 0.0254 mm) because that's
/// what Sean asked for; mm is always shown alongside.

// MARK: - Units

enum BoardUnits {
    static let mmPerMil = 0.0254

    static func mm(fromMil mil: Double) -> Double { mil * mmPerMil }
    static func mil(fromMM mm: Double) -> Double { mm / mmPerMil }

    /// "0.25" style mm formatting (same convention as the merger).
    static func formatMM(_ value: Double) -> String {
        PCBBoardMerger.formatMM(value)
    }

    /// "9.8" style mil formatting (one decimal, trimmed).
    static func formatMil(_ value: Double) -> String {
        let text = String(format: "%.1f", value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    /// A length in both units: "12.70 mm · 500 mil".
    static func formatLength(mm: Double) -> String {
        "\(formatMM(mm)) mm · \(formatMil(mil(fromMM: mm))) mil"
    }
}

// MARK: - Layers

/// The board's layer stack. Copper layers are CONFIGURABLE in
/// count (part 5): F.Cu + In1.Cu…In(n−2).Cu + B.Cu, KiCad-style.
/// Non-copper layers are a fixed set. "Flip Side" destinations are
/// exactly the two outer copper layers.
enum BoardLayers {
    /// Copper counts the editor offers.
    static let copperCountChoices = [2, 4, 6, 8, 16, 32]

    /// The destinations the Change Layer / Flip Side action offers
    /// — front and back copper ONLY, never inner or non-copper.
    static let flipDestinations = ["F.Cu", "B.Cu"]

    static func copperLayers(count: Int) -> [String] {
        let n = max(2, count)
        var layers = ["F.Cu"]
        if n > 2 {
            for index in 1...(n - 2) { layers.append("In\(index).Cu") }
        }
        layers.append("B.Cu")
        return layers
    }

    /// True for a real copper layer name (F.Cu, In1.Cu, …). The
    /// "*.Cu" pad wildcard is NOT a layer of its own.
    static func isCopper(_ layer: String) -> Bool {
        layer != "*.Cu" && layer.hasSuffix(".Cu")
    }

    /// Non-copper layers, in the Layers panel's order.
    static let nonCopperLayers = [
        "F.Adhes", "B.Adhes", "F.Paste", "B.Paste", "F.SilkS",
        "B.SilkS", "F.Mask", "B.Mask", "Dwgs.User", "Edge.Cuts",
        "F.CrtYd", "B.CrtYd", "F.Fab", "B.Fab",
    ]

    /// Every layer in the stack (copper in stack order, then the
    /// non-copper set) — the Layers panel / active-layer pickers.
    static func allLayers(copperCount: Int) -> [String] {
        copperLayers(count: copperCount) + nonCopperLayers
    }

    /// Does this layer exist on a board with `copperCount` copper
    /// layers? Non-copper layers always exist; a copper layer must
    /// be in the stack. (Items stranded on a removed inner layer
    /// are kept but hidden — see PCBBoardMerger.)
    static func layerExists(_ layer: String, copperCount: Int) -> Bool {
        guard isCopper(layer) else { return true }
        return copperLayers(count: copperCount).contains(layer)
    }
}

// MARK: - Grid

/// The snap grid (part 5): spacing is user-adjustable IN MILS and
/// applies to every placement/move in the PCB editor.
enum BoardGrid {
    static let presetMils: [Double] = [1, 2, 5, 10, 25, 50, 100]

    static func snap(_ point: FPPoint, gridMil: Double) -> FPPoint {
        BoardGeometry.snapped(point, grid: BoardUnits.mm(fromMil: gridMil))
    }
}

// MARK: - Copper shapes (shared geometry for the checkers)

/// One piece of copper, reduced to outline segments + a radius —
/// the common currency of the clearance and connectivity checks.
/// - traces: polyline segments, radius = width/2 (a capsule)
/// - vias: one degenerate segment at the centre, radius = ⌀/2
/// - pads: their true outline polygon (round pads as 16-gons),
///   radius 0, `filled` so containment counts as touching
/// - zones: their polygon, radius 0, `filled`
struct CopperShape {
    enum Kind: String {
        case pad, trace, via, zone, teardrop
    }

    var kind: Kind
    /// Human label for reports: "U1 pad 1", "NET_A trace on F.Cu"…
    var label: String
    /// The net this copper belongs to; nil = unconnected copper.
    var netName: String?
    /// Copper layers occupied (board's stack names; "*.Cu" already
    /// expanded). Clearance/connectivity only apply within a layer.
    var layers: Set<String>
    /// Outline segments (capsule centrelines for trace/via).
    var segments: [(FPPoint, FPPoint)]
    /// Extra radius around the segments.
    var radius: Double
    /// For filled shapes (pad/zone): the outline polygon, used for
    /// containment tests.
    var filledPolygon: [FPPoint]?
    /// Points tested for containment in other filled shapes
    /// (vertices + centre).
    var testPoints: [FPPoint]
    /// Highlight target for the canvas.
    var highlight: CheckHighlight

    var bounds: (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude
        for (a, b) in segments {
            minX = min(minX, a.x, b.x); minY = min(minY, a.y, b.y)
            maxX = max(maxX, a.x, b.x); maxY = max(maxY, a.y, b.y)
        }
        return (minX - radius, minY - radius, maxX + radius, maxY + radius)
    }
}

/// A board item a check can point at on the canvas.
enum CheckHighlight: Equatable {
    case component(String)
    case trace(UUID)
    case via(UUID)
    case zone(UUID)
}

enum BoardCopper {

    /// Every copper shape on the board: component pads (effective —
    /// a flipped part contributes its MIRRORED pads on their flipped
    /// layers), traces, vias, zones.
    static func shapes(model: BoardModel, copperCount: Int) -> [CopperShape] {
        let stack = BoardLayers.copperLayers(count: copperCount)
        var shapes: [CopperShape] = []

        for component in model.components {
            guard let footprint = component.footprint else { continue }
            for rawPad in footprint.pads where !rawPad.number.isEmpty {
                let pad = BoardGeometry.boardPad(component, rawPad)
                let net = component.pins
                    .first { $0.pinNumber == rawPad.number }?.netName
                var layers = Set<String>()
                for layer in pad.layers {
                    if layer == "*.Cu" {
                        layers.formUnion(stack)
                    } else if BoardLayers.isCopper(layer) {
                        layers.insert(layer)
                    }
                }
                guard !layers.isEmpty else { continue }
                let outline = outlinePolygon(component: component, rawPad: rawPad)
                var segments: [(FPPoint, FPPoint)] = []
                for index in outline.indices {
                    segments.append((outline[index],
                                     outline[(index + 1) % outline.count]))
                }
                let centre = BoardGeometry.padCenter(component, rawPad)
                shapes.append(CopperShape(
                    kind: .pad,
                    label: "\(component.reference) pad \(rawPad.number)",
                    netName: net,
                    layers: layers,
                    segments: segments,
                    radius: 0,
                    filledPolygon: outline,
                    testPoints: outline + [centre],
                    highlight: .component(component.reference)))
            }
        }

        for trace in model.traces {
            guard trace.points.count > 1 else { continue }
            var segments: [(FPPoint, FPPoint)] = []
            for index in 1..<trace.points.count {
                segments.append((trace.points[index - 1], trace.points[index]))
            }
            shapes.append(CopperShape(
                kind: .trace,
                label: "trace on \(trace.layer)",
                netName: trace.netName,
                layers: [trace.layer],
                segments: segments,
                radius: trace.width / 2,
                filledPolygon: nil,
                testPoints: trace.points,
                highlight: .trace(trace.id)))
        }

        for via in model.vias {
            shapes.append(CopperShape(
                kind: .via,
                label: "via at (\(BoardUnits.formatMM(via.center.x)), \(BoardUnits.formatMM(via.center.y)))",
                netName: via.netName,
                layers: Set(stack),
                segments: [(via.center, via.center)],
                radius: via.diameter / 2,
                filledPolygon: nil,
                testPoints: [via.center],
                highlight: .via(via.id)))
        }

        for zone in model.zones where zone.points.count >= 3 {
            var segments: [(FPPoint, FPPoint)] = []
            for index in zone.points.indices {
                segments.append((zone.points[index],
                                 zone.points[(index + 1) % zone.points.count]))
            }
            shapes.append(CopperShape(
                kind: .zone,
                label: "copper fill on \(zone.layer)",
                netName: zone.netName,
                layers: [zone.layer],
                segments: segments,
                radius: 0,
                filledPolygon: zone.points,
                testPoints: zone.points,
                highlight: .zone(zone.id)))
        }

        // Teardrops (part 5.3): real copper of their net + layer,
        // shaped exactly like a zone polygon, so connectivity
        // unions them with the pad/track they flare between and
        // clearance measures them against foreign nets. With no
        // teardrops on the board this loop appends nothing and
        // every existing result is unchanged. The highlight
        // targets the ANCHOR TRACK (a teardrop has no selection
        // of its own in the check UI).
        for teardrop in model.teardrops where teardrop.points.count >= 3 {
            var segments: [(FPPoint, FPPoint)] = []
            for index in teardrop.points.indices {
                segments.append((teardrop.points[index],
                                 teardrop.points[(index + 1) % teardrop.points.count]))
            }
            shapes.append(CopperShape(
                kind: .teardrop,
                label: "teardrop on \(teardrop.layer)",
                netName: teardrop.netName,
                layers: [teardrop.layer],
                segments: segments,
                radius: 0,
                filledPolygon: teardrop.points,
                testPoints: teardrop.points,
                highlight: .trace(UUID(uuidString: teardrop.anchorTrackID) ?? UUID())))
        }
        return shapes
    }

    /// A pad's outline polygon in BOARD coordinates: round/oval
    /// pads become 16-gons of their ellipse; other shapes use the
    /// pad's outline corners (the parser's approximation).
    static func outlinePolygon(component: BoardComponent,
                               rawPad: KiCadFootprintPad) -> [FPPoint] {
        let pad = BoardGeometry.boardPad(component, rawPad)
        let centre = BoardGeometry.padCenter(component, rawPad)
        switch pad.shape {
        case .circle, .oval:
            var points: [FPPoint] = []
            let steps = 16
            for step in 0..<steps {
                let angle = Double(step) / Double(steps) * 2 * Double.pi
                let local = FPPoint(x: cos(angle) * pad.width / 2,
                                    y: sin(angle) * pad.height / 2)
                    .rotated(degrees: pad.rotation)
                points.append(FPPoint(x: centre.x + local.x,
                                      y: centre.y + local.y))
            }
            return points
        default:
            return BoardGeometry.padOutline(component, rawPad)
        }
    }

    /// Distance between two copper shapes (mm): 0 when they touch
    /// or overlap. Segment-pair distance minus both radii, with
    /// containment (a vertex/centre inside a filled outline)
    /// counting as touching. This is the approximation the report
    /// states: true outlines for pads, capsules for traces, circles
    /// for vias, polygons for zones.
    static func distance(_ a: CopperShape, _ b: CopperShape) -> Double {
        if let polygon = a.filledPolygon {
            for point in b.testPoints
            where BoardGeometry.pointInPolygon(point, polygon: polygon) {
                return 0
            }
        }
        if let polygon = b.filledPolygon {
            for point in a.testPoints
            where BoardGeometry.pointInPolygon(point, polygon: polygon) {
                return 0
            }
        }
        var best = Double.greatestFiniteMagnitude
        for (a1, a2) in a.segments {
            for (b1, b2) in b.segments {
                best = min(best, segmentDistance(a1, a2, b1, b2))
            }
        }
        return max(0, best - a.radius - b.radius)
    }

    /// Segment–segment distance (0 when they cross).
    static func segmentDistance(_ a1: FPPoint, _ a2: FPPoint,
                                _ b1: FPPoint, _ b2: FPPoint) -> Double {
        if segmentsIntersect(a1, a2, b1, b2) { return 0 }
        return min(
            BoardGeometry.distance(point: a1, segmentStart: b1, segmentEnd: b2),
            BoardGeometry.distance(point: a2, segmentStart: b1, segmentEnd: b2),
            BoardGeometry.distance(point: b1, segmentStart: a1, segmentEnd: a2),
            BoardGeometry.distance(point: b2, segmentStart: a1, segmentEnd: a2))
    }

    static func segmentsIntersect(_ a1: FPPoint, _ a2: FPPoint,
                                  _ b1: FPPoint, _ b2: FPPoint) -> Bool {
        func cross(_ o: FPPoint, _ p: FPPoint, _ q: FPPoint) -> Double {
            (p.x - o.x) * (q.y - o.y) - (p.y - o.y) * (q.x - o.x)
        }
        let d1 = cross(b1, b2, a1)
        let d2 = cross(b1, b2, a2)
        let d3 = cross(a1, a2, b1)
        let d4 = cross(a1, a2, b2)
        return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0))
            && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
    }
}

// MARK: - Connectivity (which pads actually reach each other)

/// Per-net routing truth, derived from the board's copper: a net's
/// pads are unioned with every trace/via/zone of the same net they
/// touch on a shared layer. Through-hole pads and vias bridge
/// layers (their layer sets span the stack).
struct NetConnectivity: Equatable {
    var netName: String
    /// Pads carrying this net (distinct component/pad-number nodes).
    var padCount: Int = 0
    /// Pads in a group with at least one other pad.
    var routedPadCount: Int = 0
    /// "U1 pin 3 (pad 3)" labels of the pads that reach nothing.
    var unroutedPads: [String] = []
    /// Total routed trace length for the net, mm.
    var traceLength: Double = 0

    var isFullyRouted: Bool { unroutedPads.isEmpty }
}

/// Disjoint-set for the connectivity walk.
private struct UnionFind {
    private var parent: [Int]
    init(count: Int) { parent = Array(0..<count) }
    mutating func find(_ x: Int) -> Int {
        var root = x
        while parent[root] != root { root = parent[root] }
        var node = x
        while parent[node] != root {
            let next = parent[node]
            parent[node] = root
            node = next
        }
        return root
    }
    mutating func union(_ a: Int, _ b: Int) {
        let ra = find(a), rb = find(b)
        if ra != rb { parent[ra] = rb }
    }
}

enum BoardConnectivity {

    /// Two copper shapes connect when they belong to the same net,
    /// share a copper layer, and touch (within 0.02 mm).
    static let touchTolerance = 0.02

    static func analyze(model: BoardModel, copperCount: Int)
        -> [String: NetConnectivity] {
        let shapes = BoardCopper.shapes(model: model, copperCount: copperCount)
        // Pad nodes: one per (component, pad number) binding pad.
        var padNodeByKey: [String: Int] = [:]
        var nodeShapeIndex: [Int] = []   // node -> index into shapes
        var nodeIsPad: [Bool] = []
        var nodeNet: [String] = []
        var duplicatePadNodes: [(Int, Int)] = []
        for (index, shape) in shapes.enumerated() {
            guard let net = shape.netName else { continue }
            if shape.kind == .pad, let existing = padNodeByKey[shape.label] {
                // Duplicate pad numbers on one component are the
                // SAME electrical node (KiCad): union them.
                duplicatePadNodes.append((existing, nodeShapeIndex.count))
            } else if shape.kind == .pad {
                padNodeByKey[shape.label] = nodeShapeIndex.count
            }
            nodeShapeIndex.append(index)
            nodeIsPad.append(shape.kind == .pad)
            nodeNet.append(net)
        }
        var unionFind = UnionFind(count: nodeShapeIndex.count)
        for (a, b) in duplicatePadNodes { unionFind.union(a, b) }
        // O(n²) with a bounding-box prefilter — boards here are
        // small (tens of shapes per net); nets partition the pairs.
        for i in nodeShapeIndex.indices {
            for j in nodeShapeIndex.indices where j > i {
                guard nodeNet[i] == nodeNet[j] else { continue }
                let a = shapes[nodeShapeIndex[i]]
                let b = shapes[nodeShapeIndex[j]]
                guard !a.layers.isDisjoint(with: b.layers) else { continue }
                let ab = a.bounds, bb = b.bounds
                if ab.maxX < bb.minX - touchTolerance
                    || bb.maxX < ab.minX - touchTolerance
                    || ab.maxY < bb.minY - touchTolerance
                    || bb.maxY < ab.minY - touchTolerance {
                    continue
                }
                if BoardCopper.distance(a, b) <= touchTolerance {
                    unionFind.union(i, j)
                }
            }
        }

        // Group pads by root; a pad is routed when its group holds
        // at least one OTHER pad. (A net with a single pad is
        // trivially complete.)
        var padsByRoot: [Int: [String]] = [:]
        var padLabelByNode: [Int: String] = [:]
        for (key, node) in padNodeByKey {
            let root = unionFind.find(node)
            padsByRoot[root, default: []].append(key)
            padLabelByNode[node] = key
        }

        var result: [String: NetConnectivity] = [:]
        for net in model.netNames {
            result[net] = NetConnectivity(netName: net)
        }
        for component in model.components {
            for pin in component.pins {
                guard let net = pin.netName, pin.pad != nil else { continue }
                let key = "\(component.reference) pad \(pin.pinNumber)"
                guard let node = padNodeByKey[key] else { continue }
                let root = unionFind.find(node)
                let groupSize = padsByRoot[root]?.count ?? 1
                result[net]?.padCount += 1
                if groupSize > 1 {
                    result[net]?.routedPadCount += 1
                } else {
                    // Tentatively unrouted; the post-pass below
                    // clears this for lone-pad nets (a net with one
                    // pad has nothing to route TO).
                    result[net]?.unroutedPads.append(
                        "\(component.reference) pin \(pin.pinNumber) (pad \(pin.pinNumber))")
                }
            }
        }
        // A pad is only truly unrouted when its net has 2+ pads.
        for net in result.keys {
            if (result[net]?.padCount ?? 0) < 2 {
                result[net]?.unroutedPads = []
                if (result[net]?.padCount ?? 0) == 1 {
                    result[net]?.routedPadCount = 1
                }
            }
        }
        for trace in model.traces {
            if let net = trace.netName {
                result[net]?.traceLength += trace.length
            }
        }
        return result
    }
}

// MARK: - Ratsnest (part 5.2)

/// One ratsnest line: an unrouted connection between two pads
/// of the same net that no copper path joins yet.
struct RatsnestSegment: Equatable {
    var from: FPPoint
    var to: FPPoint
    var netName: String
}

/// The ratsnest (KiCad's connectivity/ratsnest display): for
/// every net, group its pads by the copper that actually joins
/// them (the same union-find over BoardCopper shapes the
/// connectivity analysis runs — same touch tolerance, same
/// layer rule, duplicate pad numbers unioned), then connect
/// the groups with a minimum spanning tree over inter-group
/// nearest-pad distances. A fully routed net contributes no
/// lines; a net with one pad contributes none. Deterministic
/// ordering: nets in the model's order, groups by first pad
/// label, Prim's algorithm with lowest-index tie-breaks.
enum BoardRatsnest {
    /// `hiddenNets` (part 5.3, P8): nets the user hid in the Nets
    /// panel contribute NO segments. Defaulted empty, so existing
    /// callers and fixtures are untouched.
    static func segments(model: BoardModel, copperCount: Int,
                         hiddenNets: Set<String> = [])
        -> [RatsnestSegment] {
        let shapes = BoardCopper.shapes(model: model, copperCount: copperCount)
        // Pad nodes exactly as BoardConnectivity builds them.
        var padNodeByKey: [String: Int] = [:]
        var nodeShapeIndex: [Int] = []
        var nodeIsPad: [Bool] = []
        var nodeNet: [String] = []
        var padCentreByNode: [Int: FPPoint] = [:]
        var padKeyByNode: [Int: String] = [:]
        var duplicatePadNodes: [(Int, Int)] = []
        for (index, shape) in shapes.enumerated() {
            guard let net = shape.netName else { continue }
            if shape.kind == .pad, let existing = padNodeByKey[shape.label] {
                duplicatePadNodes.append((existing, nodeShapeIndex.count))
            } else if shape.kind == .pad {
                padNodeByKey[shape.label] = nodeShapeIndex.count
            }
            if shape.kind == .pad {
                padKeyByNode[nodeShapeIndex.count] = shape.label
                // shapes() appends the pad centre as the LAST
                // test point of a pad shape.
                if let centre = shape.testPoints.last {
                    padCentreByNode[nodeShapeIndex.count] = centre
                }
            }
            nodeShapeIndex.append(index)
            nodeIsPad.append(shape.kind == .pad)
            nodeNet.append(net)
        }
        var unionFind = UnionFind(count: nodeShapeIndex.count)
        for (a, b) in duplicatePadNodes { unionFind.union(a, b) }
        for i in nodeShapeIndex.indices {
            for j in nodeShapeIndex.indices where j > i {
                guard nodeNet[i] == nodeNet[j] else { continue }
                let a = shapes[nodeShapeIndex[i]]
                let b = shapes[nodeShapeIndex[j]]
                guard !a.layers.isDisjoint(with: b.layers) else { continue }
                let ab = a.bounds, bb = b.bounds
                if ab.maxX < bb.minX - BoardConnectivity.touchTolerance
                    || bb.maxX < ab.minX - BoardConnectivity.touchTolerance
                    || ab.maxY < bb.minY - BoardConnectivity.touchTolerance
                    || bb.maxY < ab.minY - BoardConnectivity.touchTolerance {
                    continue
                }
                if BoardCopper.distance(a, b) <= BoardConnectivity.touchTolerance {
                    unionFind.union(i, j)
                }
            }
        }

        // Groups of pads per net, keyed by union-find root.
        var groupsByNet: [String: [Int: [Int]]] = [:]  // net -> root -> pad nodes
        for (_, node) in padNodeByKey {
            let net = nodeNet[node]
            let root = unionFind.find(node)
            groupsByNet[net, default: [:]][root, default: []].append(node)
        }

        var result: [RatsnestSegment] = []
        for net in model.netNames where !hiddenNets.contains(net) {
            guard let byRoot = groupsByNet[net], byRoot.count > 1
            else { continue }
            // Deterministic group order: by first pad label.
            let groups: [[Int]] = byRoot.values.map { nodes in
                nodes.sorted {
                    (padKeyByNode[$0] ?? "") < (padKeyByNode[$1] ?? "")
                }
            }.sorted {
                (padKeyByNode[$0[0]] ?? "") < (padKeyByNode[$1[0]] ?? "")
            }
            // Nearest pad pair between two groups.
            func link(_ g1: Int, _ g2: Int) -> (distance: Double, from: FPPoint, to: FPPoint) {
                var best: (Double, FPPoint, FPPoint)? = nil
                for n1 in groups[g1] {
                    for n2 in groups[g2] {
                        guard let c1 = padCentreByNode[n1],
                              let c2 = padCentreByNode[n2] else { continue }
                        let d = c1.distance(to: c2)
                        if best == nil || d < best!.0 { best = (d, c1, c2) }
                    }
                }
                return (best!.0, best!.1, best!.2)
            }
            // Prim over groups.
            var inTree: Set<Int> = [0]
            while inTree.count < groups.count {
                var bestEdge: (distance: Double, from: FPPoint, to: FPPoint, group: Int)? = nil
                for g in inTree {
                    for h in groups.indices where !inTree.contains(h) {
                        let candidate = link(g, h)
                        if bestEdge == nil || candidate.distance < bestEdge!.distance {
                            bestEdge = (candidate.distance, candidate.from,
                                        candidate.to, h)
                        }
                    }
                }
                guard let edge = bestEdge else { break }
                result.append(RatsnestSegment(from: edge.from, to: edge.to,
                                              netName: net))
                inTree.insert(edge.group)
            }
        }
        return result
    }
}

// MARK: - Pin connection status (Disconnected vs Unrouted)

/// What the PCB editor says about one pin (part 5, item 13):
/// - connected: on a net, and its pad reaches the net's other pads.
/// - disconnected: the pin is on NO net in the connection table
///   (unoccupied in the schematic — nothing was wired to it).
/// - unrouted: the pin IS on a net, but no copper path reaches the
///   net's other pads yet.
enum PinConnectionStatus: Equatable {
    case connected(net: String)
    case disconnected
    case unrouted(net: String)

    var label: String {
        switch self {
        case .connected: return "Connected"
        case .disconnected: return "Disconnected"
        case .unrouted: return "Unrouted"
        }
    }
}

enum BoardPinStatus {
    static func status(of pin: BoardPinBinding, in component: BoardComponent,
                       connectivity: [String: NetConnectivity])
        -> PinConnectionStatus {
        guard let net = pin.netName else { return .disconnected }
        guard pin.pad != nil else { return .unrouted(net: net) }
        let label = "\(component.reference) pin \(pin.pinNumber) (pad \(pin.pinNumber))"
        if connectivity[net]?.unroutedPads.contains(label) == true {
            return .unrouted(net: net)
        }
        return .connected(net: net)
    }
}

// MARK: - Netclasses (part 5.3, P16) — the clearance source of truth

/// Netclass effects, in ONE place: every clearance computation
/// in the app (the live tier-1 check and manufacturing rule 1)
/// asks requiredClearanceMM what a pair of nets demands, so a
/// class assignment can never be honoured by one checker and
/// ignored by the other. The requirement for a pair is the
/// LARGEST of: the board's own clearance setting, net A's class
/// clearance, net B's class clearance. With no classes assigned
/// this is exactly the pre-5.3 flat board clearance.
enum BoardNetClasses {

    /// The class a net is assigned to on this board, if any.
    static func netClass(forNet net: String, boardState: BoardState) -> NetClass? {
        boardState.netClass(forNet: net)
    }

    static func requiredClearanceMM(netA: String, netB: String,
                                    boardState: BoardState) -> Double {
        var required = BoardUnits.mm(fromMil: boardState.clearanceMil)
        if let netClass = netClass(forNet: netA, boardState: boardState) {
            required = max(required, netClass.clearanceMM)
        }
        if let netClass = netClass(forNet: netB, boardState: boardState) {
            required = max(required, netClass.clearanceMM)
        }
        return required
    }

    /// The width a NEW route of this net starts at: its class's
    /// track width, or nil when the net has no class (the editor
    /// then falls back to its own default-width setting).
    static func defaultTrackWidthMM(forNet net: String,
                                    boardState: BoardState) -> Double? {
        netClass(forNet: net, boardState: boardState)?.trackWidthMM
    }
}

// MARK: - Clearance / net-touch check (tier 1)

/// One clearance violation: two DIFFERENT nets' copper closer
/// than the board's clearance (touching counts — distance 0).
struct ClearanceViolation: Equatable {
    var netA: String
    var netB: String
    var itemA: String
    var itemB: String
    /// The closest distance found, mm (0 = touching).
    var distanceMM: Double
    /// A point on item A nearest the approach (for the label).
    var location: FPPoint
    var highlights: [CheckHighlight]

    var message: String {
        let gap = distanceMM <= 0.001
            ? "touching"
            : "\(BoardUnits.formatLength(mm: distanceMM)) apart"
        return "\(netA) and \(netB) are \(gap): \(itemA) ↔ \(itemB)"
    }
}

enum BoardClearance {

    /// The pre-5.3 entry point (flat clearance, no classes): kept
    /// for existing callers, and implemented THROUGH the
    /// board-state path below so there is exactly one clearance
    /// computation in the app.
    static func violations(model: BoardModel, copperCount: Int,
                           clearanceMM: Double) -> [ClearanceViolation] {
        violations(model: model, copperCount: copperCount,
                   boardState: BoardState(
                    clearanceMil: BoardUnits.mil(fromMM: clearanceMM)))
    }

    /// Per-pair requirements from BoardNetClasses (board setting
    /// vs the two nets' class clearances). With no netclasses
    /// assigned the per-pair requirement is the board clearance
    /// for every pair and the result is identical to the flat
    /// computation above.
    static func violations(model: BoardModel, copperCount: Int,
                           boardState: BoardState) -> [ClearanceViolation] {
        let shapes = BoardCopper.shapes(model: model, copperCount: copperCount)
        // Bounding-box prefilter bound: no violating pair can be
        // farther apart than the LARGEST requirement in play.
        var prefilterMM = BoardUnits.mm(fromMil: boardState.clearanceMil)
        for netClass in boardState.netClasses {
            prefilterMM = max(prefilterMM, netClass.clearanceMM)
        }
        var found: [ClearanceViolation] = []
        for i in shapes.indices {
            for j in shapes.indices where j > i {
                let a = shapes[i], b = shapes[j]
                guard let netA = a.netName, let netB = b.netName,
                      netA != netB else { continue }
                guard !a.layers.isDisjoint(with: b.layers) else { continue }
                let ab = a.bounds, bb = b.bounds
                if ab.maxX < bb.minX - prefilterMM
                    || bb.maxX < ab.minX - prefilterMM
                    || ab.maxY < bb.minY - prefilterMM
                    || bb.maxY < ab.minY - prefilterMM {
                    continue
                }
                let required = BoardNetClasses.requiredClearanceMM(
                    netA: netA, netB: netB, boardState: boardState)
                let distance = BoardCopper.distance(a, b)
                if distance < required - 1e-9 {
                    let location = a.testPoints.first ?? .zero
                    found.append(ClearanceViolation(
                        netA: netA, netB: netB,
                        itemA: a.label, itemB: b.label,
                        distanceMM: distance,
                        location: location,
                        highlights: [a.highlight, b.highlight]))
                }
            }
        }
        return found.sorted {
            ($0.netA, $0.netB, $0.itemA) < ($1.netA, $1.netB, $1.itemA)
        }
    }
}

// MARK: - Manufacturing checker (tier 2)

/// The manufacturing rule thresholds (mils, user-adjustable where
/// the editor exposes them). Defaults are common fab minimums.
struct ManufacturingSettings: Equatable {
    /// Minimum gap between different nets' copper (the board's
    /// clearance, from board state).
    var clearanceMil: Double = 8
    /// Minimum trace width.
    var minTraceWidthMil: Double = 6
    /// Minimum via drill.
    var minViaDrillMil: Double = 12
    /// Minimum via outer diameter.
    var minViaDiameterMil: Double = 24
    /// Minimum annular ring: the copper ring left around a via's
    /// drill, (diameter − drill) / 2 (part 5.2; KiCad DRC's
    /// minimum annular width). 5 mil ≈ 0.127 mm.
    var minAnnularRingMil: Double = 5
}

/// One manufacturing finding with a STABLE identity (part 5.3,
/// P7): `key` is the rule identity + the sorted involved item
/// ids + the involved net names, pipe-joined — content-derived,
/// never row order, so a BoardState.manufacturingExclusions entry
/// keeps naming the same finding across edits that don't touch
/// it, and a key that matches nothing any more is stale (the UI
/// reports it as such; nothing re-attaches it silently).
struct ManufacturingFinding: Equatable {
    /// Stable rule identity, e.g. "clearance", "minTraceWidth".
    var ruleID: String
    /// The display message — byte-identical to the violation
    /// string the rule has always produced.
    var message: String
    /// Item ids involved (trace/via/zone uuidStrings, component
    /// references, "REF pin N" pin ids), sorted in the key.
    var itemIDs: [String]
    /// Net names involved, sorted in the key.
    var netNames: [String]

    var key: String {
        ([ruleID] + itemIDs.sorted() + netNames.sorted())
            .joined(separator: "|")
    }
}

struct ManufacturingRuleResult: Equatable {
    var name: String
    var passed: Bool
    /// One line per violation, with locations. Empty when passed.
    var violations: [String]
    /// The same violations as keyed findings (part 5.3), in the
    /// same order. `violations` stays the display source of
    /// truth; findings are its identity-carrying twin.
    var findings: [ManufacturingFinding] = []
}

struct ManufacturingReport: Equatable {
    var rules: [ManufacturingRuleResult]
    var passedCount: Int { rules.filter(\.passed).count }
    var failedCount: Int { rules.count - passedCount }
    var allPassed: Bool { failedCount == 0 }
    /// Every finding on the board, in rule order (part 5.3).
    var findings: [ManufacturingFinding] { rules.flatMap(\.findings) }
}

/// A deterministic rule set Sean can run any time. Every rule here
/// is actually implemented — the report names only what ran.
enum BoardManufacturing {

    /// The pre-5.3 entry point: implemented through the
    /// board-state overload below with a classless board state
    /// carrying the settings' clearance, so there is exactly one
    /// manufacturing computation. Results are identical to the
    /// board-state overload whenever the board has no netclasses.
    static func check(model: BoardModel, copperCount: Int,
                      settings: ManufacturingSettings,
                      connectivity: [String: NetConnectivity])
        -> ManufacturingReport {
        check(model: model, copperCount: copperCount, settings: settings,
              connectivity: connectivity,
              boardState: BoardState(clearanceMil: settings.clearanceMil))
    }

    /// Board-state overload (part 5.3): rule 1's clearance goes
    /// through BoardNetClasses.requiredClearanceMM like the live
    /// check (the settings' clearanceMil wins as the board
    /// setting — in the editor the settings are DERIVED from the
    /// board state, so the two agree). Every violation also
    /// produces a keyed ManufacturingFinding; rule order, rule
    /// names and violation strings are unchanged from before.
    static func check(model: BoardModel, copperCount: Int,
                      settings: ManufacturingSettings,
                      connectivity: [String: NetConnectivity],
                      boardState: BoardState)
        -> ManufacturingReport {
        var rules: [ManufacturingRuleResult] = []
        var effectiveBoard = boardState
        effectiveBoard.clearanceMil = settings.clearanceMil

        func highlightID(_ highlight: CheckHighlight) -> String {
            switch highlight {
            case .component(let reference): return reference
            case .trace(let id): return id.uuidString
            case .via(let id): return id.uuidString
            case .zone(let id): return id.uuidString
            }
        }
        func net(of trace: BoardTrace) -> [String] {
            (trace.netName ?? trace.disconnectedNetName).map { [$0] } ?? []
        }
        func net(of via: BoardVia) -> [String] {
            (via.netName ?? via.disconnectedNetName).map { [$0] } ?? []
        }
        func net(of zone: BoardZone) -> [String] {
            (zone.netName ?? zone.disconnectedNetName).map { [$0] } ?? []
        }

        // 1. Clearance between different nets (the tier-1 check,
        // netclass-aware through BoardClearance's board-state path).
        let clearance = BoardClearance.violations(
            model: model, copperCount: copperCount, boardState: effectiveBoard)
        rules.append(ManufacturingRuleResult(
            name: "Clearance ≥ \(BoardUnits.formatMil(settings.clearanceMil)) mil between different nets",
            passed: clearance.isEmpty,
            violations: clearance.map(\.message),
            findings: clearance.map {
                ManufacturingFinding(
                    ruleID: "clearance", message: $0.message,
                    itemIDs: $0.highlights.map(highlightID),
                    netNames: [$0.netA, $0.netB])
            }))

        // 2. Minimum trace width.
        let minWidthMM = BoardUnits.mm(fromMil: settings.minTraceWidthMil)
        let thinTraces = model.traces.filter { $0.width < minWidthMM - 1e-9 }
        rules.append(ManufacturingRuleResult(
            name: "Trace width ≥ \(BoardUnits.formatMil(settings.minTraceWidthMil)) mil",
            passed: thinTraces.isEmpty,
            violations: thinTraces.map {
                "A trace on \($0.layer) is \(BoardUnits.formatLength(mm: $0.width)) wide"
            },
            findings: thinTraces.map {
                ManufacturingFinding(
                    ruleID: "minTraceWidth",
                    message: "A trace on \($0.layer) is \(BoardUnits.formatLength(mm: $0.width)) wide",
                    itemIDs: [$0.id.uuidString], netNames: net(of: $0))
            }))

        // 3. Minimum via drill.
        let minDrillMM = BoardUnits.mm(fromMil: settings.minViaDrillMil)
        let smallDrills = model.vias.filter { $0.drill < minDrillMM - 1e-9 }
        rules.append(ManufacturingRuleResult(
            name: "Via drill ≥ \(BoardUnits.formatMil(settings.minViaDrillMil)) mil",
            passed: smallDrills.isEmpty,
            violations: smallDrills.map {
                "The via at (\(BoardUnits.formatMM($0.center.x)), \(BoardUnits.formatMM($0.center.y))) "
                + "has a \(BoardUnits.formatLength(mm: $0.drill)) drill"
            },
            findings: smallDrills.map {
                ManufacturingFinding(
                    ruleID: "minViaDrill",
                    message: "The via at (\(BoardUnits.formatMM($0.center.x)), \(BoardUnits.formatMM($0.center.y))) "
                        + "has a \(BoardUnits.formatLength(mm: $0.drill)) drill",
                    itemIDs: [$0.id.uuidString], netNames: net(of: $0))
            }))

        // 4. Minimum via diameter.
        let minDiameterMM = BoardUnits.mm(fromMil: settings.minViaDiameterMil)
        let smallVias = model.vias.filter { $0.diameter < minDiameterMM - 1e-9 }
        rules.append(ManufacturingRuleResult(
            name: "Via diameter ≥ \(BoardUnits.formatMil(settings.minViaDiameterMil)) mil",
            passed: smallVias.isEmpty,
            violations: smallVias.map {
                "The via at (\(BoardUnits.formatMM($0.center.x)), \(BoardUnits.formatMM($0.center.y))) "
                + "is \(BoardUnits.formatLength(mm: $0.diameter)) across"
            },
            findings: smallVias.map {
                ManufacturingFinding(
                    ruleID: "minViaDiameter",
                    message: "The via at (\(BoardUnits.formatMM($0.center.x)), \(BoardUnits.formatMM($0.center.y))) "
                        + "is \(BoardUnits.formatLength(mm: $0.diameter)) across",
                    itemIDs: [$0.id.uuidString], netNames: net(of: $0))
            }))

        // 5. Every net fully routed.
        var unroutedLines: [String] = []
        var unroutedFindings: [ManufacturingFinding] = []
        for net in model.netNames {
            guard let info = connectivity[net], !info.unroutedPads.isEmpty
            else { continue }
            let line = "\(net): \(info.unroutedPads.count) of \(info.padCount) pads "
                + "reach nothing — \(info.unroutedPads.joined(separator: ", "))"
            unroutedLines.append(line)
            unroutedFindings.append(ManufacturingFinding(
                ruleID: "fullyRouted", message: line,
                itemIDs: info.unroutedPads, netNames: [net]))
        }
        rules.append(ManufacturingRuleResult(
            name: "Every net fully routed (all pads connected)",
            passed: unroutedLines.isEmpty,
            violations: unroutedLines,
            findings: unroutedFindings))

        // 6. No disconnected pins (pins on no net at all).
        var disconnectedLines: [String] = []
        var disconnectedFindings: [ManufacturingFinding] = []
        for component in model.components {
            for pin in component.pins where pin.netName == nil {
                let name = pin.pinName.isEmpty ? "" : " (\(pin.pinName))"
                let line = "\(component.reference) pin \(pin.pinNumber)\(name) is on no net"
                disconnectedLines.append(line)
                disconnectedFindings.append(ManufacturingFinding(
                    ruleID: "noDisconnectedPins", message: line,
                    itemIDs: ["\(component.reference) pin \(pin.pinNumber)"],
                    netNames: []))
            }
        }
        rules.append(ManufacturingRuleResult(
            name: "No disconnected pins",
            passed: disconnectedLines.isEmpty,
            violations: disconnectedLines,
            findings: disconnectedFindings))

        // 7. Nothing on layers the board doesn't have.
        var orphanLines: [String] = []
        var orphanFindings: [ManufacturingFinding] = []
        for trace in model.traces
        where !BoardLayers.layerExists(trace.layer, copperCount: copperCount) {
            let line = "A trace sits on \(trace.layer), which this board doesn't have"
            orphanLines.append(line)
            orphanFindings.append(ManufacturingFinding(
                ruleID: "layersExist", message: line,
                itemIDs: [trace.id.uuidString], netNames: net(of: trace)))
        }
        for zone in model.zones
        where !BoardLayers.layerExists(zone.layer, copperCount: copperCount) {
            let line = "A copper fill sits on \(zone.layer), which this board doesn't have"
            orphanLines.append(line)
            orphanFindings.append(ManufacturingFinding(
                ruleID: "layersExist", message: line,
                itemIDs: [zone.id.uuidString], netNames: net(of: zone)))
        }
        rules.append(ManufacturingRuleResult(
            name: "Nothing on layers the board doesn't have",
            passed: orphanLines.isEmpty,
            violations: orphanLines,
            findings: orphanFindings))

        // 8. Every component has a footprint.
        let unresolved = model.components.filter { $0.footprint == nil }
        rules.append(ManufacturingRuleResult(
            name: "Every component has a footprint",
            passed: unresolved.isEmpty,
            violations: unresolved.map {
                "\($0.reference) has no resolved footprint"
            },
            findings: unresolved.map {
                ManufacturingFinding(
                    ruleID: "footprintResolved",
                    message: "\($0.reference) has no resolved footprint",
                    itemIDs: [$0.reference], netNames: [])
            }))

        // 9. Annular ring (part 5.2): the copper ring around each
        // via's drill must be at least the minimum width, or the
        // drill can break out of the pad.
        let minRingMM = BoardUnits.mm(fromMil: settings.minAnnularRingMil)
        let thinRings = model.vias.filter {
            ($0.diameter - $0.drill) / 2 < minRingMM - 1e-9
        }
        rules.append(ManufacturingRuleResult(
            name: "Via annular ring ≥ \(BoardUnits.formatMil(settings.minAnnularRingMil)) mil",
            passed: thinRings.isEmpty,
            violations: thinRings.map {
                "The via at (\(BoardUnits.formatMM($0.center.x)), \(BoardUnits.formatMM($0.center.y))) "
                + "has a \(BoardUnits.formatLength(mm: ($0.diameter - $0.drill) / 2)) annular ring"
            },
            findings: thinRings.map {
                ManufacturingFinding(
                    ruleID: "minAnnularRing",
                    message: "The via at (\(BoardUnits.formatMM($0.center.x)), \(BoardUnits.formatMM($0.center.y))) "
                        + "has a \(BoardUnits.formatLength(mm: ($0.diameter - $0.drill) / 2)) annular ring",
                    itemIDs: [$0.id.uuidString], netNames: net(of: $0))
            }))

        // 10. Courtyard overlap (part 5.2): two components'
        // courtyards (the F.CrtYd / B.CrtYd keep-clear outlines
        // in their footprints) must not overlap — parts placed
        // inside each other's courtyards can't be assembled or
        // reworked. Bounds-based: each courtyard is reduced to
        // the bounding box of its outline points (exact for the
        // rectangular courtyards nearly every footprint uses).
        var courtyardLines: [String] = []
        var courtyardFindings: [ManufacturingFinding] = []
        let courtyards: [(reference: String,
                          bounds: (minX: Double, minY: Double,
                                   maxX: Double, maxY: Double))] =
            model.components.compactMap { component in
                guard let bounds = BoardCourtyards.bounds(component)
                else { return nil }
                return (component.reference, bounds)
            }
        for i in courtyards.indices {
            for j in courtyards.indices where j > i {
                let a = courtyards[i].bounds, b = courtyards[j].bounds
                let overlapX = min(a.maxX, b.maxX) - max(a.minX, b.minX)
                let overlapY = min(a.maxY, b.maxY) - max(a.minY, b.minY)
                if overlapX > 0.01 && overlapY > 0.01 {
                    let line = "\(courtyards[i].reference) and \(courtyards[j].reference) "
                        + "have overlapping courtyards"
                    courtyardLines.append(line)
                    courtyardFindings.append(ManufacturingFinding(
                        ruleID: "courtyardOverlap", message: line,
                        itemIDs: [courtyards[i].reference, courtyards[j].reference],
                        netNames: []))
                }
            }
        }
        rules.append(ManufacturingRuleResult(
            name: "Component courtyards don't overlap",
            passed: courtyardLines.isEmpty,
            violations: courtyardLines,
            findings: courtyardFindings))

        return ManufacturingReport(rules: rules)
    }

    /// Partition findings by an exclusion key list (part 5.3,
    /// P7): findings whose key is in `excluding` (the board
    /// state's manufacturingExclusions) go to `excluded`, the
    /// rest stay `visible`. Input order is preserved in both.
    static func visibleFindings(_ findings: [ManufacturingFinding],
                                excluding excludedKeys: [String])
        -> (visible: [ManufacturingFinding], excluded: [ManufacturingFinding]) {
        let excludedSet = Set(excludedKeys)
        var visible: [ManufacturingFinding] = []
        var excluded: [ManufacturingFinding] = []
        for finding in findings {
            if excludedSet.contains(finding.key) {
                excluded.append(finding)
            } else {
                visible.append(finding)
            }
        }
        return (visible, excluded)
    }

    /// Exclusion keys that match NO current finding — stale
    /// exclusions, reported as such by the UI, never silently
    /// re-attached to a different finding.
    static func staleExclusions(_ excludedKeys: [String],
                                findings: [ManufacturingFinding]) -> [String] {
        let liveKeys = Set(findings.map(\.key))
        return excludedKeys.filter { !liveKeys.contains($0) }
    }
}

/// Footprint courtyard extraction (part 5.2): the courtyard is
/// the keep-clear outline a footprint draws on a *.CrtYd layer.
/// PadCB reduces it to the bounding box of the outline's points
/// (board-transformed through the same mirror the renderer
/// uses), which is exact for rectangular courtyards.
enum BoardCourtyards {
    static func bounds(_ component: BoardComponent)
        -> (minX: Double, minY: Double, maxX: Double, maxY: Double)? {
        guard let footprint = component.footprint else { return nil }
        var points: [FPPoint] = []
        for raw in footprint.graphics {
            let graphic = BoardGeometry.boardGraphic(component, raw)
            switch graphic {
            case .line(let a, let b, let layer, _, _, _),
                 .rect(let a, let b, let layer, _, _, _):
                guard layer.hasSuffix("CrtYd") else { continue }
                points.append(a); points.append(b)
            case .circle(let centre, let radius, let layer, _, _, _):
                guard layer.hasSuffix("CrtYd") else { continue }
                points.append(FPPoint(x: centre.x - radius, y: centre.y - radius))
                points.append(FPPoint(x: centre.x + radius, y: centre.y + radius))
            case .arc(let a, let m, let b, let layer, _, _, _):
                guard layer.hasSuffix("CrtYd") else { continue }
                points.append(a); points.append(m); points.append(b)
            case .poly(let outline, let layer, _, _, _):
                guard layer.hasSuffix("CrtYd") else { continue }
                points.append(contentsOf: outline)
            case .curve(let p1, let p2, let p3, let p4, let layer, _, _, _):
                guard layer.hasSuffix("CrtYd") else { continue }
                points.append(p1); points.append(p2)
                points.append(p3); points.append(p4)
            case .text:
                continue
            }
        }
        guard let first = points.first else { return nil }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in points {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        // Footprint-local → board: graphics ride the component's
        // origin exactly like pads do (boardGraphic already
        // applied the side mirror in local space).
        return (component.origin.x + minX, component.origin.y + minY,
                component.origin.x + maxX, component.origin.y + maxY)
    }
}

// MARK: - Theory checker (tier 3, deterministic heuristics)

/// One advisory finding from the design-theory heuristics. These
/// are NOT proofs of a fault — they're "look at this" flags,
/// derived only from data the app actually has (the decrypted
/// connection table's pins/nets + the board model + connectivity).
struct TheoryFinding: Equatable {
    enum Severity: String, Equatable {
        case warning, note
    }
    var severity: Severity
    var message: String
}

enum BoardTheory {
    /// Pin names/types that mark a power pin.
    static func isPowerPin(name: String, type: String) -> Bool {
        if type == "power_in" || type == "power_out" { return true }
        let upper = name.uppercased()
        return ["VCC", "VDD", "VSS", "GND", "VBAT", "AVCC", "AGND",
                "+5V", "+3V3", "3V3", "5V"].contains {
            upper == $0 || upper.hasPrefix($0 + "_") || upper.hasSuffix("_" + $0)
        }
    }

    static func isGroundName(_ text: String) -> Bool {
        let upper = text.uppercased()
        return upper.contains("GND") || upper.contains("VSS") || upper == "0V"
    }

    static func isSupplyName(_ text: String) -> Bool {
        let upper = text.uppercased()
        return upper.contains("VCC") || upper.contains("VDD")
            || upper.contains("+5V") || upper.contains("+3V3")
            || upper.contains("VBAT")
    }

    static func findings(model: BoardModel,
                         connectivity: [String: NetConnectivity])
        -> [TheoryFinding] {
        var found: [TheoryFinding] = []

        // Power pins with no connection at all — the classic
        // "forgot to wire the supply" flag.
        for component in model.components {
            for pin in component.pins where pin.netName == nil {
                if isPowerPin(name: pin.pinName, type: pin.pinType) {
                    found.append(TheoryFinding(
                        severity: .warning,
                        message: "\(component.reference) pin \(pin.pinNumber) "
                        + "(\(pin.pinName)) looks like a POWER pin but is "
                        + "connected to nothing."))
                }
            }
        }

        // Disconnected pins overall (non-power).
        var disconnectedCount = 0
        for component in model.components {
            for pin in component.pins where pin.netName == nil {
                if !isPowerPin(name: pin.pinName, type: pin.pinType) {
                    disconnectedCount += 1
                }
            }
        }
        if disconnectedCount > 0 {
            found.append(TheoryFinding(
                severity: .note,
                message: "\(disconnectedCount) pin(s) are on no net. "
                + "If they're meant to be unused, that's fine — KiCad "
                + "would want a no-connect flag on them."))
        }

        // Ground/supply mixups: a ground-named pin sitting on a
        // supply-named net, or a supply pin on a ground net.
        for component in model.components {
            for pin in component.pins {
                guard let net = pin.netName else { continue }
                if isGroundName(pin.pinName), isSupplyName(net) {
                    found.append(TheoryFinding(
                        severity: .warning,
                        message: "\(component.reference) pin \(pin.pinNumber) "
                        + "(\(pin.pinName)) is a ground pin but sits on "
                        + "the supply net \(net) — possible mixup."))
                }
                if isSupplyName(pin.pinName), isGroundName(net) {
                    found.append(TheoryFinding(
                        severity: .warning,
                        message: "\(component.reference) pin \(pin.pinNumber) "
                        + "(\(pin.pinName)) is a supply pin but sits on "
                        + "the ground net \(net) — possible mixup."))
                }
            }
        }

        // Nets whose pins never land on pads (endpoints exist but
        // no matching pads) — the net can't be routed at all.
        for net in model.netNames {
            guard let info = connectivity[net] else { continue }
            if info.padCount == 0 {
                found.append(TheoryFinding(
                    severity: .warning,
                    message: "Net \(net) has pins but none of them land "
                    + "on a footprint pad, so it can't be routed."))
            } else if info.padCount >= 2, info.routedPadCount == 0,
                      model.traces.contains(where: { $0.netName == net }) == false,
                      model.vias.contains(where: { $0.netName == net }) == false,
                      model.zones.contains(where: { $0.netName == net }) == false {
                found.append(TheoryFinding(
                    severity: .note,
                    message: "Net \(net) has \(info.padCount) pads and no "
                    + "copper at all yet — nothing is routed."))
            }
        }

        // Components whose footprint never resolved.
        for component in model.components where component.footprint == nil {
            found.append(TheoryFinding(
                severity: .warning,
                message: "\(component.reference) has no resolved "
                + "footprint, so its pins can't reach the board."))
        }

        // Off-board power symbols (informational).
        if !model.excludedPowerReferences.isEmpty {
            found.append(TheoryFinding(
                severity: .note,
                message: "Power symbols kept off the board: "
                + model.excludedPowerReferences.joined(separator: ", ") + "."))
        }
        return found
    }
}

// MARK: - Board summary (what the on-device AI pass reads)

/// Builds the compact plain-text board summary the optional
/// on-device AI pass (PCBTheoryAIBridge) sends to the model. The
/// summary is generated entirely on-device from the decrypted
/// table + board model; nothing here leaves the iPad.
enum BoardSummaryText {
    static func make(model: BoardModel,
                     connectivity: [String: NetConnectivity],
                     manufacturing: ManufacturingReport,
                     theory: [TheoryFinding]) -> String {
        var lines: [String] = []
        lines.append("PCB board '\(model.tableTitle)' from \(model.sourceFileName).")
        lines.append("Components (\(model.components.count)):")
        for component in model.components {
            let side = component.side == .back ? ", back side" : ""
            lines.append("- \(component.reference) = \(component.value), "
                + "symbol \(component.symbolKey), footprint "
                + "\(component.footprintKey ?? "UNRESOLVED")\(side), "
                + "\(component.pins.count) pins")
        }
        lines.append("Nets (\(model.netNames.count)):")
        for net in model.netNames {
            let info = connectivity[net]
            let pads = info?.padCount ?? 0
            let routed = info?.routedPadCount ?? 0
            let length = info?.traceLength ?? 0
            lines.append("- \(net): \(pads) pads, \(routed) routed, "
                + "track length \(BoardUnits.formatLength(mm: length))")
        }
        lines.append("Board work: \(model.traces.count) traces, "
            + "\(model.vias.count) vias, \(model.zones.count) copper fills.")
        var disconnected: [String] = []
        for component in model.components {
            for pin in component.pins where pin.netName == nil {
                disconnected.append("\(component.reference).\(pin.pinNumber)")
            }
        }
        if !disconnected.isEmpty {
            lines.append("Disconnected pins: \(disconnected.joined(separator: ", ")).")
        }
        let failed = manufacturing.rules.filter { !$0.passed }
        if failed.isEmpty {
            lines.append("Manufacturing check: all \(manufacturing.rules.count) rules pass.")
        } else {
            lines.append("Manufacturing check failures:")
            for rule in failed {
                lines.append("- \(rule.name): \(rule.violations.count) violation(s). "
                    + rule.violations.prefix(3).joined(separator: " "))
            }
        }
        if !theory.isEmpty {
            lines.append("Heuristic flags:")
            for finding in theory.prefix(8) {
                lines.append("- \(finding.message)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Teardrops (part 5.3, P6)
//
// KiCad's teardrop generator (pcbnew/teardrop), PadCB geometry:
// at every track vertex coincident (≤ 0.02 mm) with a same-net
// pad centre or via centre on the track's layer, one teardrop
// per adjacent segment direction — a trapezoid whose base edge
// spans the junction's half-width (round pad: its radius; other
// pads: min(padW, padH)/2; via: its radius) at the junction
// point, tapering to the track's half-width at a run of
// max(1.2 × track width, 0.3 mm) along the segment. (KiCad's
// real profile is curved; the trapezoid is the stated
// approximation.) When a pad AND a via coincide at one vertex,
// the wider junction wins — one teardrop per direction, never
// two stacked. Only named-net tracks generate (a teardrop is
// copper OF a net).

enum BoardTeardrops {

    static let coincidenceTolerance = 0.02

    /// The full new teardrops array for the state: freshly
    /// generated teardrops REPLACE any existing teardrop with
    /// the same anchor key (keeping its id, so locks and
    /// selections survive regeneration); existing teardrops
    /// whose anchors were not regenerated are kept. Order:
    /// generated first (trace order, vertex order, incoming
    /// direction before outgoing), then kept ones in their
    /// original order. `model` is the merged model (its traces /
    /// vias / pads are the board's truth).
    static func generate(state: BoardState, model: BoardModel) -> [TeardropItem] {
        let stack = BoardLayers.copperLayers(count: state.copperLayerCount)
        struct Junction {
            var centre: FPPoint
            var net: String
            var layers: Set<String>
            var baseHalf: Double
        }
        var junctions: [Junction] = []
        for component in model.components {
            guard let footprint = component.footprint else { continue }
            for rawPad in footprint.pads where !rawPad.number.isEmpty {
                guard let net = BoardGeometry.netName(component, rawPad)
                else { continue }
                let pad = BoardGeometry.boardPad(component, rawPad)
                var layers = Set<String>()
                for layer in pad.layers {
                    if layer == "*.Cu" {
                        layers.formUnion(stack)
                    } else if BoardLayers.isCopper(layer) {
                        layers.insert(layer)
                    }
                }
                guard !layers.isEmpty else { continue }
                let baseHalf = pad.shape == .circle
                    ? pad.width / 2
                    : min(pad.width, pad.height) / 2
                junctions.append(Junction(
                    centre: BoardGeometry.padCenter(component, rawPad),
                    net: net, layers: layers, baseHalf: baseHalf))
            }
        }
        for via in model.vias {
            guard let net = via.netName else { continue }
            junctions.append(Junction(
                centre: via.center, net: net, layers: Set(stack),
                baseHalf: via.diameter / 2))
        }

        var generated: [TeardropItem] = []
        for trace in model.traces {
            guard let net = trace.netName, trace.points.count > 1
            else { continue }
            for (vertex, point) in trace.points.enumerated() {
                var best: Junction? = nil
                for junction in junctions
                where junction.net == net
                    && junction.layers.contains(trace.layer)
                    && point.distance(to: junction.centre) <= coincidenceTolerance {
                    if best == nil || junction.baseHalf > best!.baseHalf {
                        best = junction
                    }
                }
                guard let junction = best else { continue }
                // Adjacent segment directions: incoming first.
                var directions: [FPPoint] = []
                if vertex > 0 {
                    let from = trace.points[vertex - 1]
                    let length = point.distance(to: from)
                    if length > 1e-9 {
                        directions.append(FPPoint(
                            x: (point.x - from.x) / length,
                            y: (point.y - from.y) / length))
                    }
                }
                if vertex + 1 < trace.points.count {
                    let to = trace.points[vertex + 1]
                    let length = to.distance(to: point)
                    if length > 1e-9 {
                        directions.append(FPPoint(
                            x: (to.x - point.x) / length,
                            y: (to.y - point.y) / length))
                    }
                }
                let run = max(1.2 * trace.width, 0.3)
                let trackHalf = trace.width / 2
                for direction in directions {
                    let perp = FPPoint(x: -direction.y, y: direction.x)
                    let tipCentre = FPPoint(
                        x: point.x + direction.x * run,
                        y: point.y + direction.y * run)
                    let points = [
                        FPPoint(x: point.x + perp.x * junction.baseHalf,
                                y: point.y + perp.y * junction.baseHalf),
                        FPPoint(x: tipCentre.x + perp.x * trackHalf,
                                y: tipCentre.y + perp.y * trackHalf),
                        FPPoint(x: tipCentre.x - perp.x * trackHalf,
                                y: tipCentre.y - perp.y * trackHalf),
                        FPPoint(x: point.x - perp.x * junction.baseHalf,
                                y: point.y - perp.y * junction.baseHalf),
                    ]
                    generated.append(TeardropItem(
                        id: UUID(), netName: net, layer: trace.layer,
                        points: points,
                        anchorTrackID: trace.id.uuidString,
                        anchorPoint: point))
                }
            }
        }

        var result: [TeardropItem] = generated.map { generatedItem in
            var copy = generatedItem
            if let old = state.teardrops.first(where: {
                $0.anchorKey == copy.anchorKey
            }) {
                copy.id = old.id
            }
            return copy
        }
        let generatedKeys = Set(result.map(\.anchorKey))
        result += state.teardrops.filter { !generatedKeys.contains($0.anchorKey) }
        return result
    }

    /// Remove every teardrop (KiCad's "remove all teardrops").
    static func removingAll(from state: BoardState) -> BoardState {
        var result = state
        result.teardrops = []
        return result
    }

    /// Remove one net's teardrops (KiCad's per-net removal).
    static func removing(from state: BoardState, net: String) -> BoardState {
        var result = state
        result.teardrops.removeAll { $0.netName == net }
        return result
    }
}

// MARK: - Cleanup tracks & vias / graphics (part 5.3, P4 + P5)
//
// KiCad's TRACKS_CLEANER + graphics cleaner, as pure BoardState
// transforms with a dry-run-friendly report (the view shows the
// report from a first call, then commits a second call through
// mutateBoard — the functions are pure, so both calls agree).
// LOCKED items are never removed or merged, in either cleaner.

struct BoardCleanupOptions: Equatable {
    var removeDangling = true
    var removeNullSegments = true
    var mergeCollinear = true
    var removeDuplicateVias = true
    var removeDisconnected = true
}

enum BoardCleanup {

    /// Report keys (always all present):
    /// "nullSegments" (zero-length segments collapsed; a trace
    /// removed for falling below 2 points contributes its
    /// collapsed segments, minimum 1), "mergedSegments"
    /// (collinear vertices merged away), "duplicateVias",
    /// "danglingTracks", "disconnectedItems".
    static func cleanTracksAndVias(state: BoardState, model: BoardModel,
                                   options: BoardCleanupOptions = BoardCleanupOptions())
        -> (state: BoardState, report: [String: Int]) {
        var report: [String: Int] = [
            "nullSegments": 0, "mergedSegments": 0, "duplicateVias": 0,
            "danglingTracks": 0, "disconnectedItems": 0,
        ]
        var result = state

        // Zero-length segments: consecutive duplicate points
        // collapse; a trace left with < 2 points is removed.
        if options.removeNullSegments {
            var kept: [BoardTrace] = []
            for trace in result.traces {
                if result.isLocked(trace.id) { kept.append(trace); continue }
                var cleaned: [FPPoint] = []
                var collapsed = 0
                for point in trace.points {
                    if let last = cleaned.last,
                       last.distance(to: point) < 1e-9 {
                        collapsed += 1
                    } else {
                        cleaned.append(point)
                    }
                }
                if cleaned.count < 2 {
                    report["nullSegments"]! += max(collapsed, 1)
                    continue
                }
                report["nullSegments"]! += collapsed
                var edited = trace
                edited.points = cleaned
                kept.append(edited)
            }
            result.traces = kept
        }

        // Collinear merges: an interior vertex whose two
        // segments run the SAME direction (cross ≈ 0 within
        // 1e-6 relative, dot > 0 — a backtracking vertex is not
        // collinear for this purpose) is merged away.
        if options.mergeCollinear {
            for index in result.traces.indices
            where !result.isLocked(result.traces[index].id) {
                var points = result.traces[index].points
                var changed = true
                while changed, points.count > 2 {
                    changed = false
                    for vertex in 1..<(points.count - 1) {
                        let a = points[vertex - 1], v = points[vertex]
                        let b = points[vertex + 1]
                        let d1 = FPPoint(x: v.x - a.x, y: v.y - a.y)
                        let d2 = FPPoint(x: b.x - v.x, y: b.y - v.y)
                        let l1 = (d1.x * d1.x + d1.y * d1.y).squareRoot()
                        let l2 = (d2.x * d2.x + d2.y * d2.y).squareRoot()
                        guard l1 > 1e-12, l2 > 1e-12 else { continue }
                        let cross = d1.x * d2.y - d1.y * d2.x
                        let dot = d1.x * d2.x + d1.y * d2.y
                        if abs(cross) <= 1e-6 * l1 * l2, dot > 0 {
                            points.remove(at: vertex)
                            report["mergedSegments"]! += 1
                            changed = true
                            break
                        }
                    }
                }
                result.traces[index].points = points
            }
        }

        // Duplicate vias: same centre (±1e-9), same net (named or
        // remembered), same diameter and drill — keep the first.
        if options.removeDuplicateVias {
            var kept: [BoardVia] = []
            for via in result.vias {
                let duplicate = kept.contains {
                    $0.center.distance(to: via.center) < 1e-9
                        && $0.netName == via.netName
                        && $0.disconnectedNetName == via.disconnectedNetName
                        && abs($0.diameter - via.diameter) < 1e-9
                        && abs($0.drill - via.drill) < 1e-9
                }
                if duplicate, !result.isLocked(via.id) {
                    report["duplicateVias"]! += 1
                    continue
                }
                kept.append(via)
            }
            result.vias = kept
        }

        // Disconnected items: sync orphans (netName nil with a
        // remembered net) among traces and vias.
        if options.removeDisconnected {
            let tracesBefore = result.traces.count
            result.traces.removeAll {
                $0.netName == nil && $0.disconnectedNetName != nil
                    && !result.isLocked($0.id)
            }
            let viasBefore = result.vias.count
            result.vias.removeAll {
                $0.netName == nil && $0.disconnectedNetName != nil
                    && !result.isLocked($0.id)
            }
            report["disconnectedItems"]! = (tracesBefore - result.traces.count)
                + (viasBefore - result.vias.count)
        }

        // Dangling tracks, to a fixpoint: a trace is dangling
        // when EITHER endpoint touches no other copper of its
        // net — pads, vias, other traces, zones and teardrops
        // all count as anchors (BoardCopper shapes over the
        // working state; a trace never anchors itself). Endpoint
        // contact is BoardCopper distance ≤ the connectivity
        // touch tolerance. Net matching is by equality of
        // netName (pads carry named nets only, so an unnamed
        // trace can anchor only on unnamed copper). Removing
        // one dangling trace can strand its neighbour, hence
        // the loop.
        if options.removeDangling {
            while true {
                var working = model
                working.traces = result.traces
                working.vias = result.vias
                working.zones = result.zones
                working.teardrops = result.teardrops
                let shapes = BoardCopper.shapes(
                    model: working, copperCount: result.copperLayerCount)
                var dangling: Set<UUID> = []
                for trace in result.traces
                where !result.isLocked(trace.id) && trace.points.count > 1 {
                    func anchored(_ point: FPPoint) -> Bool {
                        let probe = CopperShape(
                            kind: .via, label: "cleanup probe",
                            netName: trace.netName, layers: [trace.layer],
                            segments: [(point, point)], radius: 0,
                            filledPolygon: nil, testPoints: [point],
                            highlight: .trace(trace.id))
                        for shape in shapes {
                            // Never self-anchored: the trace's own
                            // shape — and its own teardrops, whose
                            // highlight is the anchor trace — are
                            // skipped.
                            if shape.highlight == .trace(trace.id),
                               shape.kind == .trace || shape.kind == .teardrop {
                                continue
                            }
                            guard shape.netName == trace.netName
                            else { continue }
                            guard shape.layers.contains(trace.layer)
                            else { continue }
                            if BoardCopper.distance(probe, shape)
                                <= BoardConnectivity.touchTolerance {
                                return true
                            }
                        }
                        return false
                    }
                    if !anchored(trace.points.first!)
                        || !anchored(trace.points.last!) {
                        dangling.insert(trace.id)
                    }
                }
                if dangling.isEmpty { break }
                result.traces.removeAll { dangling.contains($0.id) }
                report["danglingTracks"]! += dangling.count
            }
        }
        return (result, report)
    }

    /// Report keys (always both present): "duplicateGraphics"
    /// (exact duplicates — same kind, layer and every geometry
    /// field, id aside — removed, first kept) and
    /// "mergedGraphics" (collinear LINE graphics on the same
    /// layer touching at an endpoint merged into one line,
    /// keeping the first line's id and stroke width).
    static func cleanGraphics(state: BoardState)
        -> (state: BoardState, report: [String: Int]) {
        var report: [String: Int] = [
            "duplicateGraphics": 0, "mergedGraphics": 0,
        ]
        var result = state

        func sameGeometry(_ a: BoardGraphicItem, _ b: BoardGraphicItem) -> Bool {
            a.kind == b.kind && a.layer == b.layer && a.points == b.points
                && a.radius == b.radius && a.strokeWidth == b.strokeWidth
                && a.text == b.text && a.textSize == b.textSize
        }
        var kept: [BoardGraphicItem] = []
        for item in result.graphics {
            if kept.contains(where: { sameGeometry($0, item) }),
               !result.isLocked(item.id) {
                report["duplicateGraphics"]! += 1
                continue
            }
            kept.append(item)
        }
        result.graphics = kept

        func mergedLine(_ a: BoardGraphicItem, _ b: BoardGraphicItem)
            -> BoardGraphicItem? {
            let a0 = a.points[0], a1 = a.points[1]
            let b0 = b.points[0], b1 = b.points[1]
            let shared: FPPoint
            let outerA: FPPoint, outerB: FPPoint
            func close(_ p: FPPoint, _ q: FPPoint) -> Bool {
                p.distance(to: q) < 1e-9
            }
            if close(a1, b0) { shared = a1; outerA = a0; outerB = b1 }
            else if close(a1, b1) { shared = a1; outerA = a0; outerB = b0 }
            else if close(a0, b0) { shared = a0; outerA = a1; outerB = b1 }
            else if close(a0, b1) { shared = a0; outerA = a1; outerB = b0 }
            else { return nil }
            // Collinear, and the two outers head AWAY from the
            // shared point in opposite directions (a doubled-back
            // pair is an overlap, not a merge).
            let u = FPPoint(x: outerA.x - shared.x, y: outerA.y - shared.y)
            let v = FPPoint(x: outerB.x - shared.x, y: outerB.y - shared.y)
            let lu = (u.x * u.x + u.y * u.y).squareRoot()
            let lv = (v.x * v.x + v.y * v.y).squareRoot()
            guard lu > 1e-12, lv > 1e-12 else { return nil }
            let cross = u.x * v.y - u.y * v.x
            let dot = u.x * v.x + u.y * v.y
            guard abs(cross) <= 1e-6 * lu * lv, dot < 0 else { return nil }
            var merged = a
            merged.points = [outerA, outerB]
            return merged
        }
        var changed = true
        while changed {
            changed = false
            outer: for i in result.graphics.indices {
                for j in result.graphics.indices where j > i {
                    let a = result.graphics[i], b = result.graphics[j]
                    guard a.kind == .line, b.kind == .line,
                          a.layer == b.layer,
                          a.points.count == 2, b.points.count == 2,
                          !result.isLocked(a.id), !result.isLocked(b.id),
                          let merged = mergedLine(a, b)
                    else { continue }
                    result.graphics[i] = merged
                    result.graphics.remove(at: j)
                    report["mergedGraphics"]! += 1
                    changed = true
                    break outer
                }
            }
        }
        return (result, report)
    }
}

// MARK: - Net queries (part 5.3, P2 + P3)

enum BoardNetQueries {

    /// Everything carrying one net, for Select All on Net.
    /// Matching is by netName ONLY — an item whose net vanished
    /// in a sync (netName nil, name remembered in
    /// disconnectedNetName) does NOT match its old net.
    /// References are the footprints having a PAD on the net
    /// (a pin bound to a pad of that net).
    static func itemIDs(onNet net: String, state: BoardState, model: BoardModel)
        -> (traceIDs: Set<String>, viaIDs: Set<String>, references: Set<String>) {
        let traceIDs = Set(state.traces.filter { $0.netName == net }
            .map(\.id.uuidString))
        let viaIDs = Set(state.vias.filter { $0.netName == net }
            .map(\.id.uuidString))
        var references = Set<String>()
        for component in model.components
        where component.pins.contains(where: {
            $0.netName == net && $0.pad != nil
        }) {
            references.insert(component.reference)
        }
        return (traceIDs, viaIDs, references)
    }

    /// References with at least one UNROUTED pad (a pin on a net
    /// whose pad reaches none of the net's other pads, per
    /// BoardConnectivity) — KiCad's selectUnconnected set.
    /// Sorted ascending in natural reference order (R2 < R10).
    static func unconnectedReferences(model: BoardModel, copperCount: Int)
        -> [String] {
        let connectivity = BoardConnectivity.analyze(
            model: model, copperCount: copperCount)
        var references: [String] = []
        for component in model.components {
            let hasUnrouted = component.pins.contains { pin in
                guard let net = pin.netName, pin.pad != nil else { return false }
                let label = "\(component.reference) pin \(pin.pinNumber) (pad \(pin.pinNumber))"
                return connectivity[net]?.unroutedPads.contains(label) == true
            }
            if hasUnrouted { references.append(component.reference) }
        }
        return references.sorted(by: PCBBoardModelBuilder.naturalLess)
    }
}

// MARK: - Unroute (part 5.3, P14)
//
// KiCad's unrouteSelected: walk the copper connected to a
// footprint's pads (or to one trace) and remove the traces/vias
// of that connected component. The walk is a graph over pads
// (anchors), traces and vias of the relevant net(s), joined by
// BoardCopper touch (≤ 0.02 mm on a shared layer). Expansion
// STOPS at any other footprint's pad: a trace touching a foreign
// pad is removed (it routes TO that pad), but the walk does not
// continue through the pad to whatever else touches it. Locked
// traces/vias are barriers — never traversed, never removed.
// Teardrops anchored to removed tracks are removed with them.

enum BoardUnroute {

    static func removingRouting(forReference reference: String,
                                state: BoardState, model: BoardModel)
        -> (state: BoardState, removedTraces: Int, removedVias: Int) {
        guard let component = model.components.first(where: {
            $0.reference == reference
        }) else { return (state, 0, 0) }
        let nets = Set(component.pins.compactMap(\.netName))
        return walk(state: state, model: model,
                    seedReference: reference, seedTraceID: nil,
                    relevantNets: nets)
    }

    static func removingRouting(fromTraceID traceID: UUID,
                                state: BoardState, model: BoardModel)
        -> (state: BoardState, removedTraces: Int, removedVias: Int) {
        guard let trace = state.traces.first(where: { $0.id == traceID })
        else { return (state, 0, 0) }
        guard !state.isLocked(traceID) else { return (state, 0, 0) }
        let nets: Set<String> = (trace.netName ?? trace.disconnectedNetName)
            .map { [$0] } ?? []
        return walk(state: state, model: model,
                    seedReference: nil, seedTraceID: traceID,
                    relevantNets: nets)
    }

    private struct Node {
        enum Kind { case pad, trace, via }
        var kind: Kind
        var id: UUID?
        var reference: String?
        var netKey: String?
        var shape: CopperShape
        var locked: Bool
    }

    private static func walk(state: BoardState, model: BoardModel,
                             seedReference: String?, seedTraceID: UUID?,
                             relevantNets: Set<String>)
        -> (state: BoardState, removedTraces: Int, removedVias: Int) {
        let stack = BoardLayers.copperLayers(count: state.copperLayerCount)
        var nodes: [Node] = []
        for component in model.components {
            guard let footprint = component.footprint else { continue }
            for rawPad in footprint.pads where !rawPad.number.isEmpty {
                guard let net = BoardGeometry.netName(component, rawPad)
                else { continue }
                let pad = BoardGeometry.boardPad(component, rawPad)
                var layers = Set<String>()
                for layer in pad.layers {
                    if layer == "*.Cu" {
                        layers.formUnion(stack)
                    } else if BoardLayers.isCopper(layer) {
                        layers.insert(layer)
                    }
                }
                guard !layers.isEmpty else { continue }
                let outline = BoardCopper.outlinePolygon(
                    component: component, rawPad: rawPad)
                var segments: [(FPPoint, FPPoint)] = []
                for index in outline.indices {
                    segments.append((outline[index],
                                     outline[(index + 1) % outline.count]))
                }
                nodes.append(Node(
                    kind: .pad, id: nil, reference: component.reference,
                    netKey: net,
                    shape: CopperShape(
                        kind: .pad,
                        label: "\(component.reference) pad \(rawPad.number)",
                        netName: net, layers: layers, segments: segments,
                        radius: 0, filledPolygon: outline,
                        testPoints: outline
                            + [BoardGeometry.padCenter(component, rawPad)],
                        highlight: .component(component.reference)),
                    locked: false))
            }
        }
        for trace in state.traces where trace.points.count > 1 {
            var segments: [(FPPoint, FPPoint)] = []
            for index in 1..<trace.points.count {
                segments.append((trace.points[index - 1], trace.points[index]))
            }
            nodes.append(Node(
                kind: .trace, id: trace.id, reference: nil,
                netKey: trace.netName ?? trace.disconnectedNetName,
                shape: CopperShape(
                    kind: .trace, label: "trace on \(trace.layer)",
                    netName: trace.netName, layers: [trace.layer],
                    segments: segments, radius: trace.width / 2,
                    filledPolygon: nil, testPoints: trace.points,
                    highlight: .trace(trace.id)),
                locked: state.isLocked(trace.id)))
        }
        for via in state.vias {
            nodes.append(Node(
                kind: .via, id: via.id, reference: nil,
                netKey: via.netName ?? via.disconnectedNetName,
                shape: CopperShape(
                    kind: .via, label: "via",
                    netName: via.netName, layers: Set(stack),
                    segments: [(via.center, via.center)],
                    radius: via.diameter / 2, filledPolygon: nil,
                    testPoints: [via.center], highlight: .via(via.id)),
                locked: state.isLocked(via.id)))
        }

        // Seeds.
        var visited = Set<Int>()
        var queue: [Int] = []
        func seed(_ index: Int) {
            if visited.insert(index).inserted { queue.append(index) }
        }
        if let seedReference {
            for index in nodes.indices
            where nodes[index].kind == .pad
                && nodes[index].reference == seedReference
                && nodes[index].netKey.map(relevantNets.contains) == true {
                seed(index)
            }
        }
        if let seedTraceID {
            guard let index = nodes.firstIndex(where: {
                $0.kind == .trace && $0.id == seedTraceID
            }) else {
                // Degenerate (≤ 1 point) seed trace: no graph to
                // walk — it is its own component.
                var result = state
                result.traces.removeAll { $0.id == seedTraceID }
                result.teardrops.removeAll {
                    $0.anchorTrackID == seedTraceID.uuidString
                }
                return (result, 1, 0)
            }
            seed(index)
        }
        if queue.isEmpty { return (state, 0, 0) }

        // BFS. A pad of another footprint (or, for the trace
        // variant, ANY pad) is a leaf: visited, never expanded.
        // Locked traces/vias are never even visited.
        //
        // Pad-centre contact rule: two items that touch ONLY at
        // a leaf pad's centre (the classic case — one track ends
        // on the pad, another starts there) are connected
        // THROUGH that pad, not directly, so their direct edge
        // is suppressed and the pad's leaf rule decides. A
        // direct edge survives when the items touch away from
        // every leaf pad centre they share.
        func touchesAtLeafPadCentre(_ a: CopperShape, _ b: CopperShape,
                                    net: String) -> Bool {
            for pad in nodes
            where pad.kind == .pad && pad.reference != seedReference
                && pad.netKey == net {
                let centre = pad.shape.testPoints.last!
                func centreDistance(_ shape: CopperShape) -> Double {
                    let probe = CopperShape(
                        kind: .via, label: "unroute probe",
                        netName: net, layers: shape.layers,
                        segments: [(centre, centre)], radius: 0,
                        filledPolygon: nil, testPoints: [centre],
                        highlight: .component(pad.reference ?? ""))
                    return BoardCopper.distance(probe, shape)
                }
                if BoardCopper.distance(pad.shape, a)
                        <= BoardConnectivity.touchTolerance,
                   BoardCopper.distance(pad.shape, b)
                        <= BoardConnectivity.touchTolerance,
                   centreDistance(a) <= BoardConnectivity.touchTolerance,
                   centreDistance(b) <= BoardConnectivity.touchTolerance {
                    return true
                }
            }
            return false
        }
        var head = 0
        while head < queue.count {
            let current = queue[head]
            head += 1
            let node = nodes[current]
            guard let net = node.netKey else { continue }
            for index in nodes.indices where !visited.contains(index) {
                let other = nodes[index]
                if other.kind != .pad, other.locked { continue }
                guard other.netKey == net else { continue }
                guard !node.shape.layers.isDisjoint(with: other.shape.layers)
                else { continue }
                guard BoardCopper.distance(node.shape, other.shape)
                        <= BoardConnectivity.touchTolerance
                else { continue }
                if node.kind != .pad, other.kind != .pad,
                   touchesAtLeafPadCentre(node.shape, other.shape, net: net) {
                    continue
                }
                visited.insert(index)
                if other.kind == .pad, other.reference != seedReference {
                    continue  // leaf: do not expand through it
                }
                queue.append(index)
            }
        }

        let removedTraceIDs = Set(visited.compactMap {
            nodes[$0].kind == .trace ? nodes[$0].id : nil
        })
        let removedViaIDs = Set(visited.compactMap {
            nodes[$0].kind == .via ? nodes[$0].id : nil
        })
        if removedTraceIDs.isEmpty, removedViaIDs.isEmpty {
            return (state, 0, 0)
        }
        var result = state
        result.traces.removeAll { removedTraceIDs.contains($0.id) }
        result.vias.removeAll { removedViaIDs.contains($0.id) }
        let removedTrackStrings = Set(removedTraceIDs.map(\.uuidString))
        result.teardrops.removeAll {
            removedTrackStrings.contains($0.anchorTrackID)
        }
        return (result, removedTraceIDs.count, removedViaIDs.count)
    }
}

// MARK: - PCB Find (part 5.3, P12)
//
// KiCad's dialog_find, data side: case-insensitive substring
// search over footprint references, footprint VALUES (which live
// on BoardComponent.value in the board model) and net names.
// Deterministic order: component hits first — references in
// natural ascending order, a reference hit before a value hit on
// the same component — then net hits by net name ascending. A
// net hit carries the reference of the net's first pad (model
// order) so the view can centre on it; a net with no pad at all
// produces no hit (there is nothing to centre on).

struct BoardFindHit: Equatable {
    enum Kind: String, Equatable {
        case reference, value, net
    }
    var kind: Kind
    /// The footprint to select/centre: for net hits, the
    /// reference owning the net's first pad.
    var reference: String
    /// The matched text (the reference, value or net name).
    var text: String
}

enum BoardFind {
    static func hits(model: BoardModel, query: String) -> [BoardFindHit] {
        let needle = query
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }

        var componentHits: [BoardFindHit] = []
        for component in model.components {
            if component.reference.lowercased().contains(needle) {
                componentHits.append(BoardFindHit(
                    kind: .reference, reference: component.reference,
                    text: component.reference))
            }
            if component.value.lowercased().contains(needle) {
                componentHits.append(BoardFindHit(
                    kind: .value, reference: component.reference,
                    text: component.value))
            }
        }
        componentHits.sort {
            if $0.reference != $1.reference {
                return PCBBoardModelBuilder.naturalLess($0.reference, $1.reference)
            }
            return $0.kind == .reference && $1.kind != .reference
        }

        var netHits: [BoardFindHit] = []
        for net in model.netNames where net.lowercased().contains(needle) {
            var owner: String? = nil
            ownerSearch: for component in model.components {
                for pin in component.pins
                where pin.netName == net && pin.pad != nil {
                    owner = component.reference
                    break ownerSearch
                }
            }
            if owner == nil {
                ownerSearchFallback: for component in model.components {
                    for pin in component.pins where pin.netName == net {
                        owner = component.reference
                        break ownerSearchFallback
                    }
                }
            }
            guard let owner else { continue }
            netHits.append(BoardFindHit(kind: .net, reference: owner, text: net))
        }
        netHits.sort { PCBBoardModelBuilder.naturalLess($0.text, $1.text) }
        return componentHits + netHits
    }
}
