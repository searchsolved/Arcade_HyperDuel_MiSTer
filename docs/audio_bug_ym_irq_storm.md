# RESOLVED: "audio silent / YM2151 IRQ storm" was a false alarm

Status 2026-07-05: closed. No RTL change was needed. Audio works: a
1300-frame boot produces 355,769 audio transitions, with the first YM
key-on at frame 630 and full voice programming matching MAME's register
values. The original bug report below was built on two measurement
artifacts, documented here so neither trap is stepped in again.

## What the "bug" actually was

1. **The sim window was too short.** Hyper Duel plays its first note
   17.6 seconds after power-on (MAME: first KON write at frame 1059,
   confirmed by WAV-recording MAME's audio; onset at t=17s). Every
   earlier "silent" run stopped at 470 frames, ~10 seconds before any
   sound is commanded. Title screen and early attract are silent by
   design; Demo Sounds was never the issue.

2. **The MAME oracle taps were garbage-collected.** MAME removes a Lua
   memory tap when its handle is collected. The first tap script kept
   the handles in locals that went dead when the autoboot script
   returned, so the taps silently died around frame ~130. That
   fabricated "MAME's YM traffic stops at 130" - which spawned the
   whole IRQ-storm/sub-reset-latch theory. With handles pinned
   (`_G.pinned_taps = {...}` in sim/mame/tap_ym.lua), MAME services YM
   timer IRQs at ~10/frame continuously forever, exactly like our RTL.

## What was verified along the way (all healthy)

- The MUSE driver's timer discipline is identical in RTL and MAME:
  same registers (0x10/0x11/0x12/0x14), same values (CLKA=0x39c,
  CLKB=0xc3), same 0x14 ack set {00,1f,2f,3f}, same status-read flag
  ratios (~82% flag A, ~6% flag B, busy never observed set).
- One YM IRQ per service (irq falls 13,664 vs IACKs 13,565 over 1300
  frames) - no storm, no re-entry.
- Steady-state service rate: ours 10.7/frame vs MAME ~10/frame (the
  earlier "25% deficit" was averaging over the slower boot phase).
- jt51 timer semantics match the real chip (timer A tick = 64 cen,
  timer B = 1024 cen, clr_flag pulse per 0x14 write, level irq).
- The 429-frame timeline offset vs MAME (our KONs at 630/709, MAME's
  at 1059/1138) is MAME's spin_until_trigger boot hacks suspending its
  main CPU; our dual-port shared RAM needs none of that. Constant
  offset, no drift: tempo is correct.
- Sim cen is 4.103 MHz (P_PIXDIV=16 makes P_YMDIV truncate to 26), a
  +2.6% pitch/tempo error IN SIM ONLY. The hardware plan (80 MHz sys,
  P_PIXDIV=12) gives P_YMDIV=20 = exactly 4.000 MHz.

## Tools that came out of this

- `sim/mame/tap_ym.lua` - pinned-handle MAME tap: YM/OKI write logs,
  register histogram, status-read stats. Run with TAP_OUT/TAP_FRAMES.
  Do NOT tap maincpu 0x800000 (subcpu_control_w): MAME 0.288 segfaults.
  Do NOT call screen:frame_number() inside tap callbacks (segfaults
  under load); read the frame from a variable cached per frame.
- `sim/mame/tap_subpc.lua` - per-frame sub CPU PC/SR sampler.
- tb_system.sv extended probes: per-register write histogram with
  first-write frame, status-read capture, edge-counted IACKs/IRQs.
- tb_system.sv +AUDIODUMP=<path>: raw s16le mono at sys/2048 (~52 kHz);
  convert with `sim/mame/raw_to_wav.py`, e.g.
  `make boot FRAMES=1300 AUDIODUMP=build/boot/audio.raw`.

## How to re-verify

- `cd sim && make boot FRAMES=1300 AUDIODUMP=build/boot/audio.raw`
  then `python3 mame/raw_to_wav.py build/boot/audio.raw out.wav` -
  expect audio transitions > 300k and sound from ~t=10.5s (frame 630).
- Video regression gate unchanged: `make verify blit-verify
  render-verify mame-verify vdp-verify` = 22/22 PASS (last run
  2026-07-05, after the probe additions).
