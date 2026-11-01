import Foundation

/// MatchCensus — symbol <-> footprint matching coverage measurement
/// for PadCB part 3, using the app's REAL matcher and parsers
/// (FootprintMatcher + KiCadLibrary + KiCadFootprint), the same
/// discipline as the geometry / footprint censuses.
///
/// Usage:
///   MatchCensus <symbolsDir> <footprintsDir>
///     [fixtureSymbolsDir fixtureFootprintsDir
///      fixtureCustomSymbols fixtureCustomFootprints]
///
/// Compile (macOS swiftc):
///   xcrun swiftc -O -o /tmp/MatchCensus \
///     App/PadCB/SExpr.swift App/PadCB/KiCadSymbol.swift \
///     App/PadCB/KiCadFootprint.swift App/PadCB/FootprintStore.swift \
///     App/PadCB/FootprintMatcher.swift App/PadCB/PadCBPaths.swift \
///     tools/MatchCensus/main.swift
/// (PadCBPaths.swift is Foundation-only and is pulled in because
/// FootprintStore references it; the census itself constructs
/// FootprintEntry values directly and never touches the store's
/// scanning paths.)
///
/// CORPUS MODE parses every merged .kicad_sym in <symbolsDir> and
/// every .kicad_mod under <footprintsDir> (.pretty groups), computes
/// FootprintMatcher.match(choiceKey: nil) for EVERY symbol, and
/// prints the coverage table. It is a measurement: exit 0 always,
/// EXCEPT exit 1 when parsing any library / footprint fails
/// wholesale. Power symbols are counted in the main table AND
/// reported separately.
///
/// Per-symbol matcher calls run over a REDUCED entry list that
/// provably yields identical results (see reducedEntryIndices):
/// resolveReference depends only on entries sharing the reference's
/// name, and a filter candidate must carry the pattern's literal
/// prefix — so non-matching entries can affect neither the
/// resolution, the uniqueness counts, nor the ranked candidate list.
///
/// FIXTURE MODE (the four extra arguments) additionally loads the
/// hand-written fixture libraries in tools/match-fixtures and checks
/// the cross-namespace assertions (custom <-> bundled), printing
/// PASS/FAIL per assertion and exiting 1 on any failure. Fixture
/// numbers are reported separately from the corpus numbers.
/// fixtureCustomSymbols / fixtureCustomFootprints may each be a
/// single file or a directory.

func eprint(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

func isDirectory(_ url: URL) -> Bool {
    var flag: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &flag)
        && flag.boolValue
}

func cleanedProperty(_ raw: String?) -> String? {
    guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty, value != "~" else { return nil }
    return value
}

// MARK: - Loading

struct LoadedLibrary {
    var key: String // "Device" (bundled) or "user:Device" (custom)
    var symbols: [String: KiCadSymbolDef]
    var parseErrorCount: Int
}

var wholesaleFailures: [String] = []

