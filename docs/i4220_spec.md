# Imagetek I4220 071 VDP - Register-Level Specification

Target: FPGA (SystemVerilog) implementation for the Hyper Duel MiSTer core.

Primary source: MAME `src/devices/video/imagetek_i4100.cpp` / `.h` (BSD-3-Clause,
Luca Elia, David Haywood, Angelo Salese), vendored in `reference/mame/`. Line
references below are to those files as fetched 2026-07-04. Everything in this
document is traced to that source or to `hyprduel.cpp`; items MAME itself does
not know are marked **UNVERIFIED**.

The I4220 is the second-generation Imagetek VDP (I4100 -> I4220 -> I4300).
Compared to the I4100 it adds 8bpp tiles and 16x16 tiles ("ext tiles",
`has_ext_tiles = true`) and relocates the sprite/layer registers to 0x797xx
(`v2_map`, imagetek_i4100.cpp:184). Hyper Duel instantiates it with a
26.666 MHz crystal (hyprduel.cpp:407).

## 1. Clocks and screen timing

- Crystal: 26.666 MHz (board OSC, hyprduel.cpp:12).
- Visible resolution: 320 x 224 (hyprduel.cpp:416).
- Total raster lines per frame: 262 (hyprduel.cpp:54, `RASTER_LINES`).
- Refresh: MAME uses 60 Hz flagged "Unknown/Unverified" (hyprduel.cpp:414).
- **UNVERIFIED** working assumption for the core: pixel clock = 26.666/4 =
  6.6665 MHz, hTotal = 424, vTotal = 262 -> 60.01 Hz. To be sanity-checked
  against PCB footage / MiSTer display compatibility. CRTC registers exist
  (section 8) but MAME ignores their values, so real hTotal is unknown.

## 2. Address map (v2_map, as seen by the 68000 at base 0x400000)

All offsets relative to the VDP base. 16-bit bus. From imagetek_i4100.cpp:184-229.

| Offset range      | Size    | Contents |
|-------------------|---------|----------|
| 0x00000 - 0x1FFFF | 128 KB  | Layer 0 VRAM (64K x 16) |
| 0x20000 - 0x3FFFF | 128 KB  | Layer 1 VRAM |
| 0x40000 - 0x5FFFF | 128 KB  | Layer 2 VRAM |
| 0x60000 - 0x6FFFF | 64 KB   | GFX ROM read window (banked, read only) |
| 0x70000 - 0x71FFF | 8 KB    | "Scratch RAM" (purpose unknown in MAME; implement as plain RAM) |
| 0x72000 - 0x73FFF | 8 KB    | Palette RAM, 4096 x 16, format GRBx_555 |
| 0x74000 - 0x74FFF | 4 KB    | Sprite RAM, 512 entries x 8 bytes (double-buffered, see 7) |
| 0x75000 - 0x75FFF | 4 KB    | Layer 0 RMW window (address-scrambled VRAM alias, see 2.1) |
| 0x76000 - 0x76FFF | 4 KB    | Layer 1 RMW window |
| 0x77000 - 0x77FFF | 4 KB    | Layer 2 RMW window |
| 0x78000 - 0x787FF | 2 KB    | Tile table ("tiles set"), 512 entries x 2 words |
| 0x78840 - 0x7884D | 14 B    | Blitter registers (write only) |
| 0x78850 - 0x78853 |         | Screen Y offset / X offset (see 6.3) |
| 0x78860 - 0x7886B |         | Window registers, 3 layers x (Y, X) |
| 0x78870 - 0x7887B |         | Scroll registers, 3 layers x (Y, X) |
| 0x78880 - 0x78881 |         | CRTC vertical (w/o, gated by unlock) |
| 0x78890 - 0x78891 |         | CRTC horizontal (w/o, gated by unlock) |
| 0x788A0 - 0x788A1 |         | CRTC unlock, bit 0 |
| 0x788A3 (byte)    |         | IRQ cause (r) / IRQ acknowledge (w) |
| 0x788A5 (byte)    |         | IRQ enable mask (w) |
| 0x788AA - 0x788AB |         | GFX ROM bank for the 0x60000 window |
| 0x788AC - 0x788AD |         | Screen control (see 9) |
| 0x79700 - 0x79713 |         | Sprite/layer registers, v2 location (see 6/7) |
| 0x78800 - 0x78813 |         | Puzzlet-compat mirror of most 0x797xx regs (imagetek_i4100.cpp:220-228). Note 0x78802 (sprite priority) is NOT mirrored. Implement the mirror; Hyper Duel writes its IRQ enable at 0x4788A5 regardless. |

