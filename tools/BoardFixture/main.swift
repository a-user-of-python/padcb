import Foundation

/// BoardFixture — headless pin↔pad correspondence proof for PadCB
/// part 3 (Lane C).
///
/// Compiled together with the app's REAL sources so the board model
/// asserted here is produced by the exact code the PCB editor runs —
/// not by a port:
///
///   swiftc -o /tmp/BoardFixture \
///     App/PadCB/SExpr.swift \
///     App/PadCB/KiCadSymbol.swift \
///     App/PadCB/KiCadFootprint.swift \
///     App/PadCB/SchematicDocument.swift \
///     App/PadCB/SymbolDrawList.swift \
///     App/PadCB/ConnectionTable.swift \
///     App/PadCB/FootprintStore.swift \
///     App/PadCB/FootprintMatcher.swift \
///     App/PadCB/PadCBPaths.swift \
///     App/PadCB/PCBBoardModel.swift \
///     tools/BoardFixture/main.swift
///   /tmp/BoardFixture tools/board-fixtures
///
/// (macOS swiftc: SchematicDocument / FootprintStore use Combine,
/// which the command-line toolchain links fine — the same precedent
/// as tools/MatchCensus.)
///
/// The fixture, in tools/board-fixtures:
/// - FixtureSym.kicad_sym (library key "FixtureSym"): FIXIC, a
///   multi-unit part — unit 0 (common) pins 8 (VCC) + 7 (GND),
///   unit 1 pins 1 (IN_A), 2 (OUT_A), 9 (SPARE), unit 2 pins 3 (IN_B),
///   4 (OUT_B); Footprint property "FixtureFP:FIXIC_FP",
///   ki_fp_filters "FIXIC*". Plus FIXR, pins 1/2, Footprint
///   "FixtureFP:FIXR_FP".
/// - CustomLib.kicad_sym (library key "user:CustomLib"): CUSTDEV,
///   pins 1 (IN), 2 (OUT), Footprint "CustomFP:CUST_FP" — a CUSTOM
///   symbol whose footprint is a CUSTOM footprint, the steering-1
///   end-to-end case.
/// - FixtureFP.pretty/FIXIC_FP.kicad_mod: pads 1–8 (pad 1 thru-hole at
///   centre (−3.81, −2.54), 1.6×1.6 mm, drill 0.8), PLUS pad "10"
///   (no pin exists for it) and one pad with an EMPTY number
///   (mechanical).
/// - FixtureFP.pretty/FIXR_FP.kicad_mod: pads 1, 2.
/// - CustomFP.pretty/CUST_FP.kicad_mod: pads 1, 2; its FootprintEntry
///   is built with source .user, so its resolutionKey is
///   "user:CustomFP:CUST_FP".
///
/// Schematic: U1 = FIXIC placed twice (units 1 and 2, one physical
/// part), R1 = FIXR, X1 = CUSTDEV. Pin world points are COMPUTED via
/// SymbolDrawList.pinWorldPoints (never hardcoded); wires are routed
/// between the exact computed points and labelled:
///   U1 pin 1 ↔ R1 pin 1  "NET_A"
///   U1 pin 4 ↔ X1 pin 1  "NET_B"
///   U1 pin 8 ↔ X1 pin 2  "VCC"   (pin 8 comes from unit 0 via the
///                                 unit-1 instance)
/// The table is built with the REAL ConnectionTableBuilder +
/// FootprintMatcher, round-tripped through JSON (the encrypted
/// store's Codable path), and a hand-written v1-format JSON literal
/// (no footprintMatchKind key) is decoded to prove backward
/// compatibility. The BoardModel is then built from the round-tripped
/// table and asserted. Finally, the SYNC proof (v3.1): a mutated v2
/// table (one renamed net, one changed footprint choice) is rebuilt
/// through the same builder — the exact operation the PCB editor's
/// "Sync from Schematic" performs — and the rebuilt board plus
/// PCBBoardModelBuilder.diff are asserted. Any failure prints FAIL
/// lines and exits 1.

// MARK: - Assertion helpers

var passCount = 0
var failCount = 0

func check(_ condition: Bool, _ label: String) {
    if condition {
        passCount += 1
        print("PASS: \(label)")
    } else {
        failCount += 1
        print("FAIL: \(label)")
    }
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    check(actual == expected, "\(label) (got \(actual), want \(expected))")
}

