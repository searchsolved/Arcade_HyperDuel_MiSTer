# Handoff: game PLAYS on hardware; sub-CPU lag suspected for remaining issues (2026-07-08 late)

Written at the end of the session that took the core from all-green black
screen to playable gameplay on the CRT. Everything below is verified fact
unless marked open. Git: three commits tonight, working tree has ONLY the
debug-probe additions (ovr counter, live p1p2 row) uncommitted-if-any -
check git status. Prior doc: handoff_black_screen_state.md (now historical).

## Tonight's three root-cause fixes (all committed, all on hardware)

1. **62e3b47 - sr3 arbiter starvation.** The shared3 arbiter's pick-next
   branch required o_sr3_req==0 but o_sr3_req = m_req||s_req: dead code,
   sub CPU could NEVER be granted. Hung on its first sr3 access inside the
   YM IRQ handler; 0xFFF34C handshake never completed; main waited forever.
   Fix: explicit in-flight tracking (sr3_infly) + registered request
   (sr3_req_r). Proof: frame-10 frozen-bus dump, then sim boots to title.

2. **6b88ca9 - P_RET=4 in the SHELL vs 3 everywhere in sim.** Old blind
   bring-up guess. Single reads masked it (SDRAM bus float holds last
   value); bursts returned data shifted +1 word, so the MUSE signature
   scan read "SE.." at word 0 and scanned banks forever (SCTL stuck 01).
   Proof: bank-gated capture showed word0=5345 (word1's data) on CRT.
   Fix: P_RET(3). Result: first graphics ever on hardware.
   LESSON: audit every shell-vs-sim parameter override (PIXDIV and P_RET
   were the two; both bit).

3. **5f242e8 - sprite buffer copy off-by-one.** The P_SPR_BUFFERED vblank
   copy (from the BRAM conversion) wrote spr_buf[k]=spriteram[k-1]: data
   path has TWO cycles of latency (BRAM q + cp_q) but write addr lagged
   one. Every sprite's attribute words shifted one slot; zoom field read
   zero bits = ztab[0] = 2.67x enlargement from wrong gfx address = the
   striped garbage photo. ALSO: the long-standing "vdp-verify 900/1500 =
   pre-existing mid-frame raster issue" was a MISATTRIBUTION - those
   frames just contain sprites (500 has none). After the fix the ENTIRE
   parity suite passes for the first time (verify, blit-verify,
   render-verify, mame-verify, vdp-verify 500/900/1500).

## Current hardware state

Game boots, attract runs clean (Technosoft, logo, demo), game starts,
sound present. Debug overlay rows (current build):
1 SUMS (BE3A = GFX checksum via single reads)
2 OVRC (dropped render kicks - overrun counter) [reading PENDING]
3 P1P2 (live input word - VERIFIED: FFFF idle, FFF7 right, FFFB left)
4 B3E0 (4D55 = MUSE word sanity)   5 SCTL/IAK1   6 WCNT   7 SRRC
8 RSDP   9 REFC (live)

## Open issues and the evidence

**A. Ship banks but never moves; speed rubber-bands; rare 2-frame
freeze at boot.** KEY INSIGHT: inputs are PROVEN to reach the game
(live P1P2 row + the ship banking animation responds). The position
never updates. On this board the sub 68000 is a game co-processor
(not just sound); main and sub sync through shared3 EVERY frame (see
MAME's spin_until/cpusync kludges around 0xFFF34C / 0xC00408). Our sub
fetches EVERY instruction via the SDRAM sr3 port (~15-25 sys clocks
per word, budget ~32 at 10 MHz) and the arbiter gives main ABSOLUTE
priority. Theory: sub runs chronically late / occasionally starved ->
sub-owned state (ship position) freezes, frame sync stretches (speed
surges), and a boot-time phase can hard-stall (2-frame freeze; cleared
by reload). NEXT STEPS in order:
  1. Arbiter fairness: bound main's priority (e.g. after N consecutive
     main grants with sub pending, grant sub). Small, sim-verifiable.
  2. Measure sub fetch stall in sim (count SB_SR3 wait cycles/frame).
  3. Consider shadow-BRAM for the hot sub code region if fairness is
     not enough (shared3 is 112KB total - too big to BRAM whole; but
     the RO shadow region 0x4000-0x1FFFF suggests code locality).
  4. The DECISIVE test: lockstep attract parity vs MAME (below) - the
     attract demo plays the game autonomously, so sub lag shows up as
     frame divergence vs MAME with NO controller needed.

**B. Image jumps a few lines occasionally.** Suspect mid-frame scroll
capture timing (raster splits). Diagnostic: per-line register write log
diff - MAME Lua logs (frame, scanline, reg, value) for every VDP write;
sim logs the same; diff the split points. MAME Lua gotchas are in
docs/audio_bug_ym_irq_storm.md (pin taps with _G, never tap 0x800000,
never call screen:frame_number() in callbacks; use vpos()).

**C. D-pad unverified.** The stick works into the core. If the d-pad
does not change row 3, it is MiSTer OSD mapping, not core.

**D. Latent, non-blocking:** sub RO shadow (s_sel_ro3) only covers
0x4000-0x7FFF and maps to the WRONG sr3 words (0x0000+ instead of
0x10000+); MAME says 0x4000-0x1FFFF aliasing 0xFE4000+. Boot never
touches it. Fix range + offset for accuracy.
Also: one boot-time freeze race exists (single occurrence; reload
cleared it) - likely the same sub-sync sensitivity as issue A.

## Accuracy programme (agreed plan, run after A-C)

1. Long-run lockstep frame parity: MAME Lua screenshot every N frames
   across the whole attract loop vs sim PPMs; auto pixel-diff; bisect
   first divergence. (Attract = deterministic, frames align.)
2. Per-line raster write log diff (directly targets issue B).
3. Frame-boundary memory checksums (VRAM/pal/spriteram/workram) in both.
4. Synthetic feature matrix from imagetek_i4100.cpp (windows, flip,
   8bpp, blitter modes, priority masking) as tb_vdp states - protects
   the other Metro titles later.
5. Audio: YM/OKI register stream diff + rendered RMS per section.
6. Scripted-input gameplay parity (hardest, strongest claim).
Ceiling caveat: MAME is the only oracle (its own driver has TODOs and
sync hacks); beating MAME needs real-PCB captures.

## Infrastructure notes for the next session

- Renderer margin at hardware divider: worst_line 5008/5088 in attract
  (PIXDIV12 sim). OVRC row now counts overruns on silicon. If gameplay
  overruns: sprite-list prescan during the vblank copy (record live
  sprite indices; per line iterate ~12 live instead of 256 slots) is
  the big win.
- Debug aids: +SPRDBG / +SPRTRC plusargs in i4220_render (VERILATOR
  ifdef'd); GFX checksum self-test in hyprduel_sdram (tag 7, SUM_BASE
  GFX_WBASE+0x32000, expect BE3A; sim fallback trigger after ~65k idle
  cycles because tb preloads the model without a download).
- Sim at hardware divider: make boot SDRAM=1 FRAMES=N PIXDIV12=1.
- Runbook (compile/deploy/gates/CRT protection): see
  handoff_black_screen_state.md "Runbook" - unchanged, still accurate.
- sr3 word mapping quirk: byte 0xFFF34C = sr3 word 0x1D9A6 (the
  m_ba[17:1]-0x2000 mapping puts 0xFE4000 at word 0x10000, NOT 0).
