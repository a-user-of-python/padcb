#!/usr/bin/env python3
"""PadCB 1.3 — truth differ (Lane B).

Compares a Swift harness dump against the INDEPENDENT truth model
(tools/truth_model.py, written from KiCad 10.0.1 source semantics; see
hidden_files/kicad-semantics-1.3.md).

Usage:
    python3 tools/truth_diff.py --corpus DIR --dump dump.jsonl \
        --probes probes.jsonl --out report.json --summary report.txt
    python3 tools/truth_diff.py --corpus DIR --out report.json \
        --summary report.txt        # truth-only stats mode

Dump schema (fixed; the harness lane codes against it):
  dump lines: {"lib","sym","unit",
    "pins":[{"num","name","plainName","hidden","type","shape","conn",
             "root","angle","len","nameSize","numSize","nameAnchor",
             "numAnchor","glyphs"}],
    "gfx":[{"kind":"rect|circle|arc|poly|bezier|text|textbox", ...}]}
  Gfx coordinate field names expected by this differ:
    rect:    x1,y1,x2,y2
    circle:  cx,cy,r
    arc:     sx,sy,mx,my,ex,ey  (cx,cy,r compared too when present)
    poly:    points [[x,y],...]
    bezier:  points [[x,y],...]  (exactly the 4 control points)
    text:    string,x,y,rotation,size (rotation in DEGREES)
    textbox: string,x,y,w,h,rotation,size
    all gfx: strokeW, strokeType, fill
  Pin "glyphs" / gfx text "glyphs": [[text, sub, sup, overbar], ...].
  Anchors: [x, y] or null.  conn/root: [x, y].  All mm, file space (y-up).

  probe lines: {"lib","sym","unit","rot","mx","my",
                "pins":[{"num","world"}]}
  "world" is the pin connection point after the placement transform
  with the symbol origin at (0,0): world = R(rot deg CCW) applied to
  (mx ? -x : x, my ? -y : y) of the local connection point.  An optional
  "x"/"y" origin on the probe line is honoured when present.

Comparison rules:
  * File-derived coordinates: tolerance 1e-6 mm.
  * Anchors: tolerance 0.6 mm (placement-convention); an anchor on the
    opposite side of the pin from truth is always anchor_off.
  * Only (lib, sym, unit) entries present in the dump are compared for
    missing pins/graphics (a partial dump is a spot check, not a claim
    of absence).  Dump entries with no truth counterpart count every
    pin/graphic as extra.
  * Classes: pin_missing, pin_extra, pin_conn_off, pin_root_off,
    pin_hidden_diff, gfx_missing, gfx_extra, gfx_coord_off, arc_off,
    text_diff, anchor_off, probe_off.  Field mapping for pin scalar
    fields not named by a class: angle/length -> pin_root_off (they
    move the root); type/shape -> pin_conn_off; name/plainName/glyphs/
    nameSize/numSize and all text content -> text_diff.
  * Exit code is always 0 (report mode).
"""

import argparse
import json
import math
import os
import sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import truth_model  # noqa: E402

COORD_TOL = 1e-6
ANCHOR_TOL = 0.6
CLASSES = ['pin_missing', 'pin_extra', 'pin_conn_off', 'pin_root_off',
           'pin_hidden_diff', 'gfx_missing', 'gfx_extra', 'gfx_coord_off',
           'arc_off', 'text_diff', 'anchor_off', 'probe_off']
MAX_EXAMPLES = 25


def _dist(a, b):
    return math.hypot(a[0] - b[0], a[1] - b[1])


def _pt(v):
    if v is None:
        return None
    return [float(v[0]), float(v[1])]


class Reporter:
    def __init__(self):
        self.counts = defaultdict(int)            # class -> n
        self.per_lib = defaultdict(lambda: defaultdict(int))
        self.examples = defaultdict(list)

    def add(self, cls, lib, sym, unit, detail):
        self.counts[cls] += 1
        self.per_lib[lib][cls] += 1
        if len(self.examples[cls]) < MAX_EXAMPLES:
            self.examples[cls].append(
                {'lib': lib, 'sym': sym, 'unit': unit, **detail})


# ---------------------------------------------------------------------------
# Pin comparison
# ---------------------------------------------------------------------------

