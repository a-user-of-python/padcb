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
/// - Documents/Libraries/         user-supplied KiCad symbol libraries
///                                (*.kicad_sym, part 2)
/// - Documents/Footprints/        user-supplied KiCad footprints
///                                (*.kicad_mod, part 2; *.pretty-style
///                                subfolders are scanned recursively)
/// - Documents/ConnectionTables/  encrypted connection tables (*.pct),
///                                one per saved schematic (part 2)
enum PadCBPaths {
    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    static var schematicsDirectory: URL {
        documentsDirectory.appendingPathComponent("PadCB", isDirectory: true)
    }

    static var userLibrariesDirectory: URL {
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
    /// before the user has dropped anything into them.
    static func ensureStandardDirectories() {
        let fm = FileManager.default
        for dir in [schematicsDirectory, userLibrariesDirectory,
                    footprintsDirectory, connectionTablesDirectory] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    static func ensureDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
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
