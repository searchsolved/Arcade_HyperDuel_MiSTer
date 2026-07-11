# Release plan: Hyprduel_MiSTer public core

Goal: first public Imagetek I4220 core. This doc is the gap between
"plays correctly on Lee's CRT" and "released MiSTer core".

## Phase R1: lock down (current, nearly done)

- [x] Prescan + tag blanking + 2px emit + 16-bit fetch (sim-verified)
- [ ] Deploy combined build, STA gate, CRT bomb/jitter test  <- NEXT, needs home LAN
- [ ] Commit everything (six logical changes, each parity-gated)
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

## Known deviation to document in README (added 2026-07-11)

Top ~4 visible lines: parallax offset is one frame stale. The game
writes per-line scroll just-in-time at each hblank; the renderer (like
the real line-buffered I4220) draws one line ahead of the beam, so the
first lines of each frame use vblank-parked values. Authenticity
UNDETERMINED - the real chip likely behaved identically (same lead) and
arcade bezels hid these lines; resolve via real-PCB footage if ever.
Do NOT "fix" without a reference. MiSTer vertical crop reproduces the
cabinet presentation.
