#!/usr/bin/env python3
"""Compare MAME attract PNGs against sim boot PPMs, frame by frame.

Usage:
    python3 diff_attract.py build/mame/attract build/boot_sdram [--every 30]

Expects MAME files as mame_NNNN.png and sim files as boot_NNNN.ppm,
where NNNN is the zero-padded frame number (dumped every --every frames).

Outputs per-frame pixel diff counts and saves amplified diff images for
any mismatched frames.
"""
import argparse, os, sys
from PIL import Image, ImageChops

def main():
    p = argparse.ArgumentParser()
    p.add_argument("mame_dir")
    p.add_argument("sim_dir")
    p.add_argument("--every", type=int, default=30)
    p.add_argument("--max-frame", type=int, default=620)
    args = p.parse_args()

    pass_count = 0
    fail_count = 0
    first_fail = None

    for n in range(0, args.max_frame + 1, args.every):
        mame_path = os.path.join(args.mame_dir, f"mame_{n:04d}.png")
        sim_path  = os.path.join(args.sim_dir, f"boot_{n:04d}.ppm")

        if not os.path.exists(mame_path):
            print(f"frame {n:4d}: MAME file missing, skipping")
            continue
        if not os.path.exists(sim_path):
            print(f"frame {n:4d}: sim file missing, skipping")
            continue

        mame_img = Image.open(mame_path).convert("RGB")
        sim_img  = Image.open(sim_path).convert("RGB")

        if mame_img.size != sim_img.size:
            mame_img = mame_img.resize(sim_img.size, Image.NEAREST)

        diff = ImageChops.difference(mame_img, sim_img)
        npx = sum(1 for px in diff.getdata() if px != (0, 0, 0))

        if npx == 0:
            print(f"frame {n:4d}: PASS")
            pass_count += 1
        else:
            print(f"frame {n:4d}: FAIL  {npx} pixels differ")
            fail_count += 1
            if first_fail is None:
                first_fail = n
            diff_amp = diff.point(lambda x: min(255, x * 8))
            diff_amp.save(os.path.join(args.sim_dir, f"diff_{n:04d}.png"))

    print(f"\n{pass_count} passed, {fail_count} failed", end="")
    if first_fail is not None:
        print(f" (first fail: frame {first_fail})")
    else:
        print()

if __name__ == "__main__":
    main()
