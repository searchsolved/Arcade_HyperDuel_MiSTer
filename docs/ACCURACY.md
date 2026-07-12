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

### 3.2 Resolved: OKI clock (measured); balance calibrated (one refinement open)

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
- **Sample/music balance calibrated to the PCB line capture**: voice
  peak / music RMS = 2.20 on hardware; our OKI mix gain was reduced
  accordingly (457 -> 196 in the 8.8 fixed-point mixer). One
  refinement open: the two recordings' attract cycles never fully
  aligned, so the anchor windows are close but not identical music
  passages; a matched-tune re-measure is planned. MAME's 0.57 OKI
  route gain is ~3x hot against the hardware capture.
- YM level keeps the MAME stream calibration (x1.20); YM clocking is
  crystal-verified.

### 3.3 Open: top-of-frame raster phase (lines 0-3), now fully characterised

Write-log analysis (2026-07-11) established exactly what the game
does: during demo scenes it runs a per-line VERTICAL scroll ramp on
layers 0 and 2 (regs sy0/sy2, one write pair per line), keeps the ramp
running through every vblank line, then RESETS the effect's phase at
the top of each frame (X seeds at line 0, Y ramp restarting at line 1
several steps away from the vblank tail value). Our renderer works one
line ahead of the beam, so lines 0-2 sample the old phase before the
reset lands; lines 3+ track it one step late (sub-pixel, invisible).
Net effect: the top few lines carry the previous phase during these
scenes.

Whether real hardware differs is genuinely open: the fresh value for
line 1 is written MID-line-1 on hardware too, so the real chip cannot
have had it for that line's left edge either unless its internal fetch
lead behaves in undocumented ways. The 1cc capture cannot adjudicate
(HUD covers those lines in gameplay; the video contains no attract).
Deliberately NOT "fixed": changing our render lead to guess at this
would risk trading an understood deviation for an unknown one.
Resolution needs attract-mode PCB footage or a logic analyser.

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
