# Release plan: Hyprduel_MiSTer public core

Goal: first public Imagetek I4220 core. This doc is the gap between
"plays correctly on Lee's CRT" and "released MiSTer core".

## Phase R1: lock down (current, nearly done)

- [x] Prescan + tag blanking + 2px emit + 16-bit fetch (sim-verified)
- [x] Deploy combined build, STA gate, CRT bomb/jitter test
- [x] Commit everything (through 770f013, v15)
- [ ] 30-minute human soak: full game credit-feed playthrough on CRT
      (stages exercise content the attract never shows: bosses, stage
      transitions, the vertical stage if any)

## Phase R2: release hygiene (one session)

- Remove the debug overlay + probe rows from mister/Hyprduel.sv and the
  CRT diagnostic OSD toggles that are dev-only (keep Test Pattern? it is
  harmless and occasionally useful - decide). Overlay removal historically
  buys timing slack; expect the STA gate to get EASIER.
- Remove VERILATOR-gated debug counters? No - they cost nothing in
  synthesis (ifdef'd out) and keep the sim harness rich. KEEP.
- d-pad vs analog mapping check (OSD joystick options), button order
  sanity (shot/transform/bomb), 2P inputs never tested - test with a
  second controller.
- MRA: verify against the MAME set name/CRCs users will have
  (hyprduel, MAME 0.288 romset), DIP defaults sensible (Show Warning
  off, difficulty normal), add magerror as a second MRA later (same
  board, needs its own bring-up pass - IRQ model differs!).
- Audio: final volume balance vs real PCB videos (YM 1.20 / OKI 457
  gains were matched to MAME, not to a PCB).
- Video timing metadata: confirm 58.something Hz reported to the
  framework matches MAME's measured refresh; check analog/direct video
  on the CRT AND HDMI scaler output.

## Phase R3: repo + distribution

- Decide repo shape: MiSTer-devel style fork (Hyprduel_MiSTer) with
  releases/ rbf naming Hyprduel_YYYYMMDD.rbf.
- Licensing/attribution audit: fx68k (ijor, CC/BSD-ish - check exact),
  jt51 (jotego, GPLv3), jt6295 (GPLv3), MiSTer framework (GPLv3),
  vendored MAME reference code is NOT shipped in the rbf but the repo
  vendors sources - keep reference/ out of the public repo or confirm
  MAME license (GPLv2+) compatibility for a mixed repo. Own RTL: pick
  GPLv3 to match the ecosystem.
- README: supported romset, controls, DIPs, known-vs-real-hardware
  deviations (document the MAME hblank-IRQ finding! our core services
  all 261 per-line IRQs where MAME drops ~14% - visible as smoother
  raster parallax; cite the measurement),
  build instructions (Quartus 17, BALANCED, SEED 2).
- CI/regression: the sim suite runs on any Linux box with Verilator -
  document `make verify blit-verify render-verify mame-verify
  vdp-verify` + the +INPUTS bomb test as the pre-release gate. MAME
  golden dumps are generated locally (not committed - ROMs).
- Announce: MiSTer forum thread + the arcade cores list. Mention the
  I4220 is now proven RTL - unlocks Metro-family follow-ups (Blazing
  Tornado, Grand Striker, Mouja run on i4220/i4300 variants; magerror
  shares this exact board).

## Phase R4: stretch accuracy (optional, post-release)

- Fetch/emit overlap (last ~35 over-budget lines -> 0)
- Feature-matrix synthetic tests (flip screen, 8bpp windows, blitter
  edge modes) - guards future Metro-family reuse
- Real-PCB cross-check: crystal values from PCB photos, speed/raster
  behaviour vs the YouTube 1cc capture
  - DONE 2026-07-11 (photo read): TWO photo sources. planetharriers
    blog (flickr 48371679096, 1024px) + arcade-museum.com
    hyper-duel-41972.jpg (1920x1435, MUCH better - Stefan Lindberg).
    CONFIRMED on silicon:
    - All three oscillators match MAME's OSC line exactly: OSC1
      4.0000 MHz (sound), OSC2 20.0000 MHz (dual CPU /2 = 10 MHz
      each), OSC3 26.6660 MHz (I4220). Clock tree photo-verified.
    - VDP part number READ OFF THE CHIP: "Imagetek, Inc. I4220 071
      9336EK710" at U55 (date code 1993 wk36).
    - CPUs: Toshiba TMP68000N-10 x2 (both 9311C8Z).
    - Sound: YM2151 + YM3012 DAC (top-left), OKI M6295 QFP44 at U16,
      sample EPROM "97" at U97. All match MAME's config.
    - GFX ROMs: FOUR NEC mask ROMs "TS HYPER-1..4" (9337KD011-014).
      MAME loads them ROM_LOAD64_WORD (ts_hyper-1..4.u74-u77): the
      real GFX bus is 64 BITS WIDE - four 16-bit mask ROMs read in
      parallel. This is the physical reason the real board never
      tears: per-access sprite fetch bandwidth is 4x our 16-bit SDRAM
      stream. (CORRECTS an earlier misread of these as DRAMs from the
      low-res photo.)
    - VDP work RAM: Cypress CY7C199-25PC 32Kx8 25ns FAST SRAMs (U32-35
      column + U53/54 + more, exact census needs a sharper photo),
      plus a CY7C185-35PC. Not DRAM - the VDP has low-latency SRAM.
    - Glue logic: nine AMI 18CV8PC-25 PALs labelled 442A21-442A28 +
      442X29 (= our hyprduel_sys decode/arbitration in PAL form).
    - Program EPROMs "24"/"23" at U24/U23 (museum board = set 1;
      the blog board's "U24A" sticker = MAME set 2 "24a.u24").
    - Unpopulated footprints (LS273 x2, LH5496 FIFO x2, 442X29 spare,
      RA9-12, sockets U85/U89/U86 etc) = alternate fit of the shared
      TEC442-A board (magerror variant), supporting the family
      roadmap.
  - IMPORTANT for R2 audio: MAME's own hyprduel.cpp flags the OKI
    clock as guesswork ("clock frequency & pin 7 not verified",
    reconstructed as 4000000/16/16*132). Our OKI pitch calibration
    target is therefore soft; a real-PCB video with known-good audio
    is the only trustworthy pitch reference, NOT MAME.
  - REAL-PCB VIDEO ANALYSED 2026-07-11: youtube 6KcyYm2Ggu0
    ("HyperDuel 1cc - Arcade PCB : ALL (1.6Mill)" by STG cvlt,
    22.4 min, direct 720p60 capture, 3.0 px per game line, top lines
    in frame). Automated tear scan (scratchpad vid/scan_tears.py:
    left-black-run + right-content + background-continuity signature)
    over ALL 80,760 frames at 60fps: ZERO genuine tears. Every flag
    triaged by eye = static scene content (dark doorways, shadows,
    near-black stage backgrounds). Includes the exact stage-2 scenes
    and boss kills where our core tears. CONCLUSION: real I4220 never
    misses a line; zero over-budget lines is the accuracy bar, any
    residual tearing in our core is OUR defect. Video audio = the
    real-PCB pitch/balance reference for the R2 audio retune (keep
    hyprduel_1cc.mp4; re-download from the URL if lost). Top-4-lines
    check inconclusive from gameplay (HUD covers top rows on real
    board); needs an attract-mode PCB capture for the parallax
    comparison - still parked.
- Scripted-input long-run: full stage-1 boss kill in sim as a repeatable
  regression (extend cfg/inputs_bombtest.txt with survival choreography)

## Open decisions for Lee

1. Test Pattern OSD toggle: keep in release or strip?
2. Public repo: include the full sim harness (great for contributors,
   requires MAME-dump bootstrap docs) or rbf-only releases first?
3. magerror support in v1 or defer?

## Note from 2026-07-10 audio regression check

build/boot_final/audio.raw (July 5) is OBSOLETE as an audio reference:
it was captured on the pre-arbiter-fix core where the sub (sound) CPU
was starved on sr3, so its note timing lags - envelope matches, sample
correlation does not. For the R2 audio check, capture FRESH MAME
reference audio and compare against the current tree; do not use the
old raws. Cross-build regression evidence today: audio transitions
355,399 (tag build) vs 355,402 (with emit2+16b fetch) over the same
1500 frames = audio path unaffected by the renderer/SDRAM changes.

Fresh MAME reference audio CAPTURED 2026-07-10 (not committed - lives at
sim/build/mame/refaudio/hyprduel_boot45s.wav, regenerate with:
  mame hyprduel -rompath ../roms -video none -nothrottle \
    -wavwrite build/mame/refaudio/hyprduel_boot45s.wav -seconds_to_run 45
48kHz mono, onset 17.67s (matches the documented 17.6s first note),
jingle 16-24s, demo music from 28s. Compare onset-aligned (our boot is
faster than MAME's); sim rate is 80MHz/2048 = 39062.5Hz - resample.

R2 AUDIO COMPARISON RUN 2026-07-10 (offline, vs fresh MAME reference):
envelope/timing PASS - 14s onset-aligned, note structure and a 5.5s
silent gap match at 0.5s resolution. LEVELS: sim = 0.81x MAME overall;
YM-dominated blocks 0.89-0.96, OKI-heavy blocks 0.70-0.79. Action for
R2: retune mix gains in hyprduel_sys (roughly YM x1.05, OKI x1.35 from
current 1.20/457 - the July 5 calibration was done against the
pre-arbiter-fix tree with corrupted OKI phrase reads). Verify by
rerunning this comparison (build/audio_current_1600.raw vs
build/mame/refaudio/hyprduel_boot45s.wav, resample 39062.5->48k,
onset-align) then by ear on the CRT. Do NOT stack into the pending
deploy build.

## Family roadmap (added 2026-07-11)

No other game is MRA-only; each tier is RTL work:
1. magerror (same TEC442-A board): VDP at 0x800000, different int-enable
   wiring, YM2413 for YM2151 (jt2413 exists - integration not invention).
   One-two sessions + bring-up. v1.1 candidate.
2. Metro-family (metro.cpp: Blazing Tornado, Toride II, Mouja, ...):
   i4100/i4220/i4300 VDP reuse is the done 80%, but boards use a single
   68000 + uPD7810 sound MCU - no known RTL uPD7810 exists. GATING
   RESEARCH: survey for a 7810 core before promising any of these.
   Announce I4220 reusability in the hyprduel release notes to attract
   collaborators.

## RESOLVED 2026-07-19: the top-lines deviation no longer exists

The "top ~4 visible lines" deviation described in earlier revisions of
this plan was fully root-caused and eliminated (ACCURACY.md 3.3): the
game programs the CRTC vertical display window to start at chip line 2,
so those lines were a hidden work area the real monitor never showed.
v15 implements the programmed window; the CRT shows what the arcade
monitor showed. Nothing to document as a deviation; documented instead
as a finding (README, docs/mame_bug_report.md).
