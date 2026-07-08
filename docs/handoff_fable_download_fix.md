# Handoff: SDRAM Download - Root Cause Narrowed, Fix Needed

Continues from `docs/handoff_opus_sdram_download.md`. This session confirmed the
download path is fundamentally broken and narrowed the root cause with hardware
diagnostics and sim reproduction.

## What was tried this session

### Changes made (all in the working tree, uncommitted)

1. **rst_n = pll_locked** (`mister/Hyprduel.sv:135`): removed `~RESET` from SDRAM
   controller reset. Correct fix, keeps it.

2. **postdl trigger + dlf_empty** (`rtl/hyprduel_sdram.sv:256`): added `&& dlf_empty`
   to the post-download readback condition. Correct fix, keeps it.

3. **FIFO enlarged to 16-deep** (`rtl/hyprduel_sdram.sv:550-575`): was 4. Busy
   threshold raised from 2 to 12. `o_dl_busy` also gated by `!o_ready` to hold off
   HPS during SDRAM init. These changes help but **did not fix the root cause**.

4. **Selftest gated** (`rtl/hyprduel_sdram.sv:231`): ST_NONE now requires
   `!i_dl_active && dlf_empty` before starting. Prevents selftest/download race.
   Correct but **insufficient**.

5. **Hex text diagnostic display** (`mister/Hyprduel.sv`): replaced binary colour bars
   with a 4x7 pixel hex font rendering 9 rows of "LABEL XXXX". Includes font glyphs
   for 0-F plus T,E,S,P,D,L,R,O,W,B,M,Q. Works well on CRT, keep it.

6. **New debug ports**: `dbg_dl_written`, `dbg_dl_dropped`, `dbg_fsm_info`
   ({dlf_cnt, dl_pend, st, dl_grant_cnt}), `dbg_reset_count` in shell.

7. **Download sim testbench** (`sim/tb/tb_download.sv`): 4 tests including T4 which
   sends bytes during selftest/init (MiSTer-like timing). T4 **reproduces the deadlock
   in sim** when bytes arrive faster than the FSM drains (1 per 4 clocks vs 1 per 8).
   Passes at realistic HPS pace (1 per 16 clocks).

### Hardware diagnostic results (3 builds deployed)

Build 1 (rst_n fix + small FIFO):
```
TEST BEEF   PDLD FFFF   ROM0 FFFF   ROM1 6668
DLBT 00FF   DLCT 4C00   DLWR 0002   RSDP 0100
```

Build 2 (16-deep FIFO + o_ready gate + selftest defer):
```
TEST EFEF   PDLD FFFF   ROM0 FFFF   ROM1 6666
DLBT 00FF   DLCT 4C55   DLWR 0002   RSDP 0100
FSMQ 0542
```

Key observations:
- **DLWR = 0002 in both builds**: only the 2 selftest writes reach SDRAM. The ~5M
  download bytes enter the FIFO but never get written.
- **DLCT ~ 4C00**: all bytes received by `i_dl_wr`. Download stream is complete.
- **dl_dropped = 0**: no FIFO overflow (RSDP low byte = 0x00).
- **FSMQ = 0542**: dlf_cnt[4:2]=0 (FIFO empty or near-empty), dl_pend=1, st=5
  (ST_IDLE), dl_grant_cnt=0x42 (66 grants). The FSM is idle with dl_pend asserted
  but somehow not serving it, or serving it without incrementing dl_written.
- **TEST changed from BEEF to EFEF** in build 2: the selftest writes are being
  corrupted, likely by the FIFO pop overwriting dl_addr_q/dl_data_q.
- **Flags unchanged**: mrom_rd GREEN, vdp_cs RED, vdp_write RED. CPU runs but never
  reaches VDP.

## Root cause analysis

The FIFO pop and the selftest both set `dl_pend`/`dl_addr_q`/`dl_data_q` in the same
always_ff block. The FIFO pop is textually LATER, so its NB assignments to
`dl_addr_q`/`dl_data_q` override the selftest's values. This corrupts the selftest
(EFEF instead of BEEF).

But the deeper issue: **DLWR stays at 2 despite dl_grant_cnt = 0x42 (66)**. This means
the FSM enters ST_IDLE and "grants" OWN_DL 66 times, but only 2 of those reach ST_CAS
with `owner == OWN_DL`. The other 64 grants must be going through ACT->RCD->CAS but
arriving at CAS with a different owner, or the CAS OWN_DL branch isn't firing.

