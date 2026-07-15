# Handoff 2026-07-15 night: the top-lines bug needs a new approach

Read top to bottom. Companion: handoff_opus_2026_07_12.md (environment
pitfalls, all still true), ACCURACY.md, plan_refresh_measurement.md.
Repo committed+pushed through 6e09a71 (+ this doc).

## THE ONE LESSON THAT MATTERS

Three consecutive fixes (v2 conditional late kick, v3 X prediction,
v6 h88-late-kick + line-1 prediction) each shipped with register-level
verification that PASSED, and each still showed the artifact on the
CRT. Register-freshness metrics are NOT visual correctness. Do not
ship a fourth fix without reproducing the artifact VISUALLY in sim
first, then showing it gone in the same pixels.

Lee's display is an 800-line PVM, razor sharp; when he counts
scanlines, treat it as exact measurement, not impression.

## Current deployed state (v6, builds/Hyprduel_v6.rbf, md5 69244a81)

- Working well per Lee: stage-7 boss tearing gone, audio mix right,
  slowdown authentic, Free Play via combined Coinage MRA dip (game
  needs BOTH coin slots = Free Play - MAME-verified game quirk, not a
  core bug), boot legal screen (SERVICE bit14, OSD option), high score
  save/restore (Hiscores_MiSTer + sr3 SDRAM shadow arbiter, autosave
  default on), 60.24 Hz native + compat toggle.
- Black tearing from v5 (all-lines late kick starving heavy gameplay
  lines) is believed fixed by the v6 adaptive backoff (lk_cool: any
  completion on the line's own display row reverts kicks to h0 for
  ~255 frames). NOT yet confirmed by Lee under heavy play - ask.
- STA: core clock +0.713, HDMI pixel clock +0.070 (thin; seed-sweep
  before any release build).

## OPEN BUG 1 (the big one): top-lines artifact in scroll-ramp scenes

Lee's latest observations on v6 (2026-07-15 night):
1. Artifact STILL present in the cloud scenes (stage 2 after the
   stage-1 transition, stage-2 boss, stage 6 - visible in the stage-6
   attract demo too, so SIM-REACHABLE).
2. With the scanline ruler on (OSD O[10]: line 0 red, line 1 cyan,
   line 2 yellow): "it's on all lines" = lines 0, 1 AND 2 all show it.
   Get an exact count of how far down it extends next session.
3. He checked a 1CC longplay of the arcade PCB: stage 6 top lines are
   CLEAN on real hardware. The artifact is definitively ours.
4. NEW/uncertain: "a bigger section slightly white on the title
   screen" - possibly a v6 regression (line-1 prediction writing
   garbage rows? hiscore sr3 arbiter interference? bank parity?), or
   long-standing and only just noticed. CHECK FIRST - a regression
   here may share the root cause.

### Why "all lines" breaks the working theory

Everything so far assumed per-line scroll-register staleness:
- v2 late-kicked lines 0/2 (sy fresh) - artifact persisted
- v3 predicted lines 0-1 X - persisted
- v6 late-kicks ALL lines at h88 (sy fresh for every line, verified
  register-exact vs scanout-start for lines 2-223) + line-1 fg
  prediction (sx0/sy1/sx1/sx2, offline-validated) - persisted, and on
  the very lines (1, 2) whose registers are now provably fresh.

If lines whose input registers are correct still render displaced,
the fault is likely BELOW the register layer. Prime suspects, in
order:

(a) LINE-BUFFER BANK / PARITY HANDOFF at the frame boundary. 4 banks,
    2-bit bank = line[1:0], cur_par/frame_par parity, bank_tag
    validation at scanout. frame_par flips at vcnt==vlast-1 h0; line
    0's kick happens at vlast h88 (late) or h0. If the parity/tag
    logic lets scanout accept a bank still holding the PREVIOUS
    frame's content for the first line(s), the top lines show
    year-old pixels: displaced clouds that move "weirdly" - EXACTLY
    the symptom, independent of scroll freshness. The late-kick
    changes moved kick timing right around this boundary. Audit
    i4220_vdp.sv bank_tag / cur_par / frame_par / scanout-accept
    logic cycle by cycle for lines 0-3, under BOTH h0 and h88 kicks.

(b) RENDER-VS-LIVE-REGISTER RACE under lk_ramp: rs_sw is a live
    registered view (1 clk behind r_scroll). A late-kicked line
    renders h88..~h330 of its kick line; verify NO writes land inside
    that window for any reg the render still reads (windows, screen
    ctrl, tiletable base...). The sy/sx audit only covered scroll.

(c) The v6 line-1 prediction mux (rnd_line1 gating rs_sw register
    load): if rnd_line1 mis-times, OTHER lines can render with
    pred_sw values (would corrupt neighbours; check the white title
    section). Kill switch test: build with the mux disabled and see
    if the title-screen whiteness goes away.

### THE PLAN (do it in this order)

