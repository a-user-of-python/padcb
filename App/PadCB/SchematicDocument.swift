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

struct SchematicState: Codable {
    var symbols: [PlacedSymbol]
    var wires: [WireItem]
    var junctions: [JunctionItem]
    var labels: [LabelItem]
    var title: String
}

enum EditorTool: String, CaseIterable {
    case select
    case placeSymbol
    case placePower
    case wire
    case junction
    case label
    case delete

    var displayName: String {
        switch self {
        case .select: return "Select"
        case .placeSymbol: return "Place Symbol"
        case .placePower: return "Place Power"
        case .wire: return "Wire"
        case .junction: return "Junction"
        case .label: return "Label"
        case .delete: return "Delete"
        }
    }
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
    /// instances are considered in sheet order (top-to-bottom,
    /// then left-to-right, in y-up document coordinates).
    /// Parts already validly annotated KEEP their numbers —
    /// unless a later part duplicates an earlier part's
    /// reference+unit, in which case the later part is
    /// reassigned. Unannotated and duplicate parts receive the
    /// first free number ≥ 1 for their prefix, in sheet order.
    /// Returns how many parts were (re)assigned.
    @discardableResult
    func annotateReferences() -> Int {
        // Sheet order.
        let ordered = state.symbols.sorted {
            if $0.y != $1.y { return $0.y > $1.y }
            if $0.x != $1.x { return $0.x < $1.x }
            return $0.unit < $1.unit
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
            if Self.isAnnotated(reference) && !duplicates {
                claimedUnits[reference, default: []].formUnion(part.units)
                let prefix = Self.referencePrefix(of: reference)
                let number = Int(reference.dropFirst(prefix.count)) ?? 0
                usedNumbers[prefix, default: []].insert(number)
            } else {
                needsAssignment.append(index)
            }
        }
        // Pass 2: assign first-free numbers in sheet order.
        var assignments: [UUID: String] = [:]
        for index in needsAssignment {
            let part = parts[index]
            let prefix = Self.referencePrefix(of: part.reference)
            let effectivePrefix = prefix.isEmpty ? "U" : prefix
            var n = 1
            while usedNumbers[effectivePrefix, default: []].contains(n) { n += 1 }
            usedNumbers[effectivePrefix, default: []].insert(n)
            let newReference = effectivePrefix + String(n)
            claimedUnits[newReference, default: []].formUnion(part.units)
            for id in part.instanceIDs { assignments[id] = newReference }
        }
        guard !assignments.isEmpty else { return 0 }
        pushHistory()
        for idx in state.symbols.indices {
            if let newReference = assignments[state.symbols[idx].id] {
                state.symbols[idx].reference = newReference
            }
        }
        return needsAssignment.count
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
