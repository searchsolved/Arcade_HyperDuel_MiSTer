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

### 3.3 Resolved (v12.2 + v14 + v15, 2026-07-19): top-of-frame and raster-split scroll staleness, and the CRTC display window

The full mechanism, established over 2026-07-11..18 by write-schedule
logging in sim, pixel-exact analysis of MAME output, attract-mode PCB
footage, and on-silicon register telemetry (probe overlay builds read
back through the MiSTer's own screenshot facility, machine-decoded
against the overlay font):

**What the game does.** Across vblank the scroll registers hold a
scratch accumulator that advances every frame without bound (measured
+7-12 px/frame in the cloud scenes; it is NOT a display value). The
per-line raster program then writes each line's true value just in
time - line N's value during line N-1 (h~20-100 in sim) - and a
once-per-frame block lands around line 0-1. In the stage-2 boss
transition (the "grey blobs" scene) the program jumps sy2 by up to
~190 px between adjacent lines.

**Why the real PCB is clean and MAME is not.** The real chip consumes
registers per-pixel at beam time, and a PCB's zero-wait mask ROMs run
the interrupt handlers on schedule, so every just-in-time write lands
before the pixels that need it. Any line-granularity renderer that
samples a line's registers before its write has landed paints the
scratch value (top lines) or the neighbouring split value (boss
scene). MAME 0.288 exhibits exactly this: its cloud-scene top lines
scroll at 3 and 12 px/frame while the sky beneath moves at 1
(pixel-exact frame differencing, mse=0 matches), and note 3.1's
measured ~14% dropped per-line interrupts push the game's writes off
schedule in the same direction. PCB attract footage shows none of it.
A MAME bug report with these measurements is planned.

**Why this core showed it, measured.** Our 68000 pays SDRAM wait
states a PCB never did, so under load the handler writes land later
relative to the beam than any simulation predicts. A hardware
sampling-ladder build measured the frame-top landing at (line 1,
h<=160) on silicon - a full line later than the SDRAM-model sim -
and the boss-section slips follow the same load-dependent lateness
(the artifact appears at the sprite-heaviest moment of the attract).

**The shipped architecture (v12.2).** Scan-out runs three lines
behind the game timeline (190 us, invisible; game-facing timing is
untouched). Each line's render consumes a register snapshot carried
in the kick FIFO: lines 2+ snapshot at their own line's h170, lines
0-1 at (1,h200)/(1,h208) - after the measured landing. The h170
sampling point buys ~1.2 lines of tolerance for late writes at zero
extra render load. (v12.1 instead re-kicked a line when a write
landed just after its snapshot; on silicon the re-renders doubled
renderer load exactly at the sprite-heaviest frames and caused
visible tearing - a failure the SDRAM-model sim cannot reproduce
because its write timing does not slide. Reverted same night.) No
detectors, predictors, or scene-specific machinery; the v6-v8
mitigation stack is deleted. This fully fixes the top-of-frame
artifact (cloud scenes verified clean on CRT).

**The stage-2 boss transition (v14).** A few wrong lines persisted
from just after the "grey blobs" effect to the end of that attract
scene, surviving both v12.2 (h170 sampling) and a v13 experiment
granting the 68000 absolute SDRAM priority - so not bus starvation.
A hardware histogram probe (overlay rows counting sy2 write landings
per hcnt band per frame, decoded from screenshot bursts) then showed
silicon writes are ON SCHEDULE: one sy write per line, >=98.8%
landing at h0-99, none ever past h170, totals equal to the sim's -
which killed every lateness theory and proved the residual
deterministic. Write-schedule modelling located it: the game runs
TWO write disciplines. sy0/sy2 are per-line ladder registers
(rewritten every line at h34-76, punctual even on silicon); sx0/
sx1/sx2/sy1 arrive once per frame during line 0 (h185-270, landing
as late as (1,h160) on silicon). Sampling lines 0/1 wholly at
(1,h200/208) - required for the late block - handed line 0 the sy
ladder write intended for line 1. Harmless on a smooth ramp, but in
the boss tail the game parks a per-frame outlier at (1,h~44) that
jumps up to 191 px (frames 1841-2163, every frame for ~5 s), so
line 0 painted the boss zone a full line early. (The vblank
"accumulator march" in this scene is not scratch: the game ramps sy
through vblank so it arrives at the correct top-of-screen parallax
value by line 0 - which is exactly why the real PCB is clean.) v14
fix: sy0/sy2 for every line come from that line's own (N,h170) view
(stashed at (0,h170)/(1,h170) for the two early kicks); only the
block class keeps the (1,h200/208) view. Proof: a dedicated
tb ladder-snapshot gate (0 mismatches, 515k renders), and on the
shared artifact frame the fix changes row 0 alone (252/320 pixels)
with rows 1-223 pixel-identical - surgical scope by construction.

