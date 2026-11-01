# PadCB architecture

How the app is put together. Everything here describes the current shipped
state (v3.0). For the user-facing overview, see the [README](../README.md).

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
| PCB editor | `PCBBoardModel.swift`, `PCBEditorView.swift` | Board model built from a decrypted table (pin↔pad binding, anomaly list) and the KiCad-style editor shell that displays it |

## The proof machinery

PadCB's claims about KiCad fidelity are gated in CI by harnesses that
compile the app's **real** sources headlessly — never a re-implementation:

| Workflow | Harness | What it proves |
| --- | --- | --- |
| *Geometry Audit* | `tools/GeomDump` + `tools/truth_model.py` / `tools/truth_diff.py` | Every bundled symbol (22,728 symbols, 27,961 units, 541,462 pins) rendered by the app's own draw-list code is diffed against an independent truth model built from KiCad 10.0.1 source semantics — coordinates, anchors, angles, strings, fills. Current result: **0 mismatches** across 12 classes |
| *Footprint Audit* | `tools/FootprintDump`, `tools/FootprintCensus` | The app's footprint parser reads fixtures and the full bundled corpus: **15,430 / 15,430 footprints, 0 failures** (386,124 pads) |
| *Part 3 Audit* | `tools/SearchBench` | A fixed 132-query battery over both corpora asserts the new search returns **identical result sets** to the previous implementation, and reports timings |
|  | `tools/MatchCensus` | Runs the real matcher over the whole bundled corpus and reports coverage in real counts, plus cross-namespace (bundled ↔ custom) fixture assertions |
|  | `tools/BoardFixture` | A fixture schematic → encrypted table → board model, with every pin→net→pad binding asserted by construction (43 assertions), including pin 1 on the exact pad-1 geometry and a part whose symbol *and* footprint both come from custom libraries |
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
