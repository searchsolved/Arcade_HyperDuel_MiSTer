# Accuracy: methodology, claims, and known deviations

**Core:** Hyper Duel (Technosoft 1993, TEC442-A) for MiSTer
**VDP:** Imagetek I4220, first FPGA implementation of any Imagetek video chip
**Status:** draft, pre-release. Numbers dated 2026-07-11; final release updates this document.

This core was developed with AI assistance throughout (RTL, testbenches,
and analysis tooling). We consider provenance irrelevant to correctness
and verification decisive. Every claim below states its oracle, its
method, and how to reproduce it. Nothing is claimed that was not tested.
Known deviations are listed, including the ones nobody would notice.

---

## 1. What we verify against

No datasheet or schematic for the I4220 has ever surfaced. The
verification stack uses three independent sources of truth:

1. **MAME 0.288** (`imagetek_i4100.cpp`, `hyprduel.cpp`): the
   documentation of record, decades of black-box reverse engineering.
   Used as a machine-checkable oracle via scripted state and frame
   dumps.
2. **Original hardware, photographed**: TEC442-A board photos
   (arcade-museum.com, planetharriers blog). Verified: all three
   oscillators (4.0000 / 20.0000 / 26.6660 MHz) match the values our
   clock tree is derived from; the VDP is marked `Imagetek I4220`
   (date code 1993 wk36); CPUs are TMP68000N-10 x2; sound is
   YM2151 + YM3012 + OKI M6295; the GFX bus is four 16-bit mask ROMs
   read as one 64-bit word.
3. **Original hardware, running**: a full 22.4-minute one-credit clear
   recorded from an arcade PCB (direct 720p60 capture), analysed frame
   by frame. Also the audio reference.

Where MAME and real hardware disagree, real hardware wins (see 3.1).

## 2. Claims and evidence

Each row is reproducible from the repo with a MAME ROM set and the
bootstrap steps in `sim/README`.

