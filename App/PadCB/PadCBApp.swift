import SwiftUI
import UIKit

/// PadCB — schematic & PCB design for iPad.
///
/// Part 1 ships the schematic editor backed by real KiCad symbol libraries.
/// Part 2 adds user-imported symbol libraries + footprints (bundled and
/// user-imported) and the encrypted connection tables. Part 3 adds fast
/// search, symbol↔footprint matching, and the PCB editor shell. The shared
/// stores are created here and handed down through the environment;
/// indexing is kicked off from `HomeView`'s `.task` so the App itself
/// stays trivial.
///
/// Device gate (v3.1): PadCB is designed for iPad. On iPhone the app
/// presents ONLY `IPadRequiredView` — the stores never bootstrap (their
/// indexing starts in `HomeView`'s `.task`, which never runs) and no
/// editor UI is reachable. On iPad the launch path is exactly the
/// pre-gate one, unchanged.
@main
struct PadCBApp: App {
    @StateObject private var store = LibraryStore()
    @StateObject private var footprintStore = FootprintStore()

    var body: some Scene {
        WindowGroup {
            if UIDevice.current.userInterfaceIdiom == .phone {
                IPadRequiredView()
            } else {
                iPadRoot
            }
        }
    }

    /// The iPad root: normally HomeView. A DEBUG build launched
    /// with `-padcbHoverCheck` (the simulator hover exercise,
    /// part 5.0.2) goes straight to the PCB editor on a seeded
    /// fixture board instead. Release builds compile that branch
    /// out entirely (the hover-check workflow passes
    /// SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG; the IPA build
    /// does not).
    @ViewBuilder
    private var iPadRoot: some View {
        #if DEBUG
        if HoverCheckSeed.isEnabled {
            HoverCheckRootView()
                .environmentObject(store)
                .environmentObject(footprintStore)
        } else {
            HomeView()
                .environmentObject(store)
                .environmentObject(footprintStore)
        }
        #else
        HomeView()
            .environmentObject(store)
            .environmentObject(footprintStore)
        #endif
    }
}

/// The only screen PadCB shows on iPhone: one headline, one supporting
/// line, nothing else. High contrast on the app's dark background,
/// Dynamic Type sizes (natural proportions — nothing force-enlarged),
/// and the headline is allowed to wrap so it is never clipped on a
/// narrow phone screen.
private struct IPadRequiredView: View {
    var body: some View {
        ZStack {
            Color(white: 0.08)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "ipad")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(.white.opacity(0.85))
                Text("You need an iPad for this to work")
                    .font(.title.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text("PadCB is designed for the iPad's larger screen.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
            .padding(32)
        }
        .preferredColorScheme(.dark)
    }
}
