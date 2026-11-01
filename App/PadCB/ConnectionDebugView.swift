import SwiftUI

/// TEMPORARY DEBUG VIEW (part 2) — remove when the PCB editor lands.
///
/// Decrypts a saved connection table (Documents/ConnectionTables/*.pct)
/// and shows, per net, what connects to what, in plain text. Sean asked
/// for this on the home screen to verify the encrypted tables the
/// schematic editor writes on every save. It lists every saved table
/// (newest first) and opens with the most recent one selected.
struct ConnectionDebugView: View {
    @State private var tables: [URL] = []
    @State private var selectedURL: URL? = nil
    @State private var table: ConnectionTable? = nil
    @State private var loadError: String? = nil

    var body: some View {
        ZStack {
            Color(white: 0.08).ignoresSafeArea()
            content
        }
        .navigationTitle("Debug: Connections")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .task {
            tables = ConnectionTableStore.availableTables()
            if selectedURL == nil { selectedURL = tables.first }
        }
        .task(id: selectedURL) {
            loadSelected()
        }
    }

    @ViewBuilder
    private var content: some View {
        if tables.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "tablecells")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                Text("No connection tables yet.")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("Save a schematic first — every save also writes an encrypted connection table to Documents/ConnectionTables.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            .padding(32)
        } else {
            VStack(spacing: 0) {
                temporaryBanner
                tablePicker
                Divider()
                if let loadError {
                    Text(loadError)
                        .font(.callout)
                        .foregroundStyle(.red.opacity(0.9))
                        .padding(16)
                    Spacer()
                } else if let table {
                    tableContent(table)
                } else {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private var temporaryBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "wrench.and.screwdriver")
                .lineLimit(1)
            Text("Temporary debug view — decrypts the saved connection table.")
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange)
    }

    private var tablePicker: some View {
        HStack(spacing: 12) {
            Text("Table")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Picker("Table", selection: $selectedURL) {
                ForEach(tables, id: \.path) { url in
                    Text(url.deletingPathExtension().lastPathComponent)
                        .lineLimit(1)
                        .tag(Optional(url))
                }
            }
            .pickerStyle(.menu)
            Spacer(minLength: 0)
            if let table {
                Text("\(table.nets.count) nets · \(table.components.count) symbols")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func tableContent(_ table: ConnectionTable) -> some View {
        List {
            Section {
                LabeledContent("Schematic", value: table.schematicTitle)
                LabeledContent("Saved from", value: table.sourceFileName)
                LabeledContent("Generated", value: table.generatedAt.formatted(date: .abbreviated, time: .standard))
                if !table.unresolvedSymbols.isEmpty {
                    Text("Could not load: \(table.unresolvedSymbols.joined(separator: ", ")) — their pins are not in this table.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Connection table")
            }

            if table.nets.isEmpty {
                Section {
                    Text("No connections yet — no net in this schematic joins 2 or more pins.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(Array(table.nets.enumerated()), id: \.offset) { _, net in
                Section {
                    ForEach(Array(net.endpoints.enumerated()), id: \.offset) { _, endpoint in
                        endpointRow(endpoint)
                    }
                } header: {
                    HStack(spacing: 8) {
                        Text(net.name)
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text("\(net.endpoints.count) connected")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.55))
                        if !net.aliases.isEmpty {
                            Text("also: \(net.aliases.joined(separator: ", "))")
                                .font(.caption)
                                .foregroundStyle(.orange.opacity(0.9))
                        }
                    }
                }
            }

            if !table.components.isEmpty {
                Section {
                    ForEach(Array(table.components.enumerated()), id: \.offset) { _, component in
                        componentRow(component)
                    }
                } header: {
                    Text("Symbols & footprints")
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func endpointRow(_ endpoint: ConnectionEndpoint) -> some View {
        HStack(spacing: 10) {
            Text(endpoint.reference)
                .font(.body.weight(.bold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text("pin \(endpoint.pinNumber)")
                .font(.body)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            if !endpoint.pinName.isEmpty {
                Text("(\(endpoint.pinName))")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text("\(endpoint.symbolName) · \(LibraryStore.displayName(forLibraryKey: endpoint.library))")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func componentRow(_ component: ConnectionComponent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(component.reference)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(component.symbolName)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            if let footprint = component.footprintReference {
                if let resolved = component.resolvedFootprintKey {
                    // Part 3: the recorded key is the EFFECTIVE one.
                    // A nil footprintMatchKind is a pre-part-3 (v2.0)
                    // table — its resolution came from the Footprint
                    // property, so it displays exactly as before. A
                    // per-instance choice is called out.
                    Text("Footprint: \(footprint) → imported as \(resolved)\(component.footprintMatchKind == "instanceChoice" ? " (your choice)" : "")")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .lineLimit(2)
                } else {
                    Text("Footprint: \(footprint) → no imported footprint matches yet")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            } else if let resolved = component.resolvedFootprintKey {
                // No Footprint property, but an effective footprint was
                // recorded (a per-instance choice, or a filter-exact
                // resolution).
                Text("Footprint: → imported as \(resolved)\(component.footprintMatchKind == "instanceChoice" ? " (your choice)" : "")")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .lineLimit(2)
            } else {
                Text("Footprint: —")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func loadSelected() {
        table = nil
        loadError = nil
        guard let selectedURL else { return }
        do {
            table = try ConnectionTableStore.load(from: selectedURL)
        } catch {
            loadError = "Could not decrypt that table: \(error.localizedDescription)"
        }
    }
}
