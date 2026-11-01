#!/usr/bin/env python3
"""PadCB 1.3 — INDEPENDENT KiCad truth model (Lane B).

Computes, from merged per-library .kicad_sym files alone, what KiCad 10.0.1
would render for body style 1 of every (library, symbol, unit): pins with
KiCad geometry (connection point, root, anchors) and graphics with verbatim
file coordinates plus derived arc geometry.

This module was written fresh from the KiCad 10.0.1 source semantics memo
(hidden_files/kicad-semantics-1.3.md).  It deliberately does NOT reuse the
1.2 visibility census's resolve/render logic (that logic is under audit).
Only the general idea of an s-expression tokenizer is shared with the
census, and even that is re-implemented here with KiCad's string-escape
rule (only \\" and \\\\ collapse; every other backslash sequence is kept
verbatim — the census tokenizer collapsed *any* \\x to x).

Key semantics implemented (see memo for file/function citations):
  * Inheritance: a derived (extends) symbol contributes NO drawing of its
    own.  Pins, graphics, unit count and pin-name/number display settings
    all come from the ROOT (non-derived) ancestor.  LIB_SYMBOL::Flatten()
    copies the root and merges only fields/keywords/filters;
    GetGraphicalPins()/GetUnitCount() delegate to the root.
  * Render set for (unit U, style 1): root draw items with
    unit in {0, U} and body style in {0, 1}.  Style 0 = common to all
    styles; unit 0 = common to all units.  Private items are not drawn
    outside the symbol editor.
  * Pin connection point = (at x y) verbatim (file space, y-up).
    Angle in {(at) third value} is one of 0/90/180/270 and names the
    direction FROM the connection point TOWARD the body:
    dir = (cos a, sin a) in file space.  Root (body-side stub end) =
    conn + dir * length.  (KiCad internally negates Y on parse —
    parseXY(true) — and PIN_UP maps to (0,-len) internally, which is
    exactly (0,+len) in file space.)
  * Pin length: (length) value; when absent, the SCH_PIN constructor
    default DEFAULT_PIN_LENGTH = 100 mil = 2.54 mm.  (No pin in the
    10.0.1 corpus omits (length); the rule is implemented anyway.)
  * Pin hidden: a DIRECT child of the pin node that is a bare `hide`
    atom (pre-20241004 form) or a (hide yes) list; (hide no) = visible.
    Nothing else hides a pin — in particular `hide` tokens inside
    (name ...)/(number ...)/(alternate ...) subtrees do not count
    (KiCad's parser only looks at pin-level tokens).
  * Pin name/number text sizes: (effects (font (size h w))) height of
    the (name ...)/(number ...) node; default DEFAULT_PINNAME_SIZE /
    DEFAULT_PINNUM_SIZE = 50 mil = 1.27 mm.
  * Pin number strings have spaces replaced by underscores
    (SCH_PIN::SetNumber).
  * Pin display settings come from the ROOT symbol: pin-name offset
    (pin_names (offset v)), default DEFAULT_PIN_NAME_OFFSET = 20 mil =
    0.508 mm; names/numbers shown unless (hide yes) in (pin_names ...) /
    (pin_numbers ...) of the root.
  * Anchors (the point the harness should report as nameAnchor /
    numAnchor), in file coordinates, following PIN_LAYOUT_CACHE
    (eeschema/pin_layout_cache.cpp), shadow width 0, pen thickness
    neglected (<= ~0.16 mm; the differ classifies anchors with a loose
    tolerance and only treats opposite-side placement as a hard error):
      - name, offset > 0 ("inside"): anchor = root + dir * offset;
        the text starts there and runs along +dir, centred on the pin
        axis.  (GetPinNameInfo, nameInside branch.)
      - name, offset == 0 ("outside"): text centred over the pin:
        horizontal pins: centre = (mid.x, conn.y + clear + maxNameHalf)
        where maxNameHalf = max nameSize/2 over the unit's pins and
        clear = textOffset + margin (see below); vertical pins:
        centre = (conn.x - (clear + nameSize/2), mid.y).
      - number: centred along the pin at its midpoint, offset
        perpendicular by clear + numSize/2: horizontal pins on the
        file +Y side of the pin axis, vertical pins on the file -X
        side — EXCEPT when both name and number are shown with the
        name outside (offset == 0), when the number goes to the
        opposite side (file -Y / file +X respectively).
        clear = MilsToIU(round(24 * 0.15)) + 4 mil = 8 mil = 0.2032 mm
        (getPinTextOffset() with DEFAULT_TEXT_OFFSET_RATIO 0.15, plus
        PIN_TEXT_MARGIN 4 mil).
  * Graphic (text ...) angle is in DECIDEGREES (tenths of a degree):
    parseSymbolText() constructs EDA_ANGLE(..., TENTHS_OF_A_DEGREE_T).
    Corpus proof: values are 0, 900, 2700, 675, ... — 900 means 90 deg.
    (text_box ...) and (property ...) angles are in plain degrees.
  * (text_box ...): end = at + size with SIGNED size (parseSymbolTextBox:
    SetEnd(pos + size)).  Truth emits x, y, w, h verbatim plus
    endX/endY.
  * (arc ...): defined by start/mid/end points on the circle
    (SetArcGeometry).  Truth derives centre (circumcentre), radius and
    start/mid/end angles and the signed sweep through mid.
  * Markup: _{...} subscript, ^{...} superscript, ~{...} overbar,
    nestable, flags combine; {identifier} renders as the bare
    identifier; an opener whose brace never closes degrades to literal
    text (include/markup_parser.h PEG grammar, as rendered).

All coordinates are millimetres in file space (y-up), exactly as stored.
"""

