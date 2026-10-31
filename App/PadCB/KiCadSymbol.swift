import Foundation

// MARK: - Model types (contract-pinned)

struct KiCadProperty {
    var name: String
    var value: String
    var id: Int
    var x: Double
    var y: Double
    var rotation: Double
    var hidden: Bool
    var fontSize: Double
}

enum KiCadPinType: String {
    case input, output, bidirectional, triState = "tri_state",
         passive, free, unspecified, powerIn = "power_in", powerOut = "power_out",
         openCollector = "open_collector", openEmitter = "open_emitter",
         noConnect = "no_connect"
}

enum KiCadPinShape: String {
    case line, inverted, clock, invertedClock = "inverted_clock",
         inputLow = "input_low", clockLow = "clock_low", outputLow = "output_low",
         edgeClockHigh = "edge_clock_high", nonLogic = "non_logic"
}

struct KiCadPin {
    var number: String
    var name: String
    var type: KiCadPinType
    var shape: KiCadPinShape
    var x: Double
    var y: Double
    var rotation: Double
    var length: Double
    var hidden: Bool
    var nameSize: Double
    var numberSize: Double
}

enum KiCadGraphic {
    case rectangle(x1: Double, y1: Double, x2: Double, y2: Double,
                   strokeWidth: Double, strokeType: String, fill: String)
    case circle(cx: Double, cy: Double, r: Double,
                strokeWidth: Double, strokeType: String, fill: String)
    case arc(sx: Double, sy: Double, mx: Double, my: Double, ex: Double, ey: Double,
             strokeWidth: Double, strokeType: String, fill: String)
    case polyline(points: [(Double, Double)],
                  strokeWidth: Double, strokeType: String, fill: String)
    case bezier(p1: (Double, Double), p2: (Double, Double),
                p3: (Double, Double), p4: (Double, Double),
                strokeWidth: Double, strokeType: String, fill: String)
    case text(string: String, x: Double, y: Double, rotation: Double, size: Double,
              bold: Bool, italic: Bool, hJustify: String, vJustify: String)
}

struct KiCadUnitDef {
    var graphics: [KiCadGraphic] = []
    var pins: [KiCadPin] = []
}

struct KiCadSymbolDef {
    var name: String
    var library: String
    /// Merged properties (child wins by name); order = child's first.
    var properties: [KiCadProperty]
    /// Key = unit number (0 = common to all units). Style 1 only.
    var units: [Int: KiCadUnitDef]
    /// Max unit key excluding 0; 1 when there are no numbered units.
    var unitCount: Int
    var extendsName: String?
    /// From (pin_names (offset v)); KiCad default 0.508 mm (0.02").
    var pinNameOffset: Double
    /// (pin_names ... (hide yes)) — pin names not drawn when true.
    var pinNamesHidden: Bool = false
    /// (pin_numbers (hide yes)) — pin numbers not drawn when true.
    var pinNumbersHidden: Bool = false
    /// The symbol node carries a (power global) / (power local) marker
    /// (after extends merge).
    var isPowerSymbol: Bool = false

    func property(_ name: String) -> String? {
        properties.first(where: { $0.name == name })?.value
    }

    /// Letters of the Reference property before any digit ("R", "U", "IC").
    /// A leading "#" (power symbols) is stripped; falls back to "U".
    var referencePrefix: String {
        let reference = property("Reference") ?? ""
        let stripped = reference.hasPrefix("#") ? String(reference.dropFirst()) : reference
        let prefix = String(stripped.prefix(while: { $0.isLetter }))
        return prefix.isEmpty ? "U" : prefix
    }

    /// Power symbols carry a (power ...) node and/or a Reference
    /// starting with "#" (e.g. "#PWR").
    var isPower: Bool {
        isPowerSymbol || (property("Reference") ?? "").hasPrefix("#")
    }
}

struct KiCadLibrary {
    /// File base name without the .kicad_sym extension.
    var name: String
    /// Fully resolved (extends merged) definitions of every placeable root.
    var symbols: [String: KiCadSymbolDef] = [:]
    /// One entry per skipped symbol / resolution problem, human-readable.
    var parseErrors: [String] = []

