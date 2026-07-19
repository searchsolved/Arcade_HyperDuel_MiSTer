# Simulation and verification harness

Everything here runs on any host with Verilator 5.x, Python 3 and (for
the MAME-parity suites) a MAME 0.288 install plus your own `hyprduel`
ROM set. No ROM data or MAME-derived dumps are committed; the harness
generates its oracles locally on first run.

## One-time bootstrap

1. Place the MAME ROM set at `../roms/hyprduel.zip` (0.288 naming, the
   same zip the MRA loads).
2. ROM images for the full-system testbench are built automatically by
   the Makefile from that zip via `../tools/build_mainrom.py` and
   `../tools/build_gfxrom.py` (outputs land in `build/mame/`).
3. For the MAME lockstep suites, MAME 0.288 must be on PATH (or set
   `MAME=...`). The lua taps in `mame/` drive it headless; on macOS run
   with `SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy` or MAME dies when
   windowless.

## The suites (the pre-release gate is all of them green)

- `make verify` - VDP register/renderer model vs the Python oracle over
  synthetic scenes (pixel-exact).
- `make blit-verify` - blitter FSM vs the oracle RLE algorithm, word
  for word, 24 randomized blits per scene.
- `make render-verify` - renderer against captured register states.
- `make vdp-verify` - standalone VDP model-vs-RTL frames.
- `make mame-verify` - frame-by-frame lockstep against MAME screenshots.
- `make download` - MRA download-path byte ordering.
- `make boot [SDRAM=1] [FRAMES=n]` - full-system boot (2x fx68k, VDP,
  jt51/jt6295, SDRAM model when `SDRAM=1`); dumps PPMs every
  `DUMPEVERY` frames. This is the workhorse: all the always-on gates
  print PASS/FAIL summaries at the end of every run:
  - scroll snapshot integrity (block class, per-line ladder class)
  - in-flight exposure (scanout must never read a mid-render bank)
  - stale-bank scanout counters
  - render line budget / late-line / beam-visible counters

## Soak convention

Deploy gating in this project = STA clean (all clocks non-negative,
timestamps matched to the RBF) plus a full-length SDRAM-model soak with
the hardware DIP configuration:

    make boot SDRAM=1 FRAMES=2200 \
      PLUSARGS="+DSW=DF80 +verilator+rand+reset+2 +verilator+seed+7"

All gate counters must be zero. Useful plusargs: `+DUMPFROM=a +DUMPTO=b`
(dump every frame in a window), `+RASTERLOG` (CSV of scroll/CRTC
register writes with beam position - the log the CRTC display-window
discovery came from), `+PROBELOG` (per-frame scroll-write landing
histogram), `+LATELOG`, `+RAMPDUMP=n`.

## Analysis tooling (../tools)

`boss_split_analysis.py` (write-log to per-line beam model),
`decode_overlay.py` (debug-overlay screenshot decoder used during
silicon telemetry), `probe_validate.py`, `v14_frame_check.py`,
`hum_evidence.py` (refresh-rate hum isolation), `measure_refresh.py`,
`scan_tears.py` and friends. Each has a docstring with usage.
