import SwiftUI
import UIKit

/// AirPlay / external display support (part 5.3 rider).
///
/// When a second display connects (AirPlay or wired — one path),
/// PadCB opens a dedicated window on it at that display's FULL
/// NATIVE resolution and mirrors the LIVE session: the schematic
/// editor's actual document object, or the PCB session's latest
/// published snapshot (see SessionBridge.swift). Editing stays on
/// the iPad; this window is a passive live view.
///
/// Two vending paths, one invariant — exactly ONE external window
/// per display:
/// 1. Primary: the scene manifest in Info.plist
///    (`UIApplicationSceneManifest` with a configuration for
///    `UIWindowSceneSessionRoleExternalDisplay`) makes the system
///    vend an external-display scene, handled by
///    `ExternalDisplaySceneDelegate`.
/// 2. Fallback: `ExternalDisplayCoordinator` observes
///    `UIScreen.didConnectNotification` /
///    `didDisconnectNotification` and creates the window itself if
///    no scene session was vended.
/// Both paths register their window with the coordinator, keyed by
/// `ObjectIdentifier(screen)` (stable for the lifetime of a
/// connected UIScreen object), and the second path to arrive for a
/// screen adopts the existing window instead of creating another.
///
/// HONESTY (per the part 5.3 contract): no external display exists
/// in the build environment. This is structure + compile proof
/// only — device confirmation is Sean's, on his monitor.

// MARK: - Scene delegate (primary path)

final class ExternalDisplaySceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?
    private var screen: UIScreen?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        // Only the external-display roles get a window here; any
        // other session is not ours to touch.
        guard session.role == UIWindowSceneSessionRoleExternalDisplay
            || session.role == UIWindowSceneSessionRoleExternalDisplayNonInteractive
        else { return }
        guard let wscene = (session.scene as? UIWindowScene)
                ?? (scene as? UIWindowScene) else { return }

        let screen = wscene.screen
        self.screen = screen
        screen.overscanCompensation = .insetApplicationFrame

        // The UIScreen fallback may have beaten the scene to it:
        // adopt its window rather than double-creating.
        if let existing = ExternalDisplayCoordinator.shared
            .registeredWindow(for: screen) {
            window = existing
            return
        }

        let w = UIWindow(windowScene: wscene)
        w.rootViewController = UIHostingController(
            rootView: ExternalDisplayRootView(
                nativePixelSize: screen.nativeBounds.size))
        w.isHidden = false
        window = w
        ExternalDisplayCoordinator.shared.register(window: w, for: screen)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        if let screen {
            ExternalDisplayCoordinator.shared.deregister(screen: screen)
        }
        screen = nil
    }
}

// MARK: - Coordinator (fallback path + window registry)

final class ExternalDisplayCoordinator: NSObject {
    static let shared = ExternalDisplayCoordinator()

    /// One window per connected external screen, keyed by the
    /// screen object's identity (`ObjectIdentifier`) — stable for
    /// as long as that UIScreen object lives, which is exactly the
    /// connect/disconnect cycle the registry tracks.
    private var windows: [ObjectIdentifier: UIWindow] = [:]
    private var started = false

    private override init() { super.init() }