    static func parse(name: String, text: String) throws -> KiCadLibrary {
        let root = try SExpr.parse(text)
        var library = KiCadLibrary(name: name)
        guard case .list = root, root.items.first?.atomValue == "kicad_symbol_lib" else {
            library.parseErrors.append("\(name): root node is not (kicad_symbol_lib ...); no symbols loaded")
            return library
        }

        // Pass 1: read every top-level symbol into a raw, unresolved form.
        var raws: [String: RawSymbol] = [:]
        var order: [String] = []
        for node in root.children("symbol") {
            guard let raw = parseRawSymbol(node) else {
                library.parseErrors.append("\(name): skipped a top-level symbol with no readable name")
                continue
            }
            if raws[raw.name] == nil { order.append(raw.name) }
            raws[raw.name] = raw
        }

        // Pass 2: resolve extends chains within this library.
        var resolved: [String: KiCadSymbolDef] = [:]
        var resolving: Set<String> = []
        var resolveErrors: [String] = []

        func resolve(_ symbolName: String) -> KiCadSymbolDef? {
            if let cached = resolved[symbolName] { return cached }
            guard let raw = raws[symbolName] else { return nil }
            if resolving.contains(symbolName) {
                resolveErrors.append("\(name): extends cycle detected at '\(symbolName)'; treated as having no parent")
                return nil
            }
            resolving.insert(symbolName)
            defer { resolving.remove(symbolName) }

            var parent: KiCadSymbolDef?
            if let parentName = raw.extendsName {
                parent = resolve(parentName)
                if parent == nil {
                    resolveErrors.append("\(name): '\(symbolName)' extends '\(parentName)', which is not in this library")
                }
            }

            // Properties: child's own first (in file order), then the
            // parent's properties the child does not override.
            var properties = raw.properties
            if let parent {
                let ownNames = Set(raw.properties.map { $0.name })
                properties += parent.properties.filter { !ownNames.contains($0.name) }
            }

            // Units: the most-derived def that defines a unit wins wholesale.
            var units = parent?.units ?? [:]
            for (unit, unitDef) in raw.units {
                units[unit] = unitDef
            }

            let def = KiCadSymbolDef(
                name: symbolName,
                library: name,
                properties: properties,
                units: units,
                unitCount: units.keys.filter { $0 > 0 }.max() ?? 1,
                extendsName: raw.extendsName,
                pinNameOffset: raw.pinNameOffset ?? parent?.pinNameOffset ?? 0.508,
                pinNamesHidden: raw.pinNamesHidden ?? parent?.pinNamesHidden ?? false,
                pinNumbersHidden: raw.pinNumbersHidden ?? parent?.pinNumbersHidden ?? false,
                isPowerSymbol: raw.hasPowerMarker ?? parent?.isPowerSymbol ?? false
            )
            resolved[symbolName] = def
            return def
        }

        for symbolName in order {
            if let def = resolve(symbolName) {
                library.symbols[symbolName] = def
            }
        }
        library.parseErrors += resolveErrors
        return library
    }
}

// MARK: - Raw (unresolved) symbol form

private struct RawSymbol {
    var name: String
    var extendsName: String?
    var properties: [KiCadProperty] = []
    var units: [Int: KiCadUnitDef] = [:]
    var pinNameOffset: Double?
    /// Non-nil when a (pin_names ...) node is present (its hide state,
    /// false when the node carries no (hide yes)).
    var pinNamesHidden: Bool?
    /// Non-nil when a (pin_numbers ...) node is present.
    var pinNumbersHidden: Bool?
    /// Non-nil (true) when a (power global)/(power local) node is present.
    var hasPowerMarker: Bool?
}

private func parseRawSymbol(_ node: SExpr) -> RawSymbol? {
    guard let name = node.value(1) else { return nil }
    var raw = RawSymbol(name: name)
    for item in node.items {
        guard case .list(let children) = item,
              let head = children.first?.atomValue else { continue }
        switch head {
        case "extends":
            raw.extendsName = item.value(1)
        case "property":
            if var property = parseProperty(item) {
                // KiCad 10 property nodes carry no (id ...); ids are the
                // sequential index in file order.
                property.id = raw.properties.count
                raw.properties.append(property)
            }
        case "power":
            // (power global) / (power local) — any value marks a power symbol.
            raw.hasPowerMarker = true
        case "pin_names":
            if let offset = item.child("offset")?.double(1) {
                raw.pinNameOffset = offset
            }
            raw.pinNamesHidden = nodeHides(item)
        case "pin_numbers":
            raw.pinNumbersHidden = nodeHides(item)
        case "symbol":
            parseSubSymbol(item, into: &raw)
        default:
            break // exclude_from_sim, in_bom, on_board, in_pos_files,
                  // duplicate_pin_numbers_are_jumpers, embedded_fonts,
                  // generator_version, ... ignored
        }
    }
    return raw
}

