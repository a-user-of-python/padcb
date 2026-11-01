import Foundation
import Combine

/// Where a symbol library came from. Bundled libraries ship inside the
/// app; custom libraries are user-supplied .kicad_sym files dropped into
/// Documents/Symbols (file sharing — no system picker anywhere).
enum SymbolLibrarySource: String, Codable {
    case bundled
    case custom
}

/// One row of the symbol chooser index, built from the symbol's RESOLVED
/// properties (extends inheritance applied over the light header pass),
/// so inherited Description/ki_keywords/Datasheet values show up on
/// extends-only variants too.
struct SymbolIndexEntry: Codable, Identifiable {
    /// Base library name (file base name without .kicad_sym) — the same
    /// for a bundled library and a custom library of the same name.
    var library: String
    var source: SymbolLibrarySource
    var name: String
    var description: String
    var keywords: String
    var datasheet: String // raw property value, "" if absent

    /// The unique lookup key for the library this entry belongs to.
    ///
    /// COLLISION RULE (part 2, documented in CONTRACTS.md): a custom
    /// library NEVER shadows a bundled one. Bundled libraries keep their
    /// plain base name as the key; a custom library's key is
    /// "user:<BaseName>" and the chooser displays it as
    /// "BaseName (Custom)". Both stay independently selectable, and a
    /// placed symbol records the key in PlacedSymbol.library, so saved
    /// schematics keep resolving to the exact library they came from.
    var libraryKey: String {
        LibraryStore.libraryKey(library: library, source: source)
    }

    var id: String { libraryKey + ":" + name }

    /// Non-nil only when the datasheet value is an http(s) URL.
    var datasheetURL: URL? {
        let value = datasheet.trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("http://") || value.hasPrefix("https://") else { return nil }
        return URL(string: value)
    }
}

/// On-disk form of Application Support/PadCB/symbol-index.json.
/// Only BUNDLED entries are cached; custom libraries are re-scanned
/// from disk on every launch (files on disk are the source of truth).
private struct IndexCache: Codable {
    var fingerprint: String
    var entries: [SymbolIndexEntry]
}

/// Loads the bundled KiCad symbol libraries plus the user's own
/// libraries from Documents/Symbols, builds (and caches) the chooser
/// index, and hands out fully parsed libraries on demand.
final class LibraryStore: ObservableObject {
    @Published var index: [SymbolIndexEntry] = []
    /// Precomputed search index over `index` (rows in the same order,
    /// fields [name, description, keywords]), rebuilt on every
    /// publishIndex() so the chooser never re-filters the raw index
    /// on the main thread (part 3 — see SearchEngine.swift).
    @Published var symbolSearchIndex: SearchIndex = SearchIndex(rows: [])
    @Published var indexReady = false
    @Published var loadError: String?
    /// Bundled libraries whose header pass failed during the last build.
    @Published var totalParseErrors: Int = 0
    /// Per-file problems from the last custom-library scan (malformed
    /// files are skipped and reported here, never fatal).
    @Published var customLibraryIssues: [String] = []
    /// Custom library files successfully loaded by the last scan.
    @Published var customLibraryCount: Int = 0
    @Published var isScanningCustomLibraries = false

    private let lock = NSLock()
    private var memo: [String: KiCadLibrary] = [:]
    private var fileURLByLibrary: [String: URL] = [:]
    private var didBootstrap = false
    private var bundledEntries: [SymbolIndexEntry] = []
    private var customEntries: [SymbolIndexEntry] = []
    private var bundledReady = false
    /// Notes from the one-time legacy-folder migration in bootstrap(),
    /// held until the first custom-scan publish folds them into
    /// `customLibraryIssues` (the scan's publish REPLACES that array,
    /// so appending the notes directly in bootstrap would lose them).
    private var pendingMigrationNotes: [String] = []

    // MARK: - Library keys

    static let customKeyPrefix = "user:"

