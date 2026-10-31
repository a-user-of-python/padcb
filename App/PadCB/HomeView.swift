import SwiftUI

/// Launcher screen: two big, high-contrast destinations (Schematic Editor,
/// PCB Editor) plus a live status line for the KiCad symbol library index.
///
/// All labels are single-line by design — see the LumenScene top-bar lesson
/// recorded in the project contracts (no wrapping button titles, ever).
struct HomeView: View {
    @EnvironmentObject private var store: LibraryStore

    private var libraryCount: Int {
        Set(store.index.map(\.library)).count
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(white: 0.08)
                    .ignoresSafeArea()

                VStack(spacing: 32) {
                    header
                    navigationButtons
                    libraryStatus
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: 640)
                .padding(.horizontal, 32)
                .padding(.top, 48)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("PadCB")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                store.bootstrap()
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
            NavigationLink {
                SchematicEditorView()
            } label: {
                launcherRow(icon: "point.3.connected.trianglepath.dotted",
                            title: "Schematic Editor")
            }
            .buttonStyle(.plain)

            NavigationLink {
                PCBPlaceholderView()
            } label: {
                launcherRow(icon: "circuitboard",
                            title: "PCB Editor")
            }
            .buttonStyle(.plain)
        }
    }

    private func launcherRow(icon: String, title: String) -> some View {
        HStack(spacing: 18) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .medium))
                .frame(width: 44)
                .lineLimit(1)
            Text(title)
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
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

    @ViewBuilder
    private var libraryStatus: some View {
        if store.indexReady {
            Text("KiCad symbol libraries — \(store.index.count.formatted()) symbols in \(libraryCount) libraries")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        } else if let loadError = store.loadError {
            Text(loadError)
                .font(.callout)
                .foregroundStyle(.red.opacity(0.9))
                .lineLimit(2)
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
}