/// Sub-symbols are nested inside their parent and named "Parent_<unit>_<style>".
/// The parent name may itself contain underscores, so only the LAST two
/// underscore-separated integers are the unit/style pair.
private func unitAndStyle(ofSubSymbolName subName: String) -> (unit: Int, style: Int)? {
    let parts = subName.split(separator: "_")
    guard parts.count >= 3,
          let unit = Int(parts[parts.count - 2]),
          let style = Int(parts[parts.count - 1]) else { return nil }
    return (unit, style)
}

private func parseSubSymbol(_ node: SExpr, into raw: inout RawSymbol) {
    guard let subName = node.value(1),
          let (unit, style) = unitAndStyle(ofSubSymbolName: subName) else { return }
    guard style == 1 else { return } // De Morgan (style 2) not used in part 1
    var unitDef = KiCadUnitDef()
    for item in node.items {
        guard case .list(let children) = item,
              let head = children.first?.atomValue else { continue }
        if head == "pin" {
            if let pin = parsePin(item) {
                unitDef.pins.append(pin)
            }
        } else if let graphic = parseGraphic(item) {
            unitDef.graphics.append(graphic)
        }
    }
    if var existing = raw.units[unit] {
        existing.graphics += unitDef.graphics
        existing.pins += unitDef.pins
        raw.units[unit] = existing
    } else {
        raw.units[unit] = unitDef
    }
}

// MARK: - Properties

private func parseProperty(_ node: SExpr) -> KiCadProperty? {
    // KiCad 10 has a (property private "Name" "Value" ...) variant — a
    // bare `private` atom before the name (60 KLC review-note properties
    // in the 10.0.1 corpus). Skip the marker so name/value stay aligned.
    let nameIndex = node.value(1) == "private" ? 2 : 1
    guard let name = node.value(nameIndex) else { return nil }
    let at = node.child("at")
    var fontSize = 1.27
    if let effects = node.child("effects"),
       let size = effects.child("font")?.child("size")?.double(1) {
        fontSize = size
    }
    return KiCadProperty(
        name: name,
        value: node.value(nameIndex + 1) ?? "",
        id: 0, // placeholder — parseRawSymbol assigns the sequential index
        x: at?.double(1) ?? 0,
        y: at?.double(2) ?? 0,
        rotation: at?.double(3) ?? 0,
        // KiCad 10: a direct (hide yes) child of the property node.
        // Legacy: a bare `hide` atom inside (effects ...). Both are
        // covered by searching the property node's own subtree.
        // (show_name ...) / (do_not_autoplace ...) are ignored.
        hidden: subtreeHides(node),
        fontSize: fontSize
    )
}

/// Direct-children hide check: true when the node has a bare `hide` atom
/// child or a `(hide yes)` child list (`(hide no)` / a missing value
/// count as shown / hidden respectively). Used for (pin_names ...) and
/// (pin_numbers ...) nodes.
private func nodeHides(_ node: SExpr) -> Bool {
    for item in node.items {
        if case .atom(let atom) = item, atom == "hide" { return true }
        if case .list(let children) = item,
           children.first?.atomValue == "hide" {
            return (item.value(1) ?? "yes") != "no"
        }
    }
    return false
}

/// True when a bare `hide` atom or a `(hide yes)` list appears anywhere
/// in the subtree. Only atoms / list heads are matched, never quoted
/// strings, so a value that happens to read "hide" cannot trigger this.
private func subtreeHides(_ node: SExpr) -> Bool {
    for item in node.items {
        if case .atom(let atom) = item, atom == "hide" { return true }
        guard case .list(let children) = item,
              let head = children.first?.atomValue else { continue }
        if head == "hide" { return (item.value(1) ?? "yes") != "no" }
        if subtreeHides(item) { return true }
    }
    return false
}

