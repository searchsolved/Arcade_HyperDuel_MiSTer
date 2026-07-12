# Hyper Duel - MiSTer FPGA Core

Hyper Duel (Technosoft, 1993, TEC442-A board) arcade core for MiSTer,
built around the first FPGA implementation of the **Imagetek I4220**
video chip - the VDP behind the entire Metro Corp. arcade catalogue
(I4100/I4220/I4300 are close variants). No datasheet for this chip has
ever surfaced; the implementation was built against MAME as a
machine-checked oracle and verified beyond it against real hardware
(board photographs and original-PCB footage).

Status: pre-release, playable start to finish on hardware. The renderer
measures zero missed scanlines across long stress simulations; the
remaining pre-release work is tracked in `docs/plan_next_steps.md`.

## Accuracy

Read `docs/ACCURACY.md`. Every claim states its oracle, its method, its
result, and how to reproduce it. Highlights:

- Blitter word-identical to the reference algorithm; frames
  pixel-identical to MAME on reference scenes and boot states
- All 261 per-line raster interrupts serviced every frame (measured;
  software emulation currently misses ~14%)
- OKI sample clock measured from original-PCB footage: 2.000 MHz (the
  4 MHz crystal halved) - sample pitch is correct here and ~3% sharp
  in emulation, whose own source marks the value unverified
- Known deviations documented, including invisible ones, plus an honest
  list of what cannot be verified without a logic analyser on silicon

This core was developed with AI assistance throughout. Provenance is
irrelevant to correctness; the reproducible verification methodology is
the point.

## Research: what MAME gave us, what we verified, what's new

The only functional documentation of the I4220 is [MAME's
`imagetek_i4100.cpp`](https://github.com/mamedev/mame/blob/master/src/mame/shared/imagetek_i4100.cpp)
and the [`hyprduel.cpp`](https://github.com/mamedev/mame/blob/master/src/mame/technosoft/hyprduel.cpp)
driver - decades of black-box reverse engineering by Luca Elia, David
Haywood, Angelo Salese and contributors, vendored in `reference/mame/`.
That work is the foundation of this core: register semantics, tile and
sprite formats, the blitter's RLE scheme, the memory maps.

**Verified against MAME, machine-checked** (methods and reproduce
commands in [docs/ACCURACY.md](docs/ACCURACY.md)): blitter output word
for word, rendered frames pixel for pixel, full-system boot RAM state
at checkpoints, audio event timing.

**Verified against real hardware, beyond MAME**: all three board
oscillators read from photographs match the emulation's assumed values;
the I4220 part number read off the die; an original-PCB 1cc recording
analysed frame by frame (80,760 frames) proving the real board never
drops a scanline.

**New information this project established** (none of it previously
documented anywhere, to our knowledge):

- **The OKI M6295 clock is 2.000 MHz** (4 MHz crystal / 2), measured
  from PCB footage by sample-pitch ratio to 0.05%. MAME's value
  (2.0625 MHz, marked `not verified` in its own source) is ~3% sharp -
  every emulator and port inherits slightly wrong sample pitch.
- **The real mix balance**: samples peak at ~2.2x music RMS on the
  board's line output; MAME plays samples roughly 3x hotter.
- **The game requests a raster interrupt on all 261 lines per frame
  and real timing services every one**; write-log comparison shows
  MAME missing ~14% of them (visible as stepped parallax).
- **MAME's "many CRTC writes" mystery characterised**: the game's
  per-line handler maintains a line-indexed CRTC-horizontal write on
  every line, always (655k writes per attract cycle), with no visible
  effect on real hardware - safe for implementations to ignore.
- **The GFX bus is 64 bits wide** - four 16-bit mask ROMs read in
  parallel (implied by MAME's loading macro, confirmed by board
  photography) - which sets the sprite-bandwidth envelope any
  implementation must meet.
- **A measured slowdown profile of the real board** (from the footage):
  effective update rate drops to ~38 Hz at the stage-6 boss and
  ~46-47 Hz in two other stretches - reproduced here for free by
  cycle-accurate CPUs, and now checkable rather than anecdotal.
- Two further MAME-flagged unknowns remain open and measurable from
  footage: the exact refresh rate (its 60 Hz is a guess; ours derives
  60.01 Hz from the verified crystal) and the top-of-frame raster
  phase behaviour (docs/ACCURACY.md section 3.3).

## Architecture

- 2x fx68k @ 10 MHz (main + sub; the sub boots the MUSE sound driver
  from shared RAM, extracted from GFX ROM by the main CPU)
- Imagetek I4220 VDP in original SystemVerilog: scanline renderer
  (3 tilemap layers with map-word prefetch, zoomed/flipped sprites with
  prescan rejection and fetch/emit overlap), ROM-fed blitter FSM,
  register file, IRQ controller, video timing
- jt51 (YM2151) + jt6295 (OKI at the hardware-measured 15,151.5 Hz),
  mono mix calibrated against a real PCB line capture
- SDRAM: main ROM, 4 MB GFX (16-bit word streaming, multi-client
  arbiter), OKI samples, one shared work-RAM bank; everything else BRAM

## ROMs

This repository and the released core contain **no game ROM data**.
Load the core through `mra/Hyper Duel.mra` with a user-supplied MAME
`hyprduel` ROM set in `games/mame/`.

## Layout

```
docs/       specs (i4220_spec.md, hyprduel_system_spec.md), ACCURACY.md,
            plans and engineering handoffs
reference/  vendored MAME sources (BSD-3-Clause, the behavioural oracle)
rtl/        the core (i4220_*.sv, hyprduel_*.sv) + rtl/vendor/ cores
mister/     MiSTer shell, Quartus 17 project, framework files
sim/        Verilator harness: parity suites, full-system boot, soaks
mra/        MRA definition
tools/      ROM image builders, analysis tooling (tear scanner etc.)
builds/     reference RBFs from the bring-up ladder
```

## Building and verifying

- Simulation: Verilator 5.x on any host; `sim/README` describes the
  one-time oracle bootstrap (MAME 0.288 + Python 3 + your ROM set),
  then `make verify blit-verify render-verify mame-verify vdp-verify`
  runs the 22-check parity suite and `make boot` boots the game
- Synthesis: Quartus 17 project under `mister/`; timing is gated on a
  clean setup summary (every clock non-negative) before any release

## License and credits

GPL-3.0-or-later for the combined work; every vendored component keeps
its own license and headers in place. See `LICENSE` and `CREDITS.md`,
which credit the cores this project stands on - Jorge Cwik's fx68k,
Jose Tejada's jt51 and jt6295, the MiSTer framework - and the reference
material: MAME's Imagetek reverse engineering by Luca Elia, David
Haywood, Angelo Salese and contributors, without which this core could
not exist.