STEP 0 - reproduce visually in sim. Everything else waits on this.
  - The stage-6 attract demo shows the artifact (Lee confirmed), and
    seed 7 plays the cloud rotation: frames 1342-2178, PPMs land in
    sim/build/boot* every 30 frames already. 3600-frame run with
    +verilator+rand+reset+2 +verilator+seed+7 (same binary =
    deterministic rotation).
  - Extract the top 12 rows of every ramp-frame PPM plus rows 12-40
    as "body reference". The artifact = top rows' cloud pattern
    offset horizontally/vertically vs the body across consecutive
    frames. Write a scanner (numpy or plain PPM parse, tools/) that
    computes, per frame, the x-correlation shift of rows 0,1,2,3...
    vs the body rows. The PCB reference behaviour: shift == body
    shift for all rows. Ours should show the mismatch on rows 0-2+.
  - If the PPM cadence (every 30 frames) hides it, run a short window
    (frames 1490-1530) with +DUMPEVERY hacked in the Makefile (the
    boot target hardcodes it before PLUSARGS - edit the Makefile, do
    not fight the plusarg precedence quirk).
  - DECISION GATE: if sim shows the artifact -> iterate locally
    against pixels (fast, no CRT). If sim does NOT show it -> the bug
    is physical-hardware-path only (SDRAM latency, analog output
    timing, scandoubler...) and the whole investigation changes; also
    compare MAME's top lines for the same scene.

STEP 1 - check the suspected v6 regression (white title section):
  diff title-screen PPMs between a v6-equivalent sim binary and the
  pre-v6 commit (be57dc5). If v6 introduced it, bisect the three v6
  mechanisms (pred mux, h88, backoff) - likely the pred mux (c).

STEP 2 - bank/parity audit (a) with a tb assertion: at scanout start
  of each display line, assert the bank being read has
  {parity, line} tag matching the CURRENT frame; count and log
  violations per line. If violations land on lines 0-2 in ramp
  frames, that is the root cause and the fix is in the tag/parity
  logic, not scroll timing.

STEP 3 - only after 0-2: revisit scroll freshness with the visual
  scanner as the acceptance test. All the register-level machinery
  (h88 kick, backoff, line-1 pred) is sound engineering - keep it -
  but the artifact's true cause must be pinned visually first.

### Tools/data already in place
- tools/xpred_hunt.sh, tools/fgpred_replay.py, fgpred_crosscheck.py
- +LINECOST=path tb log (per-line render cycles); ramp line costs:
  median ~2450, max 2836 (lines 0-3), global worst 3518.
- +LATELOG, +RASTERLOG (raster_writes/kicks CSVs), +FGLOG removed.
- perline_delta.py in old scratchpad; NOTE its line-0 row pairs
  kicks across the frame boundary (off-by-one) - line-0 numbers from
  it are unreliable.
- Measured write schedule (v0 = line 0): sx0 h180-220, sy0 h200-240,
  sx1 h220-280, sy1 h240-300, sx2 h260-320; per-line sy0/sy2 writes
  h36-76 on all other lines; vblank tail writes v250-260 h37-57.
- Scanline ruler O[10] on hardware for Lee-side line identification.

## OPEN BUG 2: white-ish section on title screen (see STEP 1)

## Environment quick reference (details in handoff_opus_2026_07_12.md)
- Compile PC: leefoot@192.168.1.207 (key auth), C:\hyprduel\mister,
  fire schtasks /run /tn hyprcompile (~21 min), gate on
  output_files/Hyprduel.sta.rpt "Worst-case setup slack" AND matching
  RBF/STA timestamps. Seeds: QSF SEED line (currently 1), never 5.
  WoL MAC 28:c5:d2:ef:93:31 (untested).
- MiSTer: sshpass -p 1 ssh -o StrictHostKeyChecking=no -o
  PubkeyAuthentication=no root@192.168.1.208 (DHCP - scan if moved).
  Deploy: menu core first, scp to /media/fat/_Arcade/cores/
  Hyprduel.rbf, md5 both sides, load_core the MRA.
- Sims: ~90 min/3600 frames solo; concurrent sims halve speed and
  clobber build/boot PPMs + raster CSVs; kill strays after restarts
  (pgrep -fl "Vtb_system|ladder|hunt").
- Verify suite: cd sim && make verify render-verify mame-verify
  vdp-verify blit-verify = 22 PASS lines, required before any compile.
- Rotation nondeterminism: same binary + +verilator+rand+reset+2
  +verilator+seed+N = deterministic; ANY rebuild changes the rotation.
  Seed 7 plays the clouds on the current binary lineage.
- Lee's standing preferences: measurements before claims, no em
  dashes in output, commit+push when verified, deploys need his
  MiSTer powered on.

## Release queue (blocked on bug 1)
R2 release: golden RBF (seed-sweep the thin HDMI clock), MRA with
hiscore + Coinage, releases/ + update_all db, teaser post
(docs/teaser_post.md), MAME upstream note (docs/mame_upstream_note.md,
Lee to send), licence/attribution pass (jt51/jt6295/fx68k/hiscore.v
GPL), short public beta before wide release.
