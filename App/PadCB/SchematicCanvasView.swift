import SwiftUI
import UIKit

// MARK: - Canvas view state (owned by the editor, driven by toolbar buttons)

final class CanvasViewState: ObservableObject {
    /// Points per millimetre.
    @Published var scale: CGFloat = 4
    /// Screen-space offset of the world origin.
    @Published var offset: CGPoint = .zero
    /// Current pointer position in world coords (mm, y-up), nil when unknown.
    @Published var cursorWorld: DPoint?

    static let minScale: CGFloat = 0.5
    static let maxScale: CGFloat = 40

    func zoomIn() { scale = min(scale * 1.3, Self.maxScale) }
    func zoomOut() { scale = max(scale / 1.3, Self.minScale) }

    /// Centres the view on a world point (part 5.3, S2/S8),
    /// keeping the current zoom unless `scale` names a new one.
    /// Mirrors fit's offset math: screen = (offset.x + x*scale,
    /// offset.y - y*scale), so the point lands at the canvas
    /// centre when offset = centre -/+ point * scale. No-op
    /// until the canvas has registered its size.
    func centre(on point: DPoint, scale newScale: CGFloat? = nil) {
        guard canvasSize.width > 10, canvasSize.height > 10 else { return }
        if let newScale {
            scale = min(max(newScale, Self.minScale), Self.maxScale)
        }
        offset = CGPoint(x: canvasSize.width / 2 - CGFloat(point.x) * scale,
                         y: canvasSize.height / 2 + CGFloat(point.y) * scale)
    }

    /// Frames an arbitrary world-space rect (part 5.3, P17 —
    /// Zoom to Selection), mirroring fit's math: 8 mm of padding
    /// around the rect, a 32 pt screen margin, the scale clamped
    /// to the usual range, and the rect's centre at the canvas
    /// centre.
    func frame(rect: CGRect, size: CGSize) {
        guard size.width > 10, size.height > 10 else { return }
        let pad = 8.0
        let minX = Double(rect.minX) - pad, maxX = Double(rect.maxX) + pad
        let minY = Double(rect.minY) - pad, maxY = Double(rect.maxY) + pad
        let w = max(maxX - minX, 1), h = max(maxY - minY, 1)
        let sx = (size.width - 32) / CGFloat(w)
        let sy = (size.height - 32) / CGFloat(h)
        let newScale = min(max(min(sx, sy), Self.minScale), Self.maxScale)
        let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
        scale = newScale
        offset = CGPoint(x: size.width / 2 - CGFloat(cx) * newScale,
                         y: size.height / 2 + CGFloat(cy) * newScale)
    }

    /// Registered by SchematicCanvasView so the editor's toolbar Fit button
    /// can call `fit(_:)` without owning a store reference or canvas size.
    var store: LibraryStore?
    var canvasSize: CGSize = .zero

    /// Toolbar-facing fit: uses the store and canvas size the canvas view
    /// registered. No-op until the canvas has appeared.
    func fit(_ document: SchematicDocument) {
        guard let store, canvasSize.width > 10, canvasSize.height > 10 else { return }
        fit(state: document.state, store: store, size: canvasSize)
    }

    /// Fits the whole document into `size`. Approximate: union of placed
    /// symbol body bounds, wire points, junctions and labels. Empty document
    /// resets to the default view centred on the origin.
    func fit(state: SchematicState, store: LibraryStore, size: CGSize) {
        guard size.width > 10, size.height > 10 else { return }
        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude
        var found = false
        func include(_ p: DPoint) {
            found = true
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        for s in state.symbols {
            if let def = store.symbol(library: s.library, name: s.symbolName) {
                let b = SymbolRenderer.placedBounds(def: def, placed: s)
                include(DPoint(x: Double(b.minX), y: Double(b.minY)))
                include(DPoint(x: Double(b.maxX), y: Double(b.maxY)))
            } else {
                include(s.origin)
            }
        }
        for w in state.wires { for p in w.points { include(p) } }
        for j in state.junctions { include(j.at) }
        for l in state.labels { include(l.at) }

        guard found else {
            scale = 4
            offset = CGPoint(x: size.width / 2, y: size.height / 2)
            return
        }
        let pad = 8.0
        minX -= pad; maxX += pad; minY -= pad; maxY += pad
        let w = max(maxX - minX, 1), h = max(maxY - minY, 1)
        let sx = (size.width - 32) / CGFloat(w)
        let sy = (size.height - 32) / CGFloat(h)
        let newScale = min(max(min(sx, sy), Self.minScale), Self.maxScale)
        let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
        scale = newScale
        offset = CGPoint(x: size.width / 2 - CGFloat(cx) * newScale,
                         y: size.height / 2 + CGFloat(cy) * newScale)
    }
}

// MARK: - Canvas view

struct SchematicCanvasView: View {
    @ObservedObject var document: SchematicDocument
    @ObservedObject var store: LibraryStore
    @ObservedObject var canvasState: CanvasViewState = CanvasViewState()
    @Binding var tool: EditorTool
    @Binding var selection: UUID?
    var pendingSymbol: KiCadSymbolDef?
    var onRequestSymbolChooser: (Bool) -> Void = { _ in }
    var onConsumePlacementDone: () -> Void = {}

    // Part 5.3 (S1/S10/S11): net highlight + connection selection.
    // All DEFAULTED — the external-display mirror constructs this
    // view with none of them and keeps compiling/rendering plainly.
    /// Wire items belonging to the highlighted net (full strength,
    /// accent colour while a highlight is active).
    var highlightedWireIDs: Set<UUID> = []
    /// Symbol instances on the highlighted net (full strength;
    /// every other symbol draws dimmed while a highlight is active).
    var highlightedSymbolIDs: Set<UUID> = []
    /// True while a net highlight is active (even in the edge case
    /// where the net's member sets are both empty).
    var isHighlightActive: Bool = false
    /// Wire items in the Select Connection selection (S11), drawn
    /// in the selection colour; Delete removes exactly these.
    var connectionSelectedWireIDs: Set<UUID> = []
    /// One-shot modes armed by the editor's top/right bars. While
    /// either is armed, the next Select-tool tap on a wire (or, for
    /// highlight, a symbol pin) is consumed by the mode instead of
    /// changing the symbol selection; the canvas disarms on a hit.
    var highlightArmed: Binding<Bool> = .constant(false)
    var selectConnectionArmed: Binding<Bool> = .constant(false)
    /// A highlighted-mode tap hit this wire item.
    var onHighlightWire: (UUID) -> Void = { _ in }
    /// A highlighted-mode tap hit this symbol instance's pin.
    var onHighlightPin: (UUID, String) -> Void = { _, _ in }
    /// A Select Connection tap hit this wire item.
    var onSelectConnectionWire: (UUID) -> Void = { _ in }
    /// Esc with a highlight active / Delete-or-Esc with a
    /// connection selection: the editor owns that state, the
    /// canvas just forwards the key intent.
    var onClearHighlight: () -> Void = {}
    var onClearConnectionSelection: () -> Void = {}
    var onDeleteConnectionSelection: () -> Void = {}