    /// Arms the UIScreen connect/disconnect fallback. Idempotent;
    /// called once from PadCBApp's init.
    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        center.addObserver(self,
                           selector: #selector(screenDidConnect(_:)),
                           name: UIScreen.didConnectNotification,
                           object: nil)
        center.addObserver(self,
                           selector: #selector(screenDidDisconnect(_:)),
                           name: UIScreen.didDisconnectNotification,
                           object: nil)
        // A display already connected at launch gets its window
        // now if the scene path has not provided one.
        for screen in UIScreen.screens where screen !== UIScreen.main {
            showWindow(for: screen)
        }
    }

    // MARK: Registry (shared with the scene delegate)

    func registeredWindow(for screen: UIScreen) -> UIWindow? {
        windows[ObjectIdentifier(screen)]
    }

    func register(window: UIWindow, for screen: UIScreen) {
        windows[ObjectIdentifier(screen)] = window
    }

    func deregister(screen: UIScreen) {
        windows.removeValue(forKey: ObjectIdentifier(screen))
    }

    // MARK: UIScreen fallback

    @objc private func screenDidConnect(_ notification: Notification) {
        guard let screen = notification.object as? UIScreen else { return }
        showWindow(for: screen)
    }

    @objc private func screenDidDisconnect(_ notification: Notification) {
        guard let screen = notification.object as? UIScreen else { return }
        if let w = windows.removeValue(forKey: ObjectIdentifier(screen)) {
            w.isHidden = true
            w.rootViewController = nil
        }
    }

    /// Creates the fallback window for a screen unless one is
    /// already registered (the one-window-per-display invariant).
    private func showWindow(for screen: UIScreen) {
        guard windows[ObjectIdentifier(screen)] == nil else { return }
        screen.overscanCompensation = .insetApplicationFrame
        let w = UIWindow(frame: screen.bounds)
        w.screen = screen
        w.rootViewController = UIHostingController(
            rootView: ExternalDisplayRootView(
                nativePixelSize: screen.nativeBounds.size))
        w.isHidden = false
        windows[ObjectIdentifier(screen)] = w
    }
}

// MARK: - Root view (state picker)

/// The external window's root: observes the hub's live-session
/// registry directly (this window lives outside the main scene's
/// SwiftUI environment, so the registry is reached through
/// `AppSessionHub.shared`, not `@EnvironmentObject`).
struct ExternalDisplayRootView: View {
    @ObservedObject private var registry = AppSessionHub.shared.liveSession
    let nativePixelSize: CGSize

