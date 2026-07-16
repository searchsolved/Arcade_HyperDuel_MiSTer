#!/usr/bin/env python3
"""Per-row temporal shift scan over CONSECUTIVE sim PPM frames.

During a scroll ramp, the background moves by a uniform (dy, dx) between
consecutive frames. For each row r of frame N+1 this finds the (dy, dx)
in a small search window that best matches a row of frame N. Rows
rendered with stale scroll registers (the top-lines artifact) show a
per-frame dx/dy that deviates from the body rows' consensus.

HUD text pixels are static and would bias the match toward (0, 0), so
pixels that are identical at the same position across the pair AND
match in a 3-frame majority are treated as HUD and excluded per row
when they cover under 80% of it.

Usage: scan_temporal_shift.py <ppm_dir> [rows=16] [maxdx=16] [maxdy=3]
Output: per-pair per-row best (dy, dx, diff), then a per-row summary of
how often the row deviates from the body consensus (rows 8..rows-1).
"""
import sys, os, glob
from collections import Counter, defaultdict

def read_ppm(path):
    with open(path, 'rb') as f:
        magic = f.readline().strip()
    if magic == b'P6':
        with open(path, 'rb') as f:
            f.readline()
            line = f.readline()
            while line.startswith(b'#'):
                line = f.readline()
            w, h = map(int, line.split())
            f.readline()
            data = f.read()
        rows = [[(data[(y*w+x)*3], data[(y*w+x)*3+1], data[(y*w+x)*3+2])
                 for x in range(w)] for y in range(h)]
        return w, h, rows
    with open(path) as f:
        f.readline()
        line = f.readline()
        while line.startswith('#'):
            line = f.readline()
        w, h = map(int, line.split())
        f.readline()
        vals = []
        for line in f:
            vals.extend(int(v) for v in line.split())
    rows = [[(vals[(y*w+x)*3], vals[(y*w+x)*3+1], vals[(y*w+x)*3+2])
             for x in range(w)] for y in range(h)]
    return w, h, rows

def row_diff(a, b, dx, mask):
    w = len(a)
    total = n = 0
    for x in range(w):
        if mask and mask[x]:
            continue
        bx = (x + dx) % w
        pa, pb = a[x], b[bx]
        total += abs(pa[0]-pb[0]) + abs(pa[1]-pb[1]) + abs(pa[2]-pb[2])
        n += 1
    return (total / (n * 3), n) if n else (0.0, 0)

def main():
    ppm_dir = sys.argv[1]
    nrows  = int(sys.argv[2]) if len(sys.argv) > 2 else 16
    maxdx  = int(sys.argv[3]) if len(sys.argv) > 3 else 16
    maxdy  = int(sys.argv[4]) if len(sys.argv) > 4 else 3

    paths = sorted(glob.glob(os.path.join(ppm_dir, 'boot_*.ppm')))
    frames = []
    for p in paths:
        n = int(os.path.basename(p)[5:9])
        frames.append((n, p))
    # keep only consecutive runs
    pairs = [(a, b) for a, b in zip(frames, frames[1:]) if b[0] == a[0] + 1]
    if not pairs:
        print("No consecutive frame pairs found")
        return
    print(f"{len(pairs)} consecutive pairs, rows 0..{nrows-1}, "
          f"search dx +/-{maxdx} dy +/-{maxdy}")

    cache = {}
    def load(p):
        if p not in cache:
            cache[p] = read_ppm(p)
        return cache[p]

    deviation = defaultdict(Counter)   # row -> Counter of (dy,dx)
    for (na, pa), (nb, pb) in pairs:
        w, h, ra = load(pa)
        _, _, rb = load(pb)
        results = {}
        for r in range(min(nrows, h - maxdy)):
            # static-pixel mask (likely HUD glyphs): identical across pair
            mask = [ra[r][x] == rb[r][x] and ra[r][x] != (0, 0, 0)
                    for x in range(w)]
            if sum(mask) > 0.8 * w:
                mask = None
            best = (1e9, 0, 0)
            for dy in range(-maxdy, maxdy + 1):
                if not (0 <= r + dy < h):
                    continue
                for dx in range(-maxdx, maxdx + 1):
                    d, n = row_diff(rb[r], ra[r + dy], dx, mask)
                    if n > 40 and d < best[0]:
                        best = (d, dy, dx)
            results[r] = best
        body = Counter((results[r][1], results[r][2])
                       for r in range(8, nrows) if r in results)
        if not body:
            continue
        consensus, _ = body.most_common(1)[0]
        line = [f"pair {na}->{nb} consensus dy={consensus[0]} dx={consensus[1]}:"]
        for r in range(min(8, nrows)):
            if r not in results:
                continue
            d, dy, dx = results[r]
            dev = (dy, dx) != consensus
            deviation[r][(dy, dx)] += 1
            if dev:
                line.append(f"row{r}=({dy},{dx},{d:.1f})*")
        print(' '.join(line))
        cache.pop(pa, None)

    print("\n=== Per-row (dy,dx) across pairs (top rows) ===")
    for r in sorted(deviation):
        top = ', '.join(f"({dy},{dx})x{c}" for (dy, dx), c
                        in deviation[r].most_common(4))
        print(f"  row {r}: {top}")

if __name__ == '__main__':
    main()
