import SwiftUI

/// PadCB — schematic & PCB design for iPad.
///
/// Part 1 ships the schematic editor backed by real KiCad symbol libraries.
/// Part 2 adds user-imported symbol libraries + footprints (bundled and
/// user-imported) and the encrypted connection tables. The shared stores
/// are created here and handed down through the environment; indexing is
/// kicked off from `HomeView`'s `.task` so the App itself stays trivial.
@main
struct PadCBApp: App {
    @StateObject private var store = LibraryStore()
    @StateObject private var footprintStore = FootprintStore()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(store)
                .environmentObject(footprintStore)
        }
    }
}
