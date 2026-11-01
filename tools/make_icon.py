#!/usr/bin/env python3
"""PadCB app-icon generator (v4.0.1 arrow fix).

The v4.0 icon — one closed-loop LED circuit (battery left, resistor
zigzag top, LED right, cyan traces, solder dots, no text) — was drawn
programmatically with PIL at 4x supersampling and committed as the
single universal 1024 master in App/Assets.xcassets/AppIcon.appiconset
(actool derives the 60/76pt payloads from it at build time).

Sean's v4.0.1 note (2026-11-01): the LED's two light-emission arrows
pointed up-right and their heads were chunky bars that read as
rectangles. This script is the delta on top of the committed master:

  1. Erase the existing emission arrows — identified as the amber
     components right of the LED (bbox x_min >= 855); the LED triangle
     and cathode bar are protected and never touched.
  2. Draw two NEW arrows in the same amber, flipped to point
     DOWN-right at 45 degrees, as a thin shaft with a clearly
     triangular pointed head, offset along the LED's right side
     exactly where the old pair sat (mirrored vertically).
  3. Everything else stays pixel-identical to the v4.0 master.

The script is re-runnable: it removes whatever emission-arrow
components it finds in the arrow zone before drawing the new pair.

Usage: python3 tools/make_icon.py [path-to-icon-1024.png]
"""
import math
import sys

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage

ICON = sys.argv[1] if len(sys.argv) > 1 else (
    "App/Assets.xcassets/AppIcon.appiconset/icon-1024.png")

BG = (27, 30, 36)          # charcoal background
AMBER = (255, 190, 64)     # LED + emission arrows
SS = 4                     # supersampling, same as the v4.0 draw

# --- emission-arrow geometry (1024-master coordinates) -----------------
# Direction: 45 degrees down-right. The two arrows are parallel,
# offset along the LED's right side like the v4.0 pair (mirrored).
# Tails sit just clear of the LED triangle's right edge.
TAILS = [(872.0, 470.0), (894.0, 430.0)]
TOTAL_LEN = 126.0          # tail -> tip, along the axis
SHAFT_HALF = 9.5           # shaft width 19
HEAD_LEN = 48.0            # triangular head length along the axis
HEAD_HALF = 28.0           # head base width 56


def arrow_polygon(tail):
    """Shaft rectangle + triangular head as one polygon (1x coords)."""
    d = np.array([math.sqrt(0.5), math.sqrt(0.5)])       # down-right 45°
    n = np.array([-math.sqrt(0.5), math.sqrt(0.5)])      # perpendicular
    t = np.array(tail, dtype=float)
    tip = t + d * TOTAL_LEN
    head_base = tip - d * HEAD_LEN
    shaft_end = head_base                                  # shaft meets head base
    pts = [
        t - n * SHAFT_HALF,
        shaft_end - n * SHAFT_HALF,
        head_base - n * HEAD_HALF,
        tip,
        head_base + n * HEAD_HALF,
        shaft_end + n * SHAFT_HALF,
        t + n * SHAFT_HALF,
    ]
    return [tuple(p) for p in pts]


def main():
    im = Image.open(ICON).convert("RGB")
    arr = np.array(im).astype(int)
    amber_mask = (np.abs(arr - np.array(AMBER)).sum(axis=2) < 30)
    lab, ncomp = ndimage.label(amber_mask)

    keep = np.zeros(amber_mask.shape, dtype=bool)   # LED triangle + bar
    erase = np.zeros(amber_mask.shape, dtype=bool)  # old emission arrows
    for i in range(1, ncomp + 1):
        comp = lab == i
        ys, xs = np.nonzero(comp)
        if xs.min() >= 855:                          # right of the LED body
            erase |= comp
        else:
            keep |= comp
    print(f"amber components: {ncomp}, erasing arrow pixels: {erase.sum()}")

    protect = ndimage.binary_dilation(keep, iterations=1)
    wipe = ndimage.binary_dilation(erase, iterations=3) & ~protect
    arr[wipe] = BG
    # Catch antialiased arrow remnants inside the arrow zone that the
    # component pass missed (amber-tinted, unprotected, right side,
    # above the cathode bar).
    zone = np.zeros(amber_mask.shape, dtype=bool)
    zone[400:556, 845:1024] = True
    r, g, b = arr[..., 0], arr[..., 1], arr[..., 2]
    amberish = (r > 140) & (g > 110) & (b < 130) & (r > b + 60)
    arr[zone & amberish & ~protect] = BG

    base = Image.fromarray(arr.astype(np.uint8), "RGB")

    # Draw the new arrows on a supersampled overlay, then downscale.
    overlay = Image.new("RGBA", (1024 * SS, 1024 * SS), (0, 0, 0, 0))
    od = ImageDraw.Draw(overlay)
    for tail in TAILS:
        poly = [(x * SS, y * SS) for (x, y) in arrow_polygon(tail)]
        od.polygon(poly, fill=AMBER + (255,))
    overlay = overlay.resize((1024, 1024), Image.LANCZOS)
    out = Image.alpha_composite(base.convert("RGBA"), overlay).convert("RGB")

    out.save(ICON)
    print(f"wrote {ICON}")


if __name__ == "__main__":
    main()