import math
import os
import re
import sys

# ---------------------------------------------------------------------------
# S-expression reader (fresh implementation; KiCad escape rule)
# ---------------------------------------------------------------------------

def tokenize(text):
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c in ' \t\r\n':
            i += 1
        elif c == '(':
            yield ('(', None)
            i += 1
        elif c == ')':
            yield (')', None)
            i += 1
        elif c == '"':
            j = i + 1
            buf = []
            while j < n:
                ch = text[j]
                if ch == '\\' and j + 1 < n:
                    nxt = text[j + 1]
                    if nxt in ('"', '\\'):
                        buf.append(nxt)
                    else:
                        buf.append('\\')
                        buf.append(nxt)
                    j += 2
                elif ch == '"':
                    break
                else:
                    buf.append(ch)
                    j += 1
            yield ('str', ''.join(buf))
            i = j + 1
        else:
            j = i
            while j < n and text[j] not in ' \t\r\n()':
                j += 1
            yield ('atom', text[i:j])
            i = j


def parse(text):
    stack = [[]]
    for kind, val in tokenize(text):
        if kind == '(':
            node = []
            stack[-1].append(node)
            stack.append(node)
        elif kind == ')':
            if len(stack) > 1:
                stack.pop()
        else:
            stack[-1].append(val)
    if not stack[0]:
        return []
    return stack[0][0]


def head(node):
    return node[0] if node and isinstance(node[0], str) else None


def children(node, h):
    return [c for c in node[1:] if isinstance(c, list) and head(c) == h]


def child(node, h):
    for c in node[1:]:
        if isinstance(c, list) and head(c) == h:
            return c
    return None


def fval(node, idx, default=None):
    if node is None or idx >= len(node):
        return default
    try:
        return float(node[idx])
    except (TypeError, ValueError):
        return default


def sval(node, idx, default=None):
    if node is None or idx >= len(node):
        return default
    v = node[idx]
    return v if isinstance(v, str) else default


# ---------------------------------------------------------------------------
# KiCad markup (independent implementation of the PEG grammar's semantics)
# ---------------------------------------------------------------------------

