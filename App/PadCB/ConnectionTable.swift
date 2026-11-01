import Foundation

/// The PadCB connection table: the netlist derived from a saved
/// schematic — every net and, for each net, exactly what connects to
/// what. This is the bridge artifact the future PCB editor consumes;
/// the on-disk format is documented in CONTRACTS.md ("Part 2 —
/// connection table format").
///
/// Derivation rules (all from the SAVED SchematicState plus the real
/// symbol definitions — there is no parallel hand-maintained model):
/// - Pin world points come from SymbolDrawList.pinWorldPoints — the
///   same geometry the renderer and wire snapping use.
/// - Wires are straight segments between consecutive polyline points.
///   Segments join when they share an endpoint, when an endpoint lands
///   on another segment (a T), when a JunctionItem sits on both, or
///   when a pin touches both. Two segments merely CROSSING (interior
///   to interior, no junction/pin) do NOT connect — KiCad's rule.
/// - A label whose point lies on a wire (or exactly on a pin) names
///   that wire's net; nets carrying the same label text are the same
///   net, even when drawn as separate wire runs.
/// - A power symbol's pins are global: nets carrying the same power
///   name (the symbol's Value, e.g. "GND") merge the same way.
/// - Pins of type no_connect never appear as endpoints.
/// - Only nets with **2 or more endpoints** are written — a lone pin
///   on a stub wire is not a connection. (Two separately-drawn single
///   pins joined by a shared label or power name DO form a net and
///   are written, because after merging they have 2 endpoints.)
/// - Unnamed nets are called Net-1, Net-2, … in a deterministic order
///   (sorted by their first endpoint), so re-saving an unchanged
///   schematic reproduces the same names.

struct ConnectionEndpoint: Codable, Equatable {
    /// The placed symbol instance this endpoint belongs to.
    var instanceID: UUID
    /// Symbol instance reference as drawn, e.g. "R1".
    var reference: String
    /// Unit of the symbol instance (multi-unit parts).
    var unit: Int
    /// Library key the symbol came from ("Device", "user:MyLib").
    var library: String
    var symbolName: String
    var pinNumber: String
    /// Pin name with KiCad markup stripped for readability.
    var pinName: String
    /// KiCad pin electrical type, e.g. "passive", "power_in".
    var pinType: String
}

struct ConnectionComponent: Codable, Equatable {
    var instanceID: UUID
    var reference: String
    var unit: Int
    var library: String
    var symbolName: String
    var value: String
    /// The symbol definition's Footprint property ("Lib:Name"), if any.
    var footprintReference: String?
    /// Canonical key ("Group:Name", or "user:Group:Name" for a user
    /// footprint) of the EFFECTIVE footprint at save time, or nil when
    /// no imported footprint matches (yet). Effective means the
    /// per-instance choice wins over the symbol's Footprint property
    /// (part 3, FootprintMatcher).
    var resolvedFootprintKey: String?
    /// How `resolvedFootprintKey` was resolved: a
    /// FootprintMatchKind raw value ("instanceChoice" | "property" |
    /// "filterExact"), or nil when nothing resolved. Part 3 addition:
    /// an OPTIONAL field only — formatVersion stays 1 and tables
    /// written before part 3 (no such key) still decode, with a nil
    /// kind meaning the part-2 behaviour (resolution came from the
    /// Footprint property).
    var footprintMatchKind: String? = nil
}

struct ConnectionNet: Codable, Equatable {
    var name: String
    /// Other explicit names (labels / power values) that landed on the
    /// same merged net — recorded instead of silently dropped.
    var aliases: [String]
    var endpoints: [ConnectionEndpoint]
}

struct ConnectionTable: Codable, Equatable {
    var formatVersion: Int
    var schematicTitle: String
    /// File name of the schematic this table was derived from.
    var sourceFileName: String
    var generatedAt: Date
    var components: [ConnectionComponent]
    var nets: [ConnectionNet]
    /// Placed symbols whose definitions could not be loaded (e.g. a
    /// custom library that has since been deleted). Their pins cannot
    /// be enumerated, so they contribute no endpoints.
    var unresolvedSymbols: [String]

    static let currentFormatVersion = 1
}

// MARK: - Builder

enum ConnectionTableBuilder {

    /// Geometry tolerance for "touching" (mm). The canvas snaps pins
    /// exactly and adds junctions at exact points; 0.02 mm matches the
    /// junction tolerance the canvas itself uses.
    static let tolerance = 0.02

