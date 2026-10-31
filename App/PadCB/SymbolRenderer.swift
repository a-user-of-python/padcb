import SwiftUI

/// Renders KiCad symbol definitions and computes pin/bounds geometry.
///
/// Coordinate notes: symbol-local coordinates are millimetres, y-UP, exactly
/// as stored in .kicad_sym files. `draw` receives a `map` closure that takes a
/// LOCAL point to the drawing (screen/canvas) point — all y-flipping and
/// placement transforms live inside that closure, never here. Placement (world)
/// transforms also keep y-UP: `world = origin + R(rotation) * Mirror * local`.
enum SymbolRenderer {

    // MARK: Colors (KiCad-ish)

    static let outlineColor = Color(red: 0.478, green: 0.122, blue: 0.122) // #7A1F1F
    static let bodyFillColor = Color(red: 1.0, green: 0.98, blue: 0.85).opacity(0.9)
    static let pinNumberColor = Color(red: 0.55, green: 0.08, blue: 0.08)
    static let pinNameColor = Color(red: 0.30, green: 0.08, blue: 0.08)

    /// KiCad inversion bubble radius (mm).
    private static let bubbleRadius = 0.3

    // MARK: Placement transform

    /// Applies mirror, then rotation (CCW, degrees), then translation.
    static func transformPoint(_ p: DPoint, placed: PlacedSymbol) -> DPoint {
        let mx = placed.mirrorX ? -p.x : p.x
        let my = placed.mirrorY ? -p.y : p.y
        let rad = Double(placed.rotation) * Double.pi / 180.0
        let c = cos(rad), s = sin(rad)
        return DPoint(x: placed.x + mx * c - my * s,
                      y: placed.y + mx * s + my * c)
    }

    /// Transforms a local direction vector (no translation).
    static func transformDirection(_ d: DPoint, placed: PlacedSymbol) -> DPoint {
        let mx = placed.mirrorX ? -d.x : d.x
        let my = placed.mirrorY ? -d.y : d.y
        let rad = Double(placed.rotation) * Double.pi / 180.0
        let c = cos(rad), s = sin(rad)
        return DPoint(x: mx * c - my * s, y: mx * s + my * c)
    }

    // MARK: Unit merging helpers

    private static func mergedUnits(def: KiCadSymbolDef, unit: Int) -> [KiCadUnitDef] {
        var out: [KiCadUnitDef] = []
        if let common = def.units[0] { out.append(common) }
        if unit != 0, let u = def.units[unit] { out.append(u) }
        return out
    }

    // MARK: Pins

    static func pinLocalPoints(def: KiCadSymbolDef, unit: Int) -> [(pin: KiCadPin, point: CGPoint)] {
        var out: [(pin: KiCadPin, point: CGPoint)] = []
        for u in mergedUnits(def: def, unit: unit) {
            for pin in u.pins {
                out.append((pin: pin, point: CGPoint(x: CGFloat(pin.x), y: CGFloat(pin.y))))
            }
        }
        return out
    }

    static func pinWorldPoints(def: KiCadSymbolDef, placed: PlacedSymbol) -> [(pin: KiCadPin, point: DPoint)] {
        pinLocalPoints(def: def, unit: placed.unit).map { entry in
            (pin: entry.pin,
             point: transformPoint(DPoint(x: Double(entry.point.x), y: Double(entry.point.y)), placed: placed))
        }
    }

    // MARK: Bounds

