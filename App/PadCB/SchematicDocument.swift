import Foundation

// MARK: - Document model types (contract-pinned)

/// A point in document/world coordinates: millimetres, x right, y UP.
struct DPoint: Codable, Equatable, Hashable {
    var x: Double
    var y: Double

    static let zero = DPoint(x: 0, y: 0)

    static func + (a: DPoint, b: DPoint) -> DPoint { DPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: DPoint, b: DPoint) -> DPoint { DPoint(x: a.x - b.x, y: a.y - b.y) }
    static prefix func - (a: DPoint) -> DPoint { DPoint(x: -a.x, y: -a.y) }

    func distance(to other: DPoint) -> Double {
        let dx = x - other.x, dy = y - other.y
        return (dx * dx + dy * dy).squareRoot()
    }
}

struct PlacedSymbol: Identifiable, Codable, Equatable {
    var id: UUID
    var library: String
    var symbolName: String
    var unit: Int
    var x: Double
    var y: Double
    var rotation: Int // 0/90/180/270 CCW, world space
    var mirrorX: Bool
    var mirrorY: Bool
    var reference: String
    var value: String
    /// Per-instance footprint choice (part 3): the
    /// FootprintEntry.resolutionKey of the footprint the user picked
    /// for THIS instance in the properties card, or nil to use the
    /// automatic resolution (the symbol's Footprint property, then
    /// its footprint filters — FootprintMatcher). Optional with a nil
    /// default: synthesized Codable decodes it with decodeIfPresent,
    /// so schematic JSON written before part 3 (no such key) still
    /// loads, and existing PlacedSymbol constructions are unchanged.
    var footprintChoice: String? = nil
    /// De Morgan body style (part 5.2): 2 = the alternate body,
    /// anything else (or nil) = the standard body. Optional with
    /// a nil default for the same decode-compatibility reason as
    /// footprintChoice: schematic JSON written before part 5.2
    /// has no such key and must still load (as style 1).
    var bodyStyle: Int? = nil

    /// The body style in effect (nil reads as the standard body).
    var effectiveBodyStyle: Int { bodyStyle == 2 ? 2 : 1 }

    var origin: DPoint { DPoint(x: x, y: y) }
}

struct WireItem: Identifiable, Codable {
    var id: UUID
    var points: [DPoint] // orthogonal polyline, >= 2 points
}

struct JunctionItem: Identifiable, Codable {
    var id: UUID
    var at: DPoint
}

struct LabelItem: Identifiable, Codable {
    var id: UUID
    var at: DPoint
    var text: String
}

/// A placed no-connect flag (part 5.3, S4; KiCad's SCH_NO_CONNECT):
/// a pin whose world point coincides with the flag's point is
/// treated by the connection-table builder exactly like an
/// intrinsic no-connect pin (excluded from nets), and ERC's
/// pin-not-connected kind exempts it.
struct NoConnectItem: Identifiable, Codable, Equatable {
    var id: UUID
    var at: DPoint
}

struct SchematicState: Codable {
    var symbols: [PlacedSymbol]
    var wires: [WireItem]
    var junctions: [JunctionItem]
    var labels: [LabelItem]
    var title: String
    /// Placed no-connect flags (part 5.3, S4). Defaulted so every
    /// pre-5.3 construction site keeps compiling unchanged.
    var noConnects: [NoConnectItem] = []
    /// ERC exclusion keys (part 5.3, P7): the `key` of every
    /// ERCFinding the user has excluded, in exclusion order.
    var ercExclusions: [String] = []
    /// Optional user notes per ERC exclusion key (part 5.3, P7).
    var ercExclusionNotes: [String: String] = [:]

    enum CodingKeys: String, CodingKey {
        case symbols, wires, junctions, labels, title
        case noConnects, ercExclusions, ercExclusionNotes
    }
}

extension SchematicState {
    /// Backward-compatible decode (part 5.3): EVERY key is read
    /// with decodeIfPresent and a default, so schematic JSON
    /// written before part 5.3 (no noConnects / ercExclusions
    /// keys — a pre-5.2 file lacks bodyStyle/footprintChoice
    /// inside its symbols too, handled by PlacedSymbol's own
    /// synthesized decode) loads unchanged. This initializer
    /// lives in an EXTENSION so the memberwise initializer is
    /// preserved; encoding stays synthesized.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            symbols: try container.decodeIfPresent([PlacedSymbol].self, forKey: .symbols) ?? [],
            wires: try container.decodeIfPresent([WireItem].self, forKey: .wires) ?? [],
            junctions: try container.decodeIfPresent([JunctionItem].self, forKey: .junctions) ?? [],
            labels: try container.decodeIfPresent([LabelItem].self, forKey: .labels) ?? [],
            title: try container.decodeIfPresent(String.self, forKey: .title) ?? "",
            noConnects: try container.decodeIfPresent([NoConnectItem].self, forKey: .noConnects) ?? [],
            ercExclusions: try container.decodeIfPresent([String].self, forKey: .ercExclusions) ?? [],
            ercExclusionNotes: try container.decodeIfPresent([String: String].self, forKey: .ercExclusionNotes) ?? [:])
    }
}

