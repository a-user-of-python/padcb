import Foundation

/// GeomDump — headless geometry audit harness for PadCB.
///
/// Compiled together with the app's REAL geometry sources
/// (App/PadCB/SExpr.swift, KiCadSymbol.swift, SchematicDocument.swift,
/// SymbolDrawList.swift) so the canonical draw lists and placement
/// transforms dumped here are produced by the exact code the app
/// renders with — not by a port.
///
/// Usage: GeomDump <symbolsDir> <dumpOut.jsonl> <probesOut.jsonl>
///
/// Dump file: one JSON object per (library, symbol, unit) for units
/// 1...unitCount (unit 0 / common items are merged in by the builder,
/// exactly as the renderer merges them). Numbers are printed with
/// %.17g (full Double precision). See tools/GeomDump/README.md for
/// the field-by-field schema.
///
/// Probe file: placed pin world points for a small fixture set,
/// computed with the real SymbolDrawList.transformPoint via
/// pinWorldPoints, for rotation in {0, 90, 180, 270} x mirrorX x
/// mirrorY, at origin (0, 0).
///
/// Parse problems never abort the run: they are counted and logged
/// to stderr, and the exit status stays 0.

// MARK: - JSON writing (manual, for full-precision numbers)

func jnum(_ v: Double) -> String {
    if !v.isFinite { return "0" } // defensive: JSON has no NaN/Inf
    return String(format: "%.17g", v)
}

func jbool(_ b: Bool) -> String { b ? "true" : "false" }