    /// Union of graphic bounds for units 0 and `unit`, in local coords.
    /// Text extents are approximated (length * size * 0.6). If the symbol has
    /// no graphics at all, falls back to the bounds of its pin points.
    static func graphicsBounds(def: KiCadSymbolDef, unit: Int) -> CGRect {
        var rect: CGRect?
        func include(_ r: CGRect) { rect = rect.map { $0.union(r) } ?? r }
        func includePt(_ x: Double, _ y: Double) {
            include(CGRect(x: CGFloat(x), y: CGFloat(y), width: 0, height: 0))
        }
        func includePts(_ pts: [(Double, Double)]) {
            guard let first = pts.first else { return }
            var minX = first.0, maxX = first.0, minY = first.1, maxY = first.1
            for p in pts.dropFirst() {
                minX = min(minX, p.0); maxX = max(maxX, p.0)
                minY = min(minY, p.1); maxY = max(maxY, p.1)
            }
            include(CGRect(x: CGFloat(minX), y: CGFloat(minY),
                           width: CGFloat(maxX - minX), height: CGFloat(maxY - minY)))
        }

        for u in mergedUnits(def: def, unit: unit) {
            for g in u.graphics {
                switch g {
                case .rectangle(let x1, let y1, let x2, let y2, _, _, _):
                    include(CGRect(x: CGFloat(min(x1, x2)), y: CGFloat(min(y1, y2)),
                                   width: CGFloat(abs(x2 - x1)), height: CGFloat(abs(y2 - y1))))
                case .circle(let cx, let cy, let r, _, _, _):
                    include(CGRect(x: CGFloat(cx - r), y: CGFloat(cy - r),
                                   width: CGFloat(2 * r), height: CGFloat(2 * r)))
                case .arc(let sx, let sy, let mx, let my, let ex, let ey, _, _, _):
                    includePts([(sx, sy), (mx, my), (ex, ey)])
                case .polyline(let points, _, _, _):
                    includePts(points)
                case .bezier(let p1, let p2, let p3, let p4, _, _, _):
                    includePts([p1, p2, p3, p4]) // control-hull approximation
                case .text(let string, let x, let y, _, let size, _, _, _, _):
                    let w = Double(string.count) * size * 0.6
                    include(CGRect(x: CGFloat(x - w / 2), y: CGFloat(y - size / 2),
                                   width: CGFloat(w), height: CGFloat(size)))
                case .textBox(_, let x, let y, let w, let h, _, _, _, _, _, _, _, _, _):
                    include(CGRect(x: CGFloat(min(x, x + w)), y: CGFloat(min(y, y + h)),
                                   width: CGFloat(abs(w)), height: CGFloat(abs(h))))
                }
            }
        }
        if let rect { return rect }

        // No graphics: fall back to pin point bounds.
        let pins = pinLocalPoints(def: def, unit: unit)
        if !pins.isEmpty {
            var r = CGRect(x: pins[0].point.x, y: pins[0].point.y, width: 0, height: 0)
            for p in pins.dropFirst() {
                r = r.union(CGRect(x: p.point.x, y: p.point.y, width: 0, height: 0))
            }
            return r
        }
        return CGRect(x: -2.54, y: -2.54, width: 5.08, height: 5.08)
    }