enum EditorTool: String, CaseIterable {
    case select
    case placeSymbol
    case placePower
    case wire
    case junction
    case label
    case noConnect
    case delete

    var displayName: String {
        switch self {
        case .select: return "Select"
        case .placeSymbol: return "Place Symbol"
        case .placePower: return "Place Power"
        case .wire: return "Wire"
        case .junction: return "Junction"
        case .label: return "Label"
        case .noConnect: return "No Connect"
        case .delete: return "Delete"
        }
    }
}

// MARK: - Part 5.3 model types

/// Annotation options (part 5.3, S7; KiCad's DIALOG_ANNOTATE).
struct AnnotateOptions: Equatable {
    enum SortOrder: Equatable {
        /// The part-5.2 ordering verbatim: top-to-bottom (y
        /// descending), then left-to-right (x ascending).
        case sheetOrder
        /// x ascending primary, y descending secondary.
        case byX
        /// y descending primary, x ascending secondary.
        case byY
    }
    var sortOrder: SortOrder = .sheetOrder
    /// True: renumber EVERY non-power part from `startNumber`
    /// in sort order. False: valid references keep their numbers
    /// and the rest fill first-free from `startNumber`.
    var resetAll: Bool = false
    /// The number annotation starts from (first-free search
    /// starts here in keep mode; numbering starts here in
    /// reset-all mode). Values below 1 behave as 1.
    var startNumber: Int = 1
}

/// One row of the Symbol Fields Table (part 5.3, S6): one row
/// per placed symbol instance. `footprint` is the instance's own
/// footprint choice (PlacedSymbol.footprintChoice), "" when the
/// instance uses the automatic resolution — the document is
/// store-free, so the definition's Footprint property is not
/// readable here.
struct SymbolFieldRow: Identifiable, Equatable {
    var instanceID: UUID
    var id: UUID { instanceID }
    var reference: String
    var unit: Int
    var symbolName: String
    var value: String
    var footprint: String
}

/// One bulk edit for the Symbol Fields Table (part 5.3, S6):
/// the new Value plus the new footprint choice ("" clears the
/// choice back to the automatic resolution).
struct FieldEdit: Equatable {
    var value: String
    var footprint: String
}

/// One Find match (part 5.3, S2). Exactly one of `symbolID` /
/// `labelID` is non-nil. `text` is the full field text that
/// matched; `reference` is the owning symbol's reference for
/// display (for a label match, the label's own text — a label
/// has no reference).
struct SchematicFindMatch: Equatable {
    enum Field: String, Equatable {
        case reference, value, symbolName, footprint, label
    }
    var symbolID: UUID?
    var labelID: UUID?
    var field: Field
    var text: String
    var reference: String
    /// The id of the matched item, whichever kind it is.
    var itemID: UUID? { symbolID ?? labelID }
}

// MARK: - Document

final class SchematicDocument: ObservableObject {
    @Published var state = SchematicState(symbols: [], wires: [], junctions: [], labels: [], title: "Untitled")

    /// Snapshot stacks. Published so toolbar Undo/Redo enabled-state refreshes.
    @Published private(set) var undoStack: [SchematicState] = []
    @Published private(set) var redoStack: [SchematicState] = []

    private let historyCap = 120

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // MARK: History

    /// Records the current state as an undo snapshot. Call BEFORE mutating.
    func pushHistory() {
        undoStack.append(state)
        if undoStack.count > historyCap {
            undoStack.removeFirst(undoStack.count - historyCap)
        }
        redoStack.removeAll()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(state)
        state = previous
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(state)
        if undoStack.count > historyCap {
            undoStack.removeFirst(undoStack.count - historyCap)
        }
        state = next
    }

    /// Replaces the whole state (New / Open) and clears history.
    func replaceState(_ newState: SchematicState) {
        state = newState
        undoStack.removeAll()
        redoStack.removeAll()
    }

    // MARK: Symbols

    func addSymbol(_ s: PlacedSymbol) {
        pushHistory()
        state.symbols.append(s)
    }

    /// Moves a symbol to a new origin. Wire endpoints AND interior vertices that
    /// EXACTLY equal one of `pinPointsBefore` (the symbol's pin world positions
    /// before the move, supplied by the caller which has the symbol definition)
    /// are translated by the same delta, so connected wires follow.
    func moveSymbol(id: UUID, to: DPoint, pinPointsBefore: [DPoint]) {
        guard let idx = state.symbols.firstIndex(where: { $0.id == id }) else { return }
        let old = state.symbols[idx].origin
        let delta = to - old
        if delta == .zero { return }
        pushHistory()
        state.symbols[idx].x = to.x
        state.symbols[idx].y = to.y
        if !pinPointsBefore.isEmpty {
            for wi in state.wires.indices {
                for pi in state.wires[wi].points.indices {
                    if pinPointsBefore.contains(state.wires[wi].points[pi]) {
                        state.wires[wi].points[pi] = state.wires[wi].points[pi] + delta
                    }
                }
            }
        }
    }