    /// Builds the table for `state`.
    /// - `resolveSymbol`: the editor passes LibraryStore.symbol.
    /// - `resolveFootprint`: the editor passes a FootprintMatcher
    ///   lookup over the placed instance + its definition (part 3);
    ///   it returns the EFFECTIVE footprint's resolution key and how
    ///   it resolved (a FootprintMatchKind raw value) — the instance's
    ///   own footprintChoice wins over the symbol's Footprint
    ///   property inside that closure.
    static func build(state: SchematicState,
                      sourceFileName: String,
                      resolveSymbol: (PlacedSymbol) -> KiCadSymbolDef?,
                      resolveFootprint: (PlacedSymbol, KiCadSymbolDef) -> (key: String?, kind: String?)) -> ConnectionTable {
        // 1. Endpoints: every pin of every placed symbol, in a
        //    deterministic order, via the renderer's own geometry.
        var endpoints: [ConnectionEndpoint] = []
        var endpointPoints: [DPoint] = [] // parallel to endpoints
        var components: [ConnectionComponent] = []
        var unresolved: [String] = []
        var powerNameByEndpoint: [Int: String] = [:]
        var seenEndpointKeys = Set<String>()

        let placedSorted = state.symbols.sorted {
            ($0.reference, $0.symbolName, $0.unit, $0.id.uuidString)
                < ($1.reference, $1.symbolName, $1.unit, $1.id.uuidString)
        }
        for placed in placedSorted {
            guard let def = resolveSymbol(placed) else {
                unresolved.append("\(placed.reference) (\(placed.library):\(placed.symbolName))")
                continue
            }
            let footprintReference = cleanedProperty(def.property("Footprint"))
            let footprintResolution = resolveFootprint(placed, def)
            components.append(ConnectionComponent(
                instanceID: placed.id,
                reference: placed.reference,
                unit: placed.unit,
                library: placed.library,
                symbolName: placed.symbolName,
                value: placed.value,
                footprintReference: footprintReference,
                resolvedFootprintKey: footprintResolution.key,
                footprintMatchKind: footprintResolution.kind))

            let powerName: String? = def.isPower
                ? (placed.value.trimmingCharacters(in: .whitespaces).isEmpty
                    ? placed.symbolName
                    : placed.value.trimmingCharacters(in: .whitespaces))
                : nil

            for entry in SymbolDrawList.pinWorldPoints(def: def, placed: placed) {
                let pin = entry.pin
                if pin.type == .noConnect { continue }
                let dedupeKey = "\(placed.id.uuidString)|\(pin.number)|"
                    + "\(Int((entry.point.x * 1000).rounded()))|\(Int((entry.point.y * 1000).rounded()))"
                if seenEndpointKeys.contains(dedupeKey) { continue }
                seenEndpointKeys.insert(dedupeKey)
                let index = endpoints.count
                endpoints.append(ConnectionEndpoint(
                    instanceID: placed.id,
                    reference: placed.reference,
                    unit: placed.unit,
                    library: placed.library,
                    symbolName: placed.symbolName,
                    pinNumber: pin.number,
                    pinName: KiCadText.plain(pin.name),
                    pinType: pin.type.rawValue))
                endpointPoints.append(entry.point)
                if let powerName { powerNameByEndpoint[index] = powerName }
            }
        }
        components.sort {
            ($0.reference, $0.symbolName, $0.unit) < ($1.reference, $1.symbolName, $1.unit)
        }
        unresolved.sort()

        // 2. Wire segments and their connectivity.
        struct Segment { var a: DPoint; var b: DPoint }
        var segments: [Segment] = []
        for wire in state.wires where wire.points.count >= 2 {
            for i in 0..<(wire.points.count - 1) {
                let a = wire.points[i], b = wire.points[i + 1]
                if a.distance(to: b) > 1e-9 { segments.append(Segment(a: a, b: b)) }
            }
        }

        var union = UnionFind(count: segments.count)
        // Segments join at shared endpoints and at T-touches.
        for i in segments.indices {
            for j in segments.indices where j > i {
                let s = segments[i], t = segments[j]
                if pointsTouch(s.a, t.a) || pointsTouch(s.a, t.b)
                    || pointsTouch(s.b, t.a) || pointsTouch(s.b, t.b)
                    || pointOnSegment(s.a, t.a, t.b) || pointOnSegment(s.b, t.a, t.b)
                    || pointOnSegment(t.a, s.a, s.b) || pointOnSegment(t.b, s.a, s.b) {
                    union.unite(i, j)
                    continue
                }
                // Interior crossing: connects only when a junction or
                // a pin sits exactly on the crossing point.
                if let crossing = segmentIntersection(s.a, s.b, t.a, t.b) {
                    let junctioned = state.junctions.contains {
                        pointsTouch($0.at, crossing)
                    }
                    let pinned = endpointPoints.contains {
                        pointsTouch($0, crossing)
                    }
                    if junctioned || pinned { union.unite(i, j) }
                }
            }
        }
        // A junction or a pin lying on several segments joins them all
        // (this is what makes a pin bridging two crossing wires, or a
        // junction dot on a crossing, connect the runs).
        func joinSegments(containing point: DPoint) {
            var first: Int? = nil
            for i in segments.indices where pointOnSegment(point, segments[i].a, segments[i].b) {
                if let first { union.unite(first, i) } else { first = i }
            }
        }
        for junction in state.junctions { joinSegments(containing: junction.at) }
        for point in endpointPoints { joinSegments(containing: point) }

        // 3. Assign each endpoint to a geometric component: the wire
        //    run it touches, or a pin-only component keyed by its point
        //    (coincident pins connect even with no wire drawn).
        func pointKey(_ p: DPoint) -> String {
            "\(Int((p.x * 1000).rounded()))|\(Int((p.y * 1000).rounded()))"
        }
        var componentKeyByEndpoint: [Int: String] = [:]
        for index in endpoints.indices {
            let point = endpointPoints[index]
            var key: String? = nil
            for i in segments.indices where pointOnSegment(point, segments[i].a, segments[i].b) {
                key = "wire:\(union.find(i))"
                break
            }
            componentKeyByEndpoint[index] = key ?? "point:\(pointKey(point))"
        }

        // 4. Explicit net names per geometric component: labels lying
        //    on it, plus power names from its endpoints.
        var namesByComponent: [String: Set<String>] = [:]
        for label in state.labels {
            let text = label.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            var key: String? = nil
            for i in segments.indices where pointOnSegment(label.at, segments[i].a, segments[i].b) {
                key = "wire:\(union.find(i))"
                break
            }
            if key == nil {
                // A label exactly on a pin names that pin's component.
                if let match = endpoints.indices.first(where: {
                    pointsTouch(endpointPoints[$0], label.at)
                }) {
                    key = componentKeyByEndpoint[match]
                }
            }
            if let key { namesByComponent[key, default: []].insert(text) }
        }
        for (index, name) in powerNameByEndpoint {
            if let key = componentKeyByEndpoint[index] {
                namesByComponent[key, default: []].insert(name)
            }
        }

        // 5. Merge geometric components that share an explicit name
        //    (same label in two places, same power net, …).
        let componentKeys = Set(componentKeyByEndpoint.values).sorted()
        var componentIndex: [String: Int] = [:]
        for (i, key) in componentKeys.enumerated() { componentIndex[key] = i }
        var groupUnion = UnionFind(count: componentKeys.count)
        var firstComponentByName: [String: Int] = [:]
        for key in componentKeys {
            guard let idx = componentIndex[key] else { continue }
            for name in namesByComponent[key] ?? [] {
                if let other = firstComponentByName[name] {
                    groupUnion.unite(idx, other)
                } else {
                    firstComponentByName[name] = idx
                }
            }
        }

        // 6. Final nets: group endpoints, attach names, drop singles.
        var endpointsByGroup: [Int: [Int]] = [:]
        var namesByGroup: [Int: Set<String>] = [:]
        for index in endpoints.indices {
            guard let key = componentKeyByEndpoint[index],
                  let ci = componentIndex[key] else { continue }
            let group = groupUnion.find(ci)
            endpointsByGroup[group, default: []].append(index)
        }
        for key in componentKeys {
            guard let ci = componentIndex[key] else { continue }
            let group = groupUnion.find(ci)
            namesByGroup[group, default: []].formUnion(namesByComponent[key] ?? [])
        }

        func endpointSortKey(_ e: ConnectionEndpoint) -> (String, Int, String, String) {
            // Natural pin order: numeric pins by value, others after.
            if let n = Int(e.pinNumber) { return (e.reference, n, "", e.symbolName) }
            return (e.reference, Int.max, e.pinNumber, e.symbolName)
        }

        var namedNets: [ConnectionNet] = []
        var unnamedGroups: [[ConnectionEndpoint]] = []
        for (group, indices) in endpointsByGroup where indices.count >= 2 {
            let sortedEndpoints = indices.map { endpoints[$0] }
                .sorted { endpointSortKey($0) < endpointSortKey($1) }
            let names = (namesByGroup[group] ?? []).sorted()
            if let primary = names.first {
                namedNets.append(ConnectionNet(
                    name: primary,
                    aliases: Array(names.dropFirst()),
                    endpoints: sortedEndpoints))
            } else {
                unnamedGroups.append(sortedEndpoints)
            }
        }
        namedNets.sort { $0.name < $1.name }
        unnamedGroups.sort {
            let a = $0.first.map(endpointSortKey), b = $1.first.map(endpointSortKey)
            switch (a, b) {
            case let (a?, b?): return a < b
            case (nil, _): return false
            case (_, nil): return true
            }
        }
        var nets = namedNets
        for (i, groupEndpoints) in unnamedGroups.enumerated() {
            nets.append(ConnectionNet(name: "Net-\(i + 1)", aliases: [], endpoints: groupEndpoints))
        }

        return ConnectionTable(
            formatVersion: ConnectionTable.currentFormatVersion,
            schematicTitle: state.title,
            sourceFileName: sourceFileName,
            generatedAt: Date(),
            components: components,
            nets: nets,
            unresolvedSymbols: unresolved)
    }

