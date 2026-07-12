# Plan: lockdown completion through public release

Status date: 2026-07-12 00:30. Current deployed build: Hyprduel_audio_pcb.rbf
(zero-tear renderer through stage 6 + hardware-measured OKI clock/balance).
Sole known visual defect: heavy-scene tearing at the stage-7 boss.

## Phase L: renderer lockdown completion (in progress tonight)

- L1. Envelope measurements (RUNNING): per-line tilemap worst, sprite-pass
  worst, sustained sprite fill rate under SDRAM contention. Replaces the
  estimated terms in the worst-case arithmetic (docs history 2026-07-11).
- L2. Scan-ahead (IMPLEMENTED, render-verify 4/4): the sprite-list scan
  runs during the previous sprite's fill and parks on the next accepted
  sprite; hides the entire reject-scan tax (~500 cycles on a full list).
  Ladder: full suites -> bomb -> 5200 soak -> envelope re-measure.
- L3. Close the provable bound if L1/L2 numbers say it is still open:
  - Full front-end pipelining: next sprite's reads/coverage/dy-divide run
    into shadow registers during the drain; commit at handoff. Design
    notes: conflicts are sattr/s_bpp8/s_group/s_prival (shadow these),
    ROM issue must wait for fill_done, div engine free after div_bg.
    Worth ~35 cycles per drawn sprite.
  - And/or arbiter improvement if measured fill rate < ~1.6 B/cycle:
    raise sprite-stream grant share during the sprite pass.
  - Acceptance: our per-line envelope >= the real chip's fetch ceiling
    (~2,300 sprite bytes/line, from the 64-bit bus + mask ROM timing),
    stated with the measured arithmetic in ACCURACY.md.
- L4. Stage-7 boss as a permanent regression scene: reach the boss in
  MAME (cheats/autofire or savestate), dump VDP state via the existing
  dump_state flow, add to the render harness; target 0 over-budget.
- L5. Final verification sweep on the finished renderer: 22-check suite,
  bomb, 5200 + 9000 soaks, compile, STA gate, deploy, and Lee's full
  1cc on the CRT. Zero anywhere or back to L3.

## Phase A: audio finalisation

- A1. Matched-tune balance: longer attract capture so both recordings
  contain the same passages; finalise the OKI gain (196 is provisional,
  direction verified). Criterion: voice/music within ~10% of the PCB
  capture on the same tune.
- A2. Robustness check of the 2.000 MHz clock with a second sample
  (different spectral content) from later in the 1cc footage.
- A3. Lee ear test: core vs PCB video side by side.

## Phase R: release (supersedes the R-phases in plan_release.md where they overlap)

- R1. Debug overlay removal (frees timing margin; keep behind an ifdef
  for future bring-up work). Recompile, STA, redeploy.
- R2. Input/config completeness: d-pad vs stick verification, 2P inputs,
  DIP sheet check against the manual, MRA final pass.
- R3. Refresh-rate measurement from the 1cc footage (scroll-slope
  method) to confirm or correct our 60.01 Hz against real hardware.
  MAME's 60 Hz is flagged unverified in their source.
- R4. ACCURACY.md final numbers + reproduce commands; deviations list
  final (top-lines carries the full 2026-07-11 characterisation).
- R5. Repo and licensing: fx68k/jt51/jt6295 license compliance, sim
  harness bootstrap docs (MAME dump flow), README, credits.
- R6. Announcement: technical post (drafted, Lee's tone notes applied),
  hold until stage-7 is zero so the tearing claim carries no asterisk.

## Parked / stretch (documented, not scheduled)

- Top-lines raster phase: needs attract-mode PCB footage (search
  periodically) or a logic analyser on a real board. Do NOT fix blind.
- Real-PCB slowdown parity automation: compare our effective frame rate
  against the measured hardware profile (38 Hz stage-6 boss etc.) on
  matched scenes.
- PAL dump outreach (442A21-28, 442X29): would allow gate-level glue
  verification. Worth a forum ask at release time.
- magerror v1.1 (needs jt2413); wider Metro family (each title needs
  its own verification pass; uPD7810 titles gated on that core existing).
- MiSTer input-binding fluke: controls can be dead right after a core
  load (ARM-side binding, not our RTL); reload the core. Consider
  reporting upstream if reproducible.

## Standing verification gates (unchanged)

Every RTL change: 22-check parity suite green before any hardware build.
Every hardware build: STA setup slack positive on every clock (seed
sweep 2..5 as needed). Every deploy: CRT-protect with sonic.mgl first.
Renderer changes additionally: bomb test + soak zero over-budget.
