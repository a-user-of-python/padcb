import Foundation
import Combine

/// Where a footprint came from: the bundled official KiCad libraries,
/// or a file the user dropped into Documents/Footprints.
enum FootprintSource: String {
    case bundled
    case user
}

/// One footprint known to the browser.
///
/// Identity follows KiCad's .pretty convention: the footprint's name is
/// its FILE base name and its library/group is the folder it sits in —
/// a `Package_SO.pretty` folder name loses the `.pretty` suffix, and a
/// file dropped straight into Documents/Footprints groups under
/// "Footprints". The canonical key is "Group:Name", exactly the form
/// symbol Footprint properties use ("Package_SO:SOIC-8_...").
struct FootprintEntry: Identifiable {
    var source: FootprintSource
    var group: String
    var name: String
    /// Original file name, e.g. "SOIC-8_3.9x4.9mm_P1.27mm.kicad_mod".
    var fileName: String
    /// Path relative to its root (Documents/Footprints or the bundle's
    /// Footprints folder), for display.
    var relativePath: String
    var url: URL
    var description: String
    var tags: [String]
    var padCount: Int
    var graphicCount: Int
    /// The full parse. User footprints are parsed at scan time; bundled
    /// footprints are parsed on demand (see FootprintStore.footprint(for:))
    /// because the bundled corpus is ~15k files.
    var parsed: KiCadFootprint?

    /// Canonical "Group:Name" key.
    var key: String { group + ":" + name }

    /// The key recorded in connection tables: bundled footprints use
    /// the plain canonical key; user footprints get a "user:" prefix —
    /// the same no-shadowing rule as symbol libraries (a user footprint
    /// never silently replaces a bundled one in the browser, and the
    /// table records exactly which copy resolved).
    var resolutionKey: String {
        source == .user ? "user:" + key : key
    }

    var id: String { resolutionKey }
}

/// One row of the CI-generated FootprintIndex.json that ships inside
/// the bundle's Footprints folder (built by tools/FootprintCensus from
/// the REAL Swift parser over the pinned official corpus).
private struct BundledFootprintIndexRow: Codable {
    var group: String
    var name: String
    var file: String // path relative to the bundle Footprints folder
    var description: String
    var tags: [String]
    var pads: Int
    var graphics: Int
}

/// Holds the footprint browser's data: the bundled official KiCad
/// footprint libraries (index loaded at launch, files parsed on
/// demand) plus the user's own footprints from Documents/Footprints
/// (fully parsed at scan time — a user's own set is small).
///
/// User scanning is recursive, so both loose files and `.pretty`-style
/// library folders work. Files on disk are the source of truth —
/// nothing is persisted. Malformed user files are skipped and reported
/// in `issues`; a bad file can never crash the scan or hide good ones.
final class FootprintStore: ObservableObject {
    @Published var userFootprints: [FootprintEntry] = []
    @Published var bundledFootprints: [FootprintEntry] = []
    /// Human-readable per-file problems from the last user scan.
    @Published var issues: [String] = []
    @Published var isScanning = false
    @Published var didScan = false

    private var didBootstrap = false
    private var parsedCache: [String: KiCadFootprint] = [:]

    /// Every known footprint, user-imported first, then bundled.
    var footprints: [FootprintEntry] { userFootprints + bundledFootprints }

    // MARK: - Bootstrap / rescan

