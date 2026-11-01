import Foundation

/// FootprintDump — headless footprint audit harness for PadCB.
///
/// Compiled together with the app's REAL footprint sources
/// (App/PadCB/SExpr.swift, App/PadCB/KiCadFootprint.swift) so the
/// counts dumped here are produced by the exact parser the app
/// uses — not by a port.
///
/// Usage: FootprintDump <fixturesDir>
///
/// Prints one line per *.kicad_mod file (sorted by file name):
///   <file>: name=<name> pads=<count> padNumbers=<comma list>
///           graphics=<count> thruHole=<count>
///           customPrimitives=<total primitives across pads>
///
/// Validates the known fixtures:
///   SOIC-8_SMD:         8 pads, 0 thru-hole
///   DIP-8_THT:          8 pads, 8 thru-hole
///   Custom_Heatsink_Pad: 3 pads, >= 2 custom primitives
///
/// On any failure (read error, parse error, missing fixture, or a
/// count mismatch) prints FAIL lines to stderr and exits 1.
/// Otherwise prints "FOOTPRINT FIXTURES OK" and exits 0.

func eprint(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count == 2 else {
    eprint("usage: FootprintDump <fixturesDir>")
    exit(2)
}
let fixturesDir = args[1]

let fm = FileManager.default
let dirURL = URL(fileURLWithPath: fixturesDir)
let files: [String]
do {
    files = try fm.contentsOfDirectory(atPath: dirURL.path)
        .filter { $0.hasSuffix(".kicad_mod") }
        .sorted()
} catch {
    eprint("FAIL: cannot list \(fixturesDir): \(error)")
    exit(1)
}

if files.isEmpty {
    eprint("FAIL: no .kicad_mod fixtures found in \(fixturesDir)")
    exit(1)
}

/// Expected counts for a fixture, keyed by file base name.
/// `minCustomPrimitives` is a lower bound (nil = not checked).
struct Expectation {
    var pads: Int
    var thruHole: Int?
    var minCustomPrimitives: Int?
}

let expectations: [String: Expectation] = [
    "SOIC-8_SMD": Expectation(pads: 8, thruHole: 0, minCustomPrimitives: nil),
    "DIP-8_THT": Expectation(pads: 8, thruHole: 8, minCustomPrimitives: nil),
    "Custom_Heatsink_Pad": Expectation(pads: 3, thruHole: nil, minCustomPrimitives: 2),
]

var failures: [String] = []
var seen: Set<String> = []

for file in files {
    let baseName = String(file.dropLast(".kicad_mod".count))
    seen.insert(baseName)
    let path = dirURL.appendingPathComponent(file).path
    let text: String
    do {
        text = try String(contentsOfFile: path, encoding: .utf8)
    } catch {
        let message = "FAIL: \(file): read failed: \(error)"
        eprint(message)
        failures.append(message)
        continue
    }
    let footprint: KiCadFootprint
    do {
        footprint = try KiCadFootprint.parse(name: baseName, text: text)
    } catch {
        let message = "FAIL: \(file): parse failed: \(error)"
        eprint(message)
        failures.append(message)
        continue
    }

    let thruHoleCount = footprint.pads.filter { $0.type == .thruHole }.count
    let customPrimitiveCount = footprint.pads.reduce(0) { $0 + $1.primitives.count }
    let padNumbers = footprint.pads.map { $0.number }.joined(separator: ",")
    print("\(file): name=\(footprint.name) pads=\(footprint.pads.count) "
        + "padNumbers=\(padNumbers) graphics=\(footprint.graphics.count) "
        + "thruHole=\(thruHoleCount) customPrimitives=\(customPrimitiveCount)")

    if let expectation = expectations[baseName] {
        if footprint.pads.count != expectation.pads {
            let message = "FAIL: \(file): expected \(expectation.pads) pads, "
                + "got \(footprint.pads.count)"
            eprint(message)
            failures.append(message)
        }
        if let expectedThruHole = expectation.thruHole,
           thruHoleCount != expectedThruHole {
            let message = "FAIL: \(file): expected \(expectedThruHole) thru-hole pads, "
                + "got \(thruHoleCount)"
            eprint(message)
            failures.append(message)
        }
        if let minCustom = expectation.minCustomPrimitives,
           customPrimitiveCount < minCustom {
            let message = "FAIL: \(file): expected >= \(minCustom) custom primitives, "
                + "got \(customPrimitiveCount)"
            eprint(message)
            failures.append(message)
        }
    }
}

for baseName in expectations.keys.sorted() where !seen.contains(baseName) {
    let message = "FAIL: expected fixture \(baseName).kicad_mod not found in \(fixturesDir)"
    eprint(message)
    failures.append(message)
}

if !failures.isEmpty {
    eprint("FAIL: \(failures.count) footprint fixture check(s) failed")
    exit(1)
}

print("FOOTPRINT FIXTURES OK")