    /// Rotates 90° CCW. Wire endpoints are NOT moved (KiCad detaches too).
    func rotateSymbol(id: UUID) {
        guard let idx = state.symbols.firstIndex(where: { $0.id == id }) else { return }
        pushHistory()
        state.symbols[idx].rotation = (state.symbols[idx].rotation + 90) % 360
    }

    /// xAxis == true toggles mirrorX, otherwise toggles mirrorY.
    /// Wire endpoints are NOT moved.
    func mirrorSymbol(id: UUID, xAxis: Bool) {
        guard let idx = state.symbols.firstIndex(where: { $0.id == id }) else { return }
        pushHistory()
        if xAxis {
            state.symbols[idx].mirrorX.toggle()
        } else {
            state.symbols[idx].mirrorY.toggle()
        }
    }

    func deleteSymbol(id: UUID) {
        guard state.symbols.contains(where: { $0.id == id }) else { return }
        pushHistory()
        state.symbols.removeAll { $0.id == id }
    }

    /// Convenience for the properties card: edits any subset of fields as a
    /// single history step.
    func updateSymbol(id: UUID, reference: String? = nil, value: String? = nil, unit: Int? = nil) {
        guard let idx = state.symbols.firstIndex(where: { $0.id == id }) else { return }
        pushHistory()
        if let reference { state.symbols[idx].reference = reference }
        if let value { state.symbols[idx].value = value }
        if let unit { state.symbols[idx].unit = unit }
    }

    /// Applies an arbitrary edit to one placed symbol as ONE
    /// undo step (part 5.2). This is the properties card's write
    /// path: before part 5.2 the card wrote straight into `state`
    /// with NO history entry at all (the recorded part-1 gap —
    /// typing in the card could not be undone). A change that
    /// alters nothing records nothing.
    func editSymbol(id: UUID, _ change: (inout PlacedSymbol) -> Void) {
        guard let idx = state.symbols.firstIndex(where: { $0.id == id })
        else { return }
        var edited = state.symbols[idx]
        change(&edited)
        guard edited != state.symbols[idx] else { return }
        pushHistory()
        state.symbols[idx] = edited
    }

    // MARK: Wires / junctions / labels

    func addWire(_ w: WireItem) {
        guard w.points.count >= 2 else { return }
        pushHistory()
        state.wires.append(w)
    }

    func deleteWire(id: UUID) {
        guard state.wires.contains(where: { $0.id == id }) else { return }
        pushHistory()
        state.wires.removeAll { $0.id == id }
    }

    func addJunction(at: DPoint) {
        // A second junction at the exact same point is meaningless; skip it
        // (and skip the history entry).
        if state.junctions.contains(where: { $0.at == at }) { return }
        pushHistory()
        state.junctions.append(JunctionItem(id: UUID(), at: at))
    }

    func deleteJunction(id: UUID) {
        guard state.junctions.contains(where: { $0.id == id }) else { return }
        pushHistory()
        state.junctions.removeAll { $0.id == id }
    }

    func addLabel(at: DPoint, text: String) {
        pushHistory()
        state.labels.append(LabelItem(id: UUID(), at: at, text: text))
    }

    func deleteLabel(id: UUID) {
        guard state.labels.contains(where: { $0.id == id }) else { return }
        pushHistory()
        state.labels.removeAll { $0.id == id }
    }

    // MARK: References

    /// Returns prefix + (max numeric suffix among existing references with
    /// that prefix + 1), starting at 1. References whose suffix after the
    /// prefix is not entirely digits are ignored.
    func nextReference(prefix: String) -> String {
        var maxN = 0
        for s in state.symbols {
            guard s.reference.hasPrefix(prefix) else { continue }
            let suffix = s.reference.dropFirst(prefix.count)
            guard !suffix.isEmpty, suffix.allSatisfy({ $0.isNumber }), let n = Int(suffix) else { continue }
            if n > maxN { maxN = n }
        }
        return prefix + String(maxN + 1)
    }

    /// The reference prefix: leading characters up to the first
    /// digit or "?" ("R12" → "R", "R?" → "R", "#PWR" → "#PWR").
    static func referencePrefix(of reference: String) -> String {
        var prefix = ""
        for ch in reference {
            if ch.isNumber || ch == "?" { break }
            prefix.append(ch)
        }
        return prefix
    }