    var body: some View {
        ZStack {
            Color(white: 0.08)
                .ignoresSafeArea()
            if let document = registry.schematicDocument {
                ExternalSchematicView(document: document)
            } else if let snapshot = registry.pcbSnapshot {
                ExternalBoardView(snapshot: snapshot)
            } else {
                ExternalIdleView(nativePixelSize: nativePixelSize)
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Idle state

struct ExternalIdleView: View {
    let nativePixelSize: CGSize

    var body: some View {
        VStack(spacing: 16) {
            Text("PadCB")
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text("Open the Schematic or PCB editor on the iPad — it appears here live.")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text("Display: \(Int(nativePixelSize.width)) × \(Int(nativePixelSize.height))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
        }
        .padding(48)
    }
}

// MARK: - Schematic mirror

/// The schematic editor's REAL document, rendered read-only by the
/// editor's own canvas. The canvas observes the document itself,
/// so edits made on the iPad redraw here automatically; hit
/// testing is off — this is a mirror, not a second editor.
struct ExternalSchematicView: View {
    @ObservedObject var document: SchematicDocument

    // Dummy interaction state: the canvas's init demands a tool
    // and a selection binding. The external view is passive, so it
    // parks the tool on Select and keeps selection permanently nil
    // in local state it owns. Placement is never armed
    // (pendingSymbol stays nil, chooser callbacks keep their
    // no-op defaults).
    @StateObject private var canvasState = CanvasViewState()
    @State private var tool: EditorTool = .select
    @State private var selection: UUID? = nil

    private var store: LibraryStore { AppSessionHub.shared.libraryStore }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("SCHEMATIC — LIVE")
                    .font(.callout.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(document.state.title)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(white: 0.13))

            GeometryReader { geo in
                SchematicCanvasView(
                    document: document,
                    store: store,
                    canvasState: canvasState,
                    tool: $tool,
                    selection: $selection
                )
                .allowsHitTesting(false)
                .onAppear {
                    canvasState.fit(state: document.state,
                                    store: store, size: geo.size)
                }
                .onChange(of: geo.size) { _, newSize in
                    canvasState.fit(state: document.state,
                                    store: store, size: newSize)
                }
            }
        }
    }
}

// MARK: - PCB mirror

/// The PCB session's latest published snapshot, rendered as a
/// fitted static board (zones, traces, vias, pads, graphics) with
/// a session-info sidebar. The snapshot is a value: the parent
/// root view observes the registry, so a fresh publish re-runs
/// this view's body with the new snapshot; the Canvas additionally
/// carries the snapshot's counts in its identity so a same-size
/// publish still redraws.
///
/// Teardrops (part 5.3, P6) render in the Canvas pass beside
/// `drawZones`: filled polygons in their layer's copper colour,
/// from `model.teardrops` (the merged BoardModel carries them).
struct ExternalBoardView: View {
    let snapshot: LiveSessionRegistry.PCBSnapshot

    private var model: BoardModel { snapshot.model }
    private var state: BoardState { snapshot.state }

    // MARK: Analysis (sidebar data)

    private struct Analysis {
        var connectivity: [String: NetConnectivity]
        var manufacturing: ManufacturingReport
    }

    /// Connectivity + manufacturing totals for the CURRENT
    /// snapshot, computed with the same public checkers the editor
    /// runs (BoardConnectivity / BoardManufacturing).
    private var analysis: Analysis {
        let copper = state.copperLayerCount
        let connectivity = BoardConnectivity.analyze(model: model,
                                                     copperCount: copper)
        var settings = ManufacturingSettings()
        settings.clearanceMil = state.clearanceMil
        let manufacturing = BoardManufacturing.check(
            model: model, copperCount: copper,
            settings: settings, connectivity: connectivity)
        return Analysis(connectivity: connectivity,
                        manufacturing: manufacturing)
    }

    /// Canvas identity: title + item counts, so a re-publish with
    /// the same view size still redraws.
    private var revision: String {
        "\(snapshot.title)|\(state.copperLayerCount)"
            + "|\(model.components.count)|\(model.traces.count)"
            + "|\(model.vias.count)|\(model.zones.count)"
            + "|\(model.graphics.count)|\(state.traces.count)"
            + "|\(model.teardrops.count)|\(state.teardrops.count)"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("PCB — LIVE")
                    .font(.callout.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(snapshot.title)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(white: 0.13))

            HStack(spacing: 0) {
                Canvas { ctx, size in
                    drawBoard(&ctx, size: size)
                }
                .id(revision)
                .background(Color(red: 0.043, green: 0.055, blue: 0.043))

                Divider()
                sidebar
                    .frame(width: 300)
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        let boardAnalysis = analysis
        let nets = boardAnalysis.connectivity.values
            .sorted { $0.netName < $1.netName }
        return VStack(alignment: .leading, spacing: 12) {
            Text("Board")
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)
            sidebarRow("Copper layers", "\(state.copperLayerCount)")
            sidebarRow("Footprints", "\(model.components.count)")
            sidebarRow("Traces", "\(model.traces.count)")
            sidebarRow("Vias", "\(model.vias.count)")
            sidebarRow("Zones", "\(model.zones.count)")

            Divider()

            Text("Manufacturing")
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(boardAnalysis.manufacturing.allPassed
                 ? "All \(boardAnalysis.manufacturing.rules.count) rules passed"
                 : "\(boardAnalysis.manufacturing.failedCount) of "
                   + "\(boardAnalysis.manufacturing.rules.count) rules failing")
                .font(.callout)
                .foregroundStyle(boardAnalysis.manufacturing.allPassed
                                 ? Color.green : Color.orange)
                .lineLimit(2)

            Divider()

            Text("Nets")
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(nets, id: \.netName) { net in
                        HStack(spacing: 8) {
                            Text(net.netName)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text("\(net.routedPadCount)/\(net.padCount) pads")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(net.isFullyRouted
                                                 ? Color.white.opacity(0.55)
                                                 : Color.orange)
                                .lineLimit(1)
                        }
                    }
                    if nets.isEmpty {
                        Text("No nets on this board.")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color(white: 0.11))
    }

    private func sidebarRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(value)
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
        }
    }

    // MARK: Layer colours (values copied from PCBEditorView)

    private static let namedLayerColors: [String: Color] = [
        "F.Cu": Color(red: 0.85, green: 0.25, blue: 0.2),
        "B.Cu": Color(red: 0.25, green: 0.45, blue: 0.9),
        "F.Adhes": Color(red: 0.7, green: 0.3, blue: 0.7),
        "B.Adhes": Color(red: 0.45, green: 0.3, blue: 0.7),
        "F.Paste": Color(red: 0.6, green: 0.6, blue: 0.65),
        "B.Paste": Color(red: 0.5, green: 0.55, blue: 0.7),
        "F.SilkS": Color(red: 0.95, green: 0.9, blue: 0.6),
        "B.SilkS": Color(red: 0.6, green: 0.75, blue: 0.75),
        "F.Mask": Color(red: 0.55, green: 0.2, blue: 0.55),
        "B.Mask": Color(red: 0.25, green: 0.35, blue: 0.6),
        "Dwgs.User": Color(red: 0.65, green: 0.65, blue: 0.65),
        "Edge.Cuts": Color(red: 0.95, green: 0.85, blue: 0.2),
        "F.CrtYd": Color(red: 0.8, green: 0.8, blue: 0.8),
        "B.CrtYd": Color(red: 0.55, green: 0.55, blue: 0.55),
        "F.Fab": Color(red: 0.75, green: 0.75, blue: 0.7),
        "B.Fab": Color(red: 0.5, green: 0.55, blue: 0.55),
    ]
    private static let innerCopperPalette: [Color] = [
        Color(red: 0.9, green: 0.6, blue: 0.2),
        Color(red: 0.6, green: 0.75, blue: 0.25),
        Color(red: 0.3, green: 0.7, blue: 0.6),
        Color(red: 0.65, green: 0.45, blue: 0.85),
    ]

    private func layerColor(_ name: String) -> Color {
        if let named = Self.namedLayerColors[name] { return named }
        if name.hasPrefix("In"), name.hasSuffix(".Cu") {
            let digits = name.dropFirst(2).dropLast(3)
            let number = Int(digits) ?? 1
            return Self.innerCopperPalette[
                (number - 1) % Self.innerCopperPalette.count]
        }
        return Color(red: 0.85, green: 0.3, blue: 0.25)
    }

    /// The editor's pad colour convention (PCBEditorView.padColor),
    /// called with the EFFECTIVE (side-flipped) pad.
    private func padColor(_ pad: KiCadFootprintPad) -> Color {
        if pad.type == .npThruHole { return .gray.opacity(0.8) }
        let hasFront = pad.layers.contains { $0.hasPrefix("F.") || $0 == "*.Cu" }
        let hasBack = pad.layers.contains { $0.hasPrefix("B.") || $0 == "*.Cu" }
        if pad.isThroughHole { return Color(red: 0.85, green: 0.55, blue: 0.2) }
        if hasFront && hasBack { return Color(red: 0.8, green: 0.4, blue: 0.7) }
        if hasBack && !hasFront { return Color(red: 0.3, green: 0.5, blue: 0.9) }
        return Color(red: 0.9, green: 0.45, blue: 0.25)
    }

    // MARK: Fit transform

    private struct Transform {
        var scale: CGFloat
        var minX: Double
        var minY: Double
        var marginX: CGFloat
        var marginY: CGFloat
        func point(_ p: FPPoint) -> CGPoint {
            CGPoint(x: marginX + CGFloat(p.x - minX) * scale,
                    y: marginY + CGFloat(p.y - minY) * scale)
        }
    }

    /// Fits the union of components / traces / vias / zones /
    /// graphics into the canvas with a margin, centred.
    private func makeTransform(size: CGSize) -> Transform {
        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude
        var found = false
        func include(_ p: FPPoint) {
            found = true
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        for component in model.components {
            let b = BoardGeometry.componentBounds(component)
            include(FPPoint(x: b.minX, y: b.minY))
            include(FPPoint(x: b.maxX, y: b.maxY))
        }
        for trace in model.traces { for p in trace.points { include(p) } }
        for via in model.vias {
            let r = via.diameter / 2
            include(FPPoint(x: via.center.x - r, y: via.center.y - r))
            include(FPPoint(x: via.center.x + r, y: via.center.y + r))
        }
        for zone in model.zones { for p in zone.points { include(p) } }
        for graphic in model.graphics { for p in graphic.points { include(p) } }

        guard found else {
            return Transform(scale: 4, minX: 0, minY: 0,
                             marginX: size.width / 2, marginY: size.height / 2)
        }
        let pad = 6.0
        minX -= pad; maxX += pad; minY -= pad; maxY += pad
        let w = max(maxX - minX, 1), h = max(maxY - minY, 1)
        let margin: CGFloat = 24
        let scale = min((size.width - 2 * margin) / CGFloat(w),
                        (size.height - 2 * margin) / CGFloat(h))
        let usedW = CGFloat(w) * scale, usedH = CGFloat(h) * scale
        return Transform(scale: scale, minX: minX, minY: minY,
                         marginX: (size.width - usedW) / 2,
                         marginY: (size.height - usedH) / 2)
    }

    // MARK: Canvas passes

    private func drawBoard(_ ctx: inout GraphicsContext, size: CGSize) {
        let t = makeTransform(size: size)
        drawZones(&ctx, t: t)
        drawTeardrops(&ctx, t: t)
        drawFootprintGraphics(&ctx, t: t)
        drawBoardGraphics(&ctx, t: t)
        drawTraces(&ctx, t: t)
        drawVias(&ctx, t: t)
        drawPads(&ctx, t: t)
    }

    private func drawZones(_ ctx: inout GraphicsContext, t: Transform) {
        for zone in model.zones where zone.points.count >= 3 {
            var path = Path()
            for (index, p) in zone.points.enumerated() {
                let s = t.point(p)
                if index == 0 { path.move(to: s) } else { path.addLine(to: s) }
            }
            path.closeSubpath()
            let color = layerColor(zone.layer)
            ctx.fill(path, with: .color(color.opacity(0.28)))
            ctx.stroke(path, with: .color(color.opacity(0.9)),
                       style: StrokeStyle(lineWidth: 1))
        }
    }

    private func drawTeardrops(_ ctx: inout GraphicsContext, t: Transform) {
        for teardrop in model.teardrops where teardrop.points.count >= 3 {
            var path = Path()
            for (index, p) in teardrop.points.enumerated() {
                let s = t.point(p)
                if index == 0 { path.move(to: s) } else { path.addLine(to: s) }
            }
            path.closeSubpath()
            ctx.fill(path, with: .color(layerColor(teardrop.layer).opacity(0.9)))
        }
    }

    private func drawTraces(_ ctx: inout GraphicsContext, t: Transform) {
        for trace in model.traces where trace.points.count >= 2 {
            var path = Path()
            for (index, p) in trace.points.enumerated() {
                let s = t.point(p)
                if index == 0 { path.move(to: s) } else { path.addLine(to: s) }
            }
            let disconnected = trace.netName == nil
            let color = disconnected ? Color(white: 0.55)
                                     : layerColor(trace.layer)
            ctx.stroke(path, with: .color(color),
                       style: StrokeStyle(
                           lineWidth: max(1, CGFloat(trace.width) * t.scale),
                           lineCap: .round, lineJoin: .round,
                           dash: disconnected ? [6, 4] : []))
        }
    }

    private func drawVias(_ ctx: inout GraphicsContext, t: Transform) {
        for via in model.vias {
            let centre = t.point(via.center)
            let d = CGFloat(via.diameter) * t.scale
            let rect = CGRect(x: centre.x - d / 2, y: centre.y - d / 2,
                              width: d, height: d)
            ctx.fill(Path(ellipseIn: rect),
                     with: .color(Color(red: 1.0, green: 0.85, blue: 0.2)))
            let drill = CGFloat(via.drill) * t.scale
            let drillRect = CGRect(x: centre.x - drill / 2,
                                   y: centre.y - drill / 2,
                                   width: drill, height: drill)
            ctx.fill(Path(ellipseIn: drillRect),
                     with: .color(Color(red: 0.043, green: 0.055, blue: 0.043)))
        }
    }

    private func drawPads(_ ctx: inout GraphicsContext, t: Transform) {
        for component in model.components {
            guard let footprint = component.footprint else {
                // Unresolved footprint: stroked placeholder box at
                // the component's bounds (the editor's convention).
                let b = BoardGeometry.componentBounds(component)
                let tl = t.point(FPPoint(x: b.minX, y: b.minY))
                let rect = CGRect(x: tl.x, y: tl.y,
                                  width: CGFloat(b.maxX - b.minX) * t.scale,
                                  height: CGFloat(b.maxY - b.minY) * t.scale)
                ctx.stroke(Path(rect), with: .color(.orange.opacity(0.8)),
                           style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                continue
            }
            for pad in footprint.pads {
                let effective = BoardGeometry.boardPad(component, pad)
                let centre = t.point(BoardGeometry.padCenter(component, pad))
                let w = CGFloat(effective.width) * t.scale
                let h = CGFloat(effective.height) * t.scale
                var pctx = ctx
                pctx.translateBy(x: centre.x, y: centre.y)
                pctx.rotate(by: .degrees(effective.rotation))
                let rect = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
                let color = padColor(effective)
                switch effective.shape {
                case .circle, .oval:
                    pctx.fill(Path(ellipseIn: rect), with: .color(color))
                case .roundrect:
                    let ratio = CGFloat(effective.roundrectRatio ?? 0.25)
                    let radius = min(w, h) / 2 * min(max(ratio, 0), 0.5) * 2
                    pctx.fill(Path(roundedRect: rect, cornerRadius: radius),
                              with: .color(color))
                case .trapezoid, .custom, .rect:
                    pctx.fill(Path(rect), with: .color(color))
                }
                if let drill = effective.drill {
                    let dw = CGFloat(drill.width) * t.scale
                    let dh = CGFloat(drill.height) * t.scale
                    let drillRect = CGRect(
                        x: CGFloat(drill.offsetX) * t.scale - dw / 2,
                        y: CGFloat(drill.offsetY) * t.scale - dh / 2,
                        width: dw, height: dh)
                    pctx.fill(Path(ellipseIn: drillRect),
                              with: .color(Color(red: 0.043,
                                                 green: 0.055, blue: 0.043)))
                }
            }
            // Reference label at the component's top-left.
            let b = BoardGeometry.componentBounds(component)
            let anchor = t.point(FPPoint(x: b.minX, y: b.minY))
            ctx.draw(Text(component.reference)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85)),
                     at: CGPoint(x: anchor.x, y: anchor.y - 4),
                     anchor: UnitPoint(x: 0, y: 1))
        }
    }

    /// Footprint graphics as thin strokes (line / rect / circle /
    /// poly true paths; arcs approximated by a quadratic through
    /// the mid point and curves by their cubic — this is a mirror
    /// view, not the editor's hit-tested rendering).
    private func drawFootprintGraphics(_ ctx: inout GraphicsContext,
                                       t: Transform) {
        for component in model.components {
            guard let footprint = component.footprint else { continue }
            for graphic in footprint.graphics {
                let effective = BoardGeometry.boardGraphic(component, graphic)
                let color = layerColor(effective.layer)
                func map(_ p: FPPoint) -> CGPoint {
                    t.point(BoardGeometry.localToBoard(component, p))
                }
                switch effective {
                case .line(let a, let b, _, _, _, _):
                    var path = Path()
                    path.move(to: map(a)); path.addLine(to: map(b))
                    ctx.stroke(path, with: .color(color),
                               style: StrokeStyle(lineWidth: 1))
                case .rect(let a, let b, _, _, _, _):
                    let pa = map(a), pb = map(b)
                    let rect = CGRect(x: min(pa.x, pb.x), y: min(pa.y, pb.y),
                                      width: abs(pb.x - pa.x),
                                      height: abs(pb.y - pa.y))
                    ctx.stroke(Path(rect), with: .color(color),
                               style: StrokeStyle(lineWidth: 1))
                case .circle(let c, let r, _, _, _, _):
                    let centre = map(c)
                    let d = CGFloat(r * 2) * t.scale
                    let rect = CGRect(x: centre.x - d / 2, y: centre.y - d / 2,
                                      width: d, height: d)
                    ctx.stroke(Path(ellipseIn: rect), with: .color(color),
                               style: StrokeStyle(lineWidth: 1))
                case .arc(let a, let m, let b, _, _, _, _):
                    var path = Path()
                    path.move(to: map(a))
                    path.addQuadCurve(to: map(b), control: map(m))
                    ctx.stroke(path, with: .color(color),
                               style: StrokeStyle(lineWidth: 1))
                case .poly(let points, _, _, _, _):
                    guard points.count >= 2 else { continue }
                    var path = Path()
                    for (index, p) in points.enumerated() {
                        let s = map(p)
                        if index == 0 { path.move(to: s) }
                        else { path.addLine(to: s) }
                    }
                    path.closeSubpath()
                    ctx.stroke(path, with: .color(color),
                               style: StrokeStyle(lineWidth: 1))
                case .curve(let p1, let p2, let p3, let p4, _, _, _, _):
                    var path = Path()
                    path.move(to: map(p1))
                    path.addCurve(to: map(p4), control1: map(p2),
                                  control2: map(p3))
                    ctx.stroke(path, with: .color(color),
                               style: StrokeStyle(lineWidth: 1))
                case .text(let text):
                    guard !text.hidden, !text.text.isEmpty else { continue }
                    let anchor = map(FPPoint(x: text.x, y: text.y))
                    ctx.draw(Text(text.text)
                                .font(.system(size: max(7, CGFloat(text.size) * t.scale)))
                                .foregroundColor(color),
                             at: anchor, anchor: .center)
                }
            }
        }
    }

    /// Board graphics (Draw Line / Arc / Circle / Text items) as
    /// thin strokes in their layer colour.
    private func drawBoardGraphics(_ ctx: inout GraphicsContext,
                                   t: Transform) {
        for graphic in model.graphics {
            let color = layerColor(graphic.layer)
            let lineWidth = max(1, CGFloat(graphic.strokeWidth) * t.scale)
            switch graphic.kind {
            case .line:
                guard graphic.points.count >= 2 else { continue }
                var path = Path()
                path.move(to: t.point(graphic.points[0]))
                path.addLine(to: t.point(graphic.points[1]))
                ctx.stroke(path, with: .color(color),
                           style: StrokeStyle(lineWidth: lineWidth))
            case .arc:
                guard graphic.points.count >= 3 else { continue }
                var path = Path()
                path.move(to: t.point(graphic.points[0]))
                path.addQuadCurve(to: t.point(graphic.points[2]),
                                  control: t.point(graphic.points[1]))
                ctx.stroke(path, with: .color(color),
                           style: StrokeStyle(lineWidth: lineWidth))
            case .circle:
                guard let centreFP = graphic.points.first else { continue }
                let centre = t.point(centreFP)
                let d = CGFloat(graphic.radius * 2) * t.scale
                let rect = CGRect(x: centre.x - d / 2, y: centre.y - d / 2,
                                  width: d, height: d)
                ctx.stroke(Path(ellipseIn: rect), with: .color(color),
                           style: StrokeStyle(lineWidth: lineWidth))
            case .text:
                guard let anchorFP = graphic.points.first,
                      !graphic.text.isEmpty else { continue }
                ctx.draw(Text(graphic.text)
                            .font(.system(size: max(7, CGFloat(graphic.textSize) * t.scale)))
                            .foregroundColor(color),
                         at: t.point(anchorFP), anchor: .center)
            }
        }
    }
}
