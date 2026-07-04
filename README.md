# Hyper Duel - MiSTer FPGA Core

Work-in-progress MiSTer core for Hyper Duel (Technosoft, 1993, TEC442-A
board), the first FPGA implementation of the Imagetek I4220 VDP. Getting the
I4220 right also unlocks the wider Metro Corp. catalogue (same VDP family,
I4100/I4220/I4300 are pin-compatible variants).

No existing MiSTer or JTBIN core covers this game or any Imagetek VDP title
(checked 2026-07-04).

## Layout

```
docs/      i4220_spec.md            register-level VDP spec (the foundation document)
           hyprduel_system_spec.md  board-level spec: CPUs, maps, IRQs, ROMs, budgets
reference/ mame/                    vendored MAME sources used as hardware reference
rtl/       SystemVerilog (core)     - not started
sim/       Verilator testbenches    - not started
mra/       MRA + ROM layout         - not started
```

## Architecture (planned)

- 2x fx68k @ 10 MHz (main + sub; sub boots from shared RAM, no ROM)
- I4220 VDP: original SystemVerilog, scanline-pipelined
  (3 tilemap fetchers, sprite line engine with zoom, priority resolve,
  4096-color GRB555 palette, ROM-fed blitter FSM, IRQ controller)
- jt51 (YM2151) + jt6295 (OKI, 15625 Hz) -> mono mix
- SDRAM: main ROM 512 KB, GFX ROM 4 MB (4 clients via arbiter), OKI 256 KB
- BRAM: shared RAM 160 KB, palette/sprite/tiletable; VRAM placement is an
  open decision (see system spec sec 8)

## Milestones

- M0 DONE (2026-07-04): specs extracted from MAME source
- M1a DONE (2026-07-04): SV render model pixel-identical to the Python
      oracle (direct MAME port) on 4 synthetic scenes (sim/, `make verify`)
- M1b DONE (2026-07-04): pixel pipeline validated against REAL MAME frames
      (Lua state dumps + snapshots, sim/mame/). Frames 500/900/1500
      pixel-perfect (71,680/71,680 each: 4bpp text, 8bpp art, mixed).
      Frame 2200 diffs only in mid-frame scroll updates (raster effects;
      frame-level dumps cannot represent them; moves to M3).
      CAUGHT AND FIXED a real spec error: 4bpp left pixel = LOW nibble for
      tiles too (spec sec 3.4 corrected). ROM set verified (all CRCs match)
- M2 DONE (2026-07-04): blitter RTL (rtl/i4220_blitter.sv, synthesizable
      FSM with ROM req/valid handshake) word-identical to the MAME-port
      oracle on 2 scenes x 24 blits, incl. IRQ counts (`make blit-verify`)
- (M2 moved up: done, see above)
- M3 (in progress): scanline renderer RTL DONE 2026-07-04 -
      rtl/i4220_render.sv (real memory-port discipline, tile-row cache,
      streaming ROM fetches, serial zoom divider) is pixel-perfect vs the
      oracle on all synthetic scenes AND vs real MAME snapshots on all 3
      reference frames (`make render-verify mame-verify`). fx68k vendored.
      VDP TOP DONE same day: rtl/i4220_vdp.sv (full v2 bus decode, register
      file, IRQ controller, video timing, 4-bank line pipeline with
      one-line render lead, sprite double-buffer copy, 3-client ROM
      arbiter) verified END-TO-END: state loaded via the CPU bus, timing
      free-running, scan-out RGB captured - pixel-perfect vs MAME on all 3
      frames, buffered and unbuffered (`make vdp-verify`). Worst line 5,579
      cycles vs ~5,088 real-time budget: M4 closure is modest optimization.
      fx68k vendored + compiles under Verilator (one packed-struct patch,
      rtl/vendor/PATCHES.md).
      REMAINING: system top (2x fx68k + shared RAM + control latch + sound
      stubs), full-system Verilator boot to title screen
- M4: sound, Quartus/MiSTer framework integration, SDRAM arbiter, timing
- M5: hardware bring-up on MiSTer, MRA, real-ROM testing

## Toolchain

- Simulation: Verilator (macOS, local)
- Synthesis: Quartus Prime (needs Linux/Windows box or VM; NOT macOS)
- Reference: MAME (`hyprduel` driver) as behavioural oracle

## Licenses

- Vendored MAME reference sources: BSD-3-Clause (headers retained)
- fx68k / jt51 / jt6295 when vendored: their own licenses (GPL3 for JT cores)
- New RTL here: GPL3 (forced by JT core linkage)
