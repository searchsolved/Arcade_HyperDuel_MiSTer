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

## Second window: the boot silence

The first 4.45 s of the same recording (the Technosoft Presents
screen, before the title jingle) are silent - about 25x quieter than
the music. Regenerate with:

    python3 tools/hum_evidence.py reference/hyprduel_1cc_pcb.mp4 \
        0 4.45 videoA_boot 1.00021

Result (`spectrum_harm_videoA_boot.png`, `hum_isolated_videoA_boot.wav`):
the second harmonic reads 120.4834 Hz raw - identical to four decimal
places with the window from 22 minutes later, with the same two-peak
structure (mains resolved at 120.00 alongside it). The board's rate is
constant across the entire session, measured at both ends of the
recording. Caveat stated plainly: in this short window the
FUNDAMENTAL band cannot separate the 60.00/60.24 pair (0.24 Hz apart
against a ~0.23 Hz natural resolution), so its blended peak reads
60.13 and is not used; the harmonic band separates its pair (0.48 Hz)
cleanly, which is why the harmonic is the discriminator throughout.

## Third window: an independent board, venue and chain

A second PCB recording from a different uploader
(https://www.youtube.com/watch?v=NYtmwY3_Jw4, audio saved as
`reference/hyprduel_pcb_NYtm.webm`) is silent for its first 9 seconds.
Regenerate with:

    python3 tools/hum_evidence.py reference/hyprduel_pcb_NYtm.webm \
        0 8.9 videoC 1.0

Result (`spectrum_harm_videoC.png` etc.): fundamental 60.2303 Hz,
harmonic 120.4720 Hz, both at very high SNR, with the same two-peak
structure - that venue's mains also resolved at exactly 120.00 Hz
beside the board's line. No chain correction is applied (no tempo
anchor has been fitted for this recording); the in-spectrum mains
line bounds the chain error directly. A different physical board in a
different venue through a different capture chain agrees with video A
to about 0.01 percent, and both sit on the 424 x 261 prediction of
60.2408 Hz.

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
