<p align="center">
  <img src="App/Assets.xcassets/AppIcon.appiconset/icon-1024.png" width="120" alt="PadCB app icon">
</p>

<h1 align="center">PadCB</h1>

<p align="center">
  <strong>Schematic capture and PCB design on iPad — KiCad's workflow, rebuilt as a native SwiftUI app.</strong>
</p>

<p align="center">
  <a href="https://github.com/a-user-of-python/padcb/actions/workflows/build-ipa.yml"><img src="https://github.com/a-user-of-python/padcb/actions/workflows/build-ipa.yml/badge.svg" alt="Build IPA"></a>
  <a href="https://github.com/a-user-of-python/padcb/actions/workflows/geometry-audit.yml"><img src="https://github.com/a-user-of-python/padcb/actions/workflows/geometry-audit.yml/badge.svg" alt="Geometry Audit"></a>
  <a href="https://github.com/a-user-of-python/padcb/actions/workflows/footprint-audit.yml"><img src="https://github.com/a-user-of-python/padcb/actions/workflows/footprint-audit.yml/badge.svg" alt="Footprint Audit"></a>
  <a href="https://github.com/a-user-of-python/padcb/actions/workflows/part3-audit.yml"><img src="https://github.com/a-user-of-python/padcb/actions/workflows/part3-audit.yml/badge.svg" alt="Part 3 Audit"></a>
</p>