v2 sprite/layer register block (imagetek_i4100.cpp:213-219):

| Offset  | Register |
|---------|----------|
| 0x79700 | Sprite count |
| 0x79702 | Sprite priority / masking control |
| 0x79704 | Sprite Y offset |
| 0x79706 | Sprite X offset |
| 0x79708 | Sprite color code start |
| 0x79710 | Layer priorities |
| 0x79712 | Background color (12-bit pen) |

All registers are readable back except where noted write-only.

### 2.1 RMW VRAM windows

The CPU-facing 4 KB windows at 0x75000/0x76000/0x77000 alias layer VRAM with
this address scramble (imagetek_i4100.cpp:565-568):

```
word_offset_in_vram = (o & 0x3F) | ((o & ~0x3F) * 4)     // o = word offset in window
```

i.e. rows of 64 words are spread every 256 words. This exposes the top-left
512x256 pixel region of the big tilemap as a compact window. Games mostly use
the blitter for VRAM, but Hyper Duel's driver family also touches these.

## 3. VRAM / tilemap geometry

From imagetek_i4100.cpp:36-57 and the draw code:

- Each layer VRAM = 65,536 x 16-bit tile codes = a 256 x 256 grid of tiles
  ("big layer": 2048 x 2048 px with 8x8 tiles, 4096 x 4096 px with 16x16).
- Only a window of 64 x 32 tiles is displayed (512 x 256 px at 8x8,
  1024 x 512 px at 16x16), carved from the big layer.
- Tile addressing within the big layer: `tile_offset = col + row * 256`.

### 3.1 Per-pixel source address derivation (no flip)

From draw_tilemap (imagetek_i4100.cpp:1389-1407). For screen pixel (x, y),
layer scroll (sx, sy), window origin (wx, wy), all in big-layer pixel coords:

```
eff_y   = wy + ((sy - wy + y) & (window_h - 1))    // window_h = 256 (8x8) or 512 (16x16)
eff_x   = wx + ((sx - wx + x) & (window_w - 1))    // window_w = 512 (8x8) or 1024 (16x16)
row     = (eff_y & (big_h - 1)) >> tile_shift       // tile_shift = 3 or 4
col     = (eff_x & (big_w - 1)) >> tile_shift
code    = vram[layer][col + row * 256]
pix_x   = eff_x & tile_mask
pix_y   = eff_y & tile_mask
```

Screen-flip inverts the pixel walk (imagetek_i4100.cpp:1391-1403) and uses
negated per-layer scroll offsets. Hyper Duel is ROT0 with MACHINE_NO_COCKTAIL;
flip is a DSW but low priority for first light.

Per-game scroll deltas (`set_tmap_xoffsets` etc.) are NOT set by hyprduel.cpp,
so all scrolldx/dy = 0 for this core.

### 3.2 Tile code word format (VRAM entry)

From get_tile_pix (imagetek_i4100.cpp:1283-1344):

```
bit 15      = 1: solid-color tile. Pen = code & 0x0FFF.
              Transparent (skipped) if (code & 0xF) == 0xF, else opaque fill.
bit 15      = 0: normal tile:
  bits 14-13 = flip: bit 13 = flip Y, bit 14 = flip X
  bits 12-4  = tile table entry index (0..511)
  bits 3-0   = sub-tile index within the entry's group of 16
```

### 3.3 Tile table entry (2 words, 512 entries at 0x78000)

From imagetek_i4100.cpp:1346-1364 and get_tile_pix:

```
word 0: bits 11-4 = color code (0x00-0xFF), bits 3-0 = tile number high bits
word 1: tile number low 16 bits
tile32 = ((word0 & 0xF) << 16) | word1        // in 32-byte units (see 3.4)
```

- 4bpp tile: gfx address = (tile32 + subtile) * 32 bytes; pen = pixel | (color << 4).
- 8bpp mode: if (color & 0xF0) == 0xF0, tile is 8bpp; palette bank =
  color & 0x0F00 applied as pen = pixel | ((color & 0x0F00) ... expressed in
  MAME as color &= 0x0F00 then pen = data | color); sub-tile step doubles
  (tileshift + 1) because an 8bpp tile is 64 bytes = 2 units.