**Deliberate deviations that remain.** (a) Three scanlines of output
latency. (b) Line granularity: a write landing mid-way across its own
line's visible pixels splits on the PCB and cannot split here; in
this game that is confined to parts of single lines in light scenes,
a 1-2 px difference. (c) Lines 0-1 take sx0/sx1/sx2/sy1 from the (1,h200/208) view -
after the once-per-frame block that lands as late as (1,h160) on
silicon - so their X scroll can lead the real beam's value by up to
a line; their sy0/sy2 come from each line's own h170 view (v14) and
match the beam-dominant value. (d) Every line samples at h170 of its
own line rather than the beam-time per-pixel consumption of the real
chip, so a mid-line write splits on the PCB but moves our whole
line; in this game that is the left ~34-56 px of the lines adjacent
to a raster discontinuity.

**Verification.** Per-render snapshot-integrity gate (consumed value
must equal the tb's own record of the sampling instant; 1.4M renders,
0 mismatches), in-flight exposure gate, stale-bank counters, full
oracle/blitter/MAME-frame parity, SDRAM-model soaks run with the
hardware's DIP configuration, on-silicon register telemetry, and
scripted hardware screenshot bursts of the artifact scenes compared
against the PCB footage - plus the CRT.

**The final piece (v15): the CRTC vertical display window.** After
v14, a 1-2 line residue remained at the top of the boss tail that
PCB footage does not show - yet the write schedule proves the chip
is TOLD to draw it (the game parks a per-frame outlier on line 1).
The resolution is the long-ignored CRTC registers: the game programs
the vertical timing through 78880 as indexed writes ({param[15:8],
value[7:0]}, gated by the 788a0 unlock): param0=223 (active span),
param2=233 (vsync start), param4=240 (vsync end), param7=2 (FIRST
VISIBLE LINE) - 233/240 match standard NTSC vertical sync placement
exactly, corroborating the decode. A real monitor therefore displays
chip lines 2-225; lines 0-1 are a hidden work area, which is why the
game freely parks its scratch accumulator and raster outliers there
and why a PCB's top of screen is always clean. v15 implements the
window: raster row R displays chip line R + 2, the render range
extends to line 225, and every prior "top-line artifact" - clouds
strip, boss stripe - is off-screen exactly as on real hardware
(verified on CRT, 2026-07-19). This resolves MAME's "many CRTC
writes" TODO for this game: MAME latches these registers, ignores
them, and hardcodes visible = lines 0-223, so it displays the hidden
work area - the actual mechanism behind the family of top-line bugs.
The once-per-line writes to the horizontal register (655k per attract
cycle, the other half of the mystery) happen with the unlock LOW and
are no-ops on real silicon, consistent with the footage showing no
geometric response.

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

### 3.6 Measured, correction pending: refresh rate is 60.24 Hz, this core still ships 60.011 Hz

Nobody had measured this board's refresh; MAME's 60 Hz is flagged
unverified in its own history. Measured 2026-07-12 from the two
independent PCB recordings, three methods that fail differently
(full numbers in docs/plan_refresh_measurement.md):

1. **Chain anchor**: the music tempo is YM-timer-paced (crystal), so
   fitting the sim's audio against each recording calibrates that
   recording chain's absolute clock to ~200 ppm (measured s = 1.00021
   and 1.00017 - both captures are near-perfect).
2. **Frame-counted script interval**: the game waits exactly 248
   frames between the first title-jingle key-on and the announcer
   trigger (frame-stamped MAME tap). Both recordings play that
   interval 0.33-0.34% faster than our 60.011 Hz core: 60.20-60.23 Hz
   after chain correction. The two recordings agree to 0.007%.
3. **Electrical pickup**: both recordings contain the board's own
   vertical-rate pickup as a narrow spectral line in silent segments
   (SNR up to ~400): 60.236-60.250 Hz chain-corrected, second
   harmonic at 120.48 Hz. Not mains: US grid is 60.000 +- ~0.02% and
   its harmonic would sit at 120.00.

All three select dot totals of 424 x 261 = 60.2408 Hz at the
photo-verified 26.6660/4 MHz dot clock. Corroboration already in this
repo's data: the game programs raster interrupts for exactly 261
lines per frame; a 262nd line is never addressed, because it does not
exist on hardware. Music/sample pitch are unaffected (crystal-clocked)
- on real hardware the game simply runs 0.38% faster than its music
would suggest.

Status: the RTL still uses MAME's assumed 424 x 262 (60.011 Hz), so
this core currently plays 0.38% slower than a real PCB. The one-line
V_TOTAL correction is deliberately queued behind its own full
re-verification ladder (the vblank write geometry shifts, so the
raster freshness analysis in 3.3 must be redone against the new frame
shape) rather than shipped as a rider on an audio build.

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