PadCB is an original iPad EDA app that recreates KiCad's schematic and PCB
editing workflow — canvas, toolbars, symbol chooser, pin-to-pin wiring — as a
native SwiftUI app. It is **not** a port of KiCad's code: the app is written
from scratch, KiCad 10's source is used only as the reference for file-format
and rendering *semantics*, and KiCad's own symbol and footprint libraries are
bundled as data under their license (see [Licensing](#licensing)).

The app opens to two buttons — **Schematic Editor** and **PCB Editor** — and
is built in parts, each one verified against the real KiCad libraries before
it ships.

## Screenshots

> 📷 **Coming soon.** Drop images into
> [`docs/screenshots/`](docs/screenshots/) and they will appear here.

<!-- Suggested shots (uncomment and adjust once the files exist):
<p align="center">
  <img src="docs/screenshots/schematic-editor.png" width="49%" alt="Schematic editor">
  <img src="docs/screenshots/symbol-chooser.png" width="49%" alt="Symbol chooser">
</p>
<p align="center">
  <img src="docs/screenshots/pcb-editor.png" width="49%" alt="PCB editor">
  <img src="docs/screenshots/footprint-browser.png" width="49%" alt="Footprint browser">
</p>
-->

## Status

| Part | Contents | State |
| --- | --- | --- |
| **Part 1** (v1.3) | Schematic editor: KiCad-style canvas, toolbars, symbol chooser with previews, pin-to-pin drag wiring, labels, datasheets — with the full KiCad 10.0.1 symbol libraries bundled | ✅ Shipped |
| **Part 2** (v2.0) | File sharing, your own imported symbol libraries, encrypted connection table saved with every schematic, `.kicad_mod` footprint parser + browser, full KiCad footprint libraries bundled | ✅ Shipped |
| **Part 3** (v3.0) | Instant search, KiCad-model symbol↔footprint matching, PCB editor shell, and schematic→PCB correspondence (the PCB editor reads the connection table and binds every pin to its footprint pad) | ✅ Shipped |
| **Part 4** (v4.0) | The PCB editor becomes a working editor: move/delete footprints, route resizeable traces (45° bends, per-net), draw lines/arcs/circles/text, highlight nets, real layer/object visibility, zoom to 6000%, and boards that persist per schematic and merge (never wipe) on Sync from Schematic | ✅ Shipped |
| **Part 5** (v5.0) | PCB depth pass: adjustable snap grid (in mils) on everything, multi-select with trace-length totals, any-layer active + configurable copper layer count, vias, copper fill zones, Flip Side (F.Cu↔B.Cu with true footprint mirroring), Pencil hover routing preview, bottom trace-width slider, and three checking tiers — live clearance check, a deterministic Manufacturing Check, and a Theory Check with an optional fully on-device AI pass | ✅ Shipped |
| **Part 5.0.1** (v5.0.1) | Pencil hover rebuilt on KiCad's interactive-router model: v5.0's hover preview froze at the first tap (a never-cleared touch point masked every hover update — diagnosed from the shipped code). Now hover and touch feed ONE pointer stream, delivered by a real UIKit `UIHoverGestureRecognizer` bridge; the routing preview is pad-anchored with a 45° corner and grid snap exactly like KiCad's router head, the pad under the pencil lights up (red when joining it would cross nets), and the previewed point is provably the point a tap commits (BoardFixture 205/205) | ✅ Shipped |
| **Part 5.0.2** (v5.0.2) | Pencil hover, delivery round: v5.0.1's model was right but its single delivery path delivered nothing on hardware (forensics: a hit-test-transparent overlay's own recognizer is excluded from hover hit-testing too — dead by construction — and its recognizers lent to near ancestors were a gamble on the framework's private view hierarchy). Hover now arrives on THREE independent channels into the same pointer stream — the overlay itself (hover-hit-testable, still touch-transparent), a recognizer on the hosting hierarchy's root view, and SwiftUI's continuous-hover feed — and the PCB status bar shows live per-channel event counts ("Hover 1: n · 2: n · 3: n · (x, y)") so the working channel names itself on real hardware (BoardFixture 233/233) | ✅ Shipped |
| **Part 5.0.3** (v5.0.3) | Pencil hover, round 3 — own the hierarchy: v5.0.2's three worked-around channels still didn't reach the Pencil Pro, so the workarounds are gone. ONE dedicated UIKit interaction view sits frontmost over the board canvas and is the hit view for hover AND touches alike, with the `UIHoverGestureRecognizer` attached directly to it (Apple's canonical pattern); it consumes no touches (the editor's drag/pinch gestures attach to the canvas+interaction composite and receive them as before — proven in the simulator exercise: the view IS the hit-test result at the canvas centre, and tap + pan still land). Click a pad, hover-draw the trace through the air, click again to confirm. One primary channel + SwiftUI's feed as counted fallback ("Hover 1: n · 2: n · (x, y)"); BoardFixture 235/235 | ✅ Shipped — **current** |
| **Future** | KiCad `.kicad_sch` round-trip; PCB export (e.g. Gerber) | 🔜 Planned |

Current limits: projects save in PadCB's own format (no `.kicad_sch`
round-trip yet), and there is no PCB export yet — boards live in the app
(and as readable JSON in Documents/Boards).

## Features

### Schematic editor

- KiCad-style canvas and workflow: place, move (wires follow pins), rotate,
  mirror, delete; pin-to-pin wiring with 0.9 mm pin snap and auto-junctions;
  drag to draw wires, lift to commit; net labels; 120-step undo.
- Multi-unit and power symbols, all graphic primitives, all 12 pin
  electrical types and 8 pin shapes.
- Symbol chooser with live preview, description and keywords — and a
  datasheet link wherever the symbol carries a real URL (19,813 of the
  bundled symbols, 87.2%).

### The full KiCad libraries, built in

- **Symbols:** all 222 KiCad 10.0.1 libraries — **22,728 symbols,
  541,462 pins** — bundled into the app, fully offline.
- **Footprints:** all 155 `.pretty` libraries — **15,430 footprints** —
  bundled verbatim (3D models excluded), parsed on demand.
- Both corpora are *proven*, not just parsed: a geometry audit compiles the
  app's real rendering code and diffs every symbol against an independent
  truth model built from KiCad 10 source semantics (**0 mismatches** across
  12 check classes), and a full-corpus census requires the app's own Swift
  parsers to read **every** symbol and footprint file cleanly before a
  build can go green.

### Your own libraries

File sharing is on, and PadCB never uses the system document picker —
everything flows through the app's Documents folders (see
[App folders](#app-folders)):

- Drop `.kicad_sym` files into **Symbols** and they appear in the chooser
  next to the bundled libraries (marked *(Custom)*), searchable, placeable
  and wireable. A custom library never shadows a bundled one of the same
  name — both stay available. Malformed files are skipped and reported,
  never fatal.
- Drop `.kicad_mod` files (or `.pretty` folders) into **Footprints** and
  browse them in the Footprint Browser with rendered top-view previews.

### Search that keeps up

Both browsers search precomputed indexes off the main thread, with debounced
typing and stale-result rejection. Measured on the full bundled corpora,
median query time went from **123.7 ms → 2.04 ms** (symbols, 60×) and
**121.3 ms → 2.74 ms** (footprints, 44×) — with result sets proven identical
to the old implementation across a fixed 132-query battery.

### Symbols know their footprints

Matching follows KiCad's own model:

- A symbol's **Footprint property** (`Library:Footprint`) is the primary
  link; its **`ki_fp_filters`** wildcard patterns define the candidate set.
- Pins bind to pads **by number**; pad counts compare against the
  footprint's *distinct* pad numbers (duplicate pads are one node).
- The properties card shows the matched footprint and how it matched —
  your choice / property / filters — and a ranked picker lets you choose a
  different candidate for that placed part. The choice is saved with the
  schematic.
- Matching works across bundled and imported libraries in both directions.
- Corpus-wide: **17,970** of the 18,003 Footprint properties resolve to a
  bundled footprint, **20,219** symbols have at least one pin-exact filter
  candidate, and 1,305 are unmatched — including all 131 power symbols,
  which have no footprint by design.

### PCB editor: the schematic, as a board

Open the PCB editor, pick a saved schematic, and PadCB decrypts its
connection table and builds the board:

- Every component appears with its matched footprint drawn on a KiCad-style
  board canvas (tool rail, Layers / Objects / Components panels, status
  bar), pads numbered and labelled with their nets from the schematic —
  **pin 1 is the real pad 1** from the footprint's own geometry.
- Each component's full pin→pad list is shown (pin, net, pad size/drill).
- Anything that doesn't line up — a pin with no pad, a pad with no pin, an
  unresolved footprint — is listed plainly under **Problems**, never
  silently dropped. Power symbols are excluded and listed separately.
- Since part 4 it is a working editor: drag footprints to place them,
  route copper traces pad-to-pad (they bend at 45° and their width can be
  changed any time), draw board graphics and text, highlight a whole net,
  and hide layers or object classes for real. Board work is saved per
  schematic (Documents/Boards, plain JSON) and **Sync from Schematic**
  merges the schematic's latest save into the board — placements and
  traces survive, parts deleted from the board are restored and named in
  the sync report, and a trace whose net disappears stays on the board,
  flagged unconnected under Problems.
- The correspondence — and now the merge, trace, visibility and zoom
  rules — is proven off-device by a fixture board (schematic → encrypted
  table → board model → merged board state, every step asserted):
  **110/110 checks**.

## How it works

### The encrypted connection table

Every schematic save also writes a **connection table** — the netlist of
what connects to what (per net: every endpoint instance, pin number and pin
name) — encrypted with **AES-256-GCM**, the key generated once and held in
the device Keychain. The table is the bridge artifact between the two
editors: the PCB editor decrypts it to build the board, and a temporary
**Debug: View Connections** button on the home screen decrypts and displays
a saved table so the contents can be checked against the drawing. The
format is versioned and extended additively only — tables written by older
versions still decode.

### Library pipeline

The KiCad libraries are pinned to release **10.0.1** and downloaded from
KiCad's GitLab at CI build time (the GitHub mirror's tags stop at the 5.1
era):

- Symbols: `kicad-symbols`, commit `7058584a0fbe9aa2f1c9ff2acf7847726ff6922c`.
  KiCad 10 ships one file per symbol in `<Library>.kicad_symdir/`
  directories; `tools/merge_symdirs.py` merges each into a single
  per-library `.kicad_sym`, symbol definitions unmodified.
- Footprints: `kicad-footprints`, commit
  `3d2b27e687a44c97f02109afb2acfeebbc8dd75f` — only the `*.pretty` folders,
  bundled verbatim with a CI-generated index.

More detail: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## App folders

PadCB's Documents folder (Files app ▸ PadCB) is the whole interface between
the app and your files:

| Folder | What goes there |
| --- | --- |
| `Symbols/` | Your own `.kicad_sym` symbol libraries — they join the chooser (this folder was `Libraries/` in v2.0; anything left there is migrated automatically on launch) |
| `Footprints/` | Your own `.kicad_mod` footprints or `.pretty` folders — they join the Footprint Browser |
| `ConnectionTables/` | The encrypted connection table written on every schematic save (`.pct` files — ciphertext, not readable text) |

Schematics themselves are saved and opened from inside the app, via in-app
lists — no system picker anywhere.

## Build & install

**CI** (GitHub Actions, standard `macos-26` runner) downloads the pinned
libraries, runs the censuses and audits, builds the app unsigned, verifies
the bundle (bundle id, file-sharing keys, bundled library counts) and
packages **`PadCB-unsigned.ipa`** (~41 MB — most of it the bundled footprint
corpus) as a workflow artifact.

**Install:** download the artifact from a green *Build IPA* run and sideload
the unsigned IPA with your usual signing tool or service.

**Locally:** the `App/PadCB/Symbols/` folder starts empty (see the README
inside it); populate it with the release's `*.kicad_sym` files to run with
libraries on a Mac.

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — how the app is put
  together: module map, the audit machinery, the connection-table format,
  the matching model.
- [tools/GeomDump/README.md](tools/GeomDump/README.md) — the geometry
  audit harness that diffs the app's real rendering code against the
  KiCad-semantics truth model.
- [docs/screenshots/README.md](docs/screenshots/README.md) — where to drop
  screenshots for this README.

## Licensing

- **PadCB's code is an original work** by the author and is not derived
  from KiCad's source code; only the UI layout/workflow concepts and the
  library *data* are used.
- **The KiCad symbol and footprint libraries** are licensed under the
  Creative Commons Attribution-ShareAlike 4.0 International License
  (**CC BY-SA 4.0**) with the **KiCad Library Exception** (libraries may be
  embedded in designs without triggering share-alike for those designs).
  Canonical sources:
  [kicad-symbols](https://gitlab.com/kicad/libraries/kicad-symbols) ·
  [kicad-footprints](https://gitlab.com/kicad/libraries/kicad-footprints).
  The full license texts ship inside the app bundle next to the libraries
  (`Symbols/KICAD-LIBRARIES-LICENSE.md`,
  `Footprints/KICAD-FOOTPRINTS-LICENSE.md`) and attribution is shown in
  the app.

---

*PadCB is built in parts; this README describes the current shipped state
(v3.0).*
