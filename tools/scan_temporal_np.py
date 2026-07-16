#!/usr/bin/env python3
"""Vectorised per-row temporal shift scan over consecutive sim PPMs.

For each consecutive frame pair and each row, finds the (dy, dx) that
best matches row r of frame N+1 against row r+dy of frame N (circular
in x). Body rows 8-19 vote a consensus motion; top rows 0-7 that
consistently deviate from it were rendered with different (stale)
scroll state - the top-lines artifact.

Static pixels (HUD glyphs, identical across the pair) are masked out
of the diff per row when they cover under 85% of the row.

Usage: scan_temporal_np.py <ppm_dir> [stride=1] [maxdx=12] [maxdy=3]
"""
import sys, os, glob
import numpy as np
from collections import Counter, defaultdict

def read_ppm(path):
    with open(path, 'rb') as f:
        data = f.read()
    if data[:2] == b'P6':
        # header: P6\n<w> <h>\n255\n
        parts = data.split(b'\n', 3)
        w, h = map(int, parts[1].split())
        raw = parts[3][:w*h*3]
        return np.frombuffer(raw, np.uint8).reshape(h, w, 3).astype(np.int16)
    # P3 ascii
    txt = data.decode()
    vals = txt.split()
    w, h = int(vals[1]), int(vals[2])
    arr = np.array(vals[4:4+w*h*3], dtype=np.int16).reshape(h, w, 3)
    return arr

def main():
    ppm_dir = sys.argv[1]
    stride = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    maxdx = int(sys.argv[3]) if len(sys.argv) > 3 else 12
    maxdy = int(sys.argv[4]) if len(sys.argv) > 4 else 3
    NROWS = 20   # rows 0-7 under test, 8-19 body consensus

    paths = sorted(glob.glob(os.path.join(ppm_dir, 'boot_*.ppm')))
    nums = [int(os.path.basename(p)[5:9]) for p in paths]
    pairs = [(paths[i], paths[i+1], nums[i]) for i in range(len(paths)-1)
             if nums[i+1] == nums[i] + 1][::stride]
    print(f"{len(pairs)} pairs analysed (stride {stride}), "
          f"search dx +/-{maxdx} dy +/-{maxdy}")

    dev_hist = defaultdict(Counter)   # row -> Counter of (dy,dx) rel consensus
    dev_frames = defaultdict(list)
    prev = None
    for pa, pb, na in pairs:
        A = read_ppm(pa)
        B = read_ppm(pb)
        best = {}
        for r in range(NROWS):
            rb = B[r]                                    # (w,3)
            static = (np.abs(A[r] - B[r]).sum(1) == 0) & (B[r].sum(1) > 0)
            use = ~static if static.sum() < 0.85 * len(rb) else np.ones(len(rb), bool)
            bd, bdy, bdx = 1e18, 0, 0
            for dy in range(-maxdy, maxdy + 1):
                if not (0 <= r + dy < A.shape[0]):
                    continue
                ra = A[r + dy]
                for dx in range(-maxdx, maxdx + 1):
                    d = np.abs(rb[use] - np.roll(ra, -dx, axis=0)[use]).mean()
                    if d < bd:
                        bd, bdy, bdx = d, dy, dx
            best[r] = (bdy, bdx, bd)
        body = Counter((best[r][0], best[r][1]) for r in range(8, NROWS))
        (cdy, cdx), _ = body.most_common(1)[0]
        for r in range(8):
            dy, dx, d = best[r]
            rel = (dy - cdy, dx - cdx)
            dev_hist[r][rel] += 1
            if rel != (0, 0) and d < 20:
                dev_frames[r].append((na, rel, round(d, 1)))

    print("\n=== Per-row motion relative to body consensus ===")
    print("(0,0) = moves with the body; anything else = rendered from")
    print("different scroll state that frame")
    for r in sorted(dev_hist):
        total = sum(dev_hist[r].values())
        top = ', '.join(f"({dy:+d},{dx:+d})x{c}" for (dy, dx), c
                        in dev_hist[r].most_common(5))
        ndev = total - dev_hist[r][(0, 0)]
        print(f"  row {r}: deviant {ndev}/{total}  {top}")
    print("\n=== Sample deviant pairs (row: frame rel diff) ===")
    for r in sorted(dev_frames):
        s = ', '.join(f"{f}{rel}" for f, rel, d in dev_frames[r][:8])
        print(f"  row {r}: {s}")

if __name__ == '__main__':
    main()
