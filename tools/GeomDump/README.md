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
| `nameAnchor` | `[x, y]` = `root + dir * pinNameOffset` (the def's offset) |
| `numAnchor` | `[x, y]` = stub midpoint + perp * (`numSize` * 0.8 + 0.1), perp = (−dirY, dirX) |
| `glyphs` | glyph objects in draw order (see below) |

### Glyphs

- `{"kind":"bubble","c":[x,y],"r":0.3}` — inversion bubble (centre,
  radius in mm).
- `{"kind":"wedge","pts":[[x,y],[x,y],[x,y]]}` — clock wedge, points
  in draw order: base + perp·0.3, apex (base + dir·0.6), base − perp·0.3.
  Drawn as an open polyline, not closed.
- `{"kind":"x","at":[x,y],"d":0.3}` — a small x centred at `at` with
  half-extent `d` in the pin's dir/perp frame: the drawn segments run
  between `at + dir·a + perp·b` for (a, b) in (−d, −d) → (d, d) and
  (−d, d) → (d, −d). Used for the non_logic glyph (centred at the pin
  root) and the no_connect cross (centred at the connection point);
  a pin can carry both, shape glyph first.

### Graphics (`gfx`)

Common suffix on every entry: `"strokeW"` (mm), `"strokeType"`
(verbatim token), `"fill"` (verbatim token). Text graphics have no
stroke/fill in the format, so those three keys are `null` there.

- `rect`: `"corners"` — 4 `[x, y]` points in the renderer's trace
  order (x1,y1) → (x2,y1) → (x2,y2) → (x1,y2).
- `circle`: `"c"` centre, `"r"` radius.
- `arc`: `"start"`, `"mid"`, `"end"` plus `"pts"` — the sampled
  polyline from the circumcenter sweep (first point = start, last =
  end; a collinear arc samples as exactly [start, mid, end]).
- `poly`: `"pts"` — the polyline points in order.
- `bezier`: `"pts"` — the 4 control points in order (start, c1, c2, end).
- `text`: `"text"` (raw), `"plain"`, `"runs"` (see below), `"at"`,
  `"rot"` (degrees), `"size"`, `"bold"`, `"italic"`, `"hJustify"`,
  `"vJustify"`.
- `textbox`: `"text"` (raw), `"plain"`, `"runs"`, `"at"`, `"w"`, `"h"`
  (signed, as stored), `"rot"`, `"size"`, `"bold"`, `"italic"`,
  `"hJustify"`, `"vJustify"`, plus the stroke/fill suffix.

`runs` entries are `{"text": "...", "sub": bool, "sup": bool,
"overbar": bool}` — the KiCad markup parse of the raw string.

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
