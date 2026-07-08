# Handoff: SDRAM Download Debug - Current State

## Project
`/Users/leefoot/python_scripts/hyperduel-mister/` - FPGA arcade core for MiSTer.

## Summary of session findings (2026-07-07)

Starting from the blank-screen investigation in `docs/handoff_blank_screen_investigation.md`,
this session identified and fixed two bugs and narrowed the remaining issue to a single
root cause: **ROM data is not surviving the SDRAM download**.

### Bug 1: MRA main ROM byte-swap (FIXED)
The MRA `map=` attributes for the main 68000 ROM were inverted, producing a stream
with swapped byte lanes. Fixed by swapping `map="10"`/`map="01"` on 24.u24/23.u23.
Verified byte-for-byte with `tools/check_mra_stream.py` against the reference builders.
This fix is necessary but not sufficient - the game still shows a blank screen.

### Bug 2: ioctl_wait never connected (FIXED, but insufficient alone)
`hps_io.ioctl_wait` was not connected to `o_dl_busy` from the SDRAM controller.
Fixed by adding `.ioctl_wait(dl_busy)` to the hps_io instantiation. This alone
did not resolve the blank screen because of deeper issues in the download path
(see current problem below).

### Current problem: SDRAM download data not persisting
After the download completes, SDRAM reads of the main ROM region return all zeros.
The CPU reads a zero reset vector, starts at address 0, executes ORI instructions
(opcode 0x0000), and never reaches VDP initialization.

## What has been proven by hardware diagnostics

Diagnostic flags (sticky latch, displayed as green/red bands on the OSD test screen
via status[6]):

| Signal | State | Meaning |
|--------|-------|---------|
| mrom_rd | GREEN | CPU fetches ROM from SDRAM |
| vdp_cs | RED | CPU NEVER accesses VDP address range (0x400000-0x47FFFF) |
| vdp_write | RED | CPU NEVER writes to VDP |
| past_vectors | GREEN | CPU address reaches >= 0x800 (executes game code or exception handlers) |
| line_start | GREEN | VDP renderer kick fires |
| rnd_done | GREEN | VDP renderer completes lines |
| sr3_ack | GREEN | shared3 SDRAM port works |
| dl_saw | GREEN | Download writes (i_dl_wr) do fire |
| lb_nonzero | GREEN | Linebuffer has nonzero pixels (uninitialized VRAM data) |

Binary data captures on the diagnostic screen:
- **selftest = 0xBEEF**: The SDRAM controller writes 0xBEEF to word addr 0x3FFFF
  via the DL port (DQM byte writes), then reads it back via the mrom port. Returns
  0xBEEF. **Proves SDRAM hardware works: write path, read path, DQM masking, P_RET=4
  timing are all correct.**
- **postdl = 0x0000**: After ioctl_download goes low, read SDRAM word 0 via mrom port.
  Returns 0x0000. Expected 0x00FF (first word of the MRA stream). **Download data is
  not present in SDRAM after download completes.**
- **mrom_word0-2 = 0x0000**: First 3 words the CPU reads from ROM are all zero.
- **dl_byte0 = 0x00**: First byte received by i_dl_wr. Matches expected stream byte 0.

## What this means

The SDRAM hardware works (selftest proves it). The HPS sends download bytes (dl_saw green,
dl_byte0 correct). But the download data doesn't survive to post-download readback.

Either:
1. Download bytes are dropped between i_dl_wr and the SDRAM write FSM
2. The SDRAM write with DQM byte masking doesn't commit during the download (but it
   works in the selftest, which uses the same mechanism)
3. Something erases SDRAM between the last download write and the postdl readback
4. The download addresses don't map to the addresses being read

## Current SDRAM controller download path

File: `rtl/hyprduel_sdram.sv`

The download uses byte-at-a-time writes with DQM masking:
```
// In ST_CAS when owner == OWN_DL:
dq_out <= {dl_data_q, dl_data_q};        // same byte on both lanes
SDRAM_DQML <= !dl_addr_q[0];             // even addr: mask low, write high
SDRAM_DQMH <=  dl_addr_q[0];             // odd addr: mask high, write low
// Auto-precharge (A10=1), wait_cnt=3 for tWR+tRP
```