- 16x16 mode (per layer, screen control bits): sub-tile step x4 (4bpp) or x8
  (8bpp); tile is 128 / 256 bytes.
- Transparent pixel value: 0xF (4bpp) or 0xFF (8bpp). Solid-color tiles: see 3.2.

### 3.4 GFX ROM pixel packing

The universal tile-number unit is 32 bytes (one 8x8x4 tile).

- 4bpp packing, BOTH tilemaps and sprites: row-major, 4 bits/pixel, LEFT
  pixel = LOW nibble of each byte. VERIFIED against real MAME frame dumps
  (M1b, warning-screen text glyphs decoded both ways vs snapshot).
  Historical note: an earlier revision of this spec claimed tiles were
  high-nibble-first from reading layout_8x8x4's xoffs {4,0,12,8,...}; that
  misread MAME's convention, where layout bit offsets are MSB-first (bit 0
  = leftmost), so offset 4 is the LOW nibble. expand_gfx1 (sprites) makes
  the same order explicit: expanded[even] = src & 0xF.
- 8bpp data: 1 byte per pixel, row-major, byte-linear in the region
  (verified by the pixel-perfect 8bpp title frame in M1b).

## 4. Blitter

Registers at 0x78840 (imagetek_i4100.cpp:778-1005). All values big-endian
16-bit register pairs forming 32-bit values:

| Offset  | Value |
|---------|-------|
| 0x78840 | Destination tilemap (32-bit): 1, 2, or 3 (= layer 0/1/2). Other values: no-op (warning). |
| 0x78844 | Source address (32-bit byte offset into GFX ROM) |
| 0x78848 | Destination address x 128 (32-bit; dst word offset = value >> 8) |
| 0x7884C | Trigger: writing here starts the blit |

Semantics:

- The blitter writes ONE BYTE LANE of the destination VRAM words. Bit 7 of the
  raw destination value selects the lane: set -> low byte (mask 0x00FF,
  shift 0), clear -> high byte (mask 0xFF00, shift 8). Two blits fill a
  tilemap (even then odd bytes).
- Destination advances within a 256-word row: `dst = (dst & ~0xFF) | ((dst + 1) & 0xFF)`
  i.e. wraps within the row, never carries into the row bits, and is masked
  to 0xFFFF overall.
- Opcode stream is read from GFX ROM at the source address, one byte at a
  time: top 2 bits = opcode, `count = ((~b) & 0x3F) + 1` (NOTE: low 6 bits
  are INVERTED, this is easy to get wrong).

| Opcode (bits 7-6) | Action |
|-------------------|--------|
| 00 | If whole byte == 0x00: STOP, schedule blit-done IRQ. Else: copy next `count` bytes from ROM to successive destinations. |
| 01 | Read one byte, write `count` incrementing values (b, b+1, ...). |
| 10 | Read one byte, write it `count` times. |
| 11 | If whole byte == 0xC0: skip to next row (+0x100 words), restoring the starting column (`(dst_reg >> 8) & 0xFF`). Else: skip `count` destination words. |

- Source offset wraps modulo GFX ROM size.
- Blit-done IRQ: MAME fires it 500 us after the stop opcode (blit_done timer,
  imagetek_i4100.cpp:933). Real chip timing unknown; core should raise it
  when the FSM drains, optionally with a programmable delay if games prove
  sensitive. Hyper Duel uses blit IRQ level 2 (hyprduel.cpp:409).
- MAME executes the whole blit instantly at trigger time. The FSM version
  must arbitrate GFX ROM and VRAM access against rendering; games write
  blits mostly during vblank/level transitions.

## 5. GFX ROM CPU window

- 0x788AA = bank register (16-bit). Window at 0x60000 exposes 64 KB:
  `rom_byte = (window_word_offset * 2) + 0x10000 * bank`, big-endian word
  reads (imagetek_i4100.cpp:738-751). Reads past ROM size return 0xFFFF.
- Hyper Duel's GFX region is 4 MB, so banks 0x00-0x3F.

## 6. Layer / screen registers

### 6.1 Layer priority (0x79710)

imagetek_i4100.cpp:627-651:

```
bits 5-4 = layer 2 priority, bits 3-2 = layer 1, bits 1-0 = layer 0
0 = frontmost ... 3 = backmost
```

Draw rule (imagetek_i4100.cpp:1424-1454): iterate pri 3 -> 0; within equal
pri draw layer 2 first, layer 0 last (layer 0 wins ties). Rendered pixels
stamp a priority-buffer code `3 - pri` used by sprite masking.

