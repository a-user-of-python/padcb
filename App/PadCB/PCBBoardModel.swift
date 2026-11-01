import Foundation

/// PCB board model: the in-memory board the PCB editor displays,
/// derived ENTIRELY from one decrypted ConnectionTable plus the real
/// symbol definitions and footprint parses it names. Foundation only,
/// so the exact code the editor renders with also compiles into the
/// headless BoardFixture harness (tools/BoardFixture), which proves
/// the pin↔pad correspondence on fixture data.
///
/// KiCad PCB coordinates throughout: millimetres, x right, y DOWN
/// (board convention — no y-flip anywhere in this file or the editor).

// MARK: - Model

/// One symbol pin of a physical component, bound to the footprint pad
/// that carries the same number.
struct BoardPinBinding {
    var pinNumber: String
    /// Pin name with KiCad markup stripped (KiCadText.plain).
    var pinName: String
    /// KiCad pin electrical type, e.g. "passive", "power_in".
    var pinType: String
    /// Net this pin sits on, from the table's endpoints; nil when the
    /// pin is on no written net (a lone pin is not a connection).
    var netName: String?
    /// The footprint pad with this pin's number (the FIRST pad of that
    /// number — duplicate pad numbers are one electrical node).
    /// Nil when the footprint is missing/unresolved, when the symbol
    /// definition is unavailable, or when no pad carries the number
    /// (that case is also a per-component anomaly).
    var pad: KiCadFootprintPad?
}

/// One physical part on the board: all placed-symbol instances that
/// share a reference (the units of a multi-unit part) merged into one.
struct BoardComponent {
    var reference: String
    var value: String
    /// "Lib:Name" display key of the symbol (first instance's).
    var symbolKey: String
    /// The agreed resolved footprint key ("Group:Name" or
    /// "user:Group:Name"), or nil when unresolved / unassigned.
    var footprintKey: String?
    /// How the footprint was chosen at save time:
    /// "instanceChoice" / "property" / "filterExact", or nil for
    /// tables written before match kinds were recorded.
    var matchKind: String?
    /// The parsed footprint, when the key resolved and parsed.
    var footprint: KiCadFootprint?
    /// Pin bindings in natural pin-number order.
    var pins: [BoardPinBinding]
    /// Problems with THIS component (missing pads, conflicting units,
    /// unresolvable footprint, …). Never silently dropped: a component
    /// that cannot be fully verified is kept and its problems listed.
    var anomalies: [String]
    /// Non-problem facts worth showing: duplicate pad numbers,
    /// unnumbered (mechanical) pads, excluded no-connect pins.
    var notes: [String]
    /// Board-space position (mm) of the footprint's local origin —
    /// i.e. boardPoint(local) = origin + local. The footprint's bounds
    /// top-left therefore sits at origin + footprint.bounds.min.
    var origin: FPPoint
    /// Footprint bounds size in mm (12×8 placeholder when unresolved).
    var boundsSize: (w: Double, h: Double)
}

struct BoardModel {
    var tableTitle: String
    var sourceFileName: String
    /// Components in natural reference order (power symbols with no
    /// footprint are NOT here — see excludedPowerReferences).
    var components: [BoardComponent]
    /// Problems that belong to the board as a whole: unit footprint
    /// disagreements, plus the table's unresolvedSymbols lines passed
    /// through verbatim.
    var globalAnomalies: [String]
    /// References kept off the board because they are power symbols
    /// with no footprint (KiCad keeps power symbols off the board).
    var excludedPowerReferences: [String]
    var netCount: Int
}

// MARK: - Builder

enum PCBBoardModelBuilder {

    /// Placeholder footprint size (mm) for components whose footprint
    /// could not be resolved — they still get a board slot so nothing
    /// is invisible.
    static let placeholderSize = (w: 12.0, h: 8.0)
    /// Horizontal/vertical gap between packed footprints (mm).
    static let packGap = 4.0
    /// Shelf-packing row width (mm): a component that would cross it
    /// starts a new row.
    static let packRowWidth = 160.0

