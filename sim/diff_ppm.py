#!/usr/bin/env python3
"""Pixel-diff two P3 PPMs; exit 1 on any mismatch."""
import sys


def load_p3(path):
    tok = []
    with open(path) as f:
        for line in f:
            if line.startswith("#"):
                continue
            tok.extend(line.split())
    assert tok[0] == "P3", f"{path}: not P3"
    w, h, maxv = int(tok[1]), int(tok[2]), int(tok[3])
    vals = list(map(int, tok[4:4 + w * h * 3]))
    assert len(vals) == w * h * 3, f"{path}: truncated"
    return w, h, vals


def main(a_path, b_path, max_report=10):
    wa, ha, a = load_p3(a_path)
    wb, hb, b = load_p3(b_path)
    if (wa, ha) != (wb, hb):
        print(f"DIMENSION MISMATCH {wa}x{ha} vs {wb}x{hb}")
        return 1
    bad = 0
    for i in range(wa * ha):
        pa, pb = a[i * 3:i * 3 + 3], b[i * 3:i * 3 + 3]
        if pa != pb:
            bad += 1
            if bad <= max_report:
                print(f"  ({i % wa},{i // wa}) oracle={pa} rtl={pb}")
    if bad:
        print(f"FAIL: {bad}/{wa * ha} pixels differ ({a_path} vs {b_path})")
        return 1
    print(f"PASS: {wa * ha} pixels identical ({a_path} vs {b_path})")
    return 0


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:3]))