func approx(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

func fatal(_ message: String) -> Never {
    print("FATAL: \(message)")
    exit(1)
}

// MARK: - Fixture loading

let args = CommandLine.arguments
let fixturesDir: String
if args.count >= 2 {
    fixturesDir = args[1]
} else {
    // tools/BoardFixture/main.swift -> ../board-fixtures
    fixturesDir = URL(fileURLWithPath: #file)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("board-fixtures")
        .path
}

func fixtureText(_ relativePath: String) -> String {
    let path = (fixturesDir as NSString).appendingPathComponent(relativePath)
    do {
        return try String(contentsOfFile: path, encoding: .utf8)
    } catch {
        fatal("cannot read fixture \(relativePath): \(error)")
    }
}

func loadLibrary(file: String, key: String) -> KiCadLibrary {
    do {
        let library = try KiCadLibrary.parse(name: key, text: fixtureText(file))
        if !library.parseErrors.isEmpty {
            fatal("\(file) parse errors: \(library.parseErrors.joined(separator: "; "))")
        }
        return library
    } catch {
        fatal("\(file) failed to parse: \(error)")
    }
}

let fixtureLib = loadLibrary(file: "FixtureSym.kicad_sym", key: "FixtureSym")
let customLib = loadLibrary(file: "CustomLib.kicad_sym", key: "user:CustomLib")

guard let fixicDef = fixtureLib.symbols["FIXIC"] else { fatal("FIXIC missing") }
guard let fixrDef = fixtureLib.symbols["FIXR"] else { fatal("FIXR missing") }
guard let custDef = customLib.symbols["CUSTDEV"] else { fatal("CUSTDEV missing") }

var defsByKey: [String: KiCadSymbolDef] = [:]
for (name, def) in fixtureLib.symbols { defsByKey["FixtureSym|\(name)"] = def }
for (name, def) in customLib.symbols { defsByKey["user:CustomLib|\(name)"] = def }

func loadEntry(group: String, name: String, file: String,
               source: FootprintSource) -> FootprintEntry {
    let relative = "\(group).pretty/\(file)"
    let parsed: KiCadFootprint
    do {
        parsed = try KiCadFootprint.parse(name: name, text: fixtureText(relative))
    } catch {
        fatal("\(relative) failed to parse: \(error)")
    }
    return FootprintEntry(
        source: source,
        group: group,
        name: name,
        fileName: file,
        relativePath: relative,
        url: URL(fileURLWithPath: (fixturesDir as NSString).appendingPathComponent(relative)),
        description: parsed.description,
        tags: parsed.tags,
        padCount: parsed.pads.count,
        distinctPadCount: FootprintStore.distinctPadCount(of: parsed),
        graphicCount: parsed.graphics.count,
        parsed: parsed)
}

let fixicEntry = loadEntry(group: "FixtureFP", name: "FIXIC_FP",
                           file: "FIXIC_FP.kicad_mod", source: .bundled)
let fixrEntry = loadEntry(group: "FixtureFP", name: "FIXR_FP",
                          file: "FIXR_FP.kicad_mod", source: .bundled)
let custEntry = loadEntry(group: "CustomFP", name: "CUST_FP",
                          file: "CUST_FP.kicad_mod", source: .user)
let entries = [fixicEntry, fixrEntry, custEntry]

checkEqual(custEntry.resolutionKey, "user:CustomFP:CUST_FP",
           "custom footprint entry resolutionKey carries the user: prefix")
checkEqual(fixicEntry.resolutionKey, "FixtureFP:FIXIC_FP",
           "bundled footprint entry resolutionKey is the plain key")

// MARK: - Schematic construction (pin points computed, not hardcoded)

func fixedUUID(_ string: String) -> UUID {
    guard let uuid = UUID(uuidString: string) else { fatal("bad fixture UUID \(string)") }
    return uuid
}

let u1Unit1 = PlacedSymbol(
    id: fixedUUID("11111111-1111-4111-8111-111111111111"),
    library: "FixtureSym", symbolName: "FIXIC", unit: 1,
    x: 25.40, y: 25.40, rotation: 0, mirrorX: false, mirrorY: false,
    reference: "U1", value: "FIXIC")
let u1Unit2 = PlacedSymbol(
    id: fixedUUID("22222222-2222-4222-8222-222222222222"),
    library: "FixtureSym", symbolName: "FIXIC", unit: 2,
    x: 25.40, y: 0, rotation: 0, mirrorX: false, mirrorY: false,
    reference: "U1", value: "FIXIC")
let r1 = PlacedSymbol(
    id: fixedUUID("33333333-3333-4333-8333-333333333333"),
    library: "FixtureSym", symbolName: "FIXR", unit: 1,
    x: 50.80, y: 25.40, rotation: 0, mirrorX: false, mirrorY: false,
    reference: "R1", value: "10k")
let x1 = PlacedSymbol(
    id: fixedUUID("44444444-4444-4444-8444-444444444444"),
    library: "user:CustomLib", symbolName: "CUSTDEV", unit: 1,
    x: 76.20, y: 25.40, rotation: 0, mirrorX: false, mirrorY: false,
    reference: "X1", value: "CUSTDEV")

func pinPoint(def: KiCadSymbolDef, placed: PlacedSymbol, number: String) -> DPoint {
    for entry in SymbolDrawList.pinWorldPoints(def: def, placed: placed)
    where entry.pin.number == number {
        return entry.point
    }
    fatal("pin \(number) of \(placed.reference) not found via pinWorldPoints")
}

/// Orthogonal wire from `a` to `b`. verticalFirst picks the V-then-H
/// route — chosen per wire so no segment passes through an unrelated
/// pin (a pin lying on a segment would join that net, KiCad's rule,
/// and the table builder implements it).
func wire(_ id: String, from a: DPoint, to b: DPoint,
          verticalFirst: Bool) -> WireItem {
    let corner = verticalFirst ? DPoint(x: a.x, y: b.y) : DPoint(x: b.x, y: a.y)
    var points = [a]
    if corner != a && corner != b { points.append(corner) }
    points.append(b)
    return WireItem(id: fixedUUID(id), points: points)
}

/// A point at parameter t along a wire's FIRST segment — labels must
/// lie exactly on a segment (or pin) to name the net.
func onFirstSegment(_ wireItem: WireItem, t: Double) -> DPoint {
    let a = wireItem.points[0], b = wireItem.points[1]
    return DPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
}

let u1Pin1 = pinPoint(def: fixicDef, placed: u1Unit1, number: "1")
let r1Pin1 = pinPoint(def: fixrDef, placed: r1, number: "1")
let wireA = wire("55555555-5555-4555-8555-555555555555",
                 from: u1Pin1, to: r1Pin1, verticalFirst: true)

let u1Pin4 = pinPoint(def: fixicDef, placed: u1Unit2, number: "4")
let x1Pin1 = pinPoint(def: custDef, placed: x1, number: "1")
let wireB = wire("66666666-6666-4666-8666-666666666666",
                 from: u1Pin4, to: x1Pin1, verticalFirst: false)

let u1Pin8 = pinPoint(def: fixicDef, placed: u1Unit1, number: "8")
let x1Pin2 = pinPoint(def: custDef, placed: x1, number: "2")
let wireVCC = wire("77777777-7777-4777-8777-777777777777",
                   from: u1Pin8, to: x1Pin2, verticalFirst: false)

let state = SchematicState(
    symbols: [u1Unit1, u1Unit2, r1, x1],
    wires: [wireA, wireB, wireVCC],
    junctions: [],
    labels: [
        LabelItem(id: fixedUUID("88888888-8888-4888-8888-888888888888"),
                  at: onFirstSegment(wireA, t: 0.5), text: "NET_A"),
        LabelItem(id: fixedUUID("99999999-9999-4999-8999-999999999999"),
                  at: onFirstSegment(wireB, t: 0.5), text: "NET_B"),
        LabelItem(id: fixedUUID("AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"),
                  at: onFirstSegment(wireVCC, t: 0.5), text: "VCC"),
    ],
    title: "Fixture Board")

// MARK: - Table build (real builder + real matcher)

let table = ConnectionTableBuilder.build(
    state: state,
    sourceFileName: "fixture.json",
    resolveSymbol: { placed in
        defsByKey["\(placed.library)|\(placed.symbolName)"]
    },
    resolveFootprint: { placed, def in
        let match = FootprintMatcher.match(def: def,
                                           choiceKey: placed.footprintChoice,
                                           entries: entries)
        return (key: match.resolved?.resolutionKey, kind: match.kind?.rawValue)
    })

checkEqual(table.components.count, 4,
           "table carries 4 placed instances (U1 twice, R1, X1)")
checkEqual(Set(table.nets.map(\.name)), Set(["NET_A", "NET_B", "VCC"]),
           "table nets are exactly NET_A, NET_B, VCC")

// JSON round-trip — the Codable path the encrypted store uses.
let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
encoder.outputFormatting = [.sortedKeys]
let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601
let roundTripped: ConnectionTable
do {
    let data = try encoder.encode(table)
    roundTripped = try decoder.decode(ConnectionTable.self, from: data)
} catch {
    fatal("table JSON round-trip failed: \(error)")
}
// generatedAt is excluded from the comparison: ISO-8601 encoding
// (the store's format) carries whole seconds only.
check(roundTripped.components == table.components
      && roundTripped.nets == table.nets
      && roundTripped.unresolvedSymbols == table.unresolvedSymbols
      && roundTripped.formatVersion == table.formatVersion,
      "table JSON round-trip preserves components, nets and unresolved list")

// Backward compatibility: a v1-format table written before part 3
// has NO footprintMatchKind key and must still decode (kind = nil).
let v1JSON = """
{"formatVersion":1,"schematicTitle":"Legacy","sourceFileName":"legacy.json",\
"generatedAt":"2026-01-01T00:00:00Z","components":[{"instanceID":\
"22222222-2222-4222-8222-222222222222","reference":"R9","unit":1,\
"library":"FixtureSym","symbolName":"FIXR","value":"10k",\
"footprintReference":"FixtureFP:FIXR_FP","resolvedFootprintKey":\
"FixtureFP:FIXR_FP"}],"nets":[],"unresolvedSymbols":[]}
"""
do {
    let v1 = try decoder.decode(ConnectionTable.self, from: Data(v1JSON.utf8))
    check(v1.components.first?.footprintMatchKind == nil,
          "v1 table without footprintMatchKind decodes with kind nil")
    checkEqual(v1.components.first?.resolvedFootprintKey ?? "",
               "FixtureFP:FIXR_FP",
               "v1 table keeps its resolvedFootprintKey")
} catch {
    check(false, "v1 table literal decodes (threw \(error))")
}

// MARK: - Board model

let board = PCBBoardModelBuilder.build(
    table: roundTripped,
    resolveSymbol: { library, name in defsByKey["\(library)|\(name)"] },
    resolveFootprint: { key in
        guard let entry = FootprintMatcher.entry(forResolutionKey: key, in: entries),
              let parsed = entry.parsed else { return nil }
        return (entry: entry, parsed: parsed)
    })

func component(_ reference: String) -> BoardComponent {
    guard let found = board.components.first(where: { $0.reference == reference })
    else { fatal("board is missing component \(reference)") }
    return found
}

func binding(_ component: BoardComponent, _ number: String) -> BoardPinBinding {
    guard let found = component.pins.first(where: { $0.pinNumber == number })
    else { fatal("\(component.reference) has no binding for pin \(number)") }
    return found
}

// No component is silently missing: exactly the three physical parts.
checkEqual(board.components.map(\.reference), ["R1", "U1", "X1"],
           "board components are exactly R1, U1, X1 in natural order")
checkEqual(board.netCount, 3, "board netCount is 3")
check(board.excludedPowerReferences.isEmpty,
      "no power references are excluded in this fixture")

// -- U1: the multi-unit part --
let u1 = component("U1")
checkEqual(u1.pins.map(\.pinNumber), ["1", "2", "3", "4", "7", "8", "9"],
           "U1 bindings cover pins 1,2,3,4,7,8 plus pad-less pin 9 (unit 0 + units 1+2)")
checkEqual(u1.pins.filter { $0.pad != nil }.map(\.pinNumber),
           ["1", "2", "3", "4", "7", "8"],
           "U1 pins 1,2,3,4,7,8 are the ones bound to real pads")
let u1Bind9 = binding(u1, "9")
check(u1Bind9.pad == nil, "U1 pin 9 binding has no pad (the anomaly below is its report)")
checkEqual(u1.footprintKey ?? "", "FixtureFP:FIXIC_FP",
           "U1 footprintKey is FixtureFP:FIXIC_FP")
checkEqual(u1.matchKind ?? "", "property",
           "U1 matchKind is property")

let u1Bind1 = binding(u1, "1")
checkEqual(u1Bind1.netName ?? "", "NET_A", "U1 pin 1 is on NET_A")
checkEqual(u1Bind1.pad?.number ?? "", "1", "U1 pin 1 binds to pad 1")
if let pad = u1Bind1.pad {
    check(approx(pad.x, -3.81) && approx(pad.y, -2.54),
          "U1 pin 1 pad centre is the fixture pad 1 centre (-3.81, -2.54) (got \(pad.x), \(pad.y))")
    check(approx(pad.width, 1.6) && approx(pad.height, 1.6),
          "U1 pin 1 pad size is 1.6x1.6 mm (got \(pad.width)x\(pad.height))")
    check(approx(pad.drill?.width ?? -1, 0.8),
          "U1 pin 1 pad drill is 0.8 mm (got \(pad.drill?.width ?? -1))")
} else {
    check(false, "U1 pin 1 has a pad")
}

let u1Bind4 = binding(u1, "4")
checkEqual(u1Bind4.netName ?? "", "NET_B", "U1 pin 4 is on NET_B")
checkEqual(u1Bind4.pad?.number ?? "", "4", "U1 pin 4 binds to pad 4")

let u1Bind8 = binding(u1, "8")
checkEqual(u1Bind8.netName ?? "", "VCC",
           "U1 pin 8 (common unit, via the unit-1 instance) is on VCC")
checkEqual(u1Bind8.pad?.number ?? "", "8", "U1 pin 8 binds to pad 8")

let u1Bind2 = binding(u1, "2")
check(u1Bind2.netName == nil && u1Bind2.pad != nil,
      "U1 pin 2 has a pad but no net (unconnected output)")

// Pin 9 exists in the symbol but not in the footprint -> anomaly.
// Pad 10 exists in the footprint but not in the symbol -> anomaly.
// (Per the builder's pinned rules these are PER-COMPONENT anomalies;
// the flattened problem surface the editor's Problems section shows
// is globalAnomalies + every component's anomalies, asserted below.)
check(u1.anomalies.contains { $0.contains("pin 9") && $0.contains("has no pad") },
      "U1 anomalies report pin 9 has no pad (got \(u1.anomalies))")
check(u1.anomalies.contains { $0.contains("pad 10") && $0.contains("not connected to any pin") },
      "U1 anomalies report pad 10 is not connected to any pin (got \(u1.anomalies))")
let allProblems = board.globalAnomalies
    + board.components.flatMap { $0.anomalies }
check(allProblems.contains { $0.contains("pin 9") && $0.contains("has no pad") }
      && allProblems.contains { $0.contains("pad 10") },
      "the board's flattened problem list mentions U1's pin-9 and pad-10 problems")

// The unnumbered mechanical pad is a NOTE, never an anomaly.
check(u1.notes.contains { $0.contains("unnumbered (mechanical)") },
      "U1 notes count the unnumbered (mechanical) pad (got \(u1.notes))")
check(!u1.anomalies.contains { $0.contains("unnumbered") },
      "the unnumbered pad is not an anomaly")

// -- R1 --
let r1Component = component("R1")
let r1Bind1 = binding(r1Component, "1")
checkEqual(r1Bind1.netName ?? "", "NET_A", "R1 pin 1 is on NET_A")
checkEqual(r1Bind1.pad?.number ?? "", "1", "R1 pin 1 binds to pad 1")
let r1Bind2 = binding(r1Component, "2")
check(r1Bind2.netName == nil, "R1 pin 2 has no net")
check(r1Bind2.pad != nil, "R1 pin 2 has a pad")
check(r1Component.anomalies.isEmpty,
      "R1 has no anomalies (got \(r1Component.anomalies))")

// -- X1: custom symbol + custom footprint (steering-1 end-to-end) --
let x1Component = component("X1")
checkEqual(x1Component.footprintKey ?? "", "user:CustomFP:CUST_FP",
           "X1 footprintKey is user:CustomFP:CUST_FP")
checkEqual(x1Component.matchKind ?? "", "property",
           "X1 matchKind is property")
let x1Pin1Binding = binding(x1Component, "1")
checkEqual(x1Pin1Binding.netName ?? "", "NET_B", "X1 pin 1 is on NET_B")
checkEqual(x1Pin1Binding.pad?.number ?? "", "1", "X1 pin 1 binds to pad 1")
if let pad = x1Pin1Binding.pad {
    check(approx(pad.x, -2.54) && approx(pad.y, 0),
          "X1 pin 1 pad centre is the custom footprint's pad 1 centre (-2.54, 0) (got \(pad.x), \(pad.y))")
} else {
    check(false, "X1 pin 1 has a pad")
}
let x1Pin2Binding = binding(x1Component, "2")
checkEqual(x1Pin2Binding.netName ?? "", "VCC", "X1 pin 2 is on VCC")
checkEqual(x1Pin2Binding.pad?.number ?? "", "2", "X1 pin 2 binds to pad 2")
check(x1Component.anomalies.isEmpty,
      "X1 has no anomalies (got \(x1Component.anomalies))")

// MARK: - Sync proof (v3.1): rebuild from a changed table

// The PCB editor's Sync is: re-decrypt the (possibly rewritten)
// table and run PCBBoardModelBuilder.build again, then diff. Here a
// v2 table is derived from the round-tripped v1 table with the two
// changes a schematic re-save would carry:
var tableV2 = roundTripped
// (a) A changed net: VCC renamed to VCC2. Endpoints reference
// instance + pin only, so renaming the net renames it for every
// endpoint at once (U1 pin 8, X1 pin 2).
if let vccIndex = tableV2.nets.firstIndex(where: { $0.name == "VCC" }) {
    tableV2.nets[vccIndex].name = "VCC2"
} else {
    fatal("VCC net missing from the v1 table")
}
// (b) A changed footprint choice: R1's instance now records an
// instance choice of the custom CUST_FP (2 pads, like FIXR_FP).
var r1Mutated = false
for index in tableV2.components.indices
where tableV2.components[index].reference == "R1" {
    tableV2.components[index].resolvedFootprintKey = "user:CustomFP:CUST_FP"
    tableV2.components[index].footprintMatchKind = "instanceChoice"
    r1Mutated = true
}
check(r1Mutated, "sync fixture: the v2 table carries R1's changed footprint choice")

let boardV2 = PCBBoardModelBuilder.build(
    table: tableV2,
    resolveSymbol: { library, name in defsByKey["\(library)|\(name)"] },
    resolveFootprint: { key in
        guard let entry = FootprintMatcher.entry(forResolutionKey: key, in: entries),
              let parsed = entry.parsed else { return nil }
        return (entry: entry, parsed: parsed)
    })

func componentV2(_ reference: String) -> BoardComponent {
    guard let found = boardV2.components.first(where: { $0.reference == reference })
    else { fatal("v2 board is missing component \(reference)") }
    return found
}

// The rebuilt board reflects v2, not v1:
checkEqual(binding(componentV2("U1"), "8").netName ?? "", "VCC2",
           "sync: U1 pin 8 follows the renamed net")
checkEqual(binding(componentV2("X1"), "2").netName ?? "", "VCC2",
           "sync: X1 pin 2 follows the renamed net")
checkEqual(binding(componentV2("U1"), "1").netName ?? "", "NET_A",
           "sync: an untouched net (NET_A) is unchanged")
let r1V2 = componentV2("R1")
checkEqual(r1V2.footprintKey ?? "", "user:CustomFP:CUST_FP",
           "sync: R1 footprint is the new instance choice")
checkEqual(r1V2.matchKind ?? "", "instanceChoice",
           "sync: R1 matchKind records the instance choice")
if let pad = binding(r1V2, "1").pad {
    check(approx(pad.x, -2.54) && approx(pad.y, 0),
          "sync: R1 pin 1 binds CUST_FP's pad 1 at (-2.54, 0) (got \(pad.x), \(pad.y))")
} else {
    check(false, "sync: R1 pin 1 has a pad after the footprint change")
}
check(r1V2.anomalies.isEmpty,
      "sync: R1 has no anomalies on its new footprint (got \(r1V2.anomalies))")

// And the diff the editor reports names exactly the touched parts:
let syncDiff = PCBBoardModelBuilder.diff(from: board, to: boardV2)
check(syncDiff.addedReferences.isEmpty,
      "sync diff: nothing added (got \(syncDiff.addedReferences))")
check(syncDiff.removedReferences.isEmpty,
      "sync diff: nothing removed (got \(syncDiff.removedReferences))")
checkEqual(Set(syncDiff.changedReferences), Set(["R1", "U1", "X1"]),
           "sync diff: R1 (footprint) + U1 and X1 (renamed net) changed")
checkEqual(syncDiff.oldNetCount, 3, "sync diff: old net count is 3")
checkEqual(syncDiff.newNetCount, 3, "sync diff: new net count is 3")
check(PCBBoardModelBuilder.diff(from: board, to: board).isEmpty,
      "sync diff: a board diffed with itself is empty (sync with no re-save reports no changes)")

// MARK: - Part 4: board state, traces, merge, visibility, filter

// -- Routing geometry: KiCad's 45° corner rule --
let cornerA = BoardGeometry.routeCorner(from: FPPoint(x: 0, y: 0),
                                        to: FPPoint(x: 10, y: 4))
check(cornerA != nil && approx(cornerA!.x, 4) && approx(cornerA!.y, 4),
      "route: (0,0)->(10,4) bends at (4,4) — a 45° segment, then straight")
check(BoardGeometry.routeCorner(from: FPPoint(x: 0, y: 0),
                                to: FPPoint(x: 10, y: 0)) == nil,
      "route: an axis-aligned run needs no corner")
check(BoardGeometry.routeCorner(from: FPPoint(x: 0, y: 0),
                                to: FPPoint(x: 6, y: -6)) == nil,
      "route: a perfect diagonal needs no corner")
let cornerB = BoardGeometry.routeCorner(from: FPPoint(x: 10, y: 10),
                                        to: FPPoint(x: 2, y: 4))
check(cornerB != nil && approx(cornerB!.x, 4) && approx(cornerB!.y, 4),
      "route: (10,10)->(2,4) bends at (4,4) — signs handled")

// -- Zoom metrics (Sean: "add more zoom, I can't get that close") --
checkEqual(BoardCanvasMetrics.maxScale, 150.0,
           "zoom: the ceiling is 150 pt/mm")
checkEqual(BoardCanvasMetrics.percent(forScale: 150), 6000,
           "zoom: 150 pt/mm reads as 6000%")
checkEqual(BoardCanvasMetrics.clamped(10_000), 150.0,
           "zoom: the clamp holds the ceiling")
checkEqual(BoardCanvasMetrics.percent(forScale: 2.5), 100,
           "zoom: 2.5 pt/mm still reads as 100%")

// -- Trace model: hit-testing follows the (resizeable) width --
var fixtureTrace = BoardTrace(
    id: fixedUUID("BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"),
    netName: "NET_A", layer: "F.Cu", width: 0.25,
    points: [FPPoint(x: 0, y: 0), FPPoint(x: 10, y: 0), FPPoint(x: 10, y: 10)])
check(BoardGeometry.traceHit(fixtureTrace, point: FPPoint(x: 5, y: 0.1),
                             tolerance: 0.05),
      "trace: a point on the copper is a hit")
check(!BoardGeometry.traceHit(fixtureTrace, point: FPPoint(x: 5, y: 1.0),
                              tolerance: 0.05),
      "trace: a point 1 mm off a 0.25 mm trace is a miss")
check(approx(fixtureTrace.length, 20),
      "trace: length sums its segments (10 + 10)")
fixtureTrace.width = 2.0
check(BoardGeometry.traceHit(fixtureTrace, point: FPPoint(x: 5, y: 0.9),
                             tolerance: 0.05),
      "trace: RESIZED to 2 mm, that same point is on the copper now")
fixtureTrace.width = 0.25

// -- Hit-testing against the real fixture board --
if let pad1 = binding(u1, "1").pad {
    let centre = BoardGeometry.padCenter(u1, pad1)
    if let hit = BoardGeometry.padAt(board, point: centre, tolerance: 0.1) {
        checkEqual(hit.component.reference, "U1",
                   "geometry: padAt names the owning component")
        checkEqual(hit.netName ?? "", "NET_A",
                   "geometry: padAt reports the pad's net (NET_A)")
    } else {
        check(false, "geometry: padAt finds U1 pad 1 at its centre")
    }
    checkEqual(BoardGeometry.componentAt(board, point: centre)?.reference ?? "",
               "U1", "geometry: componentAt finds U1 at its pad 1 centre")
} else {
    check(false, "geometry: U1 pad 1 exists for the hit tests")
}

// -- Board-state persistence through the real store --
let stateDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("padcb-boardfixture-\(ProcessInfo.processInfo.processIdentifier)")
var state1 = BoardState()
state1.placements = ["U1": FPPoint(x: 500, y: 500)]
state1.traces = [fixtureTrace,
                 BoardTrace(id: fixedUUID("CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"),
                            netName: "VCC", layer: "B.Cu", width: 0.5,
                            points: [FPPoint(x: 0, y: 20), FPPoint(x: 30, y: 20)])]
state1.graphics = [BoardGraphicItem(
    id: fixedUUID("DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD"),
    kind: .line, layer: "Dwgs.User",
    points: [FPPoint(x: 0, y: 0), FPPoint(x: 5, y: 5)])]
state1.knownReferences = ["R1", "U1", "X1"]
do {
    try BoardStateStore.save(state1, tableStem: "fixture", in: stateDir)
    let loaded = BoardStateStore.load(tableStem: "fixture", in: stateDir)
    check(loaded == state1,
          "board state: save/load through the real store is lossless")
} catch {
    check(false, "board state: the store round-trip threw \(error)")
}
check(BoardStateStore.load(tableStem: "no-such-board", in: stateDir) == BoardState.empty,
      "board state: a missing sidecar loads as the empty state")

// -- Merge on open: placements + traces + graphics carry --
let mergedLoad = PCBBoardMerger.apply(state: state1, to: board, isSync: false)
let u1Merged = mergedLoad.model.components.first { $0.reference == "U1" }!
check(approx(u1Merged.origin.x, 500) && approx(u1Merged.origin.y, 500),
      "merge: U1 keeps its saved placement (500, 500), not the shelf origin")
let r1Merged = mergedLoad.model.components.first { $0.reference == "R1" }!
check(!(approx(r1Merged.origin.x, 500) && approx(r1Merged.origin.y, 500)),
      "merge: R1 (never moved) keeps its shelf origin")
checkEqual(mergedLoad.model.traces.count, 2,
           "merge: both traces carry into the model")
checkEqual(mergedLoad.model.graphics.count, 1,
           "merge: the board graphic carries into the model")
check(mergedLoad.model.boardProblems.isEmpty,
      "merge: no problems while every trace's net exists")
checkEqual(Set(mergedLoad.stateToSave.knownReferences), Set(["R1", "U1", "X1"]),
           "merge: the canonical state records the board's references")

// -- Merge on sync to the v2 table (VCC renamed VCC2) --
let mergedSync = PCBBoardMerger.apply(state: state1, to: boardV2, isSync: true)
checkEqual(mergedSync.model.traces.count, 2,
           "sync merge: the orphaned trace is NOT dropped")
let orphaned = mergedSync.model.traces.first { $0.id == state1.traces[1].id }!
check(orphaned.netName == nil && orphaned.disconnectedNetName == "VCC",
      "sync merge: the VCC trace is unconnected and remembers its net")
check(mergedSync.model.boardProblems.contains { $0.contains("VCC") },
      "sync merge: the lost net appears in Problems, never silence")
checkEqual(mergedSync.report.disconnectedTraceIDs, [orphaned.id],
           "sync merge: the report names the disconnected trace")
let stillBound = mergedSync.model.traces.first { $0.id == state1.traces[0].id }!
checkEqual(stillBound.netName ?? "", "NET_A",
           "sync merge: the NET_A trace keeps its binding by name")
let u1Synced = mergedSync.model.components.first { $0.reference == "U1" }!
check(approx(u1Synced.origin.x, 500) && approx(u1Synced.origin.y, 500),
      "sync merge: U1's placement survives the sync")

// -- And when the net comes back, the trace rebinds --
let mergedBack = PCBBoardMerger.apply(state: mergedSync.stateToSave,
                                      to: board, isSync: true)
let rebound = mergedBack.model.traces.first { $0.id == state1.traces[1].id }!
checkEqual(rebound.netName ?? "", "VCC",
           "sync merge: when VCC returns, the trace rebinds by name")
check(rebound.disconnectedNetName == nil
      && mergedBack.model.boardProblems.isEmpty,
      "sync merge: the problem clears when the net returns")

// -- Deletion: excluded on open, restored + reported on sync --
var stateExcluded = state1
stateExcluded.excludedReferences = ["R1"]
let mergedExcluded = PCBBoardMerger.apply(state: stateExcluded,
                                          to: board, isSync: false)
checkEqual(mergedExcluded.model.components.map(\.reference), ["U1", "X1"],
           "merge (open): a deleted footprint stays off the board")
let mergedReAdded = PCBBoardMerger.apply(state: stateExcluded,
                                         to: board, isSync: true)
check(mergedReAdded.model.components.contains { $0.reference == "R1" },
      "merge (sync): the schematic restores the deleted footprint")
checkEqual(mergedReAdded.report.reAddedReferences, ["R1"],
           "merge (sync): the restore is REPORTED, never silent")
check(mergedReAdded.stateToSave.excludedReferences.isEmpty,
      "merge (sync): the exclusion is cleared once restored")

// -- Arrivals and removals across a sync --
var tableV3 = roundTripped
var r2Instance = tableV3.components.first { $0.reference == "R1" }!
r2Instance.reference = "R2"
r2Instance.instanceID = fixedUUID("EEEEEEEE-EEEE-4EEE-8EEE-EEEEEEEEEEEE")
tableV3.components.append(r2Instance)
let boardV3 = PCBBoardModelBuilder.build(
    table: tableV3,
    resolveSymbol: { library, name in defsByKey["\(library)|\(name)"] },
    resolveFootprint: { key in
        guard let entry = FootprintMatcher.entry(forResolutionKey: key, in: entries),
              let parsed = entry.parsed else { return nil }
        return (entry: entry, parsed: parsed)
    })
check(boardV3.components.contains { $0.reference == "R2" },
      "arrival fixture: the v3 board carries the new R2")
let mergedArrival = PCBBoardMerger.apply(state: state1, to: boardV3, isSync: true)
checkEqual(mergedArrival.report.arrivedReferences, ["R2"],
           "merge: a new schematic part is reported as arrived")
let r2Shelf = boardV3.components.first { $0.reference == "R2" }!
let r2Merged = mergedArrival.model.components.first { $0.reference == "R2" }!
check(r2Merged.origin == r2Shelf.origin,
      "merge: the arrived part keeps its (unplaced) shelf position")
var stateKnown = mergedArrival.stateToSave
stateKnown.placements["R2"] = FPPoint(x: 42, y: 42)
let mergedRemoval = PCBBoardMerger.apply(state: stateKnown, to: board, isSync: true)
checkEqual(mergedRemoval.report.removedReferences, ["R2"],
           "merge: a part removed from the schematic is reported")
check(mergedRemoval.stateToSave.placements["R2"] == nil,
      "merge: the vanished part's placement is pruned from the state")

// -- Visibility: the predicates the canvas draws through --
var vis = BoardVisibility()
let silkLine = KiCadFootprintGraphic.line(
    start: FPPoint(x: 0, y: 0), end: FPPoint(x: 1, y: 1),
    layer: "F.SilkS", strokeWidth: 0.12, strokeType: "solid", fill: "none")
check(vis.footprintGraphicShown(silkLine),
      "visibility: a silk graphic shows by default")
vis.hiddenLayers = ["F.SilkS"]
check(!vis.footprintGraphicShown(silkLine),
      "visibility: hiding F.SilkS hides its graphics — the eye is real")
vis.hiddenLayers = []
vis.showDrawings = false
check(!vis.footprintGraphicShown(silkLine),
      "visibility: Drawings off hides footprint graphics")
vis.showDrawings = true
let wildPad = KiCadFootprintPad(
    number: "1", type: .thruHole, shape: .circle, x: 0, y: 0, rotation: 0,
    width: 1.6, height: 1.6, drill: nil, layers: ["*.Cu", "*.Mask"],
    roundrectRatio: nil, chamferRatio: nil, rectDelta: nil,
    primitives: [], customAnchor: nil)
check(vis.padShown(wildPad),
      "visibility: a *.Cu pad shows while any copper layer is shown")
vis.hiddenLayers = ["F.Cu", "In1.Cu", "In2.Cu", "B.Cu"]
check(!vis.padShown(wildPad),
      "visibility: with every copper layer hidden, the *.Cu pad hides")
vis.hiddenLayers = ["F.Cu"]
check(vis.padShown(wildPad),
      "visibility: hiding F.Cu alone does NOT hide a through-hole pad")
vis.hiddenLayers = []
vis.showPads = false
check(!vis.padShown(wildPad), "visibility: Pads off hides pads")
vis.showPads = true
check(vis.traceShown(fixtureTrace), "visibility: a trace shows by default")
vis.showTracks = false
check(!vis.traceShown(fixtureTrace), "visibility: Tracks off hides traces")
vis.showTracks = true
vis.hiddenLayers = ["B.Cu"]
check(!vis.traceShown(state1.traces[1]),
      "visibility: hiding B.Cu hides the B.Cu trace")

// -- Selection filter --
var filter = BoardSelectionFilter()
check(filter.allows(.component) && filter.allows(.trace) && filter.allItems,
      "filter: everything is selectable by default")
filter.components = false
check(!filter.allows(.component) && filter.allows(.trace) && !filter.allItems,
      "filter: Footprints off blocks component selection only")
filter.setAll(true)
check(filter.allItems && filter.allows(.component),
      "filter: All items switches every class back on")

// MARK: - Part 5: grid/units, lengths, connectivity, pin status

// -- Units + snap math (Sean: grid adjustable IN MILS) --
check(approx(BoardUnits.mm(fromMil: 100), 2.54),
      "units: 100 mil is 2.54 mm")
check(approx(BoardUnits.mil(fromMM: 0.635), 25),
      "units: 0.635 mm is 25 mil")
let snapped25 = BoardGrid.snap(FPPoint(x: 0.4, y: 0.3), gridMil: 25)
check(approx(snapped25.x, 0.635) && approx(snapped25.y, 0),
      "grid: (0.4, 0.3) snaps to (0.635, 0) on a 25 mil grid (got \(snapped25))")
let snapped5 = BoardGrid.snap(FPPoint(x: 0.4, y: 0.3), gridMil: 5)
check(approx(snapped5.x, 0.381) && approx(snapped5.y, 0.254),
      "grid: (0.4, 0.3) snaps to (0.381, 0.254) on a 5 mil grid (got \(snapped5))")
check(BoardGrid.presetMils.contains(25) && BoardGrid.presetMils.contains(50),
      "grid: the presets include 25 and 50 mil")

// -- Layer stack (configurable copper count) --
checkEqual(BoardLayers.copperLayers(count: 2), ["F.Cu", "B.Cu"],
           "layers: a 2-layer board is F.Cu + B.Cu")
checkEqual(BoardLayers.copperLayers(count: 6),
           ["F.Cu", "In1.Cu", "In2.Cu", "In3.Cu", "In4.Cu", "B.Cu"],
           "layers: a 6-layer board gains In1..In4")
check(!BoardLayers.layerExists("In2.Cu", copperCount: 2)
      && BoardLayers.layerExists("In2.Cu", copperCount: 4),
      "layers: In2.Cu exists on a 4-layer board but not a 2-layer one")
check(BoardLayers.layerExists("F.SilkS", copperCount: 2),
      "layers: non-copper layers always exist")
checkEqual(BoardLayers.flipDestinations, ["F.Cu", "B.Cu"],
           "flip: the Change Layer destinations are exactly F.Cu and B.Cu")

// -- v4 board files load unchanged (additive format growth) --
let v4JSON = """
{"formatVersion":1,"placements":{},"excludedReferences":[],\
"traces":[{"id":"BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB","netName":"NET_A",\
"layer":"F.Cu","width":0.25,"points":[{"x":0,"y":0},{"x":10,"y":0}]}],\
"graphics":[],"knownReferences":["U1"]}
"""
do {
    let v4State = try JSONDecoder().decode(BoardState.self, from: Data(v4JSON.utf8))
    checkEqual(v4State.traces.count, 1, "v4 board file: its trace decodes")
    check(v4State.vias.isEmpty && v4State.zones.isEmpty && v4State.sides.isEmpty,
          "v4 board file: part-5 collections default to empty")
    checkEqual(v4State.copperLayerCount, 4,
               "v4 board file: copper count defaults to the part-4 stack (4)")
    check(approx(v4State.gridMil, 25) && approx(v4State.clearanceMil, 8),
          "v4 board file: grid/clearance default to 25 mil / 8 mil")
} catch {
    check(false, "v4 board file literal decodes (threw \(error))")
}

// -- Part-5 state round-trip (vias, zones, sides, settings) --
var state5 = BoardState()
state5.vias = [BoardVia(id: fixedUUID("12121212-1212-4212-8212-121212121212"),
                        netName: "NET_A", center: FPPoint(x: 10, y: 10),
                        diameter: 0.8, drill: 0.4)]
state5.zones = [BoardZone(id: fixedUUID("34343434-3434-4434-8434-343434343434"),
                          netName: "VCC", layer: "B.Cu",
                          points: [FPPoint(x: 0, y: 50), FPPoint(x: 20, y: 50),
                                   FPPoint(x: 20, y: 70), FPPoint(x: 0, y: 70)])]
state5.sides = ["U1": .back]
state5.copperLayerCount = 6
state5.gridMil = 50
state5.clearanceMil = 6
state5.knownReferences = ["R1", "U1", "X1"]
do {
    try BoardStateStore.save(state5, tableStem: "fixture5", in: stateDir)
    let loaded5 = BoardStateStore.load(tableStem: "fixture5", in: stateDir)
    check(loaded5 == state5,
          "part 5 state: vias/zones/sides/settings round-trip losslessly")
} catch {
    check(false, "part 5 state: the store round-trip threw \(error)")
}

// -- Via + zone hit geometry --
let fixtureVia = state5.vias[0]
check(BoardGeometry.viaHit(fixtureVia, point: FPPoint(x: 10.3, y: 10),
                           tolerance: 0.05),
      "via: a tap on the annular ring hits")
check(!BoardGeometry.viaHit(fixtureVia, point: FPPoint(x: 11, y: 10),
                            tolerance: 0.05),
      "via: a tap 1 mm away misses")
check(BoardGeometry.pointInPolygon(FPPoint(x: 10, y: 60),
                                   polygon: state5.zones[0].points),
      "zone: a point inside the polygon is inside")
check(!BoardGeometry.pointInPolygon(FPPoint(x: 30, y: 60),
                                    polygon: state5.zones[0].points),
      "zone: a point outside the polygon is outside")
check(BoardGeometry.zoneHit(state5.zones[0], point: FPPoint(x: 10, y: 60),
                            tolerance: 0.05),
      "zone: hit-testing finds the fill")

// -- Connectivity + trace lengths on the real fixture board --
let u1Shelf = board.components.first { $0.reference == "U1" }!
let r1Shelf = board.components.first { $0.reference == "R1" }!
let u1Pad1Centre = BoardGeometry.padCenter(u1Shelf, binding(u1, "1").pad!)
let r1Pad1Centre = BoardGeometry.padCenter(r1Shelf, binding(r1Component, "1").pad!)

var stateConn = BoardState()
stateConn.knownReferences = ["R1", "U1", "X1"]
let conn0 = BoardConnectivity.analyze(
    model: PCBBoardMerger.apply(state: stateConn, to: board, isSync: false).model,
    copperCount: 4)
checkEqual(conn0["NET_A"]?.unroutedPads.count ?? -1, 2,
           "connectivity: with no copper, NET_A's two pads reach nothing")
checkEqual(conn0["VCC"]?.padCount ?? -1, 2,
           "connectivity: VCC has exactly its two pads (U1 pin 8, X1 pin 2)")
let statusUnrouted = BoardPinStatus.status(
    of: binding(r1Component, "1"), in: r1Component, connectivity: conn0)
check(statusUnrouted == .unrouted(net: "NET_A"),
      "pin status: R1 pin 1 is UNROUTED (net exists, no copper) — got \(statusUnrouted)")
let statusDisconnected = BoardPinStatus.status(
    of: binding(u1, "2"), in: u1, connectivity: conn0)
check(statusDisconnected == .disconnected,
      "pin status: U1 pin 2 is DISCONNECTED (no net at all) — got \(statusDisconnected)")

stateConn.traces = [
    BoardTrace(id: fixedUUID("56565656-5656-4656-8656-565656565656"),
               netName: "NET_A", layer: "F.Cu", width: 0.25,
               points: [u1Pad1Centre, r1Pad1Centre]),
    BoardTrace(id: fixedUUID("78787878-7878-4787-8787-787878787878"),
               netName: "NET_A", layer: "B.Cu", width: 0.25,
               points: [FPPoint(x: 0, y: 200), FPPoint(x: 30, y: 200)]),
]
let mergedConn = PCBBoardMerger.apply(state: stateConn, to: board, isSync: false).model
let conn1 = BoardConnectivity.analyze(model: mergedConn, copperCount: 4)
checkEqual(conn1["NET_A"]?.routedPadCount ?? -1, 2,
           "connectivity: one trace pad-to-pad routes both NET_A pads")
check(conn1["NET_A"]?.unroutedPads.isEmpty == true,
      "connectivity: NET_A is fully routed once the trace lands")
let expectedLength = u1Pad1Centre.distance(to: r1Pad1Centre) + 30
check(approx(conn1["NET_A"]?.traceLength ?? -1, expectedLength),
      "lengths: NET_A total = the joining trace + the spare 30 mm trace (got \(conn1["NET_A"]?.traceLength ?? -1), want \(expectedLength))")
let statusRouted = BoardPinStatus.status(
    of: binding(r1Component, "1"), in: r1Component, connectivity: conn1)
check(statusRouted == .connected(net: "NET_A"),
      "pin status: R1 pin 1 reads CONNECTED after routing — got \(statusRouted)")

// A zone alone can route: a fill covering both NET_A pads (and no
// trace) still unions them.
var stateZone = BoardState()
stateZone.knownReferences = ["R1", "U1", "X1"]
let zoneMinX = min(u1Pad1Centre.x, r1Pad1Centre.x) - 1
let zoneMaxX = max(u1Pad1Centre.x, r1Pad1Centre.x) + 1
let zoneMinY = min(u1Pad1Centre.y, r1Pad1Centre.y) - 1
let zoneMaxY = max(u1Pad1Centre.y, r1Pad1Centre.y) + 1
stateZone.zones = [BoardZone(
    id: fixedUUID("90909090-9090-4090-8090-909090909090"),
    netName: "NET_A", layer: "F.Cu",
    points: [FPPoint(x: zoneMinX, y: zoneMinY), FPPoint(x: zoneMaxX, y: zoneMinY),
             FPPoint(x: zoneMaxX, y: zoneMaxY), FPPoint(x: zoneMinX, y: zoneMaxY)])]
let connZone = BoardConnectivity.analyze(
    model: PCBBoardMerger.apply(state: stateZone, to: board, isSync: false).model,
    copperCount: 4)
checkEqual(connZone["NET_A"]?.routedPadCount ?? -1, 2,
           "connectivity: a copper fill covering both pads routes the net")

// MARK: - Part 5: clearance (net-touch) check

// Two parallel traces 0.30 mm apart centre-to-centre, both 0.25
// wide: edge gap 0.05 mm < 8 mil (0.2032) -> violation.
var stateClear = BoardState()
stateClear.knownReferences = ["R1", "U1", "X1"]
stateClear.traces = [
    BoardTrace(id: fixedUUID("A1A1A1A1-A1A1-41A1-81A1-A1A1A1A1A1A1"),
               netName: "NET_A", layer: "F.Cu", width: 0.25,
               points: [FPPoint(x: 0, y: 100), FPPoint(x: 20, y: 100)]),
    BoardTrace(id: fixedUUID("B2B2B2B2-B2B2-42B2-82B2-B2B2B2B2B2B2"),
               netName: "VCC", layer: "F.Cu", width: 0.25,
               points: [FPPoint(x: 0, y: 100.3), FPPoint(x: 20, y: 100.3)]),
    // Same-net neighbour just as close: must NOT be flagged.
    BoardTrace(id: fixedUUID("C3C3C3C3-C3C3-43C3-83C3-C3C3C3C3C3C3"),
               netName: "NET_A", layer: "F.Cu", width: 0.25,
               points: [FPPoint(x: 0, y: 99.7), FPPoint(x: 20, y: 99.7)]),
]
let mergedClear = PCBBoardMerger.apply(state: stateClear, to: board,
                                       isSync: false).model
let violations = BoardClearance.violations(
    model: mergedClear, copperCount: 4,
    clearanceMM: BoardUnits.mm(fromMil: 8))
let tracePairViolation = violations.first {
    $0.itemA.contains("trace") && $0.itemB.contains("trace")
}
check(tracePairViolation != nil,
      "clearance: traces 0.05 mm apart (edge) across nets ARE flagged (got \(violations.map(\.message)))")
if let pair = tracePairViolation {
    check(Set([pair.netA, pair.netB]) == Set(["NET_A", "VCC"]),
          "clearance: the violation names both nets (NET_A, VCC)")
    check(approx(pair.distanceMM, 0.05),
          "clearance: the measured gap is 0.05 mm (got \(pair.distanceMM))")
}
check(!violations.contains { $0.netA == $0.netB },
      "clearance: same-net copper is never flagged")

// Boundary: edge gap 0.2132 mm > 8 mil clearance -> clean.
var stateClearOK = stateClear
stateClearOK.traces[1].points = [FPPoint(x: 0, y: 100.4632),
                                 FPPoint(x: 20, y: 100.4632)]
let violationsOK = BoardClearance.violations(
    model: PCBBoardMerger.apply(state: stateClearOK, to: board,
                                isSync: false).model,
    copperCount: 4, clearanceMM: BoardUnits.mm(fromMil: 8))
check(!violationsOK.contains {
    $0.itemA.contains("trace") && $0.itemB.contains("trace")
}, "clearance: a 0.2132 mm edge gap respects the 8 mil boundary")

// Touching = distance 0 and reported as touching.
var stateTouch = stateClear
stateTouch.traces[1].points = [FPPoint(x: 0, y: 100.25),
                               FPPoint(x: 20, y: 100.25)]
let touchViolations = BoardClearance.violations(
    model: PCBBoardMerger.apply(state: stateTouch, to: board,
                                isSync: false).model,
    copperCount: 4, clearanceMM: BoardUnits.mm(fromMil: 8))
check(touchViolations.contains {
    $0.itemA.contains("trace") && $0.distanceMM <= 0.001
}, "clearance: overlapping traces of different nets read as touching")

// MARK: - Part 5: manufacturing checker (violating + clean)

let mfgSettings = ManufacturingSettings(clearanceMil: 8)
let mfgBad = BoardManufacturing.check(
    model: mergedClear, copperCount: 4, settings: mfgSettings,
    connectivity: conn1)
check(mfgBad.rules[0].passed == false,
      "manufacturing: the clearance rule FAILS on the close-traces board")
check(mfgBad.rules[4].passed == false,
      "manufacturing: the fully-routed rule FAILS while VCC is unrouted")
check(mfgBad.rules[5].passed == false,
      "manufacturing: the disconnected-pins rule FAILS on the fixture board (loose pins exist)")

var stateThin = BoardState()
stateThin.knownReferences = ["R1", "U1", "X1"]
stateThin.traces = [BoardTrace(
    id: fixedUUID("D4D4D4D4-D4D4-44D4-84D4-D4D4D4D4D4D4"),
    netName: "NET_A", layer: "F.Cu", width: 0.1,
    points: [FPPoint(x: 0, y: 100), FPPoint(x: 20, y: 100)])]
stateThin.vias = [
    BoardVia(id: fixedUUID("E5E5E5E5-E5E5-45E5-85E5-E5E5E5E5E5E5"),
             netName: "NET_A", center: FPPoint(x: 5, y: 120),
             diameter: 0.5, drill: 0.2),   // both under the minimums
    BoardVia(id: fixedUUID("F6F6F6F6-F6F6-46F6-86F6-F6F6F6F6F6F6"),
             netName: "NET_A", center: FPPoint(x: 15, y: 120),
             diameter: 0.8, drill: 0.4),   // compliant
]
let mfgThin = BoardManufacturing.check(
    model: PCBBoardMerger.apply(state: stateThin, to: board, isSync: false).model,
    copperCount: 4, settings: mfgSettings, connectivity: conn1)
check(mfgThin.rules[1].passed == false
      && mfgThin.rules[1].violations.count == 1,
      "manufacturing: a 0.1 mm (3.9 mil) trace fails the 6 mil width rule, exactly once")
check(mfgThin.rules[2].passed == false
      && mfgThin.rules[2].violations.count == 1,
      "manufacturing: the 0.2 mm drill fails the 12 mil drill rule; the 0.4 mm drill passes")
check(mfgThin.rules[3].passed == false
      && mfgThin.rules[3].violations.count == 1,
      "manufacturing: the 0.5 mm via fails the 24 mil diameter rule; the 0.8 mm via passes")
check(mfgThin.rules[6].passed,
      "manufacturing: the layer-existence rule passes when everything is on F.Cu")

// Layer-count reduction: a trace stranded on In2.Cu is kept,
// hidden, and reported — never silently dropped.
var stateOrphan = BoardState()
stateOrphan.knownReferences = ["R1", "U1", "X1"]
stateOrphan.copperLayerCount = 2
stateOrphan.traces = [BoardTrace(
    id: fixedUUID("17171717-1717-4717-8717-171717171717"),
    netName: "NET_A", layer: "In2.Cu", width: 0.25,
    points: [FPPoint(x: 0, y: 100), FPPoint(x: 20, y: 100)])]
let mergedOrphan = PCBBoardMerger.apply(state: stateOrphan, to: board,
                                        isSync: false)
checkEqual(mergedOrphan.model.traces.count, 1,
           "layers: reducing the count does NOT drop the In2.Cu trace")
check(mergedOrphan.model.boardProblems.contains { $0.contains("In2.Cu") },
      "layers: the stranded trace is named in Problems")
var visOrphan = BoardVisibility()
visOrphan.copperLayerCount = 2
check(!visOrphan.layerShown("In2.Cu") && visOrphan.layerShown("F.Cu"),
      "layers: In2.Cu is hidden on a 2-layer board; F.Cu still shows")
let mfgOrphan = BoardManufacturing.check(
    model: mergedOrphan.model, copperCount: 2, settings: mfgSettings,
    connectivity: conn1)
check(mfgOrphan.rules[6].passed == false,
      "manufacturing: the layer-existence rule FAILS for the stranded trace")

// A fully CLEAN board: hand-built, everything routed and legal.
guard let fixrParsed = fixrEntry.parsed else { fatal("FIXR_FP parsed") }
func cleanComponent(_ reference: String, origin: FPPoint) -> BoardComponent {
    BoardComponent(
        reference: reference, value: "10k", symbolKey: "FixtureSym:FIXR",
        footprintKey: "FixtureFP:FIXR_FP", matchKind: "property",
        footprint: fixrParsed,
        pins: [
            BoardPinBinding(pinNumber: "1", pinName: "", pinType: "passive",
                            netName: "NET_A", pad: fixrParsed.pads[0]),
            BoardPinBinding(pinNumber: "2", pinName: "", pinType: "passive",
                            netName: "NET_B", pad: fixrParsed.pads[1]),
        ],
        anomalies: [], notes: [], origin: origin, boundsSize: (w: 5.41, h: 1.6))
}
var cleanModel = BoardModel(
    tableTitle: "Clean", sourceFileName: "clean.json",
    components: [cleanComponent("RA", origin: FPPoint(x: 0, y: 0)),
                 cleanComponent("RB", origin: FPPoint(x: 30, y: 0))],
    globalAnomalies: [], excludedPowerReferences: [],
    netCount: 2, netNames: ["NET_A", "NET_B"])
cleanModel.traces = [
    // NET_A jogs up and over so it never nears NET_B's pads.
    BoardTrace(id: fixedUUID("28282828-2828-4828-8828-282828282828"),
               netName: "NET_A", layer: "F.Cu", width: 0.25,
               points: [FPPoint(x: -1.905, y: 0), FPPoint(x: -1.905, y: 6),
                        FPPoint(x: 28.095, y: 6), FPPoint(x: 28.095, y: 0)]),
    BoardTrace(id: fixedUUID("39393939-3939-4939-8939-393939393939"),
               netName: "NET_B", layer: "F.Cu", width: 0.25,
               points: [FPPoint(x: 1.905, y: 0), FPPoint(x: 1.905, y: -6),
                        FPPoint(x: 31.905, y: -6), FPPoint(x: 31.905, y: 0)]),
]
let connClean = BoardConnectivity.analyze(model: cleanModel, copperCount: 4)
check(connClean["NET_A"]?.isFullyRouted == true
      && connClean["NET_B"]?.isFullyRouted == true,
      "clean board: both nets analyse as fully routed")
let mfgClean = BoardManufacturing.check(
    model: cleanModel, copperCount: 4, settings: mfgSettings,
    connectivity: connClean)
check(mfgClean.allPassed,
      "manufacturing: the clean board passes EVERY rule (failures: \(mfgClean.rules.filter { !$0.passed }.map(\.name)))")

// MARK: - Part 5: theory heuristics

let theoryFixture = BoardTheory.findings(model: mergedConn, connectivity: conn1)
check(theoryFixture.contains { $0.message.contains("pin 7") },
      "theory: U1's loose GND pin is flagged as an unconnected power pin (got \(theoryFixture.map(\.message)))")
check(!theoryFixture.contains { $0.message.contains("mixup") },
      "theory: the fixture board has no ground/supply mixup")
// Synthetic mixup: a VCC-named pin on a net called GND.
var mixupModel = cleanModel
mixupModel.components[0].pins[1] = BoardPinBinding(
    pinNumber: "2", pinName: "VCC", pinType: "power_in",
    netName: "GND", pad: fixrParsed.pads[1])
let theoryMixup = BoardTheory.findings(model: mixupModel, connectivity: connClean)
check(theoryMixup.contains { $0.message.contains("mixup") },
      "theory: a VCC pin on the GND net IS flagged as a possible mixup")
check(BoardSummaryText.make(model: cleanModel, connectivity: connClean,
                            manufacturing: mfgClean, theory: [])
        .contains("all 10 rules pass"),
      "summary: the AI summary text reports the clean manufacturing result")

// MARK: - Part 5: flip side (Change Layer)

checkEqual(BoardGeometry.flippedLayerName("F.Cu"), "B.Cu",
           "flip: F.Cu becomes B.Cu")
checkEqual(BoardGeometry.flippedLayerName("B.SilkS"), "F.SilkS",
           "flip: B.SilkS becomes F.SilkS")
checkEqual(BoardGeometry.flippedLayerName(
            BoardGeometry.flippedLayerName("F.Mask")), "F.Mask",
           "flip: flipping twice is the identity")

// Flip U1 (asymmetric: pads at x = -3.81, -1.27, 1.27, 3.81).
var stateFlip = BoardState()
stateFlip.knownReferences = ["R1", "U1", "X1"]
stateFlip.sides = ["U1": .back]
let mergedFlip = PCBBoardMerger.apply(state: stateFlip, to: board, isSync: false)
let u1Back = mergedFlip.model.components.first { $0.reference == "U1" }!
check(u1Back.side == .back, "flip: the merger puts U1 on the back side")
let u1Front = board.components.first { $0.reference == "U1" }!
for number in ["1", "4", "8"] {
    let rawPad = binding(u1, number).pad!
    let frontCentre = BoardGeometry.padCenter(u1Front, rawPad)
    let backCentre = BoardGeometry.padCenter(u1Back, rawPad)
    check(approx(backCentre.x, 2 * u1Front.origin.x - frontCentre.x)
          && approx(backCentre.y, frontCentre.y),
          "flip: U1 pad \(number) mirrors across the origin's vertical axis (front \(frontCentre) -> back \(backCentre))")
    checkEqual(binding(u1Back, number).pad?.number ?? "", number,
               "flip: pin \(number) still binds pad \(number) after the flip")
}
// ...and it survives a SYNC merge too (side is board state).
let mergedFlipSync = PCBBoardMerger.apply(state: mergedFlip.stateToSave,
                                          to: boardV2, isSync: true)
check(mergedFlipSync.model.components.first { $0.reference == "U1" }?.side == .back,
      "flip: the side survives a sync merge")

// Rotated asymmetric footprint: mirror composes with pad rotation.
// A 30°-rotated rect pad at (1.905, 0): after the flip its outline
// must be the exact mirror image of the front outline.
var rotatedFP = fixrParsed
rotatedFP.pads[1].rotation = 30
let rotatedFront = BoardComponent(
    reference: "RR", value: "", symbolKey: "FixtureSym:FIXR",
    footprintKey: "FixtureFP:FIXR_FP", matchKind: nil,
    footprint: rotatedFP, pins: [], anomalies: [], notes: [],
    origin: FPPoint(x: 100, y: 100), boundsSize: (w: 5.41, h: 1.6))
var rotatedBack = rotatedFront
rotatedBack.side = .back
let frontOutline = BoardGeometry.padOutline(rotatedFront, rotatedFP.pads[1])
let backOutline = BoardGeometry.padOutline(rotatedBack, rotatedFP.pads[1])
let mirroredFront = frontOutline.map {
    FPPoint(x: 2 * 100 - $0.x, y: $0.y)
}
check(backOutline.count == mirroredFront.count
      && backOutline.allSatisfy { point in
          mirroredFront.contains {
              approx($0.x, point.x) && approx($0.y, point.y)
          }
      },
      "flip: a rotated pad's outline after the flip is the mirror of its front outline")
check(approx(BoardGeometry.boardPad(rotatedBack, rotatedFP.pads[1]).rotation, -30),
      "flip: the rotated pad's angle negates (30 -> -30)")

// A trace's layer change keeps its coordinates exactly.
var flippedTrace = fixtureTrace
flippedTrace.layer = "B.Cu"
check(flippedTrace.points == fixtureTrace.points
      && approx(flippedTrace.length, fixtureTrace.length),
      "flip: a trace moved F.Cu -> B.Cu keeps identical coordinates")

// MARK: - Part 5.0.1: pointer stream + KiCad-modelled routing
//
// Sean's device verdict on v5.0: Pencil hover while routing did
// not work. Diagnosis (code): the preview read
// `cursorBoard ?? hoverBoard`, and cursorBoard was written on
// every touch and NEVER cleared — the tap that starts a route
// froze the preview at the start pad and masked hover forever.
// The fix: ONE pointer stream (BoardPointerState) + the routing
// resolution (routePreview / routeTap) in the audit-compiled
// BoardGeometry, modelled on KiCad's PNS LINE_PLACER
// (Start / Move(aP, aEndItem) / FixRoute): the preview head is
// pad-anchored within tolerance, and the point it shows IS the
// point a tap commits.

// -- Pointer arbitration: touch wins only while it is down --
var pointer = BoardPointerState()
check(pointer.currentPoint == nil,
      "pointer: no current point before any event")
pointer.apply(.hoverMoved(FPPoint(x: 10, y: 10)))
check(pointer.currentPoint == FPPoint(x: 10, y: 10),
      "pointer: hover feeds the current point")
pointer.apply(.touchMoved(FPPoint(x: 20, y: 20)))
check(pointer.currentPoint == FPPoint(x: 20, y: 20),
      "pointer: an ACTIVE touch wins over hover")
pointer.apply(.touchEnded)
check(pointer.currentPoint == FPPoint(x: 10, y: 10),
      "pointer: touch end falls back to the live hover point (the v5.0 freeze scenario)")
pointer.apply(.hoverMoved(FPPoint(x: 30, y: 30)))
check(pointer.currentPoint == FPPoint(x: 30, y: 30),
      "pointer: hover keeps tracking after a tap")
pointer.apply(.hoverEnded)
check(pointer.currentPoint == nil,
      "pointer: hover end clears the current point")

// -- Route resolution against the real fixture board --
let hoverTol = 0.8
// (u1Pad1Centre is already declared in the part-5 section above;
// the pad-4 centre gets its own name here.)
let u1Pad4Centre501 = BoardGeometry.padCenter(u1Shelf, binding(u1, "4").pad!)
let freeProbe = FPPoint(x: 1000.3, y: 999.7)

// Preview anchored on the same-net pad: exact centre, no refusal.
let previewPad = BoardGeometry.routePreview(
    board, from: u1Pad4Centre501, pointer: u1Pad1Centre,
    routeNet: "NET_A", snapEnabled: true, gridMil: 25, tolerance: hoverTol)
check(approx(previewPad.endPoint.x, u1Pad1Centre.x)
      && approx(previewPad.endPoint.y, u1Pad1Centre.y),
      "route preview: over pad 1 the head anchors on its EXACT centre")
check(previewPad.target?.netName == "NET_A"
      && previewPad.target?.reference == "U1"
      && previewPad.target?.padNumber == "1",
      "route preview: the anchored target is U1 pad 1 (NET_A)")
check(!previewPad.joinRefused,
      "route preview: a same-net pad is not refused")

// Preview over a FOREIGN pad: anchored on it, but flagged refused.
let previewForeign = BoardGeometry.routePreview(
    board, from: u1Pad1Centre, pointer: u1Pad4Centre501,
    routeNet: "NET_A", snapEnabled: true, gridMil: 25, tolerance: hoverTol)
check(previewForeign.target?.netName == "NET_B" && previewForeign.joinRefused,
      "route preview: a foreign-net pad under the pointer is flagged join-refused")
check(approx(previewForeign.endPoint.x, u1Pad4Centre501.x)
      && approx(previewForeign.endPoint.y, u1Pad4Centre501.y),
      "route preview: the refused head still shows the pad it would hit")

// Just NEAR a pad (inside tolerance, off-centre): pad anchoring
// beats grid snap — the head lands on the centre, not the grid.
let nearPadProbe = FPPoint(x: u1Pad1Centre.x + 1.0, y: u1Pad1Centre.y + 0.3)
let previewNear = BoardGeometry.routePreview(
    board, from: u1Pad4Centre501, pointer: nearPadProbe,
    routeNet: "NET_A", snapEnabled: true, gridMil: 25, tolerance: hoverTol)
check(previewNear.target != nil
      && approx(previewNear.endPoint.x, u1Pad1Centre.x)
      && approx(previewNear.endPoint.y, u1Pad1Centre.y),
      "route preview: within tolerance of a pad, the head snaps to the pad centre")

// Free space: grid snap applies; snap off = the raw point.
let previewFree = BoardGeometry.routePreview(
    board, from: u1Pad1Centre, pointer: freeProbe,
    routeNet: "NET_A", snapEnabled: true, gridMil: 25, tolerance: hoverTol)
check(previewFree.target == nil && !previewFree.joinRefused,
      "route preview: free space has no pad target and no refusal")
check(previewFree.endPoint == BoardGrid.snap(freeProbe, gridMil: 25)
      && previewFree.endPoint != freeProbe,
      "route preview: a free point is grid-snapped (25 mil grid)")
let previewFreeRaw = BoardGeometry.routePreview(
    board, from: u1Pad1Centre, pointer: freeProbe,
    routeNet: "NET_A", snapEnabled: false, gridMil: 25, tolerance: hoverTol)
check(previewFreeRaw.endPoint == freeProbe,
      "route preview: snap OFF leaves the free point untouched")
// The 45° corner of a long diagonal head runs at exactly 45°.
let previewCorner = BoardGeometry.routePreview(
    board, from: FPPoint(x: 0, y: 0), pointer: freeProbe,
    routeNet: "NET_A", snapEnabled: true, gridMil: 25, tolerance: hoverTol)
check(previewCorner.corner != nil
      && approx(previewCorner.corner!.x, previewCorner.corner!.y),
      "route preview: the corner of a diagonal head sits on the 45° line")

// -- Tap resolution: the same algebra, committed --
check(BoardGeometry.routeTap(board, point: freeProbe, routingActive: false,
                             routeNet: nil, snapEnabled: true, gridMil: 25,
                             tolerance: hoverTol) == .needsPad,
      "route tap: not routing + no pad = needsPad (nothing starts)")
if case .startPad(let startTarget) = BoardGeometry.routeTap(
    board, point: u1Pad1Centre, routingActive: false,
    routeNet: nil, snapEnabled: true, gridMil: 25, tolerance: hoverTol) {
    check(startTarget.netName == "NET_A"
          && approx(startTarget.center.x, u1Pad1Centre.x)
          && approx(startTarget.center.y, u1Pad1Centre.y),
          "route tap: not routing + pad = startPad on its exact centre (NET_A)")
} else {
    check(false, "route tap: not routing + pad = startPad")
}
check(BoardGeometry.routeTap(board, point: u1Pad4Centre501, routingActive: true,
                             routeNet: "NET_A", snapEnabled: true, gridMil: 25,
                             tolerance: hoverTol) == .refusedForeignNet("NET_B"),
      "route tap: routing NET_A onto a NET_B pad is refused, by name")
if case .finishAtPad(let finishTarget) = BoardGeometry.routeTap(
    board, point: u1Pad1Centre, routingActive: true,
    routeNet: "NET_A", snapEnabled: true, gridMil: 25, tolerance: hoverTol) {
    check(approx(finishTarget.center.x, u1Pad1Centre.x)
          && approx(finishTarget.center.y, u1Pad1Centre.y),
          "route tap: routing onto the same-net pad finishes on its centre")
} else {
    check(false, "route tap: routing onto the same-net pad = finishAtPad")
}
if case .finishAtPad(let adoptTarget) = BoardGeometry.routeTap(
    board, point: u1Pad4Centre501, routingActive: true,
    routeNet: nil, snapEnabled: true, gridMil: 25, tolerance: hoverTol) {
    check(adoptTarget.netName == "NET_B",
          "route tap: an unconnected track finishing on a pad adopts its net (NET_B), not refused")
} else {
    check(false, "route tap: unconnected track + pad = finishAtPad (adopt)")
}
check(BoardGeometry.routeTap(board, point: freeProbe, routingActive: true,
                             routeNet: "NET_A", snapEnabled: true, gridMil: 25,
                             tolerance: hoverTol)
      == .appendPoint(BoardGrid.snap(freeProbe, gridMil: 25)),
      "route tap: routing + free point appends the grid-snapped point")

// -- THE guarantee: preview endpoint == tap point, probe by probe --
for probe in [u1Pad1Centre, u1Pad4Centre501, nearPadProbe, freeProbe] {
    let preview = BoardGeometry.routePreview(
        board, from: u1Pad1Centre, pointer: probe,
        routeNet: "NET_A", snapEnabled: true, gridMil: 25, tolerance: hoverTol)
    switch BoardGeometry.routeTap(board, point: probe, routingActive: true,
                                  routeNet: "NET_A", snapEnabled: true,
                                  gridMil: 25, tolerance: hoverTol) {
    case .appendPoint(let committed):
        check(committed == preview.endPoint,
              "preview==tap: free probe \(probe) commits where the head showed")
    case .finishAtPad(let target):
        check(target.center == preview.endPoint && preview.target != nil,
              "preview==tap: pad probe \(probe) finishes where the head showed")
    case .refusedForeignNet(let net):
        check(preview.joinRefused && preview.target?.netName == net,
              "preview==tap: foreign probe \(probe) is the pad the preview flagged")
    default:
        check(false, "preview==tap: probe \(probe) resolved unexpectedly")
    }
}

// -- Hover targets (KiCad's hover highlight) --
if case .pad(let hoverPad) = BoardGeometry.hoverTarget(
    board, point: u1Pad1Centre, tolerance: hoverTol) {
    check(hoverPad.reference == "U1" && hoverPad.padNumber == "1"
          && hoverPad.netName == "NET_A",
          "hover: over pad 1 the hover target is that pad (U1/1, NET_A)")
} else {
    check(false, "hover: over pad 1 the hover target is the pad")
}
var hoverModel = board
let hoverTrace = BoardTrace(
    id: fixedUUID("50505050-5050-4050-8050-505050505050"),
    netName: "NET_A", layer: "F.Cu", width: 0.25,
    points: [FPPoint(x: 300, y: 300), FPPoint(x: 310, y: 300)])
hoverModel.traces = [hoverTrace]
check(BoardGeometry.hoverTarget(hoverModel, point: FPPoint(x: 305, y: 300.1),
                                tolerance: hoverTol) == .trace(hoverTrace.id),
      "hover: over a trace (no pad near) the hover target is the trace")
check(BoardGeometry.hoverTarget(board, point: FPPoint(x: 2000, y: 2000),
                                tolerance: hoverTol) == nil,
      "hover: empty board space has no hover target")

// MARK: - Parts 5.0.2 + 5.0.3: hover delivery channels + diagnostics
//
// Sean's device verdict on v5.0.1: "Hover still dead" — the model
// was right but DELIVERY failed (see CONTRACTS.md "Part 5.0.2
// forensics": the hit-test-transparent overlay's own recognizer
// was dead by construction; the lent ancestor recognizers were a
// depth-3 gamble on SwiftUI's private hierarchy). v5.0.2 fed the
// SAME BoardPointerState from three tagged channels; Sean's
// hardware STILL reported no hover (2026-11-01 21:37), so
// v5.0.3 owns the hierarchy instead: ONE frontmost UIKit
// interaction view over the canvas rect is the hit view for
// hover AND touches, with the recognizer attached directly to
// it — channel 1. SwiftUI's .onContinuousHover stays as the
// counted fallback — channel 2. The funnel below mirrors the
// editor's feed helpers EXACTLY (record the channel, then apply
// the event), so what is proven here is the convergence contract
// the view relies on: the channel tag can never change
// arbitration.

// The editor's feed funnel, mirrored: diagnostics record first,
// then the one shared apply.
struct HoverFeed {
    var pointer = BoardPointerState()
    var diagnostics = BoardHoverDiagnostics()
    mutating func moved(_ point: FPPoint, _ channel: BoardHoverChannel) {
        diagnostics.record(channel, point: point)
        pointer.apply(.hoverMoved(point))
    }
    mutating func ended(_ channel: BoardHoverChannel) {
        diagnostics.record(channel, point: nil)
        pointer.apply(.hoverEnded)
    }
}

// -- Channel numbering is the diagnostics line's numbering --
check(BoardHoverChannel.allCases.map { $0.rawValue } == [1, 2],
      "channels: interaction=1, swiftUI=2 (the status-bar numbering)")

// -- Diagnostics: initial state + the exact empty summary --
var diag = BoardHoverDiagnostics()
check(diag.totalCount == 0 && diag.lastPoint == nil && diag.lastChannel == nil,
      "diagnostics: no events recorded initially")
check(diag.summary == "Hover 1: 0 · 2: 0 · (–, –)",
      "diagnostics: the empty summary is the documented line")

// -- Diagnostics: per-channel counting, last point/channel --
diag.record(.interaction, point: FPPoint(x: 12.34, y: 4.54))
check(diag.count(.interaction) == 1 && diag.count(.swiftUI) == 0,
      "diagnostics: a channel-1 event increments ONLY channel 1")
check(diag.lastChannel == .interaction
      && diag.lastPoint == FPPoint(x: 12.34, y: 4.54),
      "diagnostics: last channel + last point track the event")
check(diag.summary == "Hover 1: 1 · 2: 0 · (12.3, 4.5)",
      "diagnostics: the summary formats counts + point (1 decimal)")
diag.record(.swiftUI, point: nil)
check(diag.count(.swiftUI) == 1
      && diag.lastPoint == FPPoint(x: 12.34, y: 4.54),
      "diagnostics: an END event counts but keeps the last point")
diag.record(.swiftUI, point: FPPoint(x: 1, y: 2))
check(diag.totalCount == 3 && diag.lastChannel == .swiftUI
      && diag.summary == "Hover 1: 1 · 2: 2 · (1.0, 2.0)",
      "diagnostics: both channels count independently")

// -- Arbitration is channel-blind: every channel drives the
//    stream identically --
for channel in BoardHoverChannel.allCases {
    var feed = HoverFeed()
    feed.moved(FPPoint(x: 10, y: 10), channel)
    check(feed.pointer.currentPoint == FPPoint(x: 10, y: 10),
          "channels: channel \(channel.rawValue) hover feeds the current point")
    feed.pointer.apply(.touchMoved(FPPoint(x: 20, y: 20)))
    check(feed.pointer.currentPoint == FPPoint(x: 20, y: 20),
          "channels: an ACTIVE touch wins over channel \(channel.rawValue) hover")
    feed.moved(FPPoint(x: 30, y: 30), channel)
    check(feed.pointer.currentPoint == FPPoint(x: 20, y: 20),
          "channels: channel \(channel.rawValue) hover during a touch does not steal the point")
    feed.pointer.apply(.touchEnded)
    check(feed.pointer.currentPoint == FPPoint(x: 30, y: 30),
          "channels: touch end falls back to channel \(channel.rawValue)'s latest hover point")
    feed.ended(channel)
    check(feed.pointer.currentPoint == nil,
          "channels: channel \(channel.rawValue) hover end clears the point")
    check(feed.diagnostics.count(channel) == 3
          && feed.diagnostics.totalCount == 3,
          "channels: channel \(channel.rawValue) recorded exactly its own 3 events")
}

// -- Cross-channel interleave: hover arrives on one channel,
//    resumes on another after a tap (the real-world case: the
//    channels race, the stream must not care) --
var cross = HoverFeed()
cross.moved(FPPoint(x: 5, y: 5), .interaction)
cross.pointer.apply(.touchMoved(FPPoint(x: 7, y: 7)))
cross.pointer.apply(.touchEnded)
cross.moved(FPPoint(x: 9, y: 9), .swiftUI)
check(cross.pointer.currentPoint == FPPoint(x: 9, y: 9),
      "channels: hover resuming on a DIFFERENT channel after a tap tracks correctly")
cross.moved(FPPoint(x: 11, y: 11), .interaction)
check(cross.pointer.currentPoint == FPPoint(x: 11, y: 11)
      && cross.diagnostics.totalCount == 3,
      "channels: the primary channel takes the same stream back seamlessly")

// -- Part 5.0.3: the interaction view is the PRIMARY source;
//    both channels describe the SAME physical hover, so the
//    stream holds ONE hover point and the latest event wins,
//    whichever channel carried it --
var dual = HoverFeed()
dual.moved(FPPoint(x: 10, y: 10), .interaction)
dual.moved(FPPoint(x: 12, y: 12), .swiftUI)
check(dual.pointer.currentPoint == FPPoint(x: 12, y: 12),
      "interaction: dual delivery of one hover — the latest point wins")
dual.moved(FPPoint(x: 14, y: 14), .interaction)
check(dual.pointer.currentPoint == FPPoint(x: 14, y: 14)
      && dual.diagnostics.lastChannel == .interaction,
      "interaction: the primary channel's later event wins back the point")
dual.ended(.swiftUI)
check(dual.pointer.currentPoint == nil,
      "interaction: an end on EITHER channel ends the one shared hover")
check(dual.diagnostics.totalCount == 4
      && dual.diagnostics.count(.interaction) == 2
      && dual.diagnostics.count(.swiftUI) == 2,
      "interaction: mixed-channel records sum to the total count")
check(dual.diagnostics.lastPoint == FPPoint(x: 14, y: 14)
      && dual.diagnostics.lastChannel == .swiftUI,
      "interaction: an end updates the last channel, keeps the last point")

// -- Part 5.0.3: Sean's acceptance sequence at the model level —
//    click a pad (touch down/up), hover-draw through the air,
//    click again to confirm — with the interaction channel
//    carrying the hover throughout --
var sean = HoverFeed()
sean.pointer.apply(.touchMoved(FPPoint(x: 3.81, y: 2.54)))
sean.pointer.apply(.touchEnded)
sean.moved(FPPoint(x: 6, y: 4), .interaction)
sean.moved(FPPoint(x: 9, y: 4), .interaction)
check(sean.pointer.currentPoint == FPPoint(x: 9, y: 4),
      "interaction: hover draws the preview after the first click")
sean.pointer.apply(.touchMoved(FPPoint(x: 9, y: 4)))
check(sean.pointer.currentPoint == FPPoint(x: 9, y: 4),
      "interaction: the confirming click lands where the hover preview was")
sean.pointer.apply(.touchEnded)
check(sean.pointer.currentPoint == FPPoint(x: 9, y: 4)
      && sean.diagnostics.count(.interaction) == 2,
      "interaction: after the confirming click the hover point persists under the lifted pencil")

// MARK: - Part 5.1: trace segment editing
//
// Sean (2026-11-01 21:39): clicking a trace selected the whole
// thing; he wants KiCad's model — a track is a chain of segments
// joined at corners, edited segment by segment. The persisted
// form is unchanged (one polyline); the operations below are
// the pure algebra PCBEditorView's gestures call, proven here
// in PCBBoardState.swift's BoardGeometry extension.

// A 3-segment track: three 10 mm runs in an L + step shape.
let segTraceID = fixedUUID("51515151-5151-4151-8151-515151515151")
let segTrace = BoardTrace(
    id: segTraceID, netName: "NET_A", layer: "F.Cu", width: 0.25,
    points: [FPPoint(x: 0, y: 0), FPPoint(x: 10, y: 0),
             FPPoint(x: 10, y: 10), FPPoint(x: 20, y: 10)])

// -- Segment basics --
check(segTrace.segmentCount == 3,
      "segments: a 4-point track has 3 segments")
check(approx(segTrace.segmentLength(0), 10)
      && approx(segTrace.segmentLength(1), 10)
      && approx(segTrace.segmentLength(2), 10)
      && approx(segTrace.length, 30),
      "segments: each run is 10 mm, the whole track 30 mm")
check(BoardGeometry.closestPointOnSegment(
        FPPoint(x: 5, y: 3), from: FPPoint(x: 0, y: 0), to: FPPoint(x: 10, y: 0))
      == FPPoint(x: 5, y: 0),
      "segments: the closest point is the perpendicular projection")
check(BoardGeometry.closestPointOnSegment(
        FPPoint(x: -4, y: 2), from: FPPoint(x: 0, y: 0), to: FPPoint(x: 10, y: 0))
      == FPPoint(x: 0, y: 0)
      && BoardGeometry.closestPointOnSegment(
        FPPoint(x: 14, y: 2), from: FPPoint(x: 0, y: 0), to: FPPoint(x: 10, y: 0))
      == FPPoint(x: 10, y: 0),
      "segments: the projection clamps to the segment's ends")

// -- Segment hit-testing (nearest wins, tolerance edges) --
let hitA = BoardGeometry.segmentHit(segTrace, point: FPPoint(x: 5, y: 0.4),
                                    tolerance: 0.8)
check(hitA?.index == 0 && approx(hitA?.distance ?? -1, 0.4),
      "segment hit: a tap over the first run picks segment 0")
let hitB = BoardGeometry.segmentHit(segTrace, point: FPPoint(x: 10.4, y: 5),
                                    tolerance: 0.8)
check(hitB?.index == 1 && approx(hitB?.distance ?? -1, 0.4),
      "segment hit: a tap over the vertical run picks segment 1")
check(BoardGeometry.segmentHit(segTrace, point: FPPoint(x: 15, y: 10.3),
                               tolerance: 0.8)?.index == 2,
      "segment hit: a tap over the last run picks segment 2")
check(BoardGeometry.segmentHit(segTrace, point: FPPoint(x: 9.8, y: -0.2),
                               tolerance: 0.8)?.index == 0,
      "segment hit: near a corner the NEAREST segment wins (0.2 mm beats 0.28 mm)")
check(BoardGeometry.segmentHit(segTrace, point: FPPoint(x: 10, y: 0),
                               tolerance: 0.8)?.index == 0,
      "segment hit: an exact tie at a shared vertex goes to the lower index")
check(BoardGeometry.segmentHit(segTrace, point: FPPoint(x: 5, y: 0.85),
                               tolerance: 0.8) == nil
      && BoardGeometry.segmentHit(segTrace, point: FPPoint(x: 5, y: 0.75),
                                  tolerance: 0.8)?.index == 0,
      "segment hit: beyond reach (0.85 > 0.8) misses, inside (0.75) hits")
var wideTrace = segTrace
wideTrace.width = 2.0
check(BoardGeometry.segmentHit(wideTrace, point: FPPoint(x: 5, y: 0.95),
                               tolerance: 0.8)?.index == 0,
      "segment hit: a wide track's reach is half its width (1.0 mm beats the 0.8 tolerance)")

// -- Segment picking across traces --
let otherTrace = BoardTrace(
    id: fixedUUID("52525252-5252-4252-8252-525252525252"),
    netName: "VCC", layer: "F.Cu", width: 0.25,
    points: [FPPoint(x: 0, y: 0.5), FPPoint(x: 10, y: 0.5)])
let pickA = BoardGeometry.segmentAt([segTrace, otherTrace],
                                    point: FPPoint(x: 5, y: 0.1),
                                    tolerance: 0.8)
check(pickA?.trace.id == segTraceID && pickA?.index == 0,
      "segment pick: the nearest segment wins even when its trace comes first")
let pickTie = BoardGeometry.segmentAt([segTrace, otherTrace],
                                      point: FPPoint(x: 5, y: 0.25),
                                      tolerance: 0.8)
check(pickTie?.trace.id == otherTrace.id,
      "segment pick: an exact tie goes to the LATER trace (it draws on top)")
check(BoardGeometry.segmentAt([segTrace, otherTrace],
                              point: FPPoint(x: 500, y: 500),
                              tolerance: 0.8) == nil,
      "segment pick: empty space picks nothing")

// -- Vertex hit-testing --
let vertexHit = BoardGeometry.vertexHit(segTrace, point: FPPoint(x: 10.3, y: 0.2),
                                        tolerance: 0.8)
check(vertexHit?.index == 1 && approx(vertexHit?.distance ?? -1, sqrt(0.13)),
      "vertex hit: the corner beside the tap is found (index 1)")
check(BoardGeometry.vertexHit(segTrace, point: FPPoint(x: 0.1, y: -0.1),
                              tolerance: 0.8)?.index == 0,
      "vertex hit: the first endpoint is a vertex too")
check(BoardGeometry.vertexHit(segTrace, point: FPPoint(x: 100, y: 100),
                              tolerance: 0.8) == nil,
      "vertex hit: far from every corner = no vertex")

// -- Vertex drag algebra (interior + endpoints) --
let bentTrace = BoardGeometry.traceWithVertexMoved(
    segTrace, vertex: 1, to: FPPoint(x: 12, y: 3))
check(bentTrace.points == [FPPoint(x: 0, y: 0), FPPoint(x: 12, y: 3),
                           FPPoint(x: 10, y: 10), FPPoint(x: 20, y: 10)],
      "vertex move: an interior corner moves, every other point stays")
check(approx(bentTrace.segmentLength(0), sqrt(153.0))
      && approx(bentTrace.segmentLength(1), sqrt(53.0)),
      "vertex move: both adjacent segments follow the corner (lengths √153, √53)")
check(BoardGeometry.traceWithVertexMoved(
        segTrace, vertex: 0, to: FPPoint(x: -5, y: -5)).points.first
      == FPPoint(x: -5, y: -5),
      "vertex move: the first endpoint moves freely (it may leave its pad)")
check(BoardGeometry.traceWithVertexMoved(
        segTrace, vertex: 3, to: FPPoint(x: 25, y: 10)).points.last
      == FPPoint(x: 25, y: 10),
      "vertex move: the last endpoint moves freely too")
// The editor's drag composition: snap the raw target with the
// board grid, THEN move — the corner lands on the grid exactly.
let snappedTarget = BoardGrid.snap(FPPoint(x: 12.3, y: 3.2), gridMil: 25)
check(BoardGeometry.traceWithVertexMoved(
        segTrace, vertex: 1, to: snappedTarget).points[1] == snappedTarget
      && snappedTarget != FPPoint(x: 12.3, y: 3.2),
      "vertex move: the editor's snap-then-move composition lands on the 25 mil grid")

// -- Segment drag algebra --
let slidTrace = BoardGeometry.traceWithSegmentMoved(
    segTrace, segment: 1, by: FPPoint(x: 2, y: -3))
check(slidTrace.points == [FPPoint(x: 0, y: 0), FPPoint(x: 12, y: -3),
                           FPPoint(x: 12, y: 7), FPPoint(x: 20, y: 10)],
      "segment move: BOTH endpoints translate by the delta, the rest stay")
check(approx(slidTrace.segmentLength(1), 10)
      && approx(slidTrace.segmentLength(0), sqrt(153.0)),
      "segment move: the moved segment keeps its length; the neighbour stretches")

// -- Vertex insertion --
let splitOnce = BoardGeometry.traceWithVertexInserted(
    segTrace, segment: 0, at: FPPoint(x: 4, y: 0))
check(splitOnce.points == [FPPoint(x: 0, y: 0), FPPoint(x: 4, y: 0),
                           FPPoint(x: 10, y: 0), FPPoint(x: 10, y: 10),
                           FPPoint(x: 20, y: 10)]
      && splitOnce.segmentCount == 4,
      "vertex insert: the corner lands at index 1 and the segment becomes two")
check(approx(splitOnce.length, segTrace.length),
      "vertex insert: an on-line corner changes no length")
check(BoardGeometry.traceWithVertexInserted(
        segTrace, segment: 0, at: FPPoint(x: 5, y: 2)).length > segTrace.length,
      "vertex insert: an off-line corner lengthens the track (it really bends)")

// -- Vertex removal (neighbours join straight) --
let joinedTrace = BoardGeometry.traceWithVertexRemoved(segTrace, vertex: 1)
check(joinedTrace?.points == [FPPoint(x: 0, y: 0), FPPoint(x: 10, y: 10),
                              FPPoint(x: 20, y: 10)],
      "vertex remove: an interior corner goes and its segments join straight")
check(approx(joinedTrace?.segmentLength(0) ?? -1, sqrt(200.0)),
      "vertex remove: the joined run is one straight √200 segment")
check(BoardGeometry.traceWithVertexRemoved(segTrace, vertex: 0)?.points
      == [FPPoint(x: 10, y: 0), FPPoint(x: 10, y: 10), FPPoint(x: 20, y: 10)],
      "vertex remove: removing the first endpoint shortens the track")
check(BoardGeometry.traceWithVertexRemoved(segTrace, vertex: 3)?.points
      == [FPPoint(x: 0, y: 0), FPPoint(x: 10, y: 0), FPPoint(x: 10, y: 10)],
      "vertex remove: removing the last endpoint shortens the track")
let twoPointTrace = BoardTrace(
    id: fixedUUID("53535353-5353-4353-8353-535353535353"),
    netName: "NET_A", layer: "F.Cu", width: 0.25,
    points: [FPPoint(x: 0, y: 0), FPPoint(x: 10, y: 0)])
check(BoardGeometry.traceWithVertexRemoved(twoPointTrace, vertex: 0) == nil,
      "vertex remove: a 2-point track loses its only segment -> the track goes (nil)")

// -- Segment deletion splits the track --
let pieces = BoardGeometry.tracesByRemovingSegments(segTrace, indices: [1])
check(pieces.count == 2,
      "segment delete: removing the middle segment splits the track in two")
check(pieces[0].points == [FPPoint(x: 0, y: 0), FPPoint(x: 10, y: 0)]
      && pieces[0].id == segTraceID,
      "segment delete: the head piece keeps the points before the gap AND the trace id")
check(pieces[1].points == [FPPoint(x: 10, y: 10), FPPoint(x: 20, y: 10)]
      && pieces[1].id != segTraceID,
      "segment delete: the tail piece keeps the points after the gap, with a fresh id")
check(pieces.allSatisfy {
    $0.netName == "NET_A" && $0.layer == "F.Cu" && approx($0.width, 0.25)
}, "segment delete: both pieces keep the net, layer and width")
check(approx(pieces.reduce(0) { $0 + $1.length } + segTrace.segmentLength(1),
             segTrace.length),
      "segment delete: copper is conserved — pieces + the removed run = the original length")
let headRemoved = BoardGeometry.tracesByRemovingSegments(segTrace, indices: [0])
check(headRemoved.count == 1
      && headRemoved[0].points == [FPPoint(x: 10, y: 0), FPPoint(x: 10, y: 10),
                                   FPPoint(x: 20, y: 10)]
      && headRemoved[0].id == segTraceID,
      "segment delete: removing the FIRST segment leaves one piece (keeps the id)")
let tailRemoved = BoardGeometry.tracesByRemovingSegments(segTrace, indices: [2])
check(tailRemoved.count == 1
      && tailRemoved[0].points == [FPPoint(x: 0, y: 0), FPPoint(x: 10, y: 0),
                                   FPPoint(x: 10, y: 10)]
      && tailRemoved[0].id == segTraceID,
      "segment delete: removing the LAST segment leaves one piece (keeps the id)")
check(BoardGeometry.tracesByRemovingSegments(twoPointTrace, indices: [0]).isEmpty,
      "segment delete: removing a 2-point track's only segment removes the track")
let fivePointTrace = BoardTrace(
    id: fixedUUID("54545454-5454-4454-8454-545454545454"),
    netName: "NET_B", layer: "B.Cu", width: 0.4,
    points: [FPPoint(x: 0, y: 0), FPPoint(x: 10, y: 0), FPPoint(x: 10, y: 10),
             FPPoint(x: 20, y: 10), FPPoint(x: 20, y: 20)])
let twoGaps = BoardGeometry.tracesByRemovingSegments(fivePointTrace,
                                                     indices: [0, 2])
check(twoGaps.count == 2
      && twoGaps[0].points == [FPPoint(x: 10, y: 0), FPPoint(x: 10, y: 10)]
      && twoGaps[1].points == [FPPoint(x: 20, y: 10), FPPoint(x: 20, y: 20)]
      && twoGaps[0].id == fivePointTrace.id && twoGaps[1].id != fivePointTrace.id,
      "segment delete: two gaps in one pass leave the two surviving runs")
var lostNetTrace = segTrace
lostNetTrace.netName = nil
lostNetTrace.disconnectedNetName = "VCC"
let lostPieces = BoardGeometry.tracesByRemovingSegments(lostNetTrace, indices: [1])
check(lostPieces.count == 2 && lostPieces.allSatisfy {
    $0.netName == nil && $0.disconnectedNetName == "VCC"
}, "segment delete: pieces of an unconnected track keep its remembered net name")

// -- Undo/redo round-trips, mirroring the editor exactly: one
//    mutateBoard pushes ONE whole-state snapshot; undo pops it.
var editState51 = BoardState()
editState51.traces = [segTrace]
var undoStack51: [BoardState] = []
var redoStack51: [BoardState] = []
func simMutate51(_ change: (inout BoardState) -> Void) {
    undoStack51.append(editState51)
    redoStack51.removeAll()
    change(&editState51)
}
func simUndo51() {
    redoStack51.append(editState51)
    editState51 = undoStack51.removeLast()
}
func simRedo51() {
    undoStack51.append(editState51)
    editState51 = redoStack51.removeLast()
}
let originalState51 = editState51

simMutate51 { state in
    state.traces[0] = BoardGeometry.traceWithVertexMoved(
        state.traces[0], vertex: 1, to: FPPoint(x: 12, y: 3))
}
check(editState51 != originalState51
      && editState51.traces[0].points[1] == FPPoint(x: 12, y: 3),
      "undo: a corner drag commits as one state change")
simUndo51()
check(editState51 == originalState51,
      "undo: one undo restores the pre-drag track exactly")
simRedo51()
check(editState51.traces[0].points[1] == FPPoint(x: 12, y: 3),
      "redo: redo replays the corner drag")
simUndo51()

simMutate51 { state in
    state.traces[0] = BoardGeometry.traceWithSegmentMoved(
        state.traces[0], segment: 1, by: FPPoint(x: 2, y: -3))
}
simUndo51()
check(editState51 == originalState51,
      "undo: a segment drag undoes in one step")

simMutate51 { state in
    state.traces[0] = BoardGeometry.traceWithVertexInserted(
        state.traces[0], segment: 0, at: FPPoint(x: 4, y: 0))
}
simUndo51()
check(editState51 == originalState51,
      "undo: a corner insert undoes in one step")

simMutate51 { state in
    state.traces[0] = BoardGeometry.traceWithVertexRemoved(
        state.traces[0], vertex: 1)!
}
simUndo51()
check(editState51 == originalState51,
      "undo: a corner removal undoes in one step")

simMutate51 { state in
    state.traces = BoardGeometry.tracesByRemovingSegments(
        state.traces[0], indices: [1])
}
check(editState51.traces.count == 2,
      "undo: the split is live before undo (2 traces)")
simUndo51()
check(editState51 == originalState51 && editState51.traces.count == 1,
      "undo: one undo un-splits the track (original id and points)")
simRedo51()
check(editState51.traces.count == 2,
      "redo: redo replays the split")
simUndo51()

// -- Persistence: an edited + split board round-trips exactly.
var persistState51 = BoardState()
persistState51.traces = BoardGeometry.tracesByRemovingSegments(
    BoardGeometry.traceWithVertexMoved(segTrace, vertex: 1,
                                       to: FPPoint(x: 12, y: 3)),
    indices: [1])
do {
    try BoardStateStore.save(persistState51, tableStem: "fixture51",
                             in: stateDir)
    check(BoardStateStore.load(tableStem: "fixture51", in: stateDir) == persistState51,
          "persistence: a bent + split board saves and reloads exactly (points, pieces, ids)")
    let encoded = try JSONEncoder().encode(persistState51)
    let decoded = try JSONDecoder().decode(BoardState.self, from: encoded)
    check(decoded == persistState51,
          "persistence: the board JSON round-trip preserves the edited traces")
} catch {
    check(false, "persistence: save/load threw \(error)")
}

// -- Downstream checks read the edited model (no stale caches):
//    connectivity lengths follow a corner move and a split, and
//    the clearance check sees a corner dragged into range.
var downState = BoardState()
downState.knownReferences = ["R1", "U1", "X1"]
downState.traces = [
    BoardTrace(id: fixedUUID("55555555-5555-4555-8555-555555555555"),
               netName: "NET_A", layer: "F.Cu", width: 0.25,
               points: [FPPoint(x: 300, y: 300), FPPoint(x: 310, y: 300),
                        FPPoint(x: 310, y: 310)]),
]
func downConnectivity(_ state: BoardState) -> [String: NetConnectivity] {
    BoardConnectivity.analyze(
        model: PCBBoardMerger.apply(state: state, to: board,
                                    isSync: false).model,
        copperCount: 4)
}
check(approx(downConnectivity(downState)["NET_A"]?.traceLength ?? -1, 20),
      "downstream: connectivity reads the track's routed length (20 mm)")
var downMoved = downState
downMoved.traces[0] = BoardGeometry.traceWithVertexMoved(
    downMoved.traces[0], vertex: 1, to: FPPoint(x: 320, y: 300))
check(approx(downConnectivity(downMoved)["NET_A"]?.traceLength ?? -1,
             20 + sqrt(200.0)),
      "downstream: a corner move updates the net's routed length at once")
var downSplit = downMoved
downSplit.traces = BoardGeometry.tracesByRemovingSegments(
    downSplit.traces[0], indices: [0])
check(approx(downConnectivity(downSplit)["NET_A"]?.traceLength ?? -1,
             sqrt(200.0)),
      "downstream: after a split, the net's length is the surviving piece's")

var clearState51 = BoardState()
clearState51.knownReferences = ["R1", "U1", "X1"]
clearState51.traces = [
    BoardTrace(id: fixedUUID("56565656-5656-4656-8656-565656565656"),
               netName: "NET_A", layer: "F.Cu", width: 0.25,
               points: [FPPoint(x: 0, y: 200), FPPoint(x: 20, y: 200)]),
    BoardTrace(id: fixedUUID("57575757-5757-4757-8757-575757575757"),
               netName: "VCC", layer: "F.Cu", width: 0.25,
               points: [FPPoint(x: 0, y: 205), FPPoint(x: 20, y: 205)]),
]
func clearViolations51(_ state: BoardState) -> [ClearanceViolation] {
    BoardClearance.violations(
        model: PCBBoardMerger.apply(state: state, to: board,
                                    isSync: false).model,
        copperCount: 4, clearanceMM: BoardUnits.mm(fromMil: 8))
}
check(!clearViolations51(clearState51).contains {
    $0.itemA.contains("trace") && $0.itemB.contains("trace")
}, "downstream: tracks 5 mm apart raise no clearance violation")
var clearMoved = clearState51
clearMoved.traces[0] = BoardGeometry.traceWithVertexMoved(
    clearMoved.traces[0], vertex: 1, to: FPPoint(x: 20, y: 204.9))
check(clearViolations51(clearMoved).contains {
    $0.itemA.contains("trace") && $0.itemB.contains("trace")
    && Set([$0.netA, $0.netB]) == Set(["NET_A", "VCC"])
}, "downstream: dragging a corner into another net's clearance flags it at once")

// -- The segment subtotal readout format (Sean's Part-5 style,
//    applied to segments): lengths print mm + mil together.
check(BoardUnits.formatLength(mm: 42.6) == "42.6 mm · 1677.2 mil",
      "segments: the subtotal readout formats \"42.6 mm · 1677.2 mil\"")

// MARK: - Part 5.2: hover oscillation, route head, spatial index,
//         ratsnest, new checks, placement tools, ERC, De Morgan
//
// Sean's v5.1 device report (2026-11-02 08:44): "whenever I use
// hover the ui shakes back and forth". Diagnosis (CONTRACTS.md,
// Part 5.2): three mechanisms, two of them proven below against
// the shipped semantics — (1) channel arbitration: BOTH hover
// channels are live on his hardware and v5.1's single shared
// hover point was nilled by EITHER channel's end, so the
// SwiftUI channel's churn blinked the stream; (2) boundary
// dither: the PURE route resolution re-derives the endpoint
// from the instantaneous pointer, so snap-cell / pad-rim /
// diagonal boundaries flip per event; (3) whole-board
// invalidation per event (view-side; the coalescing throttle
// below is its model half). The legacy pointer semantics are
// replicated here verbatim-in-miniature from the v5.1
// PCBBoardState.swift so the oscillation is demonstrated
// against the semantics that actually shipped, not a strawman.

/// v5.1 BoardPointerState semantics, replicated (one shared
/// hover point; an untagged end from ANY channel nils it).
struct LegacyPointer52 {
    var hoverPoint: FPPoint? = nil
    var currentPoint: FPPoint? { hoverPoint }
    mutating func moved(_ p: FPPoint) { hoverPoint = p }
    mutating func ended() { hoverPoint = nil }
}

// -- (1) Channel arbitration: interleaved dual-channel stream --

let hoverP52 = FPPoint(x: 12.3, y: 4.5)
var legacy52 = LegacyPointer52()
var legacyTransitions52 = 0
var legacyLast52: FPPoint?? = nil
for _ in 0..<60 {
    // One physical hover, two live channels: the interaction
    // channel moves steadily; the SwiftUI channel restarts its
    // phase (end + active) around it — v5.1 funnels both into
    // the same point.
    legacy52.moved(hoverP52)
    if legacyLast52 != nil, legacy52.currentPoint != legacyLast52! {
        legacyTransitions52 += 1
    }
    legacyLast52 = legacy52.currentPoint
    legacy52.ended()
    if legacyLast52 != nil, legacy52.currentPoint != legacyLast52! {
        legacyTransitions52 += 1
    }
    legacyLast52 = legacy52.currentPoint
    legacy52.moved(hoverP52)
    if legacyLast52 != nil, legacy52.currentPoint != legacyLast52! {
        legacyTransitions52 += 1
    }
    legacyLast52 = legacy52.currentPoint
}
check(legacyTransitions52 >= 100,
      "5.2 arbitration: v5.1 semantics oscillate under dual-channel churn (\(legacyTransitions52) transitions)")

var pointer52 = BoardPointerState()
var newTransitions52 = 0
var newLast52: FPPoint?? = nil
for _ in 0..<60 {
    pointer52.applyHoverMoved(hoverP52, channel: .interaction)
    if newLast52 != nil, pointer52.currentPoint != newLast52! {
        newTransitions52 += 1
    }
    newLast52 = pointer52.currentPoint
    pointer52.applyHoverEnded(channel: .swiftUI)
    if newLast52 != nil, pointer52.currentPoint != newLast52! {
        newTransitions52 += 1
    }
    newLast52 = pointer52.currentPoint
    pointer52.applyHoverMoved(hoverP52, channel: .swiftUI)
    if newLast52 != nil, pointer52.currentPoint != newLast52! {
        newTransitions52 += 1
    }
    newLast52 = pointer52.currentPoint
    pointer52.applyHoverEnded(channel: .swiftUI)
    if newLast52 != nil, pointer52.currentPoint != newLast52! {
        newTransitions52 += 1
    }
    newLast52 = pointer52.currentPoint
}
check(newTransitions52 == 0 && pointer52.currentPoint == hoverP52,
      "5.2 arbitration: per-channel slots never blink under the same churn (\(newTransitions52) transitions)")
pointer52.applyHoverEnded(channel: .interaction)
check(pointer52.currentPoint == nil,
      "5.2 arbitration: when BOTH channels have ended the point clears")

// Stationary hover: 200 identical moves, zero state change
// after the first.
var stationary52 = BoardPointerState()
stationary52.applyHoverMoved(hoverP52, channel: .interaction)
var stationaryStable52 = true
for _ in 0..<200 {
    stationary52.applyHoverMoved(hoverP52, channel: .interaction)
    stationary52.applyHoverEnded(channel: .swiftUI)
    if stationary52.currentPoint != hoverP52 { stationaryStable52 = false }
}
check(stationaryStable52,
      "5.2 arbitration: a stationary hover is perfectly still for 200 events")

// -- (2) Route head hysteresis --

/// A small controlled board for the head tests: one pad at the
/// origin (route start) and one at (30, 0), both on NET_A.
func synth52Pad(_ number: String, _ x: Double, _ y: Double,
                w: Double = 1.0, h: Double = 1.0) -> KiCadFootprintPad {
    KiCadFootprintPad(number: number, type: .smd, shape: .rect,
                      x: x, y: y, rotation: 0, width: w, height: h,
                      drill: nil, layers: ["F.Cu"], roundrectRatio: nil,
                      chamferRatio: nil, rectDelta: nil, primitives: [],
                      customAnchor: nil)
}
func synth52Component(_ reference: String, origin: FPPoint,
                      pads: [KiCadFootprintPad],
                      nets: [String: String]) -> BoardComponent {
    BoardComponent(
        reference: reference, value: "V", symbolKey: "L:S",
        footprintKey: "G:F", matchKind: nil,
        footprint: KiCadFootprint(name: "F", description: "", tags: [],
                                  attributes: [], properties: [:],
                                  pads: pads, graphics: [],
                                  skippedNodeCounts: [:]),
        pins: pads.map {
            BoardPinBinding(pinNumber: $0.number, pinName: "",
                            pinType: "passive",
                            netName: nets[$0.number], pad: $0)
        },
        anomalies: [], notes: [], origin: origin, boundsSize: (w: 4, h: 4))
}
let headBoard52 = BoardModel(
    tableTitle: "Head", sourceFileName: "head.json",
    components: [
        synth52Component("S1", origin: FPPoint(x: 0, y: 0),
                         pads: [synth52Pad("1", 0, 0, w: 2, h: 2)],
                         nets: ["1": "NET_A"]),
        synth52Component("S2", origin: FPPoint(x: 30, y: 0),
                         pads: [synth52Pad("1", 0, 0, w: 1, h: 1)],
                         nets: ["1": "NET_A"]),
    ],
    globalAnomalies: [], excludedPowerReferences: [], netCount: 1,
    netNames: ["NET_A"])
let headFrom52 = FPPoint(x: 0, y: 0)
let gridMil52 = 25.0

// Snap-boundary straddle: the pointer dithers ±0.05 mm across
// the snap boundary at x = 9.8425 (cells 9.525 / 10.16).
var legacyEnds52 = Set<String>()
var head52 = BoardRouteHead()
var headEnds52 = Set<String>()
for i in 0..<40 {
    let px = i % 2 == 0 ? 9.80 : 9.89
    let probe = FPPoint(x: px, y: 3.0)
    let legacy = BoardGeometry.routePreview(
        headBoard52, from: headFrom52, pointer: probe, routeNet: "NET_A",
        snapEnabled: true, gridMil: gridMil52, tolerance: 0.8)
    legacyEnds52.insert("\(legacy.endPoint.x),\(legacy.endPoint.y)")
    let resolved = head52.resolve(
        headBoard52, from: headFrom52, pointer: probe, routeNet: "NET_A",
        snapEnabled: true, gridMil: gridMil52, tolerance: 0.8)
    headEnds52.insert("\(resolved.endPoint.x),\(resolved.endPoint.y)")
}
check(legacyEnds52.count == 2,
      "5.2 head: the pure resolution dithers between 2 endpoints on a snap boundary (got \(legacyEnds52.count))")
check(headEnds52.count == 1,
      "5.2 head: snap stickiness holds ONE endpoint through the same dither (got \(headEnds52.count))")
// ...and the head still follows a genuine move.
let followed52 = head52.resolve(
    headBoard52, from: headFrom52, pointer: FPPoint(x: 12.0, y: 3.0),
    routeNet: "NET_A", snapEnabled: true, gridMil: gridMil52, tolerance: 0.8)
check(approx(followed52.endPoint.x, 12.065) && approx(followed52.endPoint.y, 3.175),
      "5.2 head: a genuine move re-resolves (stickiness is not stickiness-forever)")

// Pad-rim straddle: S2's pad (centre (30,0), 1x1) has its
// tolerance rim at x = 31.3 for tolerance 0.8.
var rimLegacy52 = Set<String>()
var rimHead52 = BoardRouteHead()
var rimHeadEnds52 = Set<String>()
for i in 0..<40 {
    let px = i % 2 == 0 ? 31.25 : 31.35
    let probe = FPPoint(x: px, y: 0)
    let legacy = BoardGeometry.routePreview(
        headBoard52, from: headFrom52, pointer: probe, routeNet: "NET_A",
        snapEnabled: true, gridMil: gridMil52, tolerance: 0.8)
    rimLegacy52.insert("\(legacy.endPoint.x),\(legacy.endPoint.y)")
    let resolved = rimHead52.resolve(
        headBoard52, from: headFrom52, pointer: probe, routeNet: "NET_A",
        snapEnabled: true, gridMil: gridMil52, tolerance: 0.8)
    rimHeadEnds52.insert("\(resolved.endPoint.x),\(resolved.endPoint.y)")
}
check(rimLegacy52.count == 2,
      "5.2 head: the pure resolution flips pad-anchor/free on the pad rim (got \(rimLegacy52.count))")
check(rimHeadEnds52.count == 1
      && rimHeadEnds52.first == "30.0,0.0",
      "5.2 head: pad stickiness holds the anchor through the rim dither (got \(rimHeadEnds52))")
// Preview == tap through the head: anchored stickiness commits
// the anchored pad.
let rimTap52 = rimHead52.tapResolution(
    headBoard52, from: headFrom52, point: FPPoint(x: 31.35, y: 0),
    routingActive: true, routeNet: "NET_A", snapEnabled: true,
    gridMil: gridMil52, tolerance: 0.8)
if case .finishAtPad(let tapTarget) = rimTap52 {
    check(tapTarget.reference == "S2",
          "5.2 head: a tap during anchor stickiness finishes on the previewed pad")
} else {
    check(false, "5.2 head: a tap during anchor stickiness finishes on the previewed pad (got \(rimTap52))")
}
// A cold tap (no routing) is the pure routeTap answer verbatim.
var coldHead52 = BoardRouteHead()
check(coldHead52.tapResolution(
        headBoard52, from: nil, point: FPPoint(x: 20, y: 20),
        routingActive: false, routeNet: nil, snapEnabled: true,
        gridMil: gridMil52, tolerance: 0.8)
      == BoardGeometry.routeTap(
        headBoard52, point: FPPoint(x: 20, y: 20), routingActive: false,
        routeNet: nil, snapEnabled: true, gridMil: gridMil52, tolerance: 0.8),
      "5.2 head: a cold start tap equals the pure routeTap")

// Slow near-diagonal sweep WITH sub-cell jitter: the remainder
// orientation (vertical vs horizontal axis segment) must flip
// at most once through the head, many times through the pure
// resolution.
func remainderOrientation52(_ preview: BoardRoutePreview, from: FPPoint) -> String {
    guard let corner = preview.corner else { return "diag" }
    return preview.endPoint.x == corner.x ? "V" : "H"
}
func orientationFlips52(_ orientations: [String]) -> Int {
    var flips = 0
    var lastAxis: String? = nil
    for o in orientations where o != "diag" {
        if let lastAxis, o != lastAxis { flips += 1 }
        lastAxis = o
    }
    return flips
}
var legacyOrient52: [String] = []
var headOrient52: [String] = []
var sweepHead52 = BoardRouteHead()
for t in 0...80 {
    let along = Double(t) * 0.1
    // Along-track jitter ±0.2 mm: near the diagonal crossing this
    // moves the raw point back and forth ACROSS the diagonal
    // through `from` — the dither that flip-flops a pure
    // resolution.
    let jitter = (t % 2 == 0 ? 0.2 : -0.2) * 0.7071
    let probe = FPPoint(x: 4 + along + jitter,
                        y: 8 - along - jitter)
    let legacy = BoardGeometry.routePreview(
        headBoard52, from: headFrom52, pointer: probe, routeNet: "NET_A",
        snapEnabled: true, gridMil: gridMil52, tolerance: 0.8)
    legacyOrient52.append(remainderOrientation52(legacy, from: headFrom52))
    let resolved = sweepHead52.resolve(
        headBoard52, from: headFrom52, pointer: probe, routeNet: "NET_A",
        snapEnabled: true, gridMil: gridMil52, tolerance: 0.8)
    headOrient52.append(remainderOrientation52(resolved, from: headFrom52))
}
check(orientationFlips52(legacyOrient52) >= 3,
      "5.2 head: the pure resolution flip-flops on a jittered diagonal sweep (\(orientationFlips52(legacyOrient52)) flips)")
check(orientationFlips52(headOrient52) <= 1,
      "5.2 head: the stateful head crosses the diagonal at most once (\(orientationFlips52(headOrient52)) flips)")

// -- (3) Pointer throttle: coalescing --

var throttle52 = BoardPointerThrottle()
var admitted52: [FPPoint] = []
let offerCount52 = 240
for i in 0..<offerCount52 {
    let t = Double(i) / 240.0
    let p = FPPoint(x: Double(i), y: 0)
    if let admitted = throttle52.offer(p, at: t) { admitted52.append(admitted) }
    if let flushed = throttle52.flush(at: t) { admitted52.append(flushed) }
}
check(admitted52.count >= 45 && admitted52.count <= 65,
      "5.2 throttle: 240 offers in 1 s admit ~60 points (got \(admitted52.count))")
var throttleEnd52 = BoardPointerThrottle()
_ = throttleEnd52.offer(FPPoint(x: 1, y: 1), at: 0)
_ = throttleEnd52.offer(FPPoint(x: 2, y: 2), at: 0.001)
check(throttleEnd52.hasPending, "5.2 throttle: a mid-window offer is pending")
throttleEnd52.end()
check(!throttleEnd52.hasPending && throttleEnd52.flush(at: 10) == nil,
      "5.2 throttle: end() owes no trailing point")

// -- Spatial index: equality with the linear scans + timing --

/// Deterministic PRNG (LCG) for the synthetic boards.
struct LCG52: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state >> 11
    }
}
var rng52 = LCG52(state: 0x5EED_0052)
func rand52(_ upper: Double) -> Double {
    Double(rng52.next() % 1_000_000) / 1_000_000.0 * upper
}