    /// A reference is annotated when it carries a numeric suffix
    /// and no "?" ("R12" yes; "R?", "R", "R1?" no).
    static func isAnnotated(_ reference: String) -> Bool {
        guard !reference.contains("?") else { return false }
        let prefix = referencePrefix(of: reference)
        let suffix = reference.dropFirst(prefix.count)
        return !suffix.isEmpty && suffix.allSatisfy { $0.isNumber }
    }

    /// Automatic annotation (part 5.2; KiCad's Annotate
    /// Schematic): every logical part ends with a unique
    /// annotated reference, as ONE undo step. A logical part =
    /// placed instances sharing (library, symbol, reference)
    /// whose units differ (the units of one multi-unit part);
    /// instances are considered in the order `options.sortOrder`
    /// names (sheet order by default — top-to-bottom, then
    /// left-to-right, in y-up document coordinates).
    /// Parts already validly annotated KEEP their numbers —
    /// unless a later part duplicates an earlier part's
    /// reference+unit, in which case the later part is
    /// reassigned. Unannotated and duplicate parts receive the
    /// first free number ≥ `options.startNumber` for their
    /// prefix, in sort order. With `options.resetAll`, NO part
    /// keeps its number: every non-power part is renumbered
    /// from `options.startNumber` in sort order.
    /// Returns how many parts were (re)assigned.
    @discardableResult
    func annotateReferences(options: AnnotateOptions = AnnotateOptions()) -> Int {
        // Sort order (part 5.3, S7). The sheet-order comparator
        // is the part-5.2 code verbatim.
        let ordered: [PlacedSymbol]
        switch options.sortOrder {
        case .sheetOrder:
            ordered = state.symbols.sorted {
                if $0.y != $1.y { return $0.y > $1.y }
                if $0.x != $1.x { return $0.x < $1.x }
                return $0.unit < $1.unit
            }
        case .byX:
            ordered = state.symbols.sorted {
                if $0.x != $1.x { return $0.x < $1.x }
                if $0.y != $1.y { return $0.y > $1.y }
                return $0.unit < $1.unit
            }
        case .byY:
            ordered = state.symbols.sorted {
                if $0.y != $1.y { return $0.y > $1.y }
                if $0.x != $1.x { return $0.x < $1.x }
                return $0.unit < $1.unit
            }
        }
        // Group into logical parts.
        struct Part {
            var key: String          // library \u{1} symbol \u{1} reference
            var reference: String
            var units: Set<Int> = []
            var instanceIDs: [UUID] = []
        }
        var parts: [Part] = []
        // Power symbols are excluded (KiCad annotation does the
        // same): their references are the "#PWR…" kind.
        for symbol in ordered where !symbol.reference.hasPrefix("#") {
            let key = "\(symbol.library)\u{1}\(symbol.symbolName)\u{1}\(symbol.reference)"
            if let idx = parts.firstIndex(where: {
                $0.key == key && !$0.units.contains(symbol.unit)
            }) {
                parts[idx].units.insert(symbol.unit)
                parts[idx].instanceIDs.append(symbol.id)
            } else {
                parts.append(Part(key: key, reference: symbol.reference,
                                  units: [symbol.unit],
                                  instanceIDs: [symbol.id]))
            }
        }
        // Pass 1: keep valid parts, claim their reference+units.
        var claimedUnits: [String: Set<Int>] = [:]   // reference -> units
        var usedNumbers: [String: Set<Int>] = [:]    // prefix -> numbers
        var needsAssignment: [Int] = []               // part indices
        for (index, part) in parts.enumerated() {
            let reference = part.reference
            let claimed = claimedUnits[reference] ?? []
            let duplicates = !claimed.isDisjoint(with: part.units)
            if !options.resetAll && Self.isAnnotated(reference) && !duplicates {
                claimedUnits[reference, default: []].formUnion(part.units)
                let prefix = Self.referencePrefix(of: reference)
                let number = Int(reference.dropFirst(prefix.count)) ?? 0
                usedNumbers[prefix, default: []].insert(number)
            } else {
                needsAssignment.append(index)
            }
        }
        // Pass 2: assign first-free numbers in sort order. The
        // first-free search starts at options.startNumber.
        var assignments: [UUID: String] = [:]
        var changedParts = 0
        for index in needsAssignment {
            let part = parts[index]
            let prefix = Self.referencePrefix(of: part.reference)
            let effectivePrefix = prefix.isEmpty ? "U" : prefix
            var n = max(1, options.startNumber)
            while usedNumbers[effectivePrefix, default: []].contains(n) { n += 1 }
            usedNumbers[effectivePrefix, default: []].insert(n)
            let newReference = effectivePrefix + String(n)
            claimedUnits[newReference, default: []].formUnion(part.units)
            // A (re)assignment that lands on the part's current
            // reference changes nothing and is not counted —
            // this is what makes a reset-all run over an already
            // sequential sheet a no-op with no history step.
            guard newReference != part.reference else { continue }
            changedParts += 1
            for id in part.instanceIDs { assignments[id] = newReference }
        }
        guard !assignments.isEmpty else { return 0 }
        pushHistory()
        for idx in state.symbols.indices {
            if let newReference = assignments[state.symbols[idx].id] {
                state.symbols[idx].reference = newReference
            }
        }
        return changedParts
    }