    // Drag bookkeeping
    private enum DragKind { case none, pan, moveSymbol, track }
    @State private var dragKind: DragKind = .none
    @State private var dragStartOffset: CGPoint = .zero
    @State private var dragSymbolID: UUID?
    @State private var dragStartOrigin: DPoint = .zero
    @State private var dragPinPoints: [DPoint] = []
    @State private var dragOrigin: DPoint? // live snapped origin while moving a symbol

    // Two-finger session (pinch zoom + two-finger pan, UIKit bridge):
    // scale at session start and the world point that was under the touch
    // centroid at session start. The centroid anchor invariant is that this
    // world point stays under the (moving) centroid for the whole session.
    @State private var twoFingerStartScale: CGFloat?
    @State private var twoFingerAnchorWorld: DPoint?

    // Wire drag (Wire tool, one finger, movement >= 5 pt): the snapped start
    // point captured when the drag began, and whether the drag has crossed
    // the movement threshold and is building a wire.
    @State private var wireDragStart: DPoint?
    @State private var wireDragActive = false

    // Wire-in-progress
    @State private var wirePoints: [DPoint] = []
    @State private var wirePointer: DPoint?
    @State private var lastWireTap: (point: DPoint, time: Date)?

    // Placement ghost transform
    @State private var ghostRotation: Int = 0
    @State private var ghostMirrorX = false
    @State private var ghostMirrorY = false

    // Label prompt
    @State private var labelPoint: DPoint?
    @State private var labelText: String = ""
    @State private var showingLabelAlert = false

    @FocusState private var focused: Bool

    private static let grid: Double = 1.27 // KiCad pin grid, mm

    // MARK: Coordinate mapping
    // screen = (offset.x + world.x * scale, offset.y - world.y * scale)

    private func screen(_ w: DPoint) -> CGPoint {
        CGPoint(x: canvasState.offset.x + CGFloat(w.x) * canvasState.scale,
                y: canvasState.offset.y - CGFloat(w.y) * canvasState.scale)
    }

    private func world(_ s: CGPoint) -> DPoint {
        DPoint(x: Double((s.x - canvasState.offset.x) / canvasState.scale),
               y: Double((canvasState.offset.y - s.y) / canvasState.scale))
    }

    private func snap(_ p: DPoint) -> DPoint {
        DPoint(x: (p.x / Self.grid).rounded() * Self.grid,
               y: (p.y / Self.grid).rounded() * Self.grid)
    }

    private var scaleD: Double { Double(canvasState.scale) }

    // MARK: Def / hit-test helpers

    private var defsByID: [UUID: KiCadSymbolDef] {
        var d: [UUID: KiCadSymbolDef] = [:]
        for s in document.state.symbols {
            if let def = store.symbol(library: s.library, name: s.symbolName) {
                d[s.id] = def
            }
        }
        return d
    }

    private func def(for s: PlacedSymbol) -> KiCadSymbolDef? {
        store.symbol(library: s.library, name: s.symbolName)
    }

    private func pinPoints(of s: PlacedSymbol) -> [DPoint] {
        guard let d = def(for: s) else { return [] }
        return SymbolRenderer.pinWorldPoints(def: d, placed: s).map { $0.point }
    }

    private var selectedSymbol: PlacedSymbol? {
        guard let selection else { return nil }
        return document.state.symbols.first { $0.id == selection }
    }

    /// Topmost symbol whose body bounds contain the world point (later in the
    /// array = drawn on top). Falls back to a 10x10mm box when the def is
    /// unavailable.
    private func symbolAt(_ w: DPoint, defs: [UUID: KiCadSymbolDef]) -> PlacedSymbol? {
        for s in document.state.symbols.reversed() {
            if let d = defs[s.id] {
                let b = SymbolRenderer.placedBounds(def: d, placed: effectivePlaced(s))
                if w.x >= Double(b.minX) - 0.5 && w.x <= Double(b.maxX) + 0.5 &&
                   w.y >= Double(b.minY) - 0.5 && w.y <= Double(b.maxY) + 0.5 {
                    return s
                }
            } else if abs(w.x - s.x) <= 5 && abs(w.y - s.y) <= 5 {
                return s
            }
        }
        return nil
    }

    /// The placed symbol as it should be drawn right now (drag preview).
    private func effectivePlaced(_ s: PlacedSymbol) -> PlacedSymbol {
        if dragKind == .moveSymbol, s.id == dragSymbolID, let o = dragOrigin {
            var copy = s
            copy.x = o.x
            copy.y = o.y
            return copy
        }
        return s
    }

    private func nearestPin(to w: DPoint, defs: [UUID: KiCadSymbolDef]) -> (point: DPoint, distance: Double)? {
        var best: (point: DPoint, distance: Double)?
        for s in document.state.symbols {
            guard let d = defs[s.id] else { continue }
            for entry in SymbolRenderer.pinWorldPoints(def: d, placed: s) {
                let dist = w.distance(to: entry.point)
                if best == nil || dist < best!.distance {
                    best = (entry.point, dist)
                }
            }
        }
        let threshold = max(0.9, 7.0 / scaleD)
        if let best, best.distance <= threshold { return best }
        return nil
    }

    /// The nearest pin with its owning instance + pin number
    /// (part 5.3, S1: a pin tap resolves its net through the
    /// connection table's endpoints). Same threshold as
    /// `nearestPin(to:defs:)`.
    private func nearestPinInfo(to w: DPoint, defs: [UUID: KiCadSymbolDef])
        -> (instanceID: UUID, pinNumber: String, point: DPoint, distance: Double)? {
        var best: (instanceID: UUID, pinNumber: String, point: DPoint, distance: Double)?
        for s in document.state.symbols {
            guard let d = defs[s.id] else { continue }
            for entry in SymbolRenderer.pinWorldPoints(def: d, placed: s) {
                let dist = w.distance(to: entry.point)
                if best == nil || dist < best!.distance {
                    best = (s.id, entry.pin.number, entry.point, dist)
                }
            }
        }
        let threshold = max(0.9, 7.0 / scaleD)
        if let best, best.distance <= threshold { return best }
        return nil
    }

