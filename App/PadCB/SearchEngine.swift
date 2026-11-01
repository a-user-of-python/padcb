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
// HOW IT WORKS (v2 — rewritten after the first CI bench run):
// per row, the index precomputes ONE canonical byte string: the
// row's fields joined with "\n", lowercased, compatibility-folded
// (below), as UTF-8 bytes; plus the canonical name-field bytes.
// A search is a SINGLE pass of byte-substring scans over those
// precomputed bytes, bucketing matches into the three ranks as it
// goes. Byte-substring search over valid UTF-8 is character-safe:
// a valid UTF-8 needle can only match at character boundaries
// (UTF-8 is self-synchronising).
//
// Why not Swift String.contains over lowercased blobs (v1)?
// Two measured failures on the real corpus (CI run 41344234853):
//   1. SPEED: String.contains on the corpus's non-ASCII strings
//      (µ, ², …) is a grapheme-cluster search — far slower than the
//      old ICU-backed compares. v1 measured SLOWER than the old
//      semantics (symbols 242 ms vs 113 ms median). Byte scans run
//      at memory speed instead.
//   2. A MISSED MATCH: the old localizedCaseInsensitiveContains is
//      ICU-backed and treats compatibility variants as equal at
//      primary collation strength — e.g. the "²" in a footprint
//      description "37x44mm²" matches the query "2". Plain
//      lowercase containment does not (that footprint was the one
//      mismatch in 38k rows). The canonical fold below maps the
//      compatibility classes that occur in this corpus — super- /
//      subscript digits, fullwidth digits, circled digits, and the
//      micro sign µ -> Greek μ — onto their base characters on BOTH
//      the row text and the query, restoring the equivalence.
//      (Not folded: full ICU tailoring such as ß -> ss. The bench
//      battery over the real corpora is the evidence standard.)

/// One searchable row: a stable id plus its searchable fields.
/// `fields[0]` is the primary (name) field; the remaining fields are
/// the secondary text (description, keywords, group, tags, ...).
struct SearchRow: Codable {
    var id: String
    var fields: [String]
}

/// Canonicalisation for search: lowercase, then fold the
/// compatibility characters the old ICU-backed compare treated as
/// equal to their base characters. Applied identically to row text
/// and to queries, so the equivalence holds in both directions.
private enum SearchCanonical {
    private static let folds: [Character: String] = [
        // Micro sign (U+00B5) folds to Greek small mu (U+03BC) —
        // the old compare matched "µF" against "μF" fields and
        // vice versa; both occur throughout the corpora.
        "µ": "μ",
        // Superscript digits.
        "⁰": "0", "¹": "1", "²": "2", "³": "3", "⁴": "4",
        "⁵": "5", "⁶": "6", "⁷": "7", "⁸": "8", "⁹": "9",
        // Subscript digits.
        "₀": "0", "₁": "1", "₂": "2", "₃": "3", "₄": "4",
        "₅": "5", "₆": "6", "₇": "7", "₈": "8", "₉": "9",
        // Fullwidth digits.
        "０": "0", "１": "1", "２": "2", "３": "3", "４": "4",
        "５": "5", "６": "6", "７": "7", "８": "8", "９": "9",
        // Circled digits.
        "⓪": "0", "①": "1", "②": "2", "③": "3", "④": "4",
        "⑤": "5", "⑥": "6", "⑦": "7", "⑧": "8", "⑨": "9",
        "⑩": "10", "⑪": "11", "⑫": "12", "⑬": "13", "⑭": "14",
        "⑮": "15", "⑯": "16", "⑰": "17", "⑱": "18", "⑲": "19",
        "⑳": "20",
    ]

    /// The canonical UTF-8 bytes of a search string.
    static func bytes(of raw: String) -> [UInt8] {
        let lowered = raw.lowercased()
        var out = String()
        out.reserveCapacity(lowered.count)
        for ch in lowered {
            if let folded = folds[ch] {
                out += folded
            } else {
                out.append(ch)
            }
        }
        return Array(out.utf8)
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
        blobs = rows.map {
            SearchCanonical.bytes(of: $0.fields.joined(separator: "\n"))
        }
        names = rows.map {
            SearchCanonical.bytes(of: $0.fields.first ?? "")
        }
    }

    var count: Int { rows.count }

    /// Indices of the rows matching `rawQuery`, ranked as described
    /// above. Single pass over the precomputed bytes: a row matches
    /// iff its blob contains the canonical query bytes — for any
    /// query without "\n" that is exactly the old per-field OR,
    /// modulo the compatibility folds documented at the top of this
    /// file, which exist to PRESERVE the old ICU-backed semantics.
    /// tools/SearchBench asserts the set equality over the real
    /// corpora against `SearchSemantics.referenceMatches`.
    func search(_ rawQuery: String) -> [Int] {
        let query = SearchCanonical.bytes(
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
