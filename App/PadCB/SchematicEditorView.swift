import SwiftUI

/// KiCad-style schematic editor scaffold:
///
/// ```
/// ┌──────────────────────────────────────────────┐
/// │ Open Save │ Undo Redo │ Zoom- Zoom+ Fit │ ⚙T │
/// ├──┬──────────────────────────────────┬────────┤
/// │T │                                  │  R     │
/// │o │            canvas                │  tools │
/// │o │                    ┌─properties─┐│        │
/// │l │                    │  card      ││        │
/// ├──┴────────────────────┴────────────┴┴────────┤
/// │ cursor · zoom · tool · selection             │
/// └──────────────────────────────────────────────┘
/// ```
///
/// The canvas itself (rendering, gestures, wire routing) lives in
/// `SchematicCanvasView`; this view owns the document, tool state,
/// selection, sheets (symbol chooser, open/save) and all chrome.
///
/// Single-line discipline everywhere (LumenScene lesson): every label is
/// `.lineLimit(1)` and top-bar buttons are `.fixedSize(horizontal: true)`.
struct SchematicEditorView: View {
    /// Cross-probe transport (part 5.3, S8): pushes the PCB
    /// editor ("pcb") onto HomeView's navigation path. Defaulted
    /// so other construction sites keep compiling unchanged.
    var navigate: (String) -> Void = { _ in }

    @StateObject private var document = SchematicDocument()
    @StateObject private var canvasState = CanvasViewState()
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var footprintStore: FootprintStore
    @EnvironmentObject private var crossProbe: CrossProbe
    @EnvironmentObject private var liveSession: LiveSessionRegistry

    @Environment(\.openURL) private var openURL

    @State private var tool: EditorTool = .select
    @State private var selection: UUID? = nil
    @State private var pendingSymbol: KiCadSymbolDef? = nil

    @State private var showChooser = false
    @State private var chooserPowerOnly = false
    @State private var showOpen = false
    @State private var showSave = false
    @State private var showTitleEdit = false
    @State private var showProperties = true

    @State private var titleDraft = ""
    @State private var errorMessage: String? = nil
    // Part 5.2: New-document confirmation, ERC sheet, and a
    // one-line info alert for Annotate/ERC outcomes.
    @State private var showNewConfirm = false
    @State private var showERC = false
    @State private var ercFindings: [ERCFinding] = []
    @State private var infoMessage: String? = nil

    // Part 5.3 state: net highlight (S1) + net navigator (S10)
    // share one lazily built connection table; Find (S2); the
    // fields table (S6); symbol swap target (S5); the connection
    // selection (S11); annotate options (S7); and a one-line
    // action status shown in the status bar.
    @State private var highlightTable: ConnectionTable? = nil
    @State private var highlightedNet: String? = nil
    @State private var highlightArmed = false
    @State private var showNets = false
    @State private var showFind = false
    @State private var findQuery = ""
    @State private var findResults: [SchematicFindMatch] = []
    @State private var showFindResults = false
    @State private var showFields = false
    @State private var fieldRowsSnapshot: [SymbolFieldRow] = []
    @State private var fieldSeed: [UUID: FieldEdit] = [:]
    @State private var fieldEdits: [UUID: FieldEdit] = [:]
    @State private var swapTargetID: UUID? = nil
    @State private var selectConnectionArmed = false
    @State private var connectionSelection: Set<UUID> = []
    @State private var connectionNetName: String? = nil
    @State private var actionStatus: String? = nil
    @State private var showAnnotateOptions = false
    @State private var annotateSortRaw = 0 // 0 sheet order, 1 by X, 2 by Y
    @State private var annotateResetAll = false
    @State private var annotateStartText = "1"

    // MARK: - Derived state

    private var selectedPlaced: PlacedSymbol? {
        guard let selection else { return nil }
        return document.state.symbols.first(where: { $0.id == selection })
    }

    private var selectedDef: KiCadSymbolDef? {
        guard let placed = selectedPlaced else { return nil }
        return store.symbol(library: placed.library, name: placed.symbolName)
    }

