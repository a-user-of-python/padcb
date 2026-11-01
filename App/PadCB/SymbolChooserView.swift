import SwiftUI

/// KiCad-style "Choose Symbol" sheet.
///
/// Left: searchable, library-filterable list of every symbol in the store's
/// index (grouped by library when not searching, flat and capped while
/// searching). Right: a live preview of the selected symbol rendered with
/// `SymbolRenderer`, plus its metadata. "Place" hands the fully parsed
/// definition back through `onPick` and dismisses.
struct SymbolChooserView: View {
    @ObservedObject var store: LibraryStore
    @EnvironmentObject private var footprintStore: FootprintStore
    let powerOnly: Bool
    var onPick: (KiCadSymbolDef) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var libraryFilter: String? = nil   // nil == All libraries
    @State private var selectedEntry: SymbolIndexEntry? = nil
    @State private var def: KiCadSymbolDef? = nil

    private static let searchRowCap = 800

    init(store: LibraryStore, powerOnly: Bool, onPick: @escaping (KiCadSymbolDef) -> Void) {
        _store = ObservedObject(wrappedValue: store)
        self.powerOnly = powerOnly
        self.onPick = onPick
    }

    // MARK: - Filtering

    /// Index entries after the power-only restriction and library filter,
    /// but before the search text — the source for the library menu.
    private var scopeEntries: [SymbolIndexEntry] {
        store.index.filter { entry in
            if powerOnly && entry.library != "power" { return false }
            return true
        }
    }

    /// Library KEYS (bundled base names, "user:<Name>" for custom
    /// libraries), sorted by their display names.
    private var availableLibraries: [String] {
        Array(Set(scopeEntries.map(\.libraryKey)))
            .sorted { LibraryStore.displayName(forLibraryKey: $0)
                < LibraryStore.displayName(forLibraryKey: $1) }
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func matchesSearch(_ entry: SymbolIndexEntry, query: String) -> Bool {
        entry.name.localizedCaseInsensitiveContains(query)
            || entry.description.localizedCaseInsensitiveContains(query)
            || entry.keywords.localizedCaseInsensitiveContains(query)
    }

    /// Fully filtered entries (power + library + search).
    private var filteredEntries: [SymbolIndexEntry] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return scopeEntries.filter { entry in
            if let libraryFilter, entry.libraryKey != libraryFilter { return false }
            if !query.isEmpty && !matchesSearch(entry, query: query) { return false }
            return true
        }
    }