func jstr(_ s: String) -> String {
    var out = "\""
    for scalar in s.unicodeScalars {
        switch scalar.value {
        case 0x22: out += "\\\""
        case 0x5C: out += "\\\\"
        case 0x0A: out += "\\n"
        case 0x0D: out += "\\r"
        case 0x09: out += "\\t"
        default:
            if scalar.value < 0x20 {
                out += String(format: "\\u%04x", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    out += "\""
    return out
}

func jxy(_ x: Double, _ y: Double) -> String {
    "[\(jnum(x)),\(jnum(y))]"
}

func jpt(_ p: CGPoint) -> String {
    jxy(Double(p.x), Double(p.y))
}

func jruns(_ runs: [KiCadText.Run]) -> String {
    "[" + runs.map {
        "{\"text\":\(jstr($0.text)),\"sub\":\(jbool($0.sub)),\"sup\":\(jbool($0.sup)),\"overbar\":\(jbool($0.overbar))}"
    }.joined(separator: ",") + "]"
}

func glyphJSON(_ g: SymbolDrawList.Glyph) -> String {
    switch g {
    case .bubble(let center, let radius):
        return "{\"kind\":\"bubble\",\"c\":\(jpt(center)),\"r\":\(jnum(radius))}"
    case .wedge(let points):
        return "{\"kind\":\"wedge\",\"pts\":[\(points.map(jpt).joined(separator: ","))]}"
    case .x(let at, let half):
        return "{\"kind\":\"x\",\"at\":\(jpt(at)),\"d\":\(jnum(half))}"
    }
}

func pinJSON(_ pg: SymbolDrawList.PinGeom) -> String {
    let pin = pg.pin
    return "{\"num\":\(jstr(pin.number)),\"name\":\(jstr(pin.name)),\"plainName\":\(jstr(pg.plainName)),"
        + "\"hidden\":\(jbool(pin.hidden)),\"type\":\(jstr(pin.type.rawValue)),\"shape\":\(jstr(pin.shape.rawValue)),"
        + "\"conn\":\(jpt(pg.conn)),\"root\":\(jpt(pg.root)),\"angle\":\(jnum(pin.rotation)),\"len\":\(jnum(pin.length)),"
        + "\"nameSize\":\(jnum(pin.nameSize)),\"numSize\":\(jnum(pin.numberSize)),"
        + "\"nameAnchor\":\(jpt(pg.nameAnchor)),\"numAnchor\":\(jpt(pg.numberAnchor)),"
        + "\"glyphs\":[\(pg.glyphs.map(glyphJSON).joined(separator: ","))]}"
}

func strokeJSON(_ w: Double, _ t: String, _ f: String) -> String {
    "\"strokeW\":\(jnum(w)),\"strokeType\":\(jstr(t)),\"fill\":\(jstr(f))"
}

func gfxJSON(_ g: SymbolDrawList.GraphicGeom) -> String {
    switch g {
    case .rectangle(let x1, let y1, let x2, let y2, let w, let t, let f):
        // Corners in the renderer's trace order:
        // (x1, y1) -> (x2, y1) -> (x2, y2) -> (x1, y2).
        let corners = [jxy(x1, y1), jxy(x2, y1), jxy(x2, y2), jxy(x1, y2)].joined(separator: ",")
        return "{\"kind\":\"rect\",\"corners\":[\(corners)],\(strokeJSON(w, t, f))}"
    case .circle(let cx, let cy, let r, let w, let t, let f):
        return "{\"kind\":\"circle\",\"c\":\(jxy(cx, cy)),\"r\":\(jnum(r)),\(strokeJSON(w, t, f))}"
    case .arc(let sx, let sy, let mx, let my, let ex, let ey, let sampled, let w, let t, let f):
        return "{\"kind\":\"arc\",\"start\":\(jxy(sx, sy)),\"mid\":\(jxy(mx, my)),\"end\":\(jxy(ex, ey)),"
            + "\"pts\":[\(sampled.map(jpt).joined(separator: ","))],\(strokeJSON(w, t, f))}"
    case .polyline(let points, let w, let t, let f):
        let pts = points.map { jxy($0.0, $0.1) }.joined(separator: ",")
        return "{\"kind\":\"poly\",\"pts\":[\(pts)],\(strokeJSON(w, t, f))}"
    case .bezier(let p1, let p2, let p3, let p4, let w, let t, let f):
        // pts = the 4 control points in order (start, c1, c2, end).
        let pts = [jxy(p1.0, p1.1), jxy(p2.0, p2.1), jxy(p3.0, p3.1), jxy(p4.0, p4.1)].joined(separator: ",")
        return "{\"kind\":\"bezier\",\"pts\":[\(pts)],\(strokeJSON(w, t, f))}"
    case .text(let string, let x, let y, let rotation, let size, let bold, let italic,
               let hJustify, let vJustify, let plain, let runs):
        // Text graphics carry no stroke/fill in the file format: null.
        return "{\"kind\":\"text\",\"text\":\(jstr(string)),\"plain\":\(jstr(plain)),\"runs\":\(jruns(runs)),"
            + "\"at\":\(jxy(x, y)),\"rot\":\(jnum(rotation)),\"size\":\(jnum(size)),"
            + "\"bold\":\(jbool(bold)),\"italic\":\(jbool(italic)),"
            + "\"hJustify\":\(jstr(hJustify)),\"vJustify\":\(jstr(vJustify)),"
            + "\"strokeW\":null,\"strokeType\":null,\"fill\":null}"
    case .textBox(let string, let x, let y, let w, let h, let rotation, let size, let bold, let italic,
                  let hJustify, let vJustify, let sw, let st, let f, let plain, let runs):
        return "{\"kind\":\"textbox\",\"text\":\(jstr(string)),\"plain\":\(jstr(plain)),\"runs\":\(jruns(runs)),"
            + "\"at\":\(jxy(x, y)),\"w\":\(jnum(w)),\"h\":\(jnum(h)),\"rot\":\(jnum(rotation)),\"size\":\(jnum(size)),"
            + "\"bold\":\(jbool(bold)),\"italic\":\(jbool(italic)),"
            + "\"hJustify\":\(jstr(hJustify)),\"vJustify\":\(jstr(vJustify)),"
            + "\(strokeJSON(sw, st, f))}"
    }
}

// MARK: - Output plumbing

func eprint(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

func emit(_ handle: FileHandle, _ line: String) {
    handle.write(Data((line + "\n").utf8))
}

// MARK: - Fixture helpers

/// True when any unit (including unit 0) of the def carries a text or
/// text_box graphic with a non-zero rotation.
func hasRotatedText(_ def: KiCadSymbolDef) -> Bool {
    for (_, u) in def.units {
        for g in u.graphics {
            if case .text(_, _, _, let rotation, _, _, _, _, _) = g, rotation != 0 { return true }
            if case .textBox(_, _, _, _, _, let rotation, _, _, _, _, _, _, _, _) = g, rotation != 0 { return true }
        }
    }
    return false
}

/// Unit selection per fixture. 4001's "power unit" is its last unit
/// (the conventional layout for the 4xxx logic family: gate units
/// first, the power unit last).
func fixtureUnits(key: String, def: KiCadSymbolDef) -> [Int] {
    switch key {
    case "4xxx/4001":
        return Array(Set([1, def.unitCount])).sorted()
    case "4xxx/14528":
        return def.unitCount >= 1 ? Array(1...min(3, def.unitCount)) : []
    case "Amplifier_Operational/ADA4084-4":
        return def.unitCount >= 1 ? Array(1...min(5, def.unitCount)) : []
    default:
        return [1]
    }
}

func emitProbes(lib: String, def: KiCadSymbolDef, units: [Int], into handle: FileHandle) {
    for unit in units {
        for rot in [0, 90, 180, 270] {
            for mx in [false, true] {
                for my in [false, true] {
                    let placed = PlacedSymbol(id: UUID(), library: lib, symbolName: def.name,
                                              unit: unit, x: 0, y: 0, rotation: rot,
                                              mirrorX: mx, mirrorY: my, reference: "", value: "")
                    let pins = SymbolDrawList.pinWorldPoints(def: def, placed: placed)
                    let pinsJSON = pins.map {
                        "{\"num\":\(jstr($0.pin.number)),\"world\":\(jxy($0.point.x, $0.point.y))}"
                    }.joined(separator: ",")
                    emit(handle, "{\"lib\":\(jstr(lib)),\"sym\":\(jstr(def.name)),\"unit\":\(unit),"
                        + "\"rot\":\(rot),\"mx\":\(jbool(mx)),\"my\":\(jbool(my)),\"pins\":[\(pinsJSON)]}")
                }
            }
        }
    }
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count == 4 else {
    eprint("usage: GeomDump <symbolsDir> <dumpOut.jsonl> <probesOut.jsonl>")
    exit(2)
}
let symbolsDir = args[1]
let dumpPath = args[2]
let probesPath = args[3]

let fm = FileManager.default
let dirURL = URL(fileURLWithPath: symbolsDir)
let files: [String]
do {
    files = try fm.contentsOfDirectory(atPath: dirURL.path)
        .filter { $0.hasSuffix(".kicad_sym") }
        .sorted()
} catch {
    eprint("GeomDump: cannot list \(symbolsDir): \(error)")
    exit(1)
}

_ = fm.createFile(atPath: dumpPath, contents: nil)
_ = fm.createFile(atPath: probesPath, contents: nil)
guard let dumpHandle = try? FileHandle(forWritingTo: URL(fileURLWithPath: dumpPath)),
      let probesHandle = try? FileHandle(forWritingTo: URL(fileURLWithPath: probesPath)) else {
    eprint("GeomDump: cannot open output files for writing")
    exit(1)
}

let wantedFixtures: [String] = ["Device/R", "4xxx/4001", "4xxx/14528", "Amplifier_Operational/ADA4084-4"]
var fixtureDefs: [String: (lib: String, def: KiCadSymbolDef)] = [:]
var rotatedFixture: (lib: String, def: KiCadSymbolDef)?

var totalParseErrors = 0
var totalSymbols = 0
var totalUnitDumps = 0

for file in files {
    let libName = String(file.dropLast(".kicad_sym".count))
    let path = dirURL.appendingPathComponent(file).path
    let text: String
    do {
        text = try String(contentsOfFile: path, encoding: .utf8)
    } catch {
        eprint("GeomDump: \(file): read failed: \(error)")
        totalParseErrors += 1
        continue
    }
    let library: KiCadLibrary
    do {
        library = try KiCadLibrary.parse(name: libName, text: text)
    } catch {
        eprint("GeomDump: \(libName): parse threw: \(error)")
        totalParseErrors += 1
        continue
    }
    if !library.parseErrors.isEmpty {
        eprint("GeomDump: \(libName): \(library.parseErrors.count) parse errors")
        totalParseErrors += library.parseErrors.count
    }
    for symName in library.symbols.keys.sorted() {
        guard let def = library.symbols[symName] else { continue }
        totalSymbols += 1
        let key = "\(libName)/\(symName)"
        if wantedFixtures.contains(key) {
            fixtureDefs[key] = (libName, def)
        }
        if rotatedFixture == nil, hasRotatedText(def) {
            rotatedFixture = (libName, def)
        }
        guard def.unitCount >= 1 else { continue }
        for unit in 1...def.unitCount {
            let drawList = SymbolDrawList.build(def: def, unit: unit, pinNameOffset: def.pinNameOffset)
            let pinsJSON = drawList.pins.map(pinJSON).joined(separator: ",")
            let gfxJSON = drawList.graphics.map(gfxJSON).joined(separator: ",")
            emit(dumpHandle, "{\"lib\":\(jstr(libName)),\"sym\":\(jstr(symName)),\"unit\":\(unit),"
                + "\"pins\":[\(pinsJSON)],\"gfx\":[\(gfxJSON)]}")
            totalUnitDumps += 1
        }
    }
}

// Probes for the named fixtures (deterministic order), then the
// auto-discovered rotated-text fixture.
for key in wantedFixtures {
    if let fixture = fixtureDefs[key] {
        emitProbes(lib: fixture.lib, def: fixture.def,
                   units: fixtureUnits(key: key, def: fixture.def), into: probesHandle)
    } else {
        eprint("GeomDump: fixture \(key) not found in corpus; probes skipped for it")
    }
}
if let fixture = rotatedFixture {
    emitProbes(lib: fixture.lib, def: fixture.def, units: [1], into: probesHandle)
    eprint("GeomDump: rotated-text fixture: \(fixture.lib)/\(fixture.def.name) unit 1")
} else {
    eprint("GeomDump: no symbol with rotated text found; rotated-text probes skipped")
}

try? dumpHandle.close()
try? probesHandle.close()
eprint("GeomDump: files=\(files.count) symbols=\(totalSymbols) unitDumps=\(totalUnitDumps) parseErrors=\(totalParseErrors)")