    /// The first wire item whose segments pass within tap
    /// tolerance of the world point — the same hit test the
    /// Delete tool uses (part 5.3, S1/S11 tap resolution).
    private func wireAt(_ w: DPoint) -> WireItem? {
        let tol = max(0.9, 6.0 / scaleD)
        for wire in document.state.wires {
            for i in 0..<(wire.points.count - 1) {
                if Self.pointSegmentDistance(w, wire.points[i], wire.points[i + 1]).distance <= tol {
                    return wire
                }
            }
        }
        return nil
    }

    private static func pointSegmentDistance(_ p: DPoint, _ a: DPoint, _ b: DPoint) -> (distance: Double, projected: DPoint) {
        let abx = b.x - a.x, aby = b.y - a.y
        let lenSq = abx * abx + aby * aby
        if lenSq == 0 { return (p.distance(to: a), a) }
        var t = ((p.x - a.x) * abx + (p.y - a.y) * aby) / lenSq
        t = min(max(t, 0), 1)
        let proj = DPoint(x: a.x + t * abx, y: a.y + t * aby)
        return (p.distance(to: proj), proj)
    }

    // MARK: Body

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                drawScene(ctx: ctx, size: size, defs: defsByID)
            }
            .background(Color.white)
            .contentShape(Rectangle())
            .overlay(CanvasGestureOverlay(handlers: gestureHandlers))
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    canvasState.cursorWorld = world(location)
                case .ended:
                    canvasState.cursorWorld = nil
                }
            }
            .focusable()
            .focused($focused)
            .onKeyPress(.escape) { handleEscape(); return .handled }
            .onKeyPress(.delete) { deleteSelection(); return .handled }
            .onKeyPress(characters: CharacterSet(charactersIn: "rxyRXY")) { press in
                handleLetterKey(press.characters.lowercased())
                return .handled
            }
            .onKeyPress(.upArrow) { nudge(dx: 0, dy: Self.grid); return .handled }
            .onKeyPress(.downArrow) { nudge(dx: 0, dy: -Self.grid); return .handled }
            .onKeyPress(.leftArrow) { nudge(dx: -Self.grid, dy: 0); return .handled }
            .onKeyPress(.rightArrow) { nudge(dx: Self.grid, dy: 0); return .handled }
            .onAppear {
                focused = true
                canvasState.store = store
                canvasState.canvasSize = geo.size
            }
            .onChange(of: geo.size) { _, newSize in
                canvasState.canvasSize = newSize
            }
            .onChange(of: tool) { _, _ in
                ghostRotation = 0
                ghostMirrorX = false
                ghostMirrorY = false
                wirePoints = []
                wirePointer = nil
                lastWireTap = nil
                wireDragStart = nil
                wireDragActive = false
            }
            .onChange(of: pendingSymbol?.name) { _, _ in
                ghostRotation = 0
                ghostMirrorX = false
                ghostMirrorY = false
            }
            .alert("Add Label", isPresented: $showingLabelAlert) {
                TextField("Label text", text: $labelText)
                Button("Add") {
                    let text = labelText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let p = labelPoint, !text.isEmpty {
                        document.addLabel(at: p, text: text)
                    }
                    labelPoint = nil
                    labelText = ""
                }
                Button("Cancel", role: .cancel) {
                    labelPoint = nil
                    labelText = ""
                }
            } message: {
                Text("Enter the label text.")
            }
        }
    }

    // MARK: Gestures (fed by the UIKit bridge at the bottom of this file)

    /// Handler set handed to the gesture overlay. Rebuilt on every body
    /// pass and pushed into the coordinator by `updateUIView`, so the
    /// recognizers always call the current view value's logic.
    private var gestureHandlers: CanvasGestureCoordinator.Handlers {
        var h = CanvasGestureCoordinator.Handlers()
        h.panBegan = { location, startLocation in
            self.handlePanBegan(location: location, startLocation: startLocation)
        }
        h.panChanged = { location, translation in
            self.handlePanChanged(location: location, translation: translation)
        }
        h.panEnded = { location, translation, cancelled in
            self.handlePanEnded(location: location, translation: translation, cancelled: cancelled)
        }
        h.tap = { location in
            if !self.focused { self.focused = true }
            self.canvasState.cursorWorld = self.world(location)
            self.handleTap(at: location)
        }
        h.twoFingerBegan = { centroid in self.handleTwoFingerBegan(centroid: centroid) }
        h.twoFingerChanged = { centroid, pinchScale in
            self.handleTwoFingerChanged(centroid: centroid, pinchScale: pinchScale)
        }
        h.twoFingerEnded = { self.handleTwoFingerEnded() }
        h.hover = { location in
            if let location {
                self.canvasState.cursorWorld = self.world(location)
            } else {
                self.canvasState.cursorWorld = nil
            }
        }
        return h
    }

    // MARK: One-finger pan (symbol move / canvas pan / tracking / wire drag)

    private func handlePanBegan(location: CGPoint, startLocation: CGPoint) {
        if !focused { focused = true }
        canvasState.cursorWorld = world(location)
        guard dragKind == .none else { return }
        switch tool {
        case .select:
            if highlightArmed.wrappedValue || selectConnectionArmed.wrappedValue {
                // Armed one-shot modes (part 5.3): a press must not
                // start a symbol drag or change the selection — the
                // tap split in handlePanEnded resolves the mode.
                dragKind = .track
            } else if let hit = symbolAt(world(startLocation), defs: defsByID) {
                dragKind = .moveSymbol
                dragSymbolID = hit.id
                selection = hit.id
                dragStartOrigin = hit.origin
                dragOrigin = hit.origin
                dragPinPoints = pinPoints(of: hit)
            } else {
                dragKind = .pan
                dragStartOffset = canvasState.offset
            }
        case .wire:
            dragKind = .track
            // The wire drag (if this pan turns into one) builds from the
            // pin snap / grid snap of where the finger landed.
            let startWorld = world(startLocation)
            wireDragStart = nearestPin(to: startWorld, defs: defsByID)?.point ?? snap(startWorld)
            wireDragActive = false
        default:
            dragKind = .track
        }
    }

    private func handlePanChanged(location: CGPoint, translation: CGPoint) {
        let w = world(location)
        canvasState.cursorWorld = w

        switch dragKind {
        case .pan:
            canvasState.offset = CGPoint(x: dragStartOffset.x + translation.x,
                                       y: dragStartOffset.y + translation.y)
        case .moveSymbol:
            let dw = DPoint(x: Double(translation.x) / scaleD,
                            y: -Double(translation.y) / scaleD)
            dragOrigin = snap(dragStartOrigin + dw)
        case .track:
            if tool == .wire {
                let target = nearestPin(to: w, defs: defsByID)?.point ?? snap(w)
                if wireDragActive {
                    updateWireDrag(to: target)
                } else if hypot(translation.x, translation.y) >= 5,
                          let start = wireDragStart {
                    // Threshold crossed: this pan is a wire drag. Seed it
                    // from the captured start point (continuing any
                    // tap-tap wire already in progress via the L-route).
                    wireDragActive = true
                    if wirePoints.isEmpty {
                        wirePoints = [start]
                    } else {
                        appendRouted(to: start)
                    }
                    updateWireDrag(to: target)
                } else {
                    wirePointer = target
                }
            }
        case .none:
            break
        }
    }

    private func handlePanEnded(location: CGPoint, translation: CGPoint, cancelled: Bool) {
        let dist = hypot(translation.x, translation.y)
        canvasState.cursorWorld = world(location)
        if wireDragActive {
            // A finished wire drag commits through the normal finishWire
            // path — including when a second finger cancelled the pan to
            // start a pinch ("commit as if lifted").
            finishWireDrag(at: location)
        } else if !cancelled && dist < 5 {
            // Preserves the old DragGesture split: sub-5 pt = tap. A
            // cancelled pan never synthesises a tap (the tap recognizer
            // covers genuine taps the pan never picked up), so starting a
            // pinch cannot also place/select/delete under the first finger.
            handleTap(at: location)
        } else if dragKind == .moveSymbol, let id = dragSymbolID,
                  let target = dragOrigin, target != dragStartOrigin {
            document.moveSymbol(id: id, to: target, pinPointsBefore: dragPinPoints)
        }
        resetDrag()
    }

    private func resetDrag() {
        dragKind = .none
        dragSymbolID = nil
        dragOrigin = nil
        dragPinPoints = []
        wireDragStart = nil
        wireDragActive = false
    }

    // MARK: Two-finger session (pinch zoom anchored at the centroid + pan)

    private func handleTwoFingerBegan(centroid: CGPoint) {
        guard twoFingerStartScale == nil else { return }
        twoFingerStartScale = canvasState.scale
        twoFingerAnchorWorld = world(centroid)
        canvasState.cursorWorld = twoFingerAnchorWorld
    }

    private func handleTwoFingerChanged(centroid: CGPoint, pinchScale: CGFloat) {
        if twoFingerStartScale == nil { handleTwoFingerBegan(centroid: centroid) }
        guard let startScale = twoFingerStartScale,
              let anchor = twoFingerAnchorWorld else { return }
        let newScale = min(max(startScale * pinchScale, CanvasViewState.minScale),
                           CanvasViewState.maxScale)
        canvasState.scale = newScale
        // Anchor invariant: screen(anchor) == centroid, i.e.
        // offset = (centroid.x - anchor.x * scale, centroid.y + anchor.y * scale).
        // Because the CURRENT centroid is used, two-finger translation
        // (pan) is folded into the same adjustment — the world point under
        // the fingers at session start stays under the fingers throughout.
        canvasState.offset = CGPoint(x: centroid.x - CGFloat(anchor.x) * newScale,
                                     y: centroid.y + CGFloat(anchor.y) * newScale)
    }

    private func handleTwoFingerEnded() {
        twoFingerStartScale = nil
        twoFingerAnchorWorld = nil
    }

    // MARK: Tap handling per tool

    private func handleTap(at location: CGPoint) {
        let w = world(location)
        // Part 5.3 one-shot modes intercept Select-tool taps. A tap
        // that hits nothing the mode can use leaves it armed.
        if tool == .select {
            if selectConnectionArmed.wrappedValue, let wire = wireAt(w) {
                selectConnectionArmed.wrappedValue = false
                onSelectConnectionWire(wire.id)
                return
            }
            if highlightArmed.wrappedValue {
                if let wire = wireAt(w) {
                    highlightArmed.wrappedValue = false
                    onHighlightWire(wire.id)
                    return
                }
                if let pin = nearestPinInfo(to: w, defs: defsByID) {
                    highlightArmed.wrappedValue = false
                    onHighlightPin(pin.instanceID, pin.pinNumber)
                    return
                }
            }
        }
        switch tool {
        case .select:
            selection = symbolAt(w, defs: defsByID)?.id
        case .placeSymbol, .placePower:
            placeSymbolTap(at: w)
        case .wire:
            wireTap(at: w)
        case .junction:
            junctionTap(at: w)
        case .label:
            labelPoint = snap(w)
            labelText = ""
            showingLabelAlert = true
        case .noConnect:
            noConnectTap(at: w)
        case .delete:
            deleteTap(at: w)
        }
    }

    /// No-connect tool (part 5.3, S4): tap places a flag at the
    /// snapped point (the junction tool's grid snap); tapping
    /// within one grid step of an existing flag removes it.
    private func noConnectTap(at w: DPoint) {
        let p = snap(w)
        if let existing = document.state.noConnects.first(where: {
            $0.at.distance(to: p) <= Self.grid + 1e-9
        }) {
            document.removeNoConnect(id: existing.id)
        } else {
            document.addNoConnect(at: p)
        }
    }

    private func placeSymbolTap(at w: DPoint) {
        guard let def = pendingSymbol else {
            onRequestSymbolChooser(tool == .placePower)
            return
        }
        let p = snap(w)
        let placed = PlacedSymbol(
            id: UUID(),
            library: def.library,
            symbolName: def.name,
            unit: 1,
            x: p.x, y: p.y,
            rotation: ghostRotation,
            mirrorX: ghostMirrorX,
            mirrorY: ghostMirrorY,
            reference: document.nextReference(prefix: def.referencePrefix),
            value: def.property("Value") ?? def.name)
        document.addSymbol(placed)
        selection = placed.id
    }

    // MARK: Wire tool

    private func appendRouted(to pt: DPoint) {
        guard let last = wirePoints.last else { wirePoints = [pt]; return }
        if pt == last { return }
        let dx = pt.x - last.x, dy = pt.y - last.y
        if dx != 0 && dy != 0 {
            // L-route: horizontal-then-vertical when |dx| >= |dy|, else v-then-h.
            let corner = abs(dx) >= abs(dy) ? DPoint(x: pt.x, y: last.y) : DPoint(x: last.x, y: pt.y)
            if corner != last && corner != pt { wirePoints.append(corner) }
        }
        wirePoints.append(pt)
    }

    /// The in-progress wire plus the L-routed segment to `to`, for preview.
    private func routedPreview(to: DPoint) -> [DPoint] {
        guard let last = wirePoints.last else { return wirePoints }
        if to == last { return wirePoints }
        var pts = wirePoints
        let dx = to.x - last.x, dy = to.y - last.y
        if dx != 0 && dy != 0 {
            let corner = abs(dx) >= abs(dy) ? DPoint(x: to.x, y: last.y) : DPoint(x: last.x, y: to.y)
            if corner != last && corner != to { pts.append(corner) }
        }
        pts.append(to)
        return pts
    }

    /// Live update for a wire drag: the endpoint follows the (pin/grid
    /// snapped) finger position, and the routed preview's corner is
    /// committed into `wirePoints` once the finger has moved at least one
    /// grid step past it along the new axis — so one drag can lay down a
    /// multi-bend wire, KiCad-style.
    private func updateWireDrag(to target: DPoint) {
        wirePointer = target
        guard let last = wirePoints.last else { return }
        let preview = routedPreview(to: target)
        // A preview exactly 2 points longer than wirePoints is
        // [.., corner, target]: the corner is the candidate to commit.
        guard preview.count == wirePoints.count + 2 else { return }
        let corner = preview[wirePoints.count]
        guard corner != last, corner != target else { return }
        // Distance travelled along the post-corner segment (pure H or V).
        let along = max(abs(target.x - corner.x), abs(target.y - corner.y))
        if along >= Self.grid - 1e-9 {
            wirePoints.append(corner)
        }
    }

    /// Release of a wire drag: route to the release point (pin snap wins,
    /// so a wire released on a pin ends exactly on it) and commit through
    /// the existing finishWire machinery (cleaning + endpoint
    /// auto-junctions).
    private func finishWireDrag(at location: CGPoint) {
        let w = world(location)
        let end = nearestPin(to: w, defs: defsByID)?.point ?? snap(w)
        updateWireDrag(to: end)
        appendRouted(to: end)
        wireDragActive = false
        wireDragStart = nil
        lastWireTap = nil
        finishWire()
    }

    private func wireTap(at w: DPoint) {
        let defs = defsByID
        let pin = nearestPin(to: w, defs: defs)
        let pt = pin?.point ?? snap(w)
        wirePointer = pt
        if wirePoints.isEmpty {
            wirePoints = [pt]
            lastWireTap = nil
            return
        }
        let isDoubleTap: Bool
        if let last = lastWireTap {
            isDoubleTap = Date().timeIntervalSince(last.time) < 0.35 && last.point == pt && pin == nil
        } else {
            isDoubleTap = false
        }
        appendRouted(to: pt)
        if pin != nil || isDoubleTap {
            finishWire()
            lastWireTap = nil
        } else {
            lastWireTap = (pt, Date())
        }
    }

    private func cleanedWirePoints(_ pts: [DPoint]) -> [DPoint] {
        var out: [DPoint] = []
        for p in pts where out.last != p { out.append(p) }
        var i = 1
        while out.count >= 3 && i < out.count - 1 {
            let a = out[i - 1], b = out[i], c = out[i + 1]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            if abs(cross) < 1e-9 {
                out.remove(at: i)
            } else {
                i += 1
            }
        }
        return out
    }

    private func finishWire() {
        let pts = cleanedWirePoints(wirePoints)
        wirePoints = []
        wirePointer = nil
        guard pts.count >= 2 else { return }
        let existing = document.state.wires
        document.addWire(WireItem(id: UUID(), points: pts))
        // Auto-junction where a new endpoint lands mid-segment on an old wire.
        for endpoint in [pts.first!, pts.last!] {
            var onSegment = false
            for w in existing {
                for i in 0..<(w.points.count - 1) {
                    let (dist, proj) = Self.pointSegmentDistance(endpoint, w.points[i], w.points[i + 1])
                    if dist < 0.02 && proj != w.points[i] && proj != w.points[i + 1] {
                        onSegment = true
                    }
                }
            }
            if onSegment {
                document.addJunction(at: endpoint)
            }
        }
    }

    // MARK: Junction / delete taps

    private func junctionTap(at w: DPoint) {
        let threshold = max(0.9, 5.0 / scaleD)
        var best: (distance: Double, point: DPoint)?
        for wire in document.state.wires {
            for i in 0..<(wire.points.count - 1) {
                let (dist, proj) = Self.pointSegmentDistance(w, wire.points[i], wire.points[i + 1])
                if dist <= threshold && (best == nil || dist < best!.distance) {
                    best = (dist, proj)
                }
            }
        }
        if let best {
            document.addJunction(at: best.point)
        }
    }

    private func deleteTap(at w: DPoint) {
        let tol = max(0.9, 6.0 / scaleD)
        for j in document.state.junctions where w.distance(to: j.at) <= tol {
            document.deleteJunction(id: j.id)
            return
        }
        let labelTol = max(1.5, 8.0 / scaleD)
        for l in document.state.labels where w.distance(to: l.at) <= labelTol {
            document.deleteLabel(id: l.id)
            return
        }
        if let s = symbolAt(w, defs: defsByID) {
            document.deleteSymbol(id: s.id)
            if selection == s.id { selection = nil }
            return
        }
        for wire in document.state.wires {
            for i in 0..<(wire.points.count - 1) {
                if Self.pointSegmentDistance(w, wire.points[i], wire.points[i + 1]).distance <= tol {
                    document.deleteWire(id: wire.id)
                    return
                }
            }
        }
    }

    // MARK: Keyboard

    private func handleEscape() {
        if !wirePoints.isEmpty {
            wirePoints = []
            wirePointer = nil
            lastWireTap = nil
            wireDragStart = nil
            wireDragActive = false
        } else if !connectionSelectedWireIDs.isEmpty {
            // Part 5.3, S11: Esc clears the connection selection.
            onClearConnectionSelection()
        } else if isHighlightActive {
            // Part 5.3, S1: Esc clears the net highlight.
            onClearHighlight()
        } else if tool == .placeSymbol || tool == .placePower {
            tool = .select
            onConsumePlacementDone()
        } else if selection != nil {
            selection = nil
        }
    }

    private func handleLetterKey(_ key: String) {
        let placing = (tool == .placeSymbol || tool == .placePower) && pendingSymbol != nil
        switch key {
        case "r":
            if placing {
                ghostRotation = (ghostRotation + 90) % 360
            } else if let id = selection {
                document.rotateSymbol(id: id)
            }
        case "x":
            if placing {
                ghostMirrorX.toggle()
            } else if let id = selection {
                document.mirrorSymbol(id: id, xAxis: true)
            }
        case "y":
            if placing {
                ghostMirrorY.toggle()
            } else if let id = selection {
                document.mirrorSymbol(id: id, xAxis: false)
            }
        default:
            break
        }
    }

    private func deleteSelection() {
        // Part 5.3, S11: with a connection selection, Delete
        // removes exactly those wires (the editor does it as one
        // undo step through deleteWires) instead of the symbol.
        if !connectionSelectedWireIDs.isEmpty {
            onDeleteConnectionSelection()
            return
        }
        if let id = selection {
            document.deleteSymbol(id: id)
            selection = nil
        }
    }

    private func nudge(dx: Double, dy: Double) {
        guard let s = selectedSymbol else { return }
        document.moveSymbol(id: s.id,
                            to: DPoint(x: s.x + dx, y: s.y + dy),
                            pinPointsBefore: pinPoints(of: s))
    }
}