    // MARK: Lookup (part 5.3, S8 support)

    /// The first placed symbol (document order) carrying
    /// `reference`, or nil. Cross-probing (S8) resolves its
    /// targets through this. A multi-unit part returns its
    /// first-placed instance.
    func placedSymbol(reference: String) -> PlacedSymbol? {
        state.symbols.first { $0.reference == reference }
    }

    // MARK: ERC exclusions (part 5.3, P7 schematic side)

    /// Exclusions are checker SETTINGS in KiCad (they persist
    /// with the file but are not undoable document edits), so
    /// these mutate state directly without a history step;
    /// persistence rides the normal save, which writes the
    /// whole state.
    func excludeERC(key: String, note: String? = nil) {
        if !state.ercExclusions.contains(key) {
            state.ercExclusions.append(key)
        }
        if let note {
            state.ercExclusionNotes[key] = note
        }
    }

    /// Remove an exclusion (the finding counts again).
    func restoreERC(key: String) {
        state.ercExclusions.removeAll { $0 == key }
        state.ercExclusionNotes[key] = nil
    }

    // MARK: Change / update symbol (part 5.3, S5)

    /// Swaps the placed symbol's definition in place (KiCad's
    /// Change Symbol): the instance keeps its reference, value,
    /// footprint choice, position, rotation and mirroring; only
    /// the library/name key changes. The unit is kept when the
    /// new definition has that unit, else reset to 1; the body
    /// style resets to standard when the new definition has no
    /// style-2 body. `definition` is the new definition as
    /// resolved by the caller (the editor resolves it through
    /// LibraryStore — the document stays store-free, the same
    /// pattern as the fixture resolvers); pass nil when it could
    /// not be resolved, in which case only the key is swapped
    /// and unit/body style are kept unvalidated. ONE history
    /// step; a swap that changes nothing records none. Returns
    /// whether anything changed.
    @discardableResult
    func changeSymbol(id: UUID, toLibrary library: String, name: String,
                      definition: KiCadSymbolDef?) -> Bool {
        guard let idx = state.symbols.firstIndex(where: { $0.id == id })
        else { return false }
        var edited = state.symbols[idx]
        edited.library = library
        edited.symbolName = name
        if let definition {
            let unitIsValid = definition.units[edited.unit] != nil
                || (edited.unit >= 1 && edited.unit <= definition.unitCount)
            if !unitIsValid { edited.unit = 1 }
            if edited.effectiveBodyStyle == 2 && !definition.hasAlternateBody {
                edited.bodyStyle = nil
            }
        }
        guard edited != state.symbols[idx] else { return false }
        pushHistory()
        state.symbols[idx] = edited
        return true
    }

    /// Refreshes a placed symbol from its library definition
    /// (KiCad's Update Symbol): value and footprint choice reset
    /// to the definition's defaults — the Value property (the
    /// symbol name when the definition carries no usable Value)
    /// and no per-instance footprint choice (the automatic
    /// resolution then applies). Reference, position, rotation,
    /// mirroring and unit are preserved. ONE history step; a
    /// refresh that changes nothing records none. Returns
    /// whether anything changed.
    @discardableResult
    func updateSymbolFromLibrary(id: UUID, definition: KiCadSymbolDef) -> Bool {
        guard let idx = state.symbols.firstIndex(where: { $0.id == id })
        else { return false }
        var edited = state.symbols[idx]
        let rawValue = definition.property("Value")?
            .trimmingCharacters(in: .whitespaces)
        edited.value = (rawValue != nil && rawValue != "" && rawValue != "~")
            ? rawValue! : edited.symbolName
        edited.footprintChoice = nil
        guard edited != state.symbols[idx] else { return false }
        pushHistory()
        state.symbols[idx] = edited
        return true
    }

    // MARK: Symbol fields table (part 5.3, S6)

    /// One row per placed symbol instance, sorted by reference
    /// then unit (symbol name then id break remaining ties, so
    /// the order is deterministic).
    func fieldRows() -> [SymbolFieldRow] {
        state.symbols.map {
            SymbolFieldRow(instanceID: $0.id, reference: $0.reference,
                           unit: $0.unit, symbolName: $0.symbolName,
                           value: $0.value,
                           footprint: $0.footprintChoice ?? "")
        }.sorted {
            ($0.reference, $0.unit, $0.symbolName, $0.instanceID.uuidString)
                < ($1.reference, $1.unit, $1.symbolName, $1.instanceID.uuidString)
        }
    }

