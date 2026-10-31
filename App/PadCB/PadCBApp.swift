import SwiftUI

/// PadCB — schematic & PCB design for iPad.
///
/// Part 1 ships the schematic editor backed by real KiCad symbol libraries.
/// The shared `LibraryStore` is created here and handed down through the
/// environment; indexing of the bundled `.kicad_sym` files is kicked off
/// from `HomeView`'s `.task` so the App itself stays trivial.
@main
struct PadCBApp: App {
    @StateObject private var store = LibraryStore()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(store)
        }
    }
}
