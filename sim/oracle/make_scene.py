#!/usr/bin/env python3
"""Synthetic scene generator for I4220 RTL-vs-oracle verification.

Builds scene directories that exercise the documented semantics:
  scene1: 4bpp tiles, solid tiles, tile flips, window+scroll wrap, all
          layer priorities, no sprites
  scene2: 8bpp tiles and 16x16 layers mixed in
  scene3: sprite stress: sizes, zoom, flips, priorities, masking vs layers,
          sprite-vs-sprite blocking, 8bpp sprites, offscreen clipping
  scene4: everything at once, dense overlap

Also emits .hex versions of every memory for $readmemh.
"""
import random
import struct
import sys
from pathlib import Path

GFX_SIZE = 0x80000  # 512 KB is plenty for synthetic tiles


def w16(words):
    return struct.pack("<%dH" % len(words), *[w & 0xFFFF for w in words])


def write_hex(path, values, width):
    fmt = "%0{}x".format(width)
    path.write_text("\n".join(fmt % v for v in values) + "\n")


def build(scene_dir, *, with_ext=False, with_sprites=False, dense=False, seed=1):
    rng = random.Random(seed)
    d = Path(scene_dir)
    d.mkdir(parents=True, exist_ok=True)

    gfxrom = bytes(rng.randrange(256) for _ in range(GFX_SIZE))

    # palette: random but avoid pathological all-zero
    palette = [rng.randrange(0x10000) for _ in range(0x1000)]

    # tile table: 512 entries pointing at valid 32-byte units.
    # Keep headroom: max consumption per entry is 16 subtiles * 8 units
    # (16x16x8) * 32 bytes = 4 KB.
    max_unit = GFX_SIZE // 32 - 16 * 8
    tiletable = []
    for i in range(512):
        unit = rng.randrange(max_unit)
        if with_ext and i % 5 == 0:
            colorbyte = (rng.randrange(16) << 4) | 0x0F  # 8bpp marker
        else:
            colorbyte = rng.randrange(256)
            if (colorbyte & 0x0F) == 0x0F:
                colorbyte &= 0xF0  # keep 4bpp unless requested
        tiletable.append(((colorbyte & 0xFF) << 4 | (unit >> 16)) & 0xFFFF)
        tiletable.append(unit & 0xFFFF)

    # VRAM: mix of normal tiles (random flips), solid tiles, transparent solids
    def vram_word():
        r = rng.random()
        if r < 0.08:
            return 0x8000 | rng.randrange(0x1000)  # solid color
        if r < 0.12:
            return 0x8000 | (rng.randrange(0x100) << 4) | 0xF  # transparent solid
        return (rng.randrange(0x2000) << 3 | rng.randrange(16)) & 0x7FFF

    vram = [[vram_word() for _ in range(0x10000)] for _ in range(3)]

    regs = {
        "sprite_count": 0,
        "sprite_priority": 0,
        "sprite_yoffset": 0x100,
        "sprite_xoffset": 0x140,
        "sprite_color_code": rng.randrange(16),
        "layer_priority": (rng.randrange(4) << 4) | (rng.randrange(4) << 2) | rng.randrange(4),
        "background_color": rng.randrange(0x1000),
        "screen_xoffset": 159,
        "screen_yoffset": 111,
        "screen_ctrl": 0,
        }
    if with_ext:
        # 16x16 on layer 1 (and layer 2 when dense)
        regs["screen_ctrl"] |= (1 << 6) | ((1 << 7) if dense else 0)
    for layer in range(3):
        regs[f"window_y{layer}"] = rng.randrange(0x800)
        regs[f"window_x{layer}"] = rng.randrange(0x800)
        regs[f"scroll_y{layer}"] = rng.randrange(0x800)
        regs[f"scroll_x{layer}"] = rng.randrange(0x800)

    spriteram = [0] * 2048
    if with_sprites:
        n = 200 if dense else 60
        for i in range(n):
            pri = rng.choice([0, 1, 2, 3, 5, 8, 15, 30, 0x1F])
            x = rng.randrange(0x7FF) if dense else (0x140 - 160 + rng.randrange(-40, 360)) & 0x7FF
            y = rng.randrange(0x3FF) if dense else (0x100 - 112 + rng.randrange(-40, 264)) & 0x3FF
            zoom = rng.randrange(64)
            attr = (rng.randrange(2) << 15) | (rng.randrange(2) << 14) \
                | (rng.randrange(8) << 11) | (rng.randrange(8) << 8) \
                | (rng.choice(list(range(15)) + [15, 15]) << 4)
            # mostly in-ROM codes; ~1 in 10 out of range to exercise the
            # bounds-skip path (code units of 32 bytes vs GFX_SIZE)
            if rng.random() < 0.1:
                attr |= rng.randrange(1, 16)  # code high bits -> far out of range
                code = rng.randrange(0x10000)
            else:
                code = rng.randrange(0x3F00)
            spriteram[i * 4 + 0] = (pri << 11) | x
            spriteram[i * 4 + 1] = (zoom << 10) | y
            spriteram[i * 4 + 2] = attr
            spriteram[i * 4 + 3] = code
        regs["sprite_count"] = n
        regs["sprite_priority"] = (rng.randrange(2) << 15) | (rng.randrange(4) << 10) \
            | (rng.randrange(4) << 8) | rng.randrange(0x20)

    (d / "gfxrom.bin").write_bytes(gfxrom)
    (d / "palette.bin").write_bytes(w16(palette))
    (d / "tiletable.bin").write_bytes(w16(tiletable))
    (d / "spriteram.bin").write_bytes(w16(spriteram))
    for i in range(3):
        (d / f"vram{i}.bin").write_bytes(w16(vram[i]))
    (d / "regs.txt").write_text(
        "\n".join(f"{k}={v:#x}" for k, v in regs.items()) + "\n")

    # hex twins for $readmemh
    write_hex(d / "gfxrom.hex", list(gfxrom), 2)
    write_hex(d / "palette.hex", palette, 4)
    write_hex(d / "tiletable.hex", tiletable, 4)
    write_hex(d / "spriteram.hex", spriteram, 4)
    for i in range(3):
        write_hex(d / f"vram{i}.hex", vram[i], 4)
    from i4220_oracle import REG_KEYS
    write_hex(d / "regs.hex", [regs.get(k, 0) for k in REG_KEYS], 4)
    print(f"scene written: {d}")


if __name__ == "__main__":
    base = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("scenes")
    build(base / "scene1", seed=101)
    build(base / "scene2", with_ext=True, seed=202)
    build(base / "scene3", with_sprites=True, seed=303)
    build(base / "scene4", with_ext=True, with_sprites=True, dense=True, seed=404)
