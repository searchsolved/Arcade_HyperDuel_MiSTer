# Refresh-rate evidence: the board's vertical-rate electrical pickup

Supporting artifacts for ACCURACY.md section 3.6 (measured refresh =
60.24 Hz, dot totals 424 x 261). This directory holds the isolated
audio and spectra so the claim can be checked by ear and by eye.

## What this is

During quiet passages, the PCB recording's audio contains a narrow
spectral line from the board's frame-rate electrical load, picked up on
the audio path. Its frequency is the vertical refresh rate.

Source: `reference/hyprduel_1cc_pcb.mp4` (original-hardware 1cc
recording), quiet window 1335.0 to 1346.3 s. Regenerate everything with:

    python3 tools/hum_evidence.py reference/hyprduel_1cc_pcb.mp4 \
        1335 1346.3 videoA 1.00021

The chain-scale factor 1.00021 is measured independently from the same
recording: the stage-1 music is paced by the YM2151 timer, clocked by
the photographed 4 MHz crystal, so fitting the recording's tune tempo
against the crystal-exact simulation calibrates the capture chain's
clock to ~200 ppm (docs/plan_refresh_measurement.md, method C).

## Files

- `spectrum_fund_videoA.png`: 55-65 Hz. The line sits at 60.236 Hz raw,
  60.249 Hz chain-corrected. US mains (60.00) is marked.
- `spectrum_harm_videoA.png`: 115-125 Hz. This is the decisive plot: it
  resolves TWO peaks. A smaller one at exactly 120.00 Hz, which is real
  mains hum sitting precisely where mains belongs, and the dominant
  line at 120.483 Hz raw (120.509 corrected), about 15 dB stronger.
  The recording contains both hum sources side by side; the board's
  line is not mains mislabeled.
- `hum_isolated_videoA.wav`: the hum itself, isolated with 4th-order
  zero-phase Butterworth bandpasses (55-65 plus 115-125 Hz) and
  normalized. Nothing else is done to the signal. The slow ~0.5 Hz
  tremolo you hear is the two sources (mains at 120.00, board at
  120.48) beating against each other, which is itself audible proof
  that two distinct lines are present.

## Why this is not a capture artifact

1. The mains line appears at exactly 120.00 in the same spectrum, so
   the chain's frequency axis is demonstrably accurate at that point.
2. The board line's frequency matches two entirely independent methods:
   frame-scripted event intervals (title jingle to announcer, a
   248-frame game constant, measured 0.33 percent shorter on hardware
   recordings than at 60.011 Hz), and the same line found in a second
   recording from a different venue and capture chain
   (docs/plan_refresh_measurement.md, field notes pass 3).
3. 60.24 Hz corresponds exactly to the photographed 26.666 MHz crystal
   divided into 424 x 261 dot totals (26,666,000 / 4 / 110,664 =
   60.2408 Hz), and the game services exactly 261 raster interrupt
   lines per frame; the 262nd line MAME assumes was never addressed by
   the game because it does not exist.