_IDENT_START = re.compile(r'[A-Za-z_]')
_IDENT_CONT = re.compile(r'[A-Za-z0-9_]')


def markup_runs(s):
    """Return list of runs: {"text", "sub", "sup", "overbar"}.

    _{...} / ^{...} / ~{...} set the flag for the braced content and nest;
    {identifier} yields the identifier with no flags changed; an opener
    with no closing brace degrades to literal characters.
    """
    chars = list(s)
    n = len(chars)
    runs = []

    def emit(text, sub, sup, over):
        if not text:
            return
        if runs and runs[-1]['sub'] == sub and runs[-1]['sup'] == sup \
                and runs[-1]['overbar'] == over:
            runs[-1]['text'] += text
        else:
            runs.append({'text': text, 'sub': sub, 'sup': sup, 'overbar': over})

    def scan_escape(pos):
        # chars[pos] == '{'; return (identifier, end_index) or None
        i = pos + 1
        if i >= n or not _IDENT_START.match(chars[i]):
            return None
        start = i
        while i < n and _IDENT_CONT.match(chars[i]):
            i += 1
        if i < n and chars[i] == '}':
            return (''.join(chars[start:i]), i + 1)
        return None

    def parse_seq(pos, sub, sup, over, inside):
        # returns (new_pos, closed)
        while pos < n:
            ch = chars[pos]
            if inside and ch == '}':
                return pos + 1, True
            if ch in '_^~' and pos + 1 < n and chars[pos + 1] == '{':
                saved = pos
                npos, closed = parse_seq(pos + 2,
                                         sub or ch == '_',
                                         sup or ch == '^',
                                         over or ch == '~',
                                         True)
                if closed:
                    pos = npos
                else:
                    emit(ch + '{', sub, sup, over)
                    pos = saved + 2
                continue
            if ch == '{':
                esc = scan_escape(pos)
                if esc is not None:
                    emit(esc[0], sub, sup, over)
                    pos = esc[1]
                else:
                    emit('{', sub, sup, over)
                    pos += 1
                continue
            emit(ch, sub, sup, over)
            pos += 1
        return pos, False

    parse_seq(0, False, False, False, False)
    return runs


def markup_plain(s):
    return ''.join(r['text'] for r in markup_runs(s))


def runs_as_glyphs(runs):
    """Serialise runs the way the harness dump is expected to carry them:
    a list of [text, sub, sup, overbar] quadruples."""
    return [[r['text'], r['sub'], r['sup'], r['overbar']] for r in runs]


# ---------------------------------------------------------------------------
# File-level extraction
# ---------------------------------------------------------------------------

DEFAULT_PIN_LENGTH = 2.54        # DEFAULT_PIN_LENGTH 100 mil
DEFAULT_TEXT_SIZE = 1.27         # DEFAULT_PINNAME_SIZE / _PINNUM_SIZE 50 mil
DEFAULT_PIN_NAME_OFFSET = 0.508  # DEFAULT_PIN_NAME_OFFSET 20 mil
TEXT_CLEARANCE = 0.2032          # (round(24*0.15) + 4) mil = 8 mil

GRAPHIC_HEADS = ('rectangle', 'circle', 'arc', 'polyline', 'bezier',
                 'text', 'text_box')


def _stroke(node):
    st = child(node, 'stroke')
    if st is None:
        return 0.0, 'default'
    w = fval(child(st, 'width'), 1, 0.0)
    t = sval(child(st, 'type'), 1, 'default')
    return w, t


def _fill(node):
    fl = child(node, 'fill')
    if fl is None:
        return 'none'
    ty = child(fl, 'type')
    t = sval(ty, 1, 'none') if ty is not None else 'none'
    if t == 'color':
        col = child(fl, 'color')
        if col is not None:
            r = fval(col, 1, 0.0)
            g = fval(col, 2, 0.0)
            b = fval(col, 3, 0.0)
            a = fval(col, 4, 1.0)
            return f'color={r:g},{g:g},{b:g},{a:g}'
    return t


