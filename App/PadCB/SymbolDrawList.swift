import Foundation
import CoreGraphics

/// Canonical, UI-free interpretation of a KiCad symbol's geometry.
///
/// This file is the single source of truth for what a symbol *is*
/// geometrically: the placement transform, unit merging, pin stub /
/// glyph / text-anchor geometry, graphic primitives and arc sampling.
/// Everything here is Foundation / CoreGraphics only (no SwiftUI), so
/// the exact code the app renders with also compiles into the headless
/// GeomDump harness (tools/GeomDump) that dumps the whole symbol corpus
/// for diffing against an independent file-truth model.
///
/// Coordinate notes: symbol-local coordinates are millimetres, y-UP,
/// exactly as stored in .kicad_sym files. Placement (world) transforms
/// also keep y-UP: `world = origin + R(rotation) * Mirror * local`.
/// Screen / canvas mapping lives in SymbolRenderer.draw's `map` closure.
enum SymbolDrawList {

    /// KiCad inversion bubble radius (mm).
    static let bubbleRadius = 0.3
    /// Half-extent (mm) of the small x glyphs (non_logic at the pin
    /// root, no_connect at the connection point): the drawn segments
    /// run between centre + dir*a + perp*b for (a, b) in
    /// (-d, -d) -> (d, d) and (-d, d) -> (d, -d).
    static let xGlyphHalf = 0.3
    /// Clock wedge dimensions (mm): base half-width and apex distance
    /// along the pin direction from the wedge base point.
    static let wedgeHalfWidth = 0.3
    static let wedgeLength = 0.6

    // MARK: - Draw-list model

    /// One pin-shape / no-connect glyph, in local coordinates.
    enum Glyph {
        /// Inversion bubble: centre one radius beyond the pin root.
        case bubble(center: CGPoint, radius: Double)
        /// Clock wedge: exactly 3 points in draw order —
        /// base + perp*h, apex (base + dir*length), base - perp*h —
        /// stroked as an open polyline (not closed).
        case wedge(points: [CGPoint])
        /// A small x centred at `at` with half-extent `half` in the
        /// pin's dir/perp frame (see xGlyphHalf).
        case x(at: CGPoint, half: Double)
    }

    /// Fully resolved geometry for one pin of a symbol unit.
    struct PinGeom {
        /// The parsed pin this geometry was derived from.
        var pin: KiCadPin
        /// Connection point (the point that joins wires), local coords.
        var conn: CGPoint
        /// Body-side stub end ("root"): conn + dir(angle) * length.
        var root: CGPoint
        /// Pin direction components (cos / sin of the pin angle): the
        /// unit vector from the connection point toward the body.
        var dirX: Double
        var dirY: Double
        /// Shape glyphs in draw order (shape glyph first, then the
        /// no-connect x when the pin type is no_connect).
        var glyphs: [Glyph]
        /// Pin-name text anchor: root + dir * pinNameOffset.
        var nameAnchor: CGPoint
        /// Pin-number text anchor: stub midpoint + perp *
        /// (numberSize * 0.8 + 0.1), perp = (-dirY, dirX).
        var numberAnchor: CGPoint
        /// Pin name with KiCad markup removed (KiCadText.plain).
        var plainName: String
        /// Pin name parsed into markup runs (KiCadText.runs).
        var nameRuns: [KiCadText.Run]
    }

    /// One graphic primitive in local coordinates, mirroring
    /// KiCadGraphic but with arcs pre-sampled and text pre-parsed so
    /// consumers never re-derive geometry.
    enum GraphicGeom {
        case rectangle(x1: Double, y1: Double, x2: Double, y2: Double,
                       strokeWidth: Double, strokeType: String, fill: String)
        case circle(cx: Double, cy: Double, r: Double,
                    strokeWidth: Double, strokeType: String, fill: String)
        /// sampledPoints[0] is the start point; the rest are the
        /// circumcenter-sweep samples ending at the end point (a
        /// collinear arc samples as exactly [start, mid, end]).
        case arc(sx: Double, sy: Double, mx: Double, my: Double,
                 ex: Double, ey: Double, sampledPoints: [CGPoint],
                 strokeWidth: Double, strokeType: String, fill: String)
        case polyline(points: [(Double, Double)],
                      strokeWidth: Double, strokeType: String, fill: String)
        case bezier(p1: (Double, Double), p2: (Double, Double),
                    p3: (Double, Double), p4: (Double, Double),
                    strokeWidth: Double, strokeType: String, fill: String)
        case text(string: String, x: Double, y: Double, rotation: Double,
                  size: Double, bold: Bool, italic: Bool,
                  hJustify: String, vJustify: String,
                  plain: String, runs: [KiCadText.Run])
        case textBox(string: String, x: Double, y: Double, w: Double, h: Double,
                     rotation: Double, size: Double, bold: Bool, italic: Bool,
                     hJustify: String, vJustify: String,
                     strokeWidth: Double, strokeType: String, fill: String,
                     plain: String, runs: [KiCadText.Run])
    }

