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

// MARK: - Result

print("BoardFixture: \(passCount) passed, \(failCount) failed")
if failCount > 0 {
    print("BOARD FIXTURE FAILED")
    exit(1)
}
print("BOARD FIXTURE OK")
