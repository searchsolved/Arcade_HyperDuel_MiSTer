# Plan: Timing Closure First, Then Download Hardening

Supersedes the investigation direction in `docs/handoff_fable_download_fix.md`.
That handoff's two race hypotheses are NOT the root cause (analysis below).
This plan is grounded in new evidence gathered 2026-07-07: the design fails
timing closure, and the failing paths explain every hardware anomaly that sim
could not reproduce.

## Root cause evidence (verified 2026-07-07)

From tonight's build (`Fitter Status: Successful - Tue Jul 07 21:33:04 2026`,
`C:\hyprduel\mister\output_files\Hyprduel.sta.rpt` on the build PC):

- **clk_sys (emu pll outclk_0, 80 MHz): Fmax 68.05 MHz. Worst setup slack
  -2.195 ns, endpoint TNS -66.347.** Hold is clean. Every RBF deployed so far
  has shipped with this violation.
- Failing pairs, from `report_timing -setup -npaths 400 -pairs_only`
  (script left at `C:\hyprduel\mister\sta_pairs.tcl`, output `sta_pairs.txt`):
  - **346 pairs inside i4220_vdp**, worst -2.195: `i4220_render|o_vram_addr[*]`
    combinational cone into the `hd_dpram u_vram0/1/2` port B address registers.
  - **~35 pairs in the hex diagnostic overlay**, worst -2.180: `dbg_vcnt[*]` and
    the row-range comparators (`LessThan26*`) through hex_val mux + font lookup
    into `arcade_video|RGB_fix[*]`.
  - **19 pairs fx68k -> i4220_vdp**, worst -0.518 (CPU to VDP register interface).
  - **Nothing in hyprduel_sdram, the download FIFO, or the ioctl path fails.**
    The download logic meets timing.

### Why this explains the "impossible" hardware readings

- DLWR=2 with dl_grant_cnt=66 is impossible in RTL semantics (a grant
  unconditionally reaches CAS 3 cycles later and increments dl_written).
  Hardware showing RTL-impossible values means the OBSERVATION is broken:
  the hex overlay that renders those values is itself among the worst
  failing paths. The numbers on the CRT cannot be trusted.
- TEST=EFEF instead of BEEF: same. Could be display corruption, not a
  corrupted selftest write.
- Sim passes at realistic HPS pace (verified today: `make download` in `sim/`
  passes all 4 tests on the current working tree) because the sim runs the
  RTL semantics; the hardware runs a netlist with setup violations.
- vdp_cs RED / vdp_write RED and no game: with 346 failing paths inside the
  VDP and a failing CPU->VDP interface, the VDP is undefined on hardware
  even if the download is perfect. Metro-family boot code polls the blitter
  status; a garbage status read alone can hang boot.

### Status of the old handoff's hypotheses

- "FIFO pop clobbers dl_pend during CAS": cannot fire. The pop at
  `rtl/hyprduel_sdram.sv:296` is gated on `!dl_pend`, and dl_pend is 1 for the
  whole grant->CAS window of the entry being served. Do not chase this.
- "grant_cnt vs dl_written discrepancy": explained by the broken display
  (see above), not by FSM logic.
- Two REAL RTL defects do exist and are fixed in Phase 3, but they are not
  the boot blocker:
  1. Selftest/pop same-cycle race: `ST_WR_HI` (line ~241) is not gated on
     `dlf_empty`. If it fires in the same cycle as the FIFO pop block, the pop
     (textually later) overwrites `dl_addr_q`/`dl_data_q`, so the selftest
     write is silently replaced by a download byte.
  2. Aggressive-pace livelock: with T4's inter-byte gap reduced to 3 cycles
     (`repeat (2)` at `sim/tb/tb_download.sv:289`), the testbench wedges with
     dl_busy stuck high at ~byte 206 and never recovers even after the sender
     stops (reproduced today; the run passes at `repeat (15)`). Note the
     $display traces around the wedge show state sequences that are not
     RTL-legal, so they are sampling-skewed; diagnose with an FST wave dump,
     not prints.

## Phase 1: make the diagnostics trustworthy

Small, do first, everything downstream depends on believing the screen.

1. In `mister/Hyprduel.sv`, snapshot all dbg_* words once per frame (capture
   on vsync) into dedicated registers, and pipeline the overlay: register
   hex_row/hex_val selection and the font lookup over 2-3 stages before they
   reach the RGB mux. A couple of pixels of overlay latency is irrelevant;
   compensate the x offset or ignore it.
2. Widen `dbg_dl_dropped` to 16 bits and make it (and dl_grant_cnt) saturating
   instead of wrapping. An 8-bit wrapping drop counter reading 0x00 after a
   5M-byte stream is meaningless.
3. Keep the hex display itself; it works well on the CRT.

## Phase 2: close timing on clk_sys

Gate: `Setup Summary` in Hyprduel.sta.rpt shows slack >= 0 for every clock
before ANY hardware conclusion is drawn again. Check it after every compile;
tonight's failure was a Critical Warning (332148) that went unnoticed.

1. Pull full detail on the worst VDP paths:
   `report_timing -setup -npaths 10 -detail full_path -to *u_vram*` via
   quartus_sta -t (reuse `C:\hyprduel\mister\sta_paths.tcl` as a template).
   Identify the combinational cone feeding `o_vram_addr`.
