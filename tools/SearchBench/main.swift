import Foundation

// SearchBench — before/after evidence for the part-3 search rewrite.
//
// Compiles with ONLY App/PadCB/SearchEngine.swift + Foundation:
//
//   swiftc -O -o /tmp/SearchBench \
//     App/PadCB/SearchEngine.swift tools/SearchBench/main.swift
//   python3 tools/search_fixtures.py --symbols-dir <merged symbols> \
//     --footprint-index <FootprintIndex.json> --out-dir /tmp/searchbench
//   /tmp/SearchBench /tmp/searchbench/symbols.json \
//                    /tmp/searchbench/footprints.json
//
// For each corpus it runs a battery of realistic queries. For every
// query it computes BOTH the pre-part-3 semantics
// (SearchSemantics.referenceMatches — per-field
// localizedCaseInsensitiveContains, original order) and the new
// SearchIndex.search, asserts the result SETS are equal (any mismatch
// is a loud report and exit 1), then times both implementations in
// this same process (>= 15 repetitions each, medians reported) so the
// OLD number is measured, not remembered.

func eprint(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

let args = CommandLine.arguments
guard args.count == 3 else {
    eprint("usage: SearchBench <symbols.json> <footprints.json>")
    exit(2)
}

// MARK: - Query batteries (>= 40 per corpus: names, substrings,
// keywords, case variants, multi-word, part numbers, single letters)

let symbolQueries: [String] = [
    "R", "C", "L", "D", "Q", "U",
    "a", "e", "x", "z",
    "74HC00", "74hc00", "74HC", "1N4148", "1n4148", "1N4007",
    "LM358", "lm358", "NE555", "555", "ATmega328", "ESP32", "esp32",
    "STM32", "PIC16", "BC547", "2N7002", "IRF540",
    "op amp", "OP AMP", "voltage regulator", "Voltage Regulator",
    "transistor", "mosfet", "MOSFET", "resistor", "capacitor",
    "inductor", "diode", "zener", "crystal", "oscillator", "relay",
    "fuse", "switch", "battery", "connector", "LED", "led",
    "ground", "GND", "gnd", "power", "USB", "usb", "HDMI",
    "ethernet", "SPI", "I2C", "uart", "UART", "ADC", "DAC",
    "bridge rectifier", "schottky", "photodiode", "thermistor",
    "  resistor  ", "no-such-symbol-zzz",
]

let footprintQueries: [String] = [
    "SOIC-8", "soic-8", "SOIC", "SOT-23", "SOT", "sot-223",
    "R_0603", "0603", "0805", "1206", "C_0603", "L_0805",
    "QFN", "qfn-32", "BGA", "DIP", "PDIP", "TQFP", "LQFP-48",
    "PinHeader", "pin header", "PinSocket", "USB", "usb-c", "HDMI",
    "resistor", "capacitor", "inductor", "LED", "led",
    "MountingHole", "mounting hole", "terminal", "TerminalBlock",
    "connector", "JST", "jst", "Molex", "RJ45", "ethernet",
    "a", "e", "1", "2", "-", "_",
    "D_PAK", "TO-220", "TO220", "Crystal", "crystal", "SMD", "smd",
    "  0603  ", "no-such-footprint-zzz",
]

// MARK: - Helpers

func loadRows(_ path: String) -> [SearchRow] {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let rows = try? JSONDecoder().decode([SearchRow].self, from: data)
    else {
        eprint("SearchBench: cannot load SearchRow JSON from \(path)")
        exit(2)
    }
    return rows
}

func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let mid = sorted.count / 2
    return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let index = min(sorted.count - 1, max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1))
    return sorted[index]
}

/// Median wall-clock milliseconds over `repetitions` runs.
func timeMedianMs(repetitions: Int, _ body: () -> [Int]) -> (medianMs: Double, count: Int) {
    var times: [Double] = []
    var count = 0
    for _ in 0..<repetitions {
        let start = Date()
        let result = body()
        times.append(Date().timeIntervalSince(start) * 1000)
        count = result.count
    }
    return (median(times), count)
}

func fmt(_ ms: Double) -> String {
    ms >= 100 ? String(format: "%.1f", ms)
        : (ms >= 10 ? String(format: "%.2f", ms) : String(format: "%.3f", ms))
}

func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

// MARK: - Per-corpus run

var totalMismatches = 0

func runCorpus(name: String, path: String, queries: [String]) {
    let rows = loadRows(path)
    let index = SearchIndex(rows: rows)
    print("== \(name): \(rows.count) rows, \(queries.count) queries ==")

    // Correctness first: set equality per query, original vs new.
    var mismatches = 0
    for query in queries {
        let reference = SearchSemantics.referenceMatches(rows: rows, query: query)
        let searched = index.search(query)
        if Set(reference) != Set(searched) || reference.count != searched.count {
            mismatches += 1
            totalMismatches += 1
            let onlyReference = Set(reference).subtracting(searched).sorted()
            let onlyNew = Set(searched).subtracting(reference).sorted()
            eprint("MISMATCH [\(name)] query \(query.debugDescription): "
                + "reference \(reference.count) vs new \(searched.count); "
                + "only-reference \(onlyReference.prefix(10)) "
                + "only-new \(onlyNew.prefix(10))")
        }
    }
    if mismatches == 0 {
        print("correctness: all \(queries.count) queries — result sets EQUAL")
    } else {
        eprint("correctness: \(mismatches)/\(queries.count) queries MISMATCHED")
    }

    // Timing: the old semantics and the new index, same process.
    let repetitions = 15
    print(pad("query", 24) + pad("matches", 9) + pad("old ms", 11)
        + pad("new ms", 11) + "speedup")
    var oldMedians: [Double] = []
    var newMedians: [Double] = []
    for query in queries {
        let old = timeMedianMs(repetitions: repetitions) {
            SearchSemantics.referenceMatches(rows: rows, query: query)
        }
        let new = timeMedianMs(repetitions: repetitions) {
            index.search(query)
        }
        oldMedians.append(old.medianMs)
        newMedians.append(new.medianMs)
        let speedup = new.medianMs > 0 ? old.medianMs / new.medianMs : 0
        print(pad(query.debugDescription, 24)
            + pad("\(new.count)", 9)
            + pad(fmt(old.medianMs), 11)
            + pad(fmt(new.medianMs), 11)
            + String(format: "%.1fx", speedup))
    }
    print("-- \(name) summary over \(queries.count) queries "
        + "(\(repetitions) reps each, medians per query) --")
    print("old: median \(fmt(median(oldMedians))) ms, "
        + "p95 \(fmt(percentile(oldMedians, 0.95))) ms, "
        + "max \(fmt(oldMedians.max() ?? 0)) ms")
    print("new: median \(fmt(median(newMedians))) ms, "
        + "p95 \(fmt(percentile(newMedians, 0.95))) ms, "
        + "max \(fmt(newMedians.max() ?? 0)) ms")
    if median(newMedians) > 0 {
        print("overall median speedup: "
            + String(format: "%.1fx", median(oldMedians) / median(newMedians)))
    }
    print("")
}

runCorpus(name: "symbols", path: args[1], queries: symbolQueries)
runCorpus(name: "footprints", path: args[2], queries: footprintQueries)

if totalMismatches > 0 {
    eprint("SEARCHBENCH FAILED: \(totalMismatches) set mismatch(es) — "
        + "the new search does NOT preserve the old result sets")
    exit(1)
}
print("SEARCHBENCH PASSED: result sets equal for every query in both corpora")
