#!/usr/bin/env python3
"""Measure the real board's refresh rate from PCB gameplay footage.

Implements docs/plan_refresh_measurement.md:
  A: cumulative scroll slope (phase correlation, sub-pixel)
  B: duplicate-frame cadence
  C: audio-anchored timebase (music tempo vs the crystal-exact sim capture)

Usage:
  measure_refresh.py <video.mp4> --scroll T0 T1 --dup T0 T1 \
      --music T0 T1 --sim-music <mix.raw> S0 S1

The sim capture is s16le mono at 39,062.5 Hz by construction (80 MHz /
2048), i.e. crystal-exact: its music tempo is ground truth for method C.
"""
import argparse, subprocess, sys
import numpy as np

CROP = "crop=984:720:144:0"     # game area in a 1280x720 pillarboxed capture
SIM_SR = 39062.5


def frames_gray(video, t0, t1, scale_w, scale_h, y0=None, y1=None):
    vf = f"{CROP},scale={scale_w}:{scale_h},format=gray"
    cmd = ["ffmpeg", "-v", "error", "-ss", str(t0), "-t", str(t1 - t0),
           "-i", video, "-vf", vf, "-f", "rawvideo", "-"]
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE)
    fsz = scale_w * scale_h
    while True:
        b = p.stdout.read(fsz)
        if len(b) < fsz:
            break
        f = np.frombuffer(b, np.uint8).reshape(scale_h, scale_w)
        yield f[y0:y1] if y0 is not None else f
    p.wait()


def xshift(a, b):
    """Sub-pixel horizontal shift of b relative to a via phase correlation
    on row-mean profiles (robust to sprites, cheap)."""
    pa = a.mean(axis=0) - a.mean()
    pb = b.mean(axis=0) - b.mean()
    fa, fb = np.fft.rfft(pa), np.fft.rfft(pb)
    cps = fa * np.conj(fb)
    cps /= np.abs(cps) + 1e-12
    corr = np.fft.irfft(cps)
    n = len(corr)
    k = int(np.argmax(corr))
    y0, y1c, y2 = corr[(k - 1) % n], corr[k], corr[(k + 1) % n]
    denom = (y0 - 2 * y1c + y2)
    frac = 0.5 * (y0 - y2) / denom if abs(denom) > 1e-12 else 0.0
    sh = k + frac
    if sh > n / 2:
        sh -= n
    return -sh   # positive = content moved right


def method_a(video, t0, t1):
    """Cumulative scroll slope over [t0,t1], px per container frame."""
    shifts = []
    prev = None
    # mid-band strip: skip HUD (top ~64/720) and status bar (bottom ~40)
    for f in frames_gray(video, t0, t1, 656, 480, y0=60, y1=400):
        if prev is not None:
            shifts.append(xshift(prev, f))
        prev = f
    s = np.array(shifts)
    # duplicates give ~0 shift; the ramp slope is total travel / frames,
    # duplicates INCLUDED (they are part of the container timeline)
    # robust: discard outlier shifts (correlation failures), keep zeros
    good = np.abs(s) < 8.0
    cum = np.cumsum(np.where(good, s, 0.0))
    idx = np.arange(len(cum))
    # Theil-Sen-ish: median of pairwise slopes over wide spans
    k = len(cum) // 3
    slopes = (cum[2 * k:] - cum[:len(cum) - 2 * k]) / (2 * k)
    return float(np.median(slopes)), len(s), int((~good).sum())


def method_b(video, t0, t1, thr=0.35):
    """Duplicate cadence: fraction of near-identical consecutive frames."""
    prev = None
    dups = 0
    n = 0
    for f in frames_gray(video, t0, t1, 246, 180):
        if prev is not None:
            d = np.abs(f.astype(np.int16) - prev.astype(np.int16)).mean()
            n += 1
            if d < thr:
                dups += 1
        prev = f
    return dups, n


def tempo(x, sr, lo=0.20, hi=1.50):
    """Beat interval via onset autocorrelation, parabolic-refined."""
    w = int(sr // 100)
    e = np.sqrt(np.convolve(x * x, np.ones(w) / w, "same"))[::w]   # 100 Hz env
    d = np.clip(np.diff(e), 0, None)
    d -= d.mean()
    ac = np.correlate(d, d, "full")[len(d) - 1:]
    lags = np.arange(len(ac)) / 100.0
    band = (lags > lo) & (lags < hi)
    k = np.argmax(np.where(band, ac, -np.inf))
    y0, y1c, y2 = ac[k - 1], ac[k], ac[k + 1]
    denom = (y0 - 2 * y1c + y2)
    frac = 0.5 * (y0 - y2) / denom if abs(denom) > 1e-12 else 0.0
    return (k + frac) / 100.0


def video_audio(video, t0, t1, sr=39062):
    cmd = ["ffmpeg", "-v", "error", "-ss", str(t0), "-t", str(t1 - t0),
           "-i", video, "-vn", "-ac", "1", "-ar", str(sr), "-f", "s16le", "-"]
    raw = subprocess.run(cmd, capture_output=True).stdout
    return np.frombuffer(raw, np.int16).astype(np.float32) / 32768, sr


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("video")
    ap.add_argument("--scroll", nargs=2, type=float, required=True)
    ap.add_argument("--dup", nargs=2, type=float, required=True)
    ap.add_argument("--music", nargs=2, type=float)
    ap.add_argument("--sim-music", nargs=3)   # mix.raw S0 S1
    args = ap.parse_args()

    slope, nf, bad = method_a(args.video, *args.scroll)
    print(f"A: scroll slope = {slope:.5f} px/container-frame "
          f"({nf} frames, {bad} outliers)  [scaled 656/984 crop: "
          f"native px/frame = {slope * 984 / 656 / 3.075:.5f} game-px]")

    dups, n = method_b(args.video, *args.dup)
    f_ratio = 1.0 - dups / n
    print(f"B: dups {dups}/{n} -> f_native/f_container = {f_ratio:.5f} "
          f"(x60 = {60 * f_ratio:.3f} Hz, slowdown-sensitive)")

    if args.music and args.sim_music:
        va, sr = video_audio(args.video, *args.music)
        tv = tempo(va, sr)
        sim = np.fromfile(args.sim_music[0], np.int16).astype(np.float32) / 32768
        s0, s1 = float(args.sim_music[1]), float(args.sim_music[2])
        ts = tempo(sim[int(s0 * SIM_SR):int(s1 * SIM_SR)], SIM_SR)
        print(f"C: tempo video={tv:.5f}s sim={ts:.5f}s "
              f"chain_scale={tv / ts:.5f} (sim is crystal-exact truth)")
        print(f"   corrected B: {60 * f_ratio * (ts / tv):.3f} Hz")


if __name__ == "__main__":
    main()