    /// Binding rules (pinned — the BoardFixture harness asserts them):
    ///
    /// - Components group by reference (natural sort). Instances of
    ///   one reference are units of one physical part; if instances
    ///   disagree on resolvedFootprintKey that is a GLOBAL anomaly
    ///   naming the reference (the first non-nil key wins).
    /// - Pin universe per reference: the union over instances of
    ///   (unit-0 pins + that instance's unit pins), keyed by pin
    ///   number. The same number from two instances must agree on
    ///   name/type, else an anomaly (first definition kept).
    ///   no_connect pins are EXCLUDED from bindings (KiCad: they
    ///   connect to nothing) but counted in a per-component note.
    /// - Net per pin: from the table's net endpoints matching
    ///   (instanceID, pinNumber), built from ALL endpoints. If two
    ///   instances expose the same pin number with different nets,
    ///   that is an anomaly (first net kept).
    /// - Footprint: the group's agreed resolvedFootprintKey, resolved
    ///   through `resolveFootprint`. Unresolved cases become
    ///   anomalies, never dropped components:
    ///     * footprintReference present but key nil →
    ///       "footprint <ref> is not in the libraries"
    ///     * key present but entry/parse missing → anomaly
    ///     * no footprintReference at all → "no footprint assigned"
    ///       — EXCEPT power symbols (every instance's def.isPower),
    ///       which go to excludedPowerReferences instead and produce
    ///       no component (KiCad keeps power symbols off the board).
    ///   If a symbol definition cannot be loaded (the table's
    ///   unresolvedSymbols mentions the reference, or resolveSymbol
    ///   returns nil for every instance) the component is kept with
    ///   the anomaly "symbol definition unavailable — pins cannot be
    ///   verified" and pins derived from table endpoints only
    ///   (net-known pins, pad nil); pad checks are skipped for it
    ///   (they could not be verified, so reporting them would be
    ///   noise on top of the real problem).
    /// - Pads: padByNumber = first pad per distinct (non-empty)
    ///   number. A pin with no pad of that number → anomaly "pin N
    ///   (name) has no pad". A distinct pad number with no pin →
    ///   anomaly "pad N is not connected to any pin". Pads with an
    ///   EMPTY number are not anomalies: one per-component note
    ///   "K unnumbered (mechanical) pads". Duplicate pad numbers are
    ///   the same electrical node: the pin binds to the first, with
    ///   the note "pad N appears K times (same node)".
    /// - Layout: deterministic shelf packing in reference order —
    ///   footprints by their bounds (unresolved → 12×8 placeholder),
    ///   4 mm gaps, row width ≈ 160 mm.
    static func build(table: ConnectionTable,
                      resolveSymbol: (String, String) -> KiCadSymbolDef?,
                      resolveFootprint: (String) -> (entry: FootprintEntry, parsed: KiCadFootprint)?) -> BoardModel {
        var globalAnomalies: [String] = []
        // The table's own unresolved-symbol lines pass through
        // verbatim — they name references whose pins never even made
        // it into the table's endpoint lists.
        globalAnomalies += table.unresolvedSymbols

        // Endpoints grouped by instance, in table order (nets in
        // order, endpoints in order) — the single source for every
        // net lookup below, built from ALL endpoints.
        var endpointsByInstance: [UUID: [(endpoint: ConnectionEndpoint, netName: String)]] = [:]
        for net in table.nets {
            for endpoint in net.endpoints {
                endpointsByInstance[endpoint.instanceID, default: []]
                    .append((endpoint: endpoint, netName: net.name))
            }
        }

        // Symbol defs are resolved once per (library, symbolName).
        var defCache: [String: KiCadSymbolDef?] = [:]
        func defFor(library: String, symbolName: String) -> KiCadSymbolDef? {
            let key = library + "\u{1}" + symbolName
            if let cached = defCache[key] { return cached }
            let def = resolveSymbol(library, symbolName)
            defCache[key] = def
            return def
        }

        func referenceIsUnresolved(_ reference: String) -> Bool {
            table.unresolvedSymbols.contains {
                $0 == reference
                    || $0.hasPrefix(reference + " ")
                    || $0.hasPrefix(reference + "(")
            }
        }

        // Group instances by reference; instances within a group in
        // (unit, instanceID) order so every "first wins" rule below is
        // deterministic.
        let grouped = Dictionary(grouping: table.components, by: \.reference)
        let references = grouped.keys.sorted(by: naturalLess)

        var components: [BoardComponent] = []
        var excludedPowerReferences: [String] = []

        for reference in references {
            let instances = (grouped[reference] ?? []).sorted {
                ($0.unit, $0.instanceID.uuidString) < ($1.unit, $1.instanceID.uuidString)
            }
            guard let first = instances.first else { continue }
            let defs: [KiCadSymbolDef?] = instances.map {
                defFor(library: $0.library, symbolName: $0.symbolName)
            }
            let allDefsMissing = defs.allSatisfy { $0 == nil }
            let defUnavailable = allDefsMissing || referenceIsUnresolved(reference)

            var anomalies: [String] = []
            var notes: [String] = []
            if defUnavailable {
                anomalies.append("symbol definition unavailable — pins cannot be verified")
            }

            // -- Agreed footprint key (+ disagreement is global) --
            let distinctKeys = Set(instances.map { $0.resolvedFootprintKey })
            let agreedKey: String? = instances.lazy.map { $0.resolvedFootprintKey }
                .first { $0 != nil } ?? nil
            if distinctKeys.count > 1 {
                let listed = Set(instances.compactMap { $0.resolvedFootprintKey })
                    .sorted()
                    .joined(separator: ", ")
                globalAnomalies.append(
                    "\(reference): units disagree on resolved footprint "
                    + "(\(listed)) — using \(agreedKey ?? "none")")
            }
            let matchKind: String? = instances.lazy.map { $0.footprintMatchKind }
                .first { $0 != nil } ?? nil
            let footprintReference: String? = instances.lazy.map { $0.footprintReference }
                .first { $0 != nil } ?? nil

            // -- Power-symbol exclusion (no footprint at all) --
            let everyDefIsPower = defs.allSatisfy { $0?.isPower == true }
            if footprintReference == nil && agreedKey == nil && everyDefIsPower {
                excludedPowerReferences.append(reference)
                continue
            }

            // -- Footprint resolution (one path for every case) --
            var footprint: KiCadFootprint? = nil
            var footprintKey: String? = nil
            if let agreedKey {
                if let resolved = resolveFootprint(agreedKey) {
                    footprint = resolved.parsed
                    footprintKey = agreedKey
                } else {
                    anomalies.append("footprint \(agreedKey) could not be loaded")
                }
            } else if let footprintReference {
                anomalies.append("footprint \(footprintReference) is not in the libraries")
            } else {
                anomalies.append("no footprint assigned")
            }

            // -- Pins --
            var bindings: [BoardPinBinding] = []
            if defUnavailable {
                // Pins from table endpoints only: distinct pin numbers
                // across this group's instances, first endpoint wins
                // for name/type/net; pad stays nil (unverifiable).
                var seen = Set<String>()
                var endpointPins: [BoardPinBinding] = []
                for instance in instances {
                    for entry in endpointsByInstance[instance.instanceID] ?? [] {
                        if seen.contains(entry.endpoint.pinNumber) { continue }
                        seen.insert(entry.endpoint.pinNumber)
                        endpointPins.append(BoardPinBinding(
                            pinNumber: entry.endpoint.pinNumber,
                            pinName: entry.endpoint.pinName,
                            pinType: entry.endpoint.pinType,
                            netName: entry.netName,
                            pad: nil))
                    }
                }
                bindings = endpointPins.sorted { pinNumberLess($0.pinNumber, $1.pinNumber) }
            } else {
                // Pin universe: union over instances of unit-0 pins +
                // the instance's unit pins, keyed by pin number.
                var pinByNumber: [String: KiCadPin] = [:]
                var pinOrder: [String] = []
                var noConnectNumbers = Set<String>()
                for (index, instance) in instances.enumerated() {
                    guard let def = defs[index] else {
                        anomalies.append("symbol definition unavailable for unit \(instance.unit) — its pins cannot be verified")
                        continue
                    }
                    var unitPins: [KiCadPin] = []
                    if let common = def.units[0] { unitPins += common.pins }
                    if instance.unit != 0, let unit = def.units[instance.unit] {
                        unitPins += unit.pins
                    }
                    for pin in unitPins {
                        if pin.type == .noConnect {
                            if pinByNumber[pin.number] == nil {
                                noConnectNumbers.insert(pin.number)
                            }
                            continue
                        }
                        noConnectNumbers.remove(pin.number)
                        if let existing = pinByNumber[pin.number] {
                            let existingName = KiCadText.plain(existing.name)
                            let thisName = KiCadText.plain(pin.name)
                            if existingName != thisName
                                || existing.type != pin.type {
                                anomalies.append(
                                    "pin \(pin.number) has conflicting definitions across units "
                                    + "(\(existingName)/\(existing.type.rawValue) vs "
                                    + "\(thisName)/\(pin.type.rawValue)) — keeping the first")
                            }
                        } else {
                            pinByNumber[pin.number] = pin
                            pinOrder.append(pin.number)
                        }
                    }
                }
                if !noConnectNumbers.isEmpty {
                    let listed = noConnectNumbers.sorted(by: pinNumberLess)
                        .joined(separator: ", ")
                    notes.append("\(noConnectNumbers.count) no-connect pin(s) excluded: \(listed)")
                }

                // Net per pin number from ALL endpoints of the group;
                // two instances exposing one number on different nets
                // is an anomaly (first net kept).
                var netByPin: [String: String] = [:]
                for instance in instances {
                    for entry in endpointsByInstance[instance.instanceID] ?? [] {
                        let number = entry.endpoint.pinNumber
                        if let existing = netByPin[number] {
                            if existing != entry.netName {
                                anomalies.append(
                                    "pin \(number) is on both \(existing) and \(entry.netName) — keeping \(existing)")
                            }
                        } else {
                            netByPin[number] = entry.netName
                        }
                    }
                }

                // Pads: first pad per distinct non-empty number.
                var padByNumber: [String: KiCadFootprintPad] = [:]
                var padCounts: [String: Int] = [:]
                var unnumberedCount = 0
                if let footprint {
                    for pad in footprint.pads {
                        if pad.number.isEmpty {
                            unnumberedCount += 1
                            continue
                        }
                        padCounts[pad.number, default: 0] += 1
                        if padByNumber[pad.number] == nil {
                            padByNumber[pad.number] = pad
                        }
                    }
                    for number in padCounts.keys.sorted(by: pinNumberLess) {
                        if let count = padCounts[number], count > 1 {
                            notes.append("pad \(number) appears \(count) times (same node)")
                        }
                    }
                    if unnumberedCount > 0 {
                        notes.append("\(unnumberedCount) unnumbered (mechanical) pads")
                    }
                }

                for number in pinOrder.sorted(by: pinNumberLess) {
                    guard let pin = pinByNumber[number] else { continue }
                    var pad: KiCadFootprintPad? = nil
                    if footprint != nil {
                        pad = padByNumber[number]
                        if pad == nil {
                            let plain = KiCadText.plain(pin.name)
                            anomalies.append(plain.isEmpty
                                ? "pin \(number) has no pad"
                                : "pin \(number) (\(plain)) has no pad")
                        }
                    }
                    bindings.append(BoardPinBinding(
                        pinNumber: number,
                        pinName: KiCadText.plain(pin.name),
                        pinType: pin.type.rawValue,
                        netName: netByPin[number],
                        pad: pad))
                }
                if footprint != nil {
                    let pinNumbers = Set(pinOrder)
                    for number in padByNumber.keys.sorted(by: pinNumberLess)
                    where !pinNumbers.contains(number) {
                        anomalies.append("pad \(number) is not connected to any pin")
                    }
                }
            }

            // -- Bounds (layout filled in after the loop) --
            let size: (w: Double, h: Double)
            if let footprint {
                let b = footprint.bounds
                size = (w: b.maxX - b.minX, h: b.maxY - b.minY)
            } else {
                size = Self.placeholderSize
            }

            components.append(BoardComponent(
                reference: reference,
                value: first.value,
                symbolKey: "\(first.library):\(first.symbolName)",
                footprintKey: footprintKey,
                matchKind: matchKind,
                footprint: footprint,
                pins: bindings,
                anomalies: anomalies,
                notes: notes,
                origin: .zero,
                boundsSize: size))
        }

        // -- Deterministic shelf packing in reference order --
        var cursorX = 0.0
        var cursorY = 0.0
        var rowHeight = 0.0
        for index in components.indices {
            let size = components[index].boundsSize
            if cursorX > 0, cursorX + size.w > Self.packRowWidth {
                cursorX = 0
                cursorY += rowHeight + Self.packGap
                rowHeight = 0
            }
            // Origin = board position of the footprint's local origin,
            // shifted so the bounds top-left lands on the cursor.
            if let footprint = components[index].footprint {
                let b = footprint.bounds
                components[index].origin = FPPoint(x: cursorX - b.minX,
                                                   y: cursorY - b.minY)
            } else {
                components[index].origin = FPPoint(x: cursorX, y: cursorY)
            }
            cursorX += size.w + Self.packGap
            rowHeight = max(rowHeight, size.h)
        }

        return BoardModel(
            tableTitle: table.schematicTitle,
            sourceFileName: table.sourceFileName,
            components: components,
            globalAnomalies: globalAnomalies,
            excludedPowerReferences: excludedPowerReferences.sorted(by: naturalLess),
            netCount: table.nets.count)
    }