def _font_of(effects_node):
    """(size, bold, italic, hjustify, vjustify) from an (effects ...) node."""
    size = DEFAULT_TEXT_SIZE
    bold = False
    italic = False
    hj = 'center'
    vj = 'center'
    if effects_node is None:
        return size, bold, italic, hj, vj
    font = child(effects_node, 'font')
    if font is not None:
        sz = child(font, 'size')
        if sz is not None:
            v = fval(sz, 1)
            if v is not None:
                size = v
        for item in font[1:]:
            if isinstance(item, str):
                if item == 'bold':
                    bold = True
                elif item == 'italic':
                    italic = True
            elif isinstance(item, list):
                if head(item) == 'bold':
                    bold = (sval(item, 1, 'yes') != 'no')
                elif head(item) == 'italic':
                    italic = (sval(item, 1, 'yes') != 'no')
    jus = child(effects_node, 'justify')
    if jus is not None:
        for item in jus[1:]:
            if item in ('left', 'right'):
                hj = item
            elif item in ('top', 'bottom'):
                vj = item
            elif item == 'center':
                pass  # centre is the default for both axes
    return size, bold, italic, hj, vj


def _pin_hidden(pin_node):
    """KiCad parser semantics: only pin-level tokens count."""
    for item in pin_node[1:]:
        if isinstance(item, str):
            if item == 'hide':
                return True
        elif isinstance(item, list) and head(item) == 'hide':
            return (sval(item, 1, 'yes') != 'no')
    return False


def _parse_pin(node):
    ptype = sval(node, 1, 'unspecified')
    pshape = sval(node, 2, 'line')
    at = child(node, 'at')
    x = fval(at, 1, 0.0)
    y = fval(at, 2, 0.0)
    angle = fval(at, 3, 0.0)
    ln = child(node, 'length')
    length = fval(ln, 1) if ln is not None else None
    if length is None:
        length = DEFAULT_PIN_LENGTH
    name = ''
    name_size = DEFAULT_TEXT_SIZE
    nm = child(node, 'name')
    if nm is not None:
        name = sval(nm, 1, '')
        eff = child(nm, 'effects')
        if eff is not None:
            name_size = _font_of(eff)[0]
    number = ''
    num_size = DEFAULT_TEXT_SIZE
    nu = child(node, 'number')
    if nu is not None:
        number = sval(nu, 1, '')
        eff = child(nu, 'effects')
        if eff is not None:
            num_size = _font_of(eff)[0]
    # SCH_PIN::SetNumber replaces spaces with underscores.
    number = number.replace(' ', '_')
    alternates = []
    for alt in children(node, 'alternate'):
        alternates.append({
            'name': sval(alt, 1, ''),
            'type': sval(alt, 2, 'unspecified'),
            'shape': sval(alt, 3, 'line'),
        })
    a = int(round(angle)) % 360
    dirs = {0: (1.0, 0.0), 90: (0.0, 1.0), 180: (-1.0, 0.0), 270: (0.0, -1.0)}
    d = dirs.get(a)
    if d is None:
        rad = math.radians(angle)
        d = (math.cos(rad), math.sin(rad))
    dx, dy = d
    root = (x + dx * length, y + dy * length)
    runs = markup_runs(name)
    return {
        'num': number,
        'name': name,
        'plainName': ''.join(r['text'] for r in runs),
        'glyphs': runs_as_glyphs(runs),
        'hidden': _pin_hidden(node),
        'type': ptype,
        'shape': pshape,
        'conn': [x, y],
        'root': [root[0], root[1]],
        'angle': float(a),
        'len': length,
        'nameSize': name_size,
        'numSize': num_size,
        'alternates': alternates,
        # anchors filled in by resolve() (need symbol-level settings)
        'nameAnchor': None,
        'numAnchor': None,
    }


