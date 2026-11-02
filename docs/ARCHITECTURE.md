# PadCB architecture

How the app is put together. Everything here describes the current shipped
state (v5.2). For the user-facing overview, see the [README](../README.md).

## Shape of the app

A single SwiftUI app (`App/PadCB/`) with two editors behind a home screen.
No system document picker is used anywhere: files move through the app's
Documents folders and in-app lists.

| Area | Files | Role |
| --- | --- | --- |
| App shell | `PadCBApp.swift`, `HomeView.swift`, `PadCBPaths.swift` | Entry point, home screen (Schematic Editor / PCB Editor / footprint browser / debug view), and the single source of truth for the Documents layout |
| File formats | `SExpr.swift` | One S-expression parser shared by the symbol and footprint formats |
| Symbols | `KiCadSymbol.swift` | `.kicad_sym` model and parser, including `extends` resolution with KiCad's root-only `Flatten()` semantics (a derived symbol's own sub-symbols are discarded, exactly as KiCad does) |
| Symbol rendering | `SymbolDrawList.swift`, `SymbolRenderer.swift` | The draw list is the *only* geometry the canvas renders — and the exact code the geometry audit compiles and diffs |
| Libraries | `LibraryStore.swift` | Bundled + custom symbol library index. Bundled libraries keep their plain name as key; a custom library's key is `user:<Name>`, displayed as "Name (Custom)" — a custom library never shadows a bundled one, and placed symbols record the key they came from |
| Schematic editor | `SchematicDocument.swift`, `SchematicCanvasView.swift`, `SchematicEditorView.swift`, `SymbolChooserView.swift`, `FileListView.swift` | Document model with snapshot undo, canvas, toolbars, chooser, in-app file lists |
| Footprints | `KiCadFootprint.swift`, `FootprintStore.swift`, `FootprintBrowserView.swift` | `.kicad_mod` parser/model; bundled index (`FootprintIndex.json`, parsed on demand) merged with user footprints from Documents; browser with rendered top-view previews |
| Search | `SearchEngine.swift` | The only search path in both browsers: precomputed canonical UTF-8 byte-blob indexes, single-pass bucketed ranking, run off the main thread with debounce and stale-result rejection |
| Matching | `FootprintMatcher.swift` | Symbol↔footprint association (model below) |
| Connection tables | `ConnectionTable.swift`, `ConnectionTableStore.swift`, `ConnectionDebugView.swift` | The encrypted netlist written on every save, its Keychain-backed store, and the temporary home-screen debug view |
| PCB editor | `PCBBoardModel.swift`, `PCBBoardState.swift`, `PCBDesignChecks.swift`, `TheoryAIBridge.swift`, `PCBEditorView.swift` | Correspondence model built from a decrypted table (pin↔pad binding, anomaly list); the editable board state — footprints, traces and their segments, vias, zones, copper layers — persisted per connection table and merged on sync; the deterministic Manufacturing Check, the heuristic Theory Check and its experimental on-device AI bridge; and the KiCad-style editor itself |

## The proof machinery

PadCB's claims about KiCad fidelity are gated in CI by harnesses that
compile the app's **real** sources headlessly — never a re-implementation:

| Workflow | Harness | What it proves |
| --- | --- | --- |
| *Geometry Audit* | `tools/GeomDump` + `tools/truth_model.py` / `tools/truth_diff.py` | Every bundled symbol (22,728 symbols, 27,961 units, 541,462 pins) rendered by the app's own draw-list code is diffed against an independent truth model built from KiCad 10.0.1 source semantics — coordinates, anchors, angles, strings, fills. Current result: **0 mismatches** across 12 classes |
| *Footprint Audit* | `tools/FootprintDump`, `tools/FootprintCensus` | The app's footprint parser reads fixtures and the full bundled corpus: **15,430 / 15,430 footprints, 0 failures** (386,124 pads) |
| *Part 3 Audit* | `tools/SearchBench` | A fixed 132-query battery over both corpora asserts the new search returns **identical result sets** to the previous implementation, and reports timings |
|  | `tools/MatchCensus` | Runs the real matcher over the whole bundled corpus and reports coverage in real counts, plus cross-namespace (bundled ↔ custom) fixture assertions |
|  | `tools/BoardFixture` | A fixture schematic → encrypted table → board model, with every pin→net→pad binding asserted by construction (294 assertions, since extended to sync-merge, traces, layers and segment editing), including pin 1 on the exact pad-1 geometry and a part whose symbol *and* footprint both come from custom libraries |
| *Build IPA* | — | Builds the unsigned IPA and verifies the bundle: bundle id, file-sharing keys, bundled library counts |

## The connection table

The bridge between the two editors, written on **every schematic save** to
`Documents/ConnectionTables/` as a `.pct` file:

- **Contents:** the schematic's netlist — for every net, its endpoints
  (component instance, pin number, pin name), plus each instance's
  effective footprint key and (since Part 3) how that footprint matched.
