#!/usr/bin/env python3
"""Scan the PCB capture for left-side black tearing bands.

Artifact signature (matches our core's stale-line blanking): a row whose
left portion is pure black for a substantial run, then transitions to
real content, while neighbouring rows show content at that x. Legit dark
scenes are dark on both sides, so require bright right-side content and
>= min_rows consecutive flagged rows.
"""
import subprocess, sys, numpy as np

SRC = sys.argv[1]
FPS = sys.argv[2] if len(sys.argv) > 2 else "1"
START = sys.argv[3] if len(sys.argv) > 3 else None
DUR = sys.argv[4] if len(sys.argv) > 4 else None

W, H = 984, 720          # game area crop
X0, Y0 = 144, 0
BLACK = 26               # luma threshold for "black"
MIN_RUN, MAX_RUN = 60, 860   # px of leading black to count as a tear row
RIGHT_MEAN = 42          # right-of-run brightness proving content exists
MIN_ROWS = 4             # consecutive rows (>1 game line at 3px/line)

cmd = ["ffmpeg", "-v", "error"]
if START: cmd += ["-ss", START]
if DUR: cmd += ["-t", DUR]
cmd += ["-i", SRC, "-vf", f"fps={FPS},crop={W}:{H}:{X0}:{Y0},format=gray",
        "-f", "rawvideo", "-"]
p = subprocess.Popen(cmd, stdout=subprocess.PIPE)
fsz = W * H
n = 0
flagged = []
t0 = float(START) if START else 0.0
while True:
    buf = p.stdout.read(fsz)
    if len(buf) < fsz:
        break
    fr = np.frombuffer(buf, np.uint8).reshape(H, W)
    dark = fr < BLACK
    # leading black run per row
    first_bright = np.argmax(~dark, axis=1)
    all_dark = ~np.any(~dark, axis=1)
    run = np.where(all_dark, W, first_bright)
    right = fr[:, -180:].mean(axis=1)
    hit = (run >= MIN_RUN) & (run <= MAX_RUN) & (right >= RIGHT_MEAN)
    # consecutive rows
    best, cur, ystart, bys = 0, 0, -1, -1
    for y in range(H):
        if hit[y]:
            if cur == 0: ystart = y
            cur += 1
            if cur > best: best, bys = cur, ystart
        else:
            cur = 0
    if best >= MIN_ROWS:
        # real tear: rows just above and below the band show content in
        # the same left region that the band leaves black (background
        # continuity); star fields are black there too and get rejected
        rl = int(run[bys])
        ya, yb = max(0, bys - 4), min(H - 1, bys + best + 3)
        seg = slice(24, max(48, rl - 8))
        above = fr[ya, seg].mean()
        below = fr[yb, seg].mean()
        if above >= 40 and below >= 40:
            ts = t0 + n / float(FPS)
            flagged.append((ts, best, bys, rl))
    n += 1
p.wait()
print(f"scanned {n} frames @ {FPS}fps")
for ts, rows, y, rl in flagged:
    print(f"  FLAG t={ts:.2f}s rows={rows} y0={y} leftrun={rl}px")
if not flagged:
    print("  no tear-signature frames found")
