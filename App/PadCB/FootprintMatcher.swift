import Foundation

/// Symbol <-> footprint matching (part 3), implementing KiCad 10.0.1
/// semantics pinned from KiCad source by the coordinator:
///
/// - Footprint filters live in the symbol property "ki_fp_filters", a
///   whitespace-separated pattern list (KiCadSymbolDef.fpFilters).
/// - Filter matching (KiCad common/footprint_filter.cpp,
///   FOOTPRINT_FILTER::FootprintFilterMatch +
///   FilterByFootprintFilters): the matcher is an ANCHORED
///   whole-string wildcard (EDA_PATTERN_MATCH_WILDCARD_ANCHORED):
///   `*` matches any run including empty, `?` matches exactly one
///   character, everything else is literal. Matching is
///   CASE-INSENSITIVE (pattern and candidate are both lowercased).
///   Candidate string: if the pattern contains ":", the candidate is
///   footprintLibraryName.lowercased() + ":" +
///   footprintName.lowercased(); otherwise it is
///   footprintName.lowercased(). A footprint is a filter candidate
///   iff ANY pattern matches.
/// - Pin-count comparison (CvPcb FilterByPinCount vs
///   FOOTPRINT_INFO::GetUniquePadCount): the footprint side is the
///   count of DISTINCT pad numbers (FootprintEntry.distinctPadCount;
///   PadCB counts distinct NON-EMPTY pad numbers — unnumbered
///   mechanical pads are notes, not bindings), compared against the
///   symbol's distinct pin number count
///   (KiCadSymbolDef.distinctPinCount).
///
/// CROSS-NAMESPACE RULE (Sean, part 3): matching runs over the
/// COMBINED user + bundled entry list for every symbol, regardless of
/// where the symbol itself came from — a custom symbol may resolve a
/// bundled footprint and a bundled symbol may be offered a user
/// footprint. Only the candidate RANKING tie-break prefers the
/// symbol's own source set. Nothing here shadows: identity stays in
/// FootprintEntry.resolutionKey ("user:" prefix for user copies).
///
/// (Known divergence, documented not implemented: CvPcb's .equ
/// auto-associate uses wxString::Matches — case-sensitive, name-only.
/// The footprint_filter.cpp rule above is the filter definition and
/// is what PadCB implements.)
///
/// Foundation only — this file compiles headlessly (tools/MatchCensus
/// links it with SExpr / KiCadSymbol / KiCadFootprint /
/// FootprintStore under macOS swiftc).

/// How a placed symbol instance's effective footprint was resolved.
enum FootprintMatchKind: String, Codable {
    /// The user picked a footprint for this instance
    /// (PlacedSymbol.footprintChoice).
    case instanceChoice
    /// The symbol definition's Footprint property resolved.
    case property
    /// A single, wildcard-free ki_fp_filters pattern resolved as an
    /// exact footprint reference (KiCad auto-associate's last-chance
    /// rule).
    case filterExact
}

/// One footprint offered for a symbol: a ki_fp_filters match, with
/// the pin-count verdict precomputed for display and ranking.
struct FootprintCandidate {
    var entry: FootprintEntry
    /// Distinct (non-empty) pad numbers of the footprint.
    var distinctPadCount: Int
    /// distinctPadCount == the symbol's distinctPinCount.
    var pinCountMatches: Bool
}

/// The result of matching one symbol definition against the known
/// footprints. `candidates` is ALWAYS computed from the filters, even
/// when `resolved` is non-nil — the editor shows the alternatives
/// alongside the effective assignment.
struct FootprintMatch {
    var kind: FootprintMatchKind?
    var resolved: FootprintEntry?
    var candidates: [FootprintCandidate]
}

enum FootprintMatcher {

    // MARK: - Wildcard matching (footprint_filter.cpp semantics)