def _arc_derived(s, m, e):
    """Circumcentre/radius/angles for the arc through s, m, e (file space)."""
    (ax, ay), (bx, by), (cx, cy) = s, m, e
    d = 2.0 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by))
    if abs(d) < 1e-12:
        return {'cx': None, 'cy': None, 'r': None,
                'aStart': None, 'aMid': None, 'aEnd': None, 'sweep': None,
                'degenerate': True}
    a2 = ax * ax + ay * ay
    b2 = bx * bx + by * by
    c2 = cx * cx + cy * cy
    ux = (a2 * (by - cy) + b2 * (cy - ay) + c2 * (ay - by)) / d
    uy = (a2 * (cx - bx) + b2 * (ax - cx) + c2 * (bx - ax)) / d
    r = math.hypot(ax - ux, ay - uy)

    def ang(px, py):
        return math.degrees(math.atan2(py - uy, px - ux))

    a0, am, a1 = ang(ax, ay), ang(bx, by), ang(cx, cy)

    def norm(v):
        v = math.fmod(v, 360.0)
        return v + 360.0 if v < 0 else v

    sweep_pos = norm(a1 - a0)
    mid_pos = norm(am - a0)
    sweep = sweep_pos if mid_pos <= sweep_pos + 1e-9 else -(360.0 - sweep_pos)
    return {'cx': ux, 'cy': uy, 'r': r,
            'aStart': a0, 'aMid': am, 'aEnd': a1, 'sweep': sweep,
            'degenerate': False}