    static func libraryKey(library: String, source: SymbolLibrarySource) -> String {
        source == .custom ? customKeyPrefix + library : library
    }

    static func isCustomLibraryKey(_ key: String) -> Bool {
        key.hasPrefix(customKeyPrefix)
    }

    static func baseName(forLibraryKey key: String) -> String {
        isCustomLibraryKey(key) ? String(key.dropFirst(customKeyPrefix.count)) : key
    }

    /// Chooser-facing name for a library key: "Device" for bundled,
    /// "Device (Custom)" for a user library of the same base name.
    static func displayName(forLibraryKey key: String) -> String {
        isCustomLibraryKey(key) ? baseName(forLibraryKey: key) + " (Custom)" : key
    }

    // MARK: - Bootstrap

    /// Idempotent. Discovers the bundled libraries, then on a background
    /// queue either loads the cached index (fingerprint match) or builds
    /// it from a LIGHT header pass over every library (name / extends /
    /// direct properties only — the full set is ~260 MB of text, so no
    /// parsed KiCadLibrary is retained here; full parses happen per
    /// library on demand in library(named:)). Custom libraries are
    /// scanned separately (always fresh from disk). Results are
    /// published on the main actor.
    func bootstrap() {
        lock.lock()
        if didBootstrap {
            lock.unlock()
            return
        }
        didBootstrap = true
        lock.unlock()

        // Folder rename (part 3): user symbol libraries live in
        // Documents/Symbols now. Move any *.kicad_sym the user still
        // has in the legacy Documents/Libraries folder BEFORE anything
        // scans, and surface the migration notes alongside the custom
        // scan's issues. The notes are appended now AND held in
        // pendingMigrationNotes, because the scan's publish replaces
        // customLibraryIssues wholesale — the publish folds the held
        // notes back in (exactly once) so they survive it.
        let migrationNotes = PadCBPaths.migrateLegacySymbolLibraries()
        if !migrationNotes.isEmpty {
            pendingMigrationNotes = migrationNotes
            customLibraryIssues += migrationNotes
        }

        PadCBPaths.ensureStandardDirectories()

        let files = Self.discoverBundledSymbolFiles()
        lock.lock()
        for url in files {
            let key = Self.libraryName(for: url)
            if fileURLByLibrary[key] == nil { fileURLByLibrary[key] = url }
        }
        lock.unlock()

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.buildIndex(files: files)
        }
        rescanUserLibraries()
    }

    private func buildIndex(files: [URL]) async {
        if files.isEmpty {
            await MainActor.run {
                self.bundledEntries = []
                self.bundledReady = true
                if self.customEntries.isEmpty {
                    self.loadError = "No KiCad symbol libraries (.kicad_sym) found in the app bundle."
                }
                self.publishIndex()
            }
            return
        }

        let fingerprint = Self.fingerprint(for: files)
        let cacheURL = Self.cacheFileURL()

        // Fast path: a cache written for exactly these files.
        if let cacheURL,
           let data = try? Data(contentsOf: cacheURL),
           let cache = try? JSONDecoder().decode(IndexCache.self, from: data),
           cache.fingerprint == fingerprint {
            let entries = cache.entries
            await MainActor.run {
                self.bundledEntries = entries
                self.bundledReady = true
                self.publishIndex()
            }
            return
        }

        // Slow path: light header pass per library. Only the index is
        // retained — parsed libraries are memory-heavy and are produced
        // on demand by library(named:) instead.
        var entries: [SymbolIndexEntry] = []
        var parseErrorTotal = 0
        for url in files {
            let libraryName = Self.libraryName(for: url)
            guard let data = try? Data(contentsOf: url) else {
                parseErrorTotal += 1
                continue
            }
            // Lossy UTF-8 decode: a stray bad byte must not kill a library.
            let text = String(decoding: data, as: UTF8.self)
            let headers = KiCadLibrary.symbolHeaders(text: text)
            if headers.isEmpty {
                parseErrorTotal += 1
                continue
            }
            entries += Self.indexEntries(library: libraryName, source: .bundled, headers: headers)
        }

        // Write the cache for the next launch (best effort).
        if let cacheURL {
            let cache = IndexCache(fingerprint: fingerprint, entries: entries)
            if let data = try? JSONEncoder().encode(cache) {
                try? FileManager.default.createDirectory(
                    at: cacheURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try? data.write(to: cacheURL, options: [.atomic])
            }
        }

        await MainActor.run {
            self.bundledEntries = entries
            self.totalParseErrors = parseErrorTotal
            self.bundledReady = true
            self.publishIndex()
        }
    }

    /// Merges bundled + custom entries into the published index, and
    /// rebuilds the precomputed search index over the merged rows.
    /// Main-actor only (all callers hop first).
    private func publishIndex() {
        index = bundledEntries + customEntries
        symbolSearchIndex = SearchIndex(rows: index.map {
            SearchRow(id: $0.id, fields: [$0.name, $0.description, $0.keywords])
        })
        if bundledReady { indexReady = true }
        if !index.isEmpty { loadError = nil }
    }

    // MARK: - Custom (user) libraries

    /// Re-scans Documents/Symbols/*.kicad_sym from disk: files added,
    /// replaced or deleted since the last scan take effect, malformed
    /// files are skipped and reported in `customLibraryIssues`, and any
    /// memoized parses of custom libraries are dropped. This is the
    /// chooser's Rescan affordance and also runs once per launch.
    func rescanUserLibraries() {
        guard !isScanningCustomLibraries else { return }
        isScanningCustomLibraries = true
        Task.detached(priority: .utility) { [weak self] in
            let result = Self.scanCustomLibraryFiles()
            await MainActor.run { [weak self] in
                guard let self else { return }
                // Drop stale custom registrations + memoized parses.
                self.lock.lock()
                self.fileURLByLibrary = self.fileURLByLibrary.filter {
                    !Self.isCustomLibraryKey($0.key)
                }
                self.memo = self.memo.filter { !Self.isCustomLibraryKey($0.key) }
                for (key, url) in result.fileURLByKey {
                    self.fileURLByLibrary[key] = url
                }
                for (key, library) in result.parsedByKey {
                    self.memo[key] = library
                }
                self.lock.unlock()

                self.customEntries = result.entries
                // Fold in the bootstrap migration notes exactly once:
                // this publish replaces the array, so anything appended
                // earlier would otherwise be lost.
                self.customLibraryIssues = self.pendingMigrationNotes + result.issues
                self.pendingMigrationNotes = []
                self.customLibraryCount = result.fileCount
                self.isScanningCustomLibraries = false
                self.publishIndex()
            }
        }
    }

    private struct CustomScanResult {
        var entries: [SymbolIndexEntry]
        var issues: [String]
        var fileCount: Int
        var fileURLByKey: [String: URL]
        var parsedByKey: [String: KiCadLibrary]
    }

    /// Full-parse scan of the custom library folder. Custom files are
    /// fully parsed at scan time (a user's own libraries are small next
    /// to the bundled corpus) so a malformed file is caught here —
    /// skipped + reported — instead of failing later in the chooser.
    private static func scanCustomLibraryFiles() -> CustomScanResult {
        let dir = PadCBPaths.userSymbolsDirectory
        PadCBPaths.ensureDirectory(dir)
        let fm = FileManager.default
        let urls = ((try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension.lowercased() == "kicad_sym" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var entries: [SymbolIndexEntry] = []
        var issues: [String] = []
        var fileURLByKey: [String: URL] = [:]
        var parsedByKey: [String: KiCadLibrary] = [:]
        var fileCount = 0

        for url in urls {
            let baseName = libraryName(for: url)
            let key = libraryKey(library: baseName, source: .custom)
            guard fileURLByKey[key] == nil else {
                issues.append("\(url.lastPathComponent): duplicates another custom library named \(baseName); skipped.")
                continue
            }
            guard let data = try? Data(contentsOf: url) else {
                issues.append("\(url.lastPathComponent): could not be read; skipped.")
                continue
            }
            let text = String(decoding: data, as: UTF8.self)
            do {
                let library = try KiCadLibrary.parse(name: key, text: text)
                guard !library.symbols.isEmpty else {
                    issues.append("\(url.lastPathComponent): no readable symbols found; skipped.")
                    continue
                }
                fileURLByKey[key] = url
                parsedByKey[key] = library
                fileCount += 1
                for message in library.parseErrors {
                    issues.append("\(url.lastPathComponent): \(message)")
                }
                // Entries come from the RESOLVED definitions, so
                // extends-inherited Description/Datasheet show up —
                // the same rule the bundled header pass applies.
                entries += library.symbols.values
                    .sorted { $0.name < $1.name }
                    .map { def in
                        SymbolIndexEntry(
                            library: baseName,
                            source: .custom,
                            name: def.name,
                            description: indexValue(def.property("Description")),
                            keywords: indexValue(def.property("ki_keywords") ?? def.property("Keywords")),
                            datasheet: indexValue(def.property("Datasheet")))
                    }
            } catch {
                issues.append("\(url.lastPathComponent): not a readable KiCad symbol library (\(error.localizedDescription)); skipped.")
            }
        }
        return CustomScanResult(entries: entries, issues: issues,
                                fileCount: fileCount,
                                fileURLByKey: fileURLByKey,
                                parsedByKey: parsedByKey)
    }

    // MARK: - On-demand access

    /// Full parse of one library, memoized. Accepts a library KEY
    /// ("Device" bundled, "user:Device" custom) or — for pre-part-2
    /// callers and saved schematics — a plain base name, which means
    /// the bundled library. The first call for a big bundled library
    /// costs a parse (~50–200 ms); later calls are dictionary hits.
    /// Custom libraries are already parsed by the scan.
    func library(named name: String) -> KiCadLibrary? {
        var key = name.hasSuffix(".kicad_sym")
            ? String(name.dropLast(".kicad_sym".count))
            : name
        if !Self.isCustomLibraryKey(key) {
            lock.lock()
            let knownBundled = fileURLByLibrary[key] != nil || memo[key] != nil
            lock.unlock()
            if !knownBundled {
                // A bare base name could still be a custom library when
                // no bundled library carries it (e.g. a schematic saved
                // against a custom-only name). Prefer bundled, fall
                // back to custom.
                let customKey = Self.libraryKey(library: key, source: .custom)
                lock.lock()
                let knownCustom = fileURLByLibrary[customKey] != nil || memo[customKey] != nil
                lock.unlock()
                if knownCustom { key = customKey }
            }
        }

        lock.lock()
        if let cached = memo[key] {
            lock.unlock()
            return cached
        }
        var url = fileURLByLibrary[key]
        lock.unlock()

        if url == nil {
            // bootstrap() has not run (or found nothing) yet — discover now.
            let bundledFiles = Self.discoverBundledSymbolFiles()
            let customFiles = Self.discoverCustomSymbolFiles()
            lock.lock()
            for file in bundledFiles {
                let fileKey = Self.libraryName(for: file)
                if fileURLByLibrary[fileKey] == nil { fileURLByLibrary[fileKey] = file }
            }
            for file in customFiles {
                let fileKey = Self.libraryKey(library: Self.libraryName(for: file), source: .custom)
                if fileURLByLibrary[fileKey] == nil { fileURLByLibrary[fileKey] = file }
            }
            url = fileURLByLibrary[key]
            lock.unlock()
        }

        guard let fileURL = url,
              let data = try? Data(contentsOf: fileURL) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard let library = try? KiCadLibrary.parse(name: key, text: text) else { return nil }
        lock.lock()
        memo[key] = library
        lock.unlock()
        return library
    }

    /// Convenience: one resolved symbol definition from a named library
    /// (key or base name — see library(named:)).
    func symbol(library: String, name: String) -> KiCadSymbolDef? {
        // `self.` is required: the `library` parameter shadows this method.
        self.library(named: library)?.symbols[name]
    }

    // MARK: - Index entries from headers

    /// Build chooser entries from one library's symbol headers, resolving
    /// property inheritance over the headers: a symbol's own property
    /// wins, otherwise the nearest extends ancestor's value is used.
    /// Duplicate symbol names keep the first occurrence. Entry order is
    /// the symbols' file order.
    private static func indexEntries(library: String,
                                     source: SymbolLibrarySource,
                                     headers: [KiCadSymbolHeader]) -> [SymbolIndexEntry] {
        var byName: [String: KiCadSymbolHeader] = [:]
        var order: [String] = []
        for header in headers where byName[header.name] == nil {
            byName[header.name] = header
            order.append(header.name)
        }

        func resolvedProperties(of symbolName: String) -> [String: String] {
            var resolved: [String: String] = [:]
            var visited: Set<String> = []
            var current: String? = symbolName
            while let name = current, !visited.contains(name),
                  let header = byName[name] {
                visited.insert(name)
                for (key, value) in header.properties where resolved[key] == nil {
                    resolved[key] = value
                }
                current = header.extendsName
            }
            return resolved
        }

        return order.map { symbolName in
            let properties = resolvedProperties(of: symbolName)
            return SymbolIndexEntry(
                library: library,
                source: source,
                name: symbolName,
                description: indexValue(properties["Description"]),
                keywords: indexValue(properties["ki_keywords"] ?? properties["Keywords"]),
                datasheet: indexValue(properties["Datasheet"])
            )
        }
    }

    // MARK: - Discovery / fingerprint / cache plumbing

    /// *.kicad_sym in the bundle's Symbols subdirectory, falling back to
    /// the bundle root. Sorted by file name for a stable fingerprint.
    private static func discoverBundledSymbolFiles() -> [URL] {
        var urls = Bundle.main.urls(forResourcesWithExtension: "kicad_sym",
                                    subdirectory: "Symbols") ?? []
        if urls.isEmpty {
            urls = Bundle.main.urls(forResourcesWithExtension: "kicad_sym",
                                    subdirectory: nil) ?? []
        }
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// *.kicad_sym dropped into Documents/Symbols (top level only —
    /// that flat folder is the documented convention). Sorted by name.
    private static func discoverCustomSymbolFiles() -> [URL] {
        let dir = PadCBPaths.userSymbolsDirectory
        PadCBPaths.ensureDirectory(dir)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        return urls
            .filter { $0.pathExtension.lowercased() == "kicad_sym" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func libraryName(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    /// Fingerprint of the sorted (filename, size) pairs of the library set.
    private static func fingerprint(for files: [URL]) -> String {
        let fileManager = FileManager.default
        let parts = files.map { url -> String in
            var size = -1
            if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
               let number = attributes[.size] as? NSNumber {
                size = number.intValue
            }
            return "\(url.lastPathComponent)=\(size)"
        }
        return parts.joined(separator: "|")
    }

    private static func cacheFileURL() -> URL? {
        guard let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        return support
            .appendingPathComponent("PadCB", isDirectory: true)
            .appendingPathComponent("symbol-index.json")
    }

    /// KiCad writes "~" for an empty property value; the index stores ""
    /// instead so the chooser never displays a tilde.
    private static func indexValue(_ raw: String?) -> String {
        guard let value = raw?.trimmingCharacters(in: .whitespaces),
              !value.isEmpty, value != "~" else { return "" }
        return value
    }
}