def _anchor_check(rep, lib, sym, unit, pin_ref, truth_anchor, dump_anchor,
                  which, conn, root):
    if truth_anchor is None and dump_anchor is None:
        return
    if truth_anchor is None or dump_anchor is None:
        rep.add('anchor_off', lib, sym, unit,
                {'pin': pin_ref, 'anchor': which,
                 'truth': truth_anchor, 'dump': _pt(dump_anchor)})
        return
    da = _pt(dump_anchor)
    # Opposite-side test: vectors from the connection point must not
    # point against each other.
    vt = (truth_anchor[0] - conn[0], truth_anchor[1] - conn[1])
    vd = (da[0] - conn[0], da[1] - conn[1])
    dot = vt[0] * vd[0] + vt[1] * vd[1]
    if math.hypot(*vt) > 1e-9 and dot < 0:
        rep.add('anchor_off', lib, sym, unit,
                {'pin': pin_ref, 'anchor': which, 'reason': 'opposite-side',
                 'truth': truth_anchor, 'dump': da})
        return
    if _dist(truth_anchor, da) > ANCHOR_TOL:
        rep.add('anchor_off', lib, sym, unit,
                {'pin': pin_ref, 'anchor': which,
                 'truth': truth_anchor, 'dump': da,
                 'dist': _dist(truth_anchor, da)})


def compare_pins(rep, lib, sym, unit, truth_pins, dump_pins):
    # Greedy match: same number, nearest connection point first.
    unmatched_dump = list(range(len(dump_pins)))
    pairs = []
    for ti, tp in enumerate(truth_pins):
        best, best_d = None, None
        for di in unmatched_dump:
            dp = dump_pins[di]
            if dp.get('num') != tp['num']:
                continue
            dc = dp.get('conn') or [0, 0]
            d = _dist(tp['conn'], dc)
            if best_d is None or d < best_d:
                best, best_d = di, d
        if best is None:
            rep.add('pin_missing', lib, sym, unit,
                    {'pin': tp['num'], 'truth_conn': tp['conn']})
        else:
            unmatched_dump.remove(best)
            pairs.append((tp, dump_pins[best]))
    for di in unmatched_dump:
        dp = dump_pins[di]
        rep.add('pin_extra', lib, sym, unit,
                {'pin': dp.get('num'), 'dump_conn': dp.get('conn')})

    for tp, dp in pairs:
        ref = tp['num']
        dc = _pt(dp.get('conn'))
        if dc is None or _dist(tp['conn'], dc) > COORD_TOL:
            rep.add('pin_conn_off', lib, sym, unit,
                    {'pin': ref, 'truth': tp['conn'], 'dump': dc})
        dr = _pt(dp.get('root'))
        if dr is None or _dist(tp['root'], dr) > COORD_TOL:
            rep.add('pin_root_off', lib, sym, unit,
                    {'pin': ref, 'truth': tp['root'], 'dump': dr})
        if bool(dp.get('hidden')) != bool(tp['hidden']):
            rep.add('pin_hidden_diff', lib, sym, unit,
                    {'pin': ref, 'truth': tp['hidden'],
                     'dump': dp.get('hidden')})
        if abs(float(dp.get('len', -1)) - tp['len']) > COORD_TOL:
            rep.add('pin_root_off', lib, sym, unit,
                    {'pin': ref, 'field': 'len', 'truth': tp['len'],
                     'dump': dp.get('len')})
        if abs(float(dp.get('angle', -999)) - tp['angle']) > 1e-9:
            rep.add('pin_root_off', lib, sym, unit,
                    {'pin': ref, 'field': 'angle', 'truth': tp['angle'],
                     'dump': dp.get('angle')})
        if dp.get('type') != tp['type'] or dp.get('shape') != tp['shape']:
            rep.add('pin_conn_off', lib, sym, unit,
                    {'pin': ref, 'field': 'type/shape',
                     'truth': [tp['type'], tp['shape']],
                     'dump': [dp.get('type'), dp.get('shape')]})
        if dp.get('name') != tp['name'] or dp.get('plainName') != tp['plainName'] \
                or dp.get('glyphs') != tp['glyphs']:
            rep.add('text_diff', lib, sym, unit,
                    {'pin': ref, 'field': 'pin name',
                     'truth': [tp['name'], tp['plainName'], tp['glyphs']],
                     'dump': [dp.get('name'), dp.get('plainName'),
                              dp.get('glyphs')]})
        if abs(float(dp.get('nameSize', -1)) - tp['nameSize']) > COORD_TOL \
                or abs(float(dp.get('numSize', -1)) - tp['numSize']) > COORD_TOL:
            rep.add('text_diff', lib, sym, unit,
                    {'pin': ref, 'field': 'pin text size',
                     'truth': [tp['nameSize'], tp['numSize']],
                     'dump': [dp.get('nameSize'), dp.get('numSize')]})
        _anchor_check(rep, lib, sym, unit, ref, tp['nameAnchor'],
                      dp.get('nameAnchor'), 'name', tp['conn'], tp['root'])
        _anchor_check(rep, lib, sym, unit, ref, tp['numAnchor'],
                      dp.get('numAnchor'), 'number', tp['conn'], tp['root'])