// MARK: - Drawing

extension SchematicCanvasView {
    private static let wireColor = Color(red: 0.0, green: 0.518, blue: 0.0) // KiCad (0,132,0)
    private static let labelColor = Color(red: 0.0, green: 0.0, blue: 0.72)
    private static let refColor = Color(red: 0.0, green: 0.0, blue: 0.75)
    private static let valueColor = Color(red: 0.15, green: 0.40, blue: 0.40)

    private func drawScene(ctx: GraphicsContext, size: CGSize, defs: [UUID: KiCadSymbolDef]) {
        var ctx = ctx
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))

        drawGrid(&ctx, size: size)

        // Wires (part 5.3: while a net highlight is active, members
        // draw full strength in the accent colour and non-members
        // dim to ~0.25; connection-selected wires draw in the
        // selection colour, which wins over the highlight).
        let highlightActive = isHighlightActive
            || !highlightedWireIDs.isEmpty || !highlightedSymbolIDs.isEmpty
        let wireWidth = max(0.15 * scaleD, 1.0)
        for w in document.state.wires where w.points.count >= 2 {
            var path = Path()
            path.move(to: screen(w.points[0]))
            for p in w.points.dropFirst() { path.addLine(to: screen(p)) }
            let color: Color
            if connectionSelectedWireIDs.contains(w.id) {
                color = .orange
            } else if highlightActive {
                color = highlightedWireIDs.contains(w.id)
                    ? .accentColor : Self.wireColor.opacity(0.25)
            } else {
                color = Self.wireColor
            }
            ctx.stroke(path, with: .color(color),
                       style: StrokeStyle(lineWidth: CGFloat(wireWidth), lineCap: .round, lineJoin: .round))
        }

        // Junctions
        let jr = CGFloat(max(0.55 * scaleD, 2.5))
        for j in document.state.junctions {
            let c = screen(j.at)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - jr, y: c.y - jr, width: 2 * jr, height: 2 * jr)),
                     with: .color(Self.wireColor))
        }

        // No-connect flags (part 5.3, S4): an × marker about one
        // grid step across, in the accent colour — the same
        // treatment KiCad gives SCH_NO_CONNECT items.
        if !document.state.noConnects.isEmpty {
            let half = CGFloat(max(0.635 * scaleD, 3.5))
            var path = Path()
            for item in document.state.noConnects {
                let c = screen(item.at)
                path.move(to: CGPoint(x: c.x - half, y: c.y - half))
                path.addLine(to: CGPoint(x: c.x + half, y: c.y + half))
                path.move(to: CGPoint(x: c.x - half, y: c.y + half))
                path.addLine(to: CGPoint(x: c.x + half, y: c.y - half))
            }
            ctx.stroke(path, with: .color(.accentColor),
                       style: StrokeStyle(lineWidth: max(1.5, CGFloat(0.15 * scaleD)),
                                          lineCap: .round))
        }

        // Labels (KiCad label texts support _{...} markup -> KiCadText)
        for l in document.state.labels {
            let sizePt = max(CGFloat(1.27 * scaleD), 9)
            let pt = screen(l.at)
            KiCadText.draw(in: &ctx, l.text, at: CGPoint(x: pt.x, y: pt.y - 2),
                           size: sizePt, color: Self.labelColor, angle: 0,
                           anchor: UnitPoint(x: 0, y: 1), bold: false, italic: false)
        }

        // Symbols + property texts (part 5.3: while a net highlight
        // is active, symbols off the net draw dimmed to ~0.25 —
        // a context copy's opacity, so the renderer is untouched).
        for s in document.state.symbols {
            let placed = effectivePlaced(s)
            var sctx = ctx
            if highlightActive && !highlightedSymbolIDs.contains(s.id) {
                sctx.opacity = 0.25
            }
            if let def = defs[s.id] {
                drawSymbol(&sctx, def: def, placed: placed)
                drawPropertyTexts(&sctx, def: def, placed: placed)
            } else {
                drawMissingDefPlaceholder(&sctx, placed: placed)
            }
        }

        // Placement ghost
        if tool == .placeSymbol || tool == .placePower,
           let def = pendingSymbol, let cursor = canvasState.cursorWorld {
            let p = snap(cursor)
            let ghost = PlacedSymbol(id: UUID(), library: def.library, symbolName: def.name,
                                     unit: 1, x: p.x, y: p.y, rotation: ghostRotation,
                                     mirrorX: ghostMirrorX, mirrorY: ghostMirrorY,
                                     reference: "", value: "")
            var c = ctx
            c.opacity = 0.5
            drawSymbol(&c, def: def, placed: ghost)
        }

        // Wire preview
        if !wirePoints.isEmpty {
            let pts = wirePointer.map { routedPreview(to: $0) } ?? wirePoints
            if pts.count >= 2 {
                var path = Path()
                path.move(to: screen(pts[0]))
                for p in pts.dropFirst() { path.addLine(to: screen(p)) }
                ctx.stroke(path, with: .color(Self.wireColor),
                           style: StrokeStyle(lineWidth: CGFloat(wireWidth), lineCap: .round,
                                              lineJoin: .round, dash: [6, 4]))
            }
        }

        // Pin markers in wire mode
        if tool == .wire {
            drawPinMarkers(&ctx, defs: defs)
        }

        // Selection highlight
        if let s = selectedSymbol, let def = defs[s.id] {
            let b = SymbolRenderer.placedBounds(def: def, placed: effectivePlaced(s))
            let rect = CGRect(x: canvasState.offset.x + b.minX * canvasState.scale,
                              y: canvasState.offset.y - b.maxY * canvasState.scale,
                              width: b.width * canvasState.scale,
                              height: b.height * canvasState.scale)
            ctx.stroke(Path(rect.insetBy(dx: -3, dy: -3)), with: .color(.orange),
                       style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        }
    }

    private func drawGrid(_ ctx: inout GraphicsContext, size: CGSize) {
        var step = Self.grid
        while step * scaleD < 8 { step *= 2 }
        let topLeft = world(CGPoint(x: 0, y: size.height))     // min x, min y (world y-up)
        let bottomRight = world(CGPoint(x: size.width, y: 0))  // max x, max y
        let startX = (topLeft.x / step).rounded(.down) * step
        let startY = (topLeft.y / step).rounded(.down) * step
        var path = Path()
        var x = startX
        while x <= bottomRight.x {
            var y = startY
            while y <= bottomRight.y {
                let c = screen(DPoint(x: x, y: y))
                path.addEllipse(in: CGRect(x: c.x - 0.7, y: c.y - 0.7, width: 1.4, height: 1.4))
                y += step
            }
            x += step
        }
        ctx.fill(path, with: .color(Color(white: 0.82)))
    }

    private func drawSymbol(_ ctx: inout GraphicsContext, def: KiCadSymbolDef, placed: PlacedSymbol) {
        let map: (CGPoint) -> CGPoint = { lp in
            let wp = SymbolRenderer.transformPoint(
                DPoint(x: Double(lp.x), y: Double(lp.y)), placed: placed)
            return screen(wp)
        }
        SymbolRenderer.draw(def: def, unit: placed.unit, in: ctx, map: map,
                            scale: canvasState.scale,
                            showPinNumbers: !def.pinNumbersHidden,
                            showPinNames: !def.pinNamesHidden,
                            bodyStyle: placed.effectiveBodyStyle)
    }

    /// Reference / Value texts at their def property positions (transformed by
    /// the placement), skipping hidden properties. If a property is missing
    /// entirely, the text falls back to just above the body bounds.
    private func drawPropertyTexts(_ ctx: inout GraphicsContext, def: KiCadSymbolDef, placed: PlacedSymbol) {
        let bounds = SymbolRenderer.placedBounds(def: def, placed: placed)
        let entries: [(name: String, text: String, color: Color)] = [
            ("Reference", placed.reference, Self.refColor),
            ("Value", placed.value, Self.valueColor),
        ]
        var fallbackSlot = 0
        for entry in entries {
            if let prop = def.properties.first(where: { $0.name == entry.name }) {
                if prop.hidden { continue }
                let wp = SymbolRenderer.transformPoint(DPoint(x: prop.x, y: prop.y), placed: placed)
                let sizePt = max(CGFloat(prop.fontSize * scaleD), 8)
                let angle = -(Double(placed.rotation) + prop.rotation) * Double.pi / 180.0
                KiCadText.draw(in: &ctx, entry.text, at: screen(wp), size: sizePt,
                               color: entry.color, angle: angle, anchor: .center,
                               bold: false, italic: false)
            } else {
                let yOffset = 3.4 - Double(fallbackSlot) * 1.9
                fallbackSlot += 1
                let wp = DPoint(x: Double(bounds.minX), y: Double(bounds.maxY) + yOffset)
                let sizePt = max(CGFloat(1.27 * scaleD), 8)
                KiCadText.draw(in: &ctx, entry.text, at: screen(wp), size: sizePt,
                               color: entry.color, angle: 0,
                               anchor: UnitPoint(x: 0, y: 1), bold: false, italic: false)
            }
        }
    }

    private func drawMissingDefPlaceholder(_ ctx: inout GraphicsContext, placed: PlacedSymbol) {
        let half = 5.0
        let corners = [
            DPoint(x: placed.x - half, y: placed.y - half),
            DPoint(x: placed.x + half, y: placed.y - half),
            DPoint(x: placed.x + half, y: placed.y + half),
            DPoint(x: placed.x - half, y: placed.y + half),
        ]
        var path = Path()
        path.move(to: screen(corners[0]))
        for c in corners.dropFirst() { path.addLine(to: screen(c)) }
        path.closeSubpath()
        ctx.stroke(path, with: .color(.purple),
                   style: StrokeStyle(lineWidth: 1.25, dash: [5, 3]))
        var c = ctx
        let pt = screen(placed.origin)
        c.translateBy(x: pt.x, y: pt.y - CGFloat(half * scaleD) - 4)
        c.draw(Text(placed.reference).font(.system(size: 10)).foregroundColor(.purple),
               at: .zero, anchor: UnitPoint(x: 0.5, y: 1))
    }

    private func drawPinMarkers(_ ctx: inout GraphicsContext, defs: [UUID: KiCadSymbolDef]) {
        let cursor = canvasState.cursorWorld
        let nearest = cursor.flatMap { nearestPin(to: $0, defs: defs) }
        let side = CGFloat(max(0.6 * scaleD, 5))
        for s in document.state.symbols {
            guard let def = defs[s.id] else { continue }
            for entry in SymbolRenderer.pinWorldPoints(def: def, placed: s) {
                let c = screen(entry.point)
                let rect = CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side)
                if let nearest, nearest.point == entry.point {
                    ctx.fill(Path(rect), with: .color(.orange))
                } else {
                    ctx.stroke(Path(rect), with: .color(Self.wireColor), lineWidth: 1.25)
                }
            }
        }
    }
}