var synthComponents52: [BoardComponent] = []
for c in 0..<120 {
    var pads: [KiCadFootprintPad] = []
    var nets: [String: String] = [:]
    for p in 0..<8 {
        pads.append(synth52Pad("\(p + 1)", rand52(6) - 3, rand52(6) - 3,
                               w: 0.8, h: 0.8))
        nets["\(p + 1)"] = "NET_\(p % 3)"
    }
    synthComponents52.append(synth52Component(
        "C\(c)", origin: FPPoint(x: rand52(200), y: rand52(200)),
        pads: pads, nets: nets))
}
var synthTraces52: [BoardTrace] = []
for t in 0..<400 {
    var points: [FPPoint] = []
    var p = FPPoint(x: rand52(200), y: rand52(200))
    for _ in 0..<(2 + t % 4) {
        points.append(p)
        p = FPPoint(x: p.x + rand52(20) - 10, y: p.y + rand52(20) - 10)
    }
    synthTraces52.append(BoardTrace(
        id: UUID(), netName: "NET_\(t % 3)", layer: "F.Cu",
        width: 0.25, points: points))
}
var synthVias52: [BoardVia] = []
for v in 0..<60 {
    synthVias52.append(BoardVia(
        id: UUID(), netName: "NET_\(v % 3)",
        center: FPPoint(x: rand52(200), y: rand52(200)),
        diameter: 0.6, drill: 0.3))
}
var synthZones52: [BoardZone] = []
for z in 0..<12 {
    let cx = rand52(180), cy = rand52(180)
    synthZones52.append(BoardZone(
        id: UUID(), netName: "NET_\(z % 3)", layer: "F.Cu",
        points: [FPPoint(x: cx, y: cy), FPPoint(x: cx + 15, y: cy),
                 FPPoint(x: cx + 15, y: cy + 15), FPPoint(x: cx, y: cy + 15)]))
}
var synthGraphics52: [BoardGraphicItem] = []
for g in 0..<30 {
    synthGraphics52.append(BoardGraphicItem(
        id: UUID(), kind: .line, layer: "Dwgs.User",
        points: [FPPoint(x: rand52(200), y: rand52(200)),
                 FPPoint(x: rand52(200), y: rand52(200))]))
}
let synthBoard52 = BoardModel(
    tableTitle: "Synth", sourceFileName: "synth.json",
    components: synthComponents52, globalAnomalies: [],
    excludedPowerReferences: [], netCount: 3,
    netNames: ["NET_0", "NET_1", "NET_2"],
    traces: synthTraces52, graphics: synthGraphics52,
    vias: synthVias52, zones: synthZones52)
