import SwiftUI

/// Renders KiCad symbol definitions.
///
/// All geometry interpretation — placement transforms, unit merging,
/// pin stub / glyph / anchor geometry, graphic primitives and arc
/// sampling — lives in `SymbolDrawList` (SymbolDrawList.swift), which
/// is Foundation / CoreGraphics only so the identical code runs in the
/// headless GeomDump harness. This type only maps the canonical local
/// draw list through the canvas transform and paints it. The static
/// geometry helpers below are thin delegations kept so existing call
/// sites (canvas, chooser) keep working unchanged.
enum SymbolRenderer {

    // MARK: Colors (KiCad-ish)

    static let outlineColor = Color(red: 0.478, green: 0.122, blue: 0.122) // #7A1F1F
    static let bodyFillColor = Color(red: 1.0, green: 0.98, blue: 0.85).opacity(0.9)
    static let pinNumberColor = Color(red: 0.55, green: 0.08, blue: 0.08)
    static let pinNameColor = Color(red: 0.30, green: 0.08, blue: 0.08)

    // MARK: Geometry (delegated to SymbolDrawList)

    static func transformPoint(_ p: DPoint, placed: PlacedSymbol) -> DPoint {
        SymbolDrawList.transformPoint(p, placed: placed)
    }

    static func transformDirection(_ d: DPoint, placed: PlacedSymbol) -> DPoint {
        SymbolDrawList.transformDirection(d, placed: placed)
    }

    static func pinLocalPoints(def: KiCadSymbolDef, unit: Int) -> [(pin: KiCadPin, point: CGPoint)] {
        SymbolDrawList.pinLocalPoints(def: def, unit: unit)
    }

    static func pinWorldPoints(def: KiCadSymbolDef, placed: PlacedSymbol) -> [(pin: KiCadPin, point: DPoint)] {
        SymbolDrawList.pinWorldPoints(def: def, placed: placed)
    }

    static func graphicsBounds(def: KiCadSymbolDef, unit: Int) -> CGRect {
        SymbolDrawList.graphicsBounds(def: def, unit: unit)
    }

