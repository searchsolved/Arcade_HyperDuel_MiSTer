# Handoff: playable core, remaining visual issues (2026-07-08/09)

Git HEAD: 1239c1f (revert of the linebuffer clear that broke controls).
Last known GOOD hardware build: bcaf717 (instruction cache + round-robin).
The revert build is compiling and will auto-deploy.

## Session achievements (6 root-cause fixes, all committed)

1. **62e3b47 - sr3 arbiter starvation**: sub CPU could never be granted
   shared3. Fix: explicit in-flight tracking. Result: game boots in sim.
2. **6b88ca9 - P_RET=4 shell mismatch**: burst reads shifted +1 word on
   hardware. Fix: P_RET(3). Result: first graphics on hardware.
3. **5f242e8 - sprite copy off-by-one**: vblank copy wrote spr_buf[k] =
   spriteram[k-1]. Fix: 2-cycle lag. Result: full parity suite green.
4. **bcaf717 - instruction cache + round-robin arbiter**: sub CPU ran at
   ~1/10th speed (every instruction fetched via SDRAM). 1024-entry
   direct-mapped cache (3 M10K, 99.99% hit rate). Round-robin arbiter
   instead of absolute main-CPU priority. Shared3 RO shadow range/addr
   fix. Result: ship moves, game fully playable.
5. **96458e5 - vblank linebuffer clear (REVERTED in 1239c1f)**: attempted
   fix for top-of-screen garbage by clearing all linebuf banks to r_bg
   during vblank. Controls broke on hardware (suspected timing
   marginality: clk_sys slack dropped to +0.192). Top garbage also
   persisted. Approach needs rethinking.

## Current hardware state (on bcaf717 equivalent after revert deploy)

- Game boots, attract clean, fully playable, sound present
- Ship moves with analog stick (controls verified via live P1P2 row)
- D-pad untested vs stick (stick reaches core; d-pad may be OSD mapping)

## Open issues

### A. Top ~5% of screen shows garbage (persistent)

Stale linebuffer data from the previous frame is displayed before the
renderer has written the current frame's top lines. The renderer gets
kicked for line 0 at vcnt=261 (one line lead = 5088 clocks at PIXDIV=12).
If the renderer or its GFX ROM fetches take longer, display reads stale
pixels. The vblank clear approach (writing r_bg into all banks during
vblank) was tried and FAILED: it passed vdp-verify but broke controls
on hardware (timing marginality from the extra write mux on the linebuf
port A). Alternative approaches to investigate:

1. **Scan-out blanking**: instead of clearing the buffer, blank the
   RGB output (force black/bg) for the first N lines of each frame
   until the renderer has written them. Track a "lines rendered this
   frame" counter; if vcnt < lines_rendered, output normally, else
   output r_bg. Zero timing impact on the linebuf write path.
2. **Vblank pre-render**: kick lines 0-2 during late vblank after the
   sprite copy (tried, broke vdp-verify because synthetic tests load
   state mid-run and the pre-rendered lines used stale register values).
   Could work if gated on a "real boot completed" flag that tb_vdp
   never sets, but fragile.
3. **Renderer speedup**: if the renderer finishes line 0 within budget,
   the problem disappears. The worst_line is 5294 vs 5088 budget;
   reclaiming ~200 cycles fixes both this and the mid-frame flashes.

### B. Occasional mid-frame glitch flashes

Same root cause as A: renderer overruns (worst_line 5294 vs 5088
budget during gameplay scenes). When a heavy line exceeds budget,
display scans out the previous frame's data for that line. The
linebuffer clear would have shown r_bg instead, which is better but
still a glitch.

Fix: renderer cycle optimisation. Biggest win: sprite-list prescan
during the vblank copy (record which of the 256 sprite slots are
actually visible on each line; iterate ~12 active sprites instead of
all 256). Each skipped sprite saves ~6 cycles (RD0-RD4+ZOOM+COVER
check). 244 skipped sprites x 6 = ~1464 cycles reclaimed, well more
than the ~200 cycle deficit.

### C. Occasional line jitter

Mid-frame scroll register writes captured at different beam positions
than real hardware. Raster write-log tooling is BUILT AND READY:
- MAME: `sim/mame/tap_raster.lua` (logs frame,vpos,hpos,addr,data)
- Sim: `+RASTERLOG` plusarg in tb_system (same CSV format)
- Run both, diff the CSVs, the divergent lines point at the fix.

### D. Speed parity with MAME

Attract-mode lockstep diff showed our core runs ~30-60 frames behind
MAME because MAME's spin_until kludges skip polling loops instantly.
The instruction cache dramatically improved this. Worth re-running the
attract diff (tooling ready: `make attract-mame`, `make attract-diff`)
to measure the current gap. On real hardware the polling also runs in
real time, so our timing may be MORE accurate than MAME's.

## Accuracy tooling (built, ready to run)

- `make attract-mame FRAMES=620` - MAME PNG dump (already run, 21 PNGs
  in build/mame/attract/)
- `make boot SDRAM=1 FRAMES=620 PIXDIV12=1` - sim PPM dump
- `make attract-diff FRAMES=620` - pixel-diff all matching frames
- `+RASTERLOG` plusarg - sim-side VDP write log (CSV)
- `sim/mame/tap_raster.lua` - MAME-side VDP write log (CSV)
- `+SPRDBG` / `+SPRTRC` - renderer sprite debug (VERILATOR ifdef'd)
- GFX checksum self-test in SDRAM controller (tag 7, expect BE3A)

## Stall counters (round-robin, 230 frames at PIXDIV=12)

sub_wait_cyc=5215 main_wait_cyc=2965039 sub_grants=485 main_grants=286658
(cache reduced sub SDRAM traffic from 3.3M to 485 accesses)

## M10K budget

544/553 used before the cache; cache adds 3 blocks = 547/553.
6 spare M10K blocks remaining.

## Runbook (unchanged)

- Compile: scp to leefoot@192.168.1.207 C:/hyprduel/{rtl,mister}/,
  schtasks /run /tn hyprcompile, ~15 min (QSF: BALANCED, TDS OFF,
  SEED 2). GATE: Setup Summary >= 0 on every clock.
- Deploy: scp RBF -> root@192.168.1.208:/media/fat/_Arcade/cores/
  Hyprduel.rbf, then load_core via /dev/MiSTer_cmd.
- CRT protection: echo "load_core /tmp/sonic.mgl" > /dev/MiSTer_cmd
- Sim: cd sim; make download / boot / vdp-verify / render-verify /
  mame-verify / attract-mame / attract-diff.
- Every renderer edit: full parity suite. Every sdram edit: make download.

## Recommended priority order for next session

1. Renderer cycle optimisation (fixes A + B together, the two visible
   issues; sprite prescan is the high-value target)
2. Raster write-log diff (fixes C, the line jitter; tooling ready)
3. Re-run attract-diff to measure speed parity gap with cache
4. Remaining accuracy programme (feature matrix, audio, scripted input)
5. Remove debug overlay for release build
