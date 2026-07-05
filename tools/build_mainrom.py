#!/usr/bin/env python3
"""Build the main CPU ROM image from roms/hyprduel.zip.

24.u24 = even bytes, 23.u23 = odd bytes (ROM_LOAD16_BYTE). Output is a
$readmemh file of 16-bit words (big-endian 68000 view: word = even<<8|odd).
"""
import sys
import zipfile
from pathlib import Path


def main(zip_path, out_path):
    with zipfile.ZipFile(zip_path) as z:
        even = z.read("24.u24")
        odd = z.read("23.u23")
    assert len(even) == len(odd) == 0x40000
    words = [(even[i] << 8) | odd[i] for i in range(0x40000)]
    Path(out_path).parent.mkdir(parents=True, exist_ok=True)
    Path(out_path).write_text("\n".join("%04x" % w for w in words) + "\n")
    print(f"mainrom: {out_path} ({len(words)} words)")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