let synthIndex52 = BoardSpatialIndex.build(synthBoard52)

var indexMismatches52 = 0
for q in 0..<3000 {
    let point = FPPoint(x: rand52(210) - 5, y: rand52(210) - 5)
    let tolerance = q % 2 == 0 ? 0.8 : 2.5
    let linPad = BoardGeometry.padAt(synthBoard52, point: point, tolerance: tolerance)
    let idxPad = synthIndex52.padAt(synthBoard52, point: point, tolerance: tolerance)
    if (linPad?.component.reference, linPad?.pad.number, linPad?.netName)
        != (idxPad?.component.reference, idxPad?.pad.number, idxPad?.netName) {
        indexMismatches52 += 1
    }
    if BoardGeometry.traceAt(synthBoard52, point: point, tolerance: tolerance)?.id
        != synthIndex52.traceAt(synthBoard52, point: point, tolerance: tolerance)?.id {
        indexMismatches52 += 1
    }
    if BoardGeometry.componentAt(synthBoard52, point: point)?.reference
        != synthIndex52.componentAt(synthBoard52, point: point)?.reference {
        indexMismatches52 += 1
    }
    if BoardGeometry.viaAt(synthBoard52, point: point, tolerance: tolerance)?.id
        != synthIndex52.viaAt(synthBoard52, point: point, tolerance: tolerance)?.id {
        indexMismatches52 += 1
    }
    if BoardGeometry.zoneAt(synthBoard52, point: point, tolerance: tolerance)?.id
        != synthIndex52.zoneAt(synthBoard52, point: point, tolerance: tolerance)?.id {
        indexMismatches52 += 1
    }
    if BoardGeometry.graphicAt(synthBoard52, point: point, tolerance: tolerance)?.id
        != synthIndex52.graphicAt(synthBoard52, point: point, tolerance: tolerance)?.id {
        indexMismatches52 += 1
    }
    let linSeg = BoardGeometry.segmentAt(synthBoard52.traces, point: point,
                                         tolerance: tolerance)
    let idxSeg = synthIndex52.segmentAt(synthBoard52, point: point,
                                        tolerance: tolerance)
    if linSeg?.trace.id != idxSeg?.trace.id
        || linSeg?.index != idxSeg?.index
        || (linSeg != nil && idxSeg != nil
            && !approx(linSeg!.distance, idxSeg!.distance)) {
        indexMismatches52 += 1
    }
    if q % 15 == 0 {
        let linHover = BoardGeometry.hoverTarget(synthBoard52, point: point, tolerance: tolerance)
        let idxHover = synthIndex52.hoverTarget(synthBoard52, point: point, tolerance: tolerance)
        if linHover != idxHover { indexMismatches52 += 1 }
    }
}
check(indexMismatches52 == 0,
      "5.2 index: 3,000 random queries x 7 lookups match the linear scans exactly (\(indexMismatches52) mismatches)")

// Timing (host numbers — printed for the record, gated loosely):
// 2,000 hover-target resolutions, linear vs indexed.
var probes52: [FPPoint] = []
for _ in 0..<2000 { probes52.append(FPPoint(x: rand52(200), y: rand52(200))) }
let linearStart52 = Date()
var linearHits52 = 0
for p in probes52 {
    if BoardGeometry.hoverTarget(synthBoard52, point: p, tolerance: 0.8) != nil {
        linearHits52 += 1
    }
}
let linearTime52 = Date().timeIntervalSince(linearStart52)
let indexStart52 = Date()
var indexHits52 = 0
for p in probes52 {
    if synthIndex52.hoverTarget(synthBoard52, point: p, tolerance: 0.8) != nil {
        indexHits52 += 1
    }
}
let indexTime52 = Date().timeIntervalSince(indexStart52)
print(String(format: "5.2 index timing (host): linear %.3f s, indexed %.3f s for 2,000 hover targets (%.1fx)",
             linearTime52, indexTime52, linearTime52 / max(indexTime52, 1e-6)))
check(linearHits52 == indexHits52 && indexTime52 < linearTime52,
      "5.2 index: indexed hover targets agree and run faster on the synthetic board")

// -- Ratsnest --

func ratsnestBoard52(traces: [BoardTrace]) -> BoardModel {
    BoardModel(
        tableTitle: "RN", sourceFileName: "rn.json",
        components: [
            synth52Component("A", origin: FPPoint(x: 0, y: 0),
                             pads: [synth52Pad("1", 0, 0), synth52Pad("2", 10, 0)],
                             nets: ["1": "N", "2": "N"]),
            synth52Component("B", origin: FPPoint(x: 100, y: 0),
                             pads: [synth52Pad("1", 0, 0), synth52Pad("2", 10, 0)],
                             nets: ["1": "N", "2": "N"]),
            synth52Component("C", origin: FPPoint(x: 0, y: 100),
                             pads: [synth52Pad("1", 0, 0)],
                             nets: ["1": "SOLO"]),
        ],
        globalAnomalies: [], excludedPowerReferences: [], netCount: 2,
        netNames: ["N", "SOLO"], traces: traces)
}
let rnOpen52 = BoardRatsnest.segments(model: ratsnestBoard52(traces: []),
                                      copperCount: 4)
check(rnOpen52.count == 3 && rnOpen52.allSatisfy { $0.netName == "N" },
      "5.2 ratsnest: 4 unconnected pads of one net give a 3-segment MST (got \(rnOpen52.count))")
let rnTotal52 = rnOpen52.reduce(0) { $0 + $1.from.distance(to: $1.to) }
check(approx(rnTotal52, 110),
      "5.2 ratsnest: the MST takes the two 10 mm in-part links and the 90 mm bridge (total \(rnTotal52))")
let rnBridged52 = BoardRatsnest.segments(
    model: ratsnestBoard52(traces: [BoardTrace(
        id: UUID(), netName: "N", layer: "F.Cu", width: 0.25,
        points: [FPPoint(x: 10, y: 0), FPPoint(x: 100, y: 0)])]),
    copperCount: 4)
check(rnBridged52.count == 2,
      "5.2 ratsnest: a routed bridge merges two groups (got \(rnBridged52.count))")
let rnDone52 = BoardRatsnest.segments(
    model: ratsnestBoard52(traces: [BoardTrace(
        id: UUID(), netName: "N", layer: "F.Cu", width: 0.25,
        points: [FPPoint(x: 0, y: 0), FPPoint(x: 10, y: 0),
                 FPPoint(x: 100, y: 0), FPPoint(x: 110, y: 0)])]),
    copperCount: 4)
check(rnDone52.isEmpty,
      "5.2 ratsnest: a fully routed net (and a single-pad net) show no lines")

// -- Manufacturing rules 9 + 10 (1-8 untouched) --

let mfgBase52 = ratsnestBoard52(traces: [])
var mfgModel52 = mfgBase52
mfgModel52.vias = [
    BoardVia(id: UUID(), netName: "N", center: FPPoint(x: 50, y: 50),
             diameter: 0.5, drill: 0.3),   // ring 0.10 mm = 3.9 mil: fails
    BoardVia(id: UUID(), netName: "N", center: FPPoint(x: 60, y: 50),
             diameter: 0.8, drill: 0.3),   // ring 0.25 mm = 9.8 mil: passes
]
let mfgReport52 = BoardManufacturing.check(
    model: mfgModel52, copperCount: 4,
    settings: ManufacturingSettings(),
    connectivity: BoardConnectivity.analyze(model: mfgModel52, copperCount: 4))
check(mfgReport52.rules.count == 10,
      "5.2 manufacturing: the report now runs 10 rules (got \(mfgReport52.rules.count))")
check(mfgReport52.rules[7].name == "Every component has a footprint"
      && mfgReport52.rules[0].name.hasPrefix("Clearance"),
      "5.2 manufacturing: rules 1-8 keep their names and order")
check(mfgReport52.rules[8].name.hasPrefix("Via annular ring")
      && !mfgReport52.rules[8].passed
      && mfgReport52.rules[8].violations.count == 1,
      "5.2 manufacturing: the 3.9 mil ring fails rule 9, the 9.8 mil ring passes")
check(mfgReport52.rules[9].passed,
      "5.2 manufacturing: no courtyards in the base model, rule 10 passes")

func courtyardComponent52(_ reference: String, origin: FPPoint) -> BoardComponent {
    var component = synth52Component(
        reference, origin: origin, pads: [synth52Pad("1", 0, 0)], nets: ["1": "N"])
    component.footprint = KiCadFootprint(
        name: "F", description: "", tags: [], attributes: [], properties: [:],
        pads: [synth52Pad("1", 0, 0)],
        graphics: [.rect(start: FPPoint(x: -5, y: -5), end: FPPoint(x: 5, y: 5),
                         layer: "F.CrtYd", strokeWidth: 0.05,
                         strokeType: "default", fill: "none")],
        skippedNodeCounts: [:])
    return component
}
var courtModel52 = mfgBase52
courtModel52.components = [
    courtyardComponent52("K1", origin: FPPoint(x: 0, y: 0)),
    courtyardComponent52("K2", origin: FPPoint(x: 8, y: 0)),   // overlaps K1
    courtyardComponent52("K3", origin: FPPoint(x: 40, y: 0)),  // clear
]
courtModel52.vias = []
let courtReport52 = BoardManufacturing.check(
    model: courtModel52, copperCount: 4,
    settings: ManufacturingSettings(),
    connectivity: BoardConnectivity.analyze(model: courtModel52, copperCount: 4))