### 6.2 Background color (0x79712)

12-bit pen index filling the screen before layers (imagetek_i4100.cpp:659-671,
1458). Writes with bits 15-12 set are masked (warning in MAME).

### 6.3 Screen X/Y offset (0x78852 / 0x78850)

Hold (visible/2 - 1) style values: sprite math uses
`max_x = (screen_xoffset + 1) * 2` (imagetek_i4100.cpp:1173-1176), so for
320x224 expect xoffset = 159, yoffset = 111. They act as the screen center
reference for sprite placement (and flip). Verify actual written values in
sim logging at first boot.

### 6.4 Window / scroll registers

0x78860: window, 3 layers x 2 words, order (Y, X) per layer (draw_layers reads
`m_window[layer*2+0]` as wy, `+1` as wx; imagetek_i4100.cpp:1432-1433).
0x78870: scroll, same ordering (sy, sx). Units: big-layer pixels.

## 7. Sprites

### 7.1 Sprite RAM entry (8 bytes, 512 entries max)

imagetek_i4100.cpp:1143-1236:

```
word 0: bits 15-11 = priority (0 = front, 0x1F = sprite disabled/skipped)
        bits 10-0  = X (11 bits)
word 1: bits 15-10 = zoom index (into 64-entry exponential table)
        bits 9-0   = Y (10 bits)
word 2: bit 15 = flip X, bit 14 = flip Y
        bits 13-11 = width/8 - 1  (8..64 px in 8 px steps)
        bits 10-8  = height/8 - 1
        bits 7-4   = color
        bits 3-0   = code high bits
word 3: code low 16 bits
gfxstart_bytes = 32 * ((code_high << 16) | code_low)
```

- 8bpp sprite mode: color == 0xF selects 8bpp pixels (1 byte/px), palette
  offset 0, transparent = 0xFF (imagetek_i4100.cpp:1022-1041).
- 4bpp: transparent = 0xF, pen = (color << 4) + pixel.
- Sprite palette base: `(sprite_color_code & 0x0F) << 8` added on top
  (imagetek_i4100.cpp:1043), register 0x79708.
- Position: `screen_x = X - (sprite_xoffset - (screen_xoffset + 1))`, same for
  Y (imagetek_i4100.cpp:1175-1176, 1256-1257).
- Zoom: one value for both axes; table of 64 16-bit factors extracted from
  the daitoride ROM (imagetek_i4100.cpp:1188-1195), scale = table[i] << 8 as
  16.16 fixed point where 0x100 -> 1.0x. Output size = (scale * dim + 0x8000) >> 16
  with source stepping dx = (dim << 16) / out_dim. Replicate exactly, table
  goes in a small ROM.
- Sprite count register (0x79700): number of entries to process, modulo 512.
- Sprite RAM is double-buffered for Hyper Duel: buffer copies at vblank end,
  rendering uses the buffered copy, CPU reads/writes the live copy
  (hyprduel.cpp:410 set_spriteram_buffered(true), imagetek_i4100.cpp:1465-1475).

### 7.2 Sprite priority register (0x79702)

imagetek_i4100.cpp:593-604:

```
bit 15    = disable sprite<->layer priority ("layerpri_disable")
bits 11-10 = masked-layer priority value (global_masklayer)
bits 9-8  = sprite priority vs layers (global_pri)
bits 4-0  = sprite mask number (global_masknum)
```

Behaviour (imagetek_i4100.cpp:1181-1275):

- Sprites are grouped by their 5-bit per-sprite priority and drawn group
  0 -> 0x1F.
- Effective layer-compare value: `pri = global_pri`, except when
  layerpri_disable == 0 AND sprite_pri > global_masknum, then
  `pri = global_masklayer`.
- Pixel test vs layers: draw if `pribuf <= (3 - pri)`; after ANY opaque sprite
  pixel is processed, pribuf is set to 0xFF, so earlier-drawn sprites always
  mask later ones at that pixel.
- Sprite RAM traversal for list build: BACKWARD (last entry first) when
  layerpri_disable == 0, FORWARD when set. Within one priority group, draw
  order = list order. Get this exactly right or sprite stacking breaks.

## 8. CRTC registers

