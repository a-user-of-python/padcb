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

// MARK: - Result

print("BoardFixture: \(passCount) passed, \(failCount) failed")
if failCount > 0 {
    print("BOARD FIXTURE FAILED")
    exit(1)
}
print("BOARD FIXTURE OK")
