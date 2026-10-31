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

## Building

CI (GitHub Actions, standard macos-26 runner) downloads the pinned symbol
libraries, validates them, builds the app unsigned, verifies the bundle
(file-sharing keys, bundle id, bundled library count), and packages
`PadCB-unsigned.ipa`.

Locally the `App/PadCB/Symbols/` folder starts empty (see the README inside
it); populate it with the release's `*.kicad_sym` files to run with
libraries on a Mac.