check(!courtReport52.rules[9].passed
      && courtReport52.rules[9].violations.count == 1
      && courtReport52.rules[9].violations[0].contains("K1")
      && courtReport52.rules[9].violations[0].contains("K2"),
      "5.2 manufacturing: overlapping courtyards fail rule 10 naming both parts")

// -- Align / distribute / duplicate / lock / measure --

func alignComponent52(_ reference: String, _ x: Double, _ y: Double) -> BoardComponent {
    synth52Component(reference, origin: FPPoint(x: x, y: y),
                     pads: [synth52Pad("1", 0, 0, w: 2, h: 2)], nets: ["1": "N"])
}
let alignBoard52 = BoardModel(
    tableTitle: "Align", sourceFileName: "a.json",
    components: [alignComponent52("A1", 10, 10), alignComponent52("A2", 20, 14),
                 alignComponent52("A3", 30, 18), alignComponent52("A4", 40, 22)],
    globalAnomalies: [], excludedPowerReferences: [], netCount: 1,
    netNames: ["N"])
let alignLeft52 = BoardPlacementTools.alignedOrigins(
    alignBoard52, references: ["A1", "A2", "A3"], mode: .left,
    lockedReferences: [])
check(alignLeft52 == ["A2": FPPoint(x: 10, y: 14), "A3": FPPoint(x: 10, y: 18)],
      "5.2 align: left-align moves A2/A3 to A1's edge, A1 (already there) is untouched")
let alignCentre52 = BoardPlacementTools.alignedOrigins(
    alignBoard52, references: ["A2", "A1"], mode: .centreX,
    lockedReferences: [])
check(alignCentre52 == ["A1": FPPoint(x: 20, y: 10)],
      "5.2 align: centre-align anchors on the FIRST listed reference (A2)")
let alignLocked52 = BoardPlacementTools.alignedOrigins(
    alignBoard52, references: ["A1", "A2", "A3"], mode: .left,
    lockedReferences: ["A3"])
check(alignLocked52 == ["A2": FPPoint(x: 10, y: 14)],
      "5.2 align: a locked component never moves")
let distributed52 = BoardPlacementTools.distributedOrigins(
    alignBoard52, references: ["A1", "A2", "A3", "A4"], horizontal: true,
    lockedReferences: [])
check(distributed52.isEmpty,
      "5.2 distribute: already-even centres stay (extremes fixed, middles already spaced)")
let unevenBoard52 = BoardModel(
    tableTitle: "Dist", sourceFileName: "d.json",
    components: [alignComponent52("B1", 0, 0), alignComponent52("B2", 10, 0),
                 alignComponent52("B3", 15, 0), alignComponent52("B4", 40, 0)],
    globalAnomalies: [], excludedPowerReferences: [], netCount: 1,
    netNames: ["N"])
let redistributed52 = BoardPlacementTools.distributedOrigins(
    unevenBoard52, references: ["B1", "B2", "B3", "B4"], horizontal: true,
    lockedReferences: [])
check(redistributed52.count == 2
      && approx(redistributed52["B2"]!.x, 40.0 / 3)
      && approx(redistributed52["B3"]!.x, 80.0 / 3),
      "5.2 distribute: middles move to even thirds between the fixed extremes")

var dupState52 = BoardState()
let dupTraceID52 = UUID(), dupViaID52 = UUID(), dupZoneID52 = UUID(), dupGraphicID52 = UUID()
dupState52.traces = [BoardTrace(id: dupTraceID52, netName: "N", layer: "F.Cu",
                                width: 0.3, points: [FPPoint(x: 0, y: 0), FPPoint(x: 5, y: 0)])]
dupState52.vias = [BoardVia(id: dupViaID52, netName: "N",
                            center: FPPoint(x: 2, y: 2), diameter: 0.6, drill: 0.3)]
dupState52.zones = [BoardZone(id: dupZoneID52, netName: "N", layer: "F.Cu",
                              points: [FPPoint(x: 0, y: 0), FPPoint(x: 4, y: 0), FPPoint(x: 4, y: 4)])]
dupState52.graphics = [BoardGraphicItem(id: dupGraphicID52, kind: .line,
                                        layer: "Dwgs.User",
                                        points: [FPPoint(x: 1, y: 1), FPPoint(x: 6, y: 1)])]
let dup52 = dupState52.duplicatedItems(
    traceIDs: [dupTraceID52], viaIDs: [dupViaID52], zoneIDs: [dupZoneID52],
    graphicIDs: [dupGraphicID52], offset: FPPoint(x: 1.27, y: 1.27))
check(dup52.traces.count == 1 && dup52.traces[0].id != dupTraceID52
      && dup52.traces[0].points[0] == FPPoint(x: 1.27, y: 1.27)
      && dup52.traces[0].netName == "N" && dup52.traces[0].width == 0.3
      && dup52.vias.count == 1 && dup52.vias[0].center == FPPoint(x: 3.27, y: 3.27)
      && dup52.zones.count == 1 && dup52.zones[0].points[2] == FPPoint(x: 5.27, y: 5.27)
      && dup52.graphics.count == 1 && dup52.graphics[0].id != dupGraphicID52,
      "5.2 duplicate: copies get fresh ids, the offset, and keep net/width/layer")

var lockState52 = dupState52
lockState52.setLocked(dupTraceID52, true)
lockState52.setLocked(reference: "A1", true)
check(lockState52.isLocked(dupTraceID52) && lockState52.isLocked(reference: "A1")
      && !lockState52.isLocked(dupViaID52),
      "5.2 lock: item and component locks record independently")
let lockRoundTrip52 = try! JSONDecoder().decode(
    BoardState.self, from: JSONEncoder().encode(lockState52))
check(lockRoundTrip52 == lockState52,
      "5.2 lock: locks survive the BoardState round-trip")
let preLockJSON52 = """
{"formatVersion":1,"placements":{},"excludedReferences":[],"traces":[],
 "graphics":[],"knownReferences":[],"vias":[],"zones":[],"sides":{},
 "copperLayerCount":4,"gridMil":25,"clearanceMil":8}
"""
let preLockState52 = try! JSONDecoder().decode(
    BoardState.self, from: Data(preLockJSON52.utf8))
check(preLockState52.lockedItemIDs.isEmpty && preLockState52.lockedReferences.isEmpty,
      "5.2 lock: a pre-5.2 board file (no lock keys) decodes with no locks")

var measure52 = BoardMeasure()
measure52.tap(FPPoint(x: 0, y: 0))
check(measure52.distance == nil, "5.2 measure: one tap is not a measurement")
measure52.tap(FPPoint(x: 3, y: 4))
check(measure52.distance == 5 && measure52.delta == FPPoint(x: 3, y: 4),
      "5.2 measure: two taps give distance and deltas")
measure52.tap(FPPoint(x: 10, y: 10))
check(measure52.distance == nil && measure52.a == FPPoint(x: 10, y: 10),
      "5.2 measure: a third tap starts a new measurement")

// -- ERC + annotation + the properties-card undo fix --

func ercPin52(_ number: String, _ type: KiCadPinType,
              _ x: Double, _ y: Double) -> KiCadPin {
    KiCadPin(number: number, name: "P\(number)", type: type, shape: .line,
             x: x, y: y, rotation: 0, length: 2.54, hidden: false,
             nameSize: 1.27, numberSize: 1.27)
}
func ercDef52(_ name: String, pins: [KiCadPin]) -> KiCadSymbolDef {
    KiCadSymbolDef(
        name: name, library: "Fixture", properties: [],
        units: [1: KiCadUnitDef(graphics: [], pins: pins)],
        unitCount: 1, extendsName: nil, pinNameOffset: 0.508,
        pinNamesHidden: false, pinNumbersHidden: false, isPowerSymbol: false)
}
let icDef52 = ercDef52("IC", pins: [
    ercPin52("1", .input, -5.08, 0), ercPin52("2", .output, 5.08, 0),
    ercPin52("3", .powerIn, 0, 5.08), ercPin52("4", .noConnect, 0, -5.08),
])
let rDef52 = ercDef52("R", pins: [
    ercPin52("1", .passive, -5.08, 0), ercPin52("2", .passive, 5.08, 0),
])
let ercDefs52: [String: KiCadSymbolDef] = ["IC": icDef52, "R": rDef52]
func ercPlaced52(_ reference: String, _ symbol: String,
                 _ x: Double, _ y: Double) -> PlacedSymbol {
    PlacedSymbol(id: UUID(), library: "Fixture", symbolName: symbol, unit: 1,
                 x: x, y: y, rotation: 0, mirrorX: false, mirrorY: false,
                 reference: reference, value: symbol)
}
var ercState52 = SchematicState(symbols: [], wires: [], junctions: [],
                                labels: [], title: "ERC")
let eu1 = ercPlaced52("U1", "IC", 0, 0)
let eu2 = ercPlaced52("U2", "IC", 30, 0)
let er1 = ercPlaced52("R1", "R", 15, 20)
let ex1a = ercPlaced52("X1", "R", 60, 40)
let ex1b = ercPlaced52("X1", "R", 70, 40)
let eq = ercPlaced52("Q?", "R", 60, 60)
ercState52.symbols = [eu1, eu2, er1, ex1a, ex1b, eq]
func pinPoint52(_ placed: PlacedSymbol, _ number: String) -> DPoint {
    let def = ercDefs52[placed.symbolName]!
    return SymbolDrawList.pinWorldPoints(def: def, placed: placed)
        .first { $0.pin.number == number }!.point
}
func wire52(_ a: DPoint, _ b: DPoint) {
    ercState52.wires.append(WireItem(id: UUID(), points: [a, b]))
}
// Output net: U1.2 -- R1.1, with U2.2 also on it (conflict).
wire52(pinPoint52(eu1, "2"), pinPoint52(er1, "1"))
wire52(pinPoint52(eu2, "2"), pinPoint52(er1, "1"))
// U2.1 input tied to the same net (legal listener).
wire52(pinPoint52(eu2, "1"), pinPoint52(er1, "1"))
// Power net: U1.3 + U2.3 + R1.2 — power_in pins, no driver.
wire52(pinPoint52(eu1, "3"), pinPoint52(er1, "2"))
wire52(pinPoint52(eu2, "3"), pinPoint52(er1, "2"))
// U1.1 input on a lone stub wire (connected only to itself).
let stubStart52 = pinPoint52(eu1, "1")
wire52(stubStart52, DPoint(x: stubStart52.x - 2.54, y: stubStart52.y))
// The remaining symbols get harmless self-nets so the ONLY
// unconnected pin in the fixture is U1 pin 1.
wire52(pinPoint52(ex1a, "1"), pinPoint52(ex1a, "2"))
wire52(pinPoint52(ex1b, "1"), pinPoint52(ex1b, "2"))
wire52(pinPoint52(eq, "1"), pinPoint52(eq, "2"))
ercState52.labels = [LabelItem(id: UUID(), at: DPoint(x: 200, y: 200), text: "FLOAT")]
let ercFindings52 = SchematicERC.check(state: ercState52) { ercDefs52[$0.symbolName] }
func ercCount52(_ kind: ERCFinding.Kind) -> Int {
    ercFindings52.filter { $0.kind == kind }.count
}
check(ercCount52(.pinNotConnected) == 1
      && ercFindings52.first { $0.kind == .pinNotConnected }?.message
        .contains("U1 pin 1") == true,
      "5.2 ERC: only U1's stub-wired input is 'not connected' (no_connect pin exempt)")
check(ercCount52(.powerPinNotDriven) == 1,
      "5.2 ERC: the undriven power net is flagged once")
check(ercCount52(.outputConflict) == 1,
      "5.2 ERC: two outputs on one net conflict")
check(ercCount52(.duplicateReference) == 1,
      "5.2 ERC: X1 placed twice on unit 1 is a duplicate")
check(ercCount52(.unannotated) == 1,
      "5.2 ERC: Q? is unannotated")
check(ercCount52(.labelNotConnected) == 1,
      "5.2 ERC: the floating label is flagged")
check(ercCount52(.unresolvedSymbol) == 0 && ercFindings52.count == 6,
      "5.2 ERC: exactly the six expected findings (got \(ercFindings52.count): \(ercFindings52.map(\.message)))")

// Annotation: keep R1/R3, fill first-free for R? parts, reassign
// the duplicate R1.
let annDoc52 = SchematicDocument()
var annState52 = SchematicState(symbols: [], wires: [], junctions: [],
                                labels: [], title: "Ann")
annState52.symbols = [
    ercPlaced52("R1", "R", 0, 30), ercPlaced52("R3", "R", 0, 20),
    ercPlaced52("R?", "R", 0, 10), ercPlaced52("R?", "R", 0, 0),
    ercPlaced52("R1", "R", 10, 30),
]
annDoc52.replaceState(annState52)
let annChanged52 = annDoc52.annotateReferences()
let annRefs52 = annDoc52.state.symbols.map(\.reference)
check(annChanged52 == 3 && Set(annRefs52) == ["R1", "R2", "R3", "R4", "R5"]
      && annDoc52.state.symbols[0].reference == "R1"
      && annDoc52.state.symbols[1].reference == "R3",
      "5.2 annotate: kept refs stay, ? parts fill first-free, the duplicate is reassigned (got \(annRefs52))")
check(annDoc52.canUndo, "5.2 annotate: the whole run is one undo step")
annDoc52.undo()
check(annDoc52.state.symbols.map(\.reference)
      == ["R1", "R3", "R?", "R?", "R1"],
      "5.2 annotate: one undo restores every original reference")

// editSymbol: the properties card's path records exactly one
// step per real change, none for a no-op.
let editDoc52 = SchematicDocument()
var editState52 = SchematicState(symbols: [], wires: [], junctions: [],
                                 labels: [], title: "Edit")
let editPlaced52 = ercPlaced52("R1", "R", 0, 0)
editState52.symbols = [editPlaced52]
editDoc52.replaceState(editState52)
editDoc52.editSymbol(id: editPlaced52.id) { $0.value = "10k" }
check(editDoc52.state.symbols[0].value == "10k" && editDoc52.canUndo,
      "5.2 card fix: an editSymbol change applies and records one undo step")
editDoc52.editSymbol(id: editPlaced52.id) { $0.value = "10k" }
editDoc52.undo()
check(editDoc52.state.symbols[0].value == "R" && !editDoc52.canUndo,
      "5.2 card fix: a no-op edit records nothing (one undo reaches the start)")

// -- De Morgan alternate bodies --

let dmText52 = fixtureText("DeMorganSym.kicad_sym")
let dmLibrary52 = try! KiCadLibrary.parse(name: "FixtureDM", text: dmText52)
let dmDef52 = dmLibrary52.symbols["GateDM"]!
check(dmDef52.hasAlternateBody,
      "5.2 De Morgan: a style-2 sub-symbol marks the alternate body")
check(dmDef52.units[1]?.graphics.count == 1 && dmDef52.altUnits[1]?.graphics.count == 1,
      "5.2 De Morgan: standard and alternate bodies each carry one graphic")
let dmDraw1_52 = SymbolDrawList.build(def: dmDef52, unit: 1,
                                      pinNameOffset: dmDef52.pinNameOffset)
let dmDraw2_52 = SymbolDrawList.build(def: dmDef52, unit: 1,
                                      pinNameOffset: dmDef52.pinNameOffset,
                                      bodyStyle: 2)
func graphicKind52(_ g: SymbolDrawList.GraphicGeom) -> String {
    switch g {
    case .rectangle: return "rect"
    case .circle: return "circle"
    default: return "other"
    }
}
check(dmDraw1_52.graphics.count == 1 && dmDraw2_52.graphics.count == 1
      && graphicKind52(dmDraw1_52.graphics[0]) == "rect"
      && graphicKind52(dmDraw2_52.graphics[0]) == "circle",
      "5.2 De Morgan: the two body styles draw different bodies")
check(dmDraw1_52.pins.map(\.pin.number) == dmDraw2_52.pins.map(\.pin.number)
      && dmDraw2_52.pins.map(\.pin.number) == ["1", "2"],
      "5.2 De Morgan: style-0 pins are common to both bodies")
var dmPlaced52 = ercPlaced52("U1", "GateDM", 10, 10)
let dmPoints1_52 = SymbolDrawList.pinWorldPoints(def: dmDef52, placed: dmPlaced52)
dmPlaced52.bodyStyle = 2
let dmPoints2_52 = SymbolDrawList.pinWorldPoints(def: dmDef52, placed: dmPlaced52)
check(dmPoints1_52.map(\.point) == dmPoints2_52.map(\.point),
      "5.2 De Morgan: pin world points are identical across body styles")
let dmStateJSON52 = try! JSONEncoder().encode(
    SchematicState(symbols: [dmPlaced52], wires: [], junctions: [],
                   labels: [], title: "DM"))
let dmStateBack52 = try! JSONDecoder().decode(SchematicState.self,
                                              from: dmStateJSON52)
check(dmStateBack52.symbols[0].effectiveBodyStyle == 2,
      "5.2 De Morgan: the body style persists through save/load")
let dmOldJSON52 = """
{"symbols":[{"id":"\(dmPlaced52.id.uuidString)","library":"Fixture",
 "symbolName":"GateDM","unit":1,"x":10,"y":10,"rotation":0,
 "mirrorX":false,"mirrorY":false,"reference":"U1","value":"GateDM"}],
 "wires":[],"junctions":[],"labels":[],"title":"Old"}
"""
let dmOldState52 = try! JSONDecoder().decode(
    SchematicState.self, from: Data(dmOldJSON52.utf8))
check(dmOldState52.symbols[0].effectiveBodyStyle == 1,
      "5.2 De Morgan: pre-5.2 schematic JSON (no bodyStyle key) loads as style 1")

// MARK: - Part 5.3: net membership, sheet cleanup, no-connects,
//         change/update symbol, fields table, annotation options,
//         find, wire-set deletion, align-to-grid, ERC/manufacturing
//         exclusions, ratsnest hiding, netclasses, teardrops,
//         tracks/graphics cleanup, net queries, unroute, clipboard,
//         move-exactly transforms, layer swap, global delete,
//         PCB find, footprint refresh
//
// The v5.3 proof section. Every assertion below states the
// CONTRACT value for the feature (the SM/PM lane specs), checked
// against the real model code compiled into this harness.

// -- Small constructors shared by the 5.3 scenarios --

func dp53(_ x: Double, _ y: Double) -> DPoint { DPoint(x: x, y: y) }
func fp53(_ x: Double, _ y: Double) -> FPPoint { FPPoint(x: x, y: y) }

func schState53(symbols: [PlacedSymbol] = [], wires: [WireItem] = [],
                junctions: [JunctionItem] = [], labels: [LabelItem] = [],
                noConnects: [NoConnectItem] = [], title: String = "53")
    -> SchematicState {
    SchematicState(symbols: symbols, wires: wires, junctions: junctions,
                   labels: labels, title: title, noConnects: noConnects)
}

func makeDoc53(_ state: SchematicState) -> SchematicDocument {
    let doc = SchematicDocument()
    doc.replaceState(state)
    return doc
}

func wire53(_ id: UUID, _ points: [DPoint]) -> WireItem {
    WireItem(id: id, points: points)
}

func trace53(_ id: UUID, _ net: String?, _ layer: String,
             _ width: Double, _ points: [FPPoint]) -> BoardTrace {
    BoardTrace(id: id, netName: net, layer: layer, width: width,
               points: points)
}

/// The six cleanUpSheet counts as one comparable dictionary.
func cleanupCounts53(null: Int = 0, dup: Int = 0, merged: Int = 0,
                     dupJ: Int = 0, dropped: Int = 0, isolated: Int = 0)
    -> [String: Int] {
    ["nullWires": null, "duplicateWires": dup, "mergedWires": merged,
     "duplicateJunctions": dupJ, "droppedJunctions": dropped,
     "isolatedWires": isolated]
}

// -- S1: connection-table net membership (wire <-> net, both ways) --

checkEqual(table.netName(forWireID: wireA.id) ?? "", "NET_A",
           "5.3 S1: wireA belongs to NET_A")
checkEqual(table.netName(forWireID: wireB.id) ?? "", "NET_B",
           "5.3 S1: wireB belongs to NET_B")
checkEqual(table.netName(forWireID: wireVCC.id) ?? "", "VCC",
           "5.3 S1: wireVCC belongs to VCC")
checkEqual(table.wireIDs(forNet: "NET_A"), [wireA.id],
           "5.3 S1: NET_A is formed by wireA alone")
checkEqual(table.wireIDs(forNet: "NET_B"), [wireB.id],
           "5.3 S1: NET_B is formed by wireB alone")
checkEqual(table.wireIDs(forNet: "VCC"), [wireVCC.id],
           "5.3 S1: VCC is formed by wireVCC alone")
checkEqual(table.net(named: "VCC")?.wireIDList ?? [], [wireVCC.id],
           "5.3 S1: the VCC net records wireVCC in its own wire list")
checkEqual(table.symbolInstanceIDs(forNet: "NET_A"), [r1.id, u1Unit1.id],
           "5.3 S1: NET_A's instances are R1 + U1 unit 1 (endpoint order)")
checkEqual(table.symbolInstanceIDs(forNet: "NET_B"), [u1Unit2.id, x1.id],
           "5.3 S1: NET_B's instances are U1 unit 2 + X1")
checkEqual(table.symbolInstanceIDs(forNet: "VCC"), [u1Unit1.id, x1.id],
           "5.3 S1: VCC's instances are U1 unit 1 + X1")

// A free wire that touches no pin participates in no written net.
let freeWire53 = wire53(
    fixedUUID("D53D53D5-3D53-4D53-8D53-D53D53D53D53"),
    [dp53(200, 200), dp53(210, 200)])
var stateFree53 = state
stateFree53.wires.append(freeWire53)
let tableFree53 = ConnectionTableBuilder.build(
    state: stateFree53,
    sourceFileName: "fixture53.json",
    resolveSymbol: { placed in
        defsByKey["\(placed.library)|\(placed.symbolName)"]
    },
    resolveFootprint: { placed, def in
        let match = FootprintMatcher.match(def: def,
                                           choiceKey: placed.footprintChoice,
                                           entries: entries)
        return (key: match.resolved?.resolutionKey, kind: match.kind?.rawValue)
    })
check(tableFree53.netName(forWireID: freeWire53.id) == nil,
      "5.3 S1: the free wire belongs to no net")
check(!tableFree53.wireNetMap.keys.contains(freeWire53.id),
      "5.3 S1: the free wire is absent from the wire->net map")
checkEqual(tableFree53.nets.count, 3,
           "5.3 S1: the free wire creates no net")

// JSON round-trip of the table: the recorded membership survives.
do {
    let data53 = try encoder.encode(table)
    let decoded53 = try decoder.decode(ConnectionTable.self, from: data53)
    checkEqual(decoded53.wireNetByWireID ?? [:], table.wireNetByWireID ?? [:],
               "5.3 S1: the wire->net map round-trips through JSON")
    checkEqual(decoded53.nets.map(\.wireIDs), table.nets.map(\.wireIDs),
               "5.3 S1: every net's wire id list round-trips through JSON")
    check(decoded53.flaggedNoConnectPinKeySet.isEmpty,
          "5.3 S1: the fixture table flags no no-connect pins")
} catch {
    check(false, "5.3 S1: table JSON round-trip threw \(error)")
}

// The existing v1 literal table (no membership keys at all)
// decodes with empty membership.
do {
    let v1Table53 = try decoder.decode(ConnectionTable.self,
                                       from: Data(v1JSON.utf8))
    check(v1Table53.wireNetMap.isEmpty,
          "5.3 S1: a pre-5.3 table has an empty wire->net map")
    check(v1Table53.flaggedNoConnectPinKeySet.isEmpty,
          "5.3 S1: a pre-5.3 table flags no no-connect pins")
} catch {
    check(false, "5.3 S1: v1 table literal decode threw \(error)")
}

// -- Pre-5.3 schematic JSON: additive state fields default away --

let oldSchematicJSON53 = """
{"symbols":[{"id":"11111111-1111-4111-8111-111111111111",\
"library":"Fixture","symbolName":"R","unit":1,"x":0,"y":0,\
"rotation":0,"mirrorX":false,"mirrorY":false,"reference":"R1",\
"value":"10k"}],"wires":[],"junctions":[],"labels":[],"title":"Old53"}
"""
do {
    let oldState53 = try JSONDecoder().decode(
        SchematicState.self, from: Data(oldSchematicJSON53.utf8))
    checkEqual(oldState53.symbols.count, 1,
               "5.3 compat: the pre-5.3 schematic keeps its one symbol")
    checkEqual(oldState53.title, "Old53",
               "5.3 compat: the pre-5.3 schematic keeps its title")
    check(oldState53.noConnects.isEmpty && oldState53.ercExclusions.isEmpty
          && oldState53.ercExclusionNotes.isEmpty,
          "5.3 compat: pre-5.3 JSON loads with no no-connects or ERC exclusions")
} catch {
    check(false, "5.3 compat: pre-5.3 schematic literal threw \(error)")
}
let oldSchematicNCJSON53 = """
{"symbols":[{"id":"11111111-1111-4111-8111-111111111111",\
"library":"Fixture","symbolName":"R","unit":1,"x":0,"y":0,\
"rotation":0,"mirrorX":false,"mirrorY":false,"reference":"R1",\
"value":"10k"}],"wires":[],"junctions":[],"labels":[],"title":"Old53",\
"noConnects":[{"id":"22222222-2222-4222-8222-222222222222","at":{"x":1,"y":2}}]}
"""
do {
    let oldState53 = try JSONDecoder().decode(
        SchematicState.self, from: Data(oldSchematicNCJSON53.utf8))
    checkEqual(oldState53.noConnects.count, 1,
               "5.3 compat: a 5.3 file's no-connect flag decodes")
    check(oldState53.noConnects.first?.at == dp53(1, 2),
          "5.3 compat: the no-connect flag sits at (1, 2)")
    check(oldState53.ercExclusions.isEmpty,
          "5.3 compat: the no-connect file still has no ERC exclusions")
} catch {
    check(false, "5.3 compat: no-connect schematic literal threw \(error)")
}

// -- S3: cleanUpSheet --

// A: nulls + one exact duplicate; the L pair is left alone.
let wireA53 = wire53(fixedUUID("A53A53A5-3A53-4A53-8A53-A53A53A53A01"),
                     [dp53(0, 0), dp53(10, 0)])
let wireB53 = wire53(fixedUUID("A53A53A5-3A53-4A53-8A53-A53A53A53A02"),
                     [dp53(10, 0), dp53(10, 10)])
let docCleanA53 = makeDoc53(schState53(wires: [
    wire53(UUID(), [dp53(0, 0), dp53(0, 0)]),
    wireA53,
    wire53(UUID(), [dp53(0, 0), dp53(10, 0)]),
    wireB53,
    wire53(UUID(), [dp53(5, 5)]),
]))
checkEqual(docCleanA53.cleanUpSheet(), cleanupCounts53(null: 2, dup: 1),
           "5.3 cleanup A: 2 null wires + 1 duplicate, nothing else")
checkEqual(docCleanA53.state.wires.map(\.id), [wireA53.id, wireB53.id],
           "5.3 cleanup A: the first copies of the L pair remain")
check(docCleanA53.canUndo, "5.3 cleanup A: the cleanup is one undo step")
docCleanA53.undo()
checkEqual(docCleanA53.state.wires.count, 5,
           "5.3 cleanup A: one undo restores all 5 wires")

// B: collinear chains merge to a fixpoint (and an interior point
// of one wire counts as a merge too).
let wireM1_53 = wire53(fixedUUID("B53B53B5-3B53-4B53-8B53-B53B53B53B01"),
                       [dp53(0, 0), dp53(10, 0)])
let wireM4_53 = wire53(UUID(), [dp53(30, 0), dp53(40, 0), dp53(50, 0)])
let wireC1_53 = wire53(fixedUUID("B53B53B5-3B53-4B53-8B53-B53B53B53B02"),
                       [dp53(100, 0), dp53(110, 0)])
let docCleanB53 = makeDoc53(schState53(wires: [
    wireM1_53,
    wire53(UUID(), [dp53(10, 0), dp53(20, 0)]),
    wire53(UUID(), [dp53(20, 0), dp53(20, 10)]),
    wireM4_53,
    wire53(UUID(), [dp53(50, 0), dp53(50, 10)]),
    wireC1_53,
    wire53(UUID(), [dp53(110, 0), dp53(120, 0)]),
    wire53(UUID(), [dp53(120, 0), dp53(130, 0)]),
    wire53(UUID(), [dp53(130, 0), dp53(130, 10)]),
]))
checkEqual(docCleanB53.cleanUpSheet(), cleanupCounts53(merged: 4),
           "5.3 cleanup B: 4 merges (2 chains + 1 chain link + 1 interior point)")
checkEqual(docCleanB53.state.wires.count, 6,
           "5.3 cleanup B: 6 wires remain")
if let mergedM53 = docCleanB53.state.wires.first(where: { $0.id == wireM1_53.id }) {
    checkEqual(mergedM53.points, [dp53(0, 0), dp53(20, 0)],
               "5.3 cleanup B: the m-chain merged under m1's id to (0,0)-(20,0)")
} else {
    check(false, "5.3 cleanup B: the m-chain keeps m1's id")
}
if let mergedM4_53 = docCleanB53.state.wires.first(where: { $0.id == wireM4_53.id }) {
    checkEqual(mergedM4_53.points, [dp53(30, 0), dp53(50, 0)],
               "5.3 cleanup B: m4's interior point merged away")
} else {
    check(false, "5.3 cleanup B: m4 survives its interior merge")
}
if let mergedC53 = docCleanB53.state.wires.first(where: { $0.id == wireC1_53.id }) {
    checkEqual(mergedC53.points, [dp53(100, 0), dp53(130, 0)],
               "5.3 cleanup B: the c-chain merged under c1's id to (100,0)-(130,0)")
} else {
    check(false, "5.3 cleanup B: the c-chain keeps c1's id")
}
checkEqual(docCleanB53.cleanUpSheet(), cleanupCounts53(),
           "5.3 cleanup B: a second cleanup finds nothing to do")
docCleanB53.undo()
checkEqual(docCleanB53.state.wires.count, 9,
           "5.3 cleanup B: one undo reaches the original 9 wires (no extra step)")
check(!docCleanB53.canUndo, "5.3 cleanup B: the history is exhausted after one undo")

// C: junction dedupe/drop + the isolated-wire delta.
let wireIso1_53 = wire53(UUID(), [dp53(200, 200), dp53(210, 200)])
let wireIso2_53 = wire53(UUID(), [dp53(220, 200), dp53(230, 200)])
let wireIso3_53 = wire53(UUID(), [dp53(230, 200), dp53(240, 200)])
let junctionC53 = { JunctionItem(id: UUID(), at: dp53(10, 0)) }
let docCleanC53 = makeDoc53(schState53(
    wires: [
        wire53(UUID(), [dp53(0, 0), dp53(10, 0)]),
        wire53(UUID(), [dp53(10, 0), dp53(10, 10)]),
        wireIso1_53, wireIso2_53, wireIso3_53,
    ],
    junctions: [
        junctionC53(), junctionC53(),
        JunctionItem(id: UUID(), at: dp53(0, 0)),
        JunctionItem(id: UUID(), at: dp53(99, 99)),
    ],
    noConnects: [
        NoConnectItem(id: UUID(), at: dp53(50, 50)),
        NoConnectItem(id: UUID(), at: dp53(50, 50)),
    ]))
checkEqual(docCleanC53.cleanUpSheet(),
           cleanupCounts53(merged: 1, dupJ: 1, dropped: 2, isolated: 2),
           "5.3 cleanup C: 1 duplicate junction, 2 dropped junctions, the collinear floating pair merges and is then isolated-removed with the lone wire")
checkEqual(docCleanC53.state.junctions.count, 1,
           "5.3 cleanup C: one junction remains")
check(docCleanC53.state.junctions.first?.at == dp53(10, 0),
      "5.3 cleanup C: the surviving junction is the (10, 0) one")
checkEqual(docCleanC53.state.noConnects.count, 1,
           "5.3 cleanup C: duplicate no-connect flags dedupe to one")
