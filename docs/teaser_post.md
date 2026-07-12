# Draft: teaser post (technical tone, for Lee to trim)

Status: DRAFT 2026-07-12, updated with the refresh and balance
measurements. Community-facing; keep the receipts, drop any line that
reads as a pitch.

---

## Hyper Duel is coming to MiSTer, and the chip work turned up some surprises

For the last while I have been building a MiSTer core for Technosoft's
Hyper Duel (1993). The interesting part is the video chip: the
Imagetek I4220 has no public documentation, no schematics, and no
previous RTL implementation. Everything had to be reconstructed from
MAME's software emulation, board photographs, and recordings of real
PCBs, then proven against those sources.

The core is a from-scratch SystemVerilog implementation of the I4220
(tilemaps, 8x8-through-zoomed sprites, blitter, per-line raster
effects), alongside proven open cores for the rest of the board:
fx68k for the two 68000s, jt51 for the YM2151, jt6295 for the OKI
M6295 (thanks to Jotego and Pedro Gimeno for those). Reusing
cycle-accurate CPU and sound cores means the novel work, and the
novel risk, is concentrated in the one chip nobody had done before.

Some numbers from the verification programme so far:

- The blitter is word-identical to reference across full VRAM
  comparisons; rendered frames are pixel-identical on every reference
  frame tested; the full parity suite (22 checks) runs before any
  build ships.
- The renderer is measured over 5,000+ frame soaks with per-line
  cycle counters: zero over-budget lines through the heaviest attract
  content, because the real board provably never tears (80,760
  video frames of a PCB 1cc scanned automatically: zero artefacts).
- Every per-line raster interrupt is serviced, 261 of 261 lines per
  frame. MAME currently misses about 14 percent of them, which is
  visible as parallax jitter in raster-effect scenes.

Measuring real hardware also corrected some long-standing guesses.
MAME's source flags the OKI clock as unverified; pitch analysis of
the announcer sample against two independent PCB recordings puts it
at exactly 2.000 MHz (MAME's value is 3 percent sharp). The sample
to music balance was measured from the same recordings with a method
that cancels each recording chain's EQ: the real board runs samples
about 2.5 times hotter than the music, around 11 dB louder than
MAME's current mix. And the refresh rate, which MAME carries as an
unverified 60 Hz, measures at 60.24 Hz across three independent
methods, including the board's own vertical-rate electrical pickup
visible in the recordings' silent moments. That is consistent with
261-line frame totals rather than the assumed 262, and it matches
the fact that the game only ever programs 261 raster lines.

All of the methodology, claims, deviations, and reproduce commands
are written up in the repo (ACCURACY.md), including what the core
does NOT claim. The remaining work before release is a short list:
one heavy-scene renderer margin item and release packaging.

Full disclosure: the RTL and the verification tooling were built in
collaboration with an AI coding assistant, with every claim gated on
measurements that are reproducible from the repo.
