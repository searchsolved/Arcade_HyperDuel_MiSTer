#!/usr/bin/env python3
"""Build the 4 MB VDP GFX region from roms/hyprduel.zip.

MAME loads the four 1 MB ROMs with ROM_LOAD64_WORD: each ROM supplies one
16-bit word (2 bytes, file order) of every 64-bit group:
  region[n*8 + 0..1] = ts_hyper-1[n*2 .. n*2+1]
  region[n*8 + 2..3] = ts_hyper-2[...]
  region[n*8 + 4..5] = ts_hyper-3[...]
  region[n*8 + 6..7] = ts_hyper-4[...]
"""
import sys
import zipfile
from pathlib import Path

ROMS = ["ts_hyper-1.u74", "ts_hyper-2.u75", "ts_hyper-3.u76", "ts_hyper-4.u77"]


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
