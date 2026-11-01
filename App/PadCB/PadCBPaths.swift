import Foundation

/// The app's Documents-folder layout — the single source of truth for
/// every folder PadCB reads or writes inside its sandbox.
///
/// File sharing is enabled (see Info.plist: UIFileSharingEnabled +
/// LSSupportsOpeningDocumentsInPlace, verified inside the built IPA by
/// CI), so everything under Documents is reachable from the Files app /
/// Finder with the device plugged in. NO system document picker is used
/// anywhere in PadCB — Sean's developer certificate breaks it — so these
/// folders plus the in-app lists are the whole file UI.
///
/// Layout:
/// - Documents/PadCB/             saved schematics (PadCB JSON, part 1)
/// - Documents/Symbols/           user-supplied KiCad symbol libraries
///                                (*.kicad_sym, part 3 — renamed from
///                                Documents/Libraries, see below)
/// - Documents/Footprints/        user-supplied KiCad footprints
///                                (*.kicad_mod, part 2; *.pretty-style
///                                subfolders are scanned recursively)
/// - Documents/ConnectionTables/  encrypted connection tables (*.pct),
///                                one per saved schematic (part 2)
///
/// PART 3 RENAME (Sean): the user symbol-library folder was
/// Documents/Libraries in part 2 and is Documents/Symbols from part 3
/// on (the footprints folder keeps its name). Existing installs may
/// still hold libraries in the old folder;
/// `migrateLegacySymbolLibraries()` moves them across — never
/// overwriting, never deleting without moving — and
/// LibraryStore calls it before its scan. Both folders stay plain
/// user-visible folders; the library KEY rules are unchanged (bundled
/// "Device", custom "user:Device").
enum PadCBPaths {
    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    static var schematicsDirectory: URL {
        documentsDirectory.appendingPathComponent("PadCB", isDirectory: true)
    }

    /// User-supplied KiCad symbol libraries (*.kicad_sym, flat folder).
    /// Part 3 name — LibraryStore scans here.
    static var userSymbolsDirectory: URL {
        documentsDirectory.appendingPathComponent("Symbols", isDirectory: true)
    }

    /// The part-2 location of user symbol libraries,
    /// Documents/Libraries. Kept ONLY as the migration source for
    /// `migrateLegacySymbolLibraries()`; nothing scans or creates it
    /// any more.
    static var legacyUserLibrariesDirectory: URL {
        documentsDirectory.appendingPathComponent("Libraries", isDirectory: true)
    }

    static var footprintsDirectory: URL {
        documentsDirectory.appendingPathComponent("Footprints", isDirectory: true)
    }

    static var connectionTablesDirectory: URL {
        documentsDirectory.appendingPathComponent("ConnectionTables", isDirectory: true)
    }

    /// Creates the four standard folders (best effort). Called on launch
    /// and before scans/writes so the folders are visible in Files even
    /// before the user has dropped anything into them. The legacy
    /// Libraries folder is deliberately NOT created (part 3 rename).
    static func ensureStandardDirectories() {
        let fm = FileManager.default
        for dir in [schematicsDirectory, userSymbolsDirectory,
                    footprintsDirectory, connectionTablesDirectory] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    static func ensureDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Moves user symbol libraries from the legacy folder
    /// (Documents/Libraries) into Documents/Symbols:
    /// - every top-level *.kicad_sym file is MOVED (never copied, never
    ///   deleted without moving);
    /// - when Documents/Symbols already holds a file of the same name,
    ///   the legacy file moves as "<Base> (Legacy).kicad_sym" instead —
    ///   both files stay resolvable as separate libraries under the
    ///   existing key rules, and nothing is ever overwritten (if the
    ///   "(Legacy)" name is also taken, a numbered variant is used);
    /// - non-.kicad_sym files are left in place.
    /// Returns human-readable notes: one per moved / left / failed
    /// file, plus a summary line. Returns [] when the legacy folder
    /// does not exist (the common case after the first launch on
    /// part 3, and on fresh installs).
    static func migrateLegacySymbolLibraries() -> [String] {
        let fm = FileManager.default
        let legacy = legacyUserLibrariesDirectory
        let target = userSymbolsDirectory
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: legacy.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return []
        }
        ensureDirectory(target)

        let items = ((try? fm.contentsOfDirectory(
            at: legacy, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var notes: [String] = []
        var moved = 0
        var left = 0
        for url in items {
            let fileName = url.lastPathComponent
            let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?
                .isRegularFile ?? false
            guard isRegular, url.pathExtension.lowercased() == "kicad_sym" else {
                notes.append("\(fileName): left in Libraries (not a .kicad_sym file).")
                left += 1
                continue
            }
            var destination = target.appendingPathComponent(fileName)
            var renamed = false
            if fm.fileExists(atPath: destination.path) {
                let base = url.deletingPathExtension().lastPathComponent
                destination = target.appendingPathComponent("\(base) (Legacy).kicad_sym")
                renamed = true
                var suffix = 2
                while fm.fileExists(atPath: destination.path) {
                    destination = target
                        .appendingPathComponent("\(base) (Legacy \(suffix)).kicad_sym")
                    suffix += 1
                }
            }
            do {
                try fm.moveItem(at: url, to: destination)
                moved += 1
                notes.append(renamed
                    ? "\(fileName): a library of this name already exists in Symbols; moved as \(destination.lastPathComponent)."
                    : "\(fileName): moved from Libraries to Symbols.")
            } catch {
                notes.append("\(fileName): could not be moved to Symbols (\(error.localizedDescription)); left in Libraries.")
                left += 1
            }
        }
        if !items.isEmpty {
            notes.append("Symbol library migration: \(moved) file\(moved == 1 ? "" : "s") moved from Libraries to Symbols, \(left) left in place.")
        }
        return notes
    }

    /// File-name stem safe for use as a table name: mirrors the schematic
    /// save-name sanitising in FileListView (no "/" or ":").
    static func sanitizedStem(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for ext in [".json", ".pct"] where name.lowercased().hasSuffix(ext) {
            name = String(name.dropLast(ext.count))
        }
        name = name.replacingOccurrences(of: "/", with: "-")
                   .replacingOccurrences(of: ":", with: "-")
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
