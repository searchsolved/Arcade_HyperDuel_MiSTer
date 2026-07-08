# Handoff: Hyper Duel MiSTer Core - Blank Screen Investigation

## Project
`/Users/leefoot/python_scripts/hyperduel-mister/` - FPGA arcade core for MiSTer. Two 68000 CPUs + Imagetek I4220 VDP + YM2151 + OKI M6295.

## The problem
The core compiles, fits the FPGA (38% ALMs, 98% M10K), and deploys to the MiSTer. The OSD works, a test pattern (colour bars via status[6] toggle) displays correctly, and the LEDs confirm the CPU is fetching ROM and vblank is running. But the game itself shows a completely black screen. Sim is pixel-perfect against MAME.

## What has been eliminated
- **MRA main ROM byte-lane order**: verified correct by cross-referencing `tools/build_mainrom.py`, the SDRAM controller's byte convention, and the MRA `map=` attributes
- **BRAM altsyncram output registers**: tested both `UNREGISTERED` and `CLOCK0/CLOCK1`; `UNREGISTERED` is confirmed correct (matches 1-cycle Verilator latency); no change in behaviour either way
- **SDRAM capture timing**: P_RET=3 and P_RET=4 both produce blank screen
- **Video pipeline**: test pattern proves arcade_video, ce_pix, sync timing, HDMI output all work
- **Framework/PLL/reset**: OSD works, LEDs work, core is not stuck in reset

## Remaining suspects (prioritised)

### 1. GFX ROM 64-bit interleave (MOST LIKELY)
The 4x1MB GFX ROMs use a complex 64-bit word interleave (`ROM_LOAD64_WORD` pattern). This has NEVER been hardware-validated. If the byte order is wrong, the renderer fetches garbled tile/sprite graphics. The tiles would decode as transparent (pen 0xF = transparent in 4bpp), producing a black screen with just the background colour (which is also black at palette entry 0). Check `mra/Hyper Duel.mra` GFX interleave against `tools/build_gfxrom.py` and the SDRAM controller's GFX stream byte-emission order.

### 2. CPU in exception loop
The mrom_rd LED confirms ROM fetches, but the CPU could be in a bus-error or address-error exception loop, constantly re-fetching the exception vector without ever writing to VRAM. Add a diagnostic: toggle an LED or status bit when the VDP receives a CPU write (`vdp_cs && !i_rnw` in i4220_vdp.sv). If it never fires, the CPU is stuck.

### 3. Renderer kick never fires
If `line_start` (the ce_pix-gated hblank edge) doesn't fire at P_PIXDIV=12, the renderer's kick FIFO stays empty and the linebuf is all zeros. Add a diagnostic: count rendered lines or toggle an LED on `rnd_done`.

### 4. shared3 SDRAM port
The new sr3 port in the SDRAM controller was only tested in behavioural sim. On hardware, the arbiter priority or timing could deadlock. Add a diagnostic: check if sr3_ack ever fires.

## Access details
- **Build PC**: `ssh leefoot@192.168.1.207`, Quartus at `C:\intelFPGA_lite\17.0`, project at `C:\hyprduel\mister\`. ALWAYS E-core affinity (`start /AFFINITY FFFF0000`). Launch: `schtasks /run /tn hyprcompile`. ~15 min compile.
- **MiSTer**: `sshpass -p "1" ssh -o PubkeyAuthentication=no root@192.168.1.208`. Files: `/media/fat/_Arcade/cores/Hyprduel.rbf`, `/media/fat/_Arcade/Hyper Duel.mra`, `/media/fat/games/mame/hyprduel.zip`. Load: `echo 'load_core /media/fat/_Arcade/Hyper Duel.mra' > /dev/MiSTer_cmd`
- **Path extractor**: `schtasks /run /tn hyprsta` on PC, produces `C:\hyprduel\mister\paths_setup.txt`

## Key files
- `docs/plan_timing_closure.md`, `plan_render_pipeline.md`, `plan_emit_pipeline.md` - timing closure plans (implemented)
- `mister/Hyprduel.sdc` - SDC with multicycle constraints
- `mister/Hyprduel.sv` - shell with test pattern (status[6]), LED heartbeat, P_RET=4
- `rtl/i4220_render.sv` - renderer with ROM-addr pipeline + emit prefetch
- `rtl/hyprduel_sdram.sv` - SDRAM controller with sr3 port
- `mra/Hyper Duel.mra` - ROM descriptor (main ROM byte-lanes corrected)
- Memory note: `hyperduel_mister_core.md` - full state including all suspects

## Verification
- `sim/make verify blit-verify` -> 22/22
- `sim/make vdp-verify` -> frame 500 PASS
- `make boot FRAMES=30` -> boots clean, worst_line_cycles=1996

## Compile history (today)

| Compile | Change | Result |
|---------|--------|--------|
| 8 | Original (plain arrays) | Fitter fail: 1.4M ALMs (3403%) |
| 9-run1 | BRAM wrappers | Synth fail: non-pow2 NUMWORDS |
| 9-run2 | shared3 padded to 2^17 | Fitter fail: BRAM 114% |
| 9-run3 | shared3 split 32K+16K+8K | Fitter fail: >553 M10K blocks |
| 10 | shared3 to SDRAM | **FIRST FIT**: 38% ALM, 98% M10K. Blank screen. Fmax 55 MHz |
| 11 | QSF aggressive | Fmax 54 MHz (worse) |
| 12 | SDC multicycles | Fmax 54 MHz, TNS -410 -> -265 |
| 13 | Renderer ROM-addr pipeline | Fmax 65 MHz |
| 14 | Emit skewed prefetch | Fmax 74 MHz |
| 15 | SEED 2 | Fmax 77 MHz, slack -0.451 (best) |
| 16 | SEED 3 | Fmax 76.5 MHz |
| 17 | SEED 5 | Fmax 76.6 MHz |
| 18 | P_RET=4 | Blank screen unchanged |
| 19 | Test pattern added | Test pattern works! Video pipeline confirmed OK |
| 20 | BRAM outdata_reg CLOCK0/1 | Blank screen unchanged |
| 21 | BRAM outdata_reg UNREGISTERED + MRA fix | Blank screen unchanged |

## QSF state on PC
`OPTIMIZATION_MODE "AGGRESSIVE PERFORMANCE"`, `SYNTH_TIMING_DRIVEN_SYNTHESIS ON`, `ALM_REGISTER_PACKING_EFFORT HIGH`, `SEED 5`. SDC has multicycle constraints for fx68k x2, jt51, jt6295.

## Recommended approach
Start with **suspect #1** (GFX ROM interleave) - it's the most likely cause since the main ROM interleave was already wrong and the GFX interleave uses a more complex 64-bit pattern. Then add hardware diagnostics (LED toggles on VDP writes, renderer kicks, sr3 acks) to narrow down whether the CPU is actually reaching the game's initialisation code.