2. Fix by pipelining, not by multicycle: the render engine runs at full
   80 MHz (ce_pix only paces scan-out, `rtl/i4220_render.sv:206-229`), so the
   CPU-style multicycle trick in `mister/Hyprduel.sdc` does NOT apply to the
   VDP. Insert a register stage on the VRAM address/request path (the fetch
   pipeline already tolerates BRAM latency; add one stage and adjust the
   return alignment). Re-verify the renderer against the MAME oracle dumps
   with the existing Verilator harness after any change (M1 workflow,
   `make` targets in `sim/`).
3. Fix the fx68k -> VDP -0.518 paths: register the VDP register-file
   write/read decode one stage earlier or add a wait state in the bus FSM.
   fx68k intra-core paths are already multicycled; this is the boundary path,
   which the SDC deliberately keeps single-cycle.
4. Recompile and iterate until slack >= 0. If the last few tenths of a ns will
   not close, dropping clk_sys to a PLL frequency the fitter can meet (e.g.
   72 MHz with P_PIXDIV and SDRAM parameters re-derived) is an acceptable
   fallback, but try pipelining first.

## Phase 3: harden the download path (sim-only, can overlap Phase 2 compiles)

The download logic meets timing and passes sim at realistic pace, so this is
robustness work, not the boot blocker.

1. Restructure `rtl/hyprduel_sdram.sv` so the FSM consumes the FIFO directly:
   grant in ST_IDLE on `!dlf_empty`, latch `dlf[dlf_rp]` into the address/data
   registers at grant time, assert dlf_pop in the same cycle. Delete the
   free-running pop-into-dl_pend block at line 296. Keep dl_pend exclusively
   for the selftest, or better, drop the selftest entirely; it has served its
   purpose (SDRAM writes proven on hardware) and it is the only other producer
   racing for dl_addr_q/dl_data_q.
2. Parameterize the T4 gap in `sim/tb/tb_download.sv` and sweep gaps
   {2,3,4,8,16}; all must pass with zero drops and dl_written == dl_count.
   Diagnose any remaining wedge with `--trace-fst`, not $display.
3. Add a T5 modeling hps_io skid: a few ioctl_wr strobes may still arrive
   after ioctl_wait asserts; the 16-deep FIFO with busy at >= 12 gives 4
   slots, verify that margin explicitly.
4. Run `make boot SDRAM=1 FRAMES=30` before any hardware deploy.

## Phase 4: hardware verification

1. Compile: `schtasks /run /tn hyprcompile` on `leefoot@192.168.1.207`
   (kill stale quartus_fit.exe first), ~15-20 min, log at
   `C:\hyprduel\mister\compile8.log`.
2. **Check the STA gate (Phase 2) before deploying.**
3. Deploy RBF to `/media/fat/_Arcade/cores/Hyprduel.rbf` on
   `root@192.168.1.208` (sshpass -p "1", PubkeyAuthentication=no), reload via
   `echo 'load_core /media/fat/_Arcade/Hyper Duel.mra' > /dev/MiSTer_cmd`.
4. With the test pattern ON, expect: TEST BEEF, DLWR == DLCT low bits,
   PDLD 00FF, ROM0 00FF, RSDP dropped byte 0000. Values are now trustworthy.
5. Test pattern OFF: if the game still does not boot with timing closed,
   diagnostics clean, and download verified, the next investigation is CPU
   execution / VDP behavior, on a foundation where the screen tells the truth.

## Why this should work (context for confidence)

The blank screens on compiles 10-21 are explained by a bug that is already
fixed in the working tree: `reset` includes `ioctl_download`, and the SDRAM
controller was reset by `RESET` until the rst_n=pll_locked fix. Every
previously deployed build erased or never performed the ROM download. The fix
was correct, but the same session added the hex overlay, which regressed
timing from the ~-0.45 ns seed-sweep floor to -2.195 and put the diagnostic
readouts on failing paths, so the fix could never be verified. This plan
removes both obstacles. Estimated odds that rst_n fix + timing closure boots
the game: 60-70%. If it still does not boot, the remaining suspects are the
GFX ROM interleave (never hardware-validated; failure mode is a booted game
with garbled graphics, which is progress) and board-level SDRAM capture.

## Hard rules and escalation triggers

- **STA gate, non-negotiable**: no RBF is deployed, and no hardware
  observation counts as evidence, unless the Setup Summary in Hyprduel.sta.rpt
  shows slack >= 0 for every clock. Check it after every single compile.
- **Renderer parity gate**: any change to i4220_render/i4220_vdp must pass the
  existing Verilator-vs-MAME frame verification before compiling for hardware.
- Stop and hand back to Lee (for escalation to Fable) if any of these hit:
  1. Timing will not close after the o_vram_addr pipeline stage plus a seed
     sweep (structural floor still negative).
  2. Renderer parity breaks after the pipeline change and cannot be localised
     within a session.
  3. The first STA-clean build shows clean diagnostics (TEST BEEF, DLWR==DLCT,
     ROM0 00FF) and the game still does not boot. That is a new diagnosis
     problem, not an execution problem; do not start speculative RTL changes.

## Working tree note

All prior session changes are still uncommitted in
`/Users/leefoot/python_scripts/hyperduel-mister`. The rst_n fix, postdl gate,
16-deep FIFO, selftest gating, and hex display are keepers per the old
handoff; nothing was reverted today. tb_download.sv was briefly modified to
reproduce the livelock and restored to `repeat (15)`.
