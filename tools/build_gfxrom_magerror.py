#!/usr/bin/env python3
"""Build the 4 MB VDP GFX region from roms/magerror.zip.

Same LOAD64_WORD interleave as hyprduel (same board layout, same u74-u77
positions), different ROM filenames.
"""
import sys
import zipfile
from pathlib import Path

ROMS = ["mr93046-02.u74", "mr93046-04.u75", "mr93046-01.u76", "mr93046-03.u77"]


def main(zip_path, out_path):
    with zipfile.ZipFile(zip_path) as z:
        parts = [z.read(n) for n in ROMS]
    assert all(len(p) == 0x100000 for p in parts)
    out = bytearray(0x400000)
    for n in range(0x100000 // 2):
        for k, p in enumerate(parts):
            out[n * 8 + k * 2 + 0] = p[n * 2 + 0]
            out[n * 8 + k * 2 + 1] = p[n * 2 + 1]
    Path(out_path).parent.mkdir(parents=True, exist_ok=True)
    Path(out_path).write_bytes(bytes(out))
    print(f"gfxrom: {out_path} ({len(out)} bytes)")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