    /// World-space bounds of a placed symbol's body graphics.
    static func placedBounds(def: KiCadSymbolDef, placed: PlacedSymbol) -> CGRect {
        let b = graphicsBounds(def: def, unit: placed.unit)
        let corners = [
            DPoint(x: Double(b.minX), y: Double(b.minY)),
            DPoint(x: Double(b.maxX), y: Double(b.minY)),
            DPoint(x: Double(b.minX), y: Double(b.maxY)),
            DPoint(x: Double(b.maxX), y: Double(b.maxY)),
        ].map { transformPoint($0, placed: placed) }
        var minX = corners[0].x, maxX = corners[0].x
        var minY = corners[0].y, maxY = corners[0].y
        for p in corners.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: CGFloat(minX), y: CGFloat(minY),
                      width: CGFloat(maxX - minX), height: CGFloat(maxY - minY))
    }

    // MARK: - Drawing

    static func draw(def: KiCadSymbolDef, unit: Int, in ctx: GraphicsContext,
                     map: (CGPoint) -> CGPoint, scale: CGFloat,
                     showPinNumbers: Bool, showPinNames: Bool) {
        var ctx = ctx

        // Linear part of `map`, recovered by probing — used to orient text
        // and pin glyphs under rotation / mirroring / y-flip.
        let origin = map(.zero)
        let ex = map(CGPoint(x: 1, y: 0))
        let ey = map(CGPoint(x: 0, y: 1))
        let bx = CGPoint(x: ex.x - origin.x, y: ex.y - origin.y) // screen dir of local +x
        let by = CGPoint(x: ey.x - origin.x, y: ey.y - origin.y) // screen dir of local +y
        func screenDir(_ dx: Double, _ dy: Double) -> CGPoint {
            CGPoint(x: bx.x * CGFloat(dx) + by.x * CGFloat(dy),
                    y: bx.y * CGFloat(dx) + by.y * CGFloat(dy))
        }
        func lp(_ x: Double, _ y: Double) -> CGPoint { map(CGPoint(x: CGFloat(x), y: CGFloat(y))) }

        // --- Graphics (units 0 + unit) ---
        for u in mergedUnits(def: def, unit: unit) {
            for g in u.graphics {
                switch g {
                case .rectangle(let x1, let y1, let x2, let y2, let w, let t, let f):
                    var path = Path()
                    path.move(to: lp(x1, y1))
                    path.addLine(to: lp(x2, y1))
                    path.addLine(to: lp(x2, y2))
                    path.addLine(to: lp(x1, y2))
                    path.closeSubpath()
                    finish(&ctx, path: path, widthMM: w, type: t, fill: f, scale: scale)

                case .circle(let cx, let cy, let r, let w, let t, let f):
                    let c = lp(cx, cy)
                    let rp = CGFloat(r) * scale
                    let path = Path(ellipseIn: CGRect(x: c.x - rp, y: c.y - rp, width: 2 * rp, height: 2 * rp))
                    finish(&ctx, path: path, widthMM: w, type: t, fill: f, scale: scale)

                case .arc(let sx, let sy, let mx, let my, let exx, let ey2, let w, let t, let f):
                    let path = arcPath(a: lp(sx, sy), m: lp(mx, my), e: lp(exx, ey2))
                    finish(&ctx, path: path, widthMM: w, type: t, fill: f, scale: scale)

                case .polyline(let points, let w, let t, let f):
                    guard let first = points.first else { continue }
                    var path = Path()
                    path.move(to: lp(first.0, first.1))
                    for p in points.dropFirst() { path.addLine(to: lp(p.0, p.1)) }
                    finish(&ctx, path: path, widthMM: w, type: t, fill: f, scale: scale)

                case .bezier(let p1, let p2, let p3, let p4, let w, let t, let f):
                    var path = Path()
                    path.move(to: lp(p1.0, p1.1))
                    path.addCurve(to: lp(p4.0, p4.1), control1: lp(p2.0, p2.1), control2: lp(p3.0, p3.1))
                    finish(&ctx, path: path, widthMM: w, type: t, fill: f, scale: scale)

                case .text(let string, let x, let y, let rotation, let size, let bold, let italic, let hJustify, let vJustify):
                    let rad = rotation * Double.pi / 180.0
                    let dir = screenDir(cos(rad), sin(rad))
                    let angle = atan2(Double(dir.y), Double(dir.x))
                    let anchor = UnitPoint(x: hJustify == "left" ? 0 : (hJustify == "right" ? 1 : 0.5),
                                           y: vJustify == "top" ? 0 : (vJustify == "bottom" ? 1 : 0.5))
                    KiCadText.draw(in: &ctx, string, at: lp(x, y),
                                   size: max(CGFloat(size) * scale, 6),
                                   color: outlineColor, angle: angle, anchor: anchor,
                                   bold: bold, italic: italic)

                case .textBox(let string, let x, let y, let w, let h, let rotation, let size, let bold, let italic, let hJustify, _, let sw, let st, let f):
                    var box = Path()
                    box.move(to: lp(x, y))
                    box.addLine(to: lp(x + w, y))
                    box.addLine(to: lp(x + w, y + h))
                    box.addLine(to: lp(x, y + h))
                    box.closeSubpath()
                    finish(&ctx, path: box, widthMM: sw, type: st, fill: f, scale: scale)
                    // Text lines stacked inside the box, centred as a
                    // block on the box centre; per-line horizontal
                    // placement follows the box's justification.
                    let lines = string
                        .components(separatedBy: "\n")
                        .flatMap { $0.components(separatedBy: "\\n") }
                    if !lines.isEmpty {
                        let rad = rotation * Double.pi / 180.0
                        let dir = screenDir(cos(rad), sin(rad))
                        let angle = atan2(Double(dir.y), Double(dir.x))
                        let lineStep = size * 1.25
                        let topY = max(y, y + h)
                        for (index, line) in lines.enumerated() where !line.isEmpty {
                            let lineCenterY = topY - (Double(index) + 0.5) * lineStep
                            let anchorX: Double
                            let anchor: UnitPoint
                            switch hJustify {
                            case "left":
                                anchorX = min(x, x + w) + size * 0.4
                                anchor = UnitPoint(x: 0, y: 0.5)
                            case "right":
                                anchorX = max(x, x + w) - size * 0.4
                                anchor = UnitPoint(x: 1, y: 0.5)
                            default:
                                anchorX = x + w / 2
                                anchor = UnitPoint(x: 0.5, y: 0.5)
                            }
                            KiCadText.draw(in: &ctx, line, at: lp(anchorX, lineCenterY),
                                           size: max(CGFloat(size) * scale, 6),
                                           color: outlineColor, angle: angle, anchor: anchor,
                                           bold: bold, italic: italic)
                        }
                    }
                }
            }
        }

        // --- Pins ---
        for (pin, local) in pinLocalPoints(def: def, unit: unit) where !pin.hidden {
            let rad = pin.rotation * Double.pi / 180.0
            // dir points from the connection point toward the body: KiCad's
            // parser maps the file angle to an orientation whose root (the
            // body-side stub end, SCH_PIN::GetPinRoot()) lies at
            // conn + dir * length in file (y-UP) coordinates.
            let dirx = cos(rad), diry = sin(rad)
            let conn = local
            let inner = CGPoint(x: conn.x + CGFloat(dirx * pin.length),
                                y: conn.y + CGFloat(diry * pin.length)) // body-side stub end (local)

            // Stub: connection point toward the body.
            if pin.length > 0 {
                var stub = Path()
                stub.move(to: map(conn))
                stub.addLine(to: map(inner))
                ctx.stroke(stub, with: .color(outlineColor),
                           style: strokeStyle(widthMM: 0, type: "solid", scale: scale, minPoints: 0.75))
            }

            // Shape glyphs.
            let perp = CGPoint(x: CGFloat(-diry), y: CGFloat(dirx)) // local, +90° from dir
            func localPt(_ base: CGPoint, _ alongDir: Double, _ alongPerp: Double) -> CGPoint {
                CGPoint(x: base.x + CGFloat(dirx * alongDir + Double(perp.x) * alongPerp),
                        y: base.y + CGFloat(diry * alongDir + Double(perp.y) * alongPerp))
            }
            switch pin.shape {
            case .inverted, .invertedClock:
                // Bubble just inside the body, tangent to the stub end:
                // its centre lies one radius beyond the root, along +dir.
                let center = localPt(inner, bubbleRadius, 0)
                let c = map(center)
                let rp = CGFloat(bubbleRadius) * scale
                let circle = Path(ellipseIn: CGRect(x: c.x - rp, y: c.y - rp, width: 2 * rp, height: 2 * rp))
                ctx.fill(circle, with: .color(.white))
                ctx.stroke(circle, with: .color(outlineColor),
                           style: strokeStyle(widthMM: 0, type: "solid", scale: scale, minPoints: 0.75))
                if pin.shape == .invertedClock {
                    // Clock wedge beyond the bubble, further along +dir.
                    drawClockWedge(&ctx, tipBase: localPt(inner, 2 * bubbleRadius, 0),
                                   dirx: dirx, diry: diry, localPt: localPt, map: map, scale: scale)
                }
            case .clock, .clockLow, .edgeClockHigh:
                drawClockWedge(&ctx, tipBase: inner, dirx: dirx, diry: diry,
                               localPt: localPt, map: map, scale: scale)
            case .nonLogic:
                // Small x centred at the root (inner stub end).
                let d = 0.3
                var xPath = Path()
                xPath.move(to: map(localPt(inner, -d, -d)))
                xPath.addLine(to: map(localPt(inner, d, d)))
                xPath.move(to: map(localPt(inner, -d, d)))
                xPath.addLine(to: map(localPt(inner, d, -d)))
                ctx.stroke(xPath, with: .color(outlineColor),
                           style: strokeStyle(widthMM: 0, type: "solid", scale: scale, minPoints: 0.75))
            default:
                break // line / input_low / output_low etc: plain stub
            }

            // No-connect pins carry a small x at the CONNECTION point
            // (KiCad's PT_NC branch draws the cross at the pin position,
            // independently of the pin's shape glyph above).
            if pin.type == .noConnect {
                let d = 0.3
                var ncPath = Path()
                ncPath.move(to: map(localPt(conn, -d, -d)))
                ncPath.addLine(to: map(localPt(conn, d, d)))
                ncPath.move(to: map(localPt(conn, -d, d)))
                ncPath.addLine(to: map(localPt(conn, d, -d)))
                ctx.stroke(ncPath, with: .color(outlineColor),
                           style: strokeStyle(widthMM: 0, type: "solid", scale: scale, minPoints: 0.75))
            }

            // Pin number: near the stub, offset perpendicular from its middle.
            if showPinNumbers && !pin.number.isEmpty {
                let midLocal = CGPoint(x: conn.x + CGFloat(dirx * pin.length / 2),
                                       y: conn.y + CGFloat(diry * pin.length / 2))
                let off = pin.numberSize * 0.8 + 0.1
                let posLocal = CGPoint(x: midLocal.x + CGFloat(-diry * off),
                                       y: midLocal.y + CGFloat(dirx * off))
                let dirS = screenDir(dirx, diry)
                var angle = atan2(Double(dirS.y), Double(dirS.x))
                if angle > Double.pi / 2 { angle -= Double.pi }
                if angle < -Double.pi / 2 { angle += Double.pi }
                drawText(&ctx, pin.number, at: map(posLocal),
                         size: max(CGFloat(pin.numberSize) * scale, 5.5),
                         color: pinNumberColor, angle: angle, anchor: .center,
                         bold: false, italic: false)
            }

            // Pin name: inside the body, starting pinNameOffset beyond the
            // inner stub end, extending along +dir (into the body).
            if showPinNames && !pin.name.isEmpty && pin.name != "~" {
                let anchorLocal = CGPoint(x: inner.x + CGFloat(dirx * def.pinNameOffset),
                                          y: inner.y + CGFloat(diry * def.pinNameOffset))
                let inward = screenDir(dirx, diry)
                var angle = atan2(Double(inward.y), Double(inward.x))
                var anchor: UnitPoint = .leading
                if cos(angle) < 0 { // text would run right-to-left; flip so it reads into the body
                    angle += Double.pi
                    anchor = .trailing
                }
                KiCadText.draw(in: &ctx, pin.name, at: map(anchorLocal),
                               size: max(CGFloat(pin.nameSize) * scale, 6),
                               color: pinNameColor, angle: angle, anchor: anchor,
                               bold: false, italic: false)
            }
        }
    }

    // MARK: Drawing helpers

    private static func fillColor(_ fill: String) -> Color {
        switch fill {
        case "background": return bodyFillColor
        // KiCad's "outline" fill = filled with the symbol outline (pen)
        // colour — 5,813 elements in the 10.0.1 corpus (solid arrowheads,
        // logo shapes, filled dots). It fell through to .clear before
        // part 1.2, so those shapes rendered hollow. "foreground" is
        // the pre-10 spelling of the same thing.
        case "foreground", "outline": return outlineColor
        default:
            // "color=R,G,B,A" token produced by KiCadSymbol.fillOf for
            // (fill (type color) (color R G B A)): R/G/B are 0-255,
            // A is 0-1.
            if fill.hasPrefix("color=") {
                let parts = fill.dropFirst("color=".count)
                    .split(separator: ",")
                    .compactMap { Double($0) }
                if parts.count == 4 {
                    return Color(red: parts[0] / 255, green: parts[1] / 255,
                                 blue: parts[2] / 255, opacity: parts[3])
                }
            }
            return .clear
        }
    }

    private static func finish(_ ctx: inout GraphicsContext, path: Path,
                               widthMM: Double, type: String, fill: String, scale: CGFloat) {
        if fill != "none" {
            ctx.fill(path, with: .color(fillColor(fill)))
        }
        ctx.stroke(path, with: .color(outlineColor),
                   style: strokeStyle(widthMM: widthMM, type: type, scale: scale, minPoints: 1.0))
    }

    /// Stroke style for a KiCad stroke. "default" is treated exactly like
    /// "solid" (KiCad 10 files emit it). Dash/dot patterns scale with zoom.
    static func strokeStyle(widthMM: Double, type: String, scale: CGFloat, minPoints: CGFloat) -> StrokeStyle {
        let w = max(max(widthMM, 0.05) * Double(scale), Double(minPoints))
        let u = max(Double(scale), 1.0) / 2.0
        switch type {
        case "dash":
            return StrokeStyle(lineWidth: CGFloat(w), lineCap: .butt, lineJoin: .round,
                               dash: [CGFloat(4 * u), CGFloat(2 * u)])
        case "dot":
            return StrokeStyle(lineWidth: CGFloat(w), lineCap: .round, lineJoin: .round,
                               dash: [CGFloat(0.5 * u), CGFloat(2 * u)])
        case "dash_dot", "dot_dash":
            return StrokeStyle(lineWidth: CGFloat(w), lineCap: .butt, lineJoin: .round,
                               dash: [CGFloat(4 * u), CGFloat(2 * u), CGFloat(0.5 * u), CGFloat(2 * u)])
        default: // "solid", "default", anything else
            return StrokeStyle(lineWidth: CGFloat(w), lineCap: .round, lineJoin: .round)
        }
    }

    /// Small open triangle at a pin's inner end (clock edge marker):
    /// base corners at tipBase ± perp * 0.3, apex at tipBase + dir * 0.6
    /// (pointing into the body, along +dir).
    private static func drawClockWedge(_ ctx: inout GraphicsContext, tipBase: CGPoint,
                                       dirx: Double, diry: Double,
                                       localPt: (CGPoint, Double, Double) -> CGPoint,
                                       map: (CGPoint) -> CGPoint, scale: CGFloat) {
        var path = Path()
        path.move(to: map(localPt(tipBase, 0, 0.3)))
        path.addLine(to: map(localPt(tipBase, 0.6, 0)))
        path.addLine(to: map(localPt(tipBase, 0, -0.3)))
        ctx.stroke(path, with: .color(outlineColor),
                   style: strokeStyle(widthMM: 0, type: "solid", scale: scale, minPoints: 0.75))
    }

    private static func drawText(_ ctx: inout GraphicsContext, _ string: String, at pt: CGPoint,
                                 size: CGFloat, color: Color, angle: Double, anchor: UnitPoint,
                                 bold: Bool, italic: Bool) {
        var text = Text(string)
            .font(.system(size: size, weight: bold ? .bold : .regular))
            .foregroundColor(color)
        if italic { text = text.italic() }
        var c = ctx
        c.translateBy(x: pt.x, y: pt.y)
        if angle != 0 { c.rotate(by: .radians(angle)) }
        c.draw(text, at: .zero, anchor: anchor)
    }

    /// Arc through three SCREEN-space points, computed via the circumcenter
    /// and sampled as short line segments along the sweep that passes
    /// through the mid point (avoids addArc direction ambiguity under the
    /// y-flipped canvas transform).
    static func arcPath(a: CGPoint, m: CGPoint, e: CGPoint) -> Path {
        var path = Path()
        path.move(to: a)
        let d = 2 * (a.x * (m.y - e.y) + m.x * (e.y - a.y) + e.x * (a.y - m.y))
        if abs(d) < 1e-9 {
            path.addLine(to: m)
            path.addLine(to: e)
            return path
        }
        let aSq = a.x * a.x + a.y * a.y
        let mSq = m.x * m.x + m.y * m.y
        let eSq = e.x * e.x + e.y * e.y
        let cx = (aSq * (m.y - e.y) + mSq * (e.y - a.y) + eSq * (a.y - m.y)) / d
        let cy = (aSq * (e.x - m.x) + mSq * (a.x - e.x) + eSq * (m.x - a.x)) / d
        let r = hypot(a.x - cx, a.y - cy)
        let a0 = Double(atan2(a.y - cy, a.x - cx))
        let am = Double(atan2(m.y - cy, m.x - cx))
        let a1 = Double(atan2(e.y - cy, e.x - cx))
        func norm(_ v: Double) -> Double {
            var v = v.truncatingRemainder(dividingBy: 2 * Double.pi)
            if v < 0 { v += 2 * Double.pi }
            return v
        }
        let sweepPos = norm(a1 - a0)          // counter-clockwise (raw coords) sweep start->end
        let midPos = norm(am - a0)            // where the mid point sits on that sweep
        let sweep = midPos <= sweepPos + 1e-9 ? sweepPos : -(2 * Double.pi - sweepPos)
        let steps = max(4, Int(abs(sweep) / (Double.pi / 36)) + 1)
        for i in 1...steps {
            let t = a0 + sweep * Double(i) / Double(steps)
            path.addLine(to: CGPoint(x: cx + r * CGFloat(cos(t)), y: cy + r * CGFloat(sin(t))))
        }
        return path
    }
}