Address mapping: `cur_word <= dl_addr_q[24:1]` (byte addr -> word addr).
Read mapping: `cur_word <= MROM_WBASE + mrom_addr_q` where MROM_WBASE = 0.

The download goes through a 4-deep FIFO (added this session) to absorb HPS bus
latency. The FIFO pops into `dl_pend` when the FSM is idle. `o_dl_busy` asserts
when the FIFO has 2+ entries, connected to `ioctl_wait` for backpressure.

**Known bug in current code**: the postdl readback trigger condition
(`!dl_pend && st == ST_IDLE`) doesn't check `dlf_empty` - it may fire before
the last FIFO entries are flushed to SDRAM. This needs fixing, but may not be
the root cause since the earlier non-FIFO version also showed postdl = 0x0000.

## Shell download wiring (mister/Hyprduel.sv)

```
wire rom_load = ioctl_download && (ioctl_index[7:0] == 8'd0);
// ...
.i_dl_wr(ioctl_wr && rom_load),
.i_dl_addr(ioctl_addr[24:0]),
.i_dl_data(ioctl_dout),
.o_dl_busy(dl_busy),
.i_dl_active(ioctl_download),
// ...
.ioctl_wait(dl_busy),   // backpressure to HPS
```

SDRAM controller reset: `rst_n = pll_locked & ~RESET` (does NOT include
ioctl_download, so SDRAM stays initialized across the download).

Core reset: `reset = RESET | status[0] | buttons[1] | ~pll_locked | ioctl_download`
(core is held in reset during download, released after).

## Sim vs hardware

The sim boot test (`make boot FRAMES=30`) passes - the CPU boots, writes to VDP by
frame 0 (3rd bus write), and runs the game. But the sim uses ideal ROM servers
(direct memory read), NOT the SDRAM download path. The sim with `+SDRAM=1` tests
the SDRAM controller with a behavioral model but doesn't test the download - it
pre-loads the SDRAM model directly.

The download path has NEVER been tested in simulation.

## Key files

- `rtl/hyprduel_sdram.sv` - SDRAM controller with download FIFO and selftest
- `mister/Hyprduel.sv` - Shell with diagnostic display and hps_io wiring
- `rtl/hyprduel_sys.sv` - System with CPU debug captures
- `rtl/i4220_vdp.sv` - VDP with debug flags
- `tools/check_mra_stream.py` - MRA stream byte-for-byte verification
- `mra/Hyper Duel.mra` - Fixed MRA (byte-swap corrected)

## Suggested investigation

1. Fix the postdl trigger to also check `dlf_empty` - confirm whether the FIFO
   fix actually resolves the download issue when properly drained.

2. Add a `dbg_dl_written` counter that increments in ST_CAS when `owner == OWN_DL`.
   Compare against `dbg_dl_count` (bytes received via i_dl_wr). If dl_written <<
   dl_count, bytes are being dropped in the FSM. If they match, the writes happen
   but data doesn't persist (pointing to a DQM/timing issue specific to the download
   context).

3. Consider adding a sim testbench that exercises the download path: load the
   stream into the behavioral SDRAM model via dl_wr, then read it back via mrom.
   This would catch address mapping bugs without hardware iteration.

4. Check whether `RESET` (the MiSTer system reset from sys_top) pulses between
   the download completing and the CPU starting. If it does, the SDRAM controller
   would re-initialize (its rst_n includes RESET), potentially disrupting data.
   Add a `dbg_reset_count` diagnostic.

5. Verify that the 4-deep FIFO synthesizes correctly - small arrays in Quartus 17
   can sometimes infer as MLAB with registered outputs, adding unexpected latency.
   Consider using explicit shift registers instead.

## Compile details

Build PC: `ssh leefoot@192.168.1.207`, Quartus at `C:\intelFPGA_lite\17.0`,
project at `C:\hyprduel\mister\`. Compile via `schtasks /run /tn hyprcompile`
(E-core affinity). ~15-20 min per compile.

MiSTer: `sshpass -p "1" ssh -o PubkeyAuthentication=no root@192.168.1.208`.
Deploy RBF to `/media/fat/_Arcade/cores/Hyprduel.rbf`, reload via
`echo 'load_core /media/fat/_Arcade/Hyper Duel.mra' > /dev/MiSTer_cmd`.

Current compile state: 38% ALMs, 100% M10K (553/553), P_RET=4, SEED 5.
