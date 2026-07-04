#!/usr/bin/env python3
"""I4220 frame-render oracle.

Direct port of MAME's imagetek_i4100.cpp draw path (screen_update ->
draw_foreground -> draw_layers/draw_tilemap/get_tile_pix + draw_sprites/
draw_spritegfx), kept deliberately structure-identical to the C++ so it can
serve as the reference model for the RTL. Reads a scene directory of binary
dumps, writes a P3 PPM.

Scene directory layout (little-endian u16 words unless noted):
  vram0.bin vram1.bin vram2.bin   128 KB each
  tiletable.bin                   2 KB
  palette.bin                     8 KB
  spriteram.bin                   4 KB
  gfxrom.bin                      raw bytes (any size)
  regs.txt                        key=value, see REG_KEYS
"""
import sys
import struct
from pathlib import Path

WIDTH, HEIGHT = 320, 224

# Exponential zoom table extracted from daitoride (imagetek_i4100.cpp:1188)
ZOOMTABLE = [
    0xAAC, 0x800, 0x668, 0x554, 0x494, 0x400, 0x390, 0x334,
    0x2E8, 0x2AC, 0x278, 0x248, 0x224, 0x200, 0x1E0, 0x1C8,
    0x1B0, 0x198, 0x188, 0x174, 0x164, 0x154, 0x148, 0x13C,
    0x130, 0x124, 0x11C, 0x110, 0x108, 0x100, 0x0F8, 0x0F0,
    0x0EC, 0x0E4, 0x0DC, 0x0D8, 0x0D4, 0x0CC, 0x0C8, 0x0C4,
    0x0C0, 0x0BC, 0x0B8, 0x0B4, 0x0B0, 0x0AC, 0x0A8, 0x0A4,
    0x0A0, 0x09C, 0x098, 0x094, 0x090, 0x08C, 0x088, 0x080,
    0x078, 0x070, 0x068, 0x060, 0x058, 0x050, 0x048, 0x040]

REG_KEYS = [
    "sprite_count", "sprite_priority", "sprite_yoffset", "sprite_xoffset",
    "sprite_color_code", "layer_priority", "background_color",
    "screen_xoffset", "screen_yoffset", "screen_ctrl",
    "window_y0", "window_x0", "window_y1", "window_x1", "window_y2", "window_x2",
    "scroll_y0", "scroll_x0", "scroll_y1", "scroll_x1", "scroll_y2", "scroll_x2",
]


