import Foundation

// SearchEngine — fast, precomputed text search over the symbol and
// footprint corpora (part 3).
//
// The pre-part-3 views re-ran the whole filter on EVERY SwiftUI body
// pass: ~22.7k symbol entries x 3 localizedCaseInsensitiveContains
// calls (plus dictionary grouping + sort), and ~15.4k footprint
// entries likewise — all on the main thread. Sean: search "can get
// really laggy".
//
// This file is the replacement core. It is Foundation ONLY (no
// SwiftUI / Combine) so tools/SearchBench can compile it headlessly
// with swiftc and prove, against the shipped corpus, that the new
// search returns exactly the same result SET as the old per-field
// semantics while running far faster.
//
// HOW IT WORKS (v3 — semantics pinned by two CI bench runs over
// the real corpora, 41344234853 and 41346564244):
// per row, the index precomputes ONE canonical byte string: the
// row's fields — each lowercased and µ-folded, with ONE special
// end-of-field rule (below) — joined with "\n", as UTF-8 bytes;
// plus the canonical name-field bytes. A search is a SINGLE pass
// of byte-substring scans over those precomputed bytes, bucketing
// matches into the three ranks as it goes. Byte-substring search
// over valid UTF-8 is character-safe: a valid UTF-8 needle can
// only match at character boundaries (UTF-8 is self-synchronising).
//
// Why not Swift String.contains over lowercased blobs (v1)?
// SPEED: String.contains on the corpus's non-ASCII strings (µ, ²,
// …) is a grapheme-cluster search — far slower than the old
// ICU-backed compares. v1 measured SLOWER than the old semantics
// (symbols 242 ms vs 113 ms median). Byte scans run at memory
// speed (v3: ~3 ms per query over 15k rows, host-measured).
//
// THE ICU SUBTLETIES (why canonicalisation is not just lowercase):
// The old oracle, localizedCaseInsensitiveContains, is ICU-backed.
// The bench runs established its exact behaviour on this corpus:
//   * µ (micro sign, U+00B5) and μ (Greek mu) match each other in
//     both directions — a true Unicode case-fold pair. Folded on
//     both text and query below.
//   * A plain-digit query char matches a SUPERSCRIPT digit in the
//     text ONLY at the very end of the searched string: ICU
//     search cannot end a match inside one character's collation
//     elements, except at the string end. Measured: query "2"
//     matches the footprint whose description ENDS "37x44mm²",
//     but NOT the many footprints with "mm²" mid-description
//     ("0.15 mm² wire"), and "I2C" does not match text "I²C".
//     Conversely a decorated query char ("²", "mm²") matches only
//     literal decorated text — the equivalence is NOT symmetric.
//   v2 of this engine folded all compatibility digits on both
//   sides and over-matched exactly along those lines (only-new
//   rows for "2", "²", "mm²", "I2C"; never an only-reference row).
//   v3 encodes the measured rule instead: no digit folding
//   anywhere, but for each field whose last character is a
//   superscript digit the blob ALSO stores a twin segment — the
//   field with that final digit in plain form. Any query that
//   matches the twin but not the literal field must end exactly
//   at that final character, which is precisely the oracle's
//   end-of-string equivalence; the literal segment keeps
//   decorated queries ("²", "mm²") matching as before.
//   (Subscript/fullwidth/circled digits have no measured
//   equivalence in this corpus and are left alone.)

/// One searchable row: a stable id plus its searchable fields.
/// `fields[0]` is the primary (name) field; the remaining fields are
/// the secondary text (description, keywords, group, tags, ...).
struct SearchRow: Codable {
    var id: String
    var fields: [String]
}

/// Canonicalisation for search (see the v3 notes at the top of
/// this file): lowercase + the µ -> μ case fold, applied to text
/// and queries alike; plus, for row FIELDS only, the end-of-field
/// superscript rule.
private enum SearchCanonical {
    /// Superscript digits and their plain equivalents — the one
    /// compatibility class with a measured ICU equivalence in this
    /// corpus, and only at a field's end (see header).
    private static let superscriptDigits: [Character: Character] = [
        "⁰": "0", "¹": "1", "²": "2", "³": "3", "⁴": "4",
        "⁵": "5", "⁶": "6", "⁷": "7", "⁸": "8", "⁹": "9",
    ]

    /// Lowercase + µ fold (U+00B5 micro sign -> U+03BC Greek mu,
    /// its Unicode case-fold target; both spellings occur
    /// throughout the corpora, e.g. "10µF" vs "10μF").
    private static func folded(_ raw: String) -> String {
        let lowered = raw.lowercased()
        guard lowered.contains("µ") else { return lowered }
        return lowered.replacingOccurrences(of: "µ", with: "μ")
    }

    /// The canonical form of one row FIELD: lowercase + µ fold.
    static func fieldString(_ raw: String) -> String {
        folded(raw)
    }