    /// Anchored whole-string wildcard match, case-insensitive:
    /// `*` matches any run of characters including the empty run,
    /// `?` matches exactly one character, every other character is
    /// literal. Both inputs are lowercased here — callers must NOT
    /// assume pre-lowercased arguments.
    static func wildcardMatch(pattern: String, value: String) -> Bool {
        wildcardMatchLowercased(pattern: Array(pattern.lowercased()),
                                value: Array(value.lowercased()))
    }

    /// Core matcher over already-lowercased character arrays.
    /// Classic greedy scan with star backtracking (linear-ish for the
    /// short library/footprint names this ever sees).
    private static func wildcardMatchLowercased(pattern: [Character],
                                                value: [Character]) -> Bool {
        var p = 0 // pattern index
        var v = 0 // value index
        var starP = -1 // pattern index just after the last `*`
        var starV = -1 // value index that star has consumed up to
        while v < value.count {
            if p < pattern.count, pattern[p] == "?" || pattern[p] == value[v] {
                p += 1
                v += 1
            } else if p < pattern.count, pattern[p] == "*" {
                starP = p + 1
                starV = v
                p += 1
            } else if starP >= 0 {
                // Let the last `*` consume one more character and retry.
                p = starP
                starV += 1
                v = starV
            } else {
                return false
            }
        }
        // Any remaining pattern must be all `*` (each matches empty).
        while p < pattern.count, pattern[p] == "*" { p += 1 }
        return p == pattern.count
    }

    /// Does one ki_fp_filters pattern match this footprint entry?
    /// Applies KiCad's ":" rule: a pattern containing ":" is matched
    /// against "group:name" (both lowercased); a pattern without ":"
    /// is matched against the footprint name alone.
    static func filterMatches(pattern: String, entry: FootprintEntry) -> Bool {
        let candidate: String
        if pattern.contains(":") {
            candidate = entry.group.lowercased() + ":" + entry.name.lowercased()
        } else {
            candidate = entry.name.lowercased()
        }
        return wildcardMatch(pattern: pattern, value: candidate)
    }

    // MARK: - Reference resolution (the part-2 order)

    /// Resolves a footprint reference (a symbol's Footprint property,
    /// KiCad's "Lib:Name" form) against `entries` — the v2.0 order,
    /// identical to FootprintStore.resolve (which now delegates here):
    /// 1. exact "Group:Name" match — a USER copy wins over a bundled
    ///    copy of the same key;
    /// 2. otherwise a name-only match, preferring a unique user copy,
    ///    then a unique overall match.
    /// Returns nil for an empty / "~" reference or no unambiguous
    /// match. Comparisons are case-insensitive, as in part 2.
    static func resolveReference(_ rawValue: String?,
                                 entries: [FootprintEntry]) -> FootprintEntry? {
        guard let raw = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, raw != "~" else { return nil }

        var wantedName = raw
        if let colon = raw.firstIndex(of: ":") {
            let group = String(raw[raw.startIndex..<colon])
            let name = String(raw[raw.index(after: colon)...])
            let exact = entries.filter {
                $0.group.caseInsensitiveCompare(group) == .orderedSame
                    && $0.name.caseInsensitiveCompare(name) == .orderedSame
            }
            if let user = exact.first(where: { $0.source == .user }) { return user }
            if let bundled = exact.first { return bundled }
            wantedName = name
        }
        let nameMatches = entries.filter {
            $0.name.caseInsensitiveCompare(wantedName) == .orderedSame
        }
        let userMatches = nameMatches.filter { $0.source == .user }
        if userMatches.count == 1 { return userMatches[0] }
        return nameMatches.count == 1 ? nameMatches[0] : nil
    }

    /// Finds an entry by its FootprintEntry.resolutionKey (exact
    /// first, then case-insensitive). Used for per-instance choices,
    /// whose stored key records exactly which copy was picked.
    static func entry(forResolutionKey key: String,
                      in entries: [FootprintEntry]) -> FootprintEntry? {
        if let exact = entries.first(where: { $0.resolutionKey == key }) {
            return exact
        }
        return entries.first {
            $0.resolutionKey.caseInsensitiveCompare(key) == .orderedSame
        }
    }