def _parse_graphic(node):
    h = head(node)
    # `private` marker: bare atom directly after the head.
    private = len(node) > 1 and node[1] == 'private'
    body = node[2:] if private else node[1:]

    def find(hh):
        for c in body:
            if isinstance(c, list) and head(c) == hh:
                return c
        return None

    def pt(hh):
        p = find(hh)
        if p is None:
            return None
        return (fval(p, 1, 0.0), fval(p, 2, 0.0))

    if h == 'rectangle':
        s, e = pt('start'), pt('end')
        if s is None or e is None:
            return None
        w, t = _stroke(node)
        rad = find('radius')
        return {'kind': 'rect', 'x1': s[0], 'y1': s[1], 'x2': e[0], 'y2': e[1],
                'cornerRadius': fval(rad, 1, 0.0) if rad is not None else 0.0,
                'strokeW': w, 'strokeType': t, 'fill': _fill(node),
                'private': private}
    if h == 'circle':
        c = pt('center')
        r = fval(find('radius'), 1)
        if c is None or r is None:
            return None
        w, t = _stroke(node)
        return {'kind': 'circle', 'cx': c[0], 'cy': c[1], 'r': r,
                'strokeW': w, 'strokeType': t, 'fill': _fill(node),
                'private': private}
    if h == 'arc':
        s, m, e = pt('start'), pt('mid'), pt('end')
        if s is None or m is None or e is None:
            return None
        w, t = _stroke(node)
        out = {'kind': 'arc', 'sx': s[0], 'sy': s[1], 'mx': m[0], 'my': m[1],
               'ex': e[0], 'ey': e[1],
               'strokeW': w, 'strokeType': t, 'fill': _fill(node),
               'private': private}
        out.update(_arc_derived(s, m, e))
        return out
    if h == 'polyline':
        pts_node = find('pts')
        pts = []
        if pts_node is not None:
            for xy in children(pts_node, 'xy'):
                pts.append([fval(xy, 1, 0.0), fval(xy, 2, 0.0)])
        w, t = _stroke(node)
        return {'kind': 'poly', 'points': pts,
                'strokeW': w, 'strokeType': t, 'fill': _fill(node),
                'private': private}
    if h == 'bezier':
        pts_node = find('pts')
        pts = []
        if pts_node is not None:
            for xy in children(pts_node, 'xy'):
                pts.append([fval(xy, 1, 0.0), fval(xy, 2, 0.0)])
        w, t = _stroke(node)
        return {'kind': 'bezier', 'points': pts,
                'strokeW': w, 'strokeType': t, 'fill': _fill(node),
                'private': private}
    if h == 'text':
        string = sval(node, 2 if private else 1, '')
        at = find('at')
        x = fval(at, 1, 0.0)
        y = fval(at, 2, 0.0)
        raw_rot = fval(at, 3, 0.0)
        size, bold, italic, hj, vj = _font_of(find('effects'))
        runs = markup_runs(string)
        return {'kind': 'text', 'string': string,
                'plain': ''.join(r['text'] for r in runs),
                'glyphs': runs_as_glyphs(runs),
                'x': x, 'y': y,
                'rotation': raw_rot / 10.0,  # DECIDEGREES in the file
                'rawRotation': raw_rot,
                'size': size, 'bold': bold, 'italic': italic,
                'hJustify': hj, 'vJustify': vj,
                'strokeW': 0.0, 'strokeType': 'default', 'fill': 'none',
                'private': private}
    if h == 'text_box':
        string = sval(node, 2 if private else 1, '')
        at = find('at')
        x = fval(at, 1, 0.0)
        y = fval(at, 2, 0.0)
        rot = fval(at, 3, 0.0)  # degrees (NOT decidegrees) for text_box
        sz = find('size')
        w = fval(sz, 1, 0.0)
        hh = fval(sz, 2, 0.0)
        size, bold, italic, hj, vj = _font_of(find('effects'))
        mg = find('margins')
        margins = None
        if mg is not None:
            margins = [fval(mg, 1, 0.0), fval(mg, 2, 0.0),
                       fval(mg, 3, 0.0), fval(mg, 4, 0.0)]
        sw, st = _stroke(node)
        runs = markup_runs(string)
        return {'kind': 'textbox', 'string': string,
                'plain': ''.join(r['text'] for r in runs),
                'glyphs': runs_as_glyphs(runs),
                'x': x, 'y': y, 'w': w, 'h': hh,
                'endX': x + w, 'endY': y + hh,
                'rotation': rot, 'size': size, 'bold': bold, 'italic': italic,
                'hJustify': hj, 'vJustify': vj, 'margins': margins,
                'strokeW': sw, 'strokeType': st, 'fill': _fill(node),
                'private': private}
    return None


def _unit_style(sub_name, parent_name):
    """KiCad parser rule: strip '<parentName>_' prefix, then exactly two
    '_' separated integers must remain (unit, body style)."""
    prefix = parent_name + '_'
    if not sub_name.startswith(prefix):
        return None
    rest = sub_name[len(prefix):]
    parts = rest.split('_')
    if len(parts) != 2:
        return None
    try:
        return int(parts[0]), int(parts[1])
    except ValueError:
        return None


class RawSymbol:
    __slots__ = ('name', 'extends', 'pin_offset', 'pin_offset_present',
                 'names_hidden', 'numbers_hidden', 'subs', 'top_items')

    def __init__(self, name):
        self.name = name
        self.extends = None
        self.pin_offset = None
        self.pin_offset_present = False
        self.names_hidden = None     # None = node absent
        self.numbers_hidden = None
        self.subs = {}               # (unit, style) -> [parsed items]
        self.top_items = []          # draw items directly under (symbol ...)


def _hide_value(node):
    """(hide yes/no) or bare `hide` atom inside a (pin_names ...)-style node."""
    hidden = False
    for item in node[1:]:
        if isinstance(item, str) and item == 'hide':
            hidden = True
        elif isinstance(item, list) and head(item) == 'hide':
            hidden = (sval(item, 1, 'yes') != 'no')
    return hidden


