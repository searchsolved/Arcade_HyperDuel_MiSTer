#!/usr/bin/env python3
"""Compare an mra-tools .rom stream against the reference ROM builders.

Usage:
    python3 tools/check_mra_stream.py <stream.rom> <roms/hyprduel.zip>

Regions in the stream (per MRA comment):
    0x000000..0x07FFFF  main 68000 program (512 KB)
    0x080000..0x47FFFF  GFX ROM (4 MB)
    0x480000..0x4BFFFF  OKI samples (256 KB)
    total = 0x4C0000 = 4980736 bytes
"""
import sys
import zipfile
from pathlib import Path

MAIN_START = 0x000000
MAIN_END   = 0x080000
GFX_START  = 0x080000
GFX_END    = 0x480000
OKI_START  = 0x480000
OKI_END    = 0x4C0000
EXPECTED   = 0x4C0000

ROMS = ["ts_hyper-1.u74", "ts_hyper-2.u75", "ts_hyper-3.u76", "ts_hyper-4.u77"]


def build_mainrom(zf):
    even = zf.read("24.u24")
    odd  = zf.read("23.u23")
    assert len(even) == len(odd) == 0x40000
    out = bytearray(0x80000)
    for i in range(0x40000):
        out[i * 2 + 0] = even[i]
        out[i * 2 + 1] = odd[i]
    return bytes(out)


def build_gfxrom(zf):
    parts = [zf.read(n) for n in ROMS]
    assert all(len(p) == 0x100000 for p in parts)
    out = bytearray(0x400000)
    for n in range(0x100000 // 2):
        for k, p in enumerate(parts):
            out[n * 8 + k * 2 + 0] = p[n * 2 + 0]
            out[n * 8 + k * 2 + 1] = p[n * 2 + 1]
    return bytes(out)


def first_diff(a, b, label, base_offset=0):
    length = min(len(a), len(b))
    for i in range(length):
        if a[i] != b[i]:
            addr = base_offset + i
            ctx_a = a[max(0, i-4):i+8]
            ctx_b = b[max(0, i-4):i+8]
            print(f"  MISMATCH at stream offset 0x{addr:06X} (region offset 0x{i:06X})")
            print(f"    stream:    {ctx_a.hex(' ')}")
            print(f"    reference: {ctx_b.hex(' ')}")
            return i
    if len(a) != len(b):
        print(f"  LENGTH MISMATCH: stream region {len(a)}, reference {len(b)}")
        return length
    return None


def main():
    stream_path = sys.argv[1]
    zip_path    = sys.argv[2]

    stream = Path(stream_path).read_bytes()
    print(f"Stream: {len(stream)} bytes (expected {EXPECTED})")
    if len(stream) != EXPECTED:
        print(f"  WARNING: length mismatch ({len(stream)} vs {EXPECTED})")

    with zipfile.ZipFile(zip_path) as zf:
        ref_main = build_mainrom(zf)
        ref_gfx  = build_gfxrom(zf)
        ref_oki  = zf.read("97.u97")

    ok = True

    # Main ROM
    s_main = stream[MAIN_START:MAIN_END]
    print(f"\nMain ROM (0x{MAIN_START:06X}..0x{MAIN_END:06X}, {len(ref_main)} bytes):")
    d = first_diff(s_main, ref_main, "main", MAIN_START)
    if d is None:
        print("  OK - exact match")
    else:
        ok = False
        # count total mismatches
        mismatches = sum(1 for i in range(min(len(s_main), len(ref_main)))
                         if s_main[i] != ref_main[i])
        print(f"  Total mismatched bytes: {mismatches} / {len(ref_main)}")

    # GFX ROM
    s_gfx = stream[GFX_START:GFX_END]
    print(f"\nGFX ROM (0x{GFX_START:06X}..0x{GFX_END:06X}, {len(ref_gfx)} bytes):")
    d = first_diff(s_gfx, ref_gfx, "gfx", GFX_START)
    if d is None:
        print("  OK - exact match")
    else:
        ok = False
        mismatches = sum(1 for i in range(min(len(s_gfx), len(ref_gfx)))
                         if s_gfx[i] != ref_gfx[i])
        print(f"  Total mismatched bytes: {mismatches} / {len(ref_gfx)}")

    # OKI
    s_oki = stream[OKI_START:OKI_END]
    print(f"\nOKI ROM (0x{OKI_START:06X}..0x{OKI_END:06X}, {len(ref_oki)} bytes):")
    d = first_diff(s_oki, ref_oki, "oki", OKI_START)
    if d is None:
        print("  OK - exact match")
    else:
        ok = False
        mismatches = sum(1 for i in range(min(len(s_oki), len(ref_oki)))
                         if s_oki[i] != ref_oki[i])
        print(f"  Total mismatched bytes: {mismatches} / {len(ref_oki)}")

    print(f"\n{'ALL REGIONS MATCH' if ok else 'MISMATCHES FOUND'}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