// MARK: - Pins

private func parsePin(_ node: SExpr) -> KiCadPin? {
    let at = node.child("at")
    var name = ""
    var number = ""
    var nameSize = 1.27
    var numberSize = 1.27
    if let nameNode = node.child("name") {
        name = nameNode.value(1) ?? ""
        if let size = effectFontSize(of: nameNode) { nameSize = size }
    }
    if let numberNode = node.child("number") {
        number = numberNode.value(1) ?? ""
        if let size = effectFontSize(of: numberNode) { numberSize = size }
    }
    return KiCadPin(
        number: number,
        name: name,
        type: KiCadPinType(rawValue: node.value(1) ?? "") ?? .unspecified,
        shape: KiCadPinShape(rawValue: node.value(2) ?? "") ?? .line,
        x: at?.double(1) ?? 0,
        y: at?.double(2) ?? 0,
        rotation: at?.double(3) ?? 0,
        length: node.child("length")?.double(1) ?? 2.54,
        hidden: pinIsHidden(node),
        nameSize: nameSize,
        numberSize: numberSize
    )
}

/// Font height from a node's (effects (font (size h w))) subtree.
private func effectFontSize(of node: SExpr) -> Double? {
    node.child("effects")?.child("font")?.child("size")?.double(1)
}

/// A pin is hidden when its node carries a `(hide yes)` child (KiCad 10,
/// written after (length ...)) or, in older files, a bare `hide` atom.
/// The (name ...), (number ...) and (alternate ...) subtrees are not
/// searched, so their content can never trigger this.
private func pinIsHidden(_ pinNode: SExpr) -> Bool {
    func search(_ node: SExpr) -> Bool {
        for item in node.items {
            if case .atom(let atom) = item, atom == "hide" { return true }
            guard case .list(let children) = item,
                  let head = children.first?.atomValue else { continue }
            if head == "hide" { return (item.value(1) ?? "yes") != "no" }
            if head == "name" || head == "number" || head == "alternate" { continue }
            if search(item) { return true }
        }
        return false
    }
    return search(pinNode)
}

// MARK: - Graphics

private func strokeOf(_ node: SExpr) -> (width: Double, type: String) {
    // The type string is stored as-is; KiCad's "default" (theme stroke)
    // is a real value in the files and renderers treat it as solid.
    guard let stroke = node.child("stroke") else { return (0, "default") }
    return (stroke.child("width")?.double(1) ?? 0,
            stroke.child("type")?.value(1) ?? "default")
}

private func fillOf(_ node: SExpr) -> String {
    node.child("fill")?.child("type")?.value(1) ?? "none"
}

/// The (x, y) pair of a point child such as (start x y) / (end x y).
private func pointOf(_ node: SExpr, _ head: String) -> (Double, Double)? {
    guard let point = node.child(head) else { return nil }
    return (point.double(1) ?? 0, point.double(2) ?? 0)
}

private func parseGraphic(_ node: SExpr) -> KiCadGraphic? {
    guard let head = node.items.first?.atomValue else { return nil }
    switch head {
    case "rectangle":
        guard let start = pointOf(node, "start"), let end = pointOf(node, "end") else { return nil }
        let stroke = strokeOf(node)
        return .rectangle(x1: start.0, y1: start.1, x2: end.0, y2: end.1,
                          strokeWidth: stroke.width, strokeType: stroke.type,
                          fill: fillOf(node))
    case "circle":
        guard let center = pointOf(node, "center"),
              let radius = node.child("radius")?.double(1) else { return nil }
        let stroke = strokeOf(node)
        return .circle(cx: center.0, cy: center.1, r: radius,
                       strokeWidth: stroke.width, strokeType: stroke.type,
                       fill: fillOf(node))
    case "arc":
        guard let start = pointOf(node, "start"),
              let mid = pointOf(node, "mid"),
              let end = pointOf(node, "end") else { return nil }
        let stroke = strokeOf(node)
        return .arc(sx: start.0, sy: start.1, mx: mid.0, my: mid.1, ex: end.0, ey: end.1,
                    strokeWidth: stroke.width, strokeType: stroke.type,
                    fill: fillOf(node))
    case "polyline":
        guard let pts = node.child("pts") else { return nil }
        let points = pts.children("xy").map { ($0.double(1) ?? 0, $0.double(2) ?? 0) }
        guard points.count >= 2 else { return nil }
        let stroke = strokeOf(node)
        return .polyline(points: points,
                         strokeWidth: stroke.width, strokeType: stroke.type,
                         fill: fillOf(node))
    case "bezier":
        guard let pts = node.child("pts") else { return nil }
        let points = pts.children("xy").map { ($0.double(1) ?? 0, $0.double(2) ?? 0) }
        guard points.count >= 4 else { return nil }
        let stroke = strokeOf(node)
        return .bezier(p1: points[0], p2: points[1], p3: points[2], p4: points[3],
                       strokeWidth: stroke.width, strokeType: stroke.type,
                       fill: fillOf(node))
    case "text":
        return parseTextGraphic(node)
    default:
        return nil
    }
}