# ---------------------------------------------------------------------------
# Graphics comparison
# ---------------------------------------------------------------------------

def _gfx_ref_pt(g):
    k = g['kind']
    if k == 'rect':
        return [g['x1'], g['y1']]
    if k == 'circle':
        return [g['cx'], g['cy']]
    if k == 'arc':
        return [g['sx'], g['sy']]
    if k in ('poly', 'bezier'):
        return g['points'][0] if g['points'] else [0, 0]
    return [g.get('x', 0), g.get('y', 0)]


def _dump_gfx_ref_pt(g):
    k = g.get('kind')
    try:
        if k == 'rect':
            return [float(g['x1']), float(g['y1'])]
        if k == 'circle':
            return [float(g['cx']), float(g['cy'])]
        if k == 'arc':
            return [float(g['sx']), float(g['sy'])]
        if k in ('poly', 'bezier'):
            pts = g.get('points') or [[0, 0]]
            return [float(pts[0][0]), float(pts[0][1])]
        return [float(g.get('x', 0)), float(g.get('y', 0))]
    except (KeyError, TypeError, ValueError, IndexError):
        return [0, 0]


def _num_eq(a, b):
    try:
        return abs(float(a) - float(b)) <= COORD_TOL
    except (TypeError, ValueError):
        return False


