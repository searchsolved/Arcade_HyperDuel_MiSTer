# Plan: fix M10K overflow by moving shared3 to SDRAM

Status: ready to implement. Written 2026-07-07 after compile 9 runs 2-3.

## Where compile 9 landed

The BRAM conversion (docs/plan_bram_fit_conversion.md) worked: logic went from
1,426,275 ALMs (3403%) to 18,833 ALMs (45%), fitter runtime from 4 hours to 4
minutes, 7.5 GB peak. Two follow-up failures, first already fixed:

1. Run 1: hd_tdpram with NUMWORDS=57344 crashed synthesis
   (MGL_INTERNAL_ERROR, width mismatch in altsyncram decode). Quartus 17
   altsyncram needs power-of-2 depths. FIXED: shared3 split into three pow2
   hd_tdpram blocks 32K+16K+8K (u_shared3a/b/c in hyprduel_sys.sv), read
   outputs muxed via registered bank selects. Verified in sim (30-frame boot).
2. Run 3 (current blocker): Error 170048 "device has 553 M10K blocks, design
   needs more than 553". Bits show 93% (5,259,008 / 5,662,720) but bits are
   not the constraint. M10K blocks are.

## Why it cannot fit by repacking (the decisive arithmetic)

An M10K holds 10,240 bits only in x20/x10/x5 configs (512x20, 1Kx10, 2Kx5).
All core memories are 16-bit wide, and 16-bit data in a 512x20 slot uses
8,192 of 10,240 bits: 20% waste, intrinsic, in every port mode
(BIDIR/SIMPLE/SINGLE all the same). Ceiling for 16-bit content:

    553 blocks x 8,192 usable bits = 4,530,176 bits

Core 16-bit BRAM content after the conversion: VRAMs 3,145,728 + shared RAMs
1,310,720 + VDP arrays ~237,568 = ~4.56M bits, ALREADY over the 16-bit
ceiling before the framework (ascal/hq2x/gamma/FIFOs, ~700K bits, ~70-80
blocks) is counted. Block estimate: core ~574 + framework ~70 = ~645 needed
vs 553. Mode tweaks (SIMPLE_DUAL_PORT, dropping linebuf padding, scratch to
SINGLE_PORT) recover a handful of blocks; we need ~90. Do not spend time
there.

Something big must leave BRAM. Candidates:

| Candidate           | Blocks freed | Assessment                            |
|---------------------|--------------|---------------------------------------|
| 3x VRAM             | 384          | Renderer random access per line; major redesign; weeks. NO |
| shared3 (112 KB)    | 112          | CPU-paced, slow bus, SDRAM-friendly. YES |
| ascal removal       | ~31          | Deeply integrated in sys_top; users lose scaler; not enough alone. NO |
| small VDP RAMs->MLAB| ~30          | Fallback top-up only (see end)         |

After shared3 leaves: core 16-bit content ~3.64M bits -> ~445 blocks, plus
framework ~70-80 -> ~515-525 of 553. Fits with headroom.

## The change: shared3 becomes an SDRAM-backed region

shared3 is 57,344 x 16 (112 KB) at main 0xFE4000-0xFFFFFF, with a sub-CPU
read-only shadow at sub 0x004000-0x007FFF (s_sel_ro3) and full R/W at sub
0xFE4000+ (s_sel_sr3). Access pattern: two 68000s at ~10 MHz, one bus cycle
per >=400 ns, already DTACK-stalled through the bus FSMs
(hyprduel_sys.sv MB_WAIT / SB_WAIT states). SDRAM random access at 80 MHz is
~10-16 cycles (~125-200 ns). This is the one big memory whose consumer
tolerates latency by construction.

### 1. hyprduel_sdram.sv: add a CPU shared-RAM port (port survey done)

Current ports and priority (header, lines 4-11): download writes (highest),
GFX stream (i_gfx_req/addr/len, byte pulses), main ROM (req/valid word), OKI
(addr/ok byte). Add:

```
    // shared3 CPU RAM (word R/W, byte enables via DQM)
    input  logic        i_sr3_req,      // 1-cycle pulse; inputs stable until ack
    input  logic        i_sr3_we,
    input  logic [16:0] i_sr3_addr,     // word address 0..57343
    input  logic [15:0] i_sr3_wdata,
    input  logic [1:0]  i_sr3_be,       // {UDS,LDS} -> {~DQMH,~DQML} on writes
    output logic [15:0] o_sr3_rdata,
    output logic        o_sr3_ack       // 1-cycle pulse (rdata valid on reads)
```

- Priority: above starting a NEW gfx burst, below an in-flight burst (the
  stream protocol cannot be interrupted mid-burst; worst-case sr3 wait = one
  full burst, ~1.6 us, absorbed by DTACK wait states, correctness unaffected).
  Concretely: in the idle-arbiter pick order put sr3 first, gfx second,
  mrom/oki after (or keep mrom above sr3 if the arbiter structure makes that
  simpler; both CPUs stall cleanly either way).
- Writes: single-word write with DQM byte masking, same pattern as the
  download port (i_dl_wr path) but 16-bit with per-byte DQM from i_sr3_be.
  Mind the OKI in-flight-address race pattern fixed on 2026-07-05 (oki_fly in
  this file): latch sr3 request fields at grant, not at CAS.
- SDRAM address map: place shared3 in a region clear of mainrom/gfx/oki.
  Read the localparams at the top of hyprduel_sdram.sv (and
  docs/plan_synthesis_and_bringup.md) for the current map and pick the next
  free 128 KB-aligned window; nothing downloads into it (not part of the MRA),
  it is plain RAM.