    /// Applies fields-table edits as ONE history step (iff
    /// anything actually changed): each entry sets the
    /// instance's value and footprint choice (an empty footprint
    /// string clears the choice). Unknown ids are ignored.
    /// Returns how many instances changed.
    @discardableResult
    func applyFieldEdits(_ edits: [UUID: FieldEdit]) -> Int {
        var changedIndices: [Int] = []
        var newValues: [Int: (value: String, choice: String?)] = [:]
        for (id, edit) in edits {
            guard let idx = state.symbols.firstIndex(where: { $0.id == id })
            else { continue }
            let trimmedFootprint = edit.footprint
                .trimmingCharacters(in: .whitespaces)
            let newChoice = trimmedFootprint.isEmpty ? nil : trimmedFootprint
            if state.symbols[idx].value != edit.value
                || state.symbols[idx].footprintChoice != newChoice {
                changedIndices.append(idx)
                newValues[idx] = (edit.value, newChoice)
            }
        }
        guard !changedIndices.isEmpty else { return 0 }
        pushHistory()
        for idx in changedIndices {
            if let edit = newValues[idx] {
                state.symbols[idx].value = edit.value
                state.symbols[idx].footprintChoice = edit.choice
            }
        }
        return changedIndices.count
    }

    // MARK: Find (part 5.3, S2)