    static func placedBounds(def: KiCadSymbolDef, placed: PlacedSymbol) -> CGRect {
        SymbolDrawList.placedBounds(def: def, placed: placed)
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

        // The canonical local draw list: every coordinate painted below
        // comes from it (graphics primitives, pin stubs, glyph points
        // and text anchors).
        let drawList = SymbolDrawList.build(def: def, unit: unit, pinNameOffset: def.pinNameOffset)

        // --- Graphics (units 0 + unit) ---
        for g in drawList.graphics {
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

            case .arc(_, _, _, _, _, _, let sampled, let w, let t, let f):
                // The draw list carries the arc pre-sampled in local
                // coords (same circumcenter sweep the old screen-space
                // arcPath used); mapping the polyline through `map`
                // traces the same curve under the canvas's
                // uniform-scale + flip transform.
                var path = Path()
                if let first = sampled.first {
                    path.move(to: map(first))
                    for p in sampled.dropFirst() { path.addLine(to: map(p)) }
                }
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

            case .text(let string, let x, let y, let rotation, let size, let bold, let italic, let hJustify, let vJustify, _, _):
                let rad = rotation * Double.pi / 180.0
                let dir = screenDir(cos(rad), sin(rad))
                let angle = atan2(Double(dir.y), Double(dir.x))
                let anchor = UnitPoint(x: hJustify == "left" ? 0 : (hJustify == "right" ? 1 : 0.5),
                                       y: vJustify == "top" ? 0 : (vJustify == "bottom" ? 1 : 0.5))
                KiCadText.draw(in: &ctx, string, at: lp(x, y),
                               size: max(CGFloat(size) * scale, 6),
                               color: outlineColor, angle: angle, anchor: anchor,
                               bold: bold, italic: italic)

            case .textBox(let string, let x, let y, let w, let h, let rotation, let size, let bold, let italic, let hJustify, _, let sw, let st, let f, _, _):
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

        // --- Pins ---
        for pg in drawList.pins where !pg.pin.hidden {
            let pin = pg.pin
            let conn = pg.conn
            let inner = pg.root // body-side stub end (local)

            // Stub: connection point toward the body.
            if pin.length > 0 {
                var stub = Path()
                stub.move(to: map(conn))
                stub.addLine(to: map(inner))
                ctx.stroke(stub, with: .color(outlineColor),
                           style: strokeStyle(widthMM: 0, type: "solid", scale: scale, minPoints: 0.75))
            }

            // Shape glyphs (points precomputed in the draw list; the x
            // glyph's segment endpoints are centre + dir*a + perp*b in
            // the pin's frame, reconstructed here from its centre).
            func framePt(_ base: CGPoint, _ alongDir: Double, _ alongPerp: Double) -> CGPoint {
                CGPoint(x: base.x + CGFloat(pg.dirX * alongDir + (-pg.dirY) * alongPerp),
                        y: base.y + CGFloat(pg.dirY * alongDir + pg.dirX * alongPerp))
            }
            for glyph in pg.glyphs {
                switch glyph {
                case .bubble(let center, let radius):
                    let c = map(center)
                    let rp = CGFloat(radius) * scale
                    let circle = Path(ellipseIn: CGRect(x: c.x - rp, y: c.y - rp, width: 2 * rp, height: 2 * rp))
                    ctx.fill(circle, with: .color(.white))
                    ctx.stroke(circle, with: .color(outlineColor),
                               style: strokeStyle(widthMM: 0, type: "solid", scale: scale, minPoints: 0.75))
                case .wedge(let points):
                    if let first = points.first {
                        var path = Path()
                        path.move(to: map(first))
                        for p in points.dropFirst() { path.addLine(to: map(p)) }
                        ctx.stroke(path, with: .color(outlineColor),
                                   style: strokeStyle(widthMM: 0, type: "solid", scale: scale, minPoints: 0.75))
                    }
                case .x(let at, let half):
                    var xPath = Path()
                    xPath.move(to: map(framePt(at, -half, -half)))
                    xPath.addLine(to: map(framePt(at, half, half)))
                    xPath.move(to: map(framePt(at, -half, half)))
                    xPath.addLine(to: map(framePt(at, half, -half)))
                    ctx.stroke(xPath, with: .color(outlineColor),
                               style: strokeStyle(widthMM: 0, type: "solid", scale: scale, minPoints: 0.75))
                }
            }

            // Pin number: near the stub, offset perpendicular from its
            // middle (anchor precomputed in the draw list).
            if showPinNumbers && !pin.number.isEmpty {
                let dirS = screenDir(pg.dirX, pg.dirY)
                var angle = atan2(Double(dirS.y), Double(dirS.x))
                if angle > Double.pi / 2 { angle -= Double.pi }
                if angle < -Double.pi / 2 { angle += Double.pi }
                drawText(&ctx, pin.number, at: map(pg.numberAnchor),
                         size: max(CGFloat(pin.numberSize) * scale, 5.5),
                         color: pinNumberColor, angle: angle, anchor: .center,
                         bold: false, italic: false)
            }

            // Pin name: inside the body, starting pinNameOffset beyond
            // the inner stub end (anchor precomputed in the draw list),
            // extending along +dir (into the body).
            if showPinNames && !pin.name.isEmpty && pin.name != "~" {
                let inward = screenDir(pg.dirX, pg.dirY)
                var angle = atan2(Double(inward.y), Double(inward.x))
                var anchor: UnitPoint = .leading
                if cos(angle) < 0 { // text would run right-to-left; flip so it reads into the body
                    angle += Double.pi
                    anchor = .trailing
                }
                KiCadText.draw(in: &ctx, pin.name, at: map(pg.nameAnchor),
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
}

// MARK: - KiCad text markup (drawing half)

/// Drawing half of KiCadText; the parser half (runs / plain /
/// estimatedWidth and the markup Parser) lives in SymbolDrawList.swift
/// with the rest of the UI-free geometry code.
extension KiCadText {

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
}