def load_words(path):
    data = Path(path).read_bytes()
    # scene dumps are little-endian; MAME read_range dumps of the 68000
    # (big-endian) space pack values big-endian: set I4220_WORD_ENDIAN=big
    import os
    fmt = ">" if os.environ.get("I4220_WORD_ENDIAN") == "big" else "<"
    return list(struct.unpack(fmt + "%dH" % (len(data) // 2), data))


class I4220Oracle:
    def __init__(self, scene):
        scene = Path(scene)
        self.vram = [load_words(scene / f"vram{i}.bin") for i in range(3)]
        self.tiletable = load_words(scene / "tiletable.bin")
        self.palette_ram = load_words(scene / "palette.bin")
        self.spriteram = load_words(scene / "spriteram.bin")
        self.gfxrom = Path(scene / "gfxrom.bin").read_bytes()
        self.regs = {}
        for line in (scene / "regs.txt").read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                k, v = line.split("=")
                self.regs[k.strip()] = int(v.strip(), 0)
        for k in REG_KEYS:
            self.regs.setdefault(k, 0)

        r = self.regs
        self.layer_priority = [
            (r["layer_priority"] >> 0) & 3,
            (r["layer_priority"] >> 2) & 3,
            (r["layer_priority"] >> 4) & 3]
        self.layer_tile_select = [bool(r["screen_ctrl"] & (1 << (5 + i))) for i in range(3)]
        self.screen_blank = bool(r["screen_ctrl"] & 2)
        self.screen_flip = bool(r["screen_ctrl"] & 1)
        if self.screen_flip:
            raise NotImplementedError("flip screen out of scope for M1")

        # framebuffer of pens resolved to RGB at the end; store RGB directly
        self.bitmap = [[0] * WIDTH for _ in range(HEIGHT)]
        self.pribuf = [[0] * WIDTH for _ in range(HEIGHT)]

    # palette_device GRBx_555
    def pen(self, idx):
        v = self.palette_ram[idx & 0xFFF]
        g = (v >> 11) & 0x1F
        r = (v >> 6) & 0x1F
        b = (v >> 1) & 0x1F
        return ((r << 3 | r >> 2) << 16) | ((g << 3 | g >> 2) << 8) | (b << 3 | b >> 2)

    # ---- tilemap path (get_tile_pix, imagetek_i4100.cpp:1283) ----
    def get_tile_pix(self, layer, code, x, y, big):
        table_index = (code & 0x1FF0) >> 3
        tile = (self.tiletable[table_index] << 16) + self.tiletable[table_index | 1]

        if code & 0x8000:  # solid color tile
            return ((code & 0xF) != 0xF), self.pen(code & 0x0FFF)

        tilesize = 16 if big else 8
        color = (tile & 0x0FF00000) >> 16
        if (color & 0x00F0) == 0x00F0:  # 8bpp
            color &= 0x0F00
            trans = 0xFF
            tileshift = 3 if big else 1
            bpp8 = True
        else:
            trans = 0xF
            tileshift = 2 if big else 0
            bpp8 = False

        tile2 = (tile & 0xFFFFF) + ((code & 0xF) << tileshift)
        # element granularity is 32 bytes for every layout
        if tile2 >= len(self.gfxrom) // 32:
            return 0, 0

        flipxy = (code & 0x6000) >> 13
        if flipxy & 1:
            y = tilesize - y - 1
        if flipxy & 2:
            x = tilesize - x - 1

        base = tile2 * 32
        if bpp8:
            rowbytes = tilesize  # 8 (8x8x8) or 16 (16x16x8)
            d = self.gfxrom[base + y * rowbytes + x]
        else:
            rowbytes = tilesize // 2  # 4 or 8
            byte = self.gfxrom[base + y * rowbytes + (x >> 1)]
            # 4bpp packing: LEFT pixel = LOW nibble (same as sprites;
            # MAME layout xoffs are MSB-first bit numbers, verified against
            # real MAME frame dumps in M1b)
            d = (byte >> 4) if (x & 1) else (byte & 0xF)
        opaque = (d & trans) != trans
        return opaque, self.pen(d | color)

    def draw_tilemap(self, pcode, sx, sy, wx, wy, big, layer):
        tileshift = 4 if big else 3
        tilemask = (1 << tileshift) - 1
        width = 0x100 << tileshift
        height = 0x100 << tileshift
        windowwidth = width >> 2
        windowheight = height >> 3
        for y in range(HEIGHT):
            resy = sy + y - wy
            scrolly = resy & (windowheight - 1)
            srcline = (wy + scrolly) & (height - 1)
            srctilerow = srcline >> tileshift
            srcline &= tilemask
            for x in range(WIDTH):
                resx = sx + x - wx
                scrollx = resx & (windowwidth - 1)
                srccol = (wx + scrollx) & (width - 1)
                srctilecol = srccol >> tileshift
                pix_x = srccol & tilemask
                tileoffs = srctilecol + srctilerow * 0x100
                code = self.vram[layer][tileoffs]
                draw, rgb = self.get_tile_pix(layer, code, pix_x, srcline, big)
                if draw:
                    self.bitmap[y][x] = rgb
                    self.pribuf[y][x] = pcode

    def draw_layers(self, pri):
        for layer in (2, 1, 0):
            if pri == self.layer_priority[layer]:
                sy = self.regs[f"scroll_y{layer}"]
                sx = self.regs[f"scroll_x{layer}"]
                wy = self.regs[f"window_y{layer}"]
                wx = self.regs[f"window_x{layer}"]
                big = self.layer_tile_select[layer]
                self.draw_tilemap(3 - pri, sx, sy, wx, wy, big, layer)

    # ---- sprite path (draw_sprites, imagetek_i4100.cpp:1171) ----
    def draw_spritegfx(self, gfxstart, width, height, color, flipx, flipy,
                       sx, sy, scale, prival):
        if not scale:
            return
        is_8bpp = (color == 0xF)
        if is_8bpp:
            if gfxstart + width * height - 1 >= len(self.gfxrom):
                return
            trans = 0xFF
            color = 0
        else:
            if gfxstart + width // 2 * height - 1 >= len(self.gfxrom):
                return
            trans = 0xF
            color <<= 4
        palbase = (self.regs["sprite_color_code"] & 0x0F) << 8

        out_h = (scale * height + 0x8000) >> 16
        out_w = (scale * width + 0x8000) >> 16
        if not (out_w and out_h):
            return
        dx = (width << 16) // out_w
        dy = (height << 16) // out_h
        ex, ey = sx + out_w, sy + out_h
        x_index_base = (out_w - 1) * dx if flipx else 0
        y_index = (out_h - 1) * dy if flipy else 0
        if flipx:
            dx = -dx
        if flipy:
            dy = -dy
        if sx < 0:
            x_index_base += -sx * dx
            sx = 0
        if sy < 0:
            y_index += -sy * dy
            sy = 0
        ex = min(ex, WIDTH)
        ey = min(ey, HEIGHT)
        if ex <= sx:
            return
        for y in range(sy, ey):
            srow = gfxstart * (2 if not is_8bpp else 1) + (y_index >> 16) * width
            x_index = x_index_base
            for x in range(sx, ex):
                p = srow + (x_index >> 16)  # pixel index
                if is_8bpp:
                    c = self.gfxrom[p]
                else:
                    byte = self.gfxrom[p >> 1]
                    # sprite packing: LEFT pixel = LOW nibble (expand_gfx1)
                    c = (byte >> 4) if (p & 1) else (byte & 0xF)
                if c != trans:
                    if self.pribuf[y][x] <= prival:
                        self.bitmap[y][x] = self.pen(palbase + color + c)
                    self.pribuf[y][x] = 0xFF
                x_index += dx
            y_index += dy

    def draw_sprites(self):
        r = self.regs
        sprite_xoffs = r["sprite_xoffset"] - (r["screen_xoffset"] + 1)
        sprite_yoffs = r["sprite_yoffset"] - (r["screen_yoffset"] + 1)
        sprites = r["sprite_count"] % 512
        spri = r["sprite_priority"]
        layerpri_disable = bool(spri & 0x8000)
        global_masknum = spri & 0x1F
        global_pri = (spri & 0x0300) >> 8
        global_masklayer = (spri & 0x0C00) >> 10
        if sprites == 0:
            return

        order = range(sprites - 1, -1, -1) if not layerpri_disable else range(sprites)
        spritelist = []
        for j in order:
            w0, w1, attr, code = self.spriteram[j * 4:j * 4 + 4]
            curr_pri = (w0 & 0xF800) >> 11
            if curr_pri == 0x1F:
                continue
            spritelist.append(dict(
                curr_pri=curr_pri,
                flipx=attr & 0x8000, flipy=attr & 0x4000,
                color=(attr & 0xF0) >> 4,
                zoom=ZOOMTABLE[(w1 & 0xFC00) >> 10] << 8,
                x=w0 & 0x07FF, y=w1 & 0x03FF,
                width=(((attr >> 11) & 0x7) + 1) * 8,
                height=(((attr >> 8) & 0x7) + 1) * 8,
                gfxstart=32 * (((attr & 0x000F) << 16) + code)))

        for group in range(0x20):
            for s in spritelist:
                if s["curr_pri"] != group:
                    continue
                pri = global_pri
                if not layerpri_disable and s["curr_pri"] > global_masknum:
                    pri = global_masklayer
                self.draw_spritegfx(
                    s["gfxstart"], s["width"], s["height"], s["color"],
                    s["flipx"], s["flipy"],
                    s["x"] - sprite_xoffs, s["y"] - sprite_yoffs,
                    s["zoom"], 3 - pri)

    # ---- top (screen_update, imagetek_i4100.cpp:1456) ----
    def render(self):
        bg = self.pen(self.regs["background_color"] & 0x0FFF)
        for y in range(HEIGHT):
            for x in range(WIDTH):
                self.bitmap[y][x] = bg
                self.pribuf[y][x] = 0
        if not self.screen_blank:
            for pri in (3, 2, 1, 0):
                self.draw_layers(pri)
            self.draw_sprites()
        return self.bitmap

    def write_ppm(self, path):
        with open(path, "w") as f:
            f.write(f"P3\n{WIDTH} {HEIGHT}\n255\n")
            for row in self.bitmap:
                f.write(" ".join(f"{p >> 16 & 255} {p >> 8 & 255} {p & 255}"
                                 for p in row) + "\n")


if __name__ == "__main__":
    scene, out = sys.argv[1], sys.argv[2]
    o = I4220Oracle(scene)
    o.render()
    o.write_ppm(out)
    print(f"oracle: rendered {scene} -> {out}")