// MARK: - UIKit gesture bridge
//
// A transparent UIView overlay carrying the real recognizers. It replaces
// the old SwiftUI DragGesture + MagnificationGesture combo (whose pinch
// zoomed about the canvas centre with no anchor, hence "very sketchy"):
//   - UIPinchGestureRecognizer: zoom anchored at the touch centroid.
//   - UIPanGestureRecognizer (2 touches): two-finger pan, simultaneous
//     with the pinch; both feed ONE two-finger session in the view, whose
//     anchor math (world point under the centroid stays under the
//     centroid) folds pan and zoom into a single offset/scale update, so
//     the two recognizers can never double-apply a translation.
//   - UIPanGestureRecognizer (1 touch): the existing one-finger logic
//     (symbol move / canvas pan / tracking / wire drag). It is NOT
//     simultaneous with pinch/pan2, so when a second finger lands and the
//     pinch begins, UIKit cancels this pan and the view commits the drag
//     through its normal end path first.
//   - UITapGestureRecognizer: taps the one-finger pan never picked up
//     (touch released before the pan began). It is required to fail the
//     one-finger pan, so a touch is delivered exactly once: pan-ended
//     (< 5 pt -> tap split in the view) XOR tap recognizer.
//   - UIHoverGestureRecognizer: mouse/trackpad hover, forwarded to the
//     same cursorWorld tracking as SwiftUI's onContinuousHover (which
//     stays attached as well). A mouse/trackpad "touch" is a single
//     touch, so pointer drags ride the one-finger pan path.

