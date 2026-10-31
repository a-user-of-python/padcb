import SwiftUI

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

    // Drag bookkeeping
    private enum DragKind { case none, pan, moveSymbol, track }
    @State private var dragKind: DragKind = .none
    @State private var dragStartOffset: CGPoint = .zero
    @State private var dragSymbolID: UUID?
    @State private var dragStartOrigin: DPoint = .zero
    @State private var dragPinPoints: [DPoint] = []
    @State private var dragOrigin: DPoint? // live snapped origin while moving a symbol
    @State private var pinchBase: CGFloat?

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
            .gesture(dragGesture)
            .simultaneousGesture(magnificationGesture)
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

    // MARK: Gestures

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { v in handleDragChanged(v) }
            .onEnded { v in handleDragEnded(v) }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if pinchBase == nil { pinchBase = canvasState.scale }
                let base = pinchBase ?? canvasState.scale
                canvasState.scale = min(max(base * value, CanvasViewState.minScale), CanvasViewState.maxScale)
            }
            .onEnded { _ in pinchBase = nil }
    }

    private func handleDragChanged(_ v: DragGesture.Value) {
        if !focused { focused = true }
        let w = world(v.location)
        canvasState.cursorWorld = w

        if dragKind == .none {
            switch tool {
            case .select:
                if let hit = symbolAt(world(v.startLocation), defs: defsByID) {
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
            default:
                dragKind = .track
            }
        }

        switch dragKind {
        case .pan:
            canvasState.offset = CGPoint(x: dragStartOffset.x + v.translation.width,
                                       y: dragStartOffset.y + v.translation.height)
        case .moveSymbol:
            let dw = DPoint(x: Double(v.translation.width) / scaleD,
                            y: -Double(v.translation.height) / scaleD)
            dragOrigin = snap(dragStartOrigin + dw)
        case .track:
            if tool == .wire {
                wirePointer = nearestPin(to: w, defs: defsByID)?.point ?? snap(w)
            }
        case .none:
            break
        }
    }

    private func handleDragEnded(_ v: DragGesture.Value) {
        let dist = hypot(v.translation.width, v.translation.height)
        canvasState.cursorWorld = world(v.location)
        if dist < 5 {
            handleTap(at: v.location)
        } else if dragKind == .moveSymbol, let id = dragSymbolID,
                  let target = dragOrigin, target != dragStartOrigin {
            document.moveSymbol(id: id, to: target, pinPointsBefore: dragPinPoints)
        }
        dragKind = .none
        dragSymbolID = nil
        dragOrigin = nil
        dragPinPoints = []
    }

    // MARK: Tap handling per tool

    private func handleTap(at location: CGPoint) {
        let w = world(location)
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
        case .delete:
            deleteTap(at: w)
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

        // Wires
        let wireWidth = max(0.15 * scaleD, 1.0)
        for w in document.state.wires where w.points.count >= 2 {
            var path = Path()
            path.move(to: screen(w.points[0]))
            for p in w.points.dropFirst() { path.addLine(to: screen(p)) }
            ctx.stroke(path, with: .color(Self.wireColor),
                       style: StrokeStyle(lineWidth: CGFloat(wireWidth), lineCap: .round, lineJoin: .round))
        }

        // Junctions
        let jr = CGFloat(max(0.55 * scaleD, 2.5))
        for j in document.state.junctions {
            let c = screen(j.at)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - jr, y: c.y - jr, width: 2 * jr, height: 2 * jr)),
                     with: .color(Self.wireColor))
        }

        // Labels
        for l in document.state.labels {
            let sizePt = max(CGFloat(1.27 * scaleD), 9)
            let text = Text(l.text).font(.system(size: sizePt)).foregroundColor(Self.labelColor)
            var c = ctx
            let pt = screen(l.at)
            c.translateBy(x: pt.x, y: pt.y - 2)
            c.draw(text, at: .zero, anchor: UnitPoint(x: 0, y: 1))
        }

        // Symbols + property texts
        for s in document.state.symbols {
            let placed = effectivePlaced(s)
            if let def = defs[s.id] {
                drawSymbol(&ctx, def: def, placed: placed)
                drawPropertyTexts(&ctx, def: def, placed: placed)
            } else {
                drawMissingDefPlaceholder(&ctx, placed: placed)
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
                            showPinNames: !def.pinNamesHidden)
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
                drawRotatedText(&ctx, entry.text, at: screen(wp), size: sizePt,
                                color: entry.color, angle: angle)
            } else {
                let yOffset = 3.4 - Double(fallbackSlot) * 1.9
                fallbackSlot += 1
                let wp = DPoint(x: Double(bounds.minX), y: Double(bounds.maxY) + yOffset)
                let sizePt = max(CGFloat(1.27 * scaleD), 8)
                var c = ctx
                let pt = screen(wp)
                c.translateBy(x: pt.x, y: pt.y)
                c.draw(Text(entry.text).font(.system(size: sizePt)).foregroundColor(entry.color),
                       at: .zero, anchor: UnitPoint(x: 0, y: 1))
            }
        }
    }

    private func drawRotatedText(_ ctx: inout GraphicsContext, _ string: String, at pt: CGPoint,
                                 size: CGFloat, color: Color, angle: Double) {
        var c = ctx
        c.translateBy(x: pt.x, y: pt.y)
        if angle != 0 { c.rotate(by: .radians(angle)) }
        c.draw(Text(string).font(.system(size: size)).foregroundColor(color),
               at: .zero, anchor: .center)
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
