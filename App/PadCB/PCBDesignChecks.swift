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
        case pad, trace, via, zone
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
    static func violations(model: BoardModel, copperCount: Int,
                           clearanceMM: Double) -> [ClearanceViolation] {
        let shapes = BoardCopper.shapes(model: model, copperCount: copperCount)
        var found: [ClearanceViolation] = []
        for i in shapes.indices {
            for j in shapes.indices where j > i {
                let a = shapes[i], b = shapes[j]
                guard let netA = a.netName, let netB = b.netName,
                      netA != netB else { continue }
                guard !a.layers.isDisjoint(with: b.layers) else { continue }
                let ab = a.bounds, bb = b.bounds
                if ab.maxX < bb.minX - clearanceMM
                    || bb.maxX < ab.minX - clearanceMM
                    || ab.maxY < bb.minY - clearanceMM
                    || bb.maxY < ab.minY - clearanceMM {
                    continue
                }
                let distance = BoardCopper.distance(a, b)
                if distance < clearanceMM - 1e-9 {
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
}

struct ManufacturingRuleResult: Equatable {
    var name: String
    var passed: Bool
    /// One line per violation, with locations. Empty when passed.
    var violations: [String]
}

struct ManufacturingReport: Equatable {
    var rules: [ManufacturingRuleResult]
    var passedCount: Int { rules.filter(\.passed).count }
    var failedCount: Int { rules.count - passedCount }
    var allPassed: Bool { failedCount == 0 }
}

/// A deterministic rule set Sean can run any time. Every rule here
/// is actually implemented — the report names only what ran.
enum BoardManufacturing {
    static func check(model: BoardModel, copperCount: Int,
                      settings: ManufacturingSettings,
                      connectivity: [String: NetConnectivity])
        -> ManufacturingReport {
        var rules: [ManufacturingRuleResult] = []
        let clearanceMM = BoardUnits.mm(fromMil: settings.clearanceMil)

        // 1. Clearance between different nets (the tier-1 check).
        let clearance = BoardClearance.violations(
            model: model, copperCount: copperCount, clearanceMM: clearanceMM)
        rules.append(ManufacturingRuleResult(
            name: "Clearance ≥ \(BoardUnits.formatMil(settings.clearanceMil)) mil between different nets",
            passed: clearance.isEmpty,
            violations: clearance.map(\.message)))

        // 2. Minimum trace width.
        let minWidthMM = BoardUnits.mm(fromMil: settings.minTraceWidthMil)
        let thinTraces = model.traces.filter { $0.width < minWidthMM - 1e-9 }
        rules.append(ManufacturingRuleResult(
            name: "Trace width ≥ \(BoardUnits.formatMil(settings.minTraceWidthMil)) mil",
            passed: thinTraces.isEmpty,
            violations: thinTraces.map {
                "A trace on \($0.layer) is \(BoardUnits.formatLength(mm: $0.width)) wide"
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
            }))

        // 5. Every net fully routed.
        var unroutedLines: [String] = []
        for net in model.netNames {
            guard let info = connectivity[net], !info.unroutedPads.isEmpty
            else { continue }
            unroutedLines.append(
                "\(net): \(info.unroutedPads.count) of \(info.padCount) pads "
                + "reach nothing — \(info.unroutedPads.joined(separator: ", "))")
        }
        rules.append(ManufacturingRuleResult(
            name: "Every net fully routed (all pads connected)",
            passed: unroutedLines.isEmpty,
            violations: unroutedLines))

        // 6. No disconnected pins (pins on no net at all).
        var disconnectedLines: [String] = []
        for component in model.components {
            for pin in component.pins where pin.netName == nil {
                let name = pin.pinName.isEmpty ? "" : " (\(pin.pinName))"
                disconnectedLines.append(
                    "\(component.reference) pin \(pin.pinNumber)\(name) is on no net")
            }
        }
        rules.append(ManufacturingRuleResult(
            name: "No disconnected pins",
            passed: disconnectedLines.isEmpty,
            violations: disconnectedLines))

        // 7. Nothing on layers the board doesn't have.
        var orphanLines: [String] = []
        for trace in model.traces
        where !BoardLayers.layerExists(trace.layer, copperCount: copperCount) {
            orphanLines.append("A trace sits on \(trace.layer), which this board doesn't have")
        }
        for zone in model.zones
        where !BoardLayers.layerExists(zone.layer, copperCount: copperCount) {
            orphanLines.append("A copper fill sits on \(zone.layer), which this board doesn't have")
        }
        rules.append(ManufacturingRuleResult(
            name: "Nothing on layers the board doesn't have",
            passed: orphanLines.isEmpty,
            violations: orphanLines))

        // 8. Every component has a footprint.
        let unresolved = model.components.filter { $0.footprint == nil }
        rules.append(ManufacturingRuleResult(
            name: "Every component has a footprint",
            passed: unresolved.isEmpty,
            violations: unresolved.map {
                "\($0.reference) has no resolved footprint"
            }))

        return ManufacturingReport(rules: rules)
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
