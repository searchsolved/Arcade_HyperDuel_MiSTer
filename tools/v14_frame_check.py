#!/usr/bin/env python3
"""v14 fix-scope proof on a shared artifact frame.

Compares a v13-semantics dump (bossbase) against the v14 dump of the
SAME frame: the fix changes only line 0's sy0/sy2 consumption, so
row 0 must differ (fix engaged) and rows 1..223 must be pixel-identical
(no collateral change).

Usage: v14_frame_check.py <pre.ppm> <post.ppm>
"""
import sys

import numpy as np
from PIL import Image


def load(p):
    return np.asarray(Image.open(p).convert("RGB"))


def main(pre_p, post_p):
    pre, post = load(pre_p), load(post_p)
    if pre.shape != post.shape:
        print(f"FAIL shape mismatch {pre.shape} vs {post.shape}")
        return 1
    row0_diff = int((pre[0] != post[0]).any(axis=-1).sum())
    rest_diff = int((pre[1:] != post[1:]).any(axis=-1).sum())
    print(f"row0 differing pixels: {row0_diff}/320")
    print(f"rows 1-223 differing pixels: {rest_diff}")
    ok = row0_diff > 0 and rest_diff == 0
    print("V14 FRAME CHECK " + ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