    // MARK: - Ordering helpers

    /// Pin numbers: numeric values ascending first, then the rest in
    /// natural order (e.g. "1", "2", "10", "A1", "B2").
    static func pinNumberLess(_ a: String, _ b: String) -> Bool {
        switch (Int(a), Int(b)) {
        case let (x?, y?): return x != y ? x < y : a < b
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return naturalLess(a, b)
        }
    }

    /// Natural string order: digit runs compare numerically, so
    /// "R2" < "R10" and "U1" < "U12".
    static func naturalLess(_ a: String, _ b: String) -> Bool {
        let ca = Array(a), cb = Array(b)
        var i = 0, j = 0
        while i < ca.count, j < cb.count {
            if ca[i].isNumber, cb[j].isNumber {
                var na = ""
                while i < ca.count, ca[i].isNumber { na.append(ca[i]); i += 1 }
                var nb = ""
                while j < cb.count, cb[j].isNumber { nb.append(cb[j]); j += 1 }
                let ia = Int(na) ?? 0, ib = Int(nb) ?? 0
                if ia != ib { return ia < ib }
                if na.count != nb.count { return na.count < nb.count }
            } else {
                if ca[i] != cb[j] { return ca[i] < cb[j] }
                i += 1
                j += 1
            }
        }
        return (ca.count - i) < (cb.count - j)
    }
}
