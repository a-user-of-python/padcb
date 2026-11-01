# PadCB

An iPad schematic + PCB design app, built in parts. Part 1 is the schematic
editor: a KiCad-style schematic-editing workflow (canvas, toolbars, symbol
chooser, pin-to-pin wiring) as an original SwiftUI app.

## KiCad symbol libraries

PadCB bundles the complete **KiCad default symbol libraries**
(the `kicad-symbols` set, `.kicad_sym` files), pinned to release **10.0.1**
(commit `7058584a0fbe9aa2f1c9ff2acf7847726ff6922c`).

- Canonical source: https://gitlab.com/kicad/libraries/kicad-symbols
  (the GitHub mirror `KiCad/kicad-symbols` is a legacy mirror whose tags stop
  at the 5.1.x era, so the current libraries come from KiCad's GitLab).
- The libraries are downloaded at CI build time from the pinned release and
  bundled into the app, so the app works fully offline. KiCad 10 ships them
  as one file per symbol inside `<Library>.kicad_symdir/` directories
  (222 libraries, 22,728 symbols); the build merges each directory into a
  single per-library `.kicad_sym` file with `tools/merge_symdirs.py`,
  extracting the symbol definitions unmodified.
- **License**: the KiCad libraries are licensed under the Creative Commons
  Attribution-ShareAlike 4.0 International License (CC BY-SA 4.0) with the
  KiCad Library Exception (libraries may be embedded in designs without
  triggering share-alike for those designs). The full license text ships
  inside the app bundle next to the libraries
  (`Symbols/KICAD-LIBRARIES-LICENSE.md`) and attribution is shown in the app.
  PadCB's own code is an original work and is not derived from KiCad's
  source code; only the UI layout/workflow concepts and the library *data*
  (under its license) are used.

## Your own libraries & footprints (part 2)

File sharing is enabled, and PadCB never uses the system document
picker — everything flows through the app's Documents folders:

- **Documents/Symbols/** — drop your own `.kicad_sym` symbol
  libraries here (Files app ▸ PadCB ▸ Symbols). They appear in the
  symbol chooser alongside the bundled ones (marked CUSTOM / shown as
  "Name (Custom)"), fully searchable with previews, placeable and
  wireable like bundled symbols. A custom library never shadows a
  bundled one of the same name — both stay available. Malformed files
  are skipped and reported on the home screen. Rescan from the
  chooser's Rescan button. *(Renamed in part 3 — this folder was
  Documents/Libraries in part 2. On launch, PadCB moves any
  `.kicad_sym` files still in the old Libraries folder into Symbols
  automatically; if a file of the same name exists in both, the
  moved one is kept as "<Name> (Legacy)" so both stay usable.)*
- **Documents/Footprints/** — drop `.kicad_mod` footprints here
  (`.pretty`-style folders work too) and browse them, with rendered
  top-view previews, in the home screen's Footprint Browser. When a
  symbol's Footprint property ("Lib:Name") matches an imported
  footprint, the chooser and the properties card say so.
- **Documents/ConnectionTables/** — every schematic save also writes
  an encrypted connection table here (AES-256-GCM, key in the device
  Keychain): the netlist of what connects to what, for the future PCB
  editor. The home screen's temporary "Debug: View Connections"
  button decrypts and displays a saved table.

## Part 3 — fast search, footprint matching, PCB editor

- **Search is instant now.** The symbol chooser and footprint
  browser search precomputed indexes off the main thread (typing is
  debounced, grouping is cached). Measured on the full bundled
  corpora against the previous implementation: median query time
  124 ms → 2 ms (symbols) and 121 ms → 3 ms (footprints), with
  identical result sets across a 132-query test battery.
- **Symbols know their footprints.** Following KiCad's own model, a
  symbol's Footprint property is the primary link and its
  `ki_fp_filters` patterns define the candidates (pin count compared
  against the footprint's *distinct* pad numbers). The properties
  card shows the matched footprint and how it matched — and lets you
  pick a different candidate for that placed part; the choice is
  saved with the schematic. Matching works across bundled and
  imported libraries in both directions. Corpus-wide, 17,970 of the
  bundled symbols' Footprint properties resolve to a bundled
  footprint, and 21,419 symbols have at least one filter candidate.
- **The PCB editor reads the connection table.** Open it from the
  home screen, pick a saved schematic's table, and it builds the
  board: every component with its matched footprint drawn on the
  board canvas, pads numbered and labelled with their nets — pin 1
  is the real pad 1 from the footprint data. Each component's
  pin→pad list is shown in full, and anything that doesn't line up
  (a pin with no pad, a pad with no pin, an unresolved footprint)
  is listed plainly under Problems. This part is a viewing shell
  modelled on KiCad's PCB editor — placement, routing and editing
  arrive in a later part.

## KiCad footprint libraries

PadCB also bundles the complete **KiCad default footprint libraries**
(`kicad-footprints`, `.kicad_mod` files), pinned to release **10.0.1**
(commit `3d2b27e687a44c97f02109afb2acfeebbc8dd75f`).

- Canonical source: https://gitlab.com/kicad/libraries/kicad-footprints
- The build takes only the `*.pretty` library folders (15,430
  footprints in 155 libraries) — 3D models are excluded — and bundles
  the files verbatim; a CI-generated index lets the app list them all
  and parse each footprint on demand. Before the app builds, the
  app's own Swift parser must parse every one of the 15,430 files
  cleanly (the full-corpus census gates the build).
- **License**: same terms as the symbol libraries — CC BY-SA 4.0 with
  the KiCad Library Exception. The license text ships in the bundle
  (`Footprints/KICAD-FOOTPRINTS-LICENSE.md`).

## Building

CI (GitHub Actions, standard macos-26 runner) downloads the pinned symbol
libraries, validates them, builds the app unsigned, verifies the bundle
(file-sharing keys, bundle id, bundled library count), and packages
`PadCB-unsigned.ipa`.

Locally the `App/PadCB/Symbols/` folder starts empty (see the README inside
it); populate it with the release's `*.kicad_sym` files to run with
libraries on a Mac.
