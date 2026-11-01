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
// How it works: building a SearchIndex precomputes, per row, ONE
// lowercased blob (the row's fields joined with "\n") and the
// lowercased name field. A search is then a plain `contains` scan
// over those precomputed strings — no per-row lowercasing, no
// localized compare machinery in the hot loop.

/// One searchable row: a stable id plus its searchable fields.
/// `fields[0]` is the primary (name) field; the remaining fields are
/// the secondary text (description, keywords, group, tags, ...).
struct SearchRow: Codable {
    var id: String
    var fields: [String]
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
    /// Per-row searchable text: fields joined with "\n", lowercased
    /// once at build time.
    private let blobs: [String]
    /// Per-row name field (fields[0]), lowercased once at build time.
    private let names: [String]

    init(rows: [SearchRow]) {
        self.rows = rows
        blobs = rows.map { $0.fields.joined(separator: "\n").lowercased() }
        names = rows.map { ($0.fields.first ?? "").lowercased() }
    }

    var count: Int { rows.count }

    /// Indices of the rows matching `rawQuery`, ranked as described
    /// above. The query is trimmed and lowercased once; matching is a
    /// single `contains` per row per rank pass over the precomputed
    /// blob — no string allocations inside the loop beyond the
    /// result array itself.
    ///
    /// Result SET (ignoring the ranking order) is identical to the
    /// old semantics — "any field contains the query,
    /// case-insensitively" — for any query that does not itself
    /// contain "\n": `contains` over the "\n"-joined blob can only
    /// match inside one field, which is exactly the per-field OR.
    /// tools/SearchBench asserts this set equality over the real
    /// corpora against `SearchSemantics.referenceMatches`.
    func search(_ rawQuery: String) -> [Int] {
        let query = rawQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return Array(rows.indices) }
        var result: [Int] = []
        // Three passes, one per rank, so the only allocation in the
        // hot loop is the result array. Each pass is a plain contains
        // scan over precomputed lowercase strings.
        for targetRank in 0...2 {
            for index in rows.indices {
                guard blobs[index].contains(query) else { continue }
                let name = names[index]
                let rank = name.hasPrefix(query) ? 0
                    : (name.contains(query) ? 1 : 2)
                if rank == targetRank { result.append(index) }
            }
        }
        return result
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