final class CanvasGestureCoordinator: NSObject, UIGestureRecognizerDelegate {
    struct Handlers {
        /// (location, startLocation) — startLocation = location - translation.
        var panBegan: (CGPoint, CGPoint) -> Void = { _, _ in }
        /// (location, translation)
        var panChanged: (CGPoint, CGPoint) -> Void = { _, _ in }
        /// (location, translation, cancelled)
        var panEnded: (CGPoint, CGPoint, Bool) -> Void = { _, _, _ in }
        var tap: (CGPoint) -> Void = { _ in }
        /// (centroid)
        var twoFingerBegan: (CGPoint) -> Void = { _ in }
        /// (centroid, cumulative pinch scale from session start)
        var twoFingerChanged: (CGPoint, CGFloat) -> Void = { _, _ in }
        var twoFingerEnded: () -> Void = {}
        /// (location, or nil when the pointer leaves)
        var hover: (CGPoint?) -> Void = { _ in }
    }

    var handlers = Handlers()

    private weak var pinchGesture: UIPinchGestureRecognizer?
    private weak var twoFingerPanGesture: UIPanGestureRecognizer?

    fileprivate func register(pinch: UIPinchGestureRecognizer, twoFingerPan: UIPanGestureRecognizer) {
        pinchGesture = pinch
        twoFingerPanGesture = twoFingerPan
    }