def parse_raw_symbol(sym_node):
    name = sval(sym_node, 1)
    if name is None:
        return None
    # KiCad unescapes {slash} in symbol names.
    name = name.replace('{slash}', '/')
    raw = RawSymbol(name)
    for item in sym_node[1:]:
        if not isinstance(item, list):
            continue
        h = head(item)
        if h == 'extends':
            v = sval(item, 1)
            raw.extends = v.replace('{slash}', '/') if v else None
        elif h == 'pin_names':
            raw.pin_offset_present = True
            off = child(item, 'offset')
            if off is not None:
                raw.pin_offset = fval(off, 1)
            raw.names_hidden = _hide_value(item)
        elif h == 'pin_numbers':
            raw.numbers_hidden = _hide_value(item)
        elif h == 'symbol':
            sub_name = sval(item, 1, '')
            us = _unit_style(sub_name.replace('{slash}', '/'), name)
            if us is None:
                continue
            entry = raw.subs.setdefault(us, [])
            for el in item[1:]:
                if not isinstance(el, list):
                    continue
                eh = head(el)
                if eh == 'pin':
                    entry.append(('pin', _parse_pin(el)))
                elif eh in GRAPHIC_HEADS:
                    g = _parse_graphic(el)
                    if g is not None:
                        entry.append(('gfx', g))
        elif h == 'pin':
            p = _parse_pin(item)
            raw.top_items.append(('pin', p))
        elif h in GRAPHIC_HEADS:
            g = _parse_graphic(item)
            if g is not None:
                raw.top_items.append(('gfx', g))
    return raw


# ---------------------------------------------------------------------------
# Resolution — KiCad root-symbol semantics
# ---------------------------------------------------------------------------

def root_of(raws, name):
    """Follow extends to the non-derived ancestor (cycle-safe).
    Returns (root_raw, chain) or (None, chain) if a link is missing."""
    chain = []
    seen = set()
    cur = name
    while True:
        if cur in seen or cur not in raws:
            return None, chain
        seen.add(cur)
        chain.append(cur)
        raw = raws[cur]
        if not raw.extends:
            return raw, chain
        cur = raw.extends


def resolve_library(lib_name, raws):
    """Yield (sym_name, unit, pins, gfx, meta) per placeable symbol/unit."""
    out = []
    for name in raws:
        root, _chain = root_of(raws, name)
        if root is None:
            continue
        # Pin display settings: ROOT symbol only (Flatten copies root).
        offset = root.pin_offset if root.pin_offset is not None \
            else DEFAULT_PIN_NAME_OFFSET
        show_names = not (root.names_hidden or False)
        show_numbers = not (root.numbers_hidden or False)
        # Merge root sub-symbols; top-level items belong to (1, 1).
        subs = dict(root.subs)
        if root.top_items:
            subs.setdefault((1, 1), [])
            subs[(1, 1)] = list(root.top_items) + list(subs[(1, 1)])
        unit_keys = sorted({u for (u, s) in subs if u > 0}) or [1]
        unit_count = max(unit_keys)
        for unit in unit_keys:
            pins, gfx = [], []
            for key in ((0, 0), (0, 1), (unit, 0), (unit, 1)):
                for kind, obj in subs.get(key, []):
                    if kind == 'pin':
                        pins.append(obj)
                    else:
                        if not obj.get('private'):
                            gfx.append(obj)
            # Anchors need unit-level context (max name half-height).
            max_name_half = 0.0
            for p in pins:
                if p['name']:
                    max_name_half = max(max_name_half, p['nameSize'] / 2.0)
            for p in pins:
                _fill_anchors(p, offset, show_names, show_numbers,
                              max_name_half)
            meta = {'unitCount': unit_count, 'pinNameOffset': offset,
                    'showNames': show_names, 'showNumbers': show_numbers,
                    'root': root.name}
            out.append((name, unit,
                        [dict(p) for p in pins],
                        [dict(g) for g in gfx], meta))
    return out


