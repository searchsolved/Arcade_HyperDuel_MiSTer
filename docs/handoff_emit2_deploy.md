# Handoff: 2px/cycle emit compile in flight, deploy + bomb test pending (2026-07-09 ~09:45)

Session ended with a Quartus compile RUNNING on the PC. This doc is the
complete plan to land it, plus fallbacks and the onward roadmap.

## Where things stand

### Hardware (MiSTer, 192.168.1.208)
Running the TAG-FIX build (prescan + tag-based scan-out blanking,
clk_sys slack +0.208). HW-VERIFIED by Lee on the CRT:
- top-of-screen garbage GONE
- controls WORK
- REMAINING: brief black tearing bands when using bombs (renderer
  genuinely over line budget on bomb shockwave frames; blanking now
  degrades them gracefully to bg-colour bands instead of corruption)

### Uncommitted work in the repo (all of it, nothing committed this session)
- rtl/i4220_render.sv: sprite PRESCAN reject (new pst port, RD2 skip,
  lline_adj check) + 2PX/CYCLE EMIT rewrite (spr_mem 512x20 -> 256x40
  pair-packed, PRIM3 state, dual accumulators s_xi0/s_xi1)
- rtl/i4220_vdp.sv: prescan table (u_spr_pst, 2 M10K) + snoop engine on
  the vblank copy + ztab_of() + TAG-BASED scan-out blanking (bank_tag,
  frame parity through kick FIFO)
- sim/tb/tb_render.sv, tb_vdp.sv: new/missing port hookups
- sim/tb/tb_system.sv: prescan_rejects + over_budget_lines stats
- mister/Hyprduel.qsf: SEED 1 -> SEED 2 (matches PC known-good override)
- builds/: Hyprduel_prescan_good.rbf (+0.902 slack, hw-good, NO tag fix
  - has the counter blanking bug), Hyprduel_tagfix_deployed.rbf
  (currently on the MiSTer, +0.208)

Commit message suggestion when Lee approves: three logical commits or
one: "render: sprite prescan + 2px/cycle emit; vdp: tag-based scanout
blanking" - full parity suite green at every stage.

### Verification state of the 2px emit change (NOT yet on hardware)
- Full parity suite 22/22 bit-exact vs oracle + MAME (incl. frames
  900/1500 sprite-heavy, scene3 which catches odd-alignment seeding
  bugs - an earlier draft FAILED there with 71 px, fixed by seeding the
  start-pixel half in PRIM2 and deriving the other half in PRIM3)