    /// The complete draw list for one (symbol, unit): pins include
    /// hidden pins (renderers skip them; geometry audits need them),
    /// in unit-0-then-unit order, exactly as pinLocalPoints yields
    /// them; graphics are in merged-unit draw order.
    struct DrawList {
        var pins: [PinGeom]
        var graphics: [GraphicGeom]
    }

    // MARK: - Draw-list builder

    /// Builds the canonical draw list reproducing exactly what
    /// SymbolRenderer.draw interprets, in local symbol coordinates.
    /// `pinNameOffset` is passed explicitly (callers use
    /// def.pinNameOffset) so the geometry under test is a pure
    /// function of its inputs.
    static func build(def: KiCadSymbolDef, unit: Int, pinNameOffset: Double) -> DrawList {
        var pins: [PinGeom] = []
        for u in mergedUnits(def: def, unit: unit) {
            for pin in u.pins {
                pins.append(pinGeom(pin, pinNameOffset: pinNameOffset))
            }
        }
        var graphics: [GraphicGeom] = []
        for u in mergedUnits(def: def, unit: unit) {
            for g in u.graphics {
                graphics.append(graphicGeom(g))
            }
        }
        return DrawList(pins: pins, graphics: graphics)
    }

    private static func pinGeom(_ pin: KiCadPin, pinNameOffset: Double) -> PinGeom {
        let rad = pin.rotation * Double.pi / 180.0
        // dir points from the connection point toward the body: KiCad's
        // parser maps the file angle to an orientation whose root (the
        // body-side stub end, SCH_PIN::GetPinRoot()) lies at
        // conn + dir * length in file (y-UP) coordinates.
        let dirx = cos(rad), diry = sin(rad)
        let conn = CGPoint(x: CGFloat(pin.x), y: CGFloat(pin.y))
        let root = CGPoint(x: conn.x + CGFloat(dirx * pin.length),
                           y: conn.y + CGFloat(diry * pin.length))
        // pt = base + dir * alongDir + perp * alongPerp, perp = +90°
        // from dir. (Same arithmetic the renderer used inline.)
        func pt(_ base: CGPoint, _ alongDir: Double, _ alongPerp: Double) -> CGPoint {
            CGPoint(x: base.x + CGFloat(dirx * alongDir + (-diry) * alongPerp),
                    y: base.y + CGFloat(diry * alongDir + dirx * alongPerp))
        }

        var glyphs: [Glyph] = []
        switch pin.shape {
        case .inverted, .invertedClock:
            // Bubble just inside the body, tangent to the stub end:
            // its centre lies one radius beyond the root, along +dir.
            glyphs.append(.bubble(center: pt(root, bubbleRadius, 0), radius: bubbleRadius))
            if pin.shape == .invertedClock {
                // Clock wedge beyond the bubble, further along +dir.
                glyphs.append(.wedge(points: wedgePoints(tipBase: pt(root, 2 * bubbleRadius, 0),
                                                         dirx: dirx, diry: diry)))
            }
        case .clock, .clockLow, .edgeClockHigh:
            glyphs.append(.wedge(points: wedgePoints(tipBase: root, dirx: dirx, diry: diry)))
        case .nonLogic:
            // Small x centred at the root (inner stub end).
            glyphs.append(.x(at: root, half: xGlyphHalf))
        default:
            break // line / input_low / output_low etc: plain stub
        }

        // No-connect pins carry a small x at the CONNECTION point
        // (KiCad's PT_NC branch draws the cross at the pin position,
        // independently of the pin's shape glyph above).
        if pin.type == .noConnect {
            glyphs.append(.x(at: conn, half: xGlyphHalf))
        }

        // Pin name: inside the body, starting pinNameOffset beyond the
        // inner stub end, extending along +dir (into the body).
        let nameAnchor = pt(root, pinNameOffset, 0)
        // Pin number: near the stub, offset perpendicular from its middle.
        let mid = CGPoint(x: conn.x + CGFloat(dirx * pin.length / 2),
                          y: conn.y + CGFloat(diry * pin.length / 2))
        let numberOff = pin.numberSize * 0.8 + 0.1
        let numberAnchor = pt(mid, 0, numberOff)

        return PinGeom(pin: pin, conn: conn, root: root,
                       dirX: dirx, dirY: diry, glyphs: glyphs,
                       nameAnchor: nameAnchor, numberAnchor: numberAnchor,
                       plainName: KiCadText.plain(pin.name),
                       nameRuns: KiCadText.runs(pin.name))
    }

