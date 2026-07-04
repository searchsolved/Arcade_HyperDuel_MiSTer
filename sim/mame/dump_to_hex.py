#!/usr/bin/env python3
"""Convert a MAME frame-dump directory into $readmemh hex files + snap.ppm.

Usage: dump_to_hex.py <frame_dir>
(gfxrom.hex is shared and built separately from gfxrom.bin)
"""
import struct
import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).parent.parent / "oracle"))
from i4220_oracle import REG_KEYS  # noqa: E402


def words(path):
    data = Path(path).read_bytes()
    return struct.unpack("<%dH" % (len(data) // 2), data)


def main(frame_dir):
    d = Path(frame_dir)
    for name in ["vram0", "vram1", "vram2", "palette", "spriteram", "tiletable"]:
        vals = words(d / f"{name}.bin")
        (d / f"{name}.hex").write_text("\n".join("%04x" % w for w in vals) + "\n")

    regs = {}
    for ln in (d / "regs.txt").read_text().splitlines():
        ln = ln.strip()
        if ln and not ln.startswith("#"):
            k, v = ln.split("=")
            regs[k.strip()] = int(v.strip(), 0)
    (d / "regs.hex").write_text(
        "\n".join("%04x" % (regs.get(k, 0) & 0xFFFF) for k in REG_KEYS) + "\n")

    img = Image.open(d / "snap.png").convert("RGB")
    w, h = img.size
    px = img.load()
    with open(d / "snap.ppm", "w") as f:
        f.write(f"P3\n{w} {h}\n255\n")
        for y in range(h):
            f.write(" ".join(f"{px[x, y][0]} {px[x, y][1]} {px[x, y][2]}"
                             for x in range(w)) + "\n")
    print(f"hex + snap.ppm written: {d}")


if __name__ == "__main__":
    main(sys.argv[1])