- Uninitialized at power-on is fine (real board SRAM is too; POST clears it).

### 2. hyprduel_sys.sv: route shared3 through new module ports

- DELETE u_shared3a/b/c, the sr3 bank-select wires, and the sr3_q output mux
  (the block added by the pow2 split).
- New module ports (o_sr3_req, o_sr3_we, o_sr3_addr, o_sr3_wdata, o_sr3_be,
  i_sr3_rdata, i_sr3_ack), wired up through emu/Hyprduel.sv to the
  controller like the mrom port already is.
- Main CPU side: sr3 reads currently resolve in MB_WAIT one cycle after the
  strobe (m_rdata_q <= sr3_q_a). Replace with a request/wait: issue o_sr3_req
  on the MB_IDLE commit cycle (read or write), sit in a new MB_SR3 state (or
  reuse MB_ROM's shape, which already does exactly this for mrom) until
  i_sr3_ack, land rdata in m_rdata_q, go to MB_ACK. Writes may either wait
  for ack (simplest, keeps one-outstanding semantics) or fire-and-forget with
  a busy flag that blocks the next sr3 access until ack; do the simplest
  (wait for ack) first.
- Sub CPU side: same treatment in the SB FSM for s_sel_ro3 and s_sel_sr3
  (address mapping for the RO shadow stays exactly as sr3_addr_b computes it
  today, hyprduel_sys.sv lines 427-430).
- TWO CPUs, ONE port: add a tiny arbiter in hyprduel_sys (main wins ties,
  the loser's FSM just stays in its wait state and re-requests, or hold its
  req until granted). Keep requests level-held-until-ack rather than pulses
  if that makes the arbiter simpler; then i_sr3_req in the controller becomes
  a level with grant handshake. Pick ONE convention and document it in both
  files.
- shared1/shared2 stay in BRAM untouched.

### 3. Sim: same RTL path everywhere, then re-baseline

- tb/sdram_model.sv (behavioral) needs the same sr3 port so the default sim
  path exercises identical semantics; also run the +SDRAM=1 path
  (hyprduel_sdram.sv proper) for the real controller.
- TIMING NOTE, do not skip: shared3 accesses gain wait states vs the
  zero-wait BRAM the goldens were captured with. CPU instruction timing
  shifts, so frame-for-frame byte-identity with old golden PPMs and with
  MAME mid-animation frames may legitimately break. The verification gate
  for this change is:
  1. `sim/make verify blit-verify` still 22/22 (renderer/blitter untouched).
  2. `vdp-verify` frame 500 still PASS (900/1500 fail as before, known
     mid-frame raster writes).
  3. Full boot (400+ frames): POST passes, MEMORY CHECK -> Technosoft logo ->
     title reached, no hangs (watch the 0xFFF34C handshake; it lives in
     shared1, not shared3, so it is unaffected).
  4. State diff vs MAME (sim/mame/diff_state.py) at a STABLE screen (title):
     VRAM/palette/regs EXACT. Mid-transition frames may shift by a frame;
     compare at stable points only.
  5. 1300-frame audio boot: first YM note plays; RMS in family with the
     2026-07-05 calibration (exact sample alignment may shift).
- If sim shows the game hammering shared3 harder than expected (it is the
  main work RAM), check the renderer line budget still closes with the gfx
  arbiter sharing: worst_line_cycles must stay < 5088 at P_PIXDIV=6... note
  render reads GFX via its own stream priority and does not touch sr3; only
  watch that sr3 grants between bursts do not starve the stream (they are
  single-word, they will not).

### 4. mister/ shell

- Hyprduel.sv (emu): plumb the new port pins between hyprduel_sys and
  hyprduel_sdram instances; re-lint against lint_stubs.sv.
- No MRA change (shared3 is RAM, not a loadable region).

### 5. Compile 10 on the PC

Standing rules (they have cost days): E-core affinity always
(start /AFFINITY FFFF0000 in runcompile.cmd), one Quartus job, launch only
via `schtasks /run /tn hyprcompile`, log C:\hyprduel\mister\compile8.log is
append-mode with `===== flow start` banners. Transfer = tar+scp over
`ssh leefoot@192.168.1.207` (no git on the PC).

Expected: synthesis a few minutes, fitter 5-20 min at ~445-525 M10K. On
success pull Hyprduel.rbf, fit.summary, sta.rpt; check Fmax on the 80 MHz
core clock before declaring victory; then M5 (MRA + ROM load on the MiSTer).

### Fallback if still short a few blocks (do not pre-apply)

If the fitter reports needing slightly over 553 even after shared3 moves,
convert the small VDP RAMs (scratch 8, palette 8, spr_live 4, spr_buf 4,
tiletable 2 blocks) to MLAB with `(* ramstyle = "MLAB" *)` on the wrapper
storage (ALM budget has room: 45% used). Note the jt6295 lesson from
2026-07-06: Quartus 17 ignored `ramstyle="logic"` on an initialized ROM, so
verify each attribute actually took in the fitter report (Info 276xxx / the
resource section) rather than assuming.

## Files touched

- rtl/hyprduel_sdram.sv (new sr3 port + arbiter slot)
- rtl/hyprduel_sys.sv (delete u_shared3a/b/c + mux, new ports, FSM wait
  states, 2-CPU arbiter)
- mister/Hyprduel.sv (wiring)
- tb/sdram_model.sv, sim/tb/tb_system.sv if it stubs the port
- docs: this file; update memory notes after the compile
