# Plan: timing closure to 80 MHz (compile 10 aftermath)

Written 2026-07-07. State: compile 10 SUCCEEDED (first ever fit: 38% ALM,
98% M10K, rbf produced, deployed to MiSTer at 192.168.1.208, root/1) but
BLANK SCREEN on hardware. Core clock Fmax = 55.18 MHz vs 80 MHz required
(worst slack -5.621 ns, TNS -409.968 = many failing paths). Compile 11 is
running with QSF changes only (AGGRESSIVE PERFORMANCE, timing-driven synth
ON, packing HIGH) - expect it to help but not close a 45% gap.

Accuracy rule: do NOT downclock. 80 MHz is required by the renderer
(line budget 5088 cycles = 424 px x 12 at P_PIXDIV=12; worst line ~4783).
Do NOT pipeline inside vendored CPU cores. The accuracy-preserving fix is
constraints, then targeted pipelining OUTSIDE the vendored cores only.

## STEP 1 DONE: failing paths identified (2026-07-07 compile 12)

All 100 worst setup paths are in ONE module: `i4220_render`.
Source registers: `sy0[0..4]` (scroll Y), `line_r[0..4]` (line number).
Destination register: `o_rom_addr[15..21]` (GFX ROM address).
Data delay: ~18 ns (budget 12.5 ns at 80 MHz).

This is the GFX ROM address computation: scroll + tile coords -> byte
address in the 4 MB GFX ROM region. It's a wide combinational chain
(scroll add + tile/row multiply + bank offset). No fx68k, no SDRAM, no
bus FSM paths in the top 100.

The fix (Step 3 below) is to pipeline this computation with one register
stage inside i4220_render.sv, splitting the address calc across two
cycles. The renderer FSM has headroom (worst_line_cycles 4783 vs 5088
budget, 6% slack). One extra cycle per ROM fetch is absorbed.

paths_setup.txt pulled to Mac scratchpad for reference.

## Step 1 (original): get the actual failing paths (stop guessing)

Quartus 17 Lite text reports omit path detail, but quartus_sta runs Tcl.
On the PC create C:\hyprduel\mister\report_paths.tcl:

    project_open Hyprduel
    create_timing_netlist
    read_sdc
    update_timing_netlist
    report_timing -setup -npaths 100 -detail path_only \
        -file paths_setup.txt
    project_close

Run: `quartus_sta -t report_paths.tcl` (E-core affinity as always), pull
paths_setup.txt back. Group the 100 paths by module. Expected buckets:
fx68k (x2), jt51, jt6295, i4220_render, sr3/bus muxes.

## Step 2: multicycle constraints for enable-gated cores (the big lever)

The 68000s advance only on enPhi1/enPhi2 (10 MHz: enables 4 sys clocks
apart, full cycle 8). jt51 cen = 4 MHz (20 clocks), jt6295 cen = 2 MHz
(~39 clocks). Every reg-to-reg path INSIDE those cores has 4+ clocks to
settle, but the SDC currently demands 1. Add to Hyprduel.sdc, scoped
intra-core only (safe: source and dest regs share the same cen):

    # fx68k: enPhi1/enPhi2 are 4 sys clocks apart -> 4-cycle paths.
    # Use 2 for safety margin; Fmax 55 already passes at 2 (25 ns).
    set_multicycle_path -setup -end 2 \
        -from [get_registers {*u_maincpu*}] -to [get_registers {*u_maincpu*}]
    set_multicycle_path -hold -end 1 \
        -from [get_registers {*u_maincpu*}] -to [get_registers {*u_maincpu*}]
    # same pair for *u_subcpu*, *u_ym* (jt51, could use 4+), *u_oki*

    (Exact register collection syntax: verify the hierarchy names with
    `get_registers -nowarn {*u_maincpu|*}` in the sta shell first; Quartus
    17 uses | separators, e.g. {emu|core|u_maincpu|*}.)

CAUTION: do NOT multicycle paths that CROSS core boundaries (fx68k ->
bus FSM / BRAM / dtack). The bus FSMs sample every clock. If Step 1 shows
cross-boundary paths failing, fix those by REGISTERING the CPU outputs
(m_a/m_dout/m_rw/strobes) once in hyprduel_sys before the decode logic -
the 68k holds them stable for many cycles, so one register stage before
decode is functionally free (verify in sim: full boot suite still passes;
frame timing must NOT shift because strobe-to-dtack still has huge margin
inside a 32-clock bus cycle... confirm no off-by-one on the commit-cycle
writes m_wr_commit / vdp_cs which are single-cycle qualified).

## Step 3: renderer paths (only if Step 1 shows them)

i4220_render runs every clock - genuinely single-cycle. If its paths fail,
pipeline INSIDE the renderer where there is line-budget slack (4783 used
vs 5088; ~6% headroom, so at most a few extra cycles per fetch step).
Re-verify with `sim/make verify vdp-verify` + boot (frames byte-identical;
renderer changes must not alter output, only latency, and stats print
worst_line_cycles - keep < 5088).

## Step 4: compile 12 and hardware bring-up checklist

- Watch quartus_map memory with timing-driven synth ON (it was OFF during
  the 50GB-balloon saga; if map balloons past ~20 GB, kill it, set
  SYNTH_TIMING_DRIVEN_SYNTHESIS back OFF, keep the SDC fixes - they are
  the real lever anyway).
- Gate: worst setup slack >= 0 on the 80 MHz clock (or a documented
  small negative with the failing endpoints listed and understood).
- Deploy: scp rbf to root@192.168.1.208 (password 1)
  /media/fat/_Arcade/cores/Hyprduel.rbf, MRA already at
  /media/fat/_Arcade/Hyper Duel.mra, rom at games/mame/hyprduel.zip.
  Load: echo 'load_core /media/fat/_Arcade/Hyper Duel.mra' > /dev/MiSTer_cmd

If STILL blank with clean timing, suspect in order:
1. SDRAM board capture: sim's sdram_model is idealized; the -90 deg
   SDRAM_CLK phase and P_RET=3 have never been hardware-validated. The
   comment in hyprduel_sdram.sv says "if board-level capture needs an
   extra cycle, bump P_RET by one" - try P_RET=4. Symptom would be main
   CPU executing garbage from the first fetch.
2. ROM download path: ioctl stream offsets vs MRA interleave (byte-lane
   order was explicitly deferred to hardware bring-up in the MRA header
   comment). A quick probe: add a status LED / OSD-visible heartbeat
   (e.g. LED_USER = vblank toggle) so "core alive vs video dead" is
   distinguishable from "CPU crashed".
3. Video pipeline: arcade_video expects CE_PIXEL duty; P_PIXDIV=12 gives
   ce_pix at 6.667 MHz - fine - but confirm hs/vs polarity matches what
   video_mixer expects (sim never checks polarity conventions).

Debug tip: MiSTer writes core video info to /tmp; `uartmode`/MiSTer.log
absent is normal. Check video mode detection with
`cat /sys/module/MiSTer_fb/*` or the OSD (F12) - if the OSD overlays fine,
the shell + PLL are alive and the fault is inside the core.

## Budget note

RS/PC rules unchanged (E-cores, one job, schtasks). Compile now ~13 min,
so iteration is cheap. Prioritize Step 1+2 in one compile; they are
SDC-only and cannot break functionality (constraints do not change logic),
only reveal or mask timing - re-run STA and confirm both setup AND hold
clean after adding multicycles.