def _fill_anchors(p, offset, show_names, show_numbers, max_name_half):
    conn = p['conn']
    root = p['root']
    a = int(round(p['angle'])) % 360
    dirs = {0: (1.0, 0.0), 90: (0.0, 1.0), 180: (-1.0, 0.0), 270: (0.0, -1.0)}
    dx, dy = dirs.get(a, (math.cos(math.radians(a)), math.sin(math.radians(a))))
    mid = ((conn[0] + root[0]) / 2.0, (conn[1] + root[1]) / 2.0)
    horizontal = a in (0, 180)
    # --- name anchor ---
    if show_names and p['plainName']:
        if offset > 0:
            p['nameAnchor'] = [root[0] + dx * offset, root[1] + dy * offset]
        else:
            if horizontal:
                p['nameAnchor'] = [mid[0],
                                   conn[1] + TEXT_CLEARANCE + max_name_half]
            else:
                p['nameAnchor'] = [conn[0] - (TEXT_CLEARANCE + p['nameSize'] / 2.0),
                                   mid[1]]
    else:
        p['nameAnchor'] = None
    # --- number anchor ---
    if show_numbers and p['num']:
        both_outside = (offset == 0 and show_names and bool(p['plainName']))
        off = TEXT_CLEARANCE + p['numSize'] / 2.0
        if horizontal:
            y = conn[1] - off if both_outside else conn[1] + off
            p['numAnchor'] = [mid[0], y]
        else:
            x = conn[0] + off if both_outside else conn[0] - off
            p['numAnchor'] = [x, mid[1]]
    else:
        p['numAnchor'] = None


# ---------------------------------------------------------------------------
# Corpus loading
# ---------------------------------------------------------------------------

def load_library(path):
    lib_name = os.path.basename(path)
    if lib_name.endswith('.kicad_sym'):
        lib_name = lib_name[:-len('.kicad_sym')]
    with open(path, encoding='utf-8', errors='replace') as f:
        doc = parse(f.read())
    raws = {}
    total_pins = 0
    if head(doc) != 'kicad_symbol_lib':
        return lib_name, raws, 0
    for sym_node in children(doc, 'symbol'):
        raw = parse_raw_symbol(sym_node)
        if raw is None:
            continue
        raws[raw.name] = raw
        for items in raw.subs.values():
            total_pins += sum(1 for k, _ in items if k == 'pin')
        total_pins += sum(1 for k, _ in raw.top_items if k == 'pin')
    return lib_name, raws, total_pins


def load_corpus(corpus_dir):
    """Return (libs, stats): libs = {lib: (raws, resolved_list)}."""
    import glob as _glob
    libs = {}
    stats = {'symbols': 0, 'pins': 0, 'libraries': 0}
    for path in sorted(_glob.glob(os.path.join(corpus_dir, '*.kicad_sym'))):
        lib_name, raws, npins = load_library(path)
        libs[lib_name] = (raws, resolve_library(lib_name, raws))
        stats['libraries'] += 1
        stats['symbols'] += len(raws)
        stats['pins'] += npins
    return libs, stats


if __name__ == '__main__':
    # Standalone self-check: python3 truth_model.py --corpus DIR
    import argparse
    ap = argparse.ArgumentParser(description='Truth model standalone check')
    ap.add_argument('--corpus', required=True)
    ap.add_argument('--spot', default='4xxx:14528')
    args = ap.parse_args()
    libs, stats = load_corpus(args.corpus)
    print(f"libraries={stats['libraries']} symbols={stats['symbols']} "
          f"pins={stats['pins']}")
    lib, sym = args.spot.split(':')
    if lib in libs:
        for (name, unit, pins, gfx, meta) in libs[lib][1]:
            if name == sym:
                print(f"{lib}:{sym} unit {unit}: pins={len(pins)} "
                      f"gfx={len(gfx)} root={meta['root']} "
                      f"unitCount={meta['unitCount']}")