    private var groupedEntries: [(library: String, entries: [SymbolIndexEntry])] {
        let grouped = Dictionary(grouping: filteredEntries, by: \.libraryKey)
        return grouped.keys
            .sorted { LibraryStore.displayName(forLibraryKey: $0)
                < LibraryStore.displayName(forLibraryKey: $1) }
            .map { key in
                (library: key, entries: grouped[key] ?? [])
            }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if !store.indexReady {
                    loadingView
                } else {
                    VStack(spacing: 0) {
                        filterBar
                        importStatusStrip
                        Divider()
                        HStack(spacing: 0) {
                            symbolList
                                .frame(maxWidth: .infinity)
                            Divider()
                            previewPane
                                .frame(width: 300)
                        }
                        Divider()
                        footer
                    }
                }
            }
            .background(Color(white: 0.10))
            .navigationTitle(powerOnly ? "Choose Power Symbol" : "Choose Symbol")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .lineLimit(1)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        store.rescanUserLibraries()
                        footprintStore.rescan()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                                .lineLimit(1)
                            Text("Rescan")
                                .lineLimit(1)
                        }
                    }
                    .disabled(store.isScanningCustomLibraries || footprintStore.isScanning)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task(id: selectedEntry?.id) {
            // Load (and parse, on first use) the full definition for the
            // preview pane whenever the selection changes.
            guard let entry = selectedEntry else {
                def = nil
                return
            }
            def = store.symbol(library: entry.libraryKey, name: entry.name)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .tint(.white)
            Text("Loading symbol libraries…")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                TextField("Search symbols — name, description, keywords", text: $searchText)
                    .autocorrectionDisabled()
                    .lineLimit(1)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))

            Menu {
                Button("All libraries") { libraryFilter = nil }
                Divider()
                ForEach(availableLibraries, id: \.self) { library in
                    Button(LibraryStore.displayName(forLibraryKey: library)) {
                        libraryFilter = library
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "books.vertical")
                        .lineLimit(1)
                    Text(libraryFilter.map { LibraryStore.displayName(forLibraryKey: $0) } ?? "All libraries")
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// One slim line under the filter bar while a custom-library
    /// rescan runs or when the last scan skipped files.
    @ViewBuilder
    private var importStatusStrip: some View {
        if store.isScanningCustomLibraries {
            HStack(spacing: 8) {
                ProgressView().tint(.white)
                Text("Scanning your Libraries folder…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        } else if !store.customLibraryIssues.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                Text("\(store.customLibraryIssues.count) library file\(store.customLibraryIssues.count == 1 ? "" : "s") skipped: \(store.customLibraryIssues.first ?? "")")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }

    // MARK: - List

    @ViewBuilder
    private var symbolList: some View {
        if filteredEntries.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("No symbols match.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isSearching {
            let capped = Array(filteredEntries.prefix(Self.searchRowCap))
            List {
                Section {
                    ForEach(capped) { entry in
                        entryRow(entry)
                    }
                } header: {
                    if filteredEntries.count > capped.count {
                        Text("\(filteredEntries.count.formatted()) matches — showing first \(capped.count). Refine your search.")
                            .lineLimit(2)
                    } else {
                        Text("\(filteredEntries.count.formatted()) matches")
                            .lineLimit(1)
                    }
                }
            }
            .listStyle(.insetGrouped)
        } else {
            List {
                ForEach(groupedEntries, id: \.library) { group in
                    Section(LibraryStore.displayName(forLibraryKey: group.library)) {
                        ForEach(group.entries) { entry in
                            entryRow(entry)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func entryRow(_ entry: SymbolIndexEntry) -> some View {
        let isSelected = selectedEntry?.id == entry.id
        return Button {
            selectedEntry = entry
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if entry.source == .custom {
                        Text("CUSTOM")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.black)
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.green, in: Capsule())
                    }
                }
                if !entry.description.isEmpty {
                    Text(entry.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.30) : Color.clear)
    }

    // MARK: - Preview

    @ViewBuilder
    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let entry = selectedEntry, let def {
                previewCanvas(def: def)
                    .frame(height: 220)
                    .background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                    )

                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(entry.name)
                            .font(.headline)
                            .lineLimit(1)
                        metadataRow("Library", LibraryStore.displayName(forLibraryKey: entry.libraryKey))
                        if !entry.description.isEmpty {
                            metadataBlock("Description", entry.description)
                        }
                        if !entry.keywords.isEmpty {
                            metadataBlock("Keywords", entry.keywords)
                        }
                        if let footprint = def.property("Footprint"),
                           !footprint.isEmpty, footprint != "~" {
                            metadataRow("Footprint", footprint)
                            if let match = footprintStore.resolve(reference: footprint) {
                                Text("Imported footprint available: \(match.key) — \(match.padCount) pads")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                                    .lineLimit(2)
                            } else {
                                Text("No imported footprint matches this reference yet — drop its .kicad_mod into the Footprints folder.")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .lineLimit(2)
                            }
                        }
                        if let url = entry.datasheetURL ?? datasheetURL(from: def) {
                            Link(destination: url) {
                                HStack(spacing: 6) {
                                    Image(systemName: "link")
                                        .lineLimit(1)
                                    Text("Open Datasheet")
                                        .lineLimit(1)
                                }
                                .font(.callout.weight(.medium))
                            }
                        }
                        metadataRow("Pins", "\(pinCount(of: def))")
                        metadataRow("Units", "\(def.unitCount) unit\(def.unitCount == 1 ? "" : "s")")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if selectedEntry != nil {
                VStack(spacing: 10) {
                    ProgressView()
                        .tint(.white)
                    Text("Loading symbol…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "square.dashed")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("Select a symbol to preview it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    /// Renders the selected definition (unit 1) fitted into the pane.
    /// Symbol-local coordinates are y-up; the canvas is y-down, so the map
    /// flips y around the fitted bounds.
    private func previewCanvas(def: KiCadSymbolDef) -> some View {
        let bounds = SymbolRenderer.graphicsBounds(def: def, unit: 1)
        return Group {
            if bounds.width <= 0 || bounds.height <= 0 {
                Text("No preview")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Canvas { ctx, size in
                    let margin: CGFloat = 16
                    let availableW = max(size.width - margin * 2, 1)
                    let availableH = max(size.height - margin * 2, 1)
                    let scale = min(availableW / bounds.width, availableH / bounds.height)
                    let drawnW = bounds.width * scale
                    let drawnH = bounds.height * scale
                    let originX = (size.width - drawnW) / 2
                    let originY = (size.height - drawnH) / 2
                    let map: (CGPoint) -> CGPoint = { local in
                        CGPoint(
                            x: originX + (local.x - bounds.minX) * scale,
                            y: originY + drawnH - (local.y - bounds.minY) * scale
                        )
                    }
                    SymbolRenderer.draw(def: def, unit: 1, in: ctx, map: map,
                                        scale: scale, showPinNumbers: true, showPinNames: true)
                }
            }
        }
    }

    private func metadataRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(value)
                .font(.callout)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private func metadataBlock(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.callout)
                .lineLimit(3)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Cancel") { dismiss() }
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer()
            if let entry = selectedEntry {
                Text("\(LibraryStore.displayName(forLibraryKey: entry.libraryKey)):\(entry.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button {
                if let def {
                    onPick(def)
                    dismiss()
                }
            } label: {
                Text("Place Symbol")
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.borderedProminent)
            .disabled(def == nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Helpers

    /// Pins visible for a placed unit-1 instance: common (unit 0) pins plus
    /// unit 1's own pins.
    private func pinCount(of def: KiCadSymbolDef) -> Int {
        (def.units[0]?.pins.count ?? 0) + (def.units[1]?.pins.count ?? 0)
    }

    private func datasheetURL(from def: KiCadSymbolDef) -> URL? {
        guard let raw = def.property("Datasheet"),
              !raw.isEmpty, raw != "~",
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }
}