    /// The pinch recognizer's live cumulative scale while it is tracking,
    /// else 1 (a pure two-finger pan leaves the scale alone).
    private var currentPinchScale: CGFloat {
        guard let pinch = pinchGesture,
              pinch.state == .began || pinch.state == .changed else { return 1 }
        return pinch.scale
    }

    // MARK: Recognizer actions

    @objc func handleOneFingerPan(_ g: UIPanGestureRecognizer) {
        guard let view = g.view else { return }
        let location = g.location(in: view)
        let translation = g.translation(in: view)
        let startLocation = CGPoint(x: location.x - translation.x,
                                    y: location.y - translation.y)
        switch g.state {
        case .began:
            handlers.panBegan(location, startLocation)
        case .changed:
            handlers.panChanged(location, translation)
        case .ended:
            handlers.panEnded(location, translation, false)
        case .cancelled, .failed:
            handlers.panEnded(location, translation, true)
        default:
            break
        }
    }

    @objc func handleTap(_ g: UITapGestureRecognizer) {
        guard g.state == .recognized, let view = g.view else { return }
        handlers.tap(g.location(in: view))
    }

    @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
        guard let view = g.view else { return }
        let centroid = g.location(in: view)
        switch g.state {
        case .began:
            handlers.twoFingerBegan(centroid)
        case .changed:
            handlers.twoFingerChanged(centroid, g.scale)
        case .ended, .cancelled, .failed:
            handlers.twoFingerEnded()
        default:
            break
        }
    }

    @objc func handleTwoFingerPan(_ g: UIPanGestureRecognizer) {
        guard let view = g.view else { return }
        let centroid = g.location(in: view)
        switch g.state {
        case .began:
            handlers.twoFingerBegan(centroid)
        case .changed:
            handlers.twoFingerChanged(centroid, currentPinchScale)
        case .ended, .cancelled, .failed:
            // If the pinch is still tracking it owns the session end;
            // otherwise the session is over. (Idempotent in the view:
            // when both recognizers end together both may call it.)
            let pinchState = pinchGesture?.state
            if pinchState != .began && pinchState != .changed {
                handlers.twoFingerEnded()
            }
        default:
            break
        }
    }

    @objc func handleHover(_ g: UIHoverGestureRecognizer) {
        guard let view = g.view else { return }
        switch g.state {
        case .began, .changed:
            handlers.hover(g.location(in: view))
        case .ended, .cancelled, .failed:
            handlers.hover(nil)
        default:
            break
        }
    }

    // MARK: UIGestureRecognizerDelegate

    /// Only pinch + two-finger pan run simultaneously (they feed one
    /// shared session). The one-finger pan is exclusive with both, which
    /// is what makes a starting pinch cancel it through its end path.
    /// Hover runs alongside everything.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        if gestureRecognizer is UIHoverGestureRecognizer || other is UIHoverGestureRecognizer {
            return true
        }
        let twoFinger = { (g: UIGestureRecognizer) in
            g === self.pinchGesture || g === self.twoFingerPanGesture
        }
        return twoFinger(gestureRecognizer) && twoFinger(other)
    }
}