0x788A0 bit 0 = unlock; while unlocked, writes to 0x78880 (vert) and 0x78890
(horz) latch values (imagetek_i4100.cpp:753-776). MAME ignores the contents
("needs so many writes before actual parameters", header TODO). The core will
generate fixed 320x224/262-line timing and simply log CRTC writes; revisit
only if the game switches video modes (it does not appear to).

## 9. Screen control (0x788AC)

imagetek_i4100.cpp:692-727:

```
bit 15    = unknown (karatour POST)
bits 10-8 = external control pins (unused by Hyper Duel; drive nothing)
bits 7-5  = 16x16 tile select for layers 2/1/0
bit 1     = blank screen (render background color / black, MAME renders bg fill only)
bit 0     = flip screen
```

## 10. Interrupts

imagetek_i4100.cpp:444-547. 8-bit cause register, per-bit sources:

```
bit 0 = vblank        bit 1 = hblank/hsync    bit 2 = blitter done
bit 3 = ?             bit 4 = ? (raster, set every line in hyprduel driver)
bit 5 = ? (vblank-window flag in hyprduel driver, cleared ~2500 us after)
bits 6-7 = unused
```

- Enable register 0x788A5: 1 = MASKED, 0 = enabled. IRQ output asserted while
  `(cause & ~enable) != 0` (level, not edge; imagetek_i4100.cpp:504-507).
- Acknowledge: write 1s to 0x788A3; only bits 4-0 clearable by ack
  (imagetek_i4100.cpp:470-482).
- Hyper Duel wiring (hyprduel.cpp:115-147, 405-420): VDP IRQ output ->
  main 68000 IPL3. The scanline timer sets cause bits 1 and 4 every line
  1..261, and bits 0 and 5 at line 0 (vblank), with bit 5 auto-cleared about
  2500 us later (a "vblank in progress" style flag the game polls; exact
  duration is a MAME guess). Additionally the driver pulses main IPL2
  directly at vblank, OUTSIDE the VDP. The game's int-enable writes are
  filtered in MAME with `data | 0xFD` (only the hblank source ever enabled
  on IPL3). Implement the VDP registers faithfully; replicate the driver's
  external IPL2-at-vblank wiring in the top level; treat the 0xFD filter and
  the bit-5 duration as behaviour to re-derive in sim (flagged RISK).
- Note MAME's header TODO: "hyprduel uses scanline attribute which crawls to
  unusable state with current video routines". The game does per-scanline
  register work off the hblank IRQ. A scanline-native FPGA core evaluates
  scroll/window registers per line by construction, so this should come out
  BETTER than MAME; it also means frame-level reference dumps of those
  registers are insufficient, line-level behaviour must be checked visually.

## 11. Palette

- 4096 entries x 16 bits at 0x72000, format GRBx_555
  (imagetek_i4100.cpp:335-339): bits 15-11 = G, 10-6 = R, 5-1 = B, bit 0 unused.
- Pen space: 256 color codes x 16 pens (4bpp) overlaid with 16 banks x 256
  (8bpp).

## 12. Compose order summary (per frame / per pixel)

1. Fill with background_color pen.
2. If screen_blank: stop (blank frame).
3. Tilemaps pri 3 -> 0 (layer 2 -> 0 within a pri), stamping pribuf = 3 - pri.
4. Sprites in priority groups 0 -> 0x1F with the masking rules of 7.2.

For hardware this becomes a per-scanline pipeline: 3 tilemap fetchers + sprite
line engine -> priority resolve -> palette -> RGB555 out. MAME's painter's
algorithm is a reference model only; the priority-buffer semantics above
define the per-pixel resolve rules the pipeline must reproduce.

## 13. Known-unknowns register (running list)

| Item | Risk | Plan |
|------|------|------|
| Exact pixel clock / hTotal | Low (display compat) | Assume /4; compare against PCB video footage |
| Blit-done IRQ latency | Medium (game may race) | Parameterize; test boot + level loads |
| Bit 5 IRQ flag duration (2500 us guess) | Medium | Trace game code reads in sim |
| int_enable OR 0xFD MAME filter | Medium | Implement raw; compare IRQ behaviour |
| Tile vs sprite nibble order opposition | High if wrong | Verify both in first frame-dump milestone |
| Scratch RAM (0x70000) real purpose | Low | Plain RAM; MAME service-mode color quirk noted upstream |
| OKI pin7/clock (MAME: unverified) | Low (audio pitch) | 132-divider, 15625 Hz; ear-check vs PCB recordings |
