import Foundation
import Combine

/// Session bridge (part 5.3) — the app-wide objects that let the
/// two editors, and the AirPlay / external-display scene, share ONE
/// live session instead of three private copies.
///
/// `AppSessionHub.shared` is the canonical owner: PadCBApp takes
/// its stores FROM the hub, and the UIKit-instantiated external
/// display scene delegate (ExternalDisplay.swift) reaches the same
/// objects through the hub — an external window's hosting
/// controller is NOT inside the main scene's SwiftUI environment,
/// so environment objects alone could never reach it.
///
/// Foundation + Combine only: this file deliberately knows nothing
/// about SwiftUI or UIKit.

// MARK: - Cross-probe (schematic <-> PCB highlight transport)

/// The cross-probing target (part 5.3, KiCad's cross-probing):
/// "Show on Board" publishes `.footprint(reference:)`, "Show in
/// Schematic" publishes `.symbol(reference:)`; the receiving editor
/// observes `target`, selects + centres that item, and the value
/// stays until the next probe (consumers compare against what they
/// last handled so a stale target does not re-fire on every appear).
final class CrossProbe: ObservableObject {
    enum Target: Equatable {
        case footprint(reference: String)
        case symbol(reference: String)
    }

    @Published var target: Target? = nil
}

// MARK: - Live session registry (what the external display mirrors)

/// The live-session registry the external display renders from.
///
/// The schematic side publishes the document OBJECT itself (true
/// live sharing: the external canvas observes the same
/// `SchematicDocument` the editor mutates, so edits redraw there
/// automatically). The PCB session is un-factored view state inside
/// PCBEditorView, so it publishes a value snapshot — title +
/// BoardState + BoardModel — refreshed at the editor's existing
/// mutation choke point (`refreshChecks()`), and cleared on
/// disappear.
final class LiveSessionRegistry: ObservableObject {
    struct PCBSnapshot {
        var title: String
        var state: BoardState
        var model: BoardModel
    }

    @Published var schematicDocument: SchematicDocument? = nil
    @Published var pcbSnapshot: PCBSnapshot? = nil

    func publishPCB(title: String, state: BoardState, model: BoardModel) {
        pcbSnapshot = PCBSnapshot(title: title, state: state, model: model)
    }

    func clearPCB() {
        pcbSnapshot = nil
    }
}

// MARK: - Hub

/// The single owner of the app's shared objects. Created once;
/// every consumer (PadCBApp, the editors via the environment, the
/// external-display scene) reaches the SAME instances through here.
final class AppSessionHub {
    static let shared = AppSessionHub()

    let libraryStore = LibraryStore()
    let footprintStore = FootprintStore()
    let crossProbe = CrossProbe()
    let liveSession = LiveSessionRegistry()

    private init() {}
}
