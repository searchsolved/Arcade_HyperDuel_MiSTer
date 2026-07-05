#!/usr/bin/env python3
"""Diff a tb_system VDP state dump against a MAME reference dump.

Usage: diff_state.py <boot_dir> <frame_n> <mame_frame_dir>
Compares layer VRAM tile codes, tiletable, and palette; reports where our
system-written state diverges from MAME's for the same screen.
"""
import struct
import sys
from pathlib import Path


def load_writememh(path, size):
    vals = [0] * size
    idx = 0
    for tok in Path(path).read_text().split():
        if tok.startswith("@"):
            idx = int(tok[1:], 16)
        elif tok.startswith("//"):
            continue
        else:
            vals[idx] = int(tok, 16)
            idx += 1
    return vals


def load_bin(path):
    d = Path(path).read_bytes()
    return list(struct.unpack("<%dH" % (len(d) // 2), d))


def main(boot_dir, n, mame_dir):
    boot, mame = Path(boot_dir), Path(mame_dir)
    for name, size in [("vram0", 65536), ("vram1", 65536), ("vram2", 65536),
                       ("tiletable", 1024), ("palette", 4096),
                       ("spriteram", 2048)]:
        ours = load_writememh(boot / f"st{n}_{name}.hex", size)
        ref = load_bin(mame / f"{name}.bin")
        bad = [(i, ref[i], ours[i]) for i in range(size) if ours[i] != ref[i]]
        print(f"{name}: {len(bad)}/{size} differ", end="")
        if bad:
            print("  first:", [(hex(i), hex(r), hex(o)) for i, r, o in bad[:6]])
        else:
            print()
    print("--- regs ---")
    ours = dict(l.split("=") for l in (boot / f"st{n}_regs.txt").read_text().splitlines() if "=" in l)
    ref = dict(l.split("=") for l in (mame / "regs.txt").read_text().splitlines() if "=" in l)
    for k in ref:
        o, r = int(ours.get(k, "0"), 16), int(ref[k], 16)
        flag = "" if o == r else "   <-- DIFFERS"
        print(f"{k}: mame={r:#x} ours={o:#x}{flag}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3])
