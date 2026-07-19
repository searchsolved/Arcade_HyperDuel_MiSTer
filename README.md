# Hyper Duel - MiSTer FPGA Core

Hyper Duel (Technosoft, 1993, TEC442-A board) arcade core for MiSTer,
built around the first FPGA implementation of the **Imagetek I4220**
video chip - the VDP behind the entire Metro Corp. arcade catalogue
(I4100/I4220/I4300 are close variants). No datasheet for this chip has
ever surfaced: the implementation was built against MAME as a
machine-checked oracle, then checked beyond it against the strongest
hardware evidence obtainable without probing a live board -
photographs of the PCB and die for the clock tree, bus widths and part
numbers, and original-PCB recordings analysed down to individual
scanlines and spectral lines. To be clear about the claim: no logic
analyser or scope has been near a real TEC442-A for this project.
[docs/ACCURACY.md](docs/ACCURACY.md) states which claims rest on which
evidence, and what remains unverifiable without one.

That verification went deep enough to surface things nobody had
documented:

- **A MAME bug, found and fixed here.** The CRTC registers MAME has
  always logged and ignored turn out to program the monitor's visible
  window. The well-known top-of-screen scroll glitch in emulation of
  this game is hidden scratch lines the real monitor never shows - and
  the same mechanism likely affects the whole Metro family in MAME.
  This core implements the window correctly; the full register decode
  and an upstream bug report ship in `docs/`.
- **The board's true refresh rate.** It runs at 60.24 Hz, not 60 Hz -
  measured three independent ways from two different PCBs, including
  the board's own refresh-locked electrical hum isolated out of the
  audio of PCB recordings.
- **The OKI sample clock is 2.000 MHz** (emulation has been running
  about 3 percent sharp), and the sample-to-music mix on real boards
  is hotter than emulation plays it.

The CPUs and sound are proven cycle-accurate cores: two of Jorge
Cwik's **fx68k** (cycle-exact 68000), Jose Tejada's **jt51** (YM2151)
and **jt6295** (OKI M6295). The I4220 RTL, system glue, SDRAM
controller and MiSTer shell are new for this project, written in
collaboration with Anthropic's Claude (Fable 5) - and because
AI-assisted RTL deserves extra scrutiny, nothing here rests on trust:
every accuracy claim is machine-checked, and the full Verilator parity
suite, stress soaks and analysis tooling ship in this repo so each one
can be reproduced from source.

Status: released. Playable start to finish on hardware with high-score
autosave, the measured-native 60.24 Hz video timing (60 Hz compat
option in the OSD for strict displays), and the real display window the
arcade monitor showed - including two picture lines every emulator to
date has cropped, and minus two scratch lines every emulator to date
has wrongly displayed. The renderer measures zero missed scanlines
across long stress simulations.

## Install

**With update_all / downloader** (recommended): add this to
`/media/fat/downloader.ini` and run update_all - the core and both
MRAs install and stay current automatically:

```ini
[searchsolved/hyperduel]
db_url = https://raw.githubusercontent.com/searchsolved/Arcade_HyperDuel_MiSTer/main/hyperduel_db.json
```