    /// For a canonical field whose last character is a superscript
    /// digit, the twin segment with that final digit in plain
    /// form ("…37x44mm²" -> "…37x44mm2"); nil otherwise. Stored in
    /// the blob alongside the literal field (see the v3 header
    /// notes): it reproduces the old ICU search's end-of-string
    /// equivalence without touching mid-field text.
    static func endVariant(of canonicalField: String) -> String? {
        guard let last = canonicalField.last,
              let plain = superscriptDigits[last] else { return nil }
        return String(canonicalField.dropLast()) + String(plain)
    }

    /// The canonical UTF-8 bytes of a QUERY: folded only. Query
    /// text is never digit-folded — a decorated query character
    /// matches only literal decorated text, as the oracle does.
    static func queryBytes(of raw: String) -> [UInt8] {
        Array(folded(raw).utf8)
    }

    /// Byte-substring search: true iff `needle` occurs in
    /// `haystack`. Both are canonical UTF-8, so a match always
    /// lands on character boundaries.
    static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        if needle.isEmpty { return true }
        if haystack.count < needle.count { return false }
        let first = needle[0]
        let lastStart = haystack.count - needle.count
        var i = 0
        while i <= lastStart {
            if haystack[i] == first {
                var j = 1
                while j < needle.count && haystack[i + j] == needle[j] { j += 1 }
                if j == needle.count { return true }
            }
            i += 1
        }
        return false
    }

    static func hasPrefix(_ bytes: [UInt8], _ prefix: [UInt8]) -> Bool {
        guard bytes.count >= prefix.count else { return false }
        for j in prefix.indices where bytes[j] != prefix[j] { return false }
        return true
    }
}

/// A precomputed search index over a fixed list of rows.
///
/// `search` returns ROW INDICES (positions in `rows`), ranked:
///   (a) rows whose name field has the query as a prefix,
///   (b) rows whose name field contains the query,
///   (c) every other match,
/// stable by original index within each rank. An empty (or
/// whitespace-only) query returns every row in original order.
struct SearchIndex {
    let rows: [SearchRow]
    /// Per-row canonical searchable bytes: fields joined with "\n".
    private let blobs: [[UInt8]]
    /// Per-row canonical name-field bytes (fields[0]).
    private let names: [[UInt8]]

    init(rows: [SearchRow]) {
        self.rows = rows
        blobs = rows.map { row in
            var segments = row.fields.map { SearchCanonical.fieldString($0) }
            // Twin segments for fields ending in a superscript
            // digit (the end-of-field equivalence, see header).
            segments += segments.compactMap { SearchCanonical.endVariant(of: $0) }
            return Array(segments.joined(separator: "\n").utf8)
        }
        names = rows.map {
            Array(SearchCanonical.fieldString($0.fields.first ?? "").utf8)
        }
    }

    var count: Int { rows.count }

    /// Indices of the rows matching `rawQuery`, ranked as described
    /// above. Single pass over the precomputed bytes: a row matches
    /// iff its blob contains the canonical query bytes — for any
    /// query without "\n" that is exactly the old per-field OR,
    /// modulo the two measured ICU behaviours documented at the top
    /// of this file (the µ case fold and the end-of-field
    /// superscript equivalence), which the canonicalisation exists
    /// to PRESERVE. tools/SearchBench asserts the set equality
    /// over the real corpora against
    /// `SearchSemantics.referenceMatches`.
    func search(_ rawQuery: String) -> [Int] {
        let query = SearchCanonical.queryBytes(
            of: rawQuery.trimmingCharacters(in: .whitespaces))
        guard !query.isEmpty else { return Array(rows.indices) }
        var rank0: [Int] = []
        var rank1: [Int] = []
        var rank2: [Int] = []
        for index in rows.indices {
            guard SearchCanonical.contains(blobs[index], query) else { continue }
            let name = names[index]
            if SearchCanonical.hasPrefix(name, query) {
                rank0.append(index)
            } else if SearchCanonical.contains(name, query) {
                rank1.append(index)
            } else {
                rank2.append(index)
            }
        }
        return rank0 + rank1 + rank2
    }
}

/// The PRE-Part-3 search semantics, kept as the correctness oracle.
///
/// This is exactly what the views did before part 3: trim the query,
/// then a row matches iff ANY field
/// `localizedCaseInsensitiveContains` the query, results in original
/// order, no ranking. It ships in the app file but is ONLY used by
/// tools/SearchBench, which proves the new `SearchIndex.search`
/// returns the same result set for a battery of realistic queries
/// over the real symbol and footprint corpora (and times both
/// implementations in the same process for the before/after numbers).
enum SearchSemantics {
    static func referenceMatches(rows: [SearchRow], query rawQuery: String) -> [Int] {
        let query = rawQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return Array(rows.indices) }
        var result: [Int] = []
        result.reserveCapacity(rows.count / 16)
        for (index, row) in rows.enumerated() {
            if row.fields.contains(where: {
                $0.localizedCaseInsensitiveContains(query)
            }) {
                result.append(index)
            }
        }
        return result
    }
}
