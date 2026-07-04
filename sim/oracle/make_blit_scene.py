#!/usr/bin/env python3
"""Blit scene generator.

Crafts GFX ROM opcode streams + blit register sets covering:
  - all 4 opcodes, random counts 1..63
  - COPY runs crossing the 256-word row wrap
  - skip-to-next-row (0xC0) with non-zero column restore
  - both byte lanes (dst bit 7 set/clear), random ignored low dst bits
  - FILL-INC with 8-bit overflow (b2 past 0xFF)
  - opcode stream wrapping past the end of GFX ROM
  - invalid destination tilemap (0, 4) -> whole blit is a no-op, no IRQ
  - destination word offsets near 0xFFFF
"""
import random
import struct
import sys
from pathlib import Path

GFX_SIZE = 0x80000


def enc(op, count):
    assert 1 <= count <= 63 or (op in (0, 3) and count is None)
    return (op << 6) | ((~(count - 1)) & 0x3F)


def gen_stream(rng, force=None):
    """Random opcode stream ending in STOP. Returns bytes."""
    out = bytearray()
    n_ops = rng.randrange(4, 24)
    for i in range(n_ops):
        kind = force[i] if force and i < len(force) else \
            rng.choice(["copy", "copy", "fillinc", "fillfix", "skip", "skipline"])
        if kind == "copy":
            c = rng.randrange(1, 64)
            out.append(enc(0, c))
            out.extend(rng.randrange(256) for _ in range(c))
        elif kind == "fillinc":
            c = rng.randrange(1, 64)
            out.append(enc(1, c))
            out.append(rng.choice([rng.randrange(256), 0xF8]))  # 0xF8 forces 8-bit overflow
        elif kind == "fillfix":
            c = rng.randrange(1, 64)
            out.append(enc(2, c))
            out.append(rng.randrange(256))
        elif kind == "skip":
            out.append(enc(3, rng.randrange(1, 64)))
        else:  # skipline
            out.append(0xC0)
    out.append(0x00)  # STOP
    return bytes(out)


def build(scene_dir, seed):
    rng = random.Random(seed)
    d = Path(scene_dir)
    d.mkdir(parents=True, exist_ok=True)

    rom = bytearray(rng.randrange(256) for _ in range(GFX_SIZE))
    vram = [[rng.randrange(0x10000) for _ in range(0x10000)] for _ in range(3)]

    blits = []
    cursor = 0x1000
    for i in range(24):
        force = None
        if i == 0:
            force = ["copy", "skipline", "copy", "fillinc", "skipline", "fillfix"]
        stream = gen_stream(rng, force)

        if i == 5:
            # stream wrapping past ROM end
            src = GFX_SIZE - rng.randrange(1, min(16, len(stream)))
            for k, b in enumerate(stream):
                rom[(src + k) % GFX_SIZE] = b
        else:
            src = cursor
            rom[src:src + len(stream)] = stream
            cursor += len(stream) + rng.randrange(4, 32)

        tmap = rng.choice([1, 2, 3])
        if i in (7, 15):
            tmap = rng.choice([0, 4])  # invalid -> no-op, no IRQ

        word_off = rng.randrange(0x10000)
        if i == 2:
            word_off = 0xFFF8   # near top: wrap behaviour under masking
        if i == 3:
            word_off = (word_off & ~0xFF) | 0xF8  # copy run crosses row wrap
        lane = rng.randrange(2)
        dst = (word_off << 8) | (lane << 7) | rng.randrange(0x80)  # low bits ignored

        blits.append((tmap, src, dst))

    (d / "gfxrom.bin").write_bytes(bytes(rom))
    for i in range(3):
        (d / f"vram{i}.bin").write_bytes(
            struct.pack("<65536H", *vram[i]))
        (d / f"vram{i}.hex").write_text(
            "\n".join("%04x" % w for w in vram[i]) + "\n")
    (d / "gfxrom.hex").write_text("\n".join("%02x" % b for b in rom) + "\n")
    (d / "blits.txt").write_text(
        "\n".join(f"{t:x} {s:x} {dd:x}" for t, s, dd in blits) + "\n")
    # flat 32-bit words for $readmemh: tmap, src, dst per blit
    (d / "blits.hex").write_text(
        "\n".join(f"{v:08x}" for t, s, dd in blits for v in (t, s, dd)) + "\n")
    print(f"blit scene written: {d} ({len(blits)} blits)")


if __name__ == "__main__":
    base = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("blitscenes")
    build(base / "blit1", seed=1001)
    build(base / "blit2", seed=2002)
