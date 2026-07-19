#!/usr/bin/env python3
"""Cross-check the v13probe sy2 histogram against the RASTERLOG CSV.

The probe counts commits of writes to 478878 (sy2) bucketed by hcnt:
  b0 h<100, b1 h<170, b2 h<240, b3 h<320, b4 rest  (active lines, vcnt<224)
  vbl = writes on vcnt>=224
The CSV logs the same writes at bus-assert time (a few clks earlier), so
individual writes near a bucket edge may drift one bucket; totals must
agree to within a handful of frame-boundary stragglers.

Usage: probe_validate.py <raster_writes_sim.csv> <probeval.log>
"""
import csv
import re
import sys


def bucket(vpos, hpos):
    if vpos >= 224:
        return "vbl"
    if hpos < 100:
        return "b0"
    if hpos < 170:
        return "b1"
    if hpos < 240:
        return "b2"
    if hpos < 320:
        return "b3"
    return "b4"


def main(csv_path, log_path):
    keys = ["b0", "b1", "b2", "b3", "b4", "vbl"]
    csv_h = dict.fromkeys(keys, 0)
    csv_tot = 0
    with open(csv_path) as f:
        for row in csv.DictReader(f):
            if int(row["addr"], 16) == 0x478878:
                csv_h[bucket(int(row["vpos"]), int(row["hpos"]))] += 1
                csv_tot += 1

    probe_h = dict.fromkeys(keys, 0)
    probe_tot = 0
    frames = 0
    pat = re.compile(
        r"PROBE f=\d+ b0=(\d+) b1=(\d+) b2=(\d+) b3=(\d+) b4=(\d+) "
        r"vbl=(\d+) tot=(\d+)")
    with open(log_path) as f:
        for line in f:
            m = pat.search(line)
            if not m:
                continue
            frames += 1
            vals = [int(x) for x in m.groups()]
            for k, v in zip(keys, vals[:6]):
                probe_h[k] += v
            probe_tot += vals[6]
            if sum(vals[:6]) != vals[6]:
                print(f"CHECKSUM FAIL on line: {line.strip()}")

    print(f"probe frames: {frames}")
    print(f"{'bucket':>6} {'csv':>7} {'probe':>7}")
    for k in keys:
        print(f"{k:>6} {csv_h[k]:>7} {probe_h[k]:>7}")
    print(f"{'total':>6} {csv_tot:>7} {probe_tot:>7}")
    drift = abs(csv_tot - probe_tot)
    edge = sum(abs(csv_h[k] - probe_h[k]) for k in keys)
    print(f"total drift={drift} bucket-edge drift={edge}")
    ok = drift <= frames // 50 + 2 and edge <= csv_tot // 20 + 4
    print("PROBE VALIDATION " + ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
