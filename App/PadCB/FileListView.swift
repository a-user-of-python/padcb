import SwiftUI

/// Sheet for opening / saving schematic JSON files stored in
/// `Documents/PadCB/*.json`. No system document picker is used anywhere in
/// PadCB; this small file list is the whole file UI for part 1.
///
/// - Open mode: tap a row to load it (`onDone` receives the file URL).
/// - Save mode: type a name (or tap an existing file to reuse its name),
///   then tap Save.
///
/// The view dismisses itself after a successful `onDone`, and via its
/// Cancel toolbar button otherwise.
struct FileListView: View {
    enum Mode {
        case open
        case save
    }

    struct FileEntry: Identifiable {
        var url: URL
        var name: String        // file name without the ".json" extension
        var modified: Date
        var id: String { url.path }
    }

    let mode: Mode
    var onDone: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var files: [FileEntry] = []
    @State private var nameField: String = ""

    init(mode: Mode, initialName: String, onDone: @escaping (URL) -> Void) {
        self.mode = mode
        self.onDone = onDone
        _nameField = State(initialValue: FileListView.sanitizedName(initialName))
    }

    // MARK: - Storage

    private static var padcbDirectory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("PadCB", isDirectory: true)
    }

    private static func sanitizedName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasSuffix(".json") {
            name = String(name.dropLast(5))
        }
        name = name.replacingOccurrences(of: "/", with: "-")
                   .replacingOccurrences(of: ":", with: "-")
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var sanitizedFieldName: String {
        FileListView.sanitizedName(nameField)
    }

    private var canSave: Bool {
        mode == .save && !sanitizedFieldName.isEmpty
    }

    private func reloadFiles() {
        let fm = FileManager.default
        let dir = FileListView.padcbDirectory
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let urls = (try? fm.contentsOfDirectory(at: dir,
                                                includingPropertiesForKeys: keys,
                                                options: [.skipsHiddenFiles])) ?? []
        files = urls
            .filter { $0.pathExtension.lowercased() == "json" }
            .map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return FileEntry(url: url,
                                 name: url.deletingPathExtension().lastPathComponent,
                                 modified: values?.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.modified > $1.modified }
    }

    private func deleteFiles(at offsets: IndexSet) {
        let fm = FileManager.default
        for index in offsets {
            try? fm.removeItem(at: files[index].url)
        }
        files.remove(atOffsets: offsets)
    }

    private func finish(with url: URL) {
        onDone(url)
        dismiss()
    }

    private func saveTapped() {
        guard canSave else { return }
        let url = FileListView.padcbDirectory
            .appendingPathComponent(sanitizedFieldName)
            .appendingPathExtension("json")
        finish(with: url)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if mode == .save {
                    saveHeader
                    Divider()
                }
                fileList
            }
            .background(Color(white: 0.10))
            .navigationTitle(mode == .save ? "Save Schematic" : "Open Schematic")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .lineLimit(1)
                }
                if mode == .save {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { saveTapped() }
                            .disabled(!canSave)
                            .lineLimit(1)
                    }
                }
            }
            .onAppear { reloadFiles() }
        }
        .preferredColorScheme(.dark)
    }

    private var saveHeader: some View {
        HStack(spacing: 12) {
            Text("File name")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            TextField("Untitled", text: $nameField)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .onSubmit { saveTapped() }
            Text(".json")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var fileList: some View {
        if files.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "doc.questionmark")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("No saved schematics yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if mode == .save {
                    Text("Type a name above and tap Save to create the first one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(files) { entry in
                    Button {
                        if mode == .open {
                            finish(with: entry.url)
                        } else {
                            nameField = entry.name
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "doc.text")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(entry.modified.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            if mode == .open {
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .onDelete(perform: deleteFiles)
            }
            .listStyle(.insetGrouped)
        }
    }
}