// MARK: - KiCad text markup

/// KiCad text markup (see KiCad's markup_parser grammar): `_{...}` is a
/// subscript, `^{...}` a superscript and `~{...}` an overbar. Braced
/// content may itself contain markup, and the flags combine under
/// nesting. A lone `{identifier}` is an escape sequence and renders as
/// the bare identifier. Unmatched braces degrade gracefully to literal
/// text. This is an original implementation of those semantics, used for
/// pin names (e.g. `IN_{BIAS}`, `V_{SO+}`) and graphic text elements.
enum KiCadText {
    struct Run: Equatable { var text: String; var sub: Bool = false; var sup: Bool = false; var overbar: Bool = false }

    // MARK: Parsing

    static func runs(_ string: String) -> [Run] {
        var parser = Parser(chars: Array(string))
        return parser.parseTopLevel()
    }

    /// The visible text with all markup removed (escape sequences kept).
    static func plain(_ string: String) -> String {
        runs(string).map { $0.text }.joined()
    }

    /// Approximate rendered width: 0.55 * size per character at full
    /// size, with a 0.7 factor for subscript / superscript runs. For
    /// bounds estimation only — `draw` measures the real glyphs.
    static func estimatedWidth(_ string: String, size: CGFloat) -> CGFloat {
        runs(string).reduce(CGFloat(0)) { sum, run in
            let factor: CGFloat = (run.sub || run.sup) ? 0.7 : 1.0
            return sum + CGFloat(run.text.count) * size * 0.55 * factor
        }
    }