private func parseTextGraphic(_ node: SExpr) -> KiCadGraphic? {
    let at = node.child("at")
    var size = 1.27
    var bold = false
    var italic = false
    var hJustify = "center"
    var vJustify = "center"
    if let effects = node.child("effects") {
        if let font = effects.child("font") {
            if let fontHeight = font.child("size")?.double(1) {
                size = fontHeight
            }
            // KiCad writes bold/italic either as bare atoms inside
            // (font ...) or as (bold yes) / (italic yes) sublists.
            for item in font.items {
                if case .atom(let atom) = item {
                    if atom == "bold" { bold = true }
                    if atom == "italic" { italic = true }
                }
            }
            if let boldNode = font.child("bold") {
                bold = (boldNode.value(1) ?? "yes") != "no"
            }
            if let italicNode = font.child("italic") {
                italic = (italicNode.value(1) ?? "yes") != "no"
            }
        }
        if let justify = effects.child("justify") {
            for item in justify.items {
                guard let atom = item.atomValue else { continue }
                switch atom {
                case "left", "right", "center":
                    hJustify = atom
                case "top", "bottom":
                    vJustify = atom
                default:
                    break // "mirror" and the head atom itself land here / are ignored
                }
            }
        }
    }
    return .text(string: node.value(1) ?? "",
                 x: at?.double(1) ?? 0,
                 y: at?.double(2) ?? 0,
                 rotation: at?.double(3) ?? 0,
                 size: size, bold: bold, italic: italic,
                 hJustify: hJustify, vJustify: vJustify)
}

// MARK: - Light header pass (index building)

/// The index-building view of one top-level symbol: just its name, its
/// (extends ...) target, and its direct property name/value pairs.
/// Graphics, pins and sub-symbols are NOT read — the full library set is
/// ~260 MB of text, so bootstrap works from headers only and full parses
/// happen per library on demand via KiCadLibrary.parse.
struct KiCadSymbolHeader {
    var name: String
    var extendsName: String?
    /// Direct (property "N" "V") pairs of this symbol node only;
    /// the first occurrence of a name wins.
    var properties: [String: String]
}

extension KiCadLibrary {
    /// Tokenize `text` once and walk ONLY the top-level (symbol ...)
    /// nodes, extracting a header per symbol. Returns [] when the text
    /// is not a readable (kicad_symbol_lib ...) document.
    static func symbolHeaders(text: String) -> [KiCadSymbolHeader] {
        guard let root = try? SExpr.parse(text),
              case .list = root,
              root.items.first?.atomValue == "kicad_symbol_lib" else { return [] }
        var headers: [KiCadSymbolHeader] = []
        for node in root.children("symbol") {
            guard let name = node.value(1) else { continue }
            var header = KiCadSymbolHeader(
                name: name,
                extendsName: node.child("extends")?.value(1),
                properties: [:]
            )
            for propertyNode in node.children("property") {
                // (property private "Name" "Value" ...) — skip the marker.
                let nameIndex = propertyNode.value(1) == "private" ? 2 : 1
                guard let propertyName = propertyNode.value(nameIndex),
                      let propertyValue = propertyNode.value(nameIndex + 1) else { continue }
                if header.properties[propertyName] == nil {
                    header.properties[propertyName] = propertyValue
                }
            }
            headers.append(header)
        }
        return headers
    }
}
