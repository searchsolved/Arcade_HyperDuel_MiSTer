# Hardware bring-up QA checklist

Things to test on the real MiSTer once the core compiles and boots.
Items marked [sim-proven] already pass in Verilator against MAME and
only need a hardware sanity pass.

## Audio (park from 2026-07-05 session; test properly here)

- [ ] A/B the boot fanfare + "Hyper Duel" voice sample against MAME
      through real speakers (sim A/B sounded compressed at 6-8x volume
      boost; judge on hardware at native levels).
      Reference recordings in repo tooling: MAME via
      `mame hyprduel -wavwrite ...`, sim via `make boot AUDIODUMP=...`
      + `sim/mame/raw_to_wav.py`. Alignment: our timeline leads MAME by
      429 frames (7.15s) because MAME's spin_until boot hacks stall its
      main CPU.
- [ ] Attract demo music (starts MAME t=30, ours t=22.9): melody,
      tempo, and multi-channel balance vs MAME. A 1900-frame sim
      capture exists from the 2026-07-05 session for desk comparison.
- [ ] Mix loudness: sim mix measured ~4-8x quieter than MAME's
      (YM 0.80 / OKI 0.57 routes). Tune the mix constants in
      hyprduel_sys.sv by ear/scope on hardware.
- [ ] Pitch/tempo: hardware P_YMDIV must give exactly 4.000 MHz
      (80 MHz / 20 at PIXDIV=12). Sim runs +2.6% fast; hardware must not.
- [ ] OKI sample quality at 15625 Hz; revisit jt6295 INTERPOL=1 once
      jtframe is vendored.
- [ ] In-game: sound effects during play, music changes between
      stages, no dropouts under heavy sprite load.

## Video [sim-proven, verify on panel]

- [ ] Boot sequence: MEMORY CHECK, Technosoft logo, title, attract.
- [ ] Scroll smoothness (raster mid-frame writes), sprite zoom on
      bosses, 8bpp layers, no flicker at 4-bank line buffer.
- [ ] Screen geometry 320x224 @ ~60.01 Hz; check HDMI/analog timing.

## System

- [ ] Both players' inputs, all buttons, coin/start/service.
- [ ] Full DIP table from the MRA (difficulty, lives, demo sounds off
      actually silences attract).
- [ ] Long soak: attract loop for 30+ minutes (watch for IRQ/sync
      drift, SDRAM refresh artifacts).
- [ ] MRA byte order / ROM CRCs load correctly from the MiSTer menu.
- [ ] Verify against real PCB video captures on YouTube if available
      (MAME is the oracle, but a second reference is cheap).
