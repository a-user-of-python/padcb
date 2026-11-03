import SwiftUI

/// Launcher screen: two big, high-contrast destinations (Schematic Editor,
/// PCB Editor), the footprint browser, and — TEMPORARY, part 2 — a debug
/// button that decrypts the saved connection tables. Plus live status
/// lines for the symbol library index and the footprint scans.
///
/// All labels are single-line by design — see the LumenScene top-bar lesson
/// recorded in the project contracts (no wrapping button titles, ever).
struct HomeView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var footprintStore: FootprintStore

    /// Path-based navigation (part 5.3, S8): the editors receive a
    /// `navigate` closure that appends a destination value, so
    /// cross-probing can push the OTHER editor ("Show on Board" /
    /// "Show in Schematic") without either editor knowing about
    /// the stack. Values are "schematic" / "pcb", resolved by the
    /// navigationDestination below.
    @State private var navPath: [String] = []

    private var libraryCount: Int {
        Set(store.index.map(\.libraryKey)).count
    }

    var body: some View {
        NavigationStack(path: $navPath) {
            ZStack {
                Color(white: 0.08)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 28) {
                        header
                        navigationButtons
                        importStatus
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: 640)
                    .padding(.horizontal, 32)
                    .padding(.top, 40)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("PadCB")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { destination in
                switch destination {
                case "schematic":
                    SchematicEditorView(navigate: { navPath.append($0) })
                case "pcb":
                    PCBEditorView(navigate: { navPath.append($0) })
                default:
                    EmptyView()
                }
            }
            .task {
                store.bootstrap()
                footprintStore.bootstrap()
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 8) {
            Text("PadCB")
                .font(.system(size: 56, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text("Schematic & PCB design")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
        }
    }

    private var navigationButtons: some View {
        VStack(spacing: 16) {
            NavigationLink(value: "schematic") {
                launcherRow(icon: "point.3.connected.trianglepath.dotted",
                            title: "Schematic Editor")
            }
            .buttonStyle(.plain)

            NavigationLink(value: "pcb") {
                launcherRow(icon: "circuitboard",
                            title: "PCB Editor")
            }
            .buttonStyle(.plain)

            NavigationLink {
                FootprintBrowserView()
            } label: {
                launcherRow(icon: "square.grid.3x3.square",
                            title: "Footprint Browser")
            }
            .buttonStyle(.plain)

            // TEMPORARY (part 2): decrypts the connection table written
            // on every schematic save and shows what connects to what.
            // Remove when the PCB editor consumes the tables directly.
            NavigationLink {
                ConnectionDebugView()
            } label: {
                launcherRow(icon: "tablecells.badge.ellipsis",
                            title: "Debug: View Connections",
                            badge: "TEMPORARY")
            }
            .buttonStyle(.plain)
        }
    }

    private func launcherRow(icon: String, title: String, badge: String? = nil) -> some View {
        HStack(spacing: 18) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .medium))
                .frame(width: 44)
                .lineLimit(1)
            Text(title)
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            if let badge {
                Text(badge)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.black)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.orange, in: Capsule())
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .frame(height: 76)
        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Import status

    @ViewBuilder
    private var importStatus: some View {
        VStack(spacing: 8) {
            symbolStatus
            if store.customLibraryCount > 0 {
                statusLine("Your libraries: \(store.customLibraryCount) file\(store.customLibraryCount == 1 ? "" : "s") in Symbols folder",
                           color: .green.opacity(0.9))
            }
            if store.isScanningCustomLibraries {
                statusLine("Scanning your Symbols folder…", color: .white.opacity(0.65))
            }
            ForEach(Array(store.customLibraryIssues.prefix(3).enumerated()), id: \.offset) { _, issue in
                statusLine(issue, color: .orange.opacity(0.9))
            }
            footprintStatus
            ForEach(Array(footprintStore.issues.prefix(3).enumerated()), id: \.offset) { _, issue in
                statusLine(issue, color: .orange.opacity(0.9))
            }
            Text("Add your own parts in the Files app: PadCB ▸ Symbols (.kicad_sym) · PadCB ▸ Footprints (.kicad_mod)")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
    }

    private func statusLine(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(color)
            .lineLimit(2)
            .multilineTextAlignment(.center)
    }

    @ViewBuilder
    private var symbolStatus: some View {
        if store.indexReady {
            statusLine("KiCad symbol libraries — \(store.index.count.formatted()) symbols in \(libraryCount) libraries",
                       color: .white.opacity(0.65))
        } else if let loadError = store.loadError {
            statusLine(loadError, color: .red.opacity(0.9))
        } else {
            HStack(spacing: 10) {
                ProgressView()
                    .tint(.white)
                Text("Loading symbol libraries…")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var footprintStatus: some View {
        if footprintStore.isScanning && !footprintStore.didScan {
            HStack(spacing: 10) {
                ProgressView()
                    .tint(.white)
                Text("Scanning footprints…")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
        } else if footprintStore.didScan {
            let userCount = footprintStore.userFootprints.count
            let bundledCount = footprintStore.bundledFootprints.count
            statusLine("Footprints — \(bundledCount.formatted()) KiCad library footprints · \(userCount) imported by you",
                       color: .white.opacity(0.65))
        }
    }
}
