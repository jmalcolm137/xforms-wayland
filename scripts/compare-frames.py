#!/usr/bin/env python3
"""compare-frames.py — score two renderings of the same XForms window.

Used by run-xforms-crosscheck.sh to tell a shim defect apart from a difference
that comes from somewhere other than the shim (a timer having fired at a
different moment, a random colour, a different font rasteriser).

The comparison is deliberately not a pixel diff.  The reference frame comes from
real X11 with core X fonts; the frame under test is drawn by cairo and Xft.  The
same glyph has different pixels at the edges in the two, so an exact comparison
reports every text label as different and the result says nothing.

Instead both frames are reduced to a grid of cells (8 px by default), and each
cell is reduced to a single bit: does it contain ink that differs from the
frame's background colour?  Widget borders, filled areas, images and text all
produce ink; empty background does not.  Two frames then agree when the same
cells are inked, which is a property of the *layout* rather than of the
rasteriser.  The score is the fraction of cells that agree, and a difference map
is printed so a disagreement can be located rather than merely counted.

Prints "<verdict> <detail>" and exits 0 when the frames agree.
"""

import argparse
import sys

try:
    from PIL import Image
except ImportError:  # pragma: no cover - Pillow is in the test env
    sys.exit("Pillow is required (pip install pillow)")


def load(path):
    """Return (ink, w, h, bg) for a frame: a 2-D bool grid plus its geometry."""
    im = Image.open(path).convert("RGB")
    w, h = im.size
    px = im.load()

    # The background is the modal colour: XForms' FL_GRAY, the window's own
    # fill, whatever the app painted over the whole window.
    hist = {}
    for y in range(h):
        for x in range(w):
            c = px[x, y]
            hist[c] = hist.get(c, 0) + 1
    bg = max(hist.items(), key=lambda kv: kv[1])[0]

    def ink(c):
        # A cell counts as inked if any pixel is far enough from the background
        # to be part of something drawn.  24 is comfortably above the largest
        # anti-aliasing halo either rasteriser produces around the same edge.
        return max(abs(c[i] - bg[i]) for i in range(3)) > 24

    return px, w, h, bg, ink


def cells(px, w, h, ink, cell):
    rows = (h + cell - 1) // cell
    cols = (w + cell - 1) // cell
    grid = [[False] * cols for _ in range(rows)]
    for gy in range(rows):
        y0, y1 = gy * cell, min(h, (gy + 1) * cell)
        for gx in range(cols):
            x0, x1 = gx * cell, min(w, (gx + 1) * cell)
            hit = False
            for y in range(y0, y1):
                for x in range(x0, x1):
                    if ink(px[x, y]):
                        hit = True
                        break
                if hit:
                    break
            grid[gy][gx] = hit
    return grid


def score(a, b):
    """Fraction of cells on which the two ink grids agree."""
    rows = max(len(a), len(b))
    cols = max(len(a[0]) if a else 0, len(b[0]) if b else 0)
    same = total = 0
    for gy in range(rows):
        for gx in range(cols):
            va = a[gy][gx] if gy < len(a) and gx < len(a[gy]) else False
            vb = b[gy][gx] if gy < len(b) and gx < len(b[gy]) else False
            total += 1
            if va == vb:
                same += 1
    return same / total if total else 0.0


def diffmap(a, b, cell):
    rows = max(len(a), len(b))
    cols = max(len(a[0]) if a else 0, len(b[0]) if b else 0)
    lines = []
    for gy in range(rows):
        line = []
        for gx in range(cols):
            va = a[gy][gx] if gy < len(a) and gx < len(a[gy]) else False
            vb = b[gy][gx] if gy < len(b) and gx < len(b[gy]) else False
            line.append("." if va == vb else ("s" if va else "x"))
        lines.append("".join(line))
    return lines, cell


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("shim", help="frame rendered through the shim")
    ap.add_argument("x11", help="frame rendered by real X11")
    ap.add_argument("--cell", type=int, default=8,
                    help="ink-cell size in pixels (default: 8)")
    ap.add_argument("--atol", type=float, default=0.02,
                    help="max fraction of disagreeing cells still called same "
                         "(default: 0.02)")
    ap.add_argument("--map", action="store_true",
                    help="print the difference map (s=shim only, x=x11 only)")
    args = ap.parse_args()

    pa, wa, ha, bga, inka = load(args.shim)
    pb, wb, hb, bgb, inkb = load(args.x11)

    if (wa, ha) != (wb, hb):
        # A size difference is a hard result on its own: XForms asked the window
        # manager for one geometry and got another, and no amount of rasteriser
        # difference explains a different number of pixels.
        print(f"diff size {wa}x{ha} (shim) vs {wb}x{hb} (x11)")
        return 1

    ga = cells(pa, wa, ha, inka, args.cell)
    gb = cells(pb, wb, hb, inkb, args.cell)
    s = score(ga, gb)

    verdicts = []
    if s >= 1.0 - args.atol:
        verdicts.append("same")
    elif s >= 0.90:
        verdicts.append("close")
    else:
        verdicts.append("diff")

    n_diff = sum(r.count("s") + r.count("x") for r in diffmap(ga, gb, args.cell)[0])
    detail = (f"agree {s * 100:.1f}% of {args.cell}px cells "
              f"({n_diff} differ) at {wa}x{ha}")
    if args.map:
        lines, cell = diffmap(ga, gb, args.cell)
        detail += f"; map (.=same s=shim x=x11, {cell}px/cell)"
    print(" ".join(verdicts), detail)
    if args.map:
        for r in lines:
            print(r)

    return 0 if verdicts[0] == "same" else 1


if __name__ == "__main__":
    sys.exit(main())