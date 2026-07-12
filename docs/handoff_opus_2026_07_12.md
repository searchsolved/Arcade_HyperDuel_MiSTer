# Handoff 2026-07-12 evening: state, in-flight tasks, and exact next steps

Read this top to bottom before touching anything. Repo is committed and
pushed through the plan update (git log from 5c41176..). Companion
docs: ACCURACY.md (claims), plan_refresh_measurement.md (60.24 Hz
evidence), plan_next_steps.md (roadmap + today's verdict).

## Where things stand

DEPLOYED on the CRT and verified by Lee: builds/Hyprduel_v2g768.rbf
(262-line timing, measured OKI gain 768, conditional late kick).
Lee's verdict: stage-7 boss tearing GONE, audio mix GOOD, slowdown
authentic (matches measured PCB profile). ONE OPEN BUG: top-line
"clouds" strip in stage 2/4 gameplay (see below - the fix exists but
never engaged; the real PCB is proven clean so it must be fixed).

Measured facts (do not re-litigate, evidence in ACCURACY.md):
- OKI:YM mix 2.5:1 => okim gain 26'sd768 in hyprduel_sys.sv.
- Refresh = 60.2408 Hz = 424 x 261 dots. RTL now has runtime vlast
  (i_compat60: OSD status[7], native 261 default, 262 compat).
- MAME upstream note drafted: docs/mame_upstream_note.md (Lee to send).

## In-flight background tasks (check these FIRST)

1. V261 ladder - tools/v261_ladder.sh, task br4jylta3.
   Sequential: 5,200fr soak -> bomb test -> audio run -> raster log.
   Results land in sim/build/v261{soak,bomb,audio,raster}/run.log.
   PASS gates: soak+bomb must print over_budget_lines=0 AND
   late_lines=0 (the "late detail" line: beam_visible=0).
2. Ramp seed hunt - tools/ramp_seed_hunt.sh, task b0q0amcz5.
   Auto-starts when the ladder exits. Tries verilator seeds until an
   attract rotation plays the scroll-ramp (clouds) scenes; success =
   "RAMP SCENE FOUND with seed N" and build/ramphunt_N/ holds
   raster_writes_sim.csv, raster_kicks_sim.csv, late.csv.

## Step 1: gate the ladder, compile the V261 build

When the ladder completes and both soak+bomb gates pass:
- Audio closing-the-loop check (v261audio/): the jingle->announcer
  interval measured on the sim audio should now be ~4.099 s (it was
  4.1148 at 262 lines; the PCB recordings measure 4.1008/4.1018).
  Measure with the edge method in scratchpad audiofit/ or just:
  onset of OKI voice minus onset of first jingle note on a 1 kHz
  envelope of v261audio/mix.raw (raw s16le mono at 39,062.5 Hz).
  Within ~5 ms of the PCB numbers = the 60.24 Hz claim is closed.
- Raster check (v261raster/raster_writes_sim.csv): confirm the
  game's vblank writes still land where the late-kick windows expect
  under 261-line geometry: sy0/sy2 (addr 478870/478878) writes on
  the kick lines (vpos 260 for line 0, vpos 1 for line 2) at hpos
  <120. If they moved, adjust the lk windows in i4220_vdp.sv
  (search "lk_hit") before compiling.
- Compile: scp rtl/*.sv leefoot@192.168.1.207:C:/hyprduel/rtl/ and
  mister/Hyprduel.sv to C:/hyprduel/mister/, then
  `ssh leefoot@192.168.1.207 "schtasks /run /tn hyprcompile"`.
  ~21 min. Watch C:\hyprduel\mister\compile8.log.
- STA GATE (never skip): output_files/Hyprduel.sta.rpt "Setup
  Summary" - every clock slack must be >= 0; prefer clk_sys (the
  emu|pll row) >= +0.2. If thin, seed sweep QSF SEED 2,3,4 (NEVER 5:
  fails to fit at 98% M10K). CHECK THE STA TIMESTAMP matches the RBF
  timestamp - an earlier flow's report cost us a wrong gate today.
- Stage as builds/Hyprduel_v261.rbf. DO NOT auto-deploy: Lee should
  opt in to the timing change (game runs 0.38% faster; OSD toggle
  "Video Timing" reverts to 60Hz compat if his display complains).

## Step 2: the clouds fix (P1, the one open visual bug)

Background: the game runs a per-line Y-scroll ramp on layers 0/2 in
cloud scenes and rewrites sy0/sy2 during vblank/per-line. Our render
kick for lines 0/2 samples the registers before the game's writes
land -> top 2-3 lines show a stale scroll phase (a displaced strip).
PCB footage PROVES the real board is clean (shear scan + zoomed
frames, see plan_next_steps.md addendum). The v2 "conditional late
kick" (lk_pred in i4220_vdp.sv) was built from attract-mode write
timings and never fired in any verification rotation (sy_changed=0
= scenes absent, not fix working).

When the seed hunt finds a rotation (build/ramphunt_N/):
1. Analyze raster_writes_sim.csv during the ramp frames: for writes
   to 478870/478878, tabulate (vpos, hpos) per frame. Questions:
   (a) do writes for line 0 land at (vpos 260, hpos 70-100) as the
   attract analysis said, or later under load? (b) same for line 2
   at (vpos 1, ...). (c) any writes with hpos > 120 on those lines?
2. Check late.csv and the run.log "late detail" - with the current
   windows, did lk_pred fire (sy_changed > 0)? Did any late
   completion become beam-visible (hcnt >= 28)?
3. Fix accordingly. Likely outcomes:
   - Writes inside h<120: predictor is correct, and the earlier
     failure was only that verification never exercised it. Verify
     freshness: kicks CSV sy values at kick time must equal the
     just-written values (deltas 0) on lines 0/2 during ramp frames.
   - Writes later than h120 under load: move the late-kick point
     and the lk_hit/handoff windows later (budget shrinks 12 cycles
     per pixel moved; lines 0/2 measured cost in ramp scenes was
     light, but re-verify with the LATELOG counters).
4. Re-run THE SAME SEED (fully deterministic) to verify: freshness
   deltas 0, late_lines beam_visible 0, then the standard suite
   (make verify render-verify mame-verify vdp-verify blit-verify -
   22 PASS lines) and a 5,200fr soak WITH THE SEED THAT PLAYS THE
   RAMP (add +verilator+rand+reset+2 +verilator+seed+N to the soak).
5. Add the permanent assertion: any future soak must report ramp
   vblank sy-writes > 0 somewhere in the run, else the soak does not
   count as covering this scenario (rotation nondeterminism lesson).

## Step 3: queue behind (in order)

- High-score saving: MAME hiscore.dat entry: maincpu program
  0xFFF2A2 len 0x3C (start byte 00, end 01) + flag byte 0xFFF2E2.
  That RAM is sharedram3 = the sr3 SDRAM region. Wire the MiSTer
  framework hiscore module to a small sr3 access port (arbitrate
  behind the CPUs, vblank-only access is fine), add the hiscore
  block to the MRA. Test: set a score, power cycle, table persists.
- Release R2: docs/plan_release.md + plan_next_steps.md R-phase
  (golden RBF + MRA in releases/, update_all via custom db, teaser
  post docs/teaser_post.md is Lee-ready, MAME upstream note ditto).

## Environment pitfalls (each cost real time today)

- MiSTer ssh is PASSWORD auth: sshpass -p 1 ssh -o
  StrictHostKeyChecking=no -o PubkeyAuthentication=no
  root@192.168.1.208. BatchMode/key auth can never work.
  Deploy runbook: load menu core first (CRT protect), scp RBF to
  /media/fat/_Arcade/cores/Hyprduel.rbf, md5sum both sides, then
  echo load_core /media/fat/_Arcade/Hyper\ Duel.mra > /dev/MiSTer_cmd.
- Attract rotation is seeded from uninitialized RAM: every rebuild
  plays different demos (Verilator x-initial unique). Same binary +
  same +verilator+seed = fully deterministic. NEVER conclude a
  scene-dependent fix works without proving the scene played.
- Makefile plusarg quirk: the boot target passes +OUTDIR and
  +DUMPEVERY BEFORE $(PLUSARGS) and $value$plusargs takes the FIRST
  match - your overrides in PLUSARGS are IGNORED. PPMs always land
  in build/boot (or build/boot_sdram with make SDRAM=1) every 30
  frames; concurrent runs clobber each other's PPMs (counters and
  explicit +LATELOG/+AUDIODUMP paths are safe).
- Background sims killed by session restarts leave the ladder SCRIPT
  alive; it then runs later stages concurrently with relaunches.
  After any restart: pgrep -fl "Vtb_system|ladder|hunt" and kill
  strays before trusting progress numbers.
- Sim wall-clock: 5,200 frames ~93 min SOLO; two sims halve speed.
- cwd resets between shell calls: always cd with absolute paths.
- grep -c returning 0 exits nonzero and kills && chains; append
  "; true".
- PC compile: always verify Hyprduel.rbf AND .sta.rpt timestamps
  are from YOUR flow before gating on them.
- Windows PC: leefoot@192.168.1.207, project C:\hyprduel\mister,
  fire via schtasks /run /tn hyprcompile.

## Verification culture (non-negotiable)

Every RTL change: 22-check parity suite + relevant soak BEFORE any
deploy; STA all-clocks-positive gate before any RBF reaches Lee;
never claim a fix without a measurement that exercised it (today's
clouds lesson). Lee's standing preference: technical claims need
receipts; no em dashes in any output; commit+push when verified.