/// Parses every .kicad_sym at the top level of `arg` (or `arg` itself
/// when it is a single file). `keyPrefix` is "" for bundled-style
/// libraries and "user:" for custom ones, mirroring the app's
/// library keys — def.library is the key, which is what the
/// matcher's source tie-break reads.
func loadSymbolLibraries(arg: URL, keyPrefix: String) -> [LoadedLibrary] {
    let fm = FileManager.default
    var files: [URL] = []
    if isDirectory(arg) {
        files = ((try? fm.contentsOfDirectory(
            at: arg, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension.lowercased() == "kicad_sym" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    } else if fm.fileExists(atPath: arg.path) {
        files = [arg]
    }
    if files.isEmpty {
        wholesaleFailures.append("\(arg.path): no .kicad_sym files found")
        return []
    }
    var libraries: [LoadedLibrary] = []
    for file in files {
        let baseName = file.deletingPathExtension().lastPathComponent
        guard let data = try? Data(contentsOf: file) else {
            wholesaleFailures.append("\(file.path): unreadable file")
            continue
        }
        let text = String(decoding: data, as: UTF8.self)
        do {
            let library = try KiCadLibrary.parse(name: keyPrefix + baseName, text: text)
            libraries.append(LoadedLibrary(key: keyPrefix + baseName,
                                           symbols: library.symbols,
                                           parseErrorCount: library.parseErrors.count))
        } catch {
            wholesaleFailures.append("\(file.path): parse failed wholesale (\(error))")
        }
    }
    return libraries
}

/// Walks `arg` recursively for .kicad_mod (or takes `arg` itself as a
/// single footprint file) and builds FootprintEntry values directly.
/// Group = the .pretty-style parent folder (suffix stripped); a file
/// loose in the root groups under the root folder's name — the same
/// rule FootprintStore/FootprintCensus use.
func loadFootprintEntries(arg: URL, source: FootprintSource) -> [FootprintEntry] {
    let fm = FileManager.default
    var urls: [URL] = []
    if isDirectory(arg) {
        if let enumerator = fm.enumerator(
            at: arg, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator
            where url.pathExtension.lowercased() == "kicad_mod" {
                urls.append(url)
            }
        }
    } else if fm.fileExists(atPath: arg.path) {
        urls = [arg]
    }
    if urls.isEmpty {
        wholesaleFailures.append("\(arg.path): no .kicad_mod files found")
        return []
    }
    urls.sort { $0.path < $1.path }

    func groupName(for url: URL) -> String {
        let parent = url.deletingLastPathComponent()
        if isDirectory(arg), parent.path == arg.path { return arg.lastPathComponent }
        var name = parent.lastPathComponent
        if name.lowercased().hasSuffix(".pretty") {
            name = String(name.dropLast(".pretty".count))
        }
        return name.isEmpty ? "Footprints" : name
    }
    func relativePath(of url: URL) -> String {
        guard isDirectory(arg) else { return url.lastPathComponent }
        let rootPath = arg.path.hasSuffix("/") ? arg.path : arg.path + "/"
        return url.path.hasPrefix(rootPath)
            ? String(url.path.dropFirst(rootPath.count))
            : url.lastPathComponent
    }

    var entries: [FootprintEntry] = []
    for url in urls {
        let baseName = url.deletingPathExtension().lastPathComponent
        guard let data = try? Data(contentsOf: url) else {
            wholesaleFailures.append("\(relativePath(of: url)): unreadable file")
            continue
        }
        let text = String(decoding: data, as: UTF8.self)
        do {
            let fp = try KiCadFootprint.parse(name: baseName, text: text)
            entries.append(FootprintEntry(
                source: source,
                group: groupName(for: url),
                name: baseName,
                fileName: url.lastPathComponent,
                relativePath: relativePath(of: url),
                url: url,
                description: fp.description,
                tags: fp.tags,
                padCount: fp.pads.count,
                distinctPadCount: FootprintStore.distinctPadCount(of: fp),
                graphicCount: fp.graphics.count,
                parsed: fp))
        } catch {
            wholesaleFailures.append("\(relativePath(of: url)): parse failed (\(error))")
        }
    }
    return entries
}

// MARK: - Reduced matcher input (equivalence-preserving)

/// Indexes over one entry list that let the census hand
/// FootprintMatcher.match a small subset per symbol with IDENTICAL
/// results to the full list:
/// - resolveReference(raw) can only return / count entries whose
///   name equals the reference's name part, so every entry with that
///   name is included (exact-match + both uniqueness counts and the
///   user-first rule are preserved, in original list order).
/// - A filter candidate for a pattern must match the pattern, and an
///   anchored wildcard match must begin with the pattern's literal
///   prefix (the characters before the first `*`/`?`), so the
///   prefix-bucket prefilter drops only entries that cannot match.
///   The candidate ranking depends only on the candidates
///   themselves, so it is unchanged.
/// - A wildcard-free single filter (the filterExact path) resolves
///   through resolveReference, so its name part's entries are
///   included too.
struct EntryIndex {
    var entries: [FootprintEntry]
    var byName: [String: [Int]] // lowercased footprint name -> indices
    var candName: [String] // lowercased name, parallel to entries
    var candFull: [String] // lowercased "group:name", parallel
    var namePrefix1: [String: [Int]]
    var namePrefix2: [String: [Int]]
    var fullPrefix1: [String: [Int]]
    var fullPrefix2: [String: [Int]]

    init(entries: [FootprintEntry]) {
        self.entries = entries
        var byName: [String: [Int]] = [:]
        var candName: [String] = []
        var candFull: [String] = []
        for (i, entry) in entries.enumerated() {
            let name = entry.name.lowercased()
            byName[name, default: []].append(i)
            candName.append(name)
            candFull.append(entry.group.lowercased() + ":" + name)
        }
        self.byName = byName
        self.candName = candName
        self.candFull = candFull
        func prefixIndex(_ strings: [String], _ keyLength: Int) -> [String: [Int]] {
            var dict: [String: [Int]] = [:]
            for (i, string) in strings.enumerated() {
                dict[String(string.prefix(keyLength)), default: []].append(i)
            }
            return dict
        }
        namePrefix1 = prefixIndex(candName, 1)
        namePrefix2 = prefixIndex(candName, 2)
        fullPrefix1 = prefixIndex(candFull, 1)
        fullPrefix2 = prefixIndex(candFull, 2)
    }

    /// Indices of entries carrying a given footprint name (any group).
    func indices(named name: String) -> [Int] {
        byName[name.lowercased()] ?? []
    }

    /// Indices of entries whose candidate string for `pattern`
    /// (name-only or "group:name", per the ":" rule) starts with the
    /// pattern's literal prefix — a superset of the true matches.
    func candidateIndices(forPattern pattern: String) -> [Int] {
        let lowered = pattern.lowercased()
        let firstWildcard = lowered.firstIndex(where: { $0 == "*" || $0 == "?" })
        let literalPrefix = firstWildcard.map { String(lowered[..<$0]) } ?? lowered
        if literalPrefix.isEmpty { return Array(entries.indices) }
        let useFull = pattern.contains(":")
        let strings = useFull ? candFull : candName
        let keyLength = min(2, literalPrefix.count)
        let dict = useFull
            ? (keyLength == 2 ? fullPrefix2 : fullPrefix1)
            : (keyLength == 2 ? namePrefix2 : namePrefix1)
        let bucket = dict[String(literalPrefix.prefix(keyLength))] ?? []
        return bucket.filter { strings[$0].hasPrefix(literalPrefix) }
    }

    /// The reduced, original-order entry list for one symbol.
    func reducedEntries(for def: KiCadSymbolDef) -> [FootprintEntry] {
        var indices = Set<Int>()
        if let raw = cleanedProperty(def.property("Footprint")) {
            let namePart = raw.firstIndex(of: ":")
                .map { String(raw[raw.index(after: $0)...]) } ?? raw
            indices.formUnion(self.indices(named: namePart))
        }
        for pattern in def.fpFilters {
            indices.formUnion(candidateIndices(forPattern: pattern))
            if !pattern.contains("*"), !pattern.contains("?") {
                let namePart = pattern.firstIndex(of: ":")
                    .map { String(pattern[pattern.index(after: $0)...]) } ?? pattern
                indices.formUnion(self.indices(named: namePart))
            }
        }
        return indices.sorted().map { entries[$0] }
    }
}

// MARK: - Stats

struct Stats {
    var total = 0
    var withFootprintProperty = 0
    var propertyResolved = 0
    var propertyUnresolvedLibraryAbsent = 0
    var propertyUnresolvedNameAbsent = 0
    var filterExactResolved = 0
    var filtersPresent = 0
    var withCandidates = 0
    var withPinExactCandidate = 0
    var fullyUnmatched = 0
}

func printStats(_ title: String, _ stats: Stats) {
    func row(_ label: String, _ value: Int) {
        print("  \(label.padding(toLength: 46, withPad: " ", startingAt: 0))\(value)")
    }
    print(title)
    row("total symbols", stats.total)
    row("with Footprint property", stats.withFootprintProperty)
    row("property resolved", stats.propertyResolved)
    row("property unresolved — library absent", stats.propertyUnresolvedLibraryAbsent)
    row("property unresolved — name absent/ambiguous", stats.propertyUnresolvedNameAbsent)
    row("filter-exact resolved", stats.filterExactResolved)
    row("with ki_fp_filters", stats.filtersPresent)
    row("≥1 filter candidate", stats.withCandidates)
    row("≥1 pin-exact candidate", stats.withPinExactCandidate)
    row("fully unmatched", stats.fullyUnmatched)
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count == 3 || args.count == 7 else {
    eprint("usage: MatchCensus <symbolsDir> <footprintsDir> "
        + "[fixtureSymbolsDir fixtureFootprintsDir fixtureCustomSymbols fixtureCustomFootprints]")
    exit(2)
}
let symbolsDir = URL(fileURLWithPath: args[1])
let footprintsDir = URL(fileURLWithPath: args[2])

// Corpus mode ------------------------------------------------------------

let corpusLibraries = loadSymbolLibraries(arg: symbolsDir, keyPrefix: "")
let corpusEntries = loadFootprintEntries(arg: footprintsDir, source: .bundled)
let entryIndex = EntryIndex(entries: corpusEntries)
let corpusGroups = Set(corpusEntries.map { $0.group.lowercased() })

var stats = Stats()
var powerStats = Stats()
var powerTotal = 0
var divergenceCount = 0
var unresolvedFrequencies: [String: Int] = [:]
var symbolParseErrors = 0

func absorb(def: KiCadSymbolDef, match: FootprintMatch, into stats: inout Stats) {
    stats.total += 1
    let hasProperty = cleanedProperty(def.property("Footprint")) != nil
    if hasProperty { stats.withFootprintProperty += 1 }
    if !def.fpFilters.isEmpty { stats.filtersPresent += 1 }
    switch match.kind {
    case .property:
        stats.propertyResolved += 1
    case .filterExact:
        stats.filterExactResolved += 1
    case .instanceChoice, nil:
        break
    }
    if hasProperty, match.kind != .property,
       let raw = cleanedProperty(def.property("Footprint")) {
        // Split the unresolved bucket: library absent (the reference
        // names a group no known footprint lives in) vs name absent /
        // ambiguous (library present, footprint not — or not unique).
        if let colon = raw.firstIndex(of: ":") {
            let group = String(raw[raw.startIndex..<colon]).lowercased()
            if !corpusGroups.contains(group) {
                stats.propertyUnresolvedLibraryAbsent += 1
            } else {
                stats.propertyUnresolvedNameAbsent += 1
            }
        } else {
            stats.propertyUnresolvedNameAbsent += 1
        }
        unresolvedFrequencies[raw, default: 0] += 1
    }
    if !match.candidates.isEmpty { stats.withCandidates += 1 }
    if match.candidates.contains(where: { $0.pinCountMatches }) {
        stats.withPinExactCandidate += 1
    }
    if match.kind == nil, match.candidates.isEmpty {
        stats.fullyUnmatched += 1
    }
}

for library in corpusLibraries {
    symbolParseErrors += library.parseErrorCount
    for def in library.symbols.values {
        let match = FootprintMatcher.match(
            def: def, choiceKey: nil,
            entries: entryIndex.reducedEntries(for: def))
        absorb(def: def, match: match, into: &stats)
        if def.isPower {
            powerTotal += 1
            absorb(def: def, match: match, into: &powerStats)
        }
        // Inheritance divergence: this symbol extends a parent whose
        // effective ki_fp_filters differ from its own effective
        // value. (Both sides are resolved defs, so an inherited
        // value always compares equal; a difference means the
        // derived symbol overrode the parent's filters.)
        if let parentName = def.extendsName,
           let parent = library.symbols[parentName],
           parent.fpFilters != def.fpFilters {
            divergenceCount += 1
        }
    }
}

print("== MatchCensus — corpus ==")
print("symbol libraries: \(corpusLibraries.count) "
    + "(\(corpusLibraries.reduce(0) { $0 + $1.symbols.count }) symbols, "
    + "\(symbolParseErrors) per-symbol parse notes)")
print("footprint entries: \(corpusEntries.count) in \(corpusGroups.count) groups")
printStats("All symbols:", stats)
print("  power symbols (subset of the above)          \(powerTotal)")
printStats("Power symbols only:", powerStats)
print("  extends-parent ki_fp_filters divergence     \(divergenceCount)")
print("Top unresolved Footprint references:")
for (reference, count) in unresolvedFrequencies
    .sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key })
    .prefix(10) {
    print("  \(reference) ×\(count)")
}
if unresolvedFrequencies.isEmpty { print("  (none)") }

// Fixture mode -----------------------------------------------------------

var fixtureFailures = 0
if args.count == 7 {
    let fixtureBundledSymbols = loadSymbolLibraries(
        arg: URL(fileURLWithPath: args[3]), keyPrefix: "")
    let fixtureBundledEntries = loadFootprintEntries(
        arg: URL(fileURLWithPath: args[4]), source: .bundled)
    let fixtureCustomSymbols = loadSymbolLibraries(
        arg: URL(fileURLWithPath: args[5]), keyPrefix: "user:")
    let fixtureUserEntries = loadFootprintEntries(
        arg: URL(fileURLWithPath: args[6]), source: .user)

    // The store's combined order: user entries first, then bundled.
    let combined = fixtureUserEntries + fixtureBundledEntries
    let bundledDefs = Dictionary(
        uniqueKeysWithValues: fixtureBundledSymbols.flatMap { lib in
            lib.symbols.values.map { ($0.name, $0) }
        })
    let customDefs = Dictionary(
        uniqueKeysWithValues: fixtureCustomSymbols.flatMap { lib in
            lib.symbols.values.map { ($0.name, $0) }
        })

    print("")
    print("== MatchCensus — fixtures (cross-namespace) ==")
    print("fixture entries: \(fixtureUserEntries.count) user + "
        + "\(fixtureBundledEntries.count) bundled; "
        + "symbols: \(customDefs.count) custom + \(bundledDefs.count) bundled")

    func check(_ label: String, _ condition: Bool, _ detail: String) {
        if condition {
            print("PASS: \(label)")
        } else {
            print("FAIL: \(label) — \(detail)")
            fixtureFailures += 1
        }
    }
    func describe(_ match: FootprintMatch?) -> String {
        guard let match else { return "no match computed (symbol missing)" }
        let kind = match.kind?.rawValue ?? "nil"
        let resolved = match.resolved?.resolutionKey ?? "nil"
        let candidates = match.candidates.map { $0.entry.resolutionKey }
            .joined(separator: ", ")
        return "kind=\(kind) resolved=\(resolved) candidates=[\(candidates)]"
    }

    // (i) A custom symbol whose Footprint property names a bundled
    //     fixture footprint resolves it, as .property.
    let crossProp = customDefs["CrossProp"].map {
        FootprintMatcher.match(def: $0, choiceKey: nil, entries: combined)
    }
    check("(i) custom symbol -> bundled footprint via Footprint property",
          crossProp?.kind == .property
            && crossProp?.resolved?.key == "FixtureFP:BundledOnly8"
            && crossProp?.resolved?.source == .bundled,
          describe(crossProp))

    // (ii) A custom symbol with only filters matches a USER fixture
    //      footprint as a candidate, pin-exact.
    let filterUserDef = customDefs["FilterUser"]
    let filterUser = filterUserDef.map {
        FootprintMatcher.match(def: $0, choiceKey: nil, entries: combined)
    }
    let userOnlyCandidate = filterUser?.candidates.first {
        $0.entry.resolutionKey == "user:CustomFP:UserOnly8"
    }
    check("(ii) custom symbol filters -> user footprint candidate, pin-exact",
          filterUserDef?.distinctPinCount == 8
            && userOnlyCandidate != nil
            && userOnlyCandidate?.pinCountMatches == true,
          describe(filterUser))

    // (iii) A bundled symbol whose filters name a USER footprint
    //       gets it as a candidate (matching is cross-namespace).
    let bundledFilter = bundledDefs["BundledFilter"].map {
        FootprintMatcher.match(def: $0, choiceKey: nil, entries: combined)
    }
    check("(iii) bundled symbol filters -> user footprint candidate",
          bundledFilter?.candidates.contains {
              $0.entry.resolutionKey == "user:CustomFP:UserOnly8"
          } == true,
          describe(bundledFilter))

    // (iv) A custom symbol's reference to "CustomFP:Shared4" resolves
    //      the USER copy even though a bundled footprint shares the
    //      exact Group:Name key (user-wins rule).
    let sharedRef = customDefs["SharedRef"].map {
        FootprintMatcher.match(def: $0, choiceKey: nil, entries: combined)
    }
    check("(iv) shared Group:Name reference resolves the user copy",
          sharedRef?.kind == .property
            && sharedRef?.resolved?.resolutionKey == "user:CustomFP:Shared4"
            && sharedRef?.resolved?.source == .user,
          describe(sharedRef))

    print(fixtureFailures == 0
        ? "FIXTURES OK"
        : "FIXTURES FAILED: \(fixtureFailures) assertion(s)")
}

// Exit -------------------------------------------------------------------

for failure in wholesaleFailures { eprint("FAIL: \(failure)") }
if !wholesaleFailures.isEmpty {
    eprint("MatchCensus: \(wholesaleFailures.count) wholesale parse failure(s)")
    exit(1)
}
exit(fixtureFailures == 0 ? 0 : 1)
