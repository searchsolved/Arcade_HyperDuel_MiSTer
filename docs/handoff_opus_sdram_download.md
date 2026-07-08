# Handoff Plan for Opus: SDRAM Download Debug

Continues from `docs/handoff_sdram_download_debug.md` (2026-07-07). That doc has the
full evidence table; this doc adds a code-review diagnosis and a concrete work plan.

## Diagnosis (code review of rtl/hyprduel_sdram.sv + mister/Hyprduel.sv)

### Primary hypothesis: RESET pulse during download re-initializes the controller

`mister/Hyprduel.sv:135`:

```
.rst_n(pll_locked & ~RESET),
```

The SDRAM controller resets on the framework RESET line. This is unconventional;
MiSTer cores normally initialize the SDRAM controller on `~pll_locked` only,
precisely because the HPS can pulse RESET around config/download events.

If RESET pulses at any point during the download:

1. The controller re-enters ST_INIT_WAIT: 8000 cycles (100 us at 80 MHz) where no
   dl writes are served.
2. The download FIFO is cleared (`dlf_cnt <= 0`) and held cleared, so
   `o_dl_busy = (dlf_cnt >= 2)` stays LOW. No backpressure reaches the HPS.
3. Every byte the HPS sends during init is silently dropped (writes only enter the
   FIFO when not in reset). The addresses of dropped bytes are simply never written.
4. After init completes, the selftest re-runs (passes again, so `selftest = 0xBEEF`
   still displays) and the remaining stream bytes are written normally.

If the pulse lands at or near download start, the beginning of the stream (the
68000 reset vectors, word 0) is exactly what gets lost. This fits every observed
symptom simultaneously:

- selftest = 0xBEEF (re-runs after re-init, still passes)
- dl_saw GREEN (bytes still arrive after the reset)
- dl_byte0 = 0x00 (dbg counters were cleared; this is the first byte seen
  after the reset, and much of the stream is 0x00, so it looks plausible)
- postdl = 0x0000, mrom_word0-2 = 0x0000 (word 0 never written)
- lb_nonzero GREEN (later GFX data may be partially present)

This is investigation item 4 from the previous handoff, promoted to primary because
it is the only single cause found that explains selftest-passes-but-download-fails.

### Confirmed secondary bugs (fix regardless of root cause)

1. **Selftest scratch clobbers main ROM.** The selftest writes 0xBE/0xEF to byte
   addresses 0x7FFFE/0x7FFFF (`hyprduel_sdram.sv:231,236`), which is the LAST WORD
   of the main 68000 ROM. Normally the download overwrites it afterwards, but if
   the selftest ever re-runs after the download (any RESET pulse, e.g. user reset),
   it corrupts ROM. Move the scratch to unused SDRAM space, e.g. byte 0x1FFFFFE
   (top of the 32 MB module; shared3 RAM ends at word 0x28E000, everything above
   is free).

2. **postdl trigger races the FIFO drain** (known from previous handoff). The
   ST_WAIT_DL condition (`hyprduel_sdram.sv:252`) checks `!dl_pend && st == ST_IDLE`
   but not `dlf_empty`. Cannot be the root cause (the CPU reads word 0 as zero much
   later too), but fix it: add `&& dlf_empty`.

