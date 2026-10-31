import Foundation
import Combine

/// One row of the symbol chooser index, built from the symbol's RESOLVED
/// properties (extends inheritance applied over the light header pass),
/// so inherited Description/ki_keywords/Datasheet values show up on
/// extends-only variants too.
struct SymbolIndexEntry: Codable, Identifiable {
    var library: String
    var name: String
    var description: String
    var keywords: String
    var datasheet: String // raw property value, "" if absent

    var id: String { library + ":" + name }

    /// Non-nil only when the datasheet value is an http(s) URL.
    var datasheetURL: URL? {
        let value = datasheet.trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("http://") || value.hasPrefix("https://") else { return nil }
        return URL(string: value)
    }
}

/// On-disk form of Application Support/PadCB/symbol-index.json.
private struct IndexCache: Codable {
    var fingerprint: String
    var entries: [SymbolIndexEntry]
}

/// Loads the bundled KiCad symbol libraries, builds (and caches) the
/// chooser index, and hands out fully parsed libraries on demand.
final class LibraryStore: ObservableObject {
    @Published var index: [SymbolIndexEntry] = []
    @Published var indexReady = false
    @Published var loadError: String?
    /// Libraries whose header pass failed during the last index build.
    @Published var totalParseErrors: Int = 0

    private let lock = NSLock()
    private var memo: [String: KiCadLibrary] = [:]
    private var fileURLByLibrary: [String: URL] = [:]
    private var didBootstrap = false

    // MARK: - Bootstrap

    /// Idempotent. Discovers the bundled libraries, then on a background
    /// queue either loads the cached index (fingerprint match) or builds
    /// it from a LIGHT header pass over every library (name / extends /
    /// direct properties only — the full set is ~260 MB of text, so no
    /// parsed KiCadLibrary is retained here; full parses happen per
    /// library on demand in library(named:)). Results are published on
    /// the main actor.
    func bootstrap() {
        lock.lock()
        if didBootstrap {
            lock.unlock()
            return
        }
        didBootstrap = true
        lock.unlock()

        let files = Self.discoverSymbolFiles()
        lock.lock()
        for url in files where fileURLByLibrary[Self.libraryName(for: url)] == nil {
            fileURLByLibrary[Self.libraryName(for: url)] = url
        }
        lock.unlock()

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.buildIndex(files: files)
        }
    }

    private func buildIndex(files: [URL]) async {
        guard !files.isEmpty else {
            await MainActor.run {
                self.loadError = "No KiCad symbol libraries (.kicad_sym) found in the app bundle."
                self.indexReady = true
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
                self.index = entries
                self.indexReady = true
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
            entries += Self.indexEntries(library: libraryName, headers: headers)
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
            self.index = entries
            self.totalParseErrors = parseErrorTotal
            self.indexReady = true
        }
    }

    // MARK: - On-demand access

    /// Full parse of one library, memoized. The first call for a big
    /// library costs a parse (~50–200 ms); later calls are dictionary hits.
    func library(named name: String) -> KiCadLibrary? {
        let key = name.hasSuffix(".kicad_sym")
            ? String(name.dropLast(".kicad_sym".count))
            : name

        lock.lock()
        if let cached = memo[key] {
            lock.unlock()
            return cached
        }
        var url = fileURLByLibrary[key]
        lock.unlock()

        if url == nil {
            // bootstrap() has not run (or found nothing) yet — discover now.
            let files = Self.discoverSymbolFiles()
            lock.lock()
            for file in files where fileURLByLibrary[Self.libraryName(for: file)] == nil {
                fileURLByLibrary[Self.libraryName(for: file)] = file
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

    /// Convenience: one resolved symbol definition from a named library.
    func symbol(library: String, name: String) -> KiCadSymbolDef? {
        library(named: library)?.symbols[name]
    }

    // MARK: - Index entries from headers

    /// Build chooser entries from one library's symbol headers, resolving
    /// property inheritance over the headers: a symbol's own property
    /// wins, otherwise the nearest extends ancestor's value is used.
    /// Duplicate symbol names keep the first occurrence. Entry order is
    /// the symbols' file order.
    private static func indexEntries(library: String,
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
    private static func discoverSymbolFiles() -> [URL] {
        var urls = Bundle.main.urls(forResourcesWithExtension: "kicad_sym",
                                    subdirectory: "Symbols") ?? []
        if urls.isEmpty {
            urls = Bundle.main.urls(forResourcesWithExtension: "kicad_sym",
                                    subdirectory: nil) ?? []
        }
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
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
