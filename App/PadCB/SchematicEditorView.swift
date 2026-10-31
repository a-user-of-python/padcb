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
    @StateObject private var document = SchematicDocument()
    @StateObject private var canvasState = CanvasViewState()
    @EnvironmentObject private var store: LibraryStore

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
                        }
                    )
                    if showProperties, let placed = selectedPlaced {
                        SymbolPropertiesCard(
                            document: document,
                            placedID: placed.id,
                            store: store,
                            onClose: { selection = nil },
                            onSelect: { selection = $0 }
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
        .sheet(isPresented: $showChooser) {
            SymbolChooserView(store: store, powerOnly: chooserPowerOnly) { def in
                pendingSymbol = def
                tool = .placeSymbol
            }
        }
        .sheet(isPresented: $showOpen) {
            FileListView(mode: .open, initialName: document.state.title) { url in
                do {
                    try document.load(from: url)
                    selection = nil
                    pendingSymbol = nil
                } catch {
                    errorMessage = "Could not open that file: \(error.localizedDescription)"
                }
            }
        }
        .sheet(isPresented: $showSave) {
            FileListView(mode: .save, initialName: document.state.title) { url in
                do {
                    try document.save(to: url)
                } catch {
                    errorMessage = "Could not save that file: \(error.localizedDescription)"
                }
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
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            topButton(icon: "folder", label: "Open") { showOpen = true }
                .keyboardShortcut("o", modifiers: .command)
            topButton(icon: "square.and.arrow.down", label: "Save") { showSave = true }
                .keyboardShortcut("s", modifiers: .command)

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

            barDivider

            Button {
                titleDraft = document.state.title
                showTitleEdit = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "pencil")
                        .lineLimit(1)
                    Text(document.state.title)
                        .font(.headline)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
        case .delete: return "Delete"
        }
    }

    private var selectionSummary: String {
        if let placed = selectedPlaced {
            return "\(placed.reference) — \(placed.library):\(placed.symbolName)"
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
    var onClose: () -> Void
    var onSelect: (UUID) -> Void

    @State private var refDraft = ""
    @State private var valueDraft = ""

    private var placed: PlacedSymbol? {
        document.state.symbols.first(where: { $0.id == placedID })
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
                    Divider()
                    readOnlyRow("Library", placed?.library ?? "—")
                    readOnlyRow("Symbol", placed?.symbolName ?? "—")
                    if let footprint = def?.property("Footprint"),
                       !footprint.isEmpty, footprint != "~" {
                        readOnlyRow("Footprint", footprint)
                    }
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

    /// Mutates the placed symbol in place. `SchematicDocument.state` is
    /// `@Published`, so writing through it notifies every observer.
    private func mutate(_ change: (inout PlacedSymbol) -> Void) {
        guard let index = document.state.symbols.firstIndex(where: { $0.id == placedID })
        else { return }
        change(&document.state.symbols[index])
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
