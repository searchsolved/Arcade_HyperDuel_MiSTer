#!/usr/bin/env python3
"""Compare two hex-word-per-line files; exit 1 on mismatch."""
import sys


def load(path):
    with open(path) as f:
        return [int(t, 16) for t in f.read().split()]


def main(a_path, b_path, max_report=10):
    a, b = load(a_path), load(b_path)
    if len(a) != len(b):
        print(f"LENGTH MISMATCH {len(a)} vs {len(b)}")
        return 1
    bad = 0
    for i, (va, vb) in enumerate(zip(a, b)):
        if va != vb:
            bad += 1
            if bad <= max_report:
                print(f"  [{i:#06x}] oracle={va:#06x} rtl={vb:#06x}")
    if bad:
        print(f"FAIL: {bad}/{len(a)} words differ ({a_path} vs {b_path})")
        return 1
    print(f"PASS: {len(a)} words identical ({a_path} vs {b_path})")
    return 0


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:3]))