3. **postdl capture races the CPU.** ST_WAIT_DL fires when `!i_dl_active`, which is
   the same event that releases core reset. The CPU's first `i_mrom_rd` can relatch
   `mrom_addr_q` (line 284) before the FSM grants the selftest's read, so `dbg_postdl`
   may capture whatever word the CPU requested rather than word 0. Diagnostic noise
   rather than root cause (the CPU's first fetch is also word 0), but worth knowing
   when interpreting the screen.

4. **dbg_dl_count is useless at 16 bits.** The full stream is 0x4C0000 bytes
   (512 KB + 4 MB + 256 KB), and 0x4C0000 mod 0x10000 = 0x0000. A complete download
   and a totally dead download both display 0x0000. Widen the counter to 24 bits and
   display bits [23:8]. Expected value for a complete download: 0x4C00.
   Bonus: a partial count here is direct evidence of a mid-download reset or drops.

### Checked and ruled out (do not re-investigate)

- **Clock domains:** hps_io and the SDRAM controller both run on clk_sys (80 MHz).
  No CDC on the ioctl path.
- **FIFO pointer/count logic:** reviewed for double-pop, underflow, and
  read-during-write hazards; correct. `dl_pend`/`dl_addr_q` cannot be overwritten
  between grant and CAS (the pop-if requires `!dl_pend`, which is held high across
  the access).
- **FIFO width/packing:** {addr[24:0], data[7:0]} = 33 bits, indices consistent.
- **Write timing/DQM/address mapping in the FSM:** identical code path serves the
  selftest, which passes. Bank/row/col split (word[23:22]/[21:9]/[8:0]) is correct
  for the 32 MB module.
- **index gating:** dl_saw is behind `ioctl_wr && rom_load`, so its GREEN state
  proves index-0 bytes arrive with the gate open.
- **MLAB inference (item 5 of the old handoff):** a 4x33 array is far below MLAB
  threshold; Quartus will build it from registers. Deprioritize.

## Work plan

### Phase 0: read the existing diagnostic screen (no compile needed)

The current build already displays two values that were never recorded:

- Row 5 = {dl_byte0, dl_byte1}, expected 0x00FF. If byte1 is 0xFF the incoming
  stream data is good and the fault is entirely on the write/persist side. If byte1
  is 0x00 the stream itself is suspect (or the counters were reset mid-download,
  which supports the RESET hypothesis).
- Row 6 = dl_count low 16 bits. Expected 0x0000 for a complete download (see above,
  which is why it must be widened), but any OTHER value = partial count = mid-stream
  reset or drops. A nonzero reading here would essentially confirm the primary
  hypothesis before writing any code.

### Phase 1: simulate the download path (highest leverage, never done)

Hardware iteration costs 15-20 min per compile; sim runs in seconds, and
`sim/tb/sdram_model.sv` already asserts on timing/protocol violations. Build
`sim/tb/tb_download.sv` (mirror the structure and Makefile pattern of
`tb_system.sv`, see `sim/Makefile:115`):

1. Instantiate `hyprduel_sdram #(P_SHORT_INIT=1, P_RET=3)` + `sdram_model`.
2. Drive `i_dl_wr` with the real stream prefix (or a counting pattern) at a
   realistic HPS pace (one byte every ~80 cycles), honoring `o_dl_busy`.
3. After `i_dl_active` drops, read back every written word via the mrom port and
   compare. This proves or disproves the FIFO/address path in isolation.
4. Repeat with hostile timing: bytes back to back every 2-3 cycles, and 2-3 extra
   bytes sent AFTER `o_dl_busy` asserts (models HPS in-flight latency). Checks the
   4-deep/threshold-2 margin.
5. **Reset test:** pulse `rst_n` low mid-download while bytes keep arriving, then
   verify exactly the dropped-prefix corruption predicted above. This demonstrates
   the failure signature of the primary hypothesis.

### Phase 2: RTL fixes (one compile)

1. `mister/Hyprduel.sv`: change SDRAM controller reset to `.rst_n(pll_locked)`.
   Keep the core reset as is (it already includes RESET and ioctl_download).
2. `rtl/hyprduel_sdram.sv`: postdl trigger adds `&& dlf_empty`.
3. Move selftest scratch to byte 0x1FFFFFE/F (word 0xFFFFFF).
4. Widen dbg_dl_count to 24 bits; display [23:8] (expected 0x4C00).
5. Add diagnostics to the spare screen rows:
   - `dbg_reset_count[7:0]`: increments on every falling edge of rst_n as seen from
     a free-running domain, or simpler: count rst_n assertions using a register
     clocked on clk that survives... it cannot survive its own reset, so instead
     count RESET pulses in the SHELL (Hyprduel.sv, not reset by RESET) and display.
   - `dbg_dl_written[15:0]`: increments in ST_CAS when owner == OWN_DL (writes
     actually issued). Compare with dl_count: equal means writes issued but not
     persisted; written << count means drops before the FSM.
   - `dbg_dl_dropped[7:0]`: increments on `i_dl_wr && dlf_full` (silent FIFO drops,
     currently invisible).

### Phase 3: compile, deploy, decide

Compile and deploy per the previous handoff (build PC 192.168.1.207, task
`hyprcompile`; MiSTer 192.168.1.208, RBF to `/media/fat/_Arcade/cores/Hyprduel.rbf`).

Decision tree after the fixed build:

- **Game boots:** root cause was the RESET wiring (and/or FIFO drain race). Verify
  title screen, then clean up: consider removing or gating the diag scaffolding,
  update docs, close out.
- **Still blank, postdl = 0x00FF:** download now persists; the problem has moved
  downstream (CPU fetch path, mrom address translation, hyprduel_sys). The mrom_word
  captures will show whether the CPU sees the same data postdl proves is present.
- **Still blank, postdl = 0x0000, reset_count > 1:** something beyond RESET is
  cycling the system; instrument what (RESET vs pll_locked) with separate counters.
- **Still blank, postdl = 0x0000, dl_written == dl_count, no drops:** writes are
  issued and not persisting only in download context. At that point compare
  the exact CAS/DQM/precharge sequence between selftest and download in sim
  (Phase 1 bench), and consider board-level effects (e.g. drive strength or
  DQM timing under sustained write traffic) or refresh starvation during the
  long write burst (ref_urgent path during download).

## Key files

- `rtl/hyprduel_sdram.sv` - controller; selftest FSM lines 225-263, FIFO lines 536-565
- `mister/Hyprduel.sv` - rst_n wiring line 135, diag screen lines 241-313
- `sim/tb/tb_system.sv`, `sim/tb/sdram_model.sv`, `sim/Makefile` - sim harness to extend
- `docs/handoff_sdram_download_debug.md` - full evidence table from 2026-07-07