    // MARK: Drawing

    /// Lays the parsed runs left-to-right along a baseline through `pt`,
    /// rotated by `angle` (radians, screen space). Subscript /
    /// superscript runs are drawn at 0.7x size with the baseline shifted
    /// down / up by 0.28 * size in the text's local frame (+y is
    /// down-screen after rotation). Overbar runs get a thin line above
    /// their glyphs. Horizontally the anchor picks where `pt` sits
    /// (.leading = start, .center = middle, .trailing = end); the runs
    /// are centred vertically on `pt` for the usual .leading / .center /
    /// .trailing anchors (anchor.y is honoured, so top / bottom
    /// justified graphic text keeps its justification).
    static func draw(in ctx: inout GraphicsContext, _ string: String, at pt: CGPoint,
                     size: CGFloat, color: Color, angle: Double, anchor: UnitPoint,
                     bold: Bool, italic: Bool) {
        let parsed = runs(string)
        guard !parsed.isEmpty else { return }

        // Resolve and measure every run up front so the anchor can be
        // honoured against the true total width.
        var resolved: [GraphicsContext.ResolvedText] = []
        var widths: [CGFloat] = []
        var heights: [CGFloat] = []
        for run in parsed {
            let runSize = size * ((run.sub || run.sup) ? 0.7 : 1.0)
            var text = Text(run.text)
                .font(.system(size: runSize, weight: bold ? .bold : .regular))
                .foregroundColor(color)
            if italic { text = text.italic() }
            let item = ctx.resolve(text)
            let measured = item.measure(in: CGSize(width: 10000, height: 10000))
            resolved.append(item)
            widths.append(measured.width)
            heights.append(measured.height)
        }
        let totalWidth = widths.reduce(CGFloat(0), +)

        var c = ctx
        c.translateBy(x: pt.x, y: pt.y)
        if angle != 0 { c.rotate(by: .radians(angle)) }

        var x = -anchor.x * totalWidth
        for index in parsed.indices {
            let run = parsed[index]
            var dy: CGFloat = 0
            if run.sub { dy += size * 0.28 }
            if run.sup { dy -= size * 0.28 }
            c.draw(resolved[index], at: CGPoint(x: x, y: dy),
                   anchor: UnitPoint(x: 0, y: anchor.y))
            if run.overbar {
                let top = dy - anchor.y * heights[index]
                let lineY = top - max(size * 0.08, 1)
                var line = Path()
                line.move(to: CGPoint(x: x, y: lineY))
                line.addLine(to: CGPoint(x: x + widths[index], y: lineY))
                c.stroke(line, with: .color(color),
                         style: StrokeStyle(lineWidth: max(size * 0.06, 0.75)))
            }
            x += widths[index]
        }
    }

