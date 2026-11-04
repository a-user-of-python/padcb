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
/// - Net naming follows KiCad 10's driver priority
///   (eeschema/connection_graph.h CONNECTION_SUBGRAPH::PRIORITY:
///   PIN=1 < SHEET_PIN=2 < HIER_LABEL=3 < LOCAL_LABEL=4 <
///   LOCAL_POWER_PIN=5 < GLOBAL_POWER_PIN=6 < GLOBAL=7),
///   renumbered locally to the classes PadCB has: label = 1,
///   local power = 2, global power = 3. A label whose point lies
///   on a wire (or exactly on a pin) names that wire's net; a
///   power symbol names its net from its Value (e.g. "GND"),
///   in the local tier when its definition's (power local)
///   scope says so and in the global tier otherwise — a power
///   symbol with NO (power …) scope (classic #-reference
///   symbols) reads as global, KiCad's treatment of its bundled
///   power library. The winning (primary) name is the first
///   name of the highest non-empty tier, names sorted ascending
///   within the tier (eeschema/connection_graph.cpp
///   ResolveDrivers tie-breaks: prefer non-"-Pad" names, then
///   alphabetical). Nets carrying the same name in ANY tier
///   are the same net, even when drawn as separate wire runs.
///   Every other distinct explicit name on the merged net is
///   recorded as an alias — the losing names, surfaced by ERC
///   as driver conflicts.
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
    /// The schematic wire items forming this net (part 5.3, S1),
    /// sorted by id string for determinism. OPTIONAL on purpose:
    /// tables written before part 5.3 have no such key and still
    /// decode (formatVersion stays 1); read it through
    /// `wireIDList`, never directly.
    var wireIDs: [UUID]? = nil

    /// `wireIDs` with the pre-5.3 case folded away.
    var wireIDList: [UUID] { wireIDs ?? [] }

    /// The symbol instance ids on this net, in endpoint order,
    /// duplicates removed (an instance with two pins on the net
    /// appears once).
    var symbolInstanceIDs: [UUID] {
        var seen = Set<UUID>()
        var ids: [UUID] = []
        for endpoint in endpoints where seen.insert(endpoint.instanceID).inserted {
            ids.append(endpoint.instanceID)
        }
        return ids
    }
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
    /// Wire item id (UUID string) -> net name, for every wire
    /// participating in a written net (part 5.3, S1). Recorded by
    /// the builder from its own union-find, so Highlight Net /
    /// Select Connection answer membership WITHOUT re-deriving
    /// the nets. OPTIONAL: pre-5.3 tables decode with nil
    /// (formatVersion stays 1).
    var wireNetByWireID: [String: String]? = nil
    /// "instanceID|pinNumber" keys of the pins a placed
    /// no-connect flag (part 5.3, S4) excluded from the nets —
    /// the same key format SchematicERC uses for its pin census,
    /// so ERC can exempt flagged pins from pin-not-connected.
    /// OPTIONAL for the same backward-compatibility reason.
    var flaggedNoConnectPins: [String]? = nil

    static let currentFormatVersion = 1

    /// The net called `name`, or nil.
    func net(named name: String) -> ConnectionNet? {
        nets.first { $0.name == name }
    }

    /// The wire->net map with UUID keys (empty for pre-5.3
    /// tables, which recorded none).
    var wireNetMap: [UUID: String] {
        var map: [UUID: String] = [:]
        for (key, name) in wireNetByWireID ?? [:] {
            if let id = UUID(uuidString: key) { map[id] = name }
        }
        return map
    }

    /// The net a wire item belongs to, or nil when the wire
    /// participates in no written net. Answers from the recorded
    /// map first, then from the per-net wire id lists, so a
    /// hand-built table carrying only one of the two still
    /// answers.
    func netName(forWireID id: UUID) -> String? {
        if let name = wireNetMap[id] { return name }
        return nets.first { $0.wireIDList.contains(id) }?.name
    }

    /// The wire item ids forming the named net (the net's own
    /// recorded list, plus any map entries naming it that the
    /// list missed — deduplicated, the list's order kept, map
    /// extras appended sorted by id string).
    func wireIDs(forNet name: String) -> [UUID] {
        guard let net = net(named: name) else { return [] }
        var ids = net.wireIDList
        let extras = wireNetMap.filter { $0.value == name }
            .map(\.key)
            .filter { !ids.contains($0) }
            .sorted { $0.uuidString < $1.uuidString }
        ids += extras
        return ids
    }

    /// The symbol instance ids on the named net.
    func symbolInstanceIDs(forNet name: String) -> [UUID] {
        net(named: name)?.symbolInstanceIDs ?? []
    }

    /// The recorded flagged-no-connect pin keys ("instance|pin")
    /// as a set (empty for pre-5.3 tables).
    var flaggedNoConnectPinKeySet: Set<String> {
        Set(flaggedNoConnectPins ?? [])
    }
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
        // Per-endpoint power name with its naming tier (part 5.4):
        // KiCad priorities LOCAL_LABEL=4 / LOCAL_POWER_PIN=5 /
        // GLOBAL_POWER_PIN=6, renumbered locally — label = 1,
        // local power = 2, global power = 3.
        var powerByEndpoint: [Int: (name: String, tier: Int)] = [:]
        var seenEndpointKeys = Set<String>()
        var flaggedNoConnects = Set<String>()

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
            // A power symbol with NO (power …) scope — classic
            // #-reference symbols — reads as global, KiCad's
            // treatment of its bundled power library.
            let powerTier: Int = def.powerScope == "local" ? 2 : 3

            for entry in SymbolDrawList.pinWorldPoints(def: def, placed: placed) {
                let pin = entry.pin
                // A placed no-connect flag (part 5.3, S4) excludes
                // the pin EXACTLY like an intrinsic no-connect:
                // it never becomes an endpoint, and the table
                // records its key so ERC can exempt it too.
                if state.noConnects.contains(where: {
                    pointsTouch($0.at, entry.point)
                }) {
                    flaggedNoConnects.insert(
                        "\(placed.id.uuidString)|\(pin.number)")
                    continue
                }
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
                if let powerName {
                    powerByEndpoint[index] = (name: powerName, tier: powerTier)
                }
            }
        }
        components.sort {
            ($0.reference, $0.symbolName, $0.unit) < ($1.reference, $1.symbolName, $1.unit)
        }
        unresolved.sort()

        // 2. Wire segments and their connectivity.
        struct Segment { var a: DPoint; var b: DPoint; var wireID: UUID }
        var segments: [Segment] = []
        for wire in state.wires where wire.points.count >= 2 {
            for i in 0..<(wire.points.count - 1) {
                let a = wire.points[i], b = wire.points[i + 1]
                if a.distance(to: b) > 1e-9 {
                    segments.append(Segment(a: a, b: b, wireID: wire.id))
                }
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

        // 4. Explicit net names per geometric component, tiered
        //    by KiCad driver priority (part 5.4): labels lying on
        //    it insert tier 1, plus power names from its endpoints
        //    inserting their tier (local power = 2, global = 3).
        var namesByComponent: [String: [Int: Set<String>]] = [:]
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
            if let key {
                var tiers = namesByComponent[key] ?? [:]
                tiers[1, default: []].insert(text)
                namesByComponent[key] = tiers
            }
        }
        for (index, power) in powerByEndpoint {
            if let key = componentKeyByEndpoint[index] {
                var tiers = namesByComponent[key] ?? [:]
                tiers[power.tier, default: []].insert(power.name)
                namesByComponent[key] = tiers
            }
        }

        // 5. Merge geometric components that share an explicit name
        //    in ANY tier (same label in two places, same power
        //    net, …) — connectivity is name equality, unchanged.
        let componentKeys = Set(componentKeyByEndpoint.values).sorted()
        var componentIndex: [String: Int] = [:]
        for (i, key) in componentKeys.enumerated() { componentIndex[key] = i }
        var groupUnion = UnionFind(count: componentKeys.count)
        var firstComponentByName: [String: Int] = [:]
        for key in componentKeys {
            guard let idx = componentIndex[key] else { continue }
            let tiers = namesByComponent[key] ?? [:]
            for tier in tiers.keys.sorted() {
                for name in tiers[tier] ?? [] {
                    if let other = firstComponentByName[name] {
                        groupUnion.unite(idx, other)
                    } else {
                        firstComponentByName[name] = idx
                    }
                }
            }
        }

        // 6. Final nets: group endpoints, attach names, drop singles.
        var endpointsByGroup: [Int: [Int]] = [:]
        var namesByGroup: [Int: [Int: Set<String>]] = [:]
        for index in endpoints.indices {
            guard let key = componentKeyByEndpoint[index],
                  let ci = componentIndex[key] else { continue }
            let group = groupUnion.find(ci)
            endpointsByGroup[group, default: []].append(index)
        }
        for key in componentKeys {
            guard let ci = componentIndex[key] else { continue }
            let group = groupUnion.find(ci)
            for (tier, names) in namesByComponent[key] ?? [:] {
                var tiers = namesByGroup[group] ?? [:]
                tiers[tier, default: []].formUnion(names)
                namesByGroup[group] = tiers
            }
        }

        func endpointSortKey(_ e: ConnectionEndpoint) -> (String, Int, String, String) {
            // Natural pin order: numeric pins by value, others after.
            if let n = Int(e.pinNumber) { return (e.reference, n, "", e.symbolName) }
            return (e.reference, Int.max, e.pinNumber, e.symbolName)
        }

        // Net naming: named groups take their primary name;
        // unnamed groups become Net-1, Net-2, … in first-endpoint
        // order (the part-2 deterministic rule, unchanged). The
        // group -> name map is computed FIRST (part 5.3, S1) so
        // wire membership can be recorded against final names.
        var groupToNetName: [Int: String] = [:]
        var namedGroups: [(group: Int, endpoints: [ConnectionEndpoint],
                           primary: String, aliases: [String])] = []
        var unnamedGroups: [(group: Int, endpoints: [ConnectionEndpoint])] = []
        for (group, indices) in endpointsByGroup where indices.count >= 2 {
            let sortedEndpoints = indices.map { endpoints[$0] }
                .sorted { endpointSortKey($0) < endpointSortKey($1) }
            // Primary (part 5.4): the first non-empty tier in
            // DESCENDING tier order wins (global power 3, then
            // local power 2, then label 1 — KiCad's
            // CONNECTION_SUBGRAPH::PRIORITY order); within the
            // winning tier names sort ascending and the first
            // wins (ResolveDrivers tie-break). Aliases are every
            // other distinct explicit name across all tiers,
            // sorted ascending — the losing names.
            let tieredNames = namesByGroup[group] ?? [:]
            var primary: String? = nil
            for tier in [3, 2, 1] {
                if let names = tieredNames[tier], !names.isEmpty {
                    primary = names.sorted().first
                    break
                }
            }
            if let primary {
                let allNames = Set(tieredNames.values.flatMap { $0 })
                let aliases = allNames.subtracting([primary]).sorted()
                namedGroups.append((group, sortedEndpoints, primary,
                                    aliases))
                groupToNetName[group] = primary
            } else {
                unnamedGroups.append((group, sortedEndpoints))
            }
        }
        unnamedGroups.sort {
            let a = $0.endpoints.first.map(endpointSortKey)
            let b = $1.endpoints.first.map(endpointSortKey)
            switch (a, b) {
            case let (a?, b?): return a < b
            case (nil, _): return false
            case (_, nil): return true
            }
        }
        for (i, unnamed) in unnamedGroups.enumerated() {
            groupToNetName[unnamed.group] = "Net-\(i + 1)"
        }

        // Wire membership per net (part 5.3, S1): a wire item
        // participates in the net its segments' geometric group
        // was named into. Wires on groups that were dropped
        // (fewer than 2 endpoints) participate in no net.
        var wireIDsByGroup: [Int: Set<UUID>] = [:]
        var wireNetByWireID: [String: String] = [:]
        for i in segments.indices {
            guard let componentIdx = componentIndex["wire:\(union.find(i))"],
                  let netName = groupToNetName[groupUnion.find(componentIdx)]
            else { continue }
            wireIDsByGroup[groupUnion.find(componentIdx), default: []]
                .insert(segments[i].wireID)
            wireNetByWireID[segments[i].wireID.uuidString] = netName
        }
        func netWireIDs(_ group: Int) -> [UUID] {
            (wireIDsByGroup[group] ?? []).sorted { $0.uuidString < $1.uuidString }
        }

        var nets: [ConnectionNet] = []
        for named in namedGroups.sorted(by: { $0.primary < $1.primary }) {
            nets.append(ConnectionNet(
                name: named.primary,
                aliases: named.aliases,
                endpoints: named.endpoints,
                wireIDs: netWireIDs(named.group)))
        }
        for unnamed in unnamedGroups {
            nets.append(ConnectionNet(
                name: groupToNetName[unnamed.group] ?? "",
                aliases: [],
                endpoints: unnamed.endpoints,
                wireIDs: netWireIDs(unnamed.group)))
        }

        return ConnectionTable(
            formatVersion: ConnectionTable.currentFormatVersion,
            schematicTitle: state.title,
            sourceFileName: sourceFileName,
            generatedAt: Date(),
            components: components,
            nets: nets,
            unresolvedSymbols: unresolved,
            wireNetByWireID: wireNetByWireID,
            flaggedNoConnectPins: flaggedNoConnects.sorted())
    }

    // MARK: - Geometry helpers

    private static func pointsTouch(_ a: DPoint, _ b: DPoint) -> Bool {
        a.distance(to: b) <= tolerance
    }

    private static func pointOnSegment(_ p: DPoint, _ a: DPoint, _ b: DPoint) -> Bool {
        distanceFromPointToSegment(p, a, b) <= tolerance
    }

    static func distanceFromPointToSegment(_ p: DPoint,
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

// MARK: - Electrical rules check (part 5.2)

/// One ERC finding (KiCad's eeschema ERC, PadCB's rule set).
/// `instanceID` identifies the placed symbol a finding belongs
/// to where one exists, so the editor can select it.
struct ERCFinding: Equatable {
    enum Severity: Equatable {
        case error, warning
    }
    enum Kind: String, Equatable {
        case pinNotConnected
        case powerPinNotDriven
        case outputConflict
        case driverConflict
        case duplicateReference
        case unannotated
        case unresolvedSymbol
        case labelNotConnected
    }
    var severity: Severity
    var kind: Kind
    var message: String
    var instanceID: UUID?
    /// The reference the finding keys on (part 5.3, P7): the
    /// symbol reference for pin/annotation findings, the NET
    /// name for per-net findings, the unresolved-symbol line
    /// for unresolvedSymbol, "" for label findings.
    var reference: String = ""
    /// The finding's detail slot: the pin number for
    /// pinNotConnected, the involved "Ref pin N" list for the
    /// per-net findings, the losing alias for driverConflict,
    /// "unit N" for duplicateReference, the
    /// symbol name for unannotated, the label text for
    /// labelNotConnected, "" for unresolvedSymbol.
    var detail: String = ""

    /// STABLE exclusion identity (part 5.3, P7): kind, reference
    /// and detail, pipe-joined — content-derived, never
    /// row-order-derived, so an exclusion stays attached to its
    /// finding across re-checks and its absence (a fixed
    /// problem) reads as a stale key rather than silently
    /// landing on a neighbour.
    var key: String {
        [kind.rawValue, reference, detail].joined(separator: "|")
    }
}

/// PadCB's electrical rules check. The net facts come from the
/// REAL connection-table derivation (ConnectionTableBuilder —
/// the same nets the PCB editor consumes), plus a census of
/// every placed pin: a pin the table does not carry sits on a
/// net of fewer than 2 endpoints, which is precisely KiCad's
/// "pin not connected". Rules (eeschema/erc.cpp semantics,
/// restricted to what PadCB's model can know — no buses, no
/// hierarchical sheets exist here):
/// - pin not connected (error): a pin (not of type no_connect)
///   on no 2+-endpoint net.
/// - power pin not driven (error): a net carrying a power_in
///   pin of an ordinary symbol but driven by nothing — no
///   power_out pin and no power symbol. (PadCB has no separate
///   PWR_FLAG: a power symbol on the net IS the driver, as in
///   KiCad where a power port drives its net.)
/// - output conflict (error): a net with 2+ driving pins
///   (output or power_out of ordinary symbols).
/// - driver conflict (warning, part 5.4): a net carrying more
///   than one explicit name — every alias is a second strong
///   name-source (label or power) on the net, precisely
///   KiCad's multiple-driver condition
///   (eeschema/connection_graph.cpp ercCheckMultipleDrivers,
///   ERCE_DRIVER_CONFLICT, whose default severity in
///   eeschema/erc/erc_settings.cpp is WARNING). One finding
///   per losing NAME — KiCad reports per driver item, which
///   is PadCB's stated delta, since the table records names,
///   not driver items.
/// - duplicate reference (error): two placed instances sharing
///   reference AND unit (the same reference across DIFFERENT
///   units is one legal multi-unit part).
/// - unannotated (warning): a reference with no numeric suffix
///   or a "?" — the Annotate tool fixes these.
/// - unresolved symbol (error): a placed symbol whose library
///   definition no longer resolves (from the table build).
/// - label not connected (warning): a label touching no wire
///   segment and no pin.
enum SchematicERC {
    /// Splits findings into visible and excluded by exclusion
    /// KEY (part 5.3, P7): a finding whose `key` is in
    /// `excludedKeys` (the state's ercExclusions, as a set) is
    /// excluded; order is preserved in both lists. check()
    /// itself is unchanged — exclusions are a presentation
    /// filter over its output, never an input to it.
    static func visibleFindings(
        _ findings: [ERCFinding], excluding excludedKeys: Set<String>
    ) -> (visible: [ERCFinding], excluded: [ERCFinding]) {
        var visible: [ERCFinding] = []
        var excluded: [ERCFinding] = []
        for finding in findings {
            if excludedKeys.contains(finding.key) {
                excluded.append(finding)
            } else {
                visible.append(finding)
            }
        }
        return (visible, excluded)
    }

    static func check(state: SchematicState,
                      resolveSymbol: (PlacedSymbol) -> KiCadSymbolDef?)
        -> [ERCFinding] {
        let table = ConnectionTableBuilder.build(
            state: state, sourceFileName: "",
            resolveSymbol: resolveSymbol,
            resolveFootprint: { _, _ in (nil, nil) })

        var findings: [ERCFinding] = []

        // Endpoint census from the table: (instance, pin number).
        var tabledPins = Set<String>()
        for net in table.nets {
            for endpoint in net.endpoints {
                tabledPins.insert("\(endpoint.instanceID.uuidString)|\(endpoint.pinNumber)")
            }
        }
        let placedByID: [UUID: PlacedSymbol] = Dictionary(
            uniqueKeysWithValues: state.symbols.map { ($0.id, $0) })
        func isPowerInstance(_ instanceID: UUID) -> Bool {
            guard let placed = placedByID[instanceID],
                  let def = resolveSymbol(placed) else { return false }
            return def.isPower
        }

        // -- Pin not connected --
        var notConnected: [ERCFinding] = []
        for placed in state.symbols {
            guard let def = resolveSymbol(placed) else { continue }
            // Power symbols are their own global net (KiCad
            // semantics) — never "not connected".
            if def.isPower { continue }
            var seenNumbers = Set<String>()
            for entry in SymbolDrawList.pinWorldPoints(def: def, placed: placed) {
                let pin = entry.pin
                if pin.type == .noConnect { continue }
                // Duplicate pin numbers on one instance are
                // jumpers (one electrical pin): census once.
                guard seenNumbers.insert(pin.number).inserted else { continue }
                let key = "\(placed.id.uuidString)|\(pin.number)"
                // A pin under a placed no-connect flag (part
                // 5.3, S4) is exempt exactly like an intrinsic
                // no-connect: the table recorded its key while
                // excluding it from the nets.
                if table.flaggedNoConnectPinKeySet.contains(key) {
                    continue
                }
                if !tabledPins.contains(key) {
                    let name = KiCadText.plain(pin.name)
                    notConnected.append(ERCFinding(
                        severity: .error, kind: .pinNotConnected,
                        message: "\(placed.reference) pin \(pin.number)"
                            + (name.isEmpty ? "" : " (\(name))")
                            + " is not connected",
                        instanceID: placed.id,
                        reference: placed.reference,
                        detail: pin.number))
                }
            }
        }
        findings += notConnected.sorted { $0.message < $1.message }

        // -- Power not driven + output conflicts (per table net) --
        var powerFindings: [ERCFinding] = []
        var outputFindings: [ERCFinding] = []
        for net in table.nets {
            var powerInPins: [ConnectionEndpoint] = []
            var drivers: [ConnectionEndpoint] = []
            var hasPowerSymbol = false
            for endpoint in net.endpoints {
                if isPowerInstance(endpoint.instanceID) {
                    hasPowerSymbol = true
                    continue
                }
                if endpoint.pinType == KiCadPinType.powerIn.rawValue {
                    powerInPins.append(endpoint)
                }
                if endpoint.pinType == KiCadPinType.powerOut.rawValue
                    || endpoint.pinType == KiCadPinType.output.rawValue {
                    drivers.append(endpoint)
                }
            }
            if !powerInPins.isEmpty && drivers.isEmpty && !hasPowerSymbol {
                let names = powerInPins
                    .map { "\($0.reference) pin \($0.pinNumber)" }
                    .joined(separator: ", ")
                powerFindings.append(ERCFinding(
                    severity: .error, kind: .powerPinNotDriven,
                    message: "Net \(net.name): power pin(s) \(names) "
                        + "are not driven by any output or power symbol",
                    instanceID: powerInPins.first?.instanceID,
                    reference: net.name,
                    detail: names))
            }
            let driving = drivers
            if driving.count > 1 {
                let names = driving
                    .map { "\($0.reference) pin \($0.pinNumber)" }
                    .joined(separator: ", ")
                outputFindings.append(ERCFinding(
                    severity: .error, kind: .outputConflict,
                    message: "Net \(net.name): outputs \(names) "
                        + "are wired together",
                    instanceID: driving.first?.instanceID,
                    reference: net.name,
                    detail: names))
            }
        }
        findings += powerFindings.sorted { $0.message < $1.message }
        findings += outputFindings.sorted { $0.message < $1.message }

        // -- Driver conflicts (part 5.4) --
        // Every alias is a second strong name-source (label or
        // power) on the net — precisely KiCad's multiple-driver
        // condition (connection_graph.cpp
        // ercCheckMultipleDrivers, ERCE_DRIVER_CONFLICT).
        // One finding per losing NAME (KiCad reports per driver
        // item) — the stated delta, since the table records
        // names, not driver items.
        var driverFindings: [ERCFinding] = []
        for net in table.nets {
            for alias in net.aliases {
                driverFindings.append(ERCFinding(
                    severity: .warning, kind: .driverConflict,
                    message: "Both \(net.name) and \(alias) are attached to the same net; \(net.name) will be used as the net name",
                    instanceID: nil,
                    reference: net.name,
                    detail: alias))
            }
        }
        findings += driverFindings.sorted { $0.message < $1.message }

        // -- Duplicate reference + unit --
        var byRefUnit: [String: [PlacedSymbol]] = [:]
        for placed in state.symbols where !placed.reference.hasPrefix("#") {
            byRefUnit["\(placed.reference)\u{1}\(placed.unit)", default: []]
                .append(placed)
        }
        var duplicates: [ERCFinding] = []
        for group in byRefUnit.values where group.count > 1 {
            duplicates.append(ERCFinding(
                severity: .error, kind: .duplicateReference,
                message: "\(group[0].reference) unit \(group[0].unit) is placed "
                    + "\(group.count) times — references must be unique per unit",
                instanceID: group[0].id,
                reference: group[0].reference,
                detail: "unit \(group[0].unit)"))
        }
        findings += duplicates.sorted { $0.message < $1.message }

        // -- Unannotated --
        var unannotated: [ERCFinding] = []
        var seenParts = Set<String>()
        for placed in state.symbols
        where !placed.reference.hasPrefix("#")
            && !SchematicDocument.isAnnotated(placed.reference) {
            let partKey = "\(placed.library)\u{1}\(placed.symbolName)\u{1}\(placed.reference)"
            guard seenParts.insert(partKey).inserted else { continue }
            unannotated.append(ERCFinding(
                severity: .warning, kind: .unannotated,
                message: "\(placed.reference) (\(placed.symbolName)) "
                    + "is not annotated — run Annotate",
                instanceID: placed.id,
                reference: placed.reference,
                detail: placed.symbolName))
        }
        findings += unannotated.sorted { $0.message < $1.message }

        // -- Unresolved symbols (from the table build) --
        for line in table.unresolvedSymbols {
            findings.append(ERCFinding(
                severity: .error, kind: .unresolvedSymbol,
                message: "Symbol \(line) could not be loaded from its library",
                instanceID: nil,
                reference: line))
        }

        // -- Labels touching nothing --
        var pinPoints: [DPoint] = []
        for placed in state.symbols {
            guard let def = resolveSymbol(placed) else { continue }
            for entry in SymbolDrawList.pinWorldPoints(def: def, placed: placed) {
                pinPoints.append(entry.point)
            }
        }
        var labelFindings: [ERCFinding] = []
        for label in state.labels {
            let onWire = state.wires.contains { wire in
                guard wire.points.count >= 2 else { return false }
                for i in 0..<(wire.points.count - 1)
                where ConnectionTableBuilder.distanceFromPointToSegment(
                    label.at, wire.points[i], wire.points[i + 1])
                    <= ConnectionTableBuilder.tolerance {
                    return true
                }
                return false
            }
            let onPin = pinPoints.contains {
                $0.distance(to: label.at) <= ConnectionTableBuilder.tolerance
            }
            if !onWire && !onPin {
                labelFindings.append(ERCFinding(
                    severity: .warning, kind: .labelNotConnected,
                    message: "Label \"\(label.text)\" is not on any wire or pin",
                    instanceID: nil,
                    detail: label.text))
            }
        }
        findings += labelFindings.sorted { $0.message < $1.message }

        return findings
    }
}
