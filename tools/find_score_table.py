#!/usr/bin/env python3
"""Hunt the real hiscore table in a shared3 memory dump.

Parses a $writememh dump of sr3 (16-bit words, word 0 = CPU 0xFE4000),
searches the byte image for the default top score 1540613 in plausible
BCD encodings, and prints CPU addresses plus context.

Usage: find_score_table.py <sr3.hex>
"""
import sys

BASE = 0xFE4000


def main(path):
    words = []
    for line in open(path):
        line = line.strip()
        if not line or line.startswith("//"):
            continue
        if line.startswith("@"):
            continue
        for tok in line.split():
            words.append(int(tok, 16) & 0xFFFF)
    # big-endian byte image (68000: word high byte = even address)
    img = bytearray()
    for w in words:
        img.append(w >> 8)
        img.append(w & 0xFF)
    print(f"{len(words)} words ({len(img)} bytes) from {path}")

    patterns = {
        "bcd 01 54 06 13": bytes([0x01, 0x54, 0x06, 0x13]),
        "bcd 00 15 40 61": bytes([0x00, 0x15, 0x40, 0x61]),
        "bcd 15 40 61 30": bytes([0x15, 0x40, 0x61, 0x30]),
        "ascii 1540613": b"1540613",
        "digits 01 05 04 00 06 01 03": bytes([1, 5, 4, 0, 6, 1, 3]),
    }
    hits = []
    for name, pat in patterns.items():
        start = 0
        while True:
            i = img.find(pat, start)
            if i < 0:
                break
            hits.append((i, name))
            start = i + 1
    if not hits:
        print("no default-score pattern found")
        return
    for off, name in sorted(hits):
        cpu = BASE + off
        ctx = img[max(0, off - 16):off + 32]
        print(f"\nCPU {cpu:06X} ({name}):")
        print("  " + " ".join(f"{b:02x}" for b in ctx))


if __name__ == "__main__":
    main(sys.argv[1])
