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

struct PlacedSymbol: Identifiable, Codable {
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
