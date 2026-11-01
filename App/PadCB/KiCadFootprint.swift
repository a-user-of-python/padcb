import Foundation

/// KiCad `.kicad_mod` footprint model + parser (KiCad 10-era S-expression
/// format), written from the file format — no KiCad code.
///
/// Coordinates: millimetres in KiCad PCB space — x right, **y DOWN**
/// (board convention, unlike the schematic's y-up). The footprint
/// browser's top view maps file coordinates straight onto the screen
/// (x right, y down), which is exactly how KiCad shows a footprint.
///
/// Modelled: pads (number/type/shape/size/drill/layers/position/
/// rotation, roundrect + chamfer ratios, trapezoid rect_delta, custom-pad
/// anchor + primitives), footprint graphics (fp_line / fp_rect /
/// fp_circle / fp_arc / fp_poly / fp_curve / fp_text), the footprint
/// description + tags, (property ...) pairs and (attr ...) flags.
/// Skipped but counted in `skippedNodeCounts`: (model ...) 3D references,
/// zones, dimensions, groups, and anything else not listed above.

struct FPPoint: Equatable {
    var x: Double
    var y: Double

    static let zero = FPPoint(x: 0, y: 0)

    func distance(to other: FPPoint) -> Double {
        let dx = x - other.x, dy = y - other.y
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Rotate by `degrees` in file coordinates (standard rotation matrix;
    /// with y down this appears clockwise on screen, as in KiCad).
    func rotated(degrees: Double) -> FPPoint {
        let rad = degrees * Double.pi / 180.0
        let c = cos(rad), s = sin(rad)
        return FPPoint(x: x * c - y * s, y: x * s + y * c)
    }
}

enum KiCadPadType: String {
    case smd
    case thruHole = "thru_hole"
    case npThruHole = "np_thru_hole"
    case connect
}

enum KiCadPadShape: String {
    case circle, rect, oval, trapezoid, roundrect, custom
}

struct KiCadDrill {
    /// First drill diameter (the only diameter for a round hole).
    var width: Double
    /// Second diameter for an oval hole; equals `width` when round.
    var height: Double
    var offsetX: Double
    var offsetY: Double

    var isOval: Bool { abs(width - height) > 1e-9 }
}

struct KiCadFootprintText {
    /// "reference" | "value" | "user" (fp_text's first argument).
    var kind: String
    var text: String
    var x: Double
    var y: Double
    var rotation: Double
    var layer: String
    var hidden: Bool
    /// Font height (the first (size h w) value), mm.
    var size: Double
    var thickness: Double
    var hJustify: String
    var vJustify: String
}

enum KiCadFootprintGraphic {
    case line(start: FPPoint, end: FPPoint, layer: String, strokeWidth: Double, strokeType: String, fill: String)
    case rect(start: FPPoint, end: FPPoint, layer: String, strokeWidth: Double, strokeType: String, fill: String)
    case circle(center: FPPoint, radius: Double, layer: String, strokeWidth: Double, strokeType: String, fill: String)
    case arc(start: FPPoint, mid: FPPoint, end: FPPoint, layer: String, strokeWidth: Double, strokeType: String, fill: String)
    case poly(points: [FPPoint], layer: String, strokeWidth: Double, strokeType: String, fill: String)
    case curve(p1: FPPoint, p2: FPPoint, p3: FPPoint, p4: FPPoint, layer: String, strokeWidth: Double, strokeType: String, fill: String)
    case text(KiCadFootprintText)

    var layer: String {
        switch self {
        case .line(_, _, let layer, _, _, _),
             .rect(_, _, let layer, _, _, _),
             .circle(_, _, let layer, _, _, _),
             .arc(_, _, _, let layer, _, _, _),
             .poly(_, let layer, _, _, _),
             .curve(_, _, _, _, let layer, _, _, _):
            return layer
        case .text(let text):
            return text.layer
        }
    }

    /// Points that define the graphic's extent (for preview bounds).
    var extentPoints: [FPPoint] {
        switch self {
        case .line(let a, let b, _, _, _, _): return [a, b]
        case .rect(let a, let b, _, _, _, _): return [a, b]
        case .circle(let c, let r, _, _, _, _):
            return [FPPoint(x: c.x - r, y: c.y - r), FPPoint(x: c.x + r, y: c.y + r)]
        case .arc(let a, let m, let b, _, _, _, _): return [a, m, b]
        case .poly(let pts, _, _, _, _): return pts
        case .curve(let a, let b, let c, let d, _, _, _, _): return [a, b, c, d]
        case .text(let t): return [FPPoint(x: t.x, y: t.y)]
        }
    }
}

struct KiCadFootprintPad {
    var number: String
    var type: KiCadPadType
    var shape: KiCadPadShape
    var x: Double
    var y: Double
    var rotation: Double
    var width: Double
    var height: Double
    var drill: KiCadDrill?
    var layers: [String]
    var roundrectRatio: Double?
    var chamferRatio: Double?
    /// (rect_delta dx dy) for trapezoid pads.
    var rectDelta: FPPoint?
    /// Custom-pad (primitives ...) graphics, in pad-local coordinates.
    var primitives: [KiCadFootprintGraphic]
    /// Custom-pad (options (anchor ...)) value, e.g. "rect" / "circle".
    var customAnchor: String?

    var center: FPPoint { FPPoint(x: x, y: y) }

    var isThroughHole: Bool { type == .thruHole || type == .npThruHole }

    /// The pad outline's corner points in footprint coordinates
    /// (rotation applied). Approximation for roundrect/trapezoid/custom:
    /// the bounding rectangle — the browser draws true shapes from the
    /// pad fields; this is for bounds and hit-free layout only.
    var outlineCorners: [FPPoint] {
        let hw = width / 2, hh = height / 2
        return [FPPoint(x: -hw, y: -hh), FPPoint(x: hw, y: -hh),
                FPPoint(x: hw, y: hh), FPPoint(x: -hw, y: hh)]
            .map { $0.rotated(degrees: rotation) }
            .map { FPPoint(x: x + $0.x, y: y + $0.y) }
    }
}

struct KiCadFootprint {
    /// Name from the file's (footprint "Name" ...) node; the store falls
    /// back to the file's base name when the node carries no name.
    var name: String
    var description: String
    var tags: [String]
    /// (attr ...) atoms after the head, e.g. ["smd"], ["through_hole"].
    var attributes: [String]
    /// (property "Name" "Value" ...) pairs, first occurrence wins.
    var properties: [String: String]
    var pads: [KiCadFootprintPad]
    var graphics: [KiCadFootprintGraphic]
    /// Node heads that were present but are not modelled (model, zone,
    /// dimension, group, …), counted by head name.
    var skippedNodeCounts: [String: Int]

    var texts: [KiCadFootprintText] {
        graphics.compactMap { graphic in
            if case .text(let text) = graphic { return text }
            return nil
        }
    }

    /// Every layer named by pads or graphics, sorted.
    var layers: [String] {
        var set = Set<String>()
        for pad in pads { set.formUnion(pad.layers) }
        for graphic in graphics where !graphic.layer.isEmpty { set.insert(graphic.layer) }
        return set.sorted()
    }

    /// Bounding box over pads and graphics, in file coordinates.
    /// Falls back to a 1×1 box at the origin for an empty footprint.
    var bounds: (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude
        func include(_ p: FPPoint) {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        for pad in pads {
            for corner in pad.outlineCorners { include(corner) }
            include(pad.center)
            for primitive in pad.primitives {
                for point in primitive.extentPoints {
                    include(point.rotated(degrees: pad.rotation)
                        .advanced(by: pad.center))
                }
            }
        }
        for graphic in graphics {
            for point in graphic.extentPoints { include(point) }
        }
        guard minX <= maxX, minY <= maxY else { return (0, 0, 1, 1) }
        return (minX, minY, maxX, maxY)
    }

    // MARK: - Parsing

    enum ParseError: Error {
        case notAFootprint
    }

    /// Parse one `.kicad_mod` document. `name` is the caller's fallback
    /// (the file's base name); the file's own (footprint "Name") wins
    /// when present. Throws SExprError on unreadable text and
    /// ParseError.notAFootprint when the root is not (footprint ...).
    static func parse(name: String, text: String) throws -> KiCadFootprint {
        let root = try SExpr.parse(text)
        guard case .list = root,
              let head = root.items.first?.atomValue,
              head == "footprint" || head == "module" else {
            throw ParseError.notAFootprint
        }

        var footprint = KiCadFootprint(
            name: root.value(1) ?? name,
            description: "",
            tags: [],
            attributes: [],
            properties: [:],
            pads: [],
            graphics: [],
            skippedNodeCounts: [:]
        )
        if footprint.name.isEmpty { footprint.name = name }

        let handled: Set<String> = [
            "version", "generator", "generator_version", "layer", "tstamp",
            "uuid", "descr", "tags", "attr", "property",
            // Per-file settings every KiCad 10 footprint carries; not
            // geometry, so not "skipped" either.
            "duplicate_pad_numbers_are_jumpers", "embedded_fonts",
            "fp_line", "fp_rect", "fp_circle", "fp_arc", "fp_poly",
            "fp_curve", "fp_text", "pad",
        ]

        for item in root.items {
            guard case .list(let children) = item,
                  let nodeHead = children.first?.atomValue else { continue }
            switch nodeHead {
            case "descr":
                footprint.description = item.value(1) ?? ""
            case "tags":
                footprint.tags = (item.value(1) ?? "")
                    .split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .map(String.init)
            case "attr":
                footprint.attributes = item.items.dropFirst().compactMap { $0.atomValue }
            case "property":
                // (property "Name" "Value" ...) — with an optional bare
                // `private` marker before the name, as in .kicad_sym.
                let nameIndex = item.value(1) == "private" ? 2 : 1
                if let propName = item.value(nameIndex),
                   footprint.properties[propName] == nil {
                    footprint.properties[propName] = item.value(nameIndex + 1) ?? ""
                }
            case "fp_line", "fp_rect", "fp_circle", "fp_arc", "fp_poly", "fp_curve":
                if let graphic = parseGraphic(item) {
                    footprint.graphics.append(graphic)
                } else {
                    footprint.skippedNodeCounts[nodeHead + " (unreadable)", default: 0] += 1
                }
            case "fp_text":
                if let text = parseText(item) {
                    footprint.graphics.append(.text(text))
                } else {
                    footprint.skippedNodeCounts["fp_text (unreadable)", default: 0] += 1
                }
            case "pad":
                if let pad = parsePad(item) {
                    footprint.pads.append(pad)
                } else {
                    footprint.skippedNodeCounts["pad (unreadable)", default: 0] += 1
                }
            default:
                if !handled.contains(nodeHead) {
                    footprint.skippedNodeCounts[nodeHead, default: 0] += 1
                }
            }
        }
        return footprint
    }

    // MARK: - Arc sampling

    /// Samples the arc through three file points via the circumcenter,
    /// along the sweep passing through the mid point. Returns [start]
    /// + one point per step, ending at the end point; a (near-)
    /// collinear triple returns exactly [start, mid, end].
    private static func arcSamplePoints(a: FPPoint, m: FPPoint, e: FPPoint) -> [FPPoint] {
        var points: [FPPoint] = [a]
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
        let a0 = atan2(a.y - cy, a.x - cx)
        let am = atan2(m.y - cy, m.x - cx)
        let a1 = atan2(e.y - cy, e.x - cx)
        func norm(_ v: Double) -> Double {
            var v = v.truncatingRemainder(dividingBy: 2 * Double.pi)
            if v < 0 { v += 2 * Double.pi }
            return v
        }
        let sweepPos = norm(a1 - a0)
        let midPos = norm(am - a0)
        let sweep = midPos <= sweepPos + 1e-9 ? sweepPos : -(2 * Double.pi - sweepPos)
        let steps = max(4, Int(abs(sweep) / (Double.pi / 36)) + 1)
        for i in 1...steps {
            let t = a0 + sweep * Double(i) / Double(steps)
            points.append(FPPoint(x: cx + r * cos(t), y: cy + r * sin(t)))
        }
        return points
    }

    // MARK: - Node helpers

    private static func pointOf(_ node: SExpr, _ head: String) -> FPPoint? {
        guard let point = node.child(head),
              let x = point.double(1), let y = point.double(2) else { return nil }
        return FPPoint(x: x, y: y)
    }

    private static func layerOf(_ node: SExpr) -> String {
        node.child("layer")?.value(1) ?? ""
    }

    private static func strokeOf(_ node: SExpr) -> (width: Double, type: String) {
        if let stroke = node.child("stroke") {
            return (stroke.child("width")?.double(1) ?? 0.1,
                    stroke.child("type")?.value(1) ?? "solid")
        }
        // Custom-pad primitives carry a bare (width w) instead of a
        // (stroke ...) node.
        if let width = node.child("width")?.double(1) {
            return (width, "solid")
        }
        return (0.1, "solid")
    }

    private static func fillOf(_ node: SExpr) -> String {
        guard let fill = node.child("fill") else { return "none" }
        if let type = fill.child("type")?.value(1) { return type }
        return fill.value(1) ?? "none"
    }

    /// True when a bare `hide` atom or a (hide yes) list appears in the
    /// node's subtree (fp_text carries it as a direct child in KiCad 10,
    /// or inside (effects ...) in older files). List heads / atoms only —
    /// quoted strings are never matched.
    private static func subtreeHides(_ node: SExpr) -> Bool {
        for item in node.items {
            if case .atom(let atom) = item, atom == "hide" { return true }
            guard case .list(let children) = item,
                  let head = children.first?.atomValue else { continue }
            if head == "hide" { return (item.value(1) ?? "yes") != "no" }
            if subtreeHides(item) { return true }
        }
        return false
    }

    // MARK: - Graphics

    private static func parseGraphic(_ node: SExpr) -> KiCadFootprintGraphic? {
        guard let head = node.items.first?.atomValue else { return nil }
        let layer = layerOf(node)
        let stroke = strokeOf(node)
        let fill = fillOf(node)
        switch head {
        case "fp_line", "gr_line":
            guard let start = pointOf(node, "start"), let end = pointOf(node, "end")
            else { return nil }
            return .line(start: start, end: end, layer: layer,
                         strokeWidth: stroke.width, strokeType: stroke.type, fill: fill)
        case "fp_rect", "gr_rect":
            guard let start = pointOf(node, "start"), let end = pointOf(node, "end")
            else { return nil }
            return .rect(start: start, end: end, layer: layer,
                         strokeWidth: stroke.width, strokeType: stroke.type, fill: fill)
        case "fp_circle", "gr_circle":
            guard let center = pointOf(node, "center"), let end = pointOf(node, "end")
            else { return nil }
            return .circle(center: center, radius: center.distance(to: end), layer: layer,
                           strokeWidth: stroke.width, strokeType: stroke.type, fill: fill)
        case "fp_arc", "gr_arc":
            guard let start = pointOf(node, "start"),
                  let mid = pointOf(node, "mid"),
                  let end = pointOf(node, "end") else { return nil }
            return .arc(start: start, mid: mid, end: end, layer: layer,
                        strokeWidth: stroke.width, strokeType: stroke.type, fill: fill)
        case "fp_poly", "gr_poly":
            guard let pts = node.child("pts") else { return nil }
            // KiCad 10 polygon outlines mix (xy x y) vertices with
            // (arc (start)(mid)(end)) segments (e.g.
            // Sensor_Pressure:Honeywell_ABPDAN) — sample the arcs into
            // the point sequence, in file order.
            var points: [FPPoint] = []
            for child in pts.items {
                guard case .list(let children) = child,
                      let childHead = children.first?.atomValue else { continue }
                if childHead == "xy",
                   let x = child.double(1), let y = child.double(2) {
                    points.append(FPPoint(x: x, y: y))
                } else if childHead == "arc",
                          let start = pointOf(child, "start"),
                          let mid = pointOf(child, "mid"),
                          let end = pointOf(child, "end") {
                    for (i, sampled) in arcSamplePoints(a: start, m: mid, e: end).enumerated() {
                        if i == 0, let last = points.last,
                           last.distance(to: sampled) < 1e-9 { continue }
                        points.append(sampled)
                    }
                }
            }
            guard points.count >= 2 else { return nil }
            return .poly(points: points, layer: layer,
                        strokeWidth: stroke.width, strokeType: stroke.type, fill: fill)
        case "fp_curve", "gr_curve":
            guard let pts = node.child("pts") else { return nil }
            let points = pts.children("xy").compactMap { xy -> FPPoint? in
                guard let x = xy.double(1), let y = xy.double(2) else { return nil }
                return FPPoint(x: x, y: y)
            }
            guard points.count >= 4 else { return nil }
            return .curve(p1: points[0], p2: points[1], p3: points[2], p4: points[3],
                          layer: layer, strokeWidth: stroke.width,
                          strokeType: stroke.type, fill: fill)
        case "fp_text", "gr_text":
            guard let text = parseText(node) else { return nil }
            return .text(text)
        default:
            return nil
        }
    }

    private static func parseText(_ node: SExpr) -> KiCadFootprintText? {
        guard let kind = node.value(1), let text = node.value(2) else { return nil }
        let at = node.child("at")
        var size = 1.0
        var thickness = 0.15
        var hJustify = "center"
        var vJustify = "center"
        if let effects = node.child("effects") {
            if let font = effects.child("font") {
                if let fontSize = font.child("size")?.double(1) { size = fontSize }
                if let fontThickness = font.child("thickness")?.double(1) {
                    thickness = fontThickness
                }
            }
            if let justify = effects.child("justify") {
                for item in justify.items {
                    guard let atom = item.atomValue else { continue }
                    switch atom {
                    case "left", "right": hJustify = atom
                    case "top", "bottom": vJustify = atom
                    case "center": break
                    case "mirror": break
                    default: break
                    }
                }
            }
        }
        return KiCadFootprintText(
            kind: kind,
            text: text,
            x: at?.double(1) ?? 0,
            y: at?.double(2) ?? 0,
            rotation: at?.double(3) ?? 0,
            layer: layerOf(node),
            hidden: subtreeHides(node),
            size: size,
            thickness: thickness,
            hJustify: hJustify,
            vJustify: vJustify
        )
    }

    // MARK: - Pads

    private static func parsePad(_ node: SExpr) -> KiCadFootprintPad? {
        guard let number = node.value(1) else { return nil }
        let type = KiCadPadType(rawValue: node.value(2) ?? "") ?? .smd
        let shape = KiCadPadShape(rawValue: node.value(3) ?? "") ?? .rect
        let at = node.child("at")
        let size = node.child("size")

        var drill: KiCadDrill? = nil
        if let drillNode = node.child("drill") {
            let offset = drillNode.child("offset")
            if drillNode.value(1) == "oval" {
                drill = KiCadDrill(
                    width: drillNode.double(2) ?? 0,
                    height: drillNode.double(3) ?? drillNode.double(2) ?? 0,
                    offsetX: offset?.double(1) ?? 0,
                    offsetY: offset?.double(2) ?? 0)
            } else if let diameter = drillNode.double(1) {
                drill = KiCadDrill(
                    width: diameter, height: diameter,
                    offsetX: offset?.double(1) ?? 0,
                    offsetY: offset?.double(2) ?? 0)
            }
        }

        var primitives: [KiCadFootprintGraphic] = []
        var customAnchor: String? = nil
        if let primitivesNode = node.child("primitives") {
            for child in primitivesNode.items {
                guard case .list(let children) = child,
                      children.first?.atomValue != nil else { continue }
                if let graphic = parseGraphic(child) {
                    primitives.append(graphic)
                }
            }
        }
        if let options = node.child("options") {
            customAnchor = options.child("anchor")?.value(1)
        }

        let rectDelta: FPPoint?
        if let delta = node.child("rect_delta"),
           let dx = delta.double(1), let dy = delta.double(2) {
            rectDelta = FPPoint(x: dx, y: dy)
        } else {
            rectDelta = nil
        }

        return KiCadFootprintPad(
            number: number,
            type: type,
            shape: shape,
            x: at?.double(1) ?? 0,
            y: at?.double(2) ?? 0,
            rotation: at?.double(3) ?? 0,
            width: size?.double(1) ?? 0,
            height: size?.double(2) ?? size?.double(1) ?? 0,
            drill: drill,
            layers: node.child("layers")?.items.dropFirst().compactMap { $0.atomValue } ?? [],
            roundrectRatio: node.child("roundrect_rratio")?.double(1),
            chamferRatio: node.child("chamfer_ratio")?.double(1),
            rectDelta: rectDelta,
            primitives: primitives,
            customAnchor: customAnchor
        )
    }
}

extension FPPoint {
    func advanced(by delta: FPPoint) -> FPPoint {
        FPPoint(x: x + delta.x, y: y + delta.y)
    }
}
