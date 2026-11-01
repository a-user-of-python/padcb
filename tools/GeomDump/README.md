# GeomDump — headless geometry audit harness

GeomDump runs PadCB's **real** Swift geometry code over the full KiCad
symbol corpus and dumps the resulting canonical draw lists as JSONL,
so they can be diffed against an independent file-truth model
(`tools/truth_diff.py`, delivered separately). No part of the geometry
is re-implemented here: the harness is compiled from the app's own
sources.

## Build & run (macOS)

```sh
# 1. Populate the corpus the same way CI does (pinned KiCad 10.0.1):
curl -fL "https://gitlab.com/kicad/libraries/kicad-symbols/-/archive/10.0.1/kicad-symbols-10.0.1.tar.gz" -o /tmp/kicad-symbols.tar.gz
mkdir -p /tmp/kicad-symbols
tar -xzf /tmp/kicad-symbols.tar.gz -C /tmp/kicad-symbols --strip-components=1
python3 tools/merge_symdirs.py /tmp/kicad-symbols App/PadCB/Symbols

# 2. Compile the harness with the app's real geometry sources:
xcrun swiftc -O -o /tmp/GeomDump \
  App/PadCB/SExpr.swift \
  App/PadCB/KiCadSymbol.swift \
  App/PadCB/SchematicDocument.swift \
  App/PadCB/SymbolDrawList.swift \
  tools/GeomDump/main.swift

# 3. Run it over the corpus:
/tmp/GeomDump App/PadCB/Symbols dump.jsonl probes.jsonl
```

Parse problems are counted and logged to stderr (one summary line per
affected library, plus a final `files=… symbols=… unitDumps=…
parseErrors=…` line); they never abort the run and the exit status
stays 0.

The same steps run in CI: see `.github/workflows/geometry-audit.yml`,
which uploads `dump.jsonl`, `probes.jsonl` and the differ's
`report.json` / `report.txt` (when present) as the `geometry-audit`
artifact.

## Dump schema (`dump.jsonl`)

One JSON object per (library, symbol, unit), for units
`1...unitCount`. Unit 0 (common) items are merged in by the builder,
exactly as the renderer merges them. All coordinates are local symbol
coordinates: millimetres, y-up. All numbers are full Double precision
(`%.17g`). Symbols are emitted in sorted (library, symbol) order.

```json
{"lib":"Device","sym":"R","unit":1,"pins":[ ... ],"gfx":[ ... ]}
```

### Pins

Every pin of the merged units is emitted, visible **and** hidden, in
unit-0-then-unit order:

| key | meaning |
|---|---|
| `num` | pin number string |
| `name` | pin name, raw (with KiCad markup) |
| `plainName` | pin name with markup removed (`KiCadText.plain`) |
| `hidden` | pin hidden flag |
| `type` / `shape` | raw values of the pin type / shape enums |
| `conn` | `[x, y]` connection point |
| `root` | `[x, y]` body-side stub end: `conn + dir(angle) * len` |
| `angle` | pin angle in degrees (as stored) |
| `len` | pin length in mm |
| `nameSize` / `numSize` | pin name / number font sizes in mm |
| `nameAnchor` | `[x, y]` anchor of the pin-name text (see `SymbolDrawList.pinGeom` for the inside/outside layouts), or `null` when the name is not drawn (names hidden / empty plain name) |
| `numAnchor` | `[x, y]` centre of the pin-number text (KiCad absolute-side rule), or `null` when the number is not drawn |
| `nameOutside` | true when pinNameOffset == 0 (name centred over the stub) |
| `glyphs` | the pin name's markup runs, array form (see below) |
| `deco` | pin decoration glyph objects in draw order (see below); not compared by the differ yet — dumped for the record |

### Markup runs

`glyphs` (pins) and `glyphs` (text graphics) are arrays of
`[text, sub, sup, overbar]` — the KiCad markup parse of the raw
string (`KiCadText.runs`).

### Decoration glyphs (`deco`)

Sizes are KiCad's text-size-derived decoration sizes: bubble radius
= pin number size / 2, clock wedge length = pin name size / 2
(half-width name size / 4), no-connect x half-extent = 0.381 mm
(TARGET_PIN_RADIUS, 15 mil).

- `{"kind":"bubble","c":[x,y],"r":…}` — inversion bubble: centre ON
  the stub, one radius from the root toward the connection point
  (tangent at the root).
- `{"kind":"wedge","pts":[[x,y],[x,y],[x,y]]}` — clock wedge, points
  in draw order: base + perp·h, apex (base + dir·length),
  base − perp·h. Drawn as an open polyline, not closed.
- `{"kind":"x","at":[x,y],"d":…}` — a small x centred at `at` with
  half-extent `d` in the pin's dir/perp frame: the drawn segments run
  between `at + dir·a + perp·b` for (a, b) in (−d, −d) → (d, d) and
  (−d, d) → (d, −d). Used for the non_logic glyph (centred at the pin
  root, d = name size / 4) and the no_connect cross (centred at the
  connection point, d = 0.381); a pin can carry both, shape glyph
  first.

### Graphics (`gfx`)

Field names are exactly the ones `tools/truth_diff.py` documents and
compares. Common suffix on every entry: `"strokeW"` (mm),
`"strokeType"` (verbatim token), `"fill"` (verbatim token). Text
graphics have no stroke/fill in the format, so those three keys are
`null` there.

- `rect`: `"x1"`, `"y1"`, `"x2"`, `"y2"` (raw start/end).
- `circle`: `"cx"`, `"cy"`, `"r"`.
- `arc`: `"sx"`, `"sy"`, `"mx"`, `"my"`, `"ex"`, `"ey"` plus `"pts"` —
  the sampled polyline from the circumcenter sweep (first point =
  start, last = end; a collinear arc samples as exactly
  [start, mid, end]).
- `poly`: `"points"` — the polyline points in order.
- `bezier`: `"points"` — the 4 control points in order (start, c1,
  c2, end).
- `text`: `"string"` (raw), `"plain"`, `"glyphs"` (markup runs, array
  form), `"x"`, `"y"`, `"rotation"` (DEGREES — the file stores graphic
  text rotation in decidegrees; the parser divides by 10), `"size"`,
  `"bold"`, `"italic"`, `"hJustify"`, `"vJustify"`.
- `textbox`: `"string"` (raw), `"plain"`, `"glyphs"`, `"x"`, `"y"`,
  `"w"`, `"h"` (signed, as stored), `"rotation"` (degrees — text_box
  angles are plain degrees in the file), `"size"`, `"bold"`,
  `"italic"`, `"hJustify"`, `"vJustify"`, plus the stroke/fill suffix.

## Probes schema (`probes.jsonl`)

Placed pin world points for fixture symbols, computed with the real
`SymbolDrawList.transformPoint` (via `pinWorldPoints`) at origin
(0, 0), for every rotation in {0, 90, 180, 270} × mirrorX × mirrorY:

```json
{"lib":"Device","sym":"R","unit":1,"rot":0,"mx":false,"my":false,
 "pins":[{"num":"1","world":[x,y]}, ...]}
```

All pins are included (hidden ones too), in `pinWorldPoints` order.
Fixtures: `Device:R` (unit 1), `4xxx:4001` (unit 1 and the power
unit — taken as the last unit, the conventional 4xxx layout),
`4xxx:14528` (units 1–3), `Amplifier_Operational:ADA4084-4`
(units 1–5), plus the first symbol in sorted (library, symbol) order
that carries a rotated text or text_box graphic (unit 1; the chosen
fixture is named on stderr). Missing fixtures are logged to stderr
and skipped.
