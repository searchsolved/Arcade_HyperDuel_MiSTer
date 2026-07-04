#!/usr/bin/env python3
"""M1b: render a MAME state dump through the oracle and diff against
MAME's own snapshot of the same frame.

Usage: compare_frame.py <frame_dir> <gfxrom.bin>
"""
import shutil
import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).parent.parent / "oracle"))
from i4220_oracle import I4220Oracle, WIDTH, HEIGHT  # noqa: E402


def main(frame_dir, gfxrom):
    frame_dir = Path(frame_dir)
    if not (frame_dir / "gfxrom.bin").exists():
        shutil.copy(gfxrom, frame_dir / "gfxrom.bin")

    o = I4220Oracle(frame_dir)
    o.render()
    o.write_ppm(frame_dir / "oracle.ppm")

    img = Image.open(frame_dir / "snap.png").convert("RGB")
    if img.size != (WIDTH, HEIGHT):
        print(f"  snapshot is {img.size}, resizing expectation mismatch")
        return 2
    px = img.load()

    bad = 0
    first = []
    for y in range(HEIGHT):
        for x in range(WIDTH):
            p = o.bitmap[y][x]
            ours = (p >> 16 & 255, p >> 8 & 255, p & 255)
            if ours != px[x, y]:
                bad += 1
                if len(first) < 8:
                    first.append((x, y, px[x, y], ours))
    total = WIDTH * HEIGHT
    if bad:
        print(f"  DIFF {frame_dir.name}: {bad}/{total} px "
              f"({100 * bad / total:.2f}%)")
        for x, y, m, us in first:
            print(f"    ({x},{y}) mame={m} oracle={us}")
    else:
        print(f"  MATCH {frame_dir.name}: {total}/{total} px identical")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
