#!/usr/bin/env python3
"""Locate sy2 raster discontinuities in a RASTERLOG CSV and predict, per
line, where the v12.2 renderer's h170 snapshot diverges from the real
chip's per-pixel beam consumption.

Model:
  - beam order: (frame, vpos, hpos) with vpos 0..260, active vpos 0..223,
    active hpos 0..319
  - real chip, line N pixel x: last sy2 write before beam point (N, x)
  - our render, line N: last sy2 write before (N, 170) [same-line sample]

For each frame with a max adjacent-line |delta sy2| >= JUMP, print the
write schedule around the jump and the lines where our whole-line value
differs from the real chip for >= MINPX leading pixels.

Usage: boss_split_analysis.py <raster_writes_sim.csv> [--jump 64]
"""
import csv
import sys
from collections import defaultdict

SY2 = 0x478878
SAMPLE_H = 170
ACTIVE_W = 320


def beam_key(vpos, hpos):
    return vpos * 1000 + hpos


def main(path, jump=64):
    frames = defaultdict(list)   # frame -> [(vpos, hpos, val)]
    with open(path) as f:
        for row in csv.DictReader(f):
            if int(row["addr"], 16) == SY2:
                frames[int(row["frame"])].append(
                    (int(row["vpos"]), int(row["hpos"]),
                     int(row["data"], 16)))

    for fr in sorted(frames):
        writes = sorted(frames[fr], key=lambda w: beam_key(w[0], w[1]))
        if len(writes) < 8:
            continue
        # per-line values at the sample point and at line start
        # walk lines 0..223, tracking last write before (N,170) and (N,0)
        at_sample, at_start = {}, {}
        wi = 0
        val = None
        # carry-in: last write of previous frame unknown; use first write
        for n in range(224):
            while wi < len(writes) and beam_key(*writes[wi][:2]) <= beam_key(n, 0):
                val = writes[wi][2]
                wi += 1
            at_start[n] = val
            while wi < len(writes) and beam_key(*writes[wi][:2]) <= beam_key(n, SAMPLE_H):
                val = writes[wi][2]
                wi += 1
            at_sample[n] = val
        # ladder deltas at the sample point
        deltas = []
        for n in range(1, 224):
            a, b = at_sample.get(n - 1), at_sample.get(n)
            if a is not None and b is not None:
                d = (b - a) & 0xFFFF
                if d > 0x8000:
                    d -= 0x10000
                deltas.append((abs(d), n, d))
        if not deltas:
            continue
        mx, mline, md = max(deltas)
        if mx < jump:
            continue
        print(f"\nframe {fr}: max adjacent-line sample delta {md} at line "
              f"{mline}; {len(writes)} sy2 writes")
        # lines where whole-line (sample) value differs from line-start
        # value: those lines show our value on pixels the real chip drew
        # with the previous value
        bad = []
        for n in range(224):
            s, st = at_sample.get(n), at_start.get(n)
            if s is None or st is None or s == st:
                continue
            d = (s - st) & 0xFFFF
            if d > 0x8000:
                d -= 0x10000
            # find the write that changed it: leading-pixel extent
            ext = next((h for (v, h, _) in writes
                        if v == n and h <= SAMPLE_H), None)
            if abs(d) >= 4:
                bad.append((n, d, ext))
        if bad:
            print("  lines where h170 sample != line-start value "
                  "(line, px shift, write hpos):")
            for n, d, ext in bad[:20]:
                print(f"    line {n:3d} shift {d:+5d} write@h{ext}")
            if len(bad) > 20:
                print(f"    ... {len(bad) - 20} more")
        # context: writes around the jump line
        print("  writes near the jump:")
        for v, h, x in writes:
            if mline - 4 <= v <= mline + 3:
                print(f"    ({v:3d},{h:3d}) = {x:04x}")


if __name__ == "__main__":
    jump = 64
    if "--jump" in sys.argv:
        jump = int(sys.argv[sys.argv.index("--jump") + 1])
    main(sys.argv[1], jump)
