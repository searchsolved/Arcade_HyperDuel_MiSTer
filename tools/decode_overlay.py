#!/usr/bin/env python3
"""Decode the forced-overlay telemetry rows from MiSTer screenshots.

Reads the 4x7 hex font straight out of mister/Hyprduel.sv, samples each
glyph dot at (ytop + fy*2, x0 + fx*4 + 1) on the native 320x224 PNG, and
matches value chars 5-8 of each of the 9 rows (rows start at y = 32+20k).
Rows that fail to match all four digits are reported as '----'.

v13probe row meaning:
  0 b0   sy2 writes, active lines, h0-99
  1 b1   active, h100-169 (before the h170 sample)
  2 dsw  live DSW word (anchor: expect DF80)
  3 b2   active, h170-239 (missed the sample)
  4 b3   active, h240-319
  5 b4   active, h320-423
  6 vbl  writes on vblank lines
  7 tot  total sy2 writes in the frame
  8 fsm  unchanged legacy row

Usage: decode_overlay.py <shot.png> [more.png ...] [--csv out.csv]
"""
import re
import sys

import numpy as np
from PIL import Image

SV = "/Users/leefoot/python_scripts/hyperduel-mister/mister/Hyprduel.sv"
ROWNAMES = ["b0", "b1", "dsw", "b2", "b3", "b4", "vbl", "tot", "fsm"]


def load_font():
    pat = re.compile(r"\{5'd(\d+),3'd(\d+)\}:\s*frow=4'b([01]{4})")
    glyphs = {}
    with open(SV) as f:
        for m in pat.finditer(f.read()):
            g, fy, bits = int(m.group(1)), int(m.group(2)), m.group(3)
            glyphs.setdefault(g, [0] * 7)[fy] = int(bits, 2)
    # hex digits are glyphs 0-15; each is a tuple of 7 4-bit rows
    return {g: tuple(rows) for g, rows in glyphs.items() if g < 16}


def sample_char(lum, ytop, x0):
    rows = []
    for fy in range(7):
        bits = 0
        for fx in range(4):
            y = ytop + fy * 2
            x = x0 + fx * 4 + 1
            if y < lum.shape[0] and x < lum.shape[1] and lum[y, x] > 100:
                bits |= 8 >> fx
        rows.append(bits)
    return tuple(rows)


def decode(path, font):
    img = Image.open(path).convert("RGB")
    a = np.asarray(img, dtype=np.int32)
    lum = (a[:, :, 0] + a[:, :, 1] + a[:, :, 2]) // 3
    inv = {v: k for k, v in font.items()}
    out = []
    for r in range(9):
        ytop = 32 + 20 * r
        digits = []
        for c in range(5, 9):
            g = inv.get(sample_char(lum, ytop, 16 + 16 * c))
            digits.append(format(g, "X") if g is not None else None)
        out.append("".join(d for d in digits) if None not in digits else None)
    return out


def main(argv):
    csv_out = None
    if "--csv" in argv:
        i = argv.index("--csv")
        csv_out = argv[i + 1]
        argv = argv[:i] + argv[i + 2:]
    font = load_font()
    lines = ["file," + ",".join(ROWNAMES)]
    for path in argv:
        try:
            vals = decode(path, font)
        except Exception as e:
            print(f"{path}: ERROR {e}", file=sys.stderr)
            continue
        cells = [v if v is not None else "----" for v in vals]
        lines.append(path.split("/")[-1] + "," + ",".join(cells))
        pretty = " ".join(f"{n}={v}" for n, v in zip(ROWNAMES, cells))
        print(f"{path.split('/')[-1]}: {pretty}")
    if csv_out:
        with open(csv_out, "w") as f:
            f.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main(sys.argv[1:])