def compare_gfx(rep, lib, sym, unit, truth_gfx, dump_gfx):
    unmatched = list(range(len(dump_gfx)))
    pairs = []
    for tg in truth_gfx:
        best, best_d = None, None
        for di in unmatched:
            dg = dump_gfx[di]
            if dg.get('kind') != tg['kind']:
                continue
            d = _dist(_gfx_ref_pt(tg), _dump_gfx_ref_pt(dg))
            if best_d is None or d < best_d:
                best, best_d = di, d
        if best is None:
            rep.add('gfx_missing', lib, sym, unit,
                    {'kind': tg['kind'], 'truth': _gfx_ref_pt(tg)})
        else:
            unmatched.remove(best)
            pairs.append((tg, dump_gfx[best]))
    for di in unmatched:
        dg = dump_gfx[di]
        rep.add('gfx_extra', lib, sym, unit,
                {'kind': dg.get('kind'), 'dump': _dump_gfx_ref_pt(dg)})

    for tg, dg in pairs:
        k = tg['kind']
        ref = _gfx_ref_pt(tg)
        # stroke / fill (all kinds)
        if not _num_eq(dg.get('strokeW'), tg['strokeW']) \
                or dg.get('strokeType') != tg['strokeType'] \
                or dg.get('fill') != tg['fill']:
            if k in ('text',) and dg.get('strokeW') is None:
                pass  # text carries no stroke in the schema
            else:
                rep.add('gfx_coord_off', lib, sym, unit,
                        {'kind': k, 'at': ref, 'field': 'stroke/fill',
                         'truth': [tg['strokeW'], tg['strokeType'], tg['fill']],
                         'dump': [dg.get('strokeW'), dg.get('strokeType'),
                                  dg.get('fill')]})
        if k == 'rect':
            if not all(_num_eq(dg.get(f), tg[f])
                       for f in ('x1', 'y1', 'x2', 'y2')):
                rep.add('gfx_coord_off', lib, sym, unit,
                        {'kind': k, 'at': ref, 'field': 'corners',
                         'truth': [tg['x1'], tg['y1'], tg['x2'], tg['y2']],
                         'dump': [dg.get('x1'), dg.get('y1'),
                                  dg.get('x2'), dg.get('y2')]})
        elif k == 'circle':
            if not all(_num_eq(dg.get(f), tg[f]) for f in ('cx', 'cy', 'r')):
                rep.add('gfx_coord_off', lib, sym, unit,
                        {'kind': k, 'at': ref, 'field': 'centre/radius',
                         'truth': [tg['cx'], tg['cy'], tg['r']],
                         'dump': [dg.get('cx'), dg.get('cy'), dg.get('r')]})
        elif k == 'arc':
            if not all(_num_eq(dg.get(f), tg[f])
                       for f in ('sx', 'sy', 'mx', 'my', 'ex', 'ey')):
                rep.add('arc_off', lib, sym, unit,
                        {'kind': k, 'at': ref, 'field': 'points',
                         'truth': [tg['sx'], tg['sy'], tg['mx'], tg['my'],
                                   tg['ex'], tg['ey']],
                         'dump': [dg.get('sx'), dg.get('sy'), dg.get('mx'),
                                  dg.get('my'), dg.get('ex'), dg.get('ey')]})
            elif tg.get('cx') is not None and dg.get('cx') is not None:
                if not (_num_eq(dg.get('cx'), tg['cx'])
                        and _num_eq(dg.get('cy'), tg['cy'])
                        and _num_eq(dg.get('r'), tg['r'])):
                    rep.add('arc_off', lib, sym, unit,
                            {'kind': k, 'at': ref, 'field': 'centre/radius',
                             'truth': [tg['cx'], tg['cy'], tg['r']],
                             'dump': [dg.get('cx'), dg.get('cy'),
                                      dg.get('r')]})
        elif k in ('poly', 'bezier'):
            tpts = tg['points']
            dpts = dg.get('points') or []
            bad = len(dpts) != len(tpts) or any(
                len(dp) < 2 or not _num_eq(dp[0], tp[0])
                or not _num_eq(dp[1], tp[1])
                for tp, dp in zip(tpts, dpts))
            if bad:
                rep.add('gfx_coord_off', lib, sym, unit,
                        {'kind': k, 'at': ref, 'field': 'points',
                         'truth': tpts, 'dump': dpts})
        elif k in ('text', 'textbox'):
            if dg.get('string') != tg['string'] \
                    or (dg.get('plain') is not None
                        and dg.get('plain') != tg['plain']) \
                    or (dg.get('glyphs') is not None
                        and dg.get('glyphs') != tg['glyphs']) \
                    or not _num_eq(dg.get('rotation'), tg['rotation']) \
                    or not _num_eq(dg.get('size'), tg['size']):
                rep.add('text_diff', lib, sym, unit,
                        {'kind': k, 'at': ref, 'field': 'text content/rotation/size',
                         'truth': [tg['string'], tg['rotation'], tg['size']],
                         'dump': [dg.get('string'), dg.get('rotation'),
                                  dg.get('size')]})
            if not _num_eq(dg.get('x'), tg['x']) \
                    or not _num_eq(dg.get('y'), tg['y']):
                rep.add('gfx_coord_off', lib, sym, unit,
                        {'kind': k, 'at': ref, 'field': 'position',
                         'truth': [tg['x'], tg['y']],
                         'dump': [dg.get('x'), dg.get('y')]})
            if k == 'textbox':
                if not _num_eq(dg.get('w'), tg['w']) \
                        or not _num_eq(dg.get('h'), tg['h']):
                    rep.add('gfx_coord_off', lib, sym, unit,
                            {'kind': k, 'at': ref, 'field': 'size (signed)',
                             'truth': [tg['w'], tg['h']],
                             'dump': [dg.get('w'), dg.get('h')]})


# ---------------------------------------------------------------------------
# Probes (placement transforms)
# ---------------------------------------------------------------------------