    private var selectedDatasheetURL: URL? {
        SchematicEditorSupport.datasheetURL(from: selectedDef)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            if showFind {
                findBar
                Divider()
            }
            HStack(spacing: 0) {
                leftTools
                Divider()
                ZStack(alignment: .trailing) {
                    SchematicCanvasView(
                        document: document,
                        store: store,
                        canvasState: canvasState,
                        tool: $tool,
                        selection: $selection,
                        pendingSymbol: pendingSymbol,
                        onRequestSymbolChooser: { powerOnly in
                            chooserPowerOnly = powerOnly
                            showChooser = true
                        },
                        onConsumePlacementDone: {
                            pendingSymbol = nil
                        },
                        highlightedWireIDs: highlightedNet.map {
                            Set(highlightTable?.wireIDs(forNet: $0) ?? [])
                        } ?? [],
                        highlightedSymbolIDs: highlightedNet.map {
                            Set(highlightTable?.symbolInstanceIDs(forNet: $0) ?? [])
                        } ?? [],
                        isHighlightActive: highlightedNet != nil,
                        connectionSelectedWireIDs: connectionSelection,
                        highlightArmed: $highlightArmed,
                        selectConnectionArmed: $selectConnectionArmed,
                        onHighlightWire: { wireID in
                            resolveHighlight(wireID: wireID)
                        },
                        onHighlightPin: { instanceID, pinNumber in
                            resolveHighlight(instanceID: instanceID,
                                             pinNumber: pinNumber)
                        },
                        onSelectConnectionWire: { wireID in
                            resolveConnectionSelection(wireID: wireID)
                        },
                        onClearHighlight: { clearHighlight() },
                        onClearConnectionSelection: { clearConnectionSelection() },
                        onDeleteConnectionSelection: { deleteConnectionSelection() }
                    )
                    if showProperties, let placed = selectedPlaced {
                        SymbolPropertiesCard(
                            document: document,
                            placedID: placed.id,
                            store: store,
                            onClose: { selection = nil },
                            onSelect: { selection = $0 },
                            onShowOnBoard: { showSelectedOnBoard() },
                            onChangeSymbol: {
                                swapTargetID = placed.id
                                chooserPowerOnly = false
                                showChooser = true
                            },
                            onUpdateFromLibrary: { updateSelectedFromLibrary() }
                        )
                        .padding(.trailing, 12)
                        .padding(.vertical, 12)
                    }
                }
                Divider()
                rightTools
            }
            Divider()
            statusBar
        }
        .background(Color(white: 0.10))
        .navigationTitle(document.state.title)
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showChooser, onDismiss: { swapTargetID = nil }) {
            SymbolChooserView(store: store, powerOnly: chooserPowerOnly,
                              swapMode: swapTargetID != nil) { def in
                // Part 5.3, S5: with a swap target set the pick
                // CHANGES that symbol's definition in place (the
                // chooser delivered the full definition; its
                // library/name are the new key — the same values
                // placement records); otherwise it places as before.
                if let target = swapTargetID {
                    let reference = document.state.symbols
                        .first(where: { $0.id == target })?.reference ?? "Symbol"
                    let changed = document.changeSymbol(
                        id: target, toLibrary: def.library, name: def.name,
                        definition: def)
                    actionStatus = changed
                        ? "Changed \(reference) to \(def.name)"
                        : "Already \(def.name) — no change"
                    swapTargetID = nil
                } else {
                    pendingSymbol = def
                    tool = .placeSymbol
                }
            }
        }
        .sheet(isPresented: $showOpen) {
            FileListView(mode: .open, initialName: document.state.title) { url in
                do {
                    try document.load(from: url)
                    selection = nil
                    pendingSymbol = nil
                    resetNetState()
                } catch {
                    errorMessage = "Could not open that file: \(error.localizedDescription)"
                }
            }
        }
        .sheet(isPresented: $showSave) {
            FileListView(mode: .save, initialName: document.state.title) { url in
                saveSchematic(to: url)
            }
        }
        .alert("Rename Schematic", isPresented: $showTitleEdit) {
            TextField("Title", text: $titleDraft)
            Button("Cancel", role: .cancel) { }
            Button("Save") {
                let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                document.state.title = trimmed.isEmpty ? "Untitled" : trimmed
            }
        } message: {
            Text("Set the schematic title.")
        }
        .alert("Something Went Wrong",
               isPresented: Binding(get: { errorMessage != nil },
                                    set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Start a New Schematic?",
               isPresented: $showNewConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("New Schematic", role: .destructive) {
                startNewDocument()
            }
        } message: {
            Text("The current schematic is replaced by an empty one. Anything not saved is lost.")
        }
        .alert("PadCB",
               isPresented: Binding(get: { infoMessage != nil },
                                    set: { if !$0 { infoMessage = nil } })) {
            Button("OK") { infoMessage = nil }
        } message: {
            Text(infoMessage ?? "")
        }
        .sheet(isPresented: $showERC) {
            ercSheet
        }
        .sheet(isPresented: $showNets) {
            netsSheet
        }
        .sheet(isPresented: $showFields) {
            fieldsSheet
        }
        .sheet(isPresented: $showAnnotateOptions) {
            annotateSheet
        }
        .sheet(isPresented: $showFindResults) {
            findResultsSheet
        }
        // Part 5.3: publish the live document for the external
        // display (AirPlay hook) — the registry holds the OBJECT,
        // so the mirror redraws as this editor mutates it.
        .onAppear {
            liveSession.schematicDocument = document
            consumeCrossProbe()
        }
        .onDisappear {
            if liveSession.schematicDocument === document {
                liveSession.schematicDocument = nil
            }
        }
        // Part 5.3, S8: a "Show in Schematic" probe from the PCB
        // editor selects + centres the named symbol here.
        .onChange(of: crossProbe.target) { _, _ in
            consumeCrossProbe()
        }
        // Part 5.3, S11: selecting anything else clears the
        // connection selection.
        .onChange(of: selection) { _, _ in
            if !connectionSelection.isEmpty {
                connectionSelection = []
                connectionNetName = nil
            }
        }
    }

    // MARK: - Cross-probe (part 5.3, S8)

    /// Consumes a `.symbol` probe target: select the symbol with
    /// that reference and centre the canvas on it, then clear the
    /// target so it cannot re-fire. Other targets (and a stale
    /// target naming a symbol this sheet does not have) are left
    /// or reported plainly.
    private func consumeCrossProbe() {
        guard let target = crossProbe.target,
              case .symbol(let reference) = target else { return }
        crossProbe.target = nil
        guard let placed = document.placedSymbol(reference: reference) else {
            actionStatus = "No symbol \(reference) on this sheet"
            return
        }
        selection = placed.id
        showProperties = true
        canvasState.centre(on: placed.origin)
        actionStatus = "Showing \(reference) from the board"
    }

    /// "Show on Board" (properties card): publish the footprint
    /// probe for the selected symbol and push the PCB editor.
    private func showSelectedOnBoard() {
        guard let placed = selectedPlaced else { return }
        crossProbe.target = .footprint(reference: placed.reference)
        navigate("pcb")
    }

    /// "Update from Library" (properties card, part 5.3, S5):
    /// refresh the selected symbol from its CURRENT library
    /// definition.
    private func updateSelectedFromLibrary() {
        guard let placed = selectedPlaced, let def = selectedDef else { return }
        let changed = document.updateSymbolFromLibrary(id: placed.id,
                                                       definition: def)
        actionStatus = changed
            ? "Updated \(placed.reference) from the library"
            : "\(placed.reference) is already up to date — no change"
    }

    /// New document (part 5.2 — closes the recorded part-1
    /// gap): replace the state with an empty "Untitled"
    /// schematic. Like Open, this clears the undo history.
    private func startNewDocument() {
        document.replaceState(SchematicState(
            symbols: [], wires: [], junctions: [], labels: [],
            title: "Untitled"))
        selection = nil
        pendingSymbol = nil
        resetNetState()
    }

    /// Clears every piece of part-5.3 net state (highlight,
    /// connection selection, armed modes, cached table) — the
    /// nets they referred to belong to the previous document.
    private func resetNetState() {
        highlightTable = nil
        highlightedNet = nil
        highlightArmed = false
        selectConnectionArmed = false
        connectionSelection = []
        connectionNetName = nil
        actionStatus = nil
    }

    /// The ERC results sheet (part 5.2; exclusions part 5.3, P7):
    /// findings split by the document's exclusion keys into
    /// visible and excluded; the header count reflects VISIBLE
    /// findings only. Tapping a finding that names a symbol
    /// selects it on the canvas; Exclude/Restore move it between
    /// the lists (settings-style, no undo — see the document).
    /// Exclusion keys that match no current finding are reported
    /// as stale, never silently re-attached.
    private var ercSheet: some View {
        let split = SchematicERC.visibleFindings(
            ercFindings, excluding: Set(document.state.ercExclusions))
        let currentKeys = Set(ercFindings.map(\.key))
        let staleKeys = document.state.ercExclusions
            .filter { !currentKeys.contains($0) }
        return NavigationStack {
            List {
                Section {
                    if split.visible.isEmpty {
                        Text(split.excluded.isEmpty && staleKeys.isEmpty
                             ? "No electrical problems found — every pin is connected or marked no-connect, power inputs are driven, and references are annotated and unique."
                             : "No visible findings — every current finding is excluded.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(split.visible.enumerated()), id: \.offset) { _, finding in
                        ercFindingRow(finding, isExcluded: false)
                    }
                } header: {
                    Text("\(split.visible.count) finding\(split.visible.count == 1 ? "" : "s")")
                        .lineLimit(1)
                }
                if !split.excluded.isEmpty {
                    Section {
                        ForEach(Array(split.excluded.enumerated()), id: \.offset) { _, finding in
                            ercFindingRow(finding, isExcluded: true)
                        }
                    } header: {
                        Text("Excluded (\(split.excluded.count))")
                            .lineLimit(1)
                    }
                }
                if !staleKeys.isEmpty {
                    Section {
                        Text("\(staleKeys.count) exclusion\(staleKeys.count == 1 ? "" : "s") no longer match any finding")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Remove stale") {
                            for key in staleKeys {
                                document.restoreERC(key: key)
                            }
                        }
                        .lineLimit(1)
                    } header: {
                        Text("Stale exclusions")
                            .lineLimit(1)
                    }
                }
            }
            .navigationTitle("Electrical Rules Check")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showERC = false }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    /// One ERC finding row: severity + message (tap selects the
    /// symbol), plus its Exclude / Restore action.
    private func ercFindingRow(_ finding: ERCFinding, isExcluded: Bool) -> some View {
        HStack(spacing: 10) {
            Button {
                if let id = finding.instanceID {
                    selection = id
                    showERC = false
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: finding.severity == .error
                          ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(finding.severity == .error
                                         ? .red : .orange)
                        .lineLimit(1)
                    Text(finding.message)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(finding.instanceID == nil)
            if isExcluded {
                Button("Restore") { document.restoreERC(key: finding.key) }
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            } else {
                Button("Exclude") { document.excludeERC(key: finding.key) }
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    // MARK: - Saving (schematic + encrypted connection table)

    /// Every save writes BOTH files: the schematic JSON and — derived
    /// from the same state, through the real symbol/footprint stores —
    /// its encrypted connection table (ConnectionTableStore). The table
    /// is built BEFORE the schematic is written, so a table problem
    /// never leaves a save half-done; a table write failure after the
    /// schematic lands is reported distinctly.
    private func saveSchematic(to url: URL) {
        let table = makeConnectionTable(sourceFileName: url.lastPathComponent)
        do {
            try document.save(to: url)
        } catch {
            errorMessage = "Could not save that file: \(error.localizedDescription)"
            return
        }
        do {
            try ConnectionTableStore.save(table, forSchematicFile: url)
        } catch {
            errorMessage = "The schematic saved, but its encrypted connection table could not be written: \(error.localizedDescription)"
        }
    }

    /// The ONE connection-table construction in this editor:
    /// saveSchematic writes its result encrypted to disk, and
    /// the part-5.3 net features (Highlight Net, Net Navigator,
    /// Select Connection) read membership from the same build.
    private func makeConnectionTable(sourceFileName: String) -> ConnectionTable {
        ConnectionTableBuilder.build(
            state: document.state,
            sourceFileName: sourceFileName,
            resolveSymbol: { placed in
                store.symbol(library: placed.library, name: placed.symbolName)
            },
            resolveFootprint: { placed, def in
                // Part 3: the EFFECTIVE footprint — the instance's own
                // choice wins, then the symbol's Footprint property,
                // then a single exact filter (FootprintMatcher). The
                // recorded key is the entry's resolutionKey and the
                // kind says how it resolved.
                let match = FootprintMatcher.match(
                    def: def,
                    choiceKey: placed.footprintChoice,
                    entries: footprintStore.footprints)
                return (key: match.resolved?.resolutionKey,
                        kind: match.kind?.rawValue)
            })
    }

    // MARK: - Net features (part 5.3: S1 highlight, S10 navigator, S11 connection)

    /// The cached table, building it on first use. Arming a
    /// feature passes `rebuild: true` so the membership always
    /// reflects the sheet as it stands at that moment.
    private func ensureHighlightTable(rebuild: Bool = false) -> ConnectionTable {
        if !rebuild, let highlightTable { return highlightTable }
        let table = makeConnectionTable(sourceFileName: "")
        highlightTable = table
        return table
    }

    private func setHighlight(_ netName: String) {
        highlightedNet = netName
        actionStatus = "Net \(netName) highlighted"
    }

    private func clearHighlight() {
        highlightedNet = nil
        highlightArmed = false
        actionStatus = nil
    }

    /// Highlight resolution from a wire tap (S1).
    private func resolveHighlight(wireID: UUID) {
        let table = ensureHighlightTable()
        if let name = table.netName(forWireID: wireID) {
            setHighlight(name)
        } else {
            actionStatus = "That wire is not on any net"
        }
    }

    /// Highlight resolution from a symbol-pin tap (S1): the net
    /// whose endpoints contain this (instance, pin number).
    private func resolveHighlight(instanceID: UUID, pinNumber: String) {
        let table = ensureHighlightTable()
        if let net = table.nets.first(where: { net in
            net.endpoints.contains {
                $0.instanceID == instanceID && $0.pinNumber == pinNumber
            }
        }) {
            setHighlight(net.name)
        } else {
            actionStatus = "That pin is not on any net"
        }
    }

    /// Select Connection resolution (S11): every wire item of
    /// the tapped wire's net becomes the connection selection.
    private func resolveConnectionSelection(wireID: UUID) {
        let table = ensureHighlightTable()
        guard let name = table.netName(forWireID: wireID) else {
            actionStatus = "That wire is not on any net"
            return
        }
        connectionSelection = Set(table.wireIDs(forNet: name))
        connectionNetName = name
        actionStatus = "\(connectionSelection.count) wires · net \(name)"
    }

    private func clearConnectionSelection() {
        connectionSelection = []
        connectionNetName = nil
        actionStatus = nil
    }

    /// Delete with a connection selection (S11): exactly those
    /// wires, as one undo step through the document.
    private func deleteConnectionSelection() {
        let removed = document.deleteWires(connectionSelection)
        connectionSelection = []
        connectionNetName = nil
        actionStatus = removed == 0
            ? "No wires to delete"
            : "Deleted \(removed) wire\(removed == 1 ? "" : "s")"
    }

    /// The Net Navigator sheet (S10): every net from the table,
    /// sorted by name, with its endpoint count. Tapping a row
    /// highlights that net (S1 rendering); tapping the active
    /// row again clears the highlight.
    private var netsSheet: some View {
        NavigationStack {
            List {
                if let table = highlightTable {
                    if table.nets.isEmpty {
                        Text("No nets yet — a net needs at least two connected pins.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(table.nets.sorted { $0.name < $1.name }, id: \.name) { net in
                        Button {
                            if highlightedNet == net.name {
                                clearHighlight()
                            } else {
                                setHighlight(net.name)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Text(net.name)
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Text("\(net.endpoints.count) pins")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                if highlightedNet == net.name {
                                    Image(systemName: "checkmark")
                                        .lineLimit(1)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Text("No nets yet — a net needs at least two connected pins.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Nets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showNets = false }
                }
                if highlightedNet != nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Clear Highlight") { clearHighlight() }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Find (part 5.3, S2)

    /// The find bar under the top bar: query field, live result
    /// count, and a button opening the results list.
    private var findBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .lineLimit(1)
            TextField("Find reference, value, symbol, footprint or label",
                      text: $findQuery)
                .autocorrectionDisabled()
                .lineLimit(1)
                .onSubmit { runFind() }
                .onChange(of: findQuery) { _, _ in runFind() }
            Text(findQuery.trimmingCharacters(in: .whitespaces).isEmpty
                 ? "" : "\(findResults.count) match\(findResults.count == 1 ? "" : "es")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Button("Results") { showFindResults = true }
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .disabled(findResults.isEmpty)
            Button {
                showFind = false
                findQuery = ""
                findResults = []
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(white: 0.13))
    }

    private func runFind() {
        findResults = document.findMatches(query: findQuery)
    }

    /// Tapping a result (S2): a symbol match selects + centres
    /// the symbol; a label match centres on the label's point.
    private func focusFindMatch(_ match: SchematicFindMatch) {
        if let symbolID = match.symbolID,
           let placed = document.state.symbols.first(where: { $0.id == symbolID }) {
            selection = symbolID
            showProperties = true
            canvasState.centre(on: placed.origin)
            actionStatus = "Found \(placed.reference)"
        } else if let labelID = match.labelID,
                  let label = document.state.labels.first(where: { $0.id == labelID }) {
            canvasState.centre(on: label.at)
            actionStatus = "Found label “\(label.text)”"
        }
        showFindResults = false
    }

    private func findFieldTag(_ field: SchematicFindMatch.Field) -> String {
        switch field {
        case .reference: return "Reference"
        case .value: return "Value"
        case .symbolName: return "Symbol"
        case .footprint: return "Footprint"
        case .label: return "Label"
        }
    }

    private var findResultsSheet: some View {
        NavigationStack {
            List {
                if findResults.isEmpty {
                    Text("No matches for “\(findQuery)”.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(findResults.enumerated()), id: \.offset) { _, match in
                    Button {
                        focusFindMatch(match)
                    } label: {
                        HStack(spacing: 10) {
                            Text(findFieldTag(match.field))
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor,
                                            in: RoundedRectangle(cornerRadius: 4))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(match.text)
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                if match.symbolID != nil {
                                    Text(match.reference)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Find Results")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showFindResults = false }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Clean up sheet (part 5.3, S3)

    /// Clean Up: every pin world point of the sheet (resolved
    /// through the store, drawn-list geometry — the same points
    /// the save flow's table builder uses) feeds the document's
    /// one-step cleanup; the report names each non-zero rule in
    /// plain words.
    private func cleanUpSheet() {
        var pinPoints: [DPoint] = []
        for placed in document.state.symbols {
            if let def = store.symbol(library: placed.library,
                                      name: placed.symbolName) {
                pinPoints += SymbolDrawList.pinWorldPoints(
                    def: def, placed: placed).map { $0.point }
            }
        }
        let counts = document.cleanUpSheet(pinPoints: pinPoints)
        func phrase(_ key: String, _ one: String, _ many: String) -> String? {
            guard let n = counts[key], n > 0 else { return nil }
            return "\(n) \(n == 1 ? one : many)"
        }
        var parts: [String] = []
        if let p = phrase("nullWires", "zero-length wire removed",
                          "zero-length wires removed") { parts.append(p) }
        if let p = phrase("duplicateWires", "duplicate wire removed",
                          "duplicate wires removed") { parts.append(p) }
        if let p = phrase("mergedWires", "collinear segment merged",
                          "collinear segments merged") { parts.append(p) }
        if let p = phrase("isolatedWires", "isolated wire removed",
                          "isolated wires removed") { parts.append(p) }
        if let p = phrase("duplicateJunctions", "duplicate junction removed",
                          "duplicate junctions removed") { parts.append(p) }
        if let p = phrase("droppedJunctions", "dangling junction removed",
                          "dangling junctions removed") { parts.append(p) }
        if parts.isEmpty {
            infoMessage = "Sheet is already clean"
        } else {
            let joined = parts.joined(separator: ", ")
            let summary = joined.prefix(1).uppercased() + String(joined.dropFirst())
            infoMessage = summary + ". Undo puts everything back."
            resetNetState()
        }
    }

    // MARK: - Fields table (part 5.3, S6)

    /// Opens the fields sheet: rows + edit seed snapshotted from
    /// the document, so Cancel is a pure discard.
    private func openFields() {
        let rows = document.fieldRows()
        fieldRowsSnapshot = rows
        let seed = Dictionary(uniqueKeysWithValues: rows.map {
            ($0.instanceID, FieldEdit(value: $0.value, footprint: $0.footprint))
        })
        fieldSeed = seed
        fieldEdits = seed
        showFields = true
    }

    private func fieldValueBinding(for row: SymbolFieldRow) -> Binding<String> {
        Binding(
            get: { fieldEdits[row.instanceID]?.value ?? row.value },
            set: { newValue in
                var edit = fieldEdits[row.instanceID]
                    ?? FieldEdit(value: row.value, footprint: row.footprint)
                edit.value = newValue
                fieldEdits[row.instanceID] = edit
            })
    }

    private func fieldFootprintBinding(for row: SymbolFieldRow) -> Binding<String> {
        Binding(
            get: { fieldEdits[row.instanceID]?.footprint ?? row.footprint },
            set: { newValue in
                var edit = fieldEdits[row.instanceID]
                    ?? FieldEdit(value: row.value, footprint: row.footprint)
                edit.footprint = newValue
                fieldEdits[row.instanceID] = edit
            })
    }

    /// Apply: only rows the user actually changed go to the
    /// document, which commits them as one undo step.
    private func applyFields() {
        var changed: [UUID: FieldEdit] = [:]
        for (id, edit) in fieldEdits where edit != fieldSeed[id] {
            changed[id] = edit
        }
        let updated = document.applyFieldEdits(changed)
        showFields = false
        actionStatus = updated == 0
            ? "No changes"
            : "\(updated) fields updated"
    }

    private var fieldsSheet: some View {
        NavigationStack {
            List {
                if fieldRowsSnapshot.isEmpty {
                    Text("No symbols on this sheet yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(fieldRowsSnapshot) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(row.reference)
                                .font(.callout.weight(.bold))
                                .lineLimit(1)
                            Text("Unit \(SchematicEditorSupport.unitLetter(row.unit))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text(row.symbolName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        HStack(spacing: 8) {
                            Text("Value")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(width: 64, alignment: .leading)
                            TextField("Value", text: fieldValueBinding(for: row))
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()
                        }
                        HStack(spacing: 8) {
                            Text("Footprint")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(width: 64, alignment: .leading)
                            TextField("Footprint choice", text: fieldFootprintBinding(for: row))
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .navigationTitle("Symbol Fields")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showFields = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { applyFields() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Annotate options (part 5.3, S7)

    private var annotateSheet: some View {
        NavigationStack {
            Form {
                Picker("Sort order", selection: $annotateSortRaw) {
                    Text("Sheet order").lineLimit(1).tag(0)
                    Text("By X").lineLimit(1).tag(1)
                    Text("By Y").lineLimit(1).tag(2)
                }
                Toggle("Reset all references", isOn: $annotateResetAll)
                HStack(spacing: 10) {
                    Text("Start number")
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    TextField("1", text: $annotateStartText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                }
            }
            .navigationTitle("Annotate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showAnnotateOptions = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Annotate") { runAnnotate() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func runAnnotate() {
        let sortOrder: AnnotateOptions.SortOrder
        switch annotateSortRaw {
        case 1: sortOrder = .byX
        case 2: sortOrder = .byY
        default: sortOrder = .sheetOrder
        }
        let options = AnnotateOptions(
            sortOrder: sortOrder,
            resetAll: annotateResetAll,
            startNumber: Int(annotateStartText) ?? 1)
        let changed = document.annotateReferences(options: options)
        showAnnotateOptions = false
        actionStatus = changed == 0
            ? "Every reference was already annotated — nothing changed."
            : "Annotated \(changed) reference(s). Undo puts the old references back."
    }

    // MARK: - Align / zoom to selection (part 5.3, S12 / P17)

    /// Align to Grid: the selected symbol's pin world points
    /// (store definition + drawn-list geometry) go to the
    /// document, which snaps it and carries its connections.
    private func alignSelectedToGrid() {
        guard let placed = selectedPlaced, let def = selectedDef else { return }
        let pinPoints = SymbolDrawList.pinWorldPoints(
            def: def, placed: placed).map { $0.point }
        let aligned = document.alignSymbolToGrid(id: placed.id,
                                                 pinPoints: pinPoints)
        actionStatus = aligned
            ? "Aligned \(placed.reference) to the grid"
            : "Already on grid"
    }

    /// Zoom to Selection: frame the selected symbol's placed
    /// bounds (the renderer's own bounds helper).
    private func zoomToSelection() {
        guard let placed = selectedPlaced, let def = selectedDef else {
            actionStatus = "Select a symbol first, then Zoom to Selection"
            return
        }
        let bounds = SymbolRenderer.placedBounds(def: def, placed: placed)
        canvasState.frame(rect: bounds, size: canvasState.canvasSize)
    }

    // MARK: - Top bar

    private var topBar: some View {
        // Part 5.3 added Highlight Net / Nets / Find / Clean Up /
        // Fields / Zoom to Selection to this row — wider than the
        // panel at some sizes, so the row scrolls horizontally
        // instead of clipping or wrapping a label.
        ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 10) {
            topButton(icon: "folder", label: "Open") { showOpen = true }
                .keyboardShortcut("o", modifiers: .command)
            topButton(icon: "doc.badge.plus", label: "New") {
                if document.state.symbols.isEmpty
                    && document.state.wires.isEmpty
                    && document.state.labels.isEmpty {
                    startNewDocument()
                } else {
                    showNewConfirm = true
                }
            }
            topButton(icon: "square.and.arrow.down", label: "Save") { showSave = true }
                .keyboardShortcut("s", modifiers: .command)

            barDivider

            topButton(icon: "list.number", label: "Annotate") {
                showAnnotateOptions = true
            }
            topButton(icon: "checklist", label: "ERC") {
                ercFindings = SchematicERC.check(
                    state: document.state,
                    resolveSymbol: { placed in
                        store.symbol(library: placed.library,
                                     name: placed.symbolName)
                    })
                showERC = true
            }

            barDivider

            // Part 5.3 net + sheet tools (S1, S10, S2, S3, S6).
            topButton(icon: "bolt", label: highlightArmed ? "Tap a Wire or Pin" : "Highlight Net") {
                if highlightArmed {
                    highlightArmed = false
                } else {
                    _ = ensureHighlightTable(rebuild: true)
                    selectConnectionArmed = false
                    highlightArmed = true
                    actionStatus = "Tap a wire or a symbol pin to highlight its net"
                }
            }
            if highlightedNet != nil {
                topButton(icon: "xmark.circle", label: "Clear Highlight") {
                    clearHighlight()
                }
            }
            topButton(icon: "point.3.connected.trianglepath.dotted", label: "Nets") {
                _ = ensureHighlightTable(rebuild: true)
                showNets = true
            }
            topButton(icon: "magnifyingglass", label: "Find") {
                showFind.toggle()
                if showFind { runFind() }
            }
            topButton(icon: "sparkles", label: "Clean Up") {
                cleanUpSheet()
            }
            topButton(icon: "tablecells", label: "Fields") {
                openFields()
            }

            barDivider

            topButton(icon: "arrow.uturn.backward", label: "Undo") { document.undo() }
                .disabled(!document.canUndo)
                .keyboardShortcut("z", modifiers: .command)
            topButton(icon: "arrow.uturn.forward", label: "Redo") { document.redo() }
                .disabled(!document.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])

            barDivider

            topButton(icon: "minus.magnifyingglass", label: "Zoom Out") { canvasState.zoomOut() }
            topButton(icon: "plus.magnifyingglass", label: "Zoom In") { canvasState.zoomIn() }
            topButton(icon: "arrow.up.left.and.down.right.magnifyingglass", label: "Fit") {
                canvasState.fit(document)
            }
            topButton(icon: "scope", label: "Zoom to Selection") {
                zoomToSelection()
            }

            barDivider

            Button {
                titleDraft = document.state.title
                showTitleEdit = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "pencil")
                        .lineLimit(1)
                    // Capped + tail-truncated (part 5 polish): the
                    // button used to be fixed-size, so a long title
                    // could push the whole top bar off the panel.
                    Text(document.state.title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 280, alignment: .leading)
                }
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        }
        .background(Color(white: 0.15))
    }

    private var barDivider: some View {
        Divider()
            .frame(height: 24)
    }

    private func topButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .lineLimit(1)
                Text(label)
                    .lineLimit(1)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: - Left tool bar

    private var leftTools: some View {
        VStack(spacing: 6) {
            toolButton(tool: .select, icon: "cursorarrow", caption: "Select")
            toolButton(tool: .placeSymbol, icon: "plus.square", caption: "Symbol") {
                chooserPowerOnly = false
                showChooser = true
            }
            toolButton(tool: .placePower, icon: "bolt.fill", caption: "Power") {
                chooserPowerOnly = true
                showChooser = true
            }
            toolButton(tool: .wire, icon: "cable.connector", caption: "Wire")
            toolButton(tool: .junction, icon: "circle.circle", caption: "Junction")
            toolButton(tool: .label, icon: "tag", caption: "Label")
            toolButton(tool: .noConnect, icon: "xmark", caption: "No Conn")
            toolButton(tool: .delete, icon: "trash", caption: "Delete")
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .frame(width: 64)
        .background(Color(white: 0.13))
    }

    // MARK: - Right tool bar

    private var rightTools: some View {
        VStack(spacing: 6) {
            actionToolButton(icon: "plus.square.on.square", caption: "Symbol") {
                chooserPowerOnly = false
                showChooser = true
            }
            actionToolButton(icon: "rotate.right", caption: "Rotate") {
                if let selection { document.rotateSymbol(id: selection) }
            }
            .disabled(selection == nil)
            actionToolButton(icon: "flip.horizontal", caption: "Mirror X") {
                if let selection { document.mirrorSymbol(id: selection, xAxis: true) }
            }
            .disabled(selection == nil)
            actionToolButton(icon: "flip.vertical", caption: "Mirror Y") {
                if let selection { document.mirrorSymbol(id: selection, xAxis: false) }
            }
            .disabled(selection == nil)
            actionToolButton(icon: "link", caption: "Datasheet") {
                if let url = selectedDatasheetURL { openURL(url) }
            }
            .disabled(selectedDatasheetURL == nil)
            // Part 5.3, S11: arm Select Connection — the next
            // canvas tap on a wire selects its whole net's wires.
            actionToolButton(icon: "arrow.triangle.branch", caption: "Connect",
                             isActive: selectConnectionArmed) {
                if selectConnectionArmed {
                    selectConnectionArmed = false
                } else {
                    _ = ensureHighlightTable()
                    highlightArmed = false
                    selectConnectionArmed = true
                    actionStatus = "Tap a wire to select its whole connection"
                }
            }
            // Part 5.3, S12: snap the selected symbol to the grid,
            // connections following its pins.
            actionToolButton(icon: "grid", caption: "Align") {
                alignSelectedToGrid()
            }
            .disabled(selection == nil)
            actionToolButton(icon: "sidebar.right", caption: "Props",
                             isActive: showProperties) {
                showProperties.toggle()
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .frame(width: 64)
        .background(Color(white: 0.13))
    }

    /// A tool-mode button in the left bar. `extraAction` runs after the tool
    /// is set (used by the place tools to open the symbol chooser).
    private func toolButton(tool target: EditorTool, icon: String, caption: String,
                            extraAction: (() -> Void)? = nil) -> some View {
        let isActive = tool == target
        return Button {
            tool = target
            extraAction?()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 19))
                    .lineLimit(1)
                Text(caption)
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: 56, height: 52)
            .foregroundStyle(isActive ? Color.white : Color.white.opacity(0.75))
            .background(isActive ? Color.accentColor : Color.clear,
                        in: RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }

    /// A momentary action button in the right bar (not a tool mode).
    private func actionToolButton(icon: String, caption: String, isActive: Bool = false,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 19))
                    .lineLimit(1)
                Text(caption)
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: 56, height: 52)
            .foregroundStyle(isActive ? Color.white : Color.white.opacity(0.75))
            .background(isActive ? Color.accentColor : Color.clear,
                        in: RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 16) {
            Text(cursorText)
                .font(.caption.monospacedDigit())
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(zoomText)
                .font(.caption)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(toolName)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(selectionSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let actionStatus {
                Text(actionStatus)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(white: 0.15))
    }

    private var cursorText: String {
        if let cursor = canvasState.cursorWorld {
            return String(format: "X %.2f  Y %.2f mm", cursor.x, cursor.y)
        }
        return "X —  Y — mm"
    }

    private var zoomText: String {
        "Zoom \(Int((Double(canvasState.scale) * 25).rounded()))%"
    }

    private var toolName: String {
        switch tool {
        case .select: return "Select"
        case .placeSymbol: return "Place Symbol"
        case .placePower: return "Place Power"
        case .wire: return "Wire"
        case .junction: return "Junction"
        case .label: return "Label"
        case .noConnect: return "No Connect"
        case .delete: return "Delete"
        }
    }

    private var selectionSummary: String {
        if let placed = selectedPlaced {
            return "\(placed.reference) — \(LibraryStore.displayName(forLibraryKey: placed.library)):\(placed.symbolName)"
        }
        return "\(document.state.symbols.count) symbols, \(document.state.wires.count) wires"
    }
}

// MARK: - Shared helpers

enum SchematicEditorSupport {
    /// A usable http(s) datasheet URL from a symbol definition's Datasheet
    /// property, or nil ("~" / empty / non-URL values are not links).
    static func datasheetURL(from def: KiCadSymbolDef?) -> URL? {
        guard let raw = def?.property("Datasheet"),
              !raw.isEmpty, raw != "~",
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }

    /// Letters before the first digit ("R12" -> "R", "#PWR1" -> "#PWR").
    static func referencePrefix(of reference: String, fallback: String) -> String {
        let prefix = reference.prefix(while: { !$0.isNumber })
        return prefix.isEmpty ? fallback : String(prefix)
    }

    /// Unit label per KiCad convention: 1 -> "A", 2 -> "B", …
    static func unitLetter(_ unit: Int) -> String {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        guard unit >= 1, unit <= letters.count else { return "\(unit)" }
        return String(letters[unit - 1])
    }
}

// MARK: - Properties card

/// Floating inspector for the selected placed symbol, anchored to the
/// trailing edge of the canvas. Reference / Value commit on submit; unit,
/// rotate, mirror, duplicate and delete act immediately through the
/// document's history-recording methods where the contract provides them.
private struct SymbolPropertiesCard: View {
    @ObservedObject var document: SchematicDocument
    let placedID: UUID
    let store: LibraryStore
    @EnvironmentObject private var footprintStore: FootprintStore
    var onClose: () -> Void
    var onSelect: (UUID) -> Void
    /// Part 5.3 card actions owned by the editor (cross-probe,
    /// chooser swap, library update + their status reporting).
    /// Defaulted so the card keeps one construction pattern.
    var onShowOnBoard: () -> Void = {}
    var onChangeSymbol: () -> Void = {}
    var onUpdateFromLibrary: () -> Void = {}

    @State private var refDraft = ""
    @State private var valueDraft = ""
    @State private var showFootprintChooser = false

    private var placed: PlacedSymbol? {
        document.state.symbols.first(where: { $0.id == placedID })
    }

    /// Part 3: the matcher result for this instance — the effective
    /// footprint (instance choice > Footprint property > exact
    /// filter) plus the ranked filter candidates, over the COMBINED
    /// user + bundled footprint list (FootprintMatcher).
    private var footprintMatch: FootprintMatch? {
        guard let def, let placed else { return nil }
        return FootprintMatcher.match(
            def: def,
            choiceKey: placed.footprintChoice,
            entries: footprintStore.footprints)
    }

    private var def: KiCadSymbolDef? {
        guard let placed else { return nil }
        return store.symbol(library: placed.library, name: placed.symbolName)
    }

    private var unitCount: Int {
        max(def?.unitCount ?? 1, 1)
    }

    private var unitBinding: Binding<Int> {
        Binding(
            get: { placed?.unit ?? 1 },
            set: { newUnit in mutate { $0.unit = newUnit } }
        )
    }

    /// De Morgan body style (part 5.2): 1 = standard body,
    /// 2 = the alternate (De Morgan) body, where the symbol
    /// defines one.
    private var bodyStyleBinding: Binding<Int> {
        Binding(
            get: { placed?.effectiveBodyStyle ?? 1 },
            set: { newStyle in mutate { $0.bodyStyle = newStyle } }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    fieldRow("Reference") {
                        TextField("Reference", text: $refDraft)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .onSubmit { commitReference() }
                    }
                    fieldRow("Value") {
                        TextField("Value", text: $valueDraft)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .onSubmit { commitValue() }
                    }
                    if unitCount > 1 {
                        fieldRow("Unit") {
                            Picker("Unit", selection: unitBinding) {
                                ForEach(1...unitCount, id: \.self) { unit in
                                    Text("Unit \(SchematicEditorSupport.unitLetter(unit))")
                                        .lineLimit(1)
                                        .tag(unit)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                    if def?.hasAlternateBody == true {
                        fieldRow("Body") {
                            Picker("Body", selection: bodyStyleBinding) {
                                Text("Standard").lineLimit(1).tag(1)
                                Text("De Morgan").lineLimit(1).tag(2)
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                    Divider()
                    readOnlyRow("Library", placed.map { LibraryStore.displayName(forLibraryKey: $0.library) } ?? "—")
                    readOnlyRow("Symbol", placed?.symbolName ?? "—")
                    footprintSection
                    if let description = def?.property("Description"),
                       !description.isEmpty, description != "~" {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Description")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(description)
                                .font(.callout)
                                .lineLimit(4)
                        }
                    }
                    if let url = SchematicEditorSupport.datasheetURL(from: def) {
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
                    Divider()
                    actionButtons
                    Divider()
                    symbolActions
                }
                .padding(14)
            }
        }
        .frame(width: 300)
        .frame(maxHeight: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 16, x: 0, y: 6)
        .onAppear { syncDrafts() }
        .onChange(of: placedID) { _, _ in syncDrafts() }
        .sheet(isPresented: $showFootprintChooser) {
            FootprintChoiceSheet(
                candidates: footprintMatch?.candidates ?? [],
                resolved: footprintMatch?.resolved,
                choiceKey: placed?.footprintChoice,
                pinCount: def?.distinctPinCount ?? 0,
                onPick: { newChoice in
                    // Writes through mutate() like the other card
                    // edits — one undo step (part 5.2).
                    mutate { $0.footprintChoice = newChoice }
                })
        }
    }

    // MARK: - Footprint association (part 3)

    /// The effective footprint for this instance, how it resolved,
    /// its distinct pad count against the symbol's distinct pin
    /// count, and the button that opens the candidate picker.
    @ViewBuilder
    private var footprintSection: some View {
        if let def, let match = footprintMatch {
            VStack(alignment: .leading, spacing: 4) {
                readOnlyRow("Footprint", match.resolved?.resolutionKey ?? "—")
                Text(footprintResolutionText(match.kind))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(match.resolved != nil ? Color.green : Color.orange)
                    .lineLimit(1)
                if let resolved = match.resolved {
                    Text(footprintPadNote(resolved, def))
                        .font(.caption)
                        .foregroundStyle(resolved.distinctPadCount == def.distinctPinCount ? Color.secondary : Color.orange)
                        .lineLimit(1)
                }
                Button {
                    showFootprintChooser = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.stack.3d.up")
                            .lineLimit(1)
                        Text("Choose Footprint…")
                            .lineLimit(1)
                    }
                    .font(.callout.weight(.medium))
                }
                .padding(.top, 2)
            }
        }
    }

    private func footprintResolutionText(_ kind: FootprintMatchKind?) -> String {
        switch kind {
        case .instanceChoice: return "Your chosen footprint"
        case .property: return "From the symbol's Footprint property"
        case .filterExact: return "From the symbol's footprint filters"
        case nil: return "No footprint assigned"
        }
    }

    private func footprintPadNote(_ resolved: FootprintEntry,
                                  _ def: KiCadSymbolDef) -> String {
        let matches = resolved.distinctPadCount == def.distinctPinCount
        return "\(resolved.distinctPadCount) distinct pads · \(def.distinctPinCount) pins — \(matches ? "pin count matches" : "pin count differs")"
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(placed?.reference ?? "Symbol")
                .font(.headline)
                .lineLimit(1)
            Text(placed?.symbolName ?? "")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                    .padding(6)
                    .background(Color.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var actionButtons: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                cardButton(icon: "rotate.right", label: "Rotate") {
                    document.rotateSymbol(id: placedID)
                }
                cardButton(icon: "flip.horizontal", label: "Mirror X") {
                    document.mirrorSymbol(id: placedID, xAxis: true)
                }
                cardButton(icon: "flip.vertical", label: "Mirror Y") {
                    document.mirrorSymbol(id: placedID, xAxis: false)
                }
            }
            HStack(spacing: 8) {
                cardButton(icon: "plus.square.on.square", label: "Duplicate") {
                    duplicate()
                }
                cardButton(icon: "trash", label: "Delete", destructive: true) {
                    document.deleteSymbol(id: placedID)
                    onClose()
                }
            }
        }
    }

    /// Part 5.3 card actions: cross-probe to the board (S8) and
    /// the Change / Update Symbol pair (S5). Full-width rows —
    /// these labels do not fit the three-across button grid.
    private var symbolActions: some View {
        VStack(spacing: 8) {
            cardButton(icon: "circuitboard", label: "Show on Board") {
                onShowOnBoard()
            }
            HStack(spacing: 8) {
                cardButton(icon: "arrow.left.arrow.right", label: "Change Symbol…") {
                    onChangeSymbol()
                }
                cardButton(icon: "arrow.clockwise", label: "Update from Library") {
                    onUpdateFromLibrary()
                }
            }
        }
    }

    private func cardButton(icon: String, label: String, destructive: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .lineLimit(1)
                Text(label)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .foregroundStyle(destructive ? Color.red : Color.primary)
            .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func fieldRow<Content: View>(_ label: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            content()
        }
    }

    private func readOnlyRow(_ label: String, _ value: String) -> some View {
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

    // MARK: - Mutations

    /// Mutates the placed symbol through the document's undoable
    /// edit path (part 5.2 — this closes the recorded part-1 gap
    /// where card edits made no undo step):
    /// `SchematicDocument.editSymbol` pushes exactly one history
    /// step per real change and none for a no-op edit.
    private func mutate(_ change: (inout PlacedSymbol) -> Void) {
        document.editSymbol(id: placedID, change)
    }

    private func syncDrafts() {
        refDraft = placed?.reference ?? ""
        valueDraft = placed?.value ?? ""
    }

    private func commitReference() {
        let trimmed = refDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            refDraft = placed?.reference ?? refDraft
            return
        }
        mutate { $0.reference = trimmed }
    }

    private func commitValue() {
        let trimmed = valueDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        mutate { $0.value = trimmed }
    }

    private func duplicate() {
        guard let placed else { return }
        var copy = placed
        copy.id = UUID()
        copy.x += 2.54
        copy.y += 2.54
        let prefix = SchematicEditorSupport.referencePrefix(
            of: placed.reference,
            fallback: def?.referencePrefix ?? "U")
        copy.reference = document.nextReference(prefix: prefix)
        document.addSymbol(copy)
        onSelect(copy.id)
    }
}

// MARK: - Footprint choice sheet (part 3)

/// The "Choose Footprint…" picker for one placed instance: the
/// automatic row (clears the per-instance choice), the currently
/// resolved entry (badged, when it is not already in the candidate
/// list), and every ranked ki_fp_filters candidate from the combined
/// user + bundled list. Picking a row records that entry's
/// resolutionKey as the instance's footprintChoice via `onPick`.
private struct FootprintChoiceSheet: View {
    var candidates: [FootprintCandidate]
    var resolved: FootprintEntry?
    var choiceKey: String?
    var pinCount: Int
    var onPick: (String?) -> Void

    @Environment(\.dismiss) private var dismiss

    /// The resolved entry shown on its own when the filters did not
    /// produce it (e.g. it came from the Footprint property).
    private var resolvedStandalone: FootprintCandidate? {
        guard let resolved,
              !candidates.contains(where: {
                  $0.entry.resolutionKey == resolved.resolutionKey
              }) else { return nil }
        return FootprintCandidate(
            entry: resolved,
            distinctPadCount: resolved.distinctPadCount,
            pinCountMatches: resolved.distinctPadCount == pinCount)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Choose Footprint")
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button("Close") { dismiss() }
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            List {
                Section {
                    Button {
                        onPick(nil)
                        dismiss()
                    } label: {
                        HStack(spacing: 8) {
                            Text("Use automatic (property/filters)")
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if choiceKey == nil {
                                Image(systemName: "checkmark")
                                    .lineLimit(1)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if let resolvedStandalone {
                    Section {
                        candidateRow(resolvedStandalone)
                    } header: {
                        Text("Assigned")
                    }
                }
                if !candidates.isEmpty {
                    Section {
                        ForEach(candidates, id: \.entry.resolutionKey) { candidate in
                            candidateRow(candidate)
                        }
                    } header: {
                        Text("Filter matches")
                    }
                }
                if candidates.isEmpty, resolvedStandalone == nil {
                    Section {
                        Text("No footprint-filter candidates for this symbol.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        .preferredColorScheme(.dark)
    }

    private func candidateRow(_ candidate: FootprintCandidate) -> some View {
        let entry = candidate.entry
        let isResolved = resolved?.resolutionKey == entry.resolutionKey
        return Button {
            onPick(entry.resolutionKey)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.key)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(entry.source == .user ? "YOURS" : "KiCad")
                        .font(.caption2.weight(.bold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.14),
                                    in: RoundedRectangle(cornerRadius: 4))
                    if isResolved {
                        Text("assigned")
                            .font(.caption2.weight(.bold))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.25),
                                        in: RoundedRectangle(cornerRadius: 4))
                    }
                    Spacer(minLength: 0)
                    if choiceKey == entry.resolutionKey {
                        Image(systemName: "checkmark")
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 8) {
                    Text("\(candidate.distinctPadCount) distinct pads (\(entry.padCount) total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if candidate.pinCountMatches {
                        Text("pin count matches")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                            .lineLimit(1)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