### Hypothesis: FIFO pop clobbers dl_pend during CAS

When ST_CAS fires with `owner == OWN_DL`, it sets `dl_pend <= 1'b0`. But the FIFO pop
(earlier in the always_ff) may have already set `dl_pend <= 1'b1` in the same cycle.
Since the CAS assignment is LATER in the text, `dl_pend` becomes 0. The FIFO entry that
was popped (dlf_pop=1, dlf_rp incremented) has its addr/data loaded into dl_addr_q/
dl_data_q, but dl_pend is cleared before the FSM can serve it. The entry is silently
consumed and lost.

This would explain:
- dl_dropped=0 (the FIFO entries are validly popped, not overflow-dropped)
- DLWR=2 (almost no CAS writes for DL)
- DLCT~4C00 (all bytes received)
- The FIFO eventually drains to empty (each pop consumes an entry even if it's not
  written to SDRAM)

### Hypothesis: grant_cnt vs dl_written discrepancy

dl_grant_cnt increments when ST_IDLE grants OWN_DL. dl_written increments when ST_CAS
fires with owner==OWN_DL. If grant_cnt >> dl_written, the FSM grants DL but the write
never completes. This could happen if:
- The owner changes between grant and CAS (impossible, owner is only set in ST_IDLE)
- The CAS branch for OWN_DL doesn't fire (maybe owner comparison fails in synthesis?)
- The FSM never reaches CAS after granting (stuck in ACT or RCD?)

## Sim reproduction

`make download` in `sim/` runs 4 tests. Test 4 sends bytes during init/selftest with
3-cycle gaps (aggressive timing). It deadlocks at ~240 bytes with a 4-cycle loop:
CAS -> WWAIT(3) -> WWAIT(2) -> WWAIT(1) -> CAS. The FSM appears to skip IDLE/ACT/RCD.

With 16-cycle gaps (realistic HPS pace), Test 4 passes. The hardware failure persists
at all timings, suggesting the real HPS sends bytes fast enough to trigger the race.

## Recommended investigation

1. **Fix the FIFO pop / dl_pend race**: The FIFO pop must NOT fire when the FSM is
   about to clear dl_pend. Options:
   a. Move the FIFO pop AFTER the case statement so CAS's `dl_pend <= 0` takes
      precedence and the pop only fires next cycle when dl_pend is truly 0.
   b. Gate the FIFO pop with `st == ST_IDLE` so it only pops when the FSM is ready
      to immediately serve. This is the cleanest fix.
   c. Add a separate `dl_fifo_pend` flag that doesn't interact with the selftest's
      `dl_pend` path. Decouple the two consumers.

2. **Fix the selftest corruption**: The selftest must not race with the FIFO pop for
   dl_addr_q/dl_data_q. Option (c) above cleanly fixes both issues.

3. **Verify with sim**: After fixing, Test 4 should pass even with 2-cycle gaps.
   Also run the full system boot test (`make boot SDRAM=1 FRAMES=30`).

4. **Verify on hardware**: The hex display should show DLWR matching DLCT (~4C00),
   PDLD=00FF, and ROM0=00FF. If those match and the game still doesn't boot, the
   issue has moved downstream (CPU execution or VDP).

## Key files

- `rtl/hyprduel_sdram.sv` - SDRAM controller, FIFO, selftest
- `mister/Hyprduel.sv` - shell, hex diagnostic display
- `sim/tb/tb_download.sv` - download testbench (Test 4 reproduces the bug)
- `sim/tb/sdram_model.sv` - behavioral SDRAM
- `sim/Makefile` - `make download` target

## Compile/deploy

Build PC: `ssh leefoot@192.168.1.207`, project at `C:\hyprduel\` (rtl/ and mister/
subdirs match repo layout). Compile: `schtasks /run /tn hyprcompile`. ~15-20 min.
Kill stale compiles first: `taskkill /im quartus_fit.exe /f` etc.

MiSTer: `sshpass -p "1" ssh -o PubkeyAuthentication=no root@192.168.1.208`.
RBF to `/media/fat/_Arcade/cores/Hyprduel.rbf`. Reload:
`echo 'load_core /media/fat/_Arcade/Hyper Duel.mra' > /dev/MiSTer_cmd`.

Enable diagnostic screen: OSD -> Test Pattern -> On.