| # | Claim | Oracle | Method | Result | Reproduce |
|---|-------|--------|--------|--------|-----------|
| 1 | Blitter is word-identical to the reference algorithm | MAME | 2 blit scenes replayed into RTL, all 3 VRAM banks compared word by word (65,536 words each, 6 comparisons) | identical | `sim/make blit-verify` |
| 2 | Rendered frames are pixel-identical on reference frames | MAME | Boot frames 500 / 900 / 1500 dumped from MAME, rendered by both the standalone renderer and the full VDP from CPU-bus-loaded state, 71,680 pixels per comparison (6 comparisons) | identical | `sim/make mame-verify vdp-verify` |
| 3 | Scanline renderer matches the scene oracle | MAME-derived scene set | 4 synthetic scenes covering tilemap layers, zoom, flip, 8bpp, sprite priority, emit alignment | identical | `sim/make render-verify` |
| 4 | Full system boots and runs the game | MAME | Verilator full-system sim (2x 68000 + VDP + sound + SDRAM controller and model), RAM/VRAM/palette state diffed against MAME at boot checkpoints | POST passes, state exact, attract and gameplay run | `sim/make boot` + `sim/mame/diff_state.py` |
| 5 | Every per-line raster interrupt is serviced | measurement vs MAME | Per-line scroll-register write logs captured from both implementations and diffed by beam position | ours 261/261 lines per frame; MAME misses ~14% | `sim/mame/tap_raster.lua` + `sim/diff_raster.py` |
| 6 | Real hardware never drops or tears a scanline, so neither may we | PCB 1cc video | Automated tear-signature scan over all 80,760 frames of the capture, every flag triaged by eye; ours measured by per-line cycle counters over long soaks | zero genuine artefacts on hardware; ours: ZERO over-budget lines over a 5,200-frame soak (boot through the heaviest attract demo) and zero over 2,500 frames of scripted worst-case gameplay (bomb spam); worst line 4,987 of a 5,088 budget | `tools/scan_tears.py reference/hyprduel_1cc_pcb.mp4 60` + soak targets in `sim/` |
| 7 | Boot and attract sequencing matches | MAME | Frame-numbered event comparison across boot | within ~4 frames (MAME's `spin_until` boot hacks account for the residual) | boot logs, `docs/` |
| 8 | Audio events match the reference | MAME + PCB video | YM2151 register-write histograms and note-onset timing vs MAME capture; music starts at the correct wall-clock time | timing parity; levels within calibration (see 3.2) | `sim/` audio harness |
| 9 | Controls and gameplay verified on hardware | human | CRT play sessions on MiSTer: controls, bombs, full attract cycles, multi-stage play | verified through current build | play it |

The full parity suite (rows 1-3 plus IRQ checks) is 22 checks and is
run before every deploy. Synthesis timing is gated on a clean STA
(setup slack positive on every clock) before any build is published;
builds that merely "seem to work" are not shipped.

## 3. Known deviations

### 3.1 Deliberate: raster interrupt cadence (we differ from MAME, toward hardware)

MAME misses roughly 14% of the game's per-line hblank interrupts
(measured, method above), so its parallax effects update in steps.
Our core services all of them. We believe real silicon does not skip
its own interrupts, and the PCB footage shows smooth parallax. We do
NOT calibrate write timing against MAME here, deliberately.

### 3.2 Resolved: OKI clock and OKI:YM mix balance, both measured

- **OKI clock = 2.000 MHz, measured from real hardware (2026-07-11).**
  Method: the title-screen announcer sample is identical ROM bytes on
  the real board and in this core, so its pitch ratio equals the clock
  ratio. Log-spectral alignment of the sample from the PCB 1cc capture
  against our capture gave ratio 1.0532 vs our then divider
  (80/38 = 2.1053 MHz), i.e. 1.9993 MHz on hardware: exactly the
  photo-verified 4 MHz OSC divided by 2. After fixing the divider to
  80/40 the re-measured ratio is 1.0000 (spectral corr 0.905).
  MAME's 2.0625 MHz (flagged "not verified" in their source) is
  therefore measurably ~3.1% sharp; sample rate is 15,151.5 Hz.
- **OKI:YM mix ratio = 2.5:1, measured from two independent PCB
  recordings (2026-07-12).** Method: the title jingle + announcer is
  the one segment where a recording and the simulator play *identical*
  content (deterministic from title start, before the player coins
  up). The sim dumps its pre-mix YM and OKI channels separately; each
  recording's power spectrogram is then regressed per STFT bin onto
  the two sim channel spectrograms (non-negative least squares, plus a
  noise-floor term). The per-bin coefficient on the YM channel absorbs
  the entire unknown recording chain (speaker, capture EQ, codec), so
  the coefficient ratio in each bin is chain-independent, and its
  weighted median across ~550 bins gives one global OKI:YM amplitude
  ratio. Recording A: 2.48. Recording B (different capture chain):
  2.52. The estimator was validated end-to-end by synthesising fake
  "recordings" from our own mix at known gains through a random EQ +
  noise + delay: a 2.50-ratio synthetic recovers 2.512, a 0.98-ratio
  synthetic recovers ~1.0. Mixer set to OKI x3.00 / YM x1.20
  (= 2.5:1). This supersedes the 2026-07-11 estimate (which compared
  envelope peak to RMS across unmatched windows with no EQ
  cancellation and pointed the wrong way); by this measurement MAME's
  0.57/0.80 routing is ~11 dB *quiet* on samples relative to the real
  board.
- YM level keeps the MAME stream calibration (x1.20); YM clocking is
  crystal-verified.

### 3.3 In progress: top-of-frame raster phase (lines 0-3), fix v1 has a heavy-scene regression

Write-log analysis (2026-07-11/12) established exactly what the game
does: during scenes with a per-line vertical scroll ramp on layers 0
and 2 (regs sy0/sy2), it writes line N's ramp values during line N-1
at h~70-100, keeps the ramp running through every vblank line, and
parks the frame-start values at (vpos 261, h~75). A renderer that
fetches each line's registers at h=0 of the previous line therefore
samples lines 0 and 2 one ramp-phase early (measured staleness: 14-17
lines of Y for line 0, ~11 for line 2), which showed on a CRT as a few
rows of displaced cloud pixels at the top of stages 2 and 6. The real
chip never shows this because it fetches just-in-time; a fetch that
happens after h~100 of the previous line always sees fresh values.

Fix v1 (2026-07-12): the render kick for lines 0 and 2 only moves
from h=0 to h=120 of the previous line, after the game's writes have
landed. This reproduces the just-in-time property the write schedule
proves the real chip relies on, and measured staleness deltas drop to
0 on every top line (all within 1 px) with zero over-budget lines and
zero mid-scanout completions over a 2,500-frame light-content soak.
HOWEVER a 5,200-frame soak through the heavy stage-2 attract window
found 1,357 mid-scanout completions on the late-kicked lines: their
reduced 3,648-cycle lead is not always enough there, and a completion
at hcnt >= 28 means the beam has already displayed stale line-buffer
content on the left edge (the resolve pass is the final 320-clock
left-to-right writer). Fix v1 is therefore NOT shipped as-is;
characterisation of the offending frames (completion-hcnt
distribution, whether the scroll values actually changed that frame)
is running to choose between a conditional late kick (only when the
ramp effect is live) and renderer throughput work that makes the
3,648-cycle lead always sufficient.

Known residual, plausibly authentic: the layer X seeds for line 0 are
written DURING line 0 (h256-400), so lines 0-1 render with X scroll
~2 px stale and line 3 is within +-1 px. The real chip cannot have had
those values for those lines' left edges either unless its internal
fetch lead behaves in undocumented ways; the 1cc captures cannot
adjudicate (the HUD covers those lines in gameplay and neither video
shows attract). Resolution needs attract-mode PCB footage or a logic
analyser.

Related finding: the game also writes a line-indexed value to the CRTC
horizontal register on EVERY line, always (655k writes per attract
cycle) - a long-standing MAME mystery ("many CRTC writes" TODO). Both
MAME and this core ignore the register; the footage shows real
hardware has no visible geometric response to it either.

### 3.4 Heavy-scene line budget: measured-zero, provable bound in progress

The real chip reads its graphics ROMs over a 64-bit bus; the MiSTer
SDRAM stream is 16-bit. Our renderer compensates with a faster clock
and pipelining: prescan sprite rejection with a pipelined table walk
(1 cycle per rejected sprite, and the walk itself runs hidden under
the previous sprite's ROM fill), paired-pixel emit, fetch/emit overlap
in both walk directions, a background zoom divider, and tilemap
map-word prefetch (the next tile's VRAM read issues during the current
tile's pixel walk; same-code boundaries cost zero cycles).

Measured (per-line envelope counters, 5,200-frame soak + scripted
worst-case gameplay, 2026-07-12): zero over-budget lines; worst line
4,678 of the 5,088 budget; worst tilemap-pass line 3,948; worst
sprite-pass line 1,217; sprite fetch sustains 0.88 bytes/cycle under
full SDRAM contention.

Two honest caveats, and the roadmap they set:
- Empirical zeros are configuration-specific: correcting the OKI clock
  (an audio change) shifted SDRAM arbitration enough to move renderer
  margins measurably. The end state is a PROVABLE bound - per-line
  worst-case arithmetic that contains the real chip's fetch envelope
  (~2,300 sprite bytes/line from the 64-bit bus) - not a passed test.
  Remaining work: hide the tile-decode chain for changed tiles, and
  one scene (the stage-7 boss, beyond attract-soak coverage) as a
  permanent dumped-state regression.
- The scan-out safety net (a late line shows background rather than
  stale data) remains in the design and no longer fires in any
  measured content.

### 3.5 Unverifiable without hardware instrumentation

Honest list of what no one can currently verify, because it would need
a logic analyser on a live board or a decap:

- The real chip's internal fetch order, bus arbitration, and FIFO depths
- Behaviour of register corners and blitter modes this game never uses
- Exact analog video timing beyond what MAME and footage establish
- The nine board PALs (442A21-28, 442X29): our system glue reimplements
  their function; a PAL dump would allow gate-level verification

Any core for this hardware, however written, shares this list.

## 4. What we do NOT claim

- Not "cycle-accurate": that term is unfalsifiable without silicon
  measurements that do not exist for this chip.
- Not verified for other Metro-family games: the I4220 here is
  validated against what Hyper Duel exercises. Family reuse gets its
  own verification pass per title.
- FM synthesis and ADPCM accuracy are inherited from jt51 and jt6295
  (verified projects in their own right), not re-proven here.

## 5. Reproducing the results

Requirements: Verilator 5.x, MAME 0.288, Python 3, a `hyprduel` ROM
set you legally own. Bootstrap: `sim/README` describes dumping the
oracle data from MAME (state dumps, frames, audio) and building the
GFX ROM image. Then:

    cd sim
    make verify blit-verify render-verify mame-verify vdp-verify
    make boot            # full-system boot to title
    tools/scan_tears.py reference/hyprduel_1cc_pcb.mp4 60

## 6. Credits

- **MAME team**, especially the authors of `imagetek_i4100.cpp` and
  `hyprduel.cpp` (Luca Elia and contributors): the only functional
  documentation of this chip on Earth. This core would not exist
  without that reverse-engineering work.
- **Jorge Cwik**: fx68k cycle-exact 68000.
- **Jose Tejada (jotego)**: jt51 (YM2151), jt6295 (OKI M6295).
- **STG cvlt**: the arcade-PCB 1cc recording used as the hardware
  reference.
- **Stefan Lindberg**: the high-resolution TEC442-A board photo
  (arcade-museum.com).
- **Technosoft**, for the game.
