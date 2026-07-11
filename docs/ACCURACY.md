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

### 3.2 Open: audio balance and OKI pitch

- Mix levels were calibrated against MAME captures (YM RMS matched on
  a reference jingle). Final balance will be calibrated against the
  PCB video audio. Retune targets are documented in the release plan.
- MAME's own source flags the OKI M6295 clock as unverified
  ("clock frequency & pin 7 not verified"). Our OKI timing therefore
  inherits an unverified value. The PCB video is the pitch reference
  for final calibration.

### 3.3 Open: top-of-frame raster phase (lines 0-3)

Our renderer runs one line ahead of scan-out; the game writes per-line
scroll values just in time. The first few lines of a frame can render
with vblank-parked scroll values, visible as a subtle parallax offset
in the top 4 lines during raster-heavy scenes. Whether real hardware
shows the same is UNDETERMINED: on the PCB capture the HUD covers
those lines during gameplay, and arcade bezels typically hid them.
Resolution needs attract-mode PCB footage. We will not "fix" this
without hardware evidence, since the fix could equally introduce a
deviation.

### 3.4 Resolved: heavy-scene line budget (2026-07-11)

The real chip reads its graphics ROMs over a 64-bit bus; the MiSTer
SDRAM stream is 16-bit. Our renderer compensates with a faster clock
and pipelining: prescan sprite rejection with a pipelined table walk
(1 cycle per rejected sprite), paired-pixel emit, fetch/emit overlap
in both walk directions, and a background zoom divider. Measured
result: zero over-budget lines across the 5,200-frame soak and the
scripted worst-case gameplay test. The scan-out safety net (a late
line shows background rather than stale data) remains in the design
but no longer fires in any measured content; extended-content soaks
(later stages) continue as regression tests.

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
