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
        .contains("all 8 rules pass"),
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
private struct LegacyPointer52 {
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
check(admitted52.count >= 55 && admitted52.count <= 65,
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

// MARK: - Result

print("BoardFixture: \(passCount) passed, \(failCount) failed")
if failCount > 0 {
    print("BOARD FIXTURE FAILED")
    exit(1)
}
print("BOARD FIXTURE OK")
