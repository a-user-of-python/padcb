import SwiftUI

/// PCB editor (part 3) — a NON-FUNCTIONAL shell modelled on KiCad 10's
/// PCB editor (pcbnew): menu strip + icon strip on top, tool rail on
/// the left, board canvas in the centre, Layers / Objects / Components
/// panels on the right, KiCad-style status bar along the bottom.
///
/// What works: opening an encrypted connection table (the same tables
/// the schematic editor writes on every save), "Sync from Schematic"
/// (re-read the loaded schematic's saved table and rebuild the board
/// in place — the saved state is the source, never a live editing
/// session), pan / zoom / fit, grid toggle, tab switching, component
/// selection, and the pin↔pad correspondence display (every pin of
/// the selected component with its net and its real footprint pad).
/// What does NOT work yet, by design: editing — no routing, no
/// moving, no mutation beyond a sync rebuild. The menus, layer/object
/// visibility toggles and selection filters are visual state only.
///
/// Board coordinates are KiCad PCB coordinates: millimetres, x right,
/// y DOWN — the canvas maps them straight to the screen (NO y-flip;
/// flipping would mirror every footprint).
struct PCBEditorView: View {
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var footprintStore: FootprintStore

    // Table / model state
    @State private var tables: [URL] = []
    @State private var selectedURL: URL? = nil
    @State private var model: BoardModel? = nil
    @State private var loadError: String? = nil
    @State private var isLoading = false
    // Sync state (v3.1): the last sync's one-line result, and the flag
    // that stops .task(id: selectedURL) from rebuilding a table a sync
    // just built when the sync itself moved the picker selection.
    @State private var isSyncing = false
    @State private var syncMessage: String? = nil
    @State private var suppressTaskLoad = false

    // Canvas state (points per mm; 2.5 pt/mm reads as "100 %" below)
    @State private var scale: CGFloat = 2.5
    @State private var offset: CGPoint = CGPoint(x: 30, y: 30)
    @State private var dragStartOffset: CGPoint? = nil
    @State private var pinchStartScale: CGFloat? = nil
    @State private var cursorBoard: FPPoint? = nil
    @State private var canvasSize: CGSize = .zero
    @State private var showGrid = true
    @State private var highlightLayer = false

    // Chrome state (visual only)
    @State private var activeTool = "Select"
    @State private var activePanelTab = "Layers"
    @State private var layerVisibility: [String: Bool] = [:]
    @State private var objectVisibility: [String: Bool] = [:]
    @State private var filterEnabled: [String: Bool] = [:]
    @State private var selectedReference: String? = nil

    private static let gridSize = 2.54 // mm, KiCad's default course grid

    private static let layerRows: [(name: String, color: Color)] = [
        ("F.Cu", Color(red: 0.85, green: 0.25, blue: 0.2)),
        ("In1.Cu", Color(red: 0.9, green: 0.6, blue: 0.2)),
        ("In2.Cu", Color(red: 0.6, green: 0.75, blue: 0.25)),
        ("B.Cu", Color(red: 0.25, green: 0.45, blue: 0.9)),
        ("F.Adhes", Color(red: 0.7, green: 0.3, blue: 0.7)),
        ("B.Adhes", Color(red: 0.45, green: 0.3, blue: 0.7)),
        ("F.Paste", Color(red: 0.6, green: 0.6, blue: 0.65)),
        ("B.Paste", Color(red: 0.5, green: 0.55, blue: 0.7)),
        ("F.SilkS", Color(red: 0.95, green: 0.9, blue: 0.6)),
        ("B.SilkS", Color(red: 0.6, green: 0.75, blue: 0.75)),
        ("F.Mask", Color(red: 0.55, green: 0.2, blue: 0.55)),
        ("B.Mask", Color(red: 0.25, green: 0.35, blue: 0.6)),
        ("Dwgs.User", Color(red: 0.65, green: 0.65, blue: 0.65)),
        ("Edge.Cuts", Color(red: 0.95, green: 0.85, blue: 0.2)),
        ("F.CrtYd", Color(red: 0.8, green: 0.8, blue: 0.8)),
        ("B.CrtYd", Color(red: 0.55, green: 0.55, blue: 0.55)),
        ("F.Fab", Color(red: 0.75, green: 0.75, blue: 0.7)),
        ("B.Fab", Color(red: 0.5, green: 0.55, blue: 0.55)),
    ]

    private static let objectRows = ["Footprints", "Tracks", "Vias", "Pads",
                                     "Zones", "Drawings", "Text", "Dimensions"]
    private static let filterRows = ["All items", "Footprints", "Tracks", "Vias",
                                     "Pads", "Zones", "Text"]
    private static let tools: [(name: String, icon: String)] = [
        ("Select", "cursorarrow"),
        ("Highlight Net", "bolt"),
        ("Delete", "trash"),
        ("Route Tracks", "point.3.connected.trianglepath.dotted"),
        ("Draw Line", "line.diagonal"),
        ("Draw Arc", "moon"),
        ("Draw Circle", "circle"),
        ("Text", "textformat"),
    ]