let remainingC53 = Set(docCleanC53.state.wires.map(\.id))
check(docCleanC53.state.wires.count == 2
      && !remainingC53.contains(wireIso1_53.id)
      && !remainingC53.contains(wireIso2_53.id)
      && !remainingC53.contains(wireIso3_53.id),
      "5.3 cleanup C: all three floating wires are gone (the pair merged, then isolated-removed); only the junction-connected pair remains")
docCleanC53.undo()
check(docCleanC53.state.wires.count == 5
      && docCleanC53.state.junctions.count == 4
      && docCleanC53.state.noConnects.count == 2,
      "5.3 cleanup C: one undo restores 5 wires / 4 junctions / 2 no-connects")

// D: a pin point anchors a wire against the isolated rule.
let docCleanD1_53 = makeDoc53(schState53(wires: [
    wire53(UUID(), [dp53(0, 0), dp53(10, 0)]),
]))
checkEqual(docCleanD1_53.cleanUpSheet(pinPoints: [dp53(0, 0)]),
           cleanupCounts53(),
           "5.3 cleanup D: a wire ending on a pin point is not isolated")
checkEqual(docCleanD1_53.state.wires.count, 1,
           "5.3 cleanup D: the pin-anchored wire survives")
let docCleanD2_53 = makeDoc53(schState53(wires: [
    wire53(UUID(), [dp53(0, 0), dp53(10, 0)]),
]))
checkEqual(docCleanD2_53.cleanUpSheet(pinPoints: []),
           cleanupCounts53(isolated: 1),
           "5.3 cleanup D: the same wire with no pin points is isolated")
checkEqual(docCleanD2_53.state.wires.count, 0,
           "5.3 cleanup D: the isolated wire is gone")

// E: the pin anchor saves its own wire only.
let wireE1_53 = wire53(UUID(), [dp53(0, 0), dp53(10, 0)])
let wireE2_53 = wire53(UUID(), [dp53(50, 50), dp53(60, 50)])
let docCleanE53 = makeDoc53(schState53(wires: [wireE1_53, wireE2_53]))
checkEqual(docCleanE53.cleanUpSheet(pinPoints: [dp53(0, 0)]),
           cleanupCounts53(isolated: 1),
           "5.3 cleanup E: exactly the unanchored wire is isolated")
checkEqual(docCleanE53.state.wires.map(\.id), [wireE1_53.id],
           "5.3 cleanup E: the pin-anchored wire survives, the other is removed")


// -- S4: no-connect flags --

let docNC53 = makeDoc53(schState53())
let pointNC53 = dp53(12, 34)
docNC53.addNoConnect(at: pointNC53)
docNC53.addNoConnect(at: pointNC53)
checkEqual(docNC53.state.noConnects.count, 1,
           "5.3 no-connect: a second flag at the same point is not placed")
check(docNC53.canUndo, "5.3 no-connect: one flag is one undo step")
docNC53.undo()
check(docNC53.state.noConnects.count == 0 && !docNC53.canUndo,
      "5.3 no-connect: one undo removes the flag and empties the history")
docNC53.addNoConnect(at: pointNC53)
let ncFlagID53 = docNC53.state.noConnects[0].id
docNC53.removeNoConnect(id: ncFlagID53)
checkEqual(docNC53.state.noConnects.count, 0,
           "5.3 no-connect: removeNoConnect removes the flag")
docNC53.undo()
checkEqual(docNC53.state.noConnects.count, 1,
           "5.3 no-connect: undo restores the removed flag")

// Builder + ERC: flagging U1 pin 1 drops its net from the table
// (R1 pin 2 is left alone on a stub) and exempts the pin in ERC.
let uNC53 = ercPlaced52("U1", "IC", 0, 0)
let rNC53 = ercPlaced52("R1", "R", 30, 0)
// The second wire jogs below the first: drawn straight it would lie
// on the same horizontal line and swallow the first wire's endpoints
// (endpoint-on-segment unions them into one net — correct builder
// behaviour, wrong scenario). The jog keeps the two nets disjoint.
let ncPinA53 = pinPoint52(uNC53, "1")
let ncPinB53 = pinPoint52(rNC53, "2")
let stateNC53 = SchematicState(
    symbols: [uNC53, rNC53],
    wires: [
        wire53(UUID(), [pinPoint52(uNC53, "2"), pinPoint52(rNC53, "1")]),
        wire53(UUID(), [ncPinA53, dp53(ncPinA53.x, -15),
                        dp53(ncPinB53.x, -15), ncPinB53]),
    ],
    junctions: [], labels: [], title: "NC53")
let docFlag53 = makeDoc53(stateNC53)
docFlag53.addNoConnect(at: pinPoint52(uNC53, "1"))
let table53 = ConnectionTableBuilder.build(
    state: docFlag53.state,
    sourceFileName: "nc53.json",
    resolveSymbol: { placed in ercDefs52[placed.symbolName] },
    resolveFootprint: { _, _ in (nil, nil) })
checkEqual(table53.nets.count, 1,
           "5.3 no-connect: flagging U1 pin 1 leaves exactly one written net")
checkEqual(Set(table53.nets.flatMap(\.endpoints).map {
               "\($0.reference)|\($0.pinNumber)"
           }), Set(["U1|2", "R1|1"]),
           "5.3 no-connect: the surviving net's endpoints are U1|2 and R1|1")
checkEqual(table53.flaggedNoConnectPinKeySet,
           Set(["\(uNC53.id.uuidString)|1"]),
           "5.3 no-connect: the table records the flagged pin key")
let ercFlag53 = SchematicERC.check(state: docFlag53.state) {
    ercDefs52[$0.symbolName]
}
checkEqual(ercFlag53.count, 2,
           "5.3 no-connect ERC: exactly two findings remain")
check(ercFlag53.allSatisfy { $0.kind == .pinNotConnected },
      "5.3 no-connect ERC: both findings are pin-not-connected")
check(ercFlag53.contains { $0.message.contains("U1 pin 3") }
      && ercFlag53.contains { $0.message.contains("R1 pin 2") },
      "5.3 no-connect ERC: the findings name U1 pin 3 and R1 pin 2")
check(!ercFlag53.contains { $0.message.contains("U1 pin 1") },
      "5.3 no-connect ERC: the flagged U1 pin 1 is exempt")
let ercBase53 = SchematicERC.check(state: stateNC53) {
    ercDefs52[$0.symbolName]
}
let baseNotConnected53 = ercBase53.filter { $0.kind == .pinNotConnected }
checkEqual(baseNotConnected53.count, 1,
           "5.3 no-connect ERC baseline: without the flag only one pin is unconnected")
check(baseNotConnected53.first?.message.contains("U1 pin 3") == true,
      "5.3 no-connect ERC baseline: the baseline finding is U1 pin 3")

// -- S5: change / update symbol in place --

func def53(_ name: String, library: String, unitCount: Int,
           value: String? = nil) -> KiCadSymbolDef {
    var units53: [Int: KiCadUnitDef] = [:]
    for unit53 in 1...unitCount {
        units53[unit53] = KiCadUnitDef(graphics: [], pins: [])
    }
    var properties53: [KiCadProperty] = []
    if let value {
        properties53.append(KiCadProperty(
            name: "Value", value: value, id: 0, x: 0, y: 0,
            rotation: 0, hidden: false, fontSize: 1.27))
    }
    return KiCadSymbolDef(
        name: name, library: library, properties: properties53,
        units: units53, unitCount: unitCount, extendsName: nil,
        pinNameOffset: 0.508, pinNamesHidden: false,
        pinNumbersHidden: false, isPowerSymbol: false)
}

func placedP53(library: String = "FixtureSym",
               name: String = "FIXIC") -> PlacedSymbol {
    PlacedSymbol(
        id: fixedUUID("E53E53E5-3E53-4E53-8E53-E53E53E53E53"),
        library: library, symbolName: name, unit: 2,
        x: 10, y: 20, rotation: 90, mirrorX: true, mirrorY: false,
        reference: "U7", value: "custom",
        footprintChoice: "FixtureFP:FIXIC_FP", bodyStyle: 2)
}

// A two-unit, no-alternate-body definition: unit is kept, the
// De Morgan body style resets, everything else is preserved.
let placedS5a53 = placedP53()
let docS5a53 = makeDoc53(schState53(symbols: [placedS5a53]))
check(docS5a53.changeSymbol(id: placedS5a53.id, toLibrary: "Lib2",
                             name: "TWO",
                             definition: def53("TWO", library: "Lib2",
                                               unitCount: 2)),
      "5.3 change symbol: the swap to a two-unit symbol reports a change")
let swappedS5a53 = docS5a53.state.symbols[0]
check(swappedS5a53.library == "Lib2" && swappedS5a53.symbolName == "TWO",
      "5.3 change symbol: library and name are swapped")
check(swappedS5a53.unit == 2 && swappedS5a53.bodyStyle == nil,
      "5.3 change symbol: unit 2 survives; body style resets (no alternate body)")
check(swappedS5a53.reference == "U7" && swappedS5a53.value == "custom"
      && swappedS5a53.footprintChoice == "FixtureFP:FIXIC_FP"
      && swappedS5a53.x == 10 && swappedS5a53.y == 20
      && swappedS5a53.rotation == 90 && swappedS5a53.mirrorX,
      "5.3 change symbol: reference/value/footprint/position/rotation/mirror are preserved")
docS5a53.undo()
check(docS5a53.state.symbols[0] == placedS5a53 && !docS5a53.canUndo,
      "5.3 change symbol: one undo restores the original instance")

// A one-unit definition pulls the unit back to 1; repeating the
// identical change is a no-op with no extra history step.
let placedS5b53 = placedP53(library: "Lib2", name: "TWO")
let docS5b53 = makeDoc53(schState53(symbols: [placedS5b53]))
check(docS5b53.changeSymbol(id: placedS5b53.id, toLibrary: "Lib2",
                             name: "ONE",
                             definition: def53("ONE", library: "Lib2",
                                               unitCount: 1)),
      "5.3 change symbol: the swap to a one-unit symbol reports a change")
checkEqual(docS5b53.state.symbols[0].unit, 1,
           "5.3 change symbol: a unit the new symbol lacks resets to 1")
check(!docS5b53.changeSymbol(id: placedS5b53.id, toLibrary: "Lib2",
                              name: "ONE",
                              definition: def53("ONE", library: "Lib2",
                                                unitCount: 1)),
      "5.3 change symbol: repeating the identical change reports no change")
docS5b53.undo()
check(docS5b53.state.symbols[0] == placedS5b53 && !docS5b53.canUndo,
      "5.3 change symbol: a single undo still reaches the pre-change state")

// An unresolved definition (nil) swaps only the key: unit and
// body style are kept unvalidated.
let placedS5c53 = placedP53()
let docS5c53 = makeDoc53(schState53(symbols: [placedS5c53]))
check(docS5c53.changeSymbol(id: placedS5c53.id, toLibrary: "Lib3",
                             name: "NILDEF", definition: nil),
      "5.3 change symbol: a nil definition still swaps the key")
let swappedS5c53 = docS5c53.state.symbols[0]
check(swappedS5c53.library == "Lib3" && swappedS5c53.symbolName == "NILDEF"
      && swappedS5c53.unit == 2 && swappedS5c53.bodyStyle == 2,
      "5.3 change symbol: with no definition, unit 2 and body style 2 are kept")

// Update from library: value resets to the definition's Value
// property, the footprint choice clears, the rest is preserved.
let placedS5d53 = placedP53()
let docS5d53 = makeDoc53(schState53(symbols: [placedS5d53]))
check(docS5d53.updateSymbolFromLibrary(
        id: placedS5d53.id,
        definition: def53("FIXIC", library: "FixtureSym", unitCount: 1,
                          value: "NEWD")),
      "5.3 update symbol: the refresh reports a change")
let updatedS5d53 = docS5d53.state.symbols[0]
check(updatedS5d53.value == "NEWD" && updatedS5d53.footprintChoice == nil,
      "5.3 update symbol: value becomes the library Value, footprint choice clears")
check(updatedS5d53.reference == "U7" && updatedS5d53.x == 10
      && updatedS5d53.y == 20 && updatedS5d53.unit == 2,
      "5.3 update symbol: reference, position and unit are preserved")
check(!docS5d53.updateSymbolFromLibrary(
        id: placedS5d53.id,
        definition: def53("FIXIC", library: "FixtureSym", unitCount: 1,
                          value: "NEWD")),
      "5.3 update symbol: refreshing again reports no change")
docS5d53.undo()
check(docS5d53.state.symbols[0] == placedS5d53 && !docS5d53.canUndo,
      "5.3 update symbol: one undo restores the instance (no extra step)")

// -- S6: symbol fields table --

func placedFields53(_ id: UUID, _ reference: String, _ unit: Int,
                    _ value: String, _ choice: String?) -> PlacedSymbol {
    PlacedSymbol(id: id, library: "Fixture", symbolName: "R", unit: unit,
                 x: 0, y: 0, rotation: 0, mirrorX: false, mirrorY: false,
                 reference: reference, value: value,
                 footprintChoice: choice)
}
let fieldsB53 = placedFields53(
    fixedUUID("B53B53B5-3B53-4B53-8B53-B53B53B53B53"), "R2", 1, "1k", nil)
let fieldsA53 = placedFields53(
    fixedUUID("A53A53A5-3A53-4A53-8A53-A53A53A53A53"), "R1", 2, "10k", "X:Y")
let fieldsC53 = placedFields53(
    fixedUUID("C53C53C5-3C53-4C53-8C53-C53C53C53C53"), "R1", 1, "10k", nil)
let docFields53 = makeDoc53(schState53(
    symbols: [fieldsB53, fieldsA53, fieldsC53]))
let fieldRows53 = docFields53.fieldRows()
checkEqual(fieldRows53.map(\.instanceID),
           [fieldsC53.id, fieldsA53.id, fieldsB53.id],
           "5.3 fields: rows sort by reference then unit (R1u1, R1u2, R2u1)")
checkEqual(fieldRows53.first { $0.instanceID == fieldsA53.id }?.footprint ?? "<none>",
           "X:Y", "5.3 fields: A's row shows its footprint choice")
checkEqual(fieldRows53.first { $0.instanceID == fieldsB53.id }?.footprint ?? "<none>",
           "", "5.3 fields: B's row shows an empty footprint (automatic resolution)")
let edits53: [UUID: FieldEdit] = [
    fieldsA53.id: FieldEdit(value: "22k", footprint: ""),
    fieldsB53.id: FieldEdit(value: "1k", footprint: ""),
]
checkEqual(docFields53.applyFieldEdits(edits53), 1,
           "5.3 fields: only A actually changes (B's edit is already its state)")
let editedA53 = docFields53.state.symbols.first { $0.id == fieldsA53.id }
check(editedA53?.value == "22k" && editedA53?.footprintChoice == nil,
      "5.3 fields: A's value is 22k and its footprint choice cleared")
checkEqual(docFields53.applyFieldEdits(edits53), 0,
           "5.3 fields: re-applying the same edits changes nothing")
checkEqual(docFields53.applyFieldEdits(
            [UUID(): FieldEdit(value: "x", footprint: "y")]), 0,
           "5.3 fields: edits for an unknown id change nothing")
docFields53.undo()
let restoredA53 = docFields53.state.symbols.first { $0.id == fieldsA53.id }
check(restoredA53?.value == "10k" && restoredA53?.footprintChoice == "X:Y"
      && !docFields53.canUndo,
      "5.3 fields: one undo restores A (the no-op reapplies recorded no step)")

// -- S7: annotation options --

let docAnnX53 = makeDoc53(schState53(symbols: [
    ercPlaced52("R?", "R", 10, 30), ercPlaced52("R?", "R", 0, 0),
    ercPlaced52("R?", "R", 10, 10),
]))
checkEqual(docAnnX53.annotateReferences(
            options: AnnotateOptions(sortOrder: .byX)), 3,
           "5.3 annotate byX: all three parts are assigned")
checkEqual(docAnnX53.state.symbols.map(\.reference), ["R2", "R1", "R3"],
           "5.3 annotate byX: x-major order numbers (0,0), (10,30), (10,10)")

let docAnnSheet53 = makeDoc53(schState53(symbols: [
    ercPlaced52("R?", "R", 10, 30), ercPlaced52("R?", "R", 0, 0),
    ercPlaced52("R?", "R", 10, 10),
]))
_ = docAnnSheet53.annotateReferences(options: AnnotateOptions(sortOrder: .sheetOrder))
checkEqual(docAnnSheet53.state.symbols.map(\.reference), ["R1", "R3", "R2"],
           "5.3 annotate sheetOrder: y-major order numbers (10,30), (10,10), (0,0)")

let docAnnY53 = makeDoc53(schState53(symbols: [
    ercPlaced52("R?", "R", 10, 30), ercPlaced52("R?", "R", 0, 0),
    ercPlaced52("R?", "R", 10, 10),
]))
_ = docAnnY53.annotateReferences(options: AnnotateOptions(sortOrder: .byY))
checkEqual(docAnnY53.state.symbols.map(\.reference), ["R1", "R3", "R2"],
           "5.3 annotate byY: same result as sheet order on this sheet")

let docAnnReset53 = makeDoc53(schState53(symbols: [
    ercPlaced52("R5", "R", 0, 10), ercPlaced52("R9", "R", 0, 0),
]))
checkEqual(docAnnReset53.annotateReferences(
            options: AnnotateOptions(resetAll: true, startNumber: 3)), 2,
           "5.3 annotate resetAll: both parts are renumbered")
checkEqual(docAnnReset53.state.symbols.map(\.reference), ["R3", "R4"],
           "5.3 annotate resetAll: numbering starts at 3 in sort order")
docAnnReset53.undo()
checkEqual(docAnnReset53.state.symbols.map(\.reference), ["R5", "R9"],
           "5.3 annotate resetAll: one undo restores R5 and R9")

let docAnnKeep53 = makeDoc53(schState53(symbols: [
    ercPlaced52("R1", "R", 0, 20), ercPlaced52("R?", "R", 0, 10),
]))
checkEqual(docAnnKeep53.annotateReferences(
            options: AnnotateOptions(startNumber: 5)), 1,
           "5.3 annotate keep+start: only the unannotated part is assigned")
checkEqual(docAnnKeep53.state.symbols.map(\.reference), ["R1", "R5"],
           "5.3 annotate keep+start: R1 keeps its number, R? becomes R5")

let docAnnNoop53 = makeDoc53(schState53(symbols: [
    ercPlaced52("R3", "R", 0, 0),
]))
checkEqual(docAnnNoop53.annotateReferences(
            options: AnnotateOptions(resetAll: true, startNumber: 3)), 0,
           "5.3 annotate resetAll: an already-sequential sheet is a no-op")
check(!docAnnNoop53.canUndo
      && docAnnNoop53.state.symbols[0].reference == "R3",
      "5.3 annotate resetAll no-op: no history step, reference untouched")

let docAnnDefault53 = makeDoc53(schState53(symbols: [
    ercPlaced52("R?", "R", 0, 0),
]))
_ = docAnnDefault53.annotateReferences()
checkEqual(docAnnDefault53.state.symbols[0].reference, "R1",
           "5.3 annotate default: a lone R? becomes R1")

// -- S2: find inside the schematic --

var r1Find53 = r1
r1Find53.footprintChoice = "FixtureFP:FIXR_FP"
let labelFind53 = state.labels[0]
let docFind53 = makeDoc53(SchematicState(
    symbols: [u1Unit1, r1Find53, x1], wires: [], junctions: [],
    labels: [labelFind53], title: "Find53"))
let matchesRef53 = docFind53.findMatches(query: "r1")
checkEqual(matchesRef53.count, 1, "5.3 find: 'r1' has exactly one match")
if let match = matchesRef53.first {
    check(match.field == .reference && match.text == "R1"
          && match.symbolID == r1Find53.id,
          "5.3 find: 'r1' matches R1's reference field")
} else {
    check(false, "5.3 find: 'r1' has a first match to inspect")
}
let matchesFIX53 = docFind53.findMatches(query: "FIX")
checkEqual(matchesFIX53.count, 4,
           "5.3 find: 'FIX' has exactly four matches (got \(matchesFIX53.map { "\($0.field.rawValue):\($0.text)" }))")
if matchesFIX53.count == 4 {
    check(matchesFIX53[0].field == .value
          && matchesFIX53[0].text == "FIXIC"
          && matchesFIX53[0].symbolID == u1Unit1.id
          && matchesFIX53[1].field == .symbolName
          && matchesFIX53[1].symbolID == u1Unit1.id
          && matchesFIX53[2].field == .symbolName
          && matchesFIX53[2].symbolID == r1Find53.id
          && matchesFIX53[3].field == .footprint
          && matchesFIX53[3].text == "FixtureFP:FIXR_FP"
          && matchesFIX53[3].symbolID == r1Find53.id,
          "5.3 find: 'FIX' matches per field — U1's value and symbol name, R1's symbol name, and R1's footprint choice (\"FIX\" is a substring of \"FIXR_FP\"), in document order")
} else {
    check(false, "5.3 find: 'FIX' matches are U1's value + name, R1's name and R1's footprint")
}
let matchesValue53 = docFind53.findMatches(query: "10k")
check(matchesValue53.count == 1 && matchesValue53.first?.field == .value
      && matchesValue53.first?.symbolID == r1Find53.id,
      "5.3 find: '10k' matches R1's value only")
let matchesFP53 = docFind53.findMatches(query: "FIXR_FP")
check(matchesFP53.count == 1 && matchesFP53.first?.field == .footprint
      && matchesFP53.first?.text == "FixtureFP:FIXR_FP",
      "5.3 find: 'FIXR_FP' matches R1's footprint choice, with the full choice as text")
let matchesLabel53 = docFind53.findMatches(query: "net_a")
check(matchesLabel53.count == 1 && matchesLabel53.first?.field == .label
      && matchesLabel53.first?.labelID == labelFind53.id
      && matchesLabel53.first?.symbolID == nil
      && matchesLabel53.first?.reference == "NET_A",
      "5.3 find: 'net_a' matches the NET_A label (label id, no symbol)")
check(docFind53.findMatches(query: "").isEmpty,
      "5.3 find: an empty query matches nothing")
check(docFind53.findMatches(query: "zzz").isEmpty,
      "5.3 find: 'zzz' matches nothing")

// -- S11: wire-set deletion --

let docDelete53 = makeDoc53(state)
checkEqual(docDelete53.deleteWires([wireB.id, wireVCC.id]), 2,
           "5.3 delete wires: the two named wires are removed in one step")
checkEqual(docDelete53.state.wires.map(\.id), [wireA.id],
           "5.3 delete wires: only wireA remains")
docDelete53.undo()
checkEqual(docDelete53.state.wires.count, 3,
           "5.3 delete wires: one undo restores all three wires")
let docDeleteFresh53 = makeDoc53(state)
checkEqual(docDeleteFresh53.deleteWires([UUID()]), 0,
           "5.3 delete wires: an unknown id removes nothing")
check(!docDeleteFresh53.canUndo,
      "5.3 delete wires: a no-match deletion records no history")

// -- S12: align symbol to grid --

let symAlign53 = PlacedSymbol(
    id: fixedUUID("D53D53D5-3D53-4D53-8D53-D53D53D53D01"),
    library: "Fixture", symbolName: "SYM", unit: 1,
    x: 26.0, y: 25.4, rotation: 0, mirrorX: false, mirrorY: false,
    reference: "U9", value: "SYM")
let pinPointsAlign53 = [dp53(20.92, 25.4), dp53(31.08, 25.4)]
let wireAlign1_53 = wire53(UUID(), [dp53(20.92, 25.4), dp53(20.92, 15.0)])
let wireAlign2_53 = wire53(UUID(), [dp53(31.0805, 25.4), dp53(40, 25.4)])
let wireAlign3_53 = wire53(UUID(), [dp53(31.09, 25.4), dp53(40, 30)])
let docAlign53 = makeDoc53(schState53(
    symbols: [symAlign53],
    wires: [wireAlign1_53, wireAlign2_53, wireAlign3_53],
    junctions: [JunctionItem(id: UUID(), at: dp53(31.08, 25.4))]))
check(docAlign53.alignSymbolToGrid(id: symAlign53.id,
                                   pinPoints: pinPointsAlign53),
      "5.3 align: the off-grid symbol aligns")
check(approx(docAlign53.state.symbols[0].x, 25.4)
      && approx(docAlign53.state.symbols[0].y, 25.4),
      "5.3 align: the origin lands on (25.4, 25.4)")
let alignedWire1_53 = docAlign53.state.wires[0].points[0]
check(approx(alignedWire1_53.x, 20.32) && approx(alignedWire1_53.y, 25.4),
      "5.3 align: the wire point on pin 1 follows to (20.32, 25.4)")
let alignedJunction53 = docAlign53.state.junctions[0].at
check(approx(alignedJunction53.x, 30.48) && approx(alignedJunction53.y, 25.4),
      "5.3 align: the junction on pin 2 follows to (30.48, 25.4)")
let alignedWire2_53 = docAlign53.state.wires[1].points[0]
check(approx(alignedWire2_53.x, 30.4805) && approx(alignedWire2_53.y, 25.4),
      "5.3 align: a wire point within 0.001 mm of pin 2 follows to (30.4805, 25.4)")
checkEqual(docAlign53.state.wires[2].points, wireAlign3_53.points,
           "5.3 align: a wire point 0.01 mm off the pin does not move")
docAlign53.undo()
check(approx(docAlign53.state.symbols[0].x, 26.0)
      && approx(docAlign53.state.wires[0].points[0].x, 20.92)
      && approx(docAlign53.state.junctions[0].at.x, 31.08),
      "5.3 align: one undo restores the symbol, wire and junction")
var symAligned53 = symAlign53
symAligned53.x = 25.4
let docAlignDone53 = makeDoc53(schState53(symbols: [symAligned53]))
check(!docAlignDone53.alignSymbolToGrid(id: symAligned53.id,
                                        pinPoints: pinPointsAlign53)
      && !docAlignDone53.canUndo,
      "5.3 align: an on-grid symbol reports no change and records no history")
let docAlignUnknown53 = makeDoc53(schState53(symbols: [symAlign53]))
check(!docAlignUnknown53.alignSymbolToGrid(id: UUID(),
                                           pinPoints: pinPointsAlign53),
      "5.3 align: an unknown symbol id reports no change")

// -- P7 (schematic side): ERC finding keys + exclusion split --

func ercFinding53(_ kind: ERCFinding.Kind) -> ERCFinding? {
    ercFindings52.first { $0.kind == kind }
}
checkEqual(ercFinding53(.pinNotConnected)?.key ?? "",
           "pinNotConnected|U1|1",
           "5.3 ERC key: pin-not-connected keys on kind|reference|pin")
checkEqual(ercFinding53(.duplicateReference)?.key ?? "",
           "duplicateReference|X1|unit 1",
           "5.3 ERC key: duplicate-reference keys on kind|reference|unit")
checkEqual(ercFinding53(.unannotated)?.key ?? "",
           "unannotated|Q?|R",
           "5.3 ERC key: unannotated keys on kind|reference|symbol name")
checkEqual(ercFinding53(.labelNotConnected)?.key ?? "",
           "labelNotConnected||FLOAT",
           "5.3 ERC key: label findings key on kind||label text")
checkEqual(ercFinding53(.powerPinNotDriven)?.key ?? "",
           "powerPinNotDriven|Net-3|U1 pin 3, U2 pin 3",
           "5.3 ERC key: power findings key on kind|net|pin list")
checkEqual(ercFinding53(.outputConflict)?.key ?? "",
           "outputConflict|Net-2|U1 pin 2, U2 pin 2",
           "5.3 ERC key: output conflicts key on kind|net|pin list")
let ercSplit53 = SchematicERC.visibleFindings(
    ercFindings52,
    excluding: ["pinNotConnected|U1|1", "labelNotConnected||FLOAT"])
checkEqual(ercSplit53.visible.count, 4,
           "5.3 ERC exclusions: two excluded keys leave four visible findings")
checkEqual(ercSplit53.excluded.count, 2,
           "5.3 ERC exclusions: exactly the two keyed findings are excluded")
checkEqual(ercSplit53.excluded.map(\.kind), [.pinNotConnected, .labelNotConnected],
           "5.3 ERC exclusions: excluded kinds keep finding order")
let ercSplitNone53 = SchematicERC.visibleFindings(ercFindings52, excluding: [])
check(ercSplitNone53.visible.count == 6 && ercSplitNone53.excluded.isEmpty,
      "5.3 ERC exclusions: excluding nothing shows all six findings")
var stateERCEx53 = ercState52
stateERCEx53.ercExclusions = ["pinNotConnected|U1|1", "labelNotConnected||FLOAT"]
let docERCEx53 = makeDoc53(stateERCEx53)
let ercSplitDoc53 = SchematicERC.visibleFindings(
    ercFindings52, excluding: Set(docERCEx53.state.ercExclusions))
check(ercSplitDoc53.visible.count == 4 && ercSplitDoc53.excluded.count == 2
      && ercSplitDoc53.excluded.map(\.kind) == [.pinNotConnected, .labelNotConnected],
      "5.3 ERC exclusions: the same split driven from a document's stored exclusions")

// -- S8: placed-symbol lookup (cross-probe support) --

let docLookup53 = makeDoc53(state)
check(docLookup53.placedSymbol(reference: "R1")?.id == r1.id,
      "5.3 lookup: R1 resolves to the fixture R1 instance")
check(docLookup53.placedSymbol(reference: "U1")?.id == u1Unit1.id,
      "5.3 lookup: U1 resolves to its first-placed instance (unit 1)")
check(docLookup53.placedSymbol(reference: "ZZZ") == nil,
      "5.3 lookup: an absent reference resolves to nil")


// -- PCB half: persistence of the 5.3 board-state fields --

var statePersist53 = BoardState()
statePersist53.teardrops = [TeardropItem(
    id: fixedUUID("00000000-0000-4000-8000-00000000053A"),
    netName: "NET_A", layer: "F.Cu",
    points: [fp53(0, 0), fp53(2, 0), fp53(2, 2), fp53(0, 2)],
    anchorTrackID: fixedUUID("99999999-9999-4999-8999-999999999999").uuidString,
    anchorPoint: fp53(0, 0))]
statePersist53.netClasses = [NetClass(name: "Power", trackWidthMM: 0.5,
                                      clearanceMM: 0.4)]
statePersist53.netClassByNet = ["VCC": "Power"]
statePersist53.manufacturingExclusions = ["minTraceWidth|X"]
statePersist53.manufacturingExclusionNotes = ["minTraceWidth|X": "fab ok"]
statePersist53.ratsnestHiddenNets = ["NET_B"]
do {
    try BoardStateStore.save(statePersist53, tableStem: "fixture53",
                             in: stateDir)
    let loadedPersist53 = BoardStateStore.load(tableStem: "fixture53",
                                               in: stateDir)
    checkEqual(loadedPersist53, statePersist53,
               "5.3 persistence: teardrops/netclasses/exclusions/ratsnest-hides round-trip losslessly")
} catch {
    check(false, "5.3 persistence: the store round-trip threw \(error)")
}
// A pre-5.3 board file (the 5.2-era literal: no 5.3 keys at all)
// decodes with every 5.3 collection empty.
let oldBoardState53 = try! JSONDecoder().decode(
    BoardState.self, from: Data(preLockJSON52.utf8))
check(oldBoardState53.teardrops.isEmpty && oldBoardState53.netClasses.isEmpty,
      "5.3 persistence: a pre-5.3 board file has no teardrops or netclasses")
check(oldBoardState53.netClassByNet.isEmpty
      && oldBoardState53.manufacturingExclusionNotes.isEmpty,
      "5.3 persistence: a pre-5.3 board file has empty netclass/exclusion-note maps")
check(oldBoardState53.manufacturingExclusions.isEmpty
      && oldBoardState53.ratsnestHiddenNets.isEmpty,
      "5.3 persistence: a pre-5.3 board file has no exclusions or hidden ratsnest nets")

// -- P8: per-net ratsnest hiding --

let m53 = PCBBoardMerger.apply(state: BoardState(), to: board,
                               isSync: false).model
let ratsOpen53 = BoardRatsnest.segments(model: m53, copperCount: 4)
let ratsHidden53 = BoardRatsnest.segments(model: m53, copperCount: 4,
                                          hiddenNets: ["NET_A"])