- Boot sim perf run NOT done (measurement sim was hogging obj_sys when
  the session ended). Run it:
    cd sim && make boot SDRAM=1 FRAMES=620 PIXDIV12=1
  Expect worst_line_cycles well under 4010 (prescan build's number);
  budget is 5088. Also rerun the deeper measurement if wanted:
    make boot SDRAM=1 FRAMES=1500 PIXDIV12=1
  tb_system now prints over_budget_lines= and last_over_frame=.

### Compile in flight on the PC (leefoot@192.168.1.207)
- hyprcompile task fired 2026-07-09 09:39:49 BST with the emit2
  renderer. ~25 min => done ~10:05. Log: C:\hyprduel\mister\compile8.log
  (append mode, banner "===== flow start 09/07/2026 09:39").
- Check completion:  ssh leefoot@192.168.1.207 then
    powershell "Get-Content C:\hyprduel\mister\compile8.log -Tail 6"
  Want "Quartus Prime Shell was successful. 0 errors".

## Deploy runbook (after compile succeeds)

1. STA GATE - Setup Summary must be >= 0 on EVERY clock:
     ssh leefoot@192.168.1.207 "powershell -Command \"$t=Get-Content C:\hyprduel\mister\output_files\Hyprduel.sta.rpt; $i=($t | Select-String '; Setup Summary' | Select -First 1).LineNumber; $t[($i-1)..($i+10)]\""
   SEED CAVEAT: the tag-fix build passed at +0.208 and works, but
   +0.192 historically coincided with broken controls. If clk_sys
   (emu|pll line) lands below ~+0.20, prefer a seed sweep before
   deploying: edit SEED in C:\hyprduel\mister\Hyprduel.qsf (try 3,4,5;
   keep BALANCED + TDS OFF), rerun hyprcompile, pick the best slack.
2. CRT protect:  sshpass -p "1" ssh root@192.168.1.208 "echo 'load_core /tmp/sonic.mgl' > /dev/MiSTer_cmd"
   (recreate /tmp/sonic.mgl if the MiSTer rebooted)
3. Pull + push RBF:
     scp leefoot@192.168.1.207:C:/hyprduel/mister/output_files/Hyprduel.rbf /tmp/
     sshpass -p "1" scp /tmp/Hyprduel.rbf root@192.168.1.208:/media/fat/_Arcade/cores/Hyprduel.rbf
     sshpass -p "1" ssh root@192.168.1.208 "sync; echo 'load_core /media/fat/_Arcade/Hyper Duel.mra' > /dev/MiSTer_cmd"
4. HW TEST (Lee, on the CRT):
   - controls (ship moves) FIRST
   - bomb repeatedly during busy scenes: black tearing bands should be
     gone (emit now 2 px/cycle; sprite-crossing cost halved)
   - top of screen stays clean; attract stays clean
   - OVRC row on the debug overlay during bomb spam: if it stays 0000,
     the renderer never drops a kick and we are done with performance
5. ROLLBACK if anything regresses:
     sshpass -p "1" scp builds/Hyprduel_tagfix_deployed.rbf root@192.168.1.208:/media/fat/_Arcade/cores/Hyprduel.rbf
   then reload the MRA as above. (builds/Hyprduel_prescan_good.rbf is
   one step further back: better slack but has the counter-blanking bug
   = top-line garbage during bombs.)

## If bomb tearing persists after emit2

Order of attack:
1. Measure first: read OVRC after a bomb-heavy session; rerun the 1500
   frame sim and check over_budget_lines. If sim shows 0 but hw tears,
   suspect SDRAM contention differences (GFX fetch latency under
   sub-CPU cache misses + OKI + refresh) - add a worst-line hw probe
   row to the overlay (track max rnd_busy cycles per line in vdp,
   expose like OVRC).
2. Next throughput lever: 16-bit GFX ROM streaming (halves fetch time;
   touches hyprduel_sdram return path, vdp arbiter, renderer GRCV
   byte-pair fill). Fetch is now a bigger share of sprite cost since
   emit halved.
3. Then: overlap fetch with emit (stream bytes into srowcache while
   emitting pixels whose bytes have arrived; saves the serial fetch
   latency entirely for 1:1-zoom sprites).
4. Tilemap passes (3 sequential ~600-cycle passes) only if truly needed.

## Onward roadmap (after this lands)

1. Issue C - line jitter (raster split timing). Tooling BUILT:
   MAME: sim/mame/tap_raster.lua; sim: +RASTERLOG plusarg in tb_system.
   Run both, diff CSVs, divergent (frame,vpos) rows point at the fix.
2. Speed parity: attract-diff showed 8 static frames PIXEL-IDENTICAL to
   MAME at PIXDIV12 through the full system - strong. Moving-demo
   frames need per-frame dumps to quantify the offset (MAME's kludged
   boot makes early frames incomparable). Note: fx68k + jt51 are
   cycle-accurate, real dual-port shared RAM instead of MAME's
   spin_until hacks - we may legitimately be MORE accurate than MAME
   on timing. Real-PCB footage (YouTube 1cc run) is the true oracle.
3. Accuracy programme: feature matrix (flip screen, 8bpp, blitter
   modes, window edges), audio RMS vs MAME (method proven), scripted
   input parity for gameplay scenes attract never reaches.
4. Release hygiene: REMOVE the debug overlay (it cost -2.2ns once
   before the pipeline fix; removal buys slack margin for free),
   confirm d-pad vs stick mapping, MRA polish.

## Key invariants (do not regress)

- Every renderer edit: FULL parity suite (make verify blit-verify
  render-verify mame-verify vdp-verify). scene3 catches emit
  alignment bugs specifically.
- Every hyprduel_sdram edit: make download + boot.
- QSF: BALANCED, TDS OFF, SEED 2 (repo QSF now matches the PC; the PC
  QSF has a duplicate SEED line - last one wins, currently 2).
- STA gate before every deploy; never deploy negative slack.
- Prescan correctness contract: the table stores per-sprite y/y_end
  from SPRITE WORDS ONLY (bit-identical ohv math); screen offsets are
  applied LIVE in the renderer's RD2 check, so a prescan reject is
  provably a subset of COVER2's reject. Never bake register state
  into the table.
- Blanking correctness contract: bank_tag compares {frame parity,
  line}; parity toggles at line 260 start, one line before line 0's
  kick is queued. Read-side only; never add logic to the linebuf
  write path (that's what broke controls in 96458e5).

## ADDENDUM 2026-07-10: raster jitter diagnosed (issue C) - sim-side complete

Raster write-log diff DONE (tooling fixed: MAME 0.288 screen:vpos()
faults in BOTH tap and frame-notifier Lua contexts - tap_raster.lua now
derives beam position from machine.time, diff_raster.py calibrates the
constant line offset; probe scripts verified all of this empirically).

FINDINGS:
- The game runs a per-line scroll raster effect (parallax) on layers 0
  and 2 during gameplay: one write pair per hblank IRQ, every line.
- OUR CORE SERVICES ALL 261 LINES PER FRAME, ZERO GAPS. MAME covers only
  ~230 of 262 - its kludged CPU timing misses ~14% of hblank IRQs
  (gaps every 7-8 lines). We are MORE faithful than MAME here; do not
  calibrate write timing against MAME.
- Our visible jitter mechanism: when the renderer falls behind on a
  heavy line, the following line renders while the beam is on it, AFTER
  the game already wrote the NEXT line's scroll value -> that line draws
  with its neighbour's parallax offset. Renderer throughput IS the
  jitter fix (same root as bomb tearing).
- Residual with 2px emit: 110 over-budget lines in ~1100 demo gameplay
  frames (worst_line 5445 vs 5088, frames ~1600-2700 attract demo).
  Each degrades to a 1-line bg blank with tag blanking. If soak says
  it's visible: next lever = 16-bit GFX ROM streaming.
- Frame pacing: sim tracks MAME within ~4 frames at boot; sequence
  positions drift later because MAME fast-forwards inter-CPU waits
  (attract title: sim reaches demo ~500 frames after MAME's frame
  count). Expected, not a defect.
- emit2 long-run stats: 1500f worst 4336 over=0; 2700f (incl demo)
  worst 5445 over=110. PPM 21/21 identical vs hw-verified prescan build.

Artifacts: sim/diff_raster.py, fixed sim/mame/tap_raster.lua, logs in
sim/build/raster_writes_sim*.csv + sim/build/mame/raster/.

## ADDENDUM 2026-07-10 (later): 16-BIT GFX FETCH DONE - deploy plan superseded

The PC compile from 09:39 (emit2-only) is OBSOLETE. The tree now also has
the 16-bit GFX ROM stream (word-mode: even-addr/even-len requests get 2
bytes per valid pulse, [15:8]=even byte; blitter len-1 reads keep byte
mode in [7:0]). Files: hyprduel_sdram.sv (word-mode emitter), sys/vdp/
render (width + pulse-count plumbing, GRCV pair fills), mister/Hyprduel.sv
(wire width), all three tb ROM servers.

Verification: make download 6/6 PASS, full parity suite 22/22 bit-exact,
scripted bomb test (inputs/inputs_bombtest.txt via +INPUTS, coin->start->
~1200 frames of live combat with 10 bombs):
  emit2 only:        worst 5583, over_budget_lines 3265
  emit2 + 16b fetch: worst 5196, over_budget_lines 35   (99% reduction)
Residual 35 lines/1200 frames = one invisible 1-line bg blank per ~0.5s
of max combat. Fetch/emit overlap remains the last lever if ever needed.

NEW DEPLOY PLAN (when home):
0. scp rtl/i4220_render.sv rtl/i4220_vdp.sv rtl/hyprduel_sdram.sv
   rtl/hyprduel_sys.sv leefoot@192.168.1.207:C:/hyprduel/rtl/
   scp mister/Hyprduel.sv leefoot@192.168.1.207:C:/hyprduel/mister/
   (do NOT push the whole mister/ dir - PC QSF has the SEED 2 override)
1. schtasks /run /tn hyprcompile, then the existing STA gate + deploy
   steps from the main runbook above. SDRAM edit on hw: watch the GFX
   checksum rows (SUMS/SUMB1/SUMB2 expect BE3A) still pass on the CRT.
2. HW test adds: bomb spam (tearing should be GONE), raster scenes for
   jitter, OVRC row should stay 0000.

Scripted-input harness is NEW tooling: tb_system +INPUTS=<file>, lines
"<frame> <p1p2hex> <systemhex>" (active-low; P1 bit4 shot, SYSTEM bit0
coin1, bit4 start1). Enables offline gameplay regression testing.

## ADDENDUM 2026-07-11: FIFO root cause, full build DEPLOYED, overlap in flight

- KICK FIFO LOST-UPDATE FOUND AND FIXED (commit b349bf5): same-edge
  enqueue+pop lost the push increment; count drifted low during
  saturated sections until the ring desynced and the renderer drew
  stale line numbers forever. Root cause of: historic issue-C line
  jitter (up to 3-line offsets), likely the rare boot freeze, and the
  permanent soak blackout at frame ~3400 (CRT-reproduced; OVRC 1B48
  climbing during title). Revert-tree soak proved it predates all
  2026-07-09+ work. Fixed soak: content cycles through all 5200 frames.
- FULL BUILD DEPLOYED 2026-07-11 14:33 (builds/Hyprduel_full_fifofix.rbf,
  clk_sys +0.228, gate passed). LEE HW-VERIFIED: controls OK, bombs OK,
  attract survives past the old death point. RESIDUAL: black tearing at
  stage-1 BOSS death and in stage 2 (gameplay + attract demo) = the
  measured heavy-scene over-budget (~17.9k lines in the stage-2 attract
  window; worst 5614 vs 5088).
- FETCH/EMIT OVERLAP PHASE A IMPLEMENTED (UNCOMMITTED, mid-verification):
  GISS folds the pair-walk setup + s_xs; GRCV/PRIME/PRIM2/PRIM3/EMIT
  replaced by ST_S_OVL with three engines (fill per ROM pulse, 2-cycle
  seed, emit chasing rx2 via s_emit_ok; flipped sprites emit after
  fill_done). spr_raddr prefetch is stall-aware (advance ? wcur+1 :
  wcur). Exit needs emit_done AND fill_done (right-clipped sprites).
  render-verify 4/4 incl. gap-server stall coverage. PENDING: remaining
  suites + bomb test + 5200 soak (stage-2 window is the metric: 17901
  to beat, target ~0). If short: Phase B = descending walk for flipped
  sprites; Phase C = overlap dx-divider under fetch (zoomed).
- Timing: this build compiled at +0.228 (SEED 2). The overlap adds an
  emit-gate cone + prefetch mux - expect tighter; seed sweep 3/4/5 if
  clk_sys < ~+0.2. NEVER deploy below the gate.
- Top-4-lines "delayed parallax" = one-line render lead vs just-in-time
  per-line scroll writes; authenticity undetermined (real chip likely
  identical); documented in plan_release.md; do not fix without PCB
  reference.