    private var selectedComponent: BoardComponent? {
        guard let selectedReference else { return nil }
        return model?.components.first { $0.reference == selectedReference }
    }

    private var problemCount: Int {
        guard let model else { return 0 }
        return model.globalAnomalies.count
            + model.components.reduce(0) { $0 + $1.anomalies.count }
    }

    var body: some View {
        ZStack {
            Color(white: 0.08).ignoresSafeArea()
            VStack(spacing: 0) {
                tableBar
                menuStrip
                iconStrip
                Divider()
                centre
                Divider()
                statusBar
            }
        }
        .navigationTitle("PCB Editor")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .task {
            libraryStore.bootstrap()
            footprintStore.bootstrap()
            tables = ConnectionTableStore.availableTables()
            if selectedURL == nil { selectedURL = tables.first }
        }
        .task(id: selectedURL) {
            await loadSelected()
        }
    }

    // MARK: - Centre (empty / loading / error / editor)

    @ViewBuilder
    private var centre: some View {
        if tables.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "circuitboard")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                Text("No connection tables yet")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("Save a schematic first — every save also writes an encrypted connection table, and the PCB editor builds its board from that table.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                Text(loadError)
                    .font(.callout)
                    .foregroundStyle(.red.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let model {
            HStack(spacing: 0) {
                toolRail
                Divider()
                boardCanvas(model: model)
                Divider()
                rightPanel(model: model)
                    .frame(width: 320)
            }
        } else {
            VStack(spacing: 10) {
                ProgressView().tint(.white)
                Text("Decrypting connection table…")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Table bar (entry flow)

    private var tableBar: some View {
        HStack(spacing: 12) {
            Text("Board from:")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            if tables.isEmpty {
                Text("No connection tables yet — save a schematic first…")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            } else {
                Picker("Board from", selection: $selectedURL) {
                    ForEach(tables, id: \.path) { url in
                        Text(url.deletingPathExtension().lastPathComponent)
                            .lineLimit(1)
                            .tag(Optional(url))
                    }
                }
                .pickerStyle(.menu)
                .fixedSize(horizontal: true, vertical: false)
                if isLoading {
                    ProgressView().tint(.white)
                }
                Spacer(minLength: 0)
                if let model {
                    Text("\(model.sourceFileName) · \(model.tableTitle)")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
            if let syncMessage {
                Text(syncMessage)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.green.opacity(0.9))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(white: 0.11))
    }

    private func loadSelected() async {
        // A sync that just rebuilt the board AND moved the picker to
        // the table it built sets this flag: the selection change must
        // not trigger a second, identical load.
        if suppressTaskLoad {
            suppressTaskLoad = false
            return
        }
        syncMessage = nil
        model = nil
        loadError = nil
        guard let url = selectedURL else { return }
        isLoading = true
        defer { isLoading = false }
        // Decrypt + build in a detached task so the UI never blocks on
        // crypto, JSON or library parsing; the stores' lookups are the
        // same ones the schematic editor and browser already use.
        let libStore = libraryStore
        let fpStore = footprintStore
        do {
            let built = try await Task.detached(priority: .userInitiated) { () throws -> BoardModel in
                let table = try ConnectionTableStore.load(from: url)
                return PCBBoardModelBuilder.build(
                    table: table,
                    resolveSymbol: { library, name in
                        libStore.symbol(library: library, name: name)
                    },
                    resolveFootprint: { key in
                        guard let entry = fpStore.entry(forResolutionKey: key),
                              let parsed = fpStore.footprint(for: entry)
                        else { return nil }
                        return (entry: entry, parsed: parsed)
                    })
            }.value
            // A detached task is not cancelled when the picker moves
            // on; drop the result if the selection has changed.
            if selectedURL == url {
                model = built
                if selectedReference == nil {
                    selectedReference = built.components.first?.reference
                }
            }
        } catch {
            if selectedURL == url {
                loadError = "Could not open that table: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Sync from Schematic (v3.1)

    /// KiCad's "Update PCB from Schematic", PadCB-style: re-read the
    /// SAVED connection table for the schematic on the board and
    /// rebuild the board in place. The saved table is the only source
    /// — sync never reaches into a live, unsaved editing session; if
    /// the schematic was edited and saved since the board was built,
    /// picking up exactly those changes is the point.
    ///
    /// The board being edited stays on screen during the rebuild and
    /// is swapped only on success; a failed sync changes nothing but
    /// the status line.
    private func syncFromSchematic() async {
        guard !isSyncing else { return }
        isSyncing = true
        isLoading = true
        defer {
            isSyncing = false
            isLoading = false
        }

        // A save since opening may have rewritten the loaded
        // schematic's .pct in place (same file, new bytes) or added a
        // new schematic's table — rescan before choosing.
        tables = ConnectionTableStore.availableTables()

        // Target: the table for the schematic currently on the board
        // (tables are one file per schematic, so that file's current
        // bytes ARE its newest state). With no board loaded, the
        // newest table overall — the same choice opening makes.
        let target: URL?
        if let current = selectedURL,
           tables.contains(where: { $0.path == current.path }) {
            target = current
        } else {
            target = tables.first
        }
        guard let url = target else {
            syncMessage = "Nothing to sync — save a schematic first."
            return
        }

        let libStore = libraryStore
        let fpStore = footprintStore
        do {
            // The exact decrypt + build path loadSelected uses.
            let built = try await Task.detached(priority: .userInitiated) { () throws -> BoardModel in
                let table = try ConnectionTableStore.load(from: url)
                return PCBBoardModelBuilder.build(
                    table: table,
                    resolveSymbol: { library, name in
                        libStore.symbol(library: library, name: name)
                    },
                    resolveFootprint: { key in
                        guard let entry = fpStore.entry(forResolutionKey: key),
                              let parsed = fpStore.footprint(for: entry)
                        else { return nil }
                        return (entry: entry, parsed: parsed)
                    })
            }.value
            let previous = model
            model = built
            loadError = nil
            if selectedURL != url {
                // Keep the picker on the table now on the board,
                // without .task(id:) rebuilding what sync just built.
                suppressTaskLoad = true
                selectedURL = url
            }
            if let selectedReference,
               !built.components.contains(where: { $0.reference == selectedReference }) {
                self.selectedReference = built.components.first?.reference
            } else if selectedReference == nil {
                selectedReference = built.components.first?.reference
            }
            syncMessage = Self.syncSummary(previous: previous, current: built)
        } catch {
            if model == nil {
                loadError = "Sync failed: \(error.localizedDescription)"
            }
            syncMessage = "Sync failed: \(error.localizedDescription)"
        }
    }

    /// "Synced — 12 components, 8 nets", plus the diff against the
    /// previously loaded board when it was the same schematic.
    private static func syncSummary(previous: BoardModel?, current: BoardModel) -> String {
        var text = "Synced — \(current.components.count) components, \(current.netCount) nets"
        guard let previous, previous.sourceFileName == current.sourceFileName
        else { return text }
        let diff = PCBBoardModelBuilder.diff(from: previous, to: current)
        if diff.isEmpty { return text + " · no changes" }
        var parts: [String] = []
        if !diff.addedReferences.isEmpty {
            parts.append("\(diff.addedReferences.count) added")
        }
        if !diff.removedReferences.isEmpty {
            parts.append("\(diff.removedReferences.count) removed")
        }
        if !diff.changedReferences.isEmpty {
            parts.append("\(diff.changedReferences.count) changed")
        }
        if diff.oldNetCount != diff.newNetCount {
            parts.append("nets \(diff.oldNetCount) → \(diff.newNetCount)")
        }
        return parts.isEmpty ? text : text + " · " + parts.joined(separator: ", ")
    }

    // MARK: - Menu strip (visual only this part)

    private var menuStrip: some View {
        HStack(spacing: 2) {
            ForEach(["File", "Edit", "View", "Place", "Route", "Inspect", "Tools", "Preferences"],
                    id: \.self) { name in
                Menu {
                    Button("No actions in this part") {}
                        .disabled(true)
                } label: {
                    Text(name)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                }
            }
            Spacer(minLength: 0)
            Text("Non-functional shell — display only")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.4))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(Color(white: 0.13))
    }

    private var iconStrip: some View {
        HStack(spacing: 4) {
            iconButton("folder", "Open table") {
                tables = ConnectionTableStore.availableTables()
                if selectedURL == nil { selectedURL = tables.first }
            }
            iconButton("arrow.triangle.2.circlepath", "Sync from Schematic",
                       disabled: isSyncing) {
                Task { await syncFromSchematic() }
            }
            Divider().frame(height: 26)
            iconButton("minus.magnifyingglass", "Zoom Out") { zoomOut() }
            iconButton("plus.magnifyingglass", "Zoom In") { zoomIn() }
            iconButton("arrow.up.left.and.arrow.down.right", "Fit") { fitBoard() }
            Divider().frame(height: 26)
            iconButton("grid", "Grid", active: showGrid) { showGrid.toggle() }
            iconButton("square.stack.3d.up", "Highlight layer", active: highlightLayer) {
                highlightLayer.toggle()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(white: 0.13))
    }

    private func iconButton(_ icon: String, _ label: String,
                            active: Bool = false,
                            disabled: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .lineLimit(1)
                Text(label)
                    .font(.caption2)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(active ? Color.accentColor : .white.opacity(0.9))
            .opacity(disabled ? 0.45 : 1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(active ? Color.accentColor.opacity(0.22) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    // MARK: - Left tool rail (visual tool selection only)

    private var toolRail: some View {
        VStack(spacing: 2) {
            ForEach(Array(Self.tools.enumerated()), id: \.offset) { index, tool in
                if index == 3 {
                    Divider().padding(.vertical, 4)
                }
                Button {
                    activeTool = tool.name
                } label: {
                    VStack(spacing: 1) {
                        Image(systemName: tool.icon)
                            .font(.system(size: 17, weight: .medium))
                            .lineLimit(1)
                        Text(tool.name)
                            .font(.caption2)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .foregroundStyle(activeTool == tool.name ? Color.white : .white.opacity(0.75))
                    .frame(width: 64)
                    .padding(.vertical, 6)
                    .background(activeTool == tool.name
                                ? Color.accentColor.opacity(0.35) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .frame(width: 72)
        .background(Color(white: 0.10))
    }

    // MARK: - Right panels

    private func rightPanel(model: BoardModel) -> some View {
        VStack(spacing: 0) {
            Picker("Panel", selection: $activePanelTab) {
                Text("Layers").lineLimit(1).tag("Layers")
                Text("Objects").lineLimit(1).tag("Objects")
                Text("Components").lineLimit(1).tag("Components")
            }
            .pickerStyle(.segmented)
            .padding(10)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if activePanelTab == "Objects" {
                        objectsPanel
                    } else if activePanelTab == "Components" {
                        componentsPanel(model: model)
                    } else {
                        layersPanel
                    }
                    Divider()
                    selectionFilterPanel
                    Divider()
                    detailPanel
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(white: 0.10))
    }

    private var layersPanel: some View {
        VStack(alignment: .leading, spacing: 2) {
            panelHeader("Layers")
            ForEach(Self.layerRows, id: \.name) { row in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(row.color)
                        .frame(width: 16, height: 16)
                    Text(row.name)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        layerVisibility[row.name] = !(layerVisibility[row.name] ?? true)
                    } label: {
                        Image(systemName: (layerVisibility[row.name] ?? true) ? "eye" : "eye.slash")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 2)
            }
            Text("Visibility is visual only in this part.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var objectsPanel: some View {
        VStack(alignment: .leading, spacing: 2) {
            panelHeader("Objects")
            ForEach(Self.objectRows, id: \.self) { name in
                checkRow(name, isOn: objectVisibility[name] ?? true) {
                    objectVisibility[name] = !(objectVisibility[name] ?? true)
                }
            }
            Text("Visibility is visual only in this part.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private func componentsPanel(model: BoardModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            panelHeader("Components")
            ForEach(model.components, id: \.reference) { component in
                Button {
                    selectedReference = component.reference
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 8) {
                            Text(component.reference)
                                .font(.callout.weight(.bold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                            Text(component.value)
                                .font(.callout)
                                .foregroundStyle(.white.opacity(0.75))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        if let key = component.footprintKey {
                            Text(key)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else {
                            Text("NO FOOTPRINT")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(selectedReference == component.reference
                                ? Color.accentColor.opacity(0.30) : Color.white.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if !model.excludedPowerReferences.isEmpty {
                Text("Off-board power symbols: \(model.excludedPowerReferences.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            problemsPanel(model: model)
        }
    }

    private func problemsPanel(model: BoardModel) -> some View {
        let lines: [String] = model.globalAnomalies
            + model.components.flatMap { component in
                component.anomalies.map { "\(component.reference): \($0)" }
            }
        return VStack(alignment: .leading, spacing: 4) {
            panelHeader("Problems")
            if lines.isEmpty {
                Text("No problems: every pin has a pad and every pad has a pin.")
                    .font(.callout)
                    .foregroundStyle(.green.opacity(0.9))
                    .lineLimit(3)
            } else {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                }
            }
        }
    }

    private var selectionFilterPanel: some View {
        VStack(alignment: .leading, spacing: 2) {
            panelHeader("Selection Filter")
            ForEach(Self.filterRows, id: \.self) { name in
                checkRow(name, isOn: filterEnabled[name] ?? (name == "All items")) {
                    filterEnabled[name] = !(filterEnabled[name] ?? (name == "All items"))
                }
            }
        }
    }

    private func checkRow(_ name: String, isOn: Bool,
                          toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.callout)
                    .foregroundStyle(isOn ? Color.accentColor : .white.opacity(0.6))
                    .lineLimit(1)
                Text(name)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func panelHeader(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .foregroundStyle(.white)
            .lineLimit(1)
    }

    // MARK: - Selected-component detail (pin ↔ pad correspondence)

    @ViewBuilder
    private var detailPanel: some View {
        if let component = selectedComponent {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(component.reference)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Text(component.value)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                detailRow("Symbol", component.symbolKey)
                detailRow("Footprint", component.footprintKey ?? "— none —")
                detailRow("Chosen by", matchKindWords(component.matchKind))

                Text("Pins → pads")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .padding(.top, 4)
                if component.pins.isEmpty {
                    Text("No pins could be derived for this component.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                ForEach(Array(component.pins.enumerated()), id: \.offset) { _, pin in
                    Text(pinRowText(pin))
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(2)
                }
                ForEach(Array(component.anomalies.enumerated()), id: \.offset) { _, anomaly in
                    Text(anomaly)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                }
                ForEach(Array(component.notes.enumerated()), id: \.offset) { _, note in
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        } else {
            Text("Tap a component on the board or in the Components tab to see its pin → pad bindings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: 74, alignment: .leading)
            Text(value)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    private func matchKindWords(_ kind: String?) -> String {
        switch kind {
        case "instanceChoice": return "Chosen for this placed part"
        case "property": return "Symbol Footprint property"
        case "filterExact": return "Footprint filter match"
        case let other?: return other
        case nil: return "—"
        }
    }

    /// "pin 1 — IN_A — net NET_A — pad 1 (1.60×1.60 mm, drill 0.80)"
    private func pinRowText(_ pin: BoardPinBinding) -> String {
        var text = "pin \(pin.pinNumber)"
        if !pin.pinName.isEmpty { text += " — \(pin.pinName)" }
        text += " — net \(pin.netName ?? "—")"
        if let pad = pin.pad {
            text += " — pad \(pad.number) (\(fmt(pad.width))×\(fmt(pad.height)) mm"
            if let drill = pad.drill {
                text += ", drill \(fmt(drill.width))"
                if drill.isOval { text += "×\(fmt(drill.height))" }
            }
            text += ")"
        } else {
            text += " — pad —"
        }
        return text
    }

    private func fmt(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 14) {
            Text(cursorText)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text("Grid \(fmt(Self.gridSize)) mm")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text("Zoom \(Int((Double(scale) / 2.5 * 100).rounded()))%")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text("F.Cu")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
            Text(boardInfoText)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(white: 0.11))
    }

    private var cursorText: String {
        guard let cursorBoard else { return "X —  Y —" }
        return "X \(fmt(cursorBoard.x)) mm  Y \(fmt(cursorBoard.y)) mm"
    }

    private var boardInfoText: String {
        guard let model else { return "No board loaded" }
        return "\(model.components.count) components · \(model.netCount) nets · "
            + "\(problemCount) problems · \(model.tableTitle)"
    }

    // MARK: - Canvas transforms (board mm, y DOWN -> screen points)

    private func boardToScreen(_ p: FPPoint) -> CGPoint {
        CGPoint(x: offset.x + CGFloat(p.x) * scale,
                y: offset.y + CGFloat(p.y) * scale)
    }

    private func screenToBoard(_ s: CGPoint) -> FPPoint {
        FPPoint(x: Double((s.x - offset.x) / scale),
                y: Double((s.y - offset.y) / scale))
    }

    private func zoomIn() { scale = min(scale * 1.25, 30) }
    private func zoomOut() { scale = max(scale / 1.25, 0.3) }

    private func fitBoard() {
        guard let model, canvasSize.width > 10, canvasSize.height > 10,
              !model.components.isEmpty else { return }
        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude
        for component in model.components {
            let b = componentBounds(component)
            minX = min(minX, b.minX); minY = min(minY, b.minY)
            maxX = max(maxX, b.maxX); maxY = max(maxY, b.maxY)
        }
        let w = max(maxX - minX, 1), h = max(maxY - minY, 1)
        let newScale = min(max(min((canvasSize.width - 32) / CGFloat(w),
                                   (canvasSize.height - 32) / CGFloat(h)), 0.3), 30)
        scale = newScale
        offset = CGPoint(x: canvasSize.width / 2 - CGFloat((minX + maxX) / 2) * newScale,
                         y: canvasSize.height / 2 - CGFloat((minY + maxY) / 2) * newScale)
    }

    /// Board-space bounds rect of one placed component.
    private func componentBounds(_ component: BoardComponent)
        -> (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        if let footprint = component.footprint {
            let b = footprint.bounds
            return (component.origin.x + b.minX, component.origin.y + b.minY,
                    component.origin.x + b.maxX, component.origin.y + b.maxY)
        }
        return (component.origin.x, component.origin.y,
                component.origin.x + component.boundsSize.w,
                component.origin.y + component.boundsSize.h)
    }

    // MARK: - Board canvas

    private func boardCanvas(model: BoardModel) -> some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                drawBoard(ctx: ctx, size: size, model: model)
            }
            .background(Color(red: 0.043, green: 0.055, blue: 0.043)) // #0B0E0B-ish
            .contentShape(Rectangle())
            .gesture(canvasDrag)
            .simultaneousGesture(canvasMagnify)
            .onAppear { canvasSize = geo.size }
            .onChange(of: geo.size) { _, newSize in canvasSize = newSize }
        }
    }

    private var canvasDrag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                cursorBoard = screenToBoard(value.location)
                if dragStartOffset == nil { dragStartOffset = offset }
                if let start = dragStartOffset {
                    offset = CGPoint(x: start.x + value.translation.width,
                                     y: start.y + value.translation.height)
                }
            }
            .onEnded { value in
                cursorBoard = screenToBoard(value.location)
                let moved = hypot(value.translation.width, value.translation.height)
                if moved < 5 {
                    // A tap: undo the micro-pan and treat as selection.
                    if let start = dragStartOffset { offset = start }
                    handleBoardTap(at: value.location)
                }
                dragStartOffset = nil
            }
    }

    private var canvasMagnify: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if pinchStartScale == nil { pinchStartScale = scale }
                if let start = pinchStartScale {
                    scale = min(max(start * value, 0.3), 30)
                }
            }
            .onEnded { _ in pinchStartScale = nil }
    }

    private func handleBoardTap(at location: CGPoint) {
        guard let model else { return }
        let point = screenToBoard(location)
        for component in model.components.reversed() {
            let b = componentBounds(component)
            if point.x >= b.minX - 0.5, point.x <= b.maxX + 0.5,
               point.y >= b.minY - 0.5, point.y <= b.maxY + 0.5 {
                selectedReference = component.reference
                return
            }
        }
        selectedReference = nil
    }

    // MARK: - Board drawing

    private func drawBoard(ctx: GraphicsContext, size: CGSize, model: BoardModel) {
        var ctx = ctx
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .color(Color(red: 0.043, green: 0.055, blue: 0.043)))
        if showGrid { drawGridDots(&ctx, size: size) }
        for component in model.components {
            drawComponent(&ctx, component: component,
                          selected: component.reference == selectedReference)
        }
    }

    private func drawGridDots(_ ctx: inout GraphicsContext, size: CGSize) {
        var step = Self.gridSize
        while step * Double(scale) < 9 { step *= 2 }
        let topLeft = screenToBoard(.zero)
        let bottomRight = screenToBoard(CGPoint(x: size.width, y: size.height))
        var path = Path()
        var x = (topLeft.x / step).rounded(.down) * step
        while x <= bottomRight.x {
            var y = (topLeft.y / step).rounded(.down) * step
            while y <= bottomRight.y {
                let c = boardToScreen(FPPoint(x: x, y: y))
                path.addEllipse(in: CGRect(x: c.x - 0.7, y: c.y - 0.7, width: 1.4, height: 1.4))
                y += step
            }
            x += step
        }
        ctx.fill(path, with: .color(.white.opacity(0.16)))
    }

    private func drawComponent(_ ctx: inout GraphicsContext,
                               component: BoardComponent, selected: Bool) {
        let b = componentBounds(component)
        let topLeft = boardToScreen(FPPoint(x: b.minX, y: b.minY))
        let rect = CGRect(x: topLeft.x, y: topLeft.y,
                          width: CGFloat(b.maxX - b.minX) * scale,
                          height: CGFloat(b.maxY - b.minY) * scale)

        if selected {
            ctx.stroke(Path(rect.insetBy(dx: -4, dy: -4)), with: .color(.orange),
                       style: StrokeStyle(lineWidth: 1.6, dash: [6, 4]))
        }

        guard let footprint = component.footprint else {
            // Unresolved footprint: dashed placeholder box.
            ctx.stroke(Path(rect), with: .color(.orange.opacity(0.8)),
                       style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
            ctx.draw(Text("NO FOOTPRINT")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.orange),
                     at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
            drawReferenceLabel(&ctx, component: component, rect: rect)
            return
        }

        // Silk / fab / courtyard graphics, simply. (The Layers panel's
        // eye toggles are visual state only in this part — they do not
        // change what the canvas draws.)
        for graphic in footprint.graphics {
            drawGraphic(&ctx, graphic: graphic, origin: component.origin)
        }
        // Pads with numbers + net names.
        for pad in footprint.pads {
            drawPad(&ctx, pad: pad, component: component)
        }
        drawReferenceLabel(&ctx, component: component, rect: rect)
    }

    private func drawReferenceLabel(_ ctx: inout GraphicsContext,
                                    component: BoardComponent, rect: CGRect) {
        ctx.draw(Text(component.reference)
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(.white),
                 at: CGPoint(x: rect.minX, y: rect.minY - 3),
                 anchor: UnitPoint(x: 0, y: 1))
        if !component.value.isEmpty {
            ctx.draw(Text(component.value)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.6)),
                     at: CGPoint(x: rect.minX, y: rect.maxY + 3),
                     anchor: UnitPoint(x: 0, y: 0))
        }
    }

    private func graphicColor(_ layer: String) -> Color {
        if layer.contains("CrtYd") { return .white.opacity(0.30) }
        if layer.contains("SilkS") { return Color(red: 0.95, green: 0.9, blue: 0.6) }
        if layer.contains("Fab") { return .gray.opacity(0.85) }
        if layer.contains("Mask") { return .purple.opacity(0.6) }
        if layer.contains("Paste") { return .white.opacity(0.55) }
        if layer.contains("Cu") { return .orange }
        if layer.contains("Edge") { return .yellow }
        return .white.opacity(0.6)
    }

    private func drawGraphic(_ ctx: inout GraphicsContext,
                             graphic: KiCadFootprintGraphic, origin: FPPoint) {
        let color = graphicColor(graphic.layer)
        let lineWidth = max(0.9, CGFloat(0.12) * scale)
        func map(_ p: FPPoint) -> CGPoint {
            boardToScreen(FPPoint(x: origin.x + p.x, y: origin.y + p.y))
        }
        switch graphic {
        case .line(let a, let b, _, _, _, _):
            var path = Path()
            path.move(to: map(a))
            path.addLine(to: map(b))
            ctx.stroke(path, with: .color(color), lineWidth: lineWidth)
        case .rect(let a, let b, _, _, _, let fill):
            let pa = map(a), pb = map(b)
            let rect = CGRect(x: min(pa.x, pb.x), y: min(pa.y, pb.y),
                              width: abs(pb.x - pa.x), height: abs(pb.y - pa.y))
            let path = Path(rect)
            if fill == "solid" { ctx.fill(path, with: .color(color.opacity(0.25))) }
            ctx.stroke(path, with: .color(color), lineWidth: lineWidth)
        case .circle(let center, let radius, _, _, _, let fill):
            let c = map(center)
            let r = CGFloat(radius) * scale
            let path = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            if fill == "solid" { ctx.fill(path, with: .color(color.opacity(0.25))) }
            ctx.stroke(path, with: .color(color), lineWidth: lineWidth)
        case .arc(let a, let m, let b, _, _, _, _):
            var path = Path()
            for (i, point) in arcSamplePoints(a: a, m: m, e: b).enumerated() {
                if i == 0 { path.move(to: map(point)) } else { path.addLine(to: map(point)) }
            }
            ctx.stroke(path, with: .color(color), lineWidth: lineWidth)
        case .poly(let points, _, _, _, let fill):
            guard points.count >= 2 else { return }
            var path = Path()
            for (i, point) in points.enumerated() {
                if i == 0 { path.move(to: map(point)) } else { path.addLine(to: map(point)) }
            }
            path.closeSubpath()
            if fill == "solid" { ctx.fill(path, with: .color(color.opacity(0.25))) }
            ctx.stroke(path, with: .color(color), lineWidth: lineWidth)
        case .curve(let p1, let p2, let p3, let p4, _, _, _, _):
            var path = Path()
            path.move(to: map(p1))
            path.addCurve(to: map(p4), control1: map(p2), control2: map(p3))
            ctx.stroke(path, with: .color(color), lineWidth: lineWidth)
        case .text(let text):
            guard !text.hidden, !text.text.isEmpty else { return }
            let fontSize = max(7, CGFloat(text.size) * scale)
            ctx.draw(Text(text.text)
                .font(.system(size: fontSize))
                .foregroundColor(color),
                     at: map(FPPoint(x: text.x, y: text.y)), anchor: .center)
        }
    }

    /// Pad fill colour by layer/type — the same convention as the
    /// footprint browser's padColor (a copy lives here so this view
    /// stays self-contained).
    private func padColor(_ pad: KiCadFootprintPad) -> Color {
        if pad.type == .npThruHole { return .gray.opacity(0.8) }
        let hasFront = pad.layers.contains { $0.hasPrefix("F.") || $0 == "*.Cu" }
        let hasBack = pad.layers.contains { $0.hasPrefix("B.") || $0 == "*.Cu" }
        if pad.isThroughHole { return Color(red: 0.85, green: 0.55, blue: 0.2) }
        if hasFront && hasBack { return Color(red: 0.8, green: 0.4, blue: 0.7) }
        if hasBack && !hasFront { return Color(red: 0.3, green: 0.5, blue: 0.9) }
        return Color(red: 0.9, green: 0.45, blue: 0.25)
    }

    private func drawPad(_ ctx: inout GraphicsContext,
                         pad: KiCadFootprintPad, component: BoardComponent) {
        let centreBoard = FPPoint(x: component.origin.x + pad.x,
                                  y: component.origin.y + pad.y)
        let centre = boardToScreen(centreBoard)
        let w = CGFloat(pad.width) * scale
        let h = CGFloat(pad.height) * scale

        var pctx = ctx
        pctx.translateBy(x: centre.x, y: centre.y)
        pctx.rotate(by: .degrees(pad.rotation))
        let rect = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
        let color = padColor(pad)
        switch pad.shape {
        case .circle, .oval:
            pctx.fill(Path(ellipseIn: rect), with: .color(color))
        case .roundrect:
            let ratio = CGFloat(pad.roundrectRatio ?? 0.25)
            let radius = min(w, h) / 2 * min(max(ratio, 0), 0.5) * 2
            pctx.fill(Path(roundedRect: rect, cornerRadius: radius), with: .color(color))
        case .trapezoid, .custom:
            // Approximation: the bounding rectangle (the browser draws
            // true trapezoid / custom primitives; the board shell only
            // needs the pad's extent, number and net).
            pctx.fill(Path(rect), with: .color(color.opacity(0.9)))
        case .rect:
            pctx.fill(Path(rect), with: .color(color))
        }
        if let drill = pad.drill {
            let dw = CGFloat(drill.width) * scale
            let dh = CGFloat(drill.height) * scale
            let drillRect = CGRect(x: CGFloat(drill.offsetX) * scale - dw / 2,
                                   y: CGFloat(drill.offsetY) * scale - dh / 2,
                                   width: dw, height: dh)
            pctx.fill(Path(ellipseIn: drillRect),
                      with: .color(Color(red: 0.043, green: 0.055, blue: 0.043)))
            pctx.stroke(Path(ellipseIn: drillRect), with: .color(.white.opacity(0.5)),
                        lineWidth: 1)
        }
        if !pad.number.isEmpty {
            let fontSize = max(7, min(w, h) * 0.55)
            pctx.draw(Text(pad.number)
                .font(.system(size: fontSize, weight: .bold))
                .foregroundColor(.black.opacity(0.75)),
                      at: .zero, anchor: .center)
        }

        // Net name beside/under the pad (unrotated, in board space):
        // the correspondence this whole part exists to display.
        if !pad.number.isEmpty,
           let net = component.pins.first(where: { $0.pinNumber == pad.number })?.netName {
            ctx.draw(Text(net)
                .font(.system(size: max(7, min(11, scale * 1.1)), weight: .semibold))
                .foregroundColor(Color(red: 0.55, green: 0.95, blue: 0.85)),
                     at: CGPoint(x: centre.x, y: centre.y + h / 2 + 2),
                     anchor: UnitPoint(x: 0.5, y: 0))
        }
    }

    /// Arc through three file points, sampled via the circumcenter
    /// (same approach as the footprint browser, in y-down coords).
    private func arcSamplePoints(a: FPPoint, m: FPPoint, e: FPPoint) -> [FPPoint] {
        var points: [FPPoint] = [a]
        let d = 2 * (a.x * (m.y - e.y) + m.x * (e.y - a.y) + e.x * (a.y - m.y))
        if abs(d) < 1e-9 {
            points.append(m)
            points.append(e)
            return points
        }
        let aSq = a.x * a.x + a.y * a.y
        let mSq = m.x * m.x + m.y * m.y
        let eSq = e.x * e.x + e.y * e.y
        let cx = (aSq * (m.y - e.y) + mSq * (e.y - a.y) + eSq * (a.y - m.y)) / d
        let cy = (aSq * (e.x - m.x) + mSq * (a.x - e.x) + eSq * (m.x - a.x)) / d
        let r = hypot(a.x - cx, a.y - cy)
        let a0 = atan2(a.y - cy, a.x - cx)
        let am = atan2(m.y - cy, m.x - cx)
        let a1 = atan2(e.y - cy, e.x - cx)
        func norm(_ v: Double) -> Double {
            var v = v.truncatingRemainder(dividingBy: 2 * Double.pi)
            if v < 0 { v += 2 * Double.pi }
            return v
        }
        let sweepPos = norm(a1 - a0)
        let midPos = norm(am - a0)
        let sweep = midPos <= sweepPos + 1e-9 ? sweepPos : -(2 * Double.pi - sweepPos)
        let steps = max(4, Int(abs(sweep) / (Double.pi / 36)) + 1)
        for i in 1...steps {
            let t = a0 + sweep * Double(i) / Double(steps)
            points.append(FPPoint(x: cx + r * cos(t), y: cy + r * sin(t)))
        }
        return points
    }
}
