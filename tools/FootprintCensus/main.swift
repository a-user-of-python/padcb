import Foundation

/// FootprintCensus — full-corpus parse census for the bundled official
/// KiCad footprint libraries, using the app's REAL parser
/// (App/PadCB/SExpr.swift + App/PadCB/KiCadFootprint.swift — the code
/// the app ships), the same discipline as the symbol geometry audit.
///
/// Usage: FootprintCensus <footprintsDir> <indexOut.json>
///
/// Walks <footprintsDir> recursively for *.kicad_mod, parses every
/// file, and:
/// - prints totals: libraries (.pretty groups), footprints, pads,
///   graphics, through-hole pads, custom pads, name mismatches;
/// - prints every failure (unparseable file, or a file with no pads
///   AND no graphics) to stderr;
/// - aggregates the parser's skipped-node counts (model/zone/…)
///   so the "not modelled" list is measured, not guessed;
/// - writes the bundle index JSON the app loads at launch
///   (group/name/file/description/tags/pad+graphic counts);
/// - exits 1 when any file failed, 0 when the census is clean.

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

func eprint(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

let args = CommandLine.arguments
guard args.count == 3 else {
    eprint("usage: FootprintCensus <footprintsDir> <indexOut.json>")
    exit(2)
}
let root = URL(fileURLWithPath: args[1])
let indexOut = URL(fileURLWithPath: args[2])

var urls: [URL] = []
if let enumerator = FileManager.default.enumerator(
    at: root, includingPropertiesForKeys: [.isRegularFileKey],
    options: [.skipsHiddenFiles]) {
    for case let url as URL in enumerator {
        if url.pathExtension.lowercased() == "kicad_mod" { urls.append(url) }
    }
}
urls.sort { $0.path < $1.path }

func groupName(for url: URL) -> String {
    let parent = url.deletingLastPathComponent()
    if parent.path == root.path { return root.lastPathComponent }
    var name = parent.lastPathComponent
    if name.lowercased().hasSuffix(".pretty") {
        name = String(name.dropLast(".pretty".count))
    }
    return name
}

func relativePath(of url: URL) -> String {
    let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
    return url.path.hasPrefix(rootPath)
        ? String(url.path.dropFirst(rootPath.count))
        : url.lastPathComponent
}

var groups = Set<String>()
var totalPads = 0
var totalGraphics = 0
var totalThruHole = 0
var totalCustomPads = 0
var totalCustomPrimitives = 0
var nameMismatches = 0
var skippedTotals: [String: Int] = [:]
var failures: [String] = []
var indexRows: [String] = []

for url in urls {
    let baseName = url.deletingPathExtension().lastPathComponent
    let group = groupName(for: url)
    groups.insert(group)
    guard let data = try? Data(contentsOf: url) else {
        failures.append("\(relativePath(of: url)): unreadable file")
        continue
    }
    let text = String(decoding: data, as: UTF8.self)
    do {
        let fp = try KiCadFootprint.parse(name: baseName, text: text)
        guard !fp.pads.isEmpty || !fp.graphics.isEmpty else {
            failures.append("\(relativePath(of: url)): parsed but contains no pads or graphics")
            continue
        }
        if fp.name != baseName { nameMismatches += 1 }
        totalPads += fp.pads.count
        totalGraphics += fp.graphics.count
        totalThruHole += fp.pads.filter { $0.isThroughHole }.count
        let customPads = fp.pads.filter { $0.shape == .custom }
        totalCustomPads += customPads.count
        totalCustomPrimitives += customPads.reduce(0) { $0 + $1.primitives.count }
        for (kind, count) in fp.skippedNodeCounts {
            skippedTotals[kind, default: 0] += count
        }
        indexRows.append(
            "{\"group\":\(jstr(group)),\"name\":\(jstr(baseName)),"
            + "\"file\":\(jstr(relativePath(of: url))),"
            + "\"description\":\(jstr(fp.description)),"
            + "\"tags\":[\(fp.tags.map(jstr).joined(separator: ","))],"
            + "\"pads\":\(fp.pads.count),\"graphics\":\(fp.graphics.count)}")
    } catch {
        failures.append("\(relativePath(of: url)): \(error)")
    }
}

let indexJSON = "[\n" + indexRows.joined(separator: ",\n") + "\n]\n"
do {
    try indexJSON.write(to: indexOut, atomically: true, encoding: .utf8)
} catch {
    eprint("FootprintCensus: cannot write index: \(error)")
    exit(1)
}

print("libraries: \(groups.count)")
print("footprints: \(urls.count)")
print("parsed OK: \(indexRows.count)")
print("pads: \(totalPads)")
print("graphics: \(totalGraphics)")
print("through-hole pads: \(totalThruHole)")
print("custom pads: \(totalCustomPads) (primitives: \(totalCustomPrimitives))")
print("name mismatches (file base name vs internal name): \(nameMismatches)")
let skippedSummary = skippedTotals
    .sorted { $0.value > $1.value }
    .map { "\($0.key) x\($0.value)" }
    .joined(separator: ", ")
print("skipped node kinds: \(skippedSummary.isEmpty ? "none" : skippedSummary)")
print("failures: \(failures.count)")
for failure in failures { eprint("FAIL: \(failure)") }
exit(failures.isEmpty ? 0 : 1)