    /// Case-insensitive substring search over the sheet: symbol
    /// references, values, symbol names and footprint choices,
    /// plus label text. The document is store-free, so the
    /// footprint field searched is the instance's own footprint
    /// choice (the definition's Footprint property lives in the
    /// library and is not readable here). One match per matching
    /// FIELD, in deterministic order: symbols in document order
    /// (fields in reference / value / symbolName / footprint
    /// order within one symbol), then labels in document order.
    /// An empty (or all-whitespace) query matches nothing.
    func findMatches(query: String) -> [SchematicFindMatch] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !needle.isEmpty else { return [] }
        func hit(_ text: String) -> Bool {
            text.lowercased().contains(needle)
        }
        var matches: [SchematicFindMatch] = []
        for symbol in state.symbols {
            if hit(symbol.reference) {
                matches.append(SchematicFindMatch(
                    symbolID: symbol.id, labelID: nil, field: .reference,
                    text: symbol.reference, reference: symbol.reference))
            }
            if hit(symbol.value) {
                matches.append(SchematicFindMatch(
                    symbolID: symbol.id, labelID: nil, field: .value,
                    text: symbol.value, reference: symbol.reference))
            }
            if hit(symbol.symbolName) {
                matches.append(SchematicFindMatch(
                    symbolID: symbol.id, labelID: nil, field: .symbolName,
                    text: symbol.symbolName, reference: symbol.reference))
            }
            if let choice = symbol.footprintChoice, hit(choice) {
                matches.append(SchematicFindMatch(
                    symbolID: symbol.id, labelID: nil, field: .footprint,
                    text: choice, reference: symbol.reference))
            }
        }
        for label in state.labels where hit(label.text) {
            matches.append(SchematicFindMatch(
                symbolID: nil, labelID: label.id, field: .label,
                text: label.text, reference: label.text))
        }
        return matches
    }

    // MARK: No-connect flags (part 5.3, S4)

    /// Places a no-connect flag. A second flag at the exact same
    /// point is meaningless; it is skipped (and records no
    /// history), mirroring addJunction.
    func addNoConnect(at: DPoint) {
        if state.noConnects.contains(where: { $0.at == at }) { return }
        pushHistory()
        state.noConnects.append(NoConnectItem(id: UUID(), at: at))
    }

    func removeNoConnect(id: UUID) {
        guard state.noConnects.contains(where: { $0.id == id }) else { return }
        pushHistory()
        state.noConnects.removeAll { $0.id == id }
    }

    // MARK: Wires — set deletion (part 5.3, S11 support)

    /// Removes exactly the wires in `ids` as ONE history step
    /// (the Delete half of Select Connection). Unknown ids are
    /// ignored; when nothing matches, no history is recorded.
    /// Returns how many wires were removed.
    @discardableResult
    func deleteWires(_ ids: Set<UUID>) -> Int {
        let removed = state.wires.filter { ids.contains($0.id) }.count
        guard removed > 0 else { return 0 }
        pushHistory()
        state.wires.removeAll { ids.contains($0.id) }
        return removed
    }

    // MARK: Clean up sheet (part 5.3, S3)

    /// KiCad's SCHEMATIC::CleanUp as an explicit action, plus
    /// PadCB's stated delta (isolated-wire removal). ONE history
    /// step when anything changes, none when the sheet is
    /// already clean. Rules, in order:
    /// - zero-length wires removed ("nullWires"): a wire whose
    ///   points collapse to fewer than 2 distinct consecutive
    ///   points. (Consecutive duplicate points of surviving
    ///   wires are stripped as part of the same pass.)
    /// - exact-duplicate wires removed ("duplicateWires"):
    ///   identical ordered point lists; the first copy stays.
    ///   Checked again after merging.
    /// - collinear touching wire segments merged
    ///   ("mergedWires"): each merge counts once — removing a
    ///   collinear interior point of one wire, or joining two
    ///   wires whose endpoint segments continue each other in a
    ///   straight line (the joined wire keeps the first wire's
    ///   id and loses the joint point). Iterated to a fixpoint.
    /// - junctions at the same point deduped
    ///   ("duplicateJunctions", exact point equality).
    /// - no-connect flags at the same point deduped (no count
    ///   key of its own — the flags still dedupe).
    /// - PADCB DELTA: wires touching nothing at either end
    ///   removed ("isolatedWires"), iterated — a wire touches
    ///   when an endpoint, or any point along it, meets another
    ///   wire, a junction, a label or a pin in `pinPoints`.
    ///   `pinPoints` is every pin world point of the document,
    ///   passed by the editor (computed via SymbolDrawList
    ///   like the save flow); the document itself stays
    ///   store-free. The default `[]` preserves the pure
    ///   wire/junction/label test.
    /// - junctions left with fewer than 2 connections dropped
    ///   ("droppedJunctions"): a junction's connections are the
    ///   wire items touching its point after all wire cleanup.
    /// All point coincidence here is exact (the canvas snaps to
    /// exact points throughout the document). Returns the
    /// per-rule counts; all six keys are always present.
    @discardableResult
    func cleanUpSheet(pinPoints: [DPoint] = []) -> [String: Int] {
        var counts: [String: Int] = [
            "nullWires": 0, "duplicateWires": 0, "mergedWires": 0,
            "duplicateJunctions": 0, "droppedJunctions": 0,
            "isolatedWires": 0,
        ]
        func bump(_ key: String) { counts[key, default: 0] += 1 }

        var didChange = false
        var wires: [WireItem] = []

        // Zero-length wires (with consecutive-duplicate strip).
        for wire in state.wires {
            var points: [DPoint] = []
            for point in wire.points where points.last != point {
                points.append(point)
            }
            if points.count < 2 {
                bump("nullWires")
                didChange = true
            } else {
                if points != wire.points { didChange = true }
                wires.append(WireItem(id: wire.id, points: points))
            }
        }

        // Exact-duplicate wires.
        func dropDuplicates(_ list: [WireItem]) -> [WireItem] {
            var seen = Set<[DPoint]>()
            var kept: [WireItem] = []
            for wire in list {
                if seen.insert(wire.points).inserted {
                    kept.append(wire)
                } else {
                    bump("duplicateWires")
                    didChange = true
                }
            }
            return kept
        }
        wires = dropDuplicates(wires)

        // Collinear merges, to a fixpoint.
        func onSegment(_ p: DPoint, _ a: DPoint, _ b: DPoint) -> Bool {
            ConnectionTableBuilder.distanceFromPointToSegment(p, a, b) <= 1e-9
        }
        func continuesStraight(_ d1: DPoint, _ d2: DPoint) -> Bool {
            // Collinear (cross ~ 0) and continuing (dot > 0: a
            // reversal would double back over the first segment,
            // which is an overlap, not a merge).
            let cross = d1.x * d2.y - d1.y * d2.x
            let dot = d1.x * d2.x + d1.y * d2.y
            return abs(cross) <= 1e-9 && dot > 0
        }
        var merging = true
        while merging {
            merging = false
            // Interior collinear points of a single wire.
            for wi in wires.indices where wires[wi].points.count > 2 {
                var points = wires[wi].points
                var i = 1
                var removedHere = false
                while i < points.count - 1 {
                    if onSegment(points[i], points[i - 1], points[i + 1]) {
                        points.remove(at: i)
                        bump("mergedWires")
                        didChange = true
                        removedHere = true
                    } else {
                        i += 1
                    }
                }
                if removedHere {
                    wires[wi] = WireItem(id: wires[wi].id, points: points)
                    merging = true
                }
            }
            // Two wires end-to-end in a straight line.
            pairLoop: for i in wires.indices {
                for j in wires.indices where j > i {
                    let a = wires[i].points, b = wires[j].points
                    // (left points, right points) oriented so the
                    // left's last point is the right's first.
                    let oriented: (left: [DPoint], right: [DPoint])?
                    if a.last == b.first {
                        oriented = (a, b)
                    } else if b.last == a.first {
                        oriented = (b, a)
                    } else if a.last == b.last {
                        oriented = (a, Array(b.reversed()))
                    } else if a.first == b.first {
                        oriented = (Array(a.reversed()), b)
                    } else {
                        oriented = nil
                    }
                    guard let (left, right) = oriented,
                          left.count >= 2, right.count >= 2 else { continue }
                    let d1 = left[left.count - 1] - left[left.count - 2]
                    let d2 = right[1] - right[0]
                    guard continuesStraight(d1, d2) else { continue }
                    // The joint point itself drops out: the two
                    // segments become one straight segment.
                    let joined = Array(left.dropLast()) + right
                    guard joined.count >= 2 else { continue }
                    wires[i] = WireItem(id: wires[i].id, points: joined)
                    wires.remove(at: j)
                    bump("mergedWires")
                    didChange = true
                    merging = true
                    break pairLoop
                }
            }
        }
        wires = dropDuplicates(wires)

        // Junction + no-connect dedupe (exact point equality).
        var junctions: [JunctionItem] = []
        var seenJunctionPoints = Set<DPoint>()
        for junction in state.junctions {
            if seenJunctionPoints.insert(junction.at).inserted {
                junctions.append(junction)
            } else {
                bump("duplicateJunctions")
                didChange = true
            }
        }
        var noConnects: [NoConnectItem] = []
        var seenNoConnectPoints = Set<DPoint>()
        for item in state.noConnects {
            if seenNoConnectPoints.insert(item.at).inserted {
                noConnects.append(item)
            } else {
                didChange = true
            }
        }

        // Isolated wires (PadCB delta), iterated: removing one
        // wire can isolate the wire that only touched it.
        func wireTouches(_ wire: WireItem, _ point: DPoint) -> Bool {
            if wire.points.contains(point) { return true }
            guard wire.points.count >= 2 else { return false }
            for i in 0..<(wire.points.count - 1)
            where onSegment(point, wire.points[i], wire.points[i + 1]) {
                return true
            }
            return false
        }
        func isIsolated(_ wire: WireItem) -> Bool {
            let others = wires.filter { $0.id != wire.id }
            for endpoint in [wire.points.first, wire.points.last] {
                guard let endpoint else { continue }
                if others.contains(where: { wireTouches($0, endpoint) }) {
                    return false
                }
                if junctions.contains(where: { $0.at == endpoint }) {
                    return false
                }
            }
            for other in others {
                for point in other.points where wireTouches(wire, point) {
                    return false
                }
            }
            if junctions.contains(where: { wireTouches(wire, $0.at) }) {
                return false
            }
            if state.labels.contains(where: { wireTouches(wire, $0.at) }) {
                return false
            }
            if pinPoints.contains(where: { wireTouches(wire, $0) }) {
                return false
            }
            return true
        }
        while let index = wires.firstIndex(where: isIsolated) {
            wires.remove(at: index)
            bump("isolatedWires")
            didChange = true
        }

        // Junctions left with fewer than 2 connections.
        var keptJunctions: [JunctionItem] = []
        for junction in junctions {
            let connections = wires.filter { wireTouches($0, junction.at) }.count
            if connections < 2 {
                bump("droppedJunctions")
                didChange = true
            } else {
                keptJunctions.append(junction)
            }
        }

        guard didChange else { return counts }
        pushHistory()
        state.wires = wires
        state.junctions = keptJunctions
        state.noConnects = noConnects
        return counts
    }

    // MARK: Align to grid (part 5.3, S12)

    /// Snaps a symbol's origin to the nearest `grid` multiple
    /// (KiCad's AlignToGrid): wire points and junction points
    /// coinciding (within 0.001 mm) with one of `pinPoints` —
    /// the symbol's pin world points BEFORE the move, computed
    /// by the caller through SymbolDrawList from the resolved
    /// definition (the document stays store-free) — translate
    /// by the same delta, so connections survive. ONE history
    /// step. Returns false (and records nothing) when the
    /// symbol is missing, the grid is not positive, or the
    /// symbol already sits on the grid.
    @discardableResult
    func alignSymbolToGrid(id: UUID, pinPoints: [DPoint],
                           grid: Double = 1.27) -> Bool {
        guard grid > 0,
              let idx = state.symbols.firstIndex(where: { $0.id == id })
        else { return false }
        let old = state.symbols[idx].origin
        let snapped = DPoint(x: (old.x / grid).rounded() * grid,
                             y: (old.y / grid).rounded() * grid)
        let delta = snapped - old
        if abs(delta.x) <= 1e-9 && abs(delta.y) <= 1e-9 { return false }
        func coincides(_ point: DPoint) -> Bool {
            pinPoints.contains { $0.distance(to: point) <= 0.001 }
        }
        pushHistory()
        state.symbols[idx].x = snapped.x
        state.symbols[idx].y = snapped.y
        for wi in state.wires.indices {
            for pi in state.wires[wi].points.indices
            where coincides(state.wires[wi].points[pi]) {
                state.wires[wi].points[pi] = state.wires[wi].points[pi] + delta
            }
        }
        for ji in state.junctions.indices
        where coincides(state.junctions[ji].at) {
            state.junctions[ji].at = state.junctions[ji].at + delta
        }
        return true
    }

    // MARK: Persistence (JSON of SchematicState)

    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: url, options: [.atomic])
    }

    func load(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(SchematicState.self, from: data)
        replaceState(decoded)
    }
}