- **Encryption:** AES-256-GCM. The key is generated once per install and
  stored in the device Keychain; the plaintext table is never written to
  disk.
- **Format:** versioned JSON (`formatVersion` 1), extended **additively
  only** — new fields are optional, and tables written by v2.0 decode
  unchanged in v3.0 (proven by a hand-written v1 fixture).

## The matching model

Implemented from KiCad 10.0.1's own rules (`common/footprint_filter.cpp`,
`LIB_SYMBOL::Flatten()` in `eeschema/lib_symbol.cpp`):

1. **Effective footprint** for a placed instance, in order: the user's
   per-instance choice → the symbol's **Footprint property** → a single
   wildcard-free `ki_fp_filters` entry used as a reference.
2. **Filters** are anchored, whole-string, case-insensitive wildcard
   patterns matched against `Library:Footprint` candidate strings;
   filter inheritance is child-wins (a derived symbol's filters replace
   its parent's).
3. **Candidates** are ranked: pin-count-exact first (pin count vs the
   footprint's *distinct* pad numbers — duplicate pads are one electrical
   node), then the symbol's own source set (bundled/custom), then fewer
   surplus pads, then key.
4. Lookup runs over the **combined** bundled + custom sets in both
   directions; the chosen association persists per instance as
   `PlacedSymbol.footprintChoice`.

In the PCB editor, each pin from the connection table binds to the pad
with the same number in the matched footprint, using the pad's real
`.kicad_mod` geometry. Pins with no pad, pads with no pin, and unresolved
footprints are reported as anomalies, never dropped; power symbols are
excluded from the board and listed separately.

## v5.2 — pointer pipeline, board layers, and the check/index layer

The PCB editor's pointer path was rebuilt after the v5.1 device
report ("whenever I use hover the ui shakes back and forth"):

- **Pointer ownership.** `BoardPointerModel` (an ObservableObject in
  PCBEditorView.swift) owns the one `BoardPointerState`, the
  per-channel delivery diagnostics, and a coalescing throttle
  (at most one applied point per 1/60 s, latest wins, trailing
  point flushed on a 60 Hz timer). Only the canvas host and the
  status-bar readout observe it, so a hover event no longer
  re-evaluates the editor body. `BoardPointerState` keeps a hover
  slot PER delivery channel plus a freshness clock: the live point
  is the freshest live slot, and a channel's end-event clears only
  its own slot (v5.1 shared one slot — the arbitration half of the
  shake).
- **The route head is stateful** (`BoardRouteHead`, PCBBoardState
  .swift), mirroring KiCad's PNS LINE_PLACER posture: it carries
  the resolved endpoint, target pad and 45° corner across events
  with hysteresis (pad stickiness over a 1.6× exit band, snap-cell
  stickiness over a 0.8×grid band, corner carry while the carried
  corner stays legal). Preview and tap commit resolve through the
  same head — what hovers is what commits; cold taps equal the
  pure resolution. The preview is resolved on pointer events into
  a cache; drawing never resolves.
- **Two canvas layers** (pcbnew's VIEW/GAL separation): a static
  layer draws the whole board + ratsnest and re-renders only when
  its Equatable token changes (model/checks/selection/transform);
  a preview layer above it draws everything pointer-driven.
- **Spatial index** (`BoardSpatialIndex`): a uniform 2 mm grid
  over pads/segments/traces/vias/components/zones/graphics whose
  queries replicate the previous linear scans exactly (winner
  rules and tie-breaks included; fixture-proven over 3,000 random
  queries × 7 lookups, 0 mismatches). It rebuilds in
  `refreshChecks` — the single choke point every model mutation
  already passed through — together with connectivity, clearance
  and the **ratsnest** (`BoardRatsnest`: MST over unconnected pad
  groups, Prim over nearest-pad links).
- **Checks growth:** Manufacturing runs 10 rules (9: via annular
  ring ≥ 5 mil; 10: courtyard overlap from `*.CrtYd` bounds),
  rules 1–8 unchanged. The schematic editor gained an ERC
  (`SchematicERC`, ConnectionTable.swift) that derives its nets
  from the REAL connection-table build — pin census, driven-ness,
  output conflicts, duplicate/unannotated references (power
  symbols exempt), unresolved symbols, floating labels — plus
  KiCad-style automatic annotation (first-free number per prefix,
  sheet order, one undo step) in SchematicDocument.
- **Symbol bodies:** the KiCad parser now routes style-2
  sub-symbols to an alternate-body table (`altUnits`), so De
  Morgan bodies render; style-1 output is byte-identical
  (Geometry Audit stays 0). `PlacedSymbol.bodyStyle` is an
  additive optional (absent = standard body), and all
  properties-card edits flow through `SchematicDocument
  .editSymbol`, which records exactly one undo step per real
  change.
