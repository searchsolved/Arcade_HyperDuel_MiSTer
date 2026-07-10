#!/usr/bin/env python3
"""Diff VDP register write logs (MAME tap_raster.lua vs sim +RASTERLOG).

Frames are aligned by write-content signature (sequence of addr,data pairs
per frame), not by frame number, because the sim boots faster than MAME
(MAME's spin_until kludges stall its main CPU). After alignment, matched
frames' writes are compared by beam position; mid-frame (visible) writes
that land on different lines are the raster-split jitter suspects.

Usage: python3 diff_raster.py <mame_csv> <sim_csv> [--window 150]
"""
import csv
import sys
from collections import defaultdict


def load(path):
    frames = defaultdict(list)
    with open(path) as f:
        for row in csv.DictReader(f):
            frames[int(row["frame"])].append(
                (row["addr"], row["data"], int(row["vpos"]), int(row["hpos"]))
            )
    return frames


def sig(writes):
    return tuple((a, d) for a, d, _, _ in writes)


def main():
    mame_p, sim_p = sys.argv[1], sys.argv[2]
    window = 150
    if "--window" in sys.argv:
        window = int(sys.argv[sys.argv.index("--window") + 1])

    mame = load(mame_p)
    sim = load(sim_p)
    msig = {f: sig(w) for f, w in mame.items()}
    ssig = {f: sig(w) for f, w in sim.items()}

    # find the frame offset (sim frame f matches mame frame f+k) that
    # maximises exact signature matches over non-trivial frames
    best_k, best_n = None, -1
    for k in range(-window, window + 1):
        n = sum(
            1
            for f in ssig
            if len(ssig[f]) >= 3 and msig.get(f + k) == ssig[f]
        )
        if n > best_n:
            best_k, best_n = k, n
    total_sig = sum(1 for f in ssig if len(ssig[f]) >= 3)
    print(f"alignment: sim frame f == mame frame f{best_k:+d} "
          f"({best_n}/{total_sig} non-trivial frames match exactly)")

    # MAME's log has an unknown constant line offset (its frame notifier
    # fires at a fixed but unknown beam position; screen:vpos() is unsafe
    # in every Lua callback context in MAME 0.288). Calibrate it as the
    # modal (v_sim - v_mame) mod 262 over all matched writes, then report
    # jitter relative to that constant.
    V_TOTAL = 262
    raw = []                            # (addr, dv_mod, v_s, v_m, frame)
    matched = 0
    for f in sorted(ssig):
        mf = f + best_k
        if msig.get(mf) != ssig[f]:
            continue
        matched += 1
        for (a, d, v_s, h_s), (_, _, v_m, h_m) in zip(sim[f], mame[mf]):
            raw.append((a, (v_s - v_m) % V_TOTAL, v_s, v_m, f))
    offs = defaultdict(int)
    for _, dvm, _, _, _ in raw:
        offs[dvm] += 1
    cal = max(offs.items(), key=lambda kv: kv[1])[0] if raw else 0
    examined = len(raw)
    print(f"calibrated constant line offset (sim - mame) = {cal} "
          f"({offs.get(cal, 0)}/{examined} writes at the mode)")

    deltas = defaultdict(list)          # addr -> [vpos delta after cal]
    visible_jitter = defaultdict(int)   # addr -> count of visible-line moves
    for a, dvm, v_s, v_m, f in raw:
        dv = ((dvm - cal + V_TOTAL // 2) % V_TOTAL) - V_TOTAL // 2
        deltas[a].append(dv)
        # a write that lands on a different VISIBLE line (after removing
        # the constant) splits the frame differently -> jitter candidate
        if dv != 0 and v_s < 224:
            visible_jitter[a] += 1

    print(f"matched frames: {matched}, writes compared: {examined}")
    print()
    print("per-register vpos delta (sim - mame):")
    for a in sorted(deltas):
        ds = deltas[a]
        zero = sum(1 for x in ds if x == 0)
        print(f"  {a}: n={len(ds)} same_line={zero} "
              f"min={min(ds)} max={max(ds)} "
              f"visible_moves={visible_jitter.get(a, 0)}")
    print()
    worst = sorted(visible_jitter.items(), key=lambda kv: -kv[1])[:8]
    if worst:
        print("jitter suspects (writes moving lines inside the visible frame):")
        for a, n in worst:
            print(f"  addr {a}: {n} moved writes")
    else:
        print("no visible-frame write moved lines - raster timing matches MAME")


if __name__ == "__main__":
    main()
