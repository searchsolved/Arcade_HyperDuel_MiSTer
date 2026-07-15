#!/usr/bin/env python3
"""Scan PPMs from a sim run for the top-lines cloud artifact.

For each PPM in the ramp-frame range, compares rows 0-7 against a body
reference (rows 12-20) pixel by pixel. On a clean frame, the cloud
pattern should be continuous from top to body. A displaced strip shows
up as a horizontal or vertical shift in the top rows vs the body.

Outputs per-row metrics: mean pixel difference and the best horizontal
shift (cross-correlation) that minimises the diff. On the real PCB,
best shift == 0 for all rows. The artifact shows best_shift != 0 for
the top rows.

Usage: scan_toplines.py <ppm_dir> [first_frame] [last_frame]
"""
import sys, os, glob, struct
from collections import defaultdict

def read_ppm(path):
    with open(path, 'rb') as f:
        magic = f.readline().strip()
        assert magic == b'P6', f"Not a binary PPM: {magic}"
        while True:
            line = f.readline()
            if not line.startswith(b'#'):
                break
        w, h = map(int, line.split())
        maxval = int(f.readline().strip())
        data = f.read()
    rows = []
    for y in range(h):
        row = []
        for x in range(w):
            off = (y * w + x) * 3
            row.append((data[off], data[off+1], data[off+2]))
        rows.append(row)
    return w, h, rows

def row_diff(a, b, shift=0):
    """Mean absolute pixel difference between rows a and b with b shifted."""
    w = len(a)
    total = 0
    n = 0
    for x in range(w):
        bx = (x + shift) % w
        dr = abs(a[x][0] - b[bx][0])
        dg = abs(a[x][1] - b[bx][1])
        db = abs(a[x][2] - b[bx][2])
        total += dr + dg + db
        n += 1
    return total / (n * 3) if n else 0

def best_shift(top_row, ref_row, max_shift=16):
    """Find the horizontal shift of ref_row that best matches top_row."""
    best_s = 0
    best_d = row_diff(top_row, ref_row, 0)
    for s in range(-max_shift, max_shift + 1):
        if s == 0:
            continue
        d = row_diff(top_row, ref_row, s)
        if d < best_d:
            best_d = d
            best_s = s
    return best_s, best_d

def main():
    ppm_dir = sys.argv[1]
    first = int(sys.argv[2]) if len(sys.argv) > 2 else 0
    last = int(sys.argv[3]) if len(sys.argv) > 3 else 99999

    ppms = sorted(glob.glob(os.path.join(ppm_dir, 'boot_*.ppm')))
    if not ppms:
        print(f"No PPMs found in {ppm_dir}")
        return

    # per-row aggregates across all frames
    agg = defaultdict(lambda: {'n': 0, 'diff0': 0, 'shifted': 0, 'max_shift': 0})
    flagged = []

    for path in ppms:
        fname = os.path.basename(path)
        frame = int(fname.replace('boot_', '').replace('.ppm', ''))
        if frame < first or frame > last:
            continue

        w, h, rows = read_ppm(path)
        if h < 24:
            continue

        # reference: average of rows 12-19
        ref_rows = rows[12:20]

        for r in range(min(8, h)):
            # compare this row against the body reference row at same offset
            ref_r = ref_rows[r % len(ref_rows)]
            d0 = row_diff(rows[r], ref_r, 0)
            bs, bd = best_shift(rows[r], ref_r)

            a = agg[r]
            a['n'] += 1
            a['diff0'] += d0
            if abs(bs) > 0:
                a['shifted'] += 1
                a['max_shift'] = max(a['max_shift'], abs(bs))

            if d0 > 5 and r < 4:
                flagged.append((frame, r, d0, bs))

    print("=== Per-row summary across ramp frames ===")
    for r in sorted(agg):
        a = agg[r]
        n = a['n'] or 1
        print(f"  row {r}: frames={a['n']} "
              f"mean_diff={a['diff0']/n:.1f} "
              f"shifted_frames={a['shifted']} "
              f"max_shift={a['max_shift']}")

    if flagged:
        print(f"\n=== Flagged frames (diff > 5 on rows 0-3): {len(flagged)} ===")
        for f, r, d, s in flagged[:20]:
            print(f"  frame {f} row {r}: diff={d:.1f} best_shift={s}")
    else:
        print("\nNo flagged frames (artifact may not be visible in sim PPMs)")

if __name__ == '__main__':
    main()