def compare_probes(rep, truth_index, probe_lines):
    for line in probe_lines:
        lib, sym, unit = line['lib'], line['sym'], line['unit']
        entry = truth_index.get((lib, sym, unit))
        if entry is None:
            rep.add('probe_off', lib, sym, unit,
                    {'reason': 'no truth entry for probe'})
            continue
        truth_pins, _gfx, _meta = entry
        rot = math.radians(float(line.get('rot', 0)))
        mx = -1.0 if line.get('mx') else 1.0
        my = -1.0 if line.get('my') else 1.0
        ox = float(line.get('x', 0.0))
        oy = float(line.get('y', 0.0))
        c, s = math.cos(rot), math.sin(rot)
        expected = {}
        for tp in truth_pins:
            lx, ly = tp['conn'][0] * mx, tp['conn'][1] * my
            wx = ox + lx * c - ly * s
            wy = oy + lx * s + ly * c
            expected.setdefault(tp['num'], []).append([wx, wy])
        for pp in line.get('pins', []):
            num = pp.get('num')
            world = _pt(pp.get('world'))
            cands = expected.get(num)
            if not cands:
                rep.add('probe_off', lib, sym, unit,
                        {'pin': num, 'reason': 'probe pin not in truth',
                         'dump': world})
                continue
            if world is None or min(_dist(world, e) for e in cands) > COORD_TOL:
                rep.add('probe_off', lib, sym, unit,
                        {'pin': num, 'truth': cands[0], 'dump': world,
                         'rot': line.get('rot'), 'mx': line.get('mx'),
                         'my': line.get('my')})


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description='PadCB truth differ')
    ap.add_argument('--corpus', required=True,
                    help='dir of merged per-library .kicad_sym files')
    ap.add_argument('--dump', default=None, help='harness dump .jsonl')
    ap.add_argument('--probes', default=None, help='harness probes .jsonl')
    ap.add_argument('--out', default=None, help='JSON report path')
    ap.add_argument('--summary', default=None, help='text summary path')
    args = ap.parse_args()

    libs, stats = truth_model.load_corpus(args.corpus)
    truth_index = {}
    for lib_name, (_raws, resolved) in libs.items():
        for (name, unit, pins, gfx, meta) in resolved:
            truth_index[(lib_name, name, unit)] = (pins, gfx, meta)

    rep = Reporter()
    covered = 0
    if args.dump:
        with open(args.dump, encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                d = json.loads(line)
                key = (d['lib'], d['sym'], d['unit'])
                entry = truth_index.get(key)
                if entry is None:
                    for p in d.get('pins', []):
                        rep.add('pin_extra', d['lib'], d['sym'], d['unit'],
                                {'pin': p.get('num'),
                                 'reason': 'no truth symbol/unit'})
                    for g in d.get('gfx', []):
                        rep.add('gfx_extra', d['lib'], d['sym'], d['unit'],
                                {'kind': g.get('kind'),
                                 'reason': 'no truth symbol/unit'})
                    continue
                covered += 1
                tpins, tgfx, _meta = entry
                compare_pins(rep, d['lib'], d['sym'], d['unit'],
                             tpins, d.get('pins', []))
                compare_gfx(rep, d['lib'], d['sym'], d['unit'],
                            tgfx, d.get('gfx', []))
    if args.probes:
        probe_lines = []
        with open(args.probes, encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if line:
                    probe_lines.append(json.loads(line))
        compare_probes(rep, truth_index, probe_lines)

    report = {
        'corpus': {'libraries': stats['libraries'],
                   'symbols': stats['symbols'],
                   'pin_nodes_in_files': stats['pins']},
        'truth_units': len(truth_index),
        'dump_units_compared': covered,
        'counts': {c: rep.counts.get(c, 0) for c in CLASSES},
        'per_library': {lib: dict(cnt)
                        for lib, cnt in sorted(rep.per_lib.items())},
        'examples': {c: rep.examples.get(c, []) for c in CLASSES},
    }
    if args.out:
        with open(args.out, 'w', encoding='utf-8') as f:
            json.dump(report, f, indent=1)
    lines = []
    lines.append('PadCB 1.3 truth diff')
    lines.append(f"corpus: {stats['libraries']} libraries, "
                 f"{stats['symbols']} symbols, "
                 f"{stats['pins']} pin nodes in files")
    lines.append(f"truth units: {len(truth_index)}; "
                 f"dump units compared: {covered}")
    total = sum(rep.counts.values())
    lines.append(f"total mismatches: {total}")
    for c in CLASSES:
        lines.append(f"  {c}: {rep.counts.get(c, 0)}")
    for c in CLASSES:
        if not rep.counts.get(c):
            continue
        per = sorted(((lib, cnt[c]) for lib, cnt in rep.per_lib.items()
                      if cnt.get(c)), key=lambda kv: -kv[1])[:5]
        lines.append(f"top libraries for {c}: "
                     + ', '.join(f"{lib}={n}" for lib, n in per))
    summary = '\n'.join(lines) + '\n'
    if args.summary:
        with open(args.summary, 'w', encoding='utf-8') as f:
            f.write(summary)
    print(summary, end='')
    return 0


if __name__ == '__main__':
    sys.exit(main())