    // MARK: - Candidates

    /// Every entry matched by ANY of the symbol's ki_fp_filters
    /// patterns, over the COMBINED entry list (cross-namespace rule:
    /// the symbol's own source never restricts the set), ranked:
    /// 1. pin-count matches first;
    /// 2. entries whose source matches the symbol's source first
    ///    (the symbol is custom iff its library key has the "user:"
    ///    prefix; .user entries match custom symbols, .bundled
    ///    entries match bundled symbols);
    /// 3. smaller |distinctPadCount - symbol pin count| first;
    /// 4. resolutionKey ascending.
    static func candidates(def: KiCadSymbolDef,
                           entries: [FootprintEntry]) -> [FootprintCandidate] {
        let patterns = def.fpFilters
        guard !patterns.isEmpty else { return [] }
        let pinCount = def.distinctPinCount
        let symbolIsCustom = def.library.hasPrefix("user:")

        var matched: [FootprintCandidate] = []
        for entry in entries {
            guard patterns.contains(where: { filterMatches(pattern: $0, entry: entry) })
            else { continue }
            matched.append(FootprintCandidate(
                entry: entry,
                distinctPadCount: entry.distinctPadCount,
                pinCountMatches: entry.distinctPadCount == pinCount))
        }

        func sourceMatches(_ entry: FootprintEntry) -> Bool {
            symbolIsCustom ? entry.source == .user : entry.source == .bundled
        }
        matched.sort { a, b in
            if a.pinCountMatches != b.pinCountMatches {
                return a.pinCountMatches
            }
            let aSource = sourceMatches(a.entry), bSource = sourceMatches(b.entry)
            if aSource != bSource { return aSource }
            let aDelta = abs(a.distinctPadCount - pinCount)
            let bDelta = abs(b.distinctPadCount - pinCount)
            if aDelta != bDelta { return aDelta < bDelta }
            if a.entry.resolutionKey != b.entry.resolutionKey {
                return a.entry.resolutionKey < b.entry.resolutionKey
            }
            return a.entry.key < b.entry.key
        }
        return matched
    }

    // MARK: - Full match for one symbol instance

    /// The effective footprint for one placed instance of `def`:
    /// (a) `choiceKey` (PlacedSymbol.footprintChoice — a
    ///     FootprintEntry.resolutionKey) when it names a known entry
    ///     -> .instanceChoice. A stale choice (footprint since
    ///     deleted) falls through to the automatic rules below.
    /// (b) the symbol's Footprint property via resolveReference
    ///     -> .property.
    /// (c) when the symbol carries exactly ONE filter pattern, the
    ///     pattern contains no wildcard, and it resolves as an exact
    ///     reference -> .filterExact (KiCad auto-associate's
    ///     last-chance rule).
    /// (d) otherwise no resolution (kind nil, resolved nil).
    /// Candidates are always computed, resolved or not.
    static func match(def: KiCadSymbolDef,
                      choiceKey: String?,
                      entries: [FootprintEntry]) -> FootprintMatch {
        let allCandidates = candidates(def: def, entries: entries)

        if let choiceKey, !choiceKey.isEmpty,
           let chosen = entry(forResolutionKey: choiceKey, in: entries) {
            return FootprintMatch(kind: .instanceChoice,
                                  resolved: chosen,
                                  candidates: allCandidates)
        }

        if let resolved = resolveReference(def.property("Footprint"), entries: entries) {
            return FootprintMatch(kind: .property,
                                  resolved: resolved,
                                  candidates: allCandidates)
        }

        let patterns = def.fpFilters
        if patterns.count == 1 {
            let pattern = patterns[0]
            if !pattern.contains("*"), !pattern.contains("?"),
               let resolved = resolveReference(pattern, entries: entries) {
                return FootprintMatch(kind: .filterExact,
                                      resolved: resolved,
                                      candidates: allCandidates)
            }
        }

        return FootprintMatch(kind: nil, resolved: nil, candidates: allCandidates)
    }
}