    /// Clock wedge points in draw order: base corners at
    /// tipBase ± perp * wedgeHalfWidth, apex at
    /// tipBase + dir * wedgeLength (pointing into the body).
    private static func wedgePoints(tipBase: CGPoint, dirx: Double, diry: Double) -> [CGPoint] {
        func pt(_ alongDir: Double, _ alongPerp: Double) -> CGPoint {
            CGPoint(x: tipBase.x + CGFloat(dirx * alongDir + (-diry) * alongPerp),
                    y: tipBase.y + CGFloat(diry * alongDir + dirx * alongPerp))
        }
        return [pt(0, wedgeHalfWidth), pt(wedgeLength, 0), pt(0, -wedgeHalfWidth)]
    }

    private static func graphicGeom(_ g: KiCadGraphic) -> GraphicGeom {
        switch g {
        case .rectangle(let x1, let y1, let x2, let y2, let w, let t, let f):
            return .rectangle(x1: x1, y1: y1, x2: x2, y2: y2,
                              strokeWidth: w, strokeType: t, fill: f)
        case .circle(let cx, let cy, let r, let w, let t, let f):
            return .circle(cx: cx, cy: cy, r: r, strokeWidth: w, strokeType: t, fill: f)
        case .arc(let sx, let sy, let mx, let my, let ex, let ey, let w, let t, let f):
            let sampled = arcSamplePoints(a: CGPoint(x: CGFloat(sx), y: CGFloat(sy)),
                                          m: CGPoint(x: CGFloat(mx), y: CGFloat(my)),
                                          e: CGPoint(x: CGFloat(ex), y: CGFloat(ey)))
            return .arc(sx: sx, sy: sy, mx: mx, my: my, ex: ex, ey: ey,
                        sampledPoints: sampled, strokeWidth: w, strokeType: t, fill: f)
        case .polyline(let points, let w, let t, let f):
            return .polyline(points: points, strokeWidth: w, strokeType: t, fill: f)
        case .bezier(let p1, let p2, let p3, let p4, let w, let t, let f):
            return .bezier(p1: p1, p2: p2, p3: p3, p4: p4,
                           strokeWidth: w, strokeType: t, fill: f)
        case .text(let string, let x, let y, let rotation, let size,
                   let bold, let italic, let hJustify, let vJustify):
            return .text(string: string, x: x, y: y, rotation: rotation, size: size,
                         bold: bold, italic: italic, hJustify: hJustify, vJustify: vJustify,
                         plain: KiCadText.plain(string), runs: KiCadText.runs(string))
        case .textBox(let string, let x, let y, let w, let h, let rotation, let size,
                      let bold, let italic, let hJustify, let vJustify, let sw, let st, let f):
            return .textBox(string: string, x: x, y: y, w: w, h: h, rotation: rotation,
                            size: size, bold: bold, italic: italic,
                            hJustify: hJustify, vJustify: vJustify,
                            strokeWidth: sw, strokeType: st, fill: f,
                            plain: KiCadText.plain(string), runs: KiCadText.runs(string))
        }
    }

    // MARK: - Arc sampling

    /// Samples the arc through three LOCAL points via the circumcenter,
    /// along the sweep that passes through the mid point. This is the
    /// exact algorithm SymbolRenderer.arcPath used in screen space;
    /// under the canvas's uniform-scale + flip map the sampled local
    /// polyline maps to the same curve. Returns [start] + one point
    /// per step, the last being the end point; a (near-)collinear
    /// triple returns exactly [start, mid, end].
    static func arcSamplePoints(a: CGPoint, m: CGPoint, e: CGPoint) -> [CGPoint] {
        var points: [CGPoint] = [a]
        let d = 2 * (a.x * (m.y - e.y) + m.x * (e.y - a.y) + e.x * (a.y - m.y))
        if abs(d) < 1e-9 {
            points.append(m)
            points.append(e)
            return points
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
            points.append(CGPoint(x: cx + r * CGFloat(cos(t)), y: cy + r * CGFloat(sin(t))))
        }
        return points
    }

    // MARK: - Placement transform

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

    // MARK: - Unit merging helpers

    static func mergedUnits(def: KiCadSymbolDef, unit: Int) -> [KiCadUnitDef] {
        var out: [KiCadUnitDef] = []
        if let common = def.units[0] { out.append(common) }
        if unit != 0, let u = def.units[unit] { out.append(u) }
        return out
    }

    // MARK: - Pins

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

    // MARK: - Bounds

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
}

// MARK: - KiCad text markup (parser half)

/// KiCad text markup (see KiCad's markup_parser grammar): `_{...}` is a
/// subscript, `^{...}` a superscript and `~{...}` an overbar. Braced
/// content may itself contain markup, and the flags combine under
/// nesting. A lone `{identifier}` is an escape sequence and renders as
/// the bare identifier. Unmatched braces degrade gracefully to literal
/// text. This is an original implementation of those semantics, used for
/// pin names (e.g. `IN_{BIAS}`, `V_{SO+}`) and graphic text elements.
///
/// The parser half lives here so the headless harness shares it; the
/// drawing half (`draw`) lives in SymbolRenderer.swift as an extension.
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