    /// Idempotent: loads the bundled index and scans Documents/Footprints.
    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true
        Task.detached(priority: .utility) { [weak self] in
            let bundled = Self.loadBundledEntries()
            await MainActor.run { [weak self] in
                self?.bundledFootprints = bundled
            }
        }
        rescan()
    }

    /// Re-reads Documents/Footprints from disk (the browser's Rescan
    /// affordance; also runs once per launch via bootstrap()).
    func rescan() {
        guard !isScanning else { return }
        isScanning = true
        Task.detached(priority: .utility) { [weak self] in
            let result = Self.scanUserFootprintFiles()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.userFootprints = result.entries
                self.issues = result.issues
                self.isScanning = false
                self.didScan = true
            }
        }
    }

    // MARK: - On-demand parse

    /// The full parse for an entry. User entries carry it already;
    /// bundled entries are read + parsed here on first use and cached.
    /// Returns nil when the file cannot be parsed.
    func footprint(for entry: FootprintEntry) -> KiCadFootprint? {
        if let parsed = entry.parsed { return parsed }
        if let cached = parsedCache[entry.resolutionKey] { return cached }
        guard let data = try? Data(contentsOf: entry.url) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard let parsed = try? KiCadFootprint.parse(name: entry.name, text: text)
        else { return nil }
        parsedCache[entry.resolutionKey] = parsed
        return parsed
    }

    // MARK: - Resolution (symbol Footprint property -> footprint)

    /// Resolves a symbol's Footprint property (KiCad's "Lib:Name" form,
    /// e.g. "Package_SO:SOIC-8_3.9x4.9mm_P1.27mm") against every known
    /// footprint:
    /// 1. exact "Group:Name" match — a USER copy wins over a bundled
    ///    copy of the same key (the user imported theirs on purpose;
    ///    both still appear in the browser, and the recorded
    ///    resolutionKey shows which one resolved);
    /// 2. otherwise a name-only match, again preferring a unique user
    ///    copy, then a unique overall match (covers files dropped
    ///    straight into Documents/Footprints, whose group is
    ///    "Footprints" rather than the KiCad library name).
    /// Returns nil for an empty/"~" reference or no unambiguous match.
    func resolve(reference rawValue: String?) -> FootprintEntry? {
        guard let raw = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, raw != "~" else { return nil }
        let all = footprints

        var wantedName = raw
        if let colon = raw.firstIndex(of: ":") {
            let group = String(raw[raw.startIndex..<colon])
            let name = String(raw[raw.index(after: colon)...])
            let exact = all.filter {
                $0.group.caseInsensitiveCompare(group) == .orderedSame
                    && $0.name.caseInsensitiveCompare(name) == .orderedSame
            }
            if let user = exact.first(where: { $0.source == .user }) { return user }
            if let bundled = exact.first { return bundled }
            wantedName = name
        }
        let nameMatches = all.filter {
            $0.name.caseInsensitiveCompare(wantedName) == .orderedSame
        }
        let userMatches = nameMatches.filter { $0.source == .user }
        if userMatches.count == 1 { return userMatches[0] }
        return nameMatches.count == 1 ? nameMatches[0] : nil
    }

    /// The resolution key of the footprint a Footprint property
    /// resolves to, or nil. Recorded into connection tables so the PCB
    /// editor can consume the resolution without re-deriving it.
    func resolvedKey(forFootprintReference rawValue: String?) -> String? {
        resolve(reference: rawValue)?.resolutionKey
    }

    // MARK: - Bundled corpus

    private static func loadBundledEntries() -> [FootprintEntry] {
        // Preferred path: the CI-generated index (real-parser data).
        let indexURL = Bundle.main.url(forResource: "FootprintIndex",
                                       withExtension: "json",
                                       subdirectory: "Footprints")
            ?? Bundle.main.url(forResource: "FootprintIndex", withExtension: "json")
        if let indexURL,
           let data = try? Data(contentsOf: indexURL),
           let rows = try? JSONDecoder().decode([BundledFootprintIndexRow].self, from: data) {
            let root = indexURL.deletingLastPathComponent()
            return rows.map { row in
                FootprintEntry(
                    source: .bundled,
                    group: row.group,
                    name: row.name,
                    fileName: (row.file as NSString).lastPathComponent,
                    relativePath: row.file,
                    url: root.appendingPathComponent(row.file),
                    description: row.description,
                    tags: row.tags,
                    padCount: row.pads,
                    graphicCount: row.graphics,
                    parsed: nil)
            }
        }

        // Fallback (local dev builds where the CI corpus step has not
        // run): parse whatever .kicad_mod files sit in the bundle's
        // Footprints folder. Correct, just slower.
        guard let root = Bundle.main.resourceURL?
            .appendingPathComponent("Footprints", isDirectory: true) else { return [] }
        return scanFootprintTree(root: root, source: .bundled, parseEagerly: true)
    }

    // MARK: - User scanning

    private struct ScanResult {
        var entries: [FootprintEntry]
        var issues: [String]
    }

    private static func scanUserFootprintFiles() -> ScanResult {
        let root = PadCBPaths.footprintsDirectory
        PadCBPaths.ensureDirectory(root)
        var issues: [String] = []
        let entries = scanFootprintTree(root: root, source: .user,
                                        parseEagerly: true, issues: &issues)
        return ScanResult(entries: entries, issues: issues)
    }

    /// Recursive .kicad_mod scan shared by the user folder and the
    /// bundled fallback. With `parseEagerly`, every file is fully
    /// parsed; unreadable/empty files are skipped into `issues` (when
    /// provided) instead of failing the scan.
    private static func scanFootprintTree(root: URL,
                                          source: FootprintSource,
                                          parseEagerly: Bool,
                                          issues: inout [String]) -> [FootprintEntry] {
        let fm = FileManager.default
        var urls: [URL] = []
        if let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                if url.pathExtension.lowercased() == "kicad_mod" {
                    urls.append(url)
                }
            }
        }
        urls.sort { $0.path < $1.path }

        var entries: [FootprintEntry] = []
        var seenKeys = Set<String>()
        for url in urls {
            let baseName = url.deletingPathExtension().lastPathComponent
            let group = groupName(for: url, root: root)
            let key = (group + ":" + baseName).lowercased()
            guard !seenKeys.contains(key) else {
                issues.append("\(url.lastPathComponent): another file already provides \(group):\(baseName); skipped.")
                continue
            }
            guard let data = try? Data(contentsOf: url) else {
                issues.append("\(url.lastPathComponent): could not be read; skipped.")
                continue
            }
            let text = String(decoding: data, as: UTF8.self)
            do {
                let footprint = try KiCadFootprint.parse(name: baseName, text: text)
                guard !footprint.pads.isEmpty || !footprint.graphics.isEmpty else {
                    issues.append("\(url.lastPathComponent): no pads or graphics found; skipped.")
                    continue
                }
                seenKeys.insert(key)
                entries.append(FootprintEntry(
                    source: source,
                    group: group,
                    name: baseName,
                    fileName: url.lastPathComponent,
                    relativePath: relativePath(of: url, root: root),
                    url: url,
                    description: footprint.description,
                    tags: footprint.tags,
                    padCount: footprint.pads.count,
                    graphicCount: footprint.graphics.count,
                    parsed: parseEagerly ? footprint : nil))
            } catch {
                issues.append("\(url.lastPathComponent): not a readable KiCad footprint (\(error.localizedDescription)); skipped.")
            }
        }
        entries.sort { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
        return entries
    }

    private static func scanFootprintTree(root: URL,
                                          source: FootprintSource,
                                          parseEagerly: Bool) -> [FootprintEntry] {
        var issues: [String] = []
        return scanFootprintTree(root: root, source: source,
                                 parseEagerly: parseEagerly, issues: &issues)
    }

    /// The .pretty-style group for a file: its immediate parent folder,
    /// with a ".pretty" suffix stripped; the root itself groups under
    /// the root folder's name ("Footprints" for the user folder).
    private static func groupName(for url: URL, root: URL) -> String {
        let parent = url.deletingLastPathComponent()
        if parent.path == root.path { return root.lastPathComponent }
        var name = parent.lastPathComponent
        if name.lowercased().hasSuffix(".pretty") {
            name = String(name.dropLast(".pretty".count))
        }
        return name.isEmpty ? root.lastPathComponent : name
    }

    private static func relativePath(of url: URL, root: URL) -> String {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        if url.path.hasPrefix(rootPath) {
            return String(url.path.dropFirst(rootPath.count))
        }
        return url.lastPathComponent
    }
}
