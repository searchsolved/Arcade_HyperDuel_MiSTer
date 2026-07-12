# Draft: upstream note to MAME (hyprduel.cpp)

Status: DRAFT for Lee's review, 2026-07-12. Not sent. MAME's own source
invites both corrections ("clock frequency & pin 7 not verified", and
the 60 Hz refresh carries an Unknown/Unverified comment lineage).
Suggested venue: a MAME GitHub issue against src/mame/metro/hyprduel.cpp
with the measurements and method summaries below; the full methodology
lives in this repo (docs/ACCURACY.md, docs/plan_refresh_measurement.md).

## 1. OKI M6295 clock: 2.000 MHz, not 4000000/16/16*132 (= 2.0625 MHz)

The title-screen announcer sample is identical ROM data on hardware and
in emulation, so its pitch ratio equals the clock ratio. Log-spectral
alignment of the sample from two independent original-PCB recordings
gives a pitch ratio of exactly 1.0000 against a 2.000 MHz clock
(4 MHz OSC / 2; the 4 MHz oscillator is photo-verified on the board).
MAME's 2.0625 MHz plays every sample ~3.1% sharp. Suggested:
`OKIM6295(config, "oki", 4000000/2, okim6295_device::PIN7_HIGH)`.
(PIN7 stands: measured sample rate 15,151.5 Hz is consistent with
PIN7_HIGH at 2.000 MHz.)

## 2. Refresh rate: ~60.24 Hz (424 x 261 dot totals), not 60 Hz flat

Three independent measurements on two original-PCB recordings
(different players, venues, capture chains), all anchored to the
photographed 26.6660 MHz pixel crystal via the music tempo (the YM2151
is timer-paced, so recorded tempo calibrates each capture chain's
clock to ~200 ppm):

- A frame-counted game-script interval (first title-jingle key-on to
  the announcer OKI trigger; exactly 248 frames, verifiable in MAME
  with a frame-stamped tap) plays 0.33-0.34% faster on hardware than
  at 60.011 Hz: 60.20-60.23 Hz.
- Both recordings contain the board's own vertical-rate electrical
  pickup as a narrow line in silent segments: 60.238-60.250 Hz after
  chain correction, with the second harmonic at 120.48 Hz (not mains:
  US grid is 60.000 +- ~0.02%).
- The game programs raster interrupts for exactly 261 lines per frame;
  a 262nd line is never addressed.

At the fixed 26.6660/4 MHz dot clock this selects totals of
424 x 261 = 60.2408 Hz. MAME's SCREEN_RAW_PARAMS currently implies
424 x 262 = 60.0107 Hz. Suggested: change the vertical total to 261
(60.2408 Hz refresh).

## 3. Sound balance (informational)

Chain-EQ-cancelling spectral regression of the two PCB recordings
against a cycle-accurate simulation with separately rendered YM2151
and OKI channels puts the OKI at ~2.5x the YM2151's full-scale
amplitude contribution (both videos independently: 2.48 / 2.52).
MAME's current routes (YM 0.80 / OKI 0.57) render the samples roughly
11 dB quieter relative to music than the real board's mix.

## 4. Raster IRQ cadence (informational)

The game writes a per-line scroll pair from the hblank interrupt on
every line; on hardware and in our RTL implementation all 261 lines
are serviced every frame. MAME (0.288) misses ~14% of the per-line
interrupts (gaps every 7-8 lines), measurable by frame-stamped taps
on the scroll registers.