private struct CanvasGestureOverlay: UIViewRepresentable {
    var handlers: CanvasGestureCoordinator.Handlers

    func makeCoordinator() -> CanvasGestureCoordinator { CanvasGestureCoordinator() }

    func makeUIView(context: Context) -> UIView {
        let coordinator = context.coordinator
        coordinator.handlers = handlers
        let view = UIView()
        view.backgroundColor = .clear

        let pinch = UIPinchGestureRecognizer(target: coordinator,
                                             action: #selector(CanvasGestureCoordinator.handlePinch(_:)))
        pinch.delegate = coordinator

        let twoFingerPan = UIPanGestureRecognizer(target: coordinator,
                                                  action: #selector(CanvasGestureCoordinator.handleTwoFingerPan(_:)))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        twoFingerPan.delegate = coordinator

        let oneFingerPan = UIPanGestureRecognizer(target: coordinator,
                                                  action: #selector(CanvasGestureCoordinator.handleOneFingerPan(_:)))
        oneFingerPan.minimumNumberOfTouches = 1
        oneFingerPan.maximumNumberOfTouches = 1
        oneFingerPan.delegate = coordinator

        let tap = UITapGestureRecognizer(target: coordinator,
                                         action: #selector(CanvasGestureCoordinator.handleTap(_:)))
        tap.numberOfTapsRequired = 1
        tap.numberOfTouchesRequired = 1
        // Exactly-once tap delivery: the tap fires only when the
        // one-finger pan failed (touch ended before the pan began). If
        // the pan ran, the view's own < 5 pt split handles the tap.
        tap.require(toFail: oneFingerPan)
        tap.delegate = coordinator

        let hover = UIHoverGestureRecognizer(target: coordinator,
                                             action: #selector(CanvasGestureCoordinator.handleHover(_:)))
        hover.delegate = coordinator

        coordinator.register(pinch: pinch, twoFingerPan: twoFingerPan)
        view.addGestureRecognizer(pinch)
        view.addGestureRecognizer(twoFingerPan)
        view.addGestureRecognizer(oneFingerPan)
        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(hover)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.handlers = handlers
    }
}