**Manually**: grab the RBF and MRAs from the
[latest release](https://github.com/searchsolved/Arcade_HyperDuel_MiSTer/releases/latest),
put the RBF in `/media/fat/_Arcade/cores/` and the MRAs in
`/media/fat/_Arcade/`.

Either way you need the MAME `hyprduel` ROM set (0.288 naming) in
`/media/fat/games/mame/`. No ROM data is included here.

## Controls and options

Buttons: Shot, Change (transform), Bomb + Start/Coin/Service. DIPs are
set from the OSD (Coinage including Free Play, Demo Sounds, Difficulty,
Lives, Flip Screen). OSD options: scandoubler effects, Video Timing
(Native 60.24 Hz / 60 Hz Compat), Boot Warning screen (Show/Skip),
Autosave Hiscores.

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
`imagetek_i4100.cpp`](https://github.com/mamedev/mame/blob/master/src/devices/video/imagetek_i4100.cpp)
and the [`hyprduel.cpp`](https://github.com/mamedev/mame/blob/master/src/mame/metro/hyprduel.cpp)
driver - decades of black-box reverse engineering by Luca Elia, David
Haywood, Angelo Salese and contributors, vendored in `reference/mame/`.
That work is the foundation of this core: register semantics, tile and
sprite formats, the blitter's RLE scheme, the memory maps.

**Verified against MAME, machine-checked** (methods and reproduce
commands in [docs/ACCURACY.md](docs/ACCURACY.md)): blitter output word
for word, rendered frames pixel for pixel, full-system boot RAM state
at checkpoints, audio event timing.

**Checked against hardware evidence, beyond MAME**: all three board
oscillators read from photographs match the emulation's assumed values;
the I4220 part number read off the die; an original-PCB 1cc recording
analysed frame by frame (80,760 frames) proving the real board never
drops a scanline.

**New information this project established** (none of it previously
documented anywhere, to our knowledge):

- **The refresh rate is 60.24 Hz, not 60 Hz.** MAME's 60 Hz carries an
  unverified-comment lineage; nobody had measured it. Three independent
  methods on two independent PCB recordings agree (details and numbers
  in [docs/plan_refresh_measurement.md](docs/plan_refresh_measurement.md)):
  (1) the music tempo is YM-timer-paced and crystal-locked, which
  calibrates each recording chain's clock to ~200 ppm; (2) a
  frame-counted game-script interval - exactly 248 frames between the
  title jingle and the announcer, verified by a frame-stamped MAME tap -
  plays 0.33% faster on hardware than at 60.011 Hz; (3) the board's own
  vertical-rate **electrical pickup is visible as a spectral line in the
  recordings' silent moments**: 60.24-60.25 Hz chain-corrected, second
  harmonic at 120.48 Hz. The isolated hum audio and spectra are banked
  in `docs/evidence/refresh/` - the harmonic spectrum resolves real
  mains hum at exactly 120.00 Hz alongside the board's line at 120.48,
  about 15 dB stronger, so the claim is checkable by eye and by ear.
  All three methods select dot totals of 424 x 261 = 60.2408 Hz -
  corroborated by the game itself, which programs raster interrupts for
  exactly 261 lines and never addresses a 262nd. This core ships that
  timing natively (with a 60 Hz compat OSD option).
- **The OKI M6295 clock is 2.000 MHz** (4 MHz crystal / 2), measured
  from PCB footage by sample-pitch ratio to 0.05%. MAME's value
  (2.0625 MHz, marked `not verified` in its own source) is ~3% sharp -
  every emulator and port inherits slightly wrong sample pitch.
- **The real sample-to-music mix balance is 2.5:1** (OKI vs YM2151
  full-scale amplitude), measured from both recordings by per-frequency
  -bin regression against the simulator's separately rendered channels,
  a method that cancels each recording chain's EQ and was validated on
  synthetic recordings of known mixes. MAME's current routing plays the
  samples ~11 dB quieter than the real board. (Supersedes an earlier
  envelope-based estimate that pointed the other way.)
- **The game requests a raster interrupt on all 261 lines per frame
  and real timing services every one**; write-log comparison shows
  MAME missing ~14% of them (visible as stepped parallax).
- **MAME's "many CRTC writes" mystery solved, both halves.** The CRTC
  registers everyone ignores are indexed parameter writes (parameter in
  the high byte, value in the low byte, gated by the unlock register),
  and the vertical set programs the display window: first visible line
  2, active span 224, vsync start 233, vsync end 240 - textbook NTSC
  placement in a 261-line frame. **A real monitor shows chip lines
  2-225; lines 0-1 are a hidden work area** where the game parks its
  scroll scratch accumulator and raster-effect outliers. Every
  "top-line artifact" in emulation of this game is those hidden lines
  being wrongly displayed by a hardcoded 0-223 visible area. The
  massive per-line CRTC-horizontal write volume (655k per attract
  cycle) happens with the lock engaged: no-ops on hardware. This core
  implements the programmed window; the fix and evidence are written
  up for MAME in [docs/mame_bug_report.md](docs/mame_bug_report.md).
- **The GFX bus is 64 bits wide** - four 16-bit mask ROMs read in
  parallel (implied by MAME's loading macro, confirmed by board
  photography) - which sets the sprite-bandwidth envelope any
  implementation must meet.
- **A measured slowdown profile of the real board** (from the footage):
  effective update rate drops to ~38 Hz at the stage-6 boss and
  ~46-47 Hz in two other stretches - reproduced here for free by
  cycle-accurate CPUs, and now checkable rather than anecdotal.
- **The game's scroll registers run two write disciplines** (measured
  in simulation and confirmed on FPGA silicon with a write-landing
  histogram probe): per-line ladder registers rewritten every line on
  schedule, and a once-per-frame block landing during line 0. The full
  investigation - from artifact through silicon telemetry to the CRTC
  answer - is documented in docs/ACCURACY.md section 3.3.

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
Load the core through `mra/Hyper Duel.mra` (or
`mra/Hyper Duel (Set 2).mra` for the alternate program ROM revision)
with a user-supplied MAME `hyprduel` / `hyprduel2` ROM set (0.288
naming) in `games/mame/`.

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