    // MARK: Parser

    /// Recursive-descent parser over the markup grammar. Adjacent
    /// characters sharing the same flags are coalesced into one run.
    private struct Parser {
        var chars: [Character]
        var pos: Int = 0

        mutating func parseTopLevel() -> [Run] {
            parseSequence(sub: false, sup: false, overbar: false, insideBraces: false).runs
        }

        private mutating func append(_ text: String, to runs: inout [Run],
                                     sub: Bool, sup: Bool, overbar: Bool) {
            guard !text.isEmpty else { return }
            if let last = runs.last, last.sub == sub, last.sup == sup, last.overbar == overbar {
                runs[runs.count - 1].text += text
            } else {
                runs.append(Run(text: text, sub: sub, sup: sup, overbar: overbar))
            }
        }

        /// Parses until the end of input or — when `insideBraces` — the
        /// matching closing brace (which is consumed). `closed` reports
        /// whether that closing brace was found.
        private mutating func parseSequence(sub: Bool, sup: Bool, overbar: Bool,
                                            insideBraces: Bool) -> (runs: [Run], closed: Bool) {
            var out: [Run] = []
            while pos < chars.count {
                let ch = chars[pos]
                if insideBraces && ch == "}" {
                    pos += 1
                    return (out, true)
                }
                if (ch == "_" || ch == "^" || ch == "~"),
                   pos + 1 < chars.count, chars[pos + 1] == "{" {
                    // Markup opener: parse the braced content with the
                    // extra flag set. If its brace never closes, fall
                    // back to treating the opener as literal text.
                    let saved = pos
                    pos += 2
                    let inner = parseSequence(sub: sub || ch == "_",
                                              sup: sup || ch == "^",
                                              overbar: overbar || ch == "~",
                                              insideBraces: true)
                    if inner.closed {
                        for run in inner.runs {
                            append(run.text, to: &out, sub: run.sub, sup: run.sup, overbar: run.overbar)
                        }
                    } else {
                        pos = saved + 2
                        append(String(ch) + "{", to: &out, sub: sub, sup: sup, overbar: overbar)
                    }
                    continue
                }
                if ch == "{" {
                    // Escape sequence {identifier}: renders as the bare
                    // identifier. Any other lone "{" is literal text.
                    if let escape = scanEscape(from: pos) {
                        append(escape.text, to: &out, sub: sub, sup: sup, overbar: overbar)
                        pos = escape.end
                    } else {
                        append("{", to: &out, sub: sub, sup: sup, overbar: overbar)
                        pos += 1
                    }
                    continue
                }
                append(String(ch), to: &out, sub: sub, sup: sup, overbar: overbar)
                pos += 1
            }
            return (out, false)
        }

        /// If `chars[open]` opens a `{identifier}` escape, returns the
        /// identifier and the index just past the closing brace.
        private func scanEscape(from open: Int) -> (text: String, end: Int)? {
            var i = open + 1
            guard i < chars.count, isIdentifierStart(chars[i]) else { return nil }
            let start = i
            while i < chars.count, isIdentifierContinue(chars[i]) { i += 1 }
            guard i < chars.count, chars[i] == "}" else { return nil }
            return (String(chars[start..<i]), i + 1)
        }

        private func isIdentifierStart(_ ch: Character) -> Bool {
            ch.isLetter || ch == "_"
        }

        private func isIdentifierContinue(_ ch: Character) -> Bool {
            ch.isLetter || ch.isNumber || ch == "_"
        }
    }
}