    // MARK: - Geometry helpers

    private static func pointsTouch(_ a: DPoint, _ b: DPoint) -> Bool {
        a.distance(to: b) <= tolerance
    }

    private static func pointOnSegment(_ p: DPoint, _ a: DPoint, _ b: DPoint) -> Bool {
        distanceFromPointToSegment(p, a, b) <= tolerance
    }

    private static func distanceFromPointToSegment(_ p: DPoint,
                                                   _ a: DPoint,
                                                   _ b: DPoint) -> Double {
        let ab = b - a
        let lengthSquared = ab.x * ab.x + ab.y * ab.y
        if lengthSquared < 1e-12 { return p.distance(to: a) }
        let t = max(0, min(1, ((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / lengthSquared))
        let projection = DPoint(x: a.x + ab.x * t, y: a.y + ab.y * t)
        return p.distance(to: projection)
    }

    /// The crossing point of two segments, or nil when they do not
    /// cross within both spans (parallel/collinear pairs return nil —
    /// those are covered by the endpoint / on-segment rules).
    private static func segmentIntersection(_ sa: DPoint, _ sb: DPoint,
                                            _ ta: DPoint, _ tb: DPoint) -> DPoint? {
        let r = sb - sa
        let u = tb - ta
        let denominator = r.x * u.y - r.y * u.x
        if abs(denominator) < 1e-12 { return nil }
        let qp = ta - sa
        let alpha = (qp.x * u.y - qp.y * u.x) / denominator
        let beta = (qp.x * r.y - qp.y * r.x) / denominator
        let eps = 1e-9
        guard alpha >= -eps, alpha <= 1 + eps, beta >= -eps, beta <= 1 + eps
        else { return nil }
        return DPoint(x: sa.x + r.x * alpha, y: sa.y + r.y * alpha)
    }

    private static func cleanedProperty(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespaces),
              !value.isEmpty, value != "~" else { return nil }
        return value
    }
}

// MARK: - Union-find

private struct UnionFind {
    private var parent: [Int]
    private var rank: [Int]

    init(count: Int) {
        parent = Array(0..<count)
        rank = Array(repeating: 0, count: count)
    }

    mutating func find(_ x: Int) -> Int {
        var root = x
        while parent[root] != root { root = parent[root] }
        var current = x
        while parent[current] != root {
            let next = parent[current]
            parent[current] = root
            current = next
        }
        return root
    }

    mutating func unite(_ a: Int, _ b: Int) {
        let ra = find(a), rb = find(b)
        if ra == rb { return }
        if rank[ra] < rank[rb] {
            parent[ra] = rb
        } else if rank[ra] > rank[rb] {
            parent[rb] = ra
        } else {
            parent[rb] = ra
            rank[ra] += 1
        }
    }
}