check(ratsOpen53.filter { $0.netName == "NET_A" }.count >= 1,
      "5.3 ratsnest: the open ratsnest has at least one NET_A segment")
check(!ratsHidden53.contains { $0.netName == "NET_A" },
      "5.3 ratsnest: hiding NET_A removes every NET_A segment")
checkEqual(ratsHidden53, ratsOpen53.filter { $0.netName != "NET_A" },
           "5.3 ratsnest: every other net's segments are identical")

// -- P16: netclasses --

var stateClass53 = BoardState()
stateClass53.upsertNetClass(NetClass(name: "Power", trackWidthMM: 0.5,
                                     clearanceMM: 0.4))
stateClass53.assignNetClass(net: "VCC", className: "Power")
checkEqual(stateClass53.netClassByNet["VCC"] ?? "", "Power",
           "5.3 netclass: VCC is assigned to Power")
check(approx(BoardNetClasses.requiredClearanceMM(
                netA: "VCC", netB: "NET_A", boardState: stateClass53), 0.4),
      "5.3 netclass: a VCC pair requires the class's 0.4 mm (the board's 8 mil loses)")
check(approx(BoardNetClasses.requiredClearanceMM(
                netA: "NET_A", netB: "NET_B", boardState: stateClass53), 0.2032),
      "5.3 netclass: a classless pair requires just the board's 8 mil (0.2032 mm)")
check(approx(BoardNetClasses.defaultTrackWidthMM(
                forNet: "VCC", boardState: stateClass53) ?? -1, 0.5),
      "5.3 netclass: VCC's default track width is the class's 0.5 mm")
check(BoardNetClasses.defaultTrackWidthMM(
        forNet: "NET_A", boardState: stateClass53) == nil,
      "5.3 netclass: NET_A has no class, so no class track width")
stateClass53.assignNetClass(net: "VCC", className: "Nope")
checkEqual(stateClass53.netClassByNet["VCC"] ?? "", "Power",
           "5.3 netclass: assigning an unknown class is ignored")
stateClass53.assignNetClass(net: "VCC", className: nil)
check(stateClass53.netClassByNet["VCC"] == nil,
      "5.3 netclass: assigning nil unassigns the net")
stateClass53.assignNetClass(net: "VCC", className: "Power")
stateClass53.deleteNetClass(named: "Power")
check(stateClass53.netClasses.isEmpty && stateClass53.netClassByNet.isEmpty,
      "5.3 netclass: deleting a class removes it and unassigns its nets")

// Clearance routing: the tier-1 check honours per-pair class
// requirements, on the part-5 close-traces board.
func hasTracePair53(_ violations: [ClearanceViolation]) -> Bool {
    violations.contains {
        $0.itemA.contains("trace") && $0.itemB.contains("trace")
            && Set([$0.netA, $0.netB]) == Set(["NET_A", "VCC"])
    }
}
var stateClearClass53 = BoardState()
stateClearClass53.clearanceMil = 8
stateClearClass53.upsertNetClass(NetClass(name: "Power", trackWidthMM: 0.5,
                                          clearanceMM: 0.5))
stateClearClass53.assignNetClass(net: "VCC", className: "Power")
check(hasTracePair53(BoardClearance.violations(
        model: mergedClear, copperCount: 4, boardState: stateClearClass53)),
      "5.3 clearance: board 8 mil + a VCC class reports the 0.05 mm pair")
check(hasTracePair53(BoardClearance.violations(
        model: mergedClear, copperCount: 4, clearanceMM: 0.2032)),
      "5.3 clearance: the flat 0.2032 mm call reports the pair too")
check(!hasTracePair53(BoardClearance.violations(
        model: mergedClear, copperCount: 4,
        boardState: BoardState(clearanceMil: 1))),
      "5.3 clearance: at a flat 1 mil board setting the pair is legal")
var stateClearClass1Mil53 = BoardState(clearanceMil: 1)
stateClearClass1Mil53.upsertNetClass(NetClass(name: "Power",
                                              trackWidthMM: 0.5,
                                              clearanceMM: 0.4))
stateClearClass1Mil53.assignNetClass(net: "VCC", className: "Power")
check(hasTracePair53(BoardClearance.violations(
        model: mergedClear, copperCount: 4, boardState: stateClearClass1Mil53)),
      "5.3 clearance: a VCC class of 0.4 mm flags the pair even at 1 mil board setting")

// -- P7 (PCB side): manufacturing finding keys + exclusions --

let traceThin53ID = fixedUUID("00000000-0000-4000-8000-00000000053B")
var stateThin53 = BoardState()
stateThin53.knownReferences = ["R1", "U1", "X1"]
stateThin53.traces = [trace53(traceThin53ID, "NET_A", "F.Cu", 0.1,
                              [fp53(0, 100), fp53(20, 100)])]
let modelThin53 = PCBBoardMerger.apply(state: stateThin53, to: board,
                                       isSync: false).model
let connThin53 = BoardConnectivity.analyze(model: modelThin53, copperCount: 4)
let reportThin53 = BoardManufacturing.check(
    model: modelThin53, copperCount: 4, settings: ManufacturingSettings(),
    connectivity: connThin53, boardState: BoardState())
let findingThin53 = reportThin53.findings.first { $0.ruleID == "minTraceWidth" }
check(findingThin53 != nil,
      "5.3 manufacturing: the 0.1 mm trace produces a minTraceWidth finding")
checkEqual(findingThin53?.key ?? "",
           "minTraceWidth|\(traceThin53ID.uuidString)|NET_A",
           "5.3 manufacturing: the finding key is rule|item id|net")
checkEqual(reportThin53.findings.count,
           reportThin53.rules.reduce(0) { $0 + $1.violations.count },
           "5.3 manufacturing: findings count equals total violations across rules")
var findingMessagesOK53 = true
for rule53 in reportThin53.rules {
    for finding53 in rule53.findings
    where !rule53.violations.contains(finding53.message) {
        findingMessagesOK53 = false
    }
}
check(findingMessagesOK53,
      "5.3 manufacturing: every finding's message is among its rule's violations")
if let findingThin53 {
    let splitThin53 = BoardManufacturing.visibleFindings(
        reportThin53.findings, excluding: [findingThin53.key])
    checkEqual(splitThin53.visible.count, reportThin53.findings.count - 1,
               "5.3 manufacturing exclusions: excluding the thin-trace key hides one finding")
    checkEqual(splitThin53.excluded, [findingThin53],
               "5.3 manufacturing exclusions: the excluded list is exactly that finding")
} else {
    check(false, "5.3 manufacturing exclusions: the thin-trace finding exists to exclude")
}
checkEqual(BoardManufacturing.staleExclusions(["bogus|key"],
                                              findings: reportThin53.findings),
           ["bogus|key"],
           "5.3 manufacturing exclusions: a key matching nothing is stale")
let reportThinOld53 = BoardManufacturing.check(
    model: modelThin53, copperCount: 4, settings: ManufacturingSettings(),
    connectivity: connThin53)
checkEqual(reportThinOld53.rules.map(\.violations),
           reportThin53.rules.map(\.violations),
           "5.3 manufacturing: the pre-5.3 4-argument check gives identical per-rule violations")

// -- P6: teardrops --

let traceTD53ID = fixedUUID("00000000-0000-4000-8000-00000000053C")
var stateTD53 = BoardState()
stateTD53.knownReferences = ["R1", "U1", "X1"]
stateTD53.traces = [trace53(traceTD53ID, "NET_A", "F.Cu", 0.25,
                            [u1Pad1Centre, r1Pad1Centre])]
let modelTD53 = PCBBoardMerger.apply(state: stateTD53, to: board,
                                     isSync: false).model
let teardrops53 = BoardTeardrops.generate(state: stateTD53, model: modelTD53)
checkEqual(teardrops53.count, 2,
           "5.3 teardrops: one teardrop per pad end of the pad-to-pad trace")
if let firstTD53 = teardrops53.first {
    checkEqual(firstTD53.anchorPoint, u1Pad1Centre,
               "5.3 teardrops: the first teardrop anchors at U1 pad 1")
    check(firstTD53.layer == "F.Cu" && firstTD53.netName == "NET_A"
          && firstTD53.anchorTrackID == traceTD53ID.uuidString,
          "5.3 teardrops: the first teardrop carries the trace's layer, net and id")
    if firstTD53.points.count == 4 {
        let baseHalf53 = firstTD53.points[0].distance(to: firstTD53.points[3]) / 2
        check(approx(baseHalf53, 0.8),
              "5.3 teardrops: the base half-width is the circle pad's radius (0.8 mm)")
        let tipMid53 = FPPoint(x: (firstTD53.points[1].x + firstTD53.points[2].x) / 2,
                               y: (firstTD53.points[1].y + firstTD53.points[2].y) / 2)
        check(approx(tipMid53.distance(to: u1Pad1Centre), 0.3),
              "5.3 teardrops: the tip sits 0.3 mm from the anchor")
        let runTD53 = u1Pad1Centre.distance(to: r1Pad1Centre)
        let tipExpected53 = FPPoint(
            x: u1Pad1Centre.x + (r1Pad1Centre.x - u1Pad1Centre.x) / runTD53 * 0.3,
            y: u1Pad1Centre.y + (r1Pad1Centre.y - u1Pad1Centre.y) / runTD53 * 0.3)
        check(approx(tipMid53.x, tipExpected53.x)
              && approx(tipMid53.y, tipExpected53.y),
              "5.3 teardrops: the tip lies toward R1 pad 1")
        let tipHalf53 = firstTD53.points[1].distance(to: firstTD53.points[2]) / 2
        check(approx(tipHalf53, 0.125),
              "5.3 teardrops: the tip half-width is the track's half width (0.125 mm)")
    } else {
        check(false, "5.3 teardrops: a teardrop polygon has 4 points")
    }
} else {
    check(false, "5.3 teardrops: a first teardrop exists to inspect")
}
var stateTDRegen53 = stateTD53
stateTDRegen53.teardrops = teardrops53
checkEqual(BoardTeardrops.generate(state: stateTDRegen53, model: modelTD53),
           teardrops53,
           "5.3 teardrops: regeneration over its own output is identical, ids included")
let modelTDShapes53 = PCBBoardMerger.apply(state: stateTDRegen53, to: board,
                                           isSync: false).model
let shapesTD53 = BoardCopper.shapes(model: modelTDShapes53, copperCount: 4)
let shapesNoTD53 = BoardCopper.shapes(model: modelTD53, copperCount: 4)
check(shapesTD53.contains { $0.kind == .teardrop && $0.netName == "NET_A" },
      "5.3 teardrops: teardrops are real copper shapes of their net")
checkEqual(shapesTD53.count, shapesNoTD53.count + 2,
           "5.3 teardrops: the copper shape count grows by exactly the 2 teardrops")
checkEqual(BoardTeardrops.removing(from: stateTDRegen53, net: "NET_A")
            .teardrops.count, 0,
           "5.3 teardrops: removing NET_A's teardrops removes both")
checkEqual(BoardTeardrops.removingAll(from: stateTDRegen53).teardrops.count, 0,
           "5.3 teardrops: removing all teardrops removes both")
checkEqual(BoardTeardrops.removing(from: stateTDRegen53, net: "VCC")
            .teardrops.count, 2,
           "5.3 teardrops: removing another net's teardrops keeps both")


// -- P4: cleanup tracks & vias --

let traceCleanA53 = trace53(UUID(), "NET_A", "F.Cu", 0.25,
                            [u1Pad1Centre, r1Pad1Centre])
let traceCleanB53 = trace53(UUID(), "NET_A", "F.Cu", 0.25,
                            [fp53(0, 200), fp53(30, 200)])
let traceCleanC53 = trace53(UUID(), "NET_A", "F.Cu", 0.25,
                            [r1Pad1Centre, fp53(200, 200)])
let traceCleanD53 = trace53(UUID(), "NET_A", "F.Cu", 0.25,
                            [fp53(200, 200), fp53(260, 200)])
let traceNull53 = trace53(UUID(), "NET_B", "F.Cu", 0.25,
                          [fp53(0, 300), fp53(0, 300), fp53(10, 300), fp53(10, 300)])
let traceColl53 = trace53(UUID(), "NET_B", "F.Cu", 0.25,
                          [fp53(0, 320), fp53(10, 320), fp53(20, 320)])
var stateCleanPartial53 = BoardState()
stateCleanPartial53.knownReferences = ["R1", "U1", "X1"]
stateCleanPartial53.traces = [traceCleanA53, traceCleanB53, traceCleanC53,
                              traceCleanD53, traceNull53, traceColl53]
let cleanPartial53 = BoardCleanup.cleanTracksAndVias(
    state: stateCleanPartial53,
    model: PCBBoardMerger.apply(state: stateCleanPartial53, to: board,
                                isSync: false).model,
    options: BoardCleanupOptions(removeDangling: false))
checkEqual(cleanPartial53.report,
           ["nullSegments": 2, "mergedSegments": 1, "duplicateVias": 0,
            "danglingTracks": 0, "disconnectedItems": 0],
           "5.3 cleanup: null/collinear pass reports 2 null segments + 1 merged segment")
checkEqual(cleanPartial53.state.traces.first { $0.id == traceNull53.id }?.points ?? [],
           [fp53(0, 300), fp53(10, 300)],
           "5.3 cleanup: the null-segment trace collapses to its two distinct points")
checkEqual(cleanPartial53.state.traces.first { $0.id == traceColl53.id }?.points ?? [],
           [fp53(0, 320), fp53(20, 320)],
           "5.3 cleanup: the collinear trace loses its interior point")

var stateCleanFull53 = BoardState()
stateCleanFull53.knownReferences = ["R1", "U1", "X1"]
stateCleanFull53.traces = [traceCleanA53, traceCleanB53,
                           traceCleanC53, traceCleanD53]
let cleanFull53 = BoardCleanup.cleanTracksAndVias(
    state: stateCleanFull53,
    model: PCBBoardMerger.apply(state: stateCleanFull53, to: board,
                                isSync: false).model)
checkEqual(cleanFull53.report,
           ["nullSegments": 0, "mergedSegments": 0, "duplicateVias": 0,
            "danglingTracks": 3, "disconnectedItems": 0],
           "5.3 cleanup: full cleanup removes 3 dangling tracks (B and D, then C by fixpoint)")
checkEqual(cleanFull53.state.traces.map(\.id), [traceCleanA53.id],
           "5.3 cleanup: only the pad-to-pad trace survives")

let viaDup1_53 = BoardVia(id: UUID(), netName: "NET_A",
                          center: fp53(10, 400), diameter: 0.8, drill: 0.4)
let viaDup2_53 = BoardVia(id: UUID(), netName: "NET_A",
                          center: fp53(10, 400), diameter: 0.8, drill: 0.4)
let viaOther53 = BoardVia(id: UUID(), netName: "NET_A",
                          center: fp53(30, 400), diameter: 0.8, drill: 0.4)
var stateViaDup53 = BoardState()
stateViaDup53.vias = [viaDup1_53, viaDup2_53, viaOther53]
let cleanViaDup53 = BoardCleanup.cleanTracksAndVias(
    state: stateViaDup53,
    model: PCBBoardMerger.apply(state: stateViaDup53, to: board,
                                isSync: false).model)
checkEqual(cleanViaDup53.report["duplicateVias"] ?? -1, 1,
           "5.3 cleanup: one duplicate via is reported")
checkEqual(cleanViaDup53.state.vias.map(\.id), [viaDup1_53.id, viaOther53.id],
           "5.3 cleanup: the first duplicate via is kept, the different-centre via stays")

var stateViaDisc53 = BoardState()
stateViaDisc53.vias = [BoardVia(id: UUID(), netName: nil,
                                disconnectedNetName: "VCC",
                                center: fp53(0, 450), diameter: 0.8, drill: 0.4)]
let cleanViaDisc53 = BoardCleanup.cleanTracksAndVias(
    state: stateViaDisc53,
    model: PCBBoardMerger.apply(state: stateViaDisc53, to: board,
                                isSync: false).model)
checkEqual(cleanViaDisc53.report["disconnectedItems"] ?? -1, 1,
           "5.3 cleanup: the sync-orphaned via counts as a disconnected item")
check(cleanViaDisc53.state.vias.isEmpty,
      "5.3 cleanup: the disconnected via is removed")

var stateCleanLock53 = stateCleanFull53
stateCleanLock53.setLocked(traceCleanB53.id, true)
let cleanLock53 = BoardCleanup.cleanTracksAndVias(
    state: stateCleanLock53,
    model: PCBBoardMerger.apply(state: stateCleanLock53, to: board,
                                isSync: false).model)
check(cleanLock53.state.traces.contains { $0.id == traceCleanB53.id },
      "5.3 cleanup: a locked dangling trace survives")
checkEqual(cleanLock53.report["danglingTracks"] ?? -1, 2,
           "5.3 cleanup: the locked trace is not counted as dangling (D, then C)")

// -- P5: cleanup graphics --

func graphicLine53(_ points: [FPPoint]) -> BoardGraphicItem {
    BoardGraphicItem(id: UUID(), kind: .line, layer: "Dwgs.User",
                     points: points)
}
let gfxDup1_53 = graphicLine53([fp53(100, 100), fp53(110, 100)])
let gfxDup2_53 = graphicLine53([fp53(100, 100), fp53(110, 100)])
let gfxLine1_53 = graphicLine53([fp53(0, 0), fp53(10, 0)])
let gfxLine2_53 = graphicLine53([fp53(10, 0), fp53(25, 0)])
let gfxLock1_53 = graphicLine53([fp53(200, 200), fp53(210, 200)])
let gfxLock2_53 = graphicLine53([fp53(200, 200), fp53(210, 200)])
var stateGfx53 = BoardState()
stateGfx53.graphics = [gfxDup1_53, gfxDup2_53, gfxLine1_53, gfxLine2_53,
                       gfxLock1_53, gfxLock2_53]
stateGfx53.setLocked(gfxLock2_53.id, true)
let cleanGfx53 = BoardCleanup.cleanGraphics(state: stateGfx53)
checkEqual(cleanGfx53.report, ["duplicateGraphics": 1, "mergedGraphics": 1],
           "5.3 cleanup graphics: 1 duplicate (unlocked pair only) + 1 merged line")
let mergedGfx53 = cleanGfx53.state.graphics.first { $0.id == gfxLine1_53.id }
checkEqual(mergedGfx53?.points ?? [], [fp53(0, 0), fp53(25, 0)],
           "5.3 cleanup graphics: the merged line runs (0,0)-(25,0) under the first line's id")
checkEqual(cleanGfx53.state.graphics.filter {
               $0.id == gfxLock1_53.id || $0.id == gfxLock2_53.id
           }.count, 2,
           "5.3 cleanup graphics: the locked duplicate pair survives")

// -- P2 + P3: net queries --

let traceConn53 = stateConn.traces[0]
let traceVCC53 = trace53(UUID(), "VCC", "F.Cu", 0.25,
                         [fp53(0, 250), fp53(20, 250)])
let viaVCC53 = BoardVia(id: UUID(), netName: "VCC", center: fp53(10, 250),
                        diameter: 0.8, drill: 0.4)
let traceOrphan53 = BoardTrace(id: UUID(), netName: nil,
                               disconnectedNetName: "NET_A", layer: "F.Cu",
                               width: 0.25,
                               points: [fp53(0, 260), fp53(20, 260)])
var stateNQ53 = BoardState()
stateNQ53.knownReferences = ["R1", "U1", "X1"]
stateNQ53.traces = [traceConn53, traceVCC53, traceOrphan53]
stateNQ53.vias = [viaVCC53]
let modelNQ53 = PCBBoardMerger.apply(state: stateNQ53, to: board,
                                     isSync: false).model
let queryA53 = BoardNetQueries.itemIDs(onNet: "NET_A", state: stateNQ53,
                                       model: modelNQ53)
checkEqual(queryA53.traceIDs, Set([traceConn53.id.uuidString]),
           "5.3 net query: NET_A's traces are exactly the routed conn trace")
check(queryA53.viaIDs.isEmpty, "5.3 net query: NET_A has no vias")
checkEqual(queryA53.references, Set(["U1", "R1"]),
           "5.3 net query: NET_A's footprints are U1 and R1")
check(!queryA53.traceIDs.contains(traceOrphan53.id.uuidString),
      "5.3 net query: the sync-orphan trace does NOT match its old net")
let queryVCC53 = BoardNetQueries.itemIDs(onNet: "VCC", state: stateNQ53,
                                         model: modelNQ53)
checkEqual(queryVCC53.traceIDs, Set([traceVCC53.id.uuidString]),
           "5.3 net query: VCC's trace is the VCC trace")
checkEqual(queryVCC53.viaIDs, Set([viaVCC53.id.uuidString]),
           "5.3 net query: VCC's via is the VCC via")
checkEqual(queryVCC53.references, Set(["U1", "X1"]),
           "5.3 net query: VCC's footprints are U1 and X1")
checkEqual(BoardNetQueries.unconnectedReferences(model: board, copperCount: 4),
           ["R1", "U1", "X1"],
           "5.3 net query: with no copper every component has an unrouted pad")
checkEqual(BoardNetQueries.unconnectedReferences(model: mergedConn, copperCount: 4),
           ["U1", "X1"],
           "5.3 net query: routing NET_A clears R1; U1 and X1 still have unrouted pads")

// -- P14: unroute --

let traceU1_53 = trace53(UUID(), "NET_A", "F.Cu", 0.25,
                         [u1Pad1Centre, r1Pad1Centre])
let traceU2_53 = trace53(UUID(), "NET_A", "F.Cu", 0.25,
                         [r1Pad1Centre, fp53(200, 200)])
let u1Pad4Centre53 = BoardGeometry.padCenter(
    component("U1"), binding(component("U1"), "4").pad!)
let x1Pad1Centre53 = BoardGeometry.padCenter(
    component("X1"), binding(component("X1"), "1").pad!)
let traceU3_53 = trace53(UUID(), "NET_B", "F.Cu", 0.25,
                         [u1Pad4Centre53, x1Pad1Centre53])
let viaU1_53 = BoardVia(id: UUID(), netName: "NET_A", center: r1Pad1Centre,
                        diameter: 0.8, drill: 0.4)
let teardropU53 = TeardropItem(
    id: UUID(), netName: "NET_A", layer: "F.Cu",
    points: [u1Pad1Centre,
             fp53(u1Pad1Centre.x + 2, u1Pad1Centre.y),
             fp53(u1Pad1Centre.x + 2, u1Pad1Centre.y + 2),
             fp53(u1Pad1Centre.x, u1Pad1Centre.y + 2)],
    anchorTrackID: traceU1_53.id.uuidString, anchorPoint: u1Pad1Centre)
var stateUnroute53 = BoardState()
stateUnroute53.knownReferences = ["R1", "U1", "X1"]
stateUnroute53.traces = [traceU1_53, traceU2_53, traceU3_53]
stateUnroute53.vias = [viaU1_53]
stateUnroute53.teardrops = [teardropU53]
let modelUnroute53 = PCBBoardMerger.apply(state: stateUnroute53, to: board,
                                          isSync: false).model
let unrouteRef53 = BoardUnroute.removingRouting(
    forReference: "U1", state: stateUnroute53, model: modelUnroute53)
checkEqual(unrouteRef53.removedTraces, 2,
           "5.3 unroute: unrouting U1 removes both traces touching its pads (NET_A pad 1 and NET_B pad 4)")
checkEqual(unrouteRef53.removedVias, 0,
           "5.3 unroute: the via sitting on R1's pad centre stays — traversal stops at the far pad (leaf-pad-centre rule)")
check(!unrouteRef53.state.traces.contains { $0.id == traceU1_53.id }
      && unrouteRef53.state.traces.contains { $0.id == traceU2_53.id }
      && !unrouteRef53.state.traces.contains { $0.id == traceU3_53.id },
      "5.3 unroute: t2 stops at R1's pad and survives; t3 touched U1's pad 4 and is removed")
check(unrouteRef53.state.teardrops.isEmpty,
      "5.3 unroute: the removed trace's teardrop goes with it")
let unrouteTrace53 = BoardUnroute.removingRouting(
    fromTraceID: traceU1_53.id, state: stateUnroute53, model: modelUnroute53)
checkEqual(unrouteTrace53.removedTraces, 1,
           "5.3 unroute: unrouting from the trace removes the same trace")
checkEqual(unrouteTrace53.removedVias, 0,
           "5.3 unroute: unrouting from the trace also leaves the far pad's via in place")
check(unrouteTrace53.state.traces.contains { $0.id == traceU2_53.id }
      && unrouteTrace53.state.traces.contains { $0.id == traceU3_53.id },
      "5.3 unroute: from-trace unroute leaves t2 and t3 in place")
var stateUnrouteLock53 = stateUnroute53
stateUnrouteLock53.setLocked(traceU1_53.id, true)
let unrouteLock53 = BoardUnroute.removingRouting(
    forReference: "U1", state: stateUnrouteLock53, model: modelUnroute53)
checkEqual(unrouteLock53.removedTraces, 1,
           "5.3 unroute: the locked trace is a barrier for its own route; U1's NET_B route is still removed")
checkEqual(unrouteLock53.removedVias, 0,
           "5.3 unroute: behind the locked barrier the via stays too")

// -- P11: board clipboard --

let traceCB53 = trace53(UUID(), "NET_A", "F.Cu", 0.25,
                        [fp53(10, 20), fp53(30, 20)])
let viaCB53 = BoardVia(id: UUID(), netName: "NET_A", center: fp53(15, 30),
                       diameter: 0.8, drill: 0.4)
let zoneCB53 = BoardZone(id: UUID(), netName: "NET_A", layer: "F.Cu",
                         points: [fp53(20, 40), fp53(35, 40),
                                  fp53(35, 55), fp53(20, 55)])
let gfxCB53 = BoardGraphicItem(id: UUID(), kind: .line, layer: "Dwgs.User",
                               points: [fp53(8, 50), fp53(18, 50)])
let tdCB53 = TeardropItem(
    id: UUID(), netName: "NET_A", layer: "F.Cu",
    points: [fp53(10, 18), fp53(16, 19), fp53(16, 21), fp53(10, 22)],
    anchorTrackID: traceCB53.id.uuidString, anchorPoint: fp53(10, 20))
let traceCBExtra53 = trace53(UUID(), "NET_B", "F.Cu", 0.25,
                             [fp53(500, 500), fp53(510, 500)])
var stateCB53 = BoardState()
stateCB53.traces = [traceCB53, traceCBExtra53]
stateCB53.vias = [viaCB53]
stateCB53.zones = [zoneCB53]
stateCB53.graphics = [gfxCB53]
stateCB53.teardrops = [tdCB53]
let idsCB53 = Set([traceCB53.id.uuidString, viaCB53.id.uuidString,
                   zoneCB53.id.uuidString, gfxCB53.id.uuidString,
                   tdCB53.id.uuidString])
let slice53 = BoardClipboard.extract(state: stateCB53, itemIDs: idsCB53)
check(slice53.traces.count == 1 && slice53.vias.count == 1
      && slice53.zones.count == 1 && slice53.graphics.count == 1
      && slice53.teardrops.count == 1,
      "5.3 clipboard: the slice holds exactly one item of each kind")
checkEqual(slice53.boundsOrigin, fp53(8, 18),
           "5.3 clipboard: the bounds origin is the componentwise minimum of all points")
checkEqual(BoardClipboard.extract(state: stateCB53,
                                  itemIDs: idsCB53.union(["U1"])), slice53,
           "5.3 clipboard: adding a footprint reference to the id set changes nothing")
let paste53 = BoardClipboard.pasted(into: BoardState(), slice: slice53,
                                    anchorOffset: fp53(100, 100))
checkEqual(paste53.newIDs.count, 5,
           "5.3 clipboard: pasting five items reports five new ids")
check(Set(paste53.newIDs).count == 5
      && Set(paste53.newIDs).isDisjoint(with: idsCB53),
      "5.3 clipboard: every pasted id is fresh and distinct from the originals")
check(paste53.state.traces.count == 1 && paste53.state.vias.count == 1
      && paste53.state.zones.count == 1 && paste53.state.graphics.count == 1
      && paste53.state.teardrops.count == 1,
      "5.3 clipboard: the pasted state gains exactly the five items")
checkEqual(paste53.state.traces[0].points, [fp53(110, 120), fp53(130, 120)],
           "5.3 clipboard: pasted trace points are translated by (100, 100)")
checkEqual(paste53.state.teardrops[0].anchorTrackID,
           paste53.state.traces[0].id.uuidString,
           "5.3 clipboard: the pasted teardrop anchors to the pasted trace's new id")
check(paste53.newIDs.allSatisfy { !paste53.state.lockedItemIDs.contains($0) },
      "5.3 clipboard: no pasted item is locked")

// -- P1: move exactly (translate / rotate) --

let traceT53 = trace53(UUID(), "NET_A", "F.Cu", 0.25,
                       [fp53(0, 0), fp53(10, 0)])
let viaT53 = BoardVia(id: UUID(), netName: "NET_A", center: fp53(5, 5),
                      diameter: 0.8, drill: 0.4)
let gfxT53 = BoardGraphicItem(id: UUID(), kind: .circle, layer: "F.SilkS",
                              points: [fp53(2, 2)], radius: 3)
var stateT53 = BoardState()
stateT53.traces = [traceT53]
stateT53.vias = [viaT53]
stateT53.graphics = [gfxT53]
stateT53.placements = ["U1": fp53(20, 20)]
let translated53 = BoardTransforms.translated(
    state: stateT53, itemIDs: [traceT53.id.uuidString, "U1"], dx: 1, dy: 2)
checkEqual(translated53.traces[0].points, [fp53(1, 2), fp53(11, 2)],
           "5.3 move exactly: the trace translates by (1, 2)")
checkEqual(translated53.placements["U1"] ?? fp53(-1, -1), fp53(21, 22),
           "5.3 move exactly: U1's placement translates by (1, 2)")
checkEqual(translated53.vias[0].center, fp53(5, 5),
           "5.3 move exactly: an item outside the set does not move")
let rotated53 = BoardTransforms.rotated(
    state: stateT53,
    itemIDs: [traceT53.id.uuidString, viaT53.id.uuidString,
              gfxT53.id.uuidString],
    centre: fp53(0, 0), degrees: 90)
let rotatedTrace53 = rotated53.traces[0]
check(approx(rotatedTrace53.points[0].x, 0) && approx(rotatedTrace53.points[0].y, 0)
      && approx(rotatedTrace53.points[1].x, 0) && approx(rotatedTrace53.points[1].y, 10),
      "5.3 move exactly: rotating 90° about the origin sends (10,0) to (0,10)")
check(approx(rotated53.vias[0].center.x, -5) && approx(rotated53.vias[0].center.y, 5),
      "5.3 move exactly: the via centre rotates to (-5, 5)")
check(approx(rotated53.graphics[0].points[0].x, -2)
      && approx(rotated53.graphics[0].points[0].y, 2)
      && approx(rotated53.graphics[0].radius, 3),
      "5.3 move exactly: the circle's centre rotates, its radius stays 3")
var stateTLock53 = stateT53
stateTLock53.setLocked(traceT53.id, true)
let translatedLock53 = BoardTransforms.translated(
    state: stateTLock53, itemIDs: [traceT53.id.uuidString], dx: 5, dy: 5)
checkEqual(translatedLock53.traces[0].points, traceT53.points,
           "5.3 move exactly: a locked trace in the set is unchanged")
let rotatedFP53 = BoardTransforms.rotated(
    state: stateT53, itemIDs: ["U1"], centre: fp53(0, 0), degrees: 90)
let rotatedPlacement53 = rotatedFP53.placements["U1"] ?? fp53(-1, -1)
check(approx(rotatedPlacement53.x, -20) && approx(rotatedPlacement53.y, 20),
      "5.3 move exactly: a footprint in the rotated set orbits the centre to (-20, 20)")

// -- P15: swap layers --

let traceSwapF53 = trace53(UUID(), "NET_A", "F.Cu", 0.25,
                           [fp53(0, 0), fp53(10, 0)])
let traceSwapB53 = trace53(UUID(), "NET_A", "B.Cu", 0.25,
                           [fp53(0, 20), fp53(10, 20)])
let zoneSwap53 = BoardZone(id: UUID(), netName: nil, layer: "In1.Cu",
                           points: [fp53(0, 40), fp53(10, 40),
                                    fp53(10, 50), fp53(0, 50)])
let gfxSwapCu53 = BoardGraphicItem(id: UUID(), kind: .line, layer: "F.Cu",
                                   points: [fp53(0, 60), fp53(10, 60)])
let gfxSwapSilk53 = BoardGraphicItem(id: UUID(), kind: .line, layer: "F.SilkS",
                                     points: [fp53(0, 70), fp53(10, 70)])
var stateSwap53 = BoardState()
stateSwap53.copperLayerCount = 2
stateSwap53.traces = [traceSwapF53, traceSwapB53]
stateSwap53.zones = [zoneSwap53]
stateSwap53.graphics = [gfxSwapCu53, gfxSwapSilk53]
stateSwap53.sides = ["U1": .front]
stateSwap53.knownReferences = ["U1", "R1"]
let swappedLayers53 = BoardLayerSwap.swapped(state: stateSwap53)
checkEqual(swappedLayers53.traces.first { $0.id == traceSwapF53.id }?.layer ?? "",
           "B.Cu", "5.3 swap layers: the F.Cu trace goes to B.Cu on a 2-layer board")
checkEqual(swappedLayers53.traces.first { $0.id == traceSwapB53.id }?.layer ?? "",
           "F.Cu", "5.3 swap layers: the B.Cu trace goes to F.Cu")
checkEqual(swappedLayers53.zones[0].layer, "In1.Cu",
           "5.3 swap layers: a zone on a layer outside the 2-layer stack stays")
checkEqual(swappedLayers53.graphics.first { $0.id == gfxSwapSilk53.id }?.layer ?? "",
           "F.SilkS", "5.3 swap layers: a silkscreen graphic is unchanged")
check(swappedLayers53.sides["U1"] == .back && swappedLayers53.sides["R1"] == .back,
      "5.3 swap layers: every known footprint flips side (U1 and R1 end on the back)")
let swappedTwice53 = BoardLayerSwap.swapped(state: swappedLayers53)
check(swappedTwice53.traces == stateSwap53.traces
      && swappedTwice53.zones == stateSwap53.zones
      && swappedTwice53.graphics == stateSwap53.graphics
      && swappedTwice53.sides["U1"] == .front
      && swappedTwice53.sides["R1"] == .front,
      "5.3 swap layers: swapping twice restores the original items and sides")
let traceSwapIn1_53 = trace53(UUID(), "NET_A", "In1.Cu", 0.25,
                              [fp53(0, 0), fp53(10, 0)])
let traceSwapIn2_53 = trace53(UUID(), "NET_A", "In2.Cu", 0.25,
                              [fp53(0, 20), fp53(10, 20)])
var stateSwap4_53 = BoardState()
stateSwap4_53.copperLayerCount = 4
stateSwap4_53.traces = [traceSwapIn1_53, traceSwapIn2_53]
let swapped4_53 = BoardLayerSwap.swapped(state: stateSwap4_53)
checkEqual(swapped4_53.traces.first { $0.id == traceSwapIn1_53.id }?.layer ?? "",
           "In2.Cu", "5.3 swap layers: on a 4-layer board In1.Cu goes to In2.Cu")
checkEqual(swapped4_53.traces.first { $0.id == traceSwapIn2_53.id }?.layer ?? "",
           "In1.Cu", "5.3 swap layers: on a 4-layer board In2.Cu goes to In1.Cu")

// -- P13: global deletions --

let traceGD1_53 = trace53(UUID(), "NET_A", "F.Cu", 0.25,
                          [fp53(0, 0), fp53(10, 0)])
let traceGD2_53 = trace53(UUID(), "NET_A", "F.Cu", 0.25,
                          [fp53(0, 20), fp53(10, 20)])
let viaGD53 = BoardVia(id: UUID(), netName: "NET_A", center: fp53(5, 40),
                       diameter: 0.8, drill: 0.4)
let tdGD53 = TeardropItem(id: UUID(), netName: "NET_A", layer: "F.Cu",
                          points: [fp53(0, 0), fp53(1, 0), fp53(1, 1), fp53(0, 1)],
                          anchorTrackID: traceGD1_53.id.uuidString,
                          anchorPoint: fp53(0, 0))
var stateGD53 = BoardState()
stateGD53.traces = [traceGD1_53, traceGD2_53]
stateGD53.vias = [viaGD53]
stateGD53.teardrops = [tdGD53]
stateGD53.setLocked(traceGD2_53.id, true)
let globalDelete53 = BoardGlobalDelete.apply(
    state: stateGD53, classes: [.tracks, .teardrops], includeLocked: false)
checkEqual(globalDelete53.counts,
           ["tracks": 1, "vias": 0, "zones": 0, "graphics": 0, "teardrops": 1],
           "5.3 global delete: one track + one teardrop deleted, other classes untouched")
checkEqual(globalDelete53.state.traces.map(\.id), [traceGD2_53.id],
           "5.3 global delete: the locked trace survives")
let globalDeleteAll53 = BoardGlobalDelete.apply(
    state: stateGD53, classes: [.tracks, .teardrops], includeLocked: true)
checkEqual(globalDeleteAll53.counts["tracks"] ?? -1, 2,
           "5.3 global delete: including locked items deletes both tracks")
check(!globalDeleteAll53.state.lockedItemIDs.contains(traceGD2_53.id.uuidString),
      "5.3 global delete: the deleted locked trace's lock entry is pruned")

// -- P12: PCB find --

let hitsRef53 = BoardFind.hits(model: board, query: "r1")
check(hitsRef53.first?.kind == .reference && hitsRef53.first?.reference == "R1",
      "5.3 PCB find: 'r1' first hits R1's reference")
let hitsValue53 = BoardFind.hits(model: board, query: "10k")
check(hitsValue53.count == 1 && hitsValue53.first?.kind == .value
      && hitsValue53.first?.reference == "R1" && hitsValue53.first?.text == "10k",
      "5.3 PCB find: '10k' is one value hit on R1")
let hitsNetFind53 = BoardFind.hits(model: board, query: "net_a")
check(hitsNetFind53.count == 1 && hitsNetFind53.first?.kind == .net
      && hitsNetFind53.first?.reference == "R1"
      && hitsNetFind53.first?.text == "NET_A",
      "5.3 PCB find: 'net_a' is one net hit owned by R1 (its pad 1 is first on NET_A)")
check(BoardFind.hits(model: board, query: "").isEmpty,
      "5.3 PCB find: an empty query hits nothing")
check(BoardFind.hits(model: board, query: "zzz").isEmpty,
      "5.3 PCB find: 'zzz' hits nothing")
let hitsOne53 = BoardFind.hits(model: board, query: "1")
checkEqual(hitsOne53.filter { $0.kind == .reference }.map(\.reference),
           ["R1", "U1", "X1"],
           "5.3 PCB find: '1' reference hits come in natural order R1, U1, X1")
check(hitsOne53.allSatisfy { $0.kind != .net },
      "5.3 PCB find: '1' has no net hits, so every hit is a component hit")

// -- P10: update footprints from library --

func compIn53(_ model: BoardModel, _ reference: String) -> BoardComponent {
    guard let found = model.components.first(where: { $0.reference == reference })
    else { fatal("5.3 refreshed board is missing component \(reference)") }
    return found
}
var fixrMod53 = fixrParsed
fixrMod53.pads[0].x = -7.7
fixrMod53.pads[0].y = 4.4
var fixrEntryMod53 = fixrEntry
fixrEntryMod53.parsed = fixrMod53
let store53 = FootprintStore()
store53.bundledFootprints = [fixicEntry, fixrEntryMod53]
store53.userFootprints = [custEntry]
let refreshed53 = PCBBoardModelBuilder.refreshed(model: board, store: store53)
let r1Refreshed53 = compIn53(refreshed53, "R1")
let r1Pad1Refreshed53 = r1Refreshed53.pins.first { $0.pinNumber == "1" }?.pad
check(r1Pad1Refreshed53 != nil && approx(r1Pad1Refreshed53!.x, -7.7)
      && approx(r1Pad1Refreshed53!.y, 4.4),
      "5.3 refresh: R1's pin 1 rebinds to the library's moved pad 1 (-7.7, 4.4)")
let u1Pad1Refreshed53 = compIn53(refreshed53, "U1").pins
    .first { $0.pinNumber == "1" }?.pad
check(u1Pad1Refreshed53 != nil && approx(u1Pad1Refreshed53!.x, -3.81)
      && approx(u1Pad1Refreshed53!.y, -2.54),
      "5.3 refresh: U1's footprint is unchanged (pad 1 still at (-3.81, -2.54))")
let x1Pad1Refreshed53 = compIn53(refreshed53, "X1").pins
    .first { $0.pinNumber == "1" }?.pad
check(x1Pad1Refreshed53 != nil && approx(x1Pad1Refreshed53!.x, -2.54)
      && approx(x1Pad1Refreshed53!.y, 0),
      "5.3 refresh: X1's footprint is unchanged (pad 1 still at (-2.54, 0))")
let refreshedEmpty53 = PCBBoardModelBuilder.refreshed(
    model: refreshed53, store: FootprintStore())
let r1Empty53 = compIn53(refreshedEmpty53, "R1")
check(r1Empty53.footprint == nil,
      "5.3 refresh: with an empty store R1's footprint no longer resolves")
check(!r1Empty53.pins.isEmpty && r1Empty53.pins.allSatisfy { $0.pad == nil },
      "5.3 refresh: with an empty store every R1 pin's pad is nil")

// MARK: - Part 5.4: net labels — tiered naming, power scope,
//         label edit/move, validation, cleanup safety, board sync
//
// The v5.4 proof section. Builder naming is TIERED (KiCad
// connection_graph.h PRIORITY): tier 3 = global power symbol name,
// tier 2 = local power symbol name, tier 1 = label text. The primary
// name is the highest non-empty tier's alphabetical-first name; all
// other distinct explicit names are the net's aliases, sorted.
// Every assertion states the CONTRACT value against the real
// ConnectionTableBuilder / SchematicERC / SchematicDocument /
// PCBBoardModelBuilder compiled into this harness.

guard let fixpwrgDef54 = fixtureLib.symbols["FIXPWRG"]
else { fatal("FIXPWRG missing") }
guard let fixpwrlDef54 = fixtureLib.symbols["FIXPWRL"]
else { fatal("FIXPWRL missing") }

check(fixpwrgDef54.isPower && fixpwrgDef54.powerScope == "global",
      "5.4 power fixture: FIXPWRG resolves as a global power symbol")
check(fixpwrlDef54.isPower && fixpwrlDef54.powerScope == "local",
      "5.4 power fixture: FIXPWRL resolves as a local power symbol")

func fixr54(_ reference: String, _ x: Double, _ y: Double) -> PlacedSymbol {
    PlacedSymbol(id: UUID(), library: "FixtureSym", symbolName: "FIXR",
                 unit: 1, x: x, y: y, rotation: 0, mirrorX: false,
                 mirrorY: false, reference: reference, value: "10k")
}

func fixpwr54(_ symbol: String, _ reference: String, _ value: String,
              _ x: Double, _ y: Double) -> PlacedSymbol {
    PlacedSymbol(id: UUID(), library: "FixtureSym", symbolName: symbol,
                 unit: 1, x: x, y: y, rotation: 0, mirrorX: false,
                 mirrorY: false, reference: reference, value: value)
}

func wire54(_ a: DPoint, _ b: DPoint, verticalFirst: Bool = true) -> WireItem {
    wire(UUID().uuidString, from: a, to: b, verticalFirst: verticalFirst)
}

/// One straight FIXR-to-FIXR run on the 25.40 placement grid: the
/// left part's pin 2 wired to the right part's pin 1.
func fixrRun54(_ leftRef: String, _ rightRef: String, _ y: Double)
    -> (left: PlacedSymbol, right: PlacedSymbol, wire: WireItem) {
    let left = fixr54(leftRef, 25.40, y)
    let right = fixr54(rightRef, 50.80, y)
    let runWire = wire54(pinPoint(def: fixrDef, placed: left, number: "2"),
                         pinPoint(def: fixrDef, placed: right, number: "1"))
    return (left, right, runWire)
}

func label54(_ text: String, _ at: DPoint) -> LabelItem {
    LabelItem(id: UUID(), at: at, text: text)
}

func table54(_ state: SchematicState) -> ConnectionTable {
    ConnectionTableBuilder.build(
        state: state,
        sourceFileName: "fixture54.json",
        resolveSymbol: { placed in
            defsByKey["\(placed.library)|\(placed.symbolName)"]
        },
        resolveFootprint: { placed, def in
            let match = FootprintMatcher.match(def: def,
                                               choiceKey: placed.footprintChoice,
                                               entries: entries)
            return (key: match.resolved?.resolutionKey, kind: match.kind?.rawValue)
        })
}

func erc54(_ state: SchematicState) -> [ERCFinding] {
    SchematicERC.check(state: state) { placed in
        defsByKey["\(placed.library)|\(placed.symbolName)"]
    }
}

func driverConflicts54(_ state: SchematicState) -> [ERCFinding] {
    erc54(state).filter { $0.kind == .driverConflict }
}

func endpointKeys54(_ net: ConnectionNet?) -> Set<String> {
    Set((net?.endpoints ?? []).map { "\($0.reference)|\($0.pinNumber)" })
}

func makeDoc54(_ state: SchematicState) -> SchematicDocument {
    let doc = SchematicDocument()
    doc.replaceState(state)
    return doc
}

// The power fixtures' pin 1 sits at local (0, 0), so pinWorldPoints
// puts it exactly at the placed origin (FIXR's pins, by contrast,
// sit at (±5.08, 0) — every other placement below goes through
// pinPoint(...) instead of assuming an origin coincidence).
let pwrPlacedG54 = fixpwr54("FIXPWRG", "#PWR1", "VDD", 25.40, 101.60)
check(pinPoint(def: fixpwrgDef54, placed: pwrPlacedG54, number: "1")
      == DPoint(x: 25.40, y: 101.60),
      "5.4 power fixture: FIXPWRG pin 1 is exactly at the placed origin")
let pwrPlacedL54 = fixpwr54("FIXPWRL", "#PWR2", "VDD", 50.80, 101.60)
check(pinPoint(def: fixpwrlDef54, placed: pwrPlacedL54, number: "1")
      == DPoint(x: 50.80, y: 101.60),
      "5.4 power fixture: FIXPWRL pin 1 is exactly at the placed origin")

// -- 1: a label names its net (Sean's example) --

let u2_54 = PlacedSymbol(
    id: UUID(), library: "FixtureSym", symbolName: "FIXIC", unit: 1,
    x: 25.40, y: 25.40, rotation: 0, mirrorX: false, mirrorY: false,
    reference: "U2", value: "FIXIC")
let r2_54 = fixr54("R2", 50.80, 25.40)
// U2 pin 2 (not pin 1): pin 1's row also carries pin 2's point, so a
// wire out of pin 1 would pass through pin 2 and join it — pin 2's
// first segment is clear of every other pin.
let wire1_54 = wire54(pinPoint(def: fixicDef, placed: u2_54, number: "2"),
                      pinPoint(def: fixrDef, placed: r2_54, number: "1"),
                      verticalFirst: false)
let label1_54 = label54("3V3", onFirstSegment(wire1_54, t: 0.5))
let state1_54 = SchematicState(
    symbols: [u2_54, r2_54], wires: [wire1_54], junctions: [],
    labels: [label1_54], title: "54-1")
let table1_54 = table54(state1_54)
check(table1_54.net(named: "3V3") != nil,
      "5.4 label names its net: a net named 3V3 exists")
checkEqual(table1_54.net(named: "3V3")?.endpoints.count ?? -1, 2,
           "5.4 label names its net: the 3V3 net has exactly 2 endpoints")
checkEqual(endpointKeys54(table1_54.net(named: "3V3")),
           Set(["U2|2", "R2|1"]),
           "5.4 label names its net: the endpoints are U2 pin 2 and R2 pin 1")
checkEqual(table1_54.nets.count, 1,
           "5.4 label names its net: the state writes exactly one net")

// -- 2: same-name labels union separate runs --

let runA54_2 = fixrRun54("R2", "R3", 76.20)
let runB54_2 = fixrRun54("R4", "R5", 25.40)
let state2_54 = SchematicState(
    symbols: [runA54_2.left, runA54_2.right, runB54_2.left, runB54_2.right],
    wires: [runA54_2.wire, runB54_2.wire], junctions: [],
    labels: [label54("3V3", onFirstSegment(runA54_2.wire, t: 0.5)),
             label54("3V3", onFirstSegment(runB54_2.wire, t: 0.5))],
    title: "54-2")
let table2_54 = table54(state2_54)
checkEqual(table2_54.nets.count, 1,
           "5.4 same-name union: two 3V3 runs write exactly one net")
checkEqual(table2_54.net(named: "3V3")?.endpoints.count ?? -1, 4,
           "5.4 same-name union: the single 3V3 net has all 4 endpoints")
checkEqual(table2_54.wireNetByWireID?[runA54_2.wire.id.uuidString] ?? "", "3V3",
           "5.4 same-name union: the first run's wire maps to 3V3")
checkEqual(table2_54.wireNetByWireID?[runB54_2.wire.id.uuidString] ?? "", "3V3",
           "5.4 same-name union: the second run's wire maps to 3V3")

// -- 3: a floating label joins nothing --

let run54_3 = fixrRun54("R2", "R3", 25.40)
let state3_54 = SchematicState(
    symbols: [run54_3.left, run54_3.right],
    wires: [run54_3.wire], junctions: [],
    labels: [label54("ORPHAN", DPoint(x: 200, y: 200))],
    title: "54-3")
let table3_54 = table54(state3_54)
check(table3_54.net(named: "ORPHAN") == nil,
      "5.4 floating label: no net is named ORPHAN")
let orphanFindings54 = erc54(state3_54).filter { $0.kind == .labelNotConnected }
checkEqual(orphanFindings54.count, 1,
           "5.4 floating label: ERC reports exactly one label-not-connected finding")
checkEqual(orphanFindings54.first?.detail ?? "", "ORPHAN",
           "5.4 floating label: the finding's detail is the label text ORPHAN")

// -- 4: a global power name beats a label on the same run --

let run54_4 = fixrRun54("R2", "R3", 25.40)
let pwr54_4 = fixpwr54("FIXPWRG", "#PWR1", "VDD", 38.10, 25.40)
let state4_54 = SchematicState(
    symbols: [run54_4.left, run54_4.right, pwr54_4],
    wires: [run54_4.wire], junctions: [],
    labels: [label54("3V3", onFirstSegment(run54_4.wire, t: 0.25))],
    title: "54-4")
let table4_54 = table54(state4_54)
check(table4_54.net(named: "VDD") != nil,
      "5.4 power beats label: the net is named VDD (the tier-3 power name)")
checkEqual(table4_54.net(named: "VDD")?.aliases ?? [], ["3V3"],
           "5.4 power beats label: the label survives as the only alias")
checkEqual(table4_54.net(named: "VDD")?.endpoints.count ?? -1, 3,
           "5.4 power beats label: the net carries both pins plus the power pin")
let conflicts54_4 = driverConflicts54(state4_54)
checkEqual(conflicts54_4.count, 1,
           "5.4 power beats label: ERC reports exactly one driver conflict")
check(conflicts54_4.first?.severity == .warning
      && conflicts54_4.first?.reference == "VDD"
      && conflicts54_4.first?.detail == "3V3",
      "5.4 power beats label: the conflict is a warning keyed VDD / 3V3")
check(conflicts54_4.first?.message.contains("will be used as the net name") == true,
      "5.4 power beats label: the message says VDD will be used as the net name")

// -- 5: two labels on one run — alphabetical-first wins within the tier --

let run54_5 = fixrRun54("R2", "R3", 25.40)
let state5_54 = SchematicState(
    symbols: [run54_5.left, run54_5.right],
    wires: [run54_5.wire], junctions: [],
    labels: [label54("BBB", onFirstSegment(run54_5.wire, t: 0.25)),
             label54("AAA", onFirstSegment(run54_5.wire, t: 0.75))],
    title: "54-5")
let table5_54 = table54(state5_54)
check(table5_54.net(named: "AAA") != nil,
      "5.4 two labels conflict: the net is named AAA (alphabetical within tier 1)")
checkEqual(table5_54.net(named: "AAA")?.aliases ?? [], ["BBB"],
           "5.4 two labels conflict: BBB is the only alias")
let conflicts54_5 = driverConflicts54(state5_54)
checkEqual(conflicts54_5.count, 1,
           "5.4 two labels conflict: ERC reports exactly one driver conflict")
checkEqual(conflicts54_5.first?.detail ?? "", "BBB",
           "5.4 two labels conflict: the conflict's detail is BBB")

// -- 6: global power beats local power (tier beats alphabetical) --

let pwrG54_6 = fixpwr54("FIXPWRG", "#PWR1", "ZGND", 25.40, 25.40)
let pwrL54_6 = fixpwr54("FIXPWRL", "#PWR2", "AGND", 50.80, 25.40)
let wire54_6 = wire54(
    pinPoint(def: fixpwrgDef54, placed: pwrG54_6, number: "1"),
    pinPoint(def: fixpwrlDef54, placed: pwrL54_6, number: "1"))
let state6_54 = SchematicState(
    symbols: [pwrG54_6, pwrL54_6], wires: [wire54_6], junctions: [],
    labels: [], title: "54-6")
let table6_54 = table54(state6_54)
check(table6_54.net(named: "ZGND") != nil,
      "5.4 global beats local: the net is named ZGND (tier 3 beats tier 2, not alphabetical)")
checkEqual(table6_54.net(named: "ZGND")?.aliases ?? [], ["AGND"],
           "5.4 global beats local: AGND is the only alias")
checkEqual(table6_54.net(named: "ZGND")?.endpoints.count ?? -1, 2,
           "5.4 global beats local: the written net has both power endpoints")
let conflicts54_6 = driverConflicts54(state6_54)
checkEqual(conflicts54_6.count, 1,
           "5.4 global beats local: ERC reports exactly one driver conflict")
checkEqual(conflicts54_6.first?.detail ?? "", "AGND",
           "5.4 global beats local: the conflict's detail is AGND")

// -- 7: renaming one of two unioned labels splits the net --

let runA54_7 = fixrRun54("R2", "R3", 76.20)
let runB54_7 = fixrRun54("R4", "R5", 25.40)
let labelA54_7 = label54("3V3", onFirstSegment(runA54_7.wire, t: 0.5))
let labelB54_7 = label54("3V3", onFirstSegment(runB54_7.wire, t: 0.5))
let doc54_7 = makeDoc54(SchematicState(
    symbols: [runA54_7.left, runA54_7.right, runB54_7.left, runB54_7.right],
    wires: [runA54_7.wire, runB54_7.wire], junctions: [],
    labels: [labelA54_7, labelB54_7], title: "54-7"))
let tableBefore54_7 = table54(doc54_7.state)
checkEqual(tableBefore54_7.nets.count, 1,
           "5.4 rename splits: before the rename the two runs are one net")
checkEqual(tableBefore54_7.net(named: "3V3")?.endpoints.count ?? -1, 4,
           "5.4 rename splits: the unioned 3V3 net has 4 endpoints")
let canUndoBeforeNoop54_7 = doc54_7.canUndo
check(doc54_7.editLabelText(id: labelA54_7.id, text: "3V3") == false,
      "5.4 rename splits: editing a label to its current text returns false")
checkEqual(doc54_7.canUndo, canUndoBeforeNoop54_7,
           "5.4 rename splits: the no-op edit records no history")
check(doc54_7.editLabelText(id: labelB54_7.id, text: "5V") == true,
      "5.4 rename splits: renaming the second run's label returns true")
let tableAfter54_7 = table54(doc54_7.state)
checkEqual(tableAfter54_7.net(named: "3V3")?.endpoints.count ?? -1, 2,
           "5.4 rename splits: 3V3 keeps the first run's 2 endpoints")
checkEqual(tableAfter54_7.net(named: "5V")?.endpoints.count ?? -1, 2,
           "5.4 rename splits: 5V takes the renamed run's 2 endpoints")
doc54_7.undo()
let tableUndone54_7 = table54(doc54_7.state)
checkEqual(tableUndone54_7.nets.count, 1,
           "5.4 rename splits: one undo reunions the runs into a single net")
checkEqual(tableUndone54_7.net(named: "3V3")?.endpoints.count ?? -1, 4,
           "5.4 rename splits: after undo the single 3V3 net has 4 endpoints again")

// -- 8: deleting labels falls back through the remaining names --

let run54_8 = fixrRun54("R2", "R3", 25.40)
let labelA54_8 = label54("3V3", onFirstSegment(run54_8.wire, t: 0.25))
let labelB54_8 = label54("3V3", onFirstSegment(run54_8.wire, t: 0.75))
let doc54_8 = makeDoc54(SchematicState(
    symbols: [run54_8.left, run54_8.right],
    wires: [run54_8.wire], junctions: [],
    labels: [labelA54_8, labelB54_8], title: "54-8"))
doc54_8.deleteLabel(id: labelA54_8.id)
check(table54(doc54_8.state).net(named: "3V3") != nil,
      "5.4 delete fallback: with one 3V3 label left the net is still 3V3")
doc54_8.deleteLabel(id: labelB54_8.id)
check(table54(doc54_8.state).net(named: "3V3") == nil,
      "5.4 delete fallback: with both labels gone no net is named 3V3")
checkEqual(table54(doc54_8.state).net(named: "Net-1")?.endpoints.count ?? -1, 2,
           "5.4 delete fallback: the unnamed run falls back to the auto-name Net-1")

// -- 9: label-name validation (exact messages) --

check(NetLabelName.validationProblem("3V3") == nil,
      "5.4 validation: 3V3 is a valid net name")
check(NetLabelName.validationProblem("VCC_MAIN") == nil,
      "5.4 validation: VCC_MAIN is a valid net name")
check(NetLabelName.validationProblem("3V3/5V") == nil,
      "5.4 validation: 3V3/5V is valid (a slash is allowed in a single-sheet name)")
checkEqual(NetLabelName.validationProblem("MY NET") ?? "<nil>",
           "Net names can't contain spaces — join the words with an underscore instead, like VCC_MAIN.",
           "5.4 validation: a name with a space gets the spaces message verbatim")
checkEqual(NetLabelName.validationProblem("A\tB") ?? "<nil>",
           "Net names can't contain spaces — join the words with an underscore instead, like VCC_MAIN.",
           "5.4 validation: a name with a tab gets the spaces message verbatim")
checkEqual(NetLabelName.validationProblem("") ?? "<nil>",
           "A net label needs a name — type the net's name, like 3V3 or GND.",
           "5.4 validation: an empty name gets the empty message verbatim")
checkEqual(NetLabelName.validationProblem("   ") ?? "<nil>",
           "A net label needs a name — type the net's name, like 3V3 or GND.",
           "5.4 validation: an all-whitespace name gets the empty message verbatim")

// -- 10: moving a label re-anchors its name --

let runA54_10 = fixrRun54("R2", "R3", 76.20)
let runB54_10 = fixrRun54("R4", "R5", 25.40)
let label54_10 = label54("3V3", onFirstSegment(runA54_10.wire, t: 0.5))
let startPoint54_10 = label54_10.at
let doc54_10 = makeDoc54(SchematicState(
    symbols: [runA54_10.left, runA54_10.right, runB54_10.left, runB54_10.right],
    wires: [runA54_10.wire, runB54_10.wire], junctions: [],
    labels: [label54_10], title: "54-10"))
checkEqual(endpointKeys54(table54(doc54_10.state).net(named: "3V3")),
           Set(["R2|2", "R3|1"]),
           "5.4 move re-anchors: 3V3 starts on the first run")
check(doc54_10.moveLabel(id: label54_10.id, to: DPoint(x: 200, y: 200)) == true,
      "5.4 move re-anchors: moving the label to an empty point returns true")
check(table54(doc54_10.state).net(named: "3V3") == nil,
      "5.4 move re-anchors: off every wire, the label names nothing (the run is auto-named)")
check(doc54_10.moveLabel(id: label54_10.id,
                         to: onFirstSegment(runB54_10.wire, t: 0.5)) == true,
      "5.4 move re-anchors: moving the label onto the second run returns true")
checkEqual(endpointKeys54(table54(doc54_10.state).net(named: "3V3")),
           Set(["R4|2", "R5|1"]),
           "5.4 move re-anchors: 3V3 now names the second run")
doc54_10.undo()
doc54_10.undo()
check(doc54_10.state.labels.first { $0.id == label54_10.id }?.at == startPoint54_10,
      "5.4 move re-anchors: two undos (one per move) return the label to its start point")

// -- 11: Clean Up Sheet keeps a pin-anchored, labelled wire --

let r54_11 = fixr54("R2", 25.40, 25.40)
let pin1_54_11 = pinPoint(def: fixrDef, placed: r54_11, number: "1")
let wire54_11 = WireItem(
    id: UUID(),
    points: [pin1_54_11, DPoint(x: pin1_54_11.x - 10.16, y: pin1_54_11.y)])
let label54_11 = label54("KEEP", onFirstSegment(wire54_11, t: 0.5))
let state11_54 = SchematicState(
    symbols: [r54_11], wires: [wire54_11], junctions: [],
    labels: [label54_11], title: "54-11")
let doc54_11 = makeDoc54(state11_54)
let allPinPoints54_11: [DPoint] = state11_54.symbols.flatMap { placed in
    guard let def = defsByKey["\(placed.library)|\(placed.symbolName)"]
    else { return [DPoint]() }
    return SymbolDrawList.pinWorldPoints(def: def, placed: placed).map(\.point)
}
let cleanup54_11 = doc54_11.cleanUpSheet(pinPoints: allPinPoints54_11)
checkEqual(cleanup54_11["isolatedWires"] ?? -1, 0,
           "5.4 cleanup safety: the pin-anchored labelled wire is not isolated")
check(doc54_11.state.wires.count == 1
      && doc54_11.state.wires.first?.id == wire54_11.id,
      "5.4 cleanup safety: the wire is still present after Clean Up Sheet")
check(doc54_11.state.labels.count == 1
      && doc54_11.state.labels.first?.id == label54_11.id
      && doc54_11.state.labels.first?.text == "KEEP",
      "5.4 cleanup safety: the KEEP label is unchanged by Clean Up Sheet")

// -- 12: the label-named net reaches the board model --

let board54_12 = PCBBoardModelBuilder.build(
    table: table1_54,
    resolveSymbol: { library, name in defsByKey["\(library)|\(name)"] },
    resolveFootprint: { key in
        guard let entry = FootprintMatcher.entry(forResolutionKey: key, in: entries),
              let parsed = entry.parsed else { return nil }
        return (entry: entry, parsed: parsed)
    })
check(board54_12.netNames.contains("3V3"),
      "5.4 board: the board model's net names contain 3V3")

// -- 13: label persistence (round-trip + pre-5.4 JSON) --

do {
    let data54 = try JSONEncoder().encode(state1_54)
    let decoded54 = try JSONDecoder().decode(SchematicState.self, from: data54)
    checkEqual(decoded54.labels.count, 1,
               "5.4 persistence: the encoded state decodes with its one label")
    check(decoded54.labels.first?.id == label1_54.id
          && decoded54.labels.first?.at == label1_54.at
          && decoded54.labels.first?.text == label1_54.text,
          "5.4 persistence: the label round-trips exactly (id, at, text)")
} catch {
    check(false, "5.4 persistence: the state round-trip threw \(error)")
}
let legacyJSON54 = """
{"symbols":[],"wires":[],"junctions":[],"title":"Legacy54"}
"""
do {
    let legacy54 = try JSONDecoder().decode(
        SchematicState.self, from: Data(legacyJSON54.utf8))
    check(legacy54.labels.isEmpty,
          "5.4 persistence: legacy JSON with no labels key loads with no labels")
} catch {
    check(false, "5.4 persistence: the legacy literal threw \(error)")
}

// MARK: - Result

print("BoardFixture: \(passCount) passed, \(failCount) failed")
if failCount > 0 {
    print("BOARD FIXTURE FAILED")
    exit(1)
}
print("BOARD FIXTURE OK")
