# Plan: synthesis recovery, RAM primitives, timing, hardware bring-up

Status: written 2026-07-06 ~10:40 while compile 8 run 4 was still in quartus_map.
Executor: any capable session. Read `docs/plan_bram_optimisation.md` first for the
house style: baseline before edits, byte-identical frames = correct, exact commands.
The memory file `hyperduel_mister_core.md` carries the live compile state.

## 0. Hard process rules (violating these has already cost nights)

- ONE Quartus job on the PC at a time, ever. The box has 128GB RAM but only a
  ~136GB Windows commit limit (8.5GB pagefile). Two quartus_map processes killed
  each other on 2026-07-06 ~08:50. All "Access Violation" crashes to date are
  consistent with commit exhaustion or tool failure under memory pressure.
- Compiles run ONLY detached via `schtasks /run /tn hyprcompile` (sshd kills
  session children on disconnect). The task trigger is parked at 01/01/2030 so
  it cannot self-fire; launch is always manual via /run.
- `C:\hyprduel\runcompile.cmd` APPENDS to compile8.log with a
  "===== flow start" banner per run. Never change it back to `>`.
- Recommend Lee set a fixed 64GB+ pagefile (System Properties > Advanced >
  Performance > Virtual memory) for headroom. Do not change it yourself; ask.

## 1. Current compile state (check first, act accordingly)

Run 4 config (all already deployed to C:\hyprduel and in the local repo):
OPTIMIZATION_MODE BALANCED + SYNTH_TIMING_DRIVEN_SYNTHESIS OFF (Hyprduel.qsf),
jt6295 luts ramstyle=logic, fx68k structs unpacked for Quartus via
`ifdef VERILATOR` (see rtl/vendor/PATCHES.md for all three vendor patches).

Check the verdict:
```
ssh leefoot@192.168.1.207 "powershell -Command \"Select-String -Path C:\hyprduel\mister\compile8.log -Pattern 'Full Compilation was' | Select-Object -Last 1\""
```

### If run 4 SUCCEEDED
1. Pull `C:\hyprduel\mister\output_files\Hyprduel.rbf` to the Mac (scp with
   forward slashes in the remote path; backslashes fail on download).
2. Pull `Hyprduel.fit.summary` and `Hyprduel.sta.rpt`. Record: ALMs, registers,
   M10K count (budget 557; vram0/1/2 alone ~307), and per-clock Fmax/worst
   setup slack. The clocks that matter are the two 80 MHz PLL outputs.
3. Negative slack does NOT block hardware smoke testing. Go to section 5 and
   run section 3 (RAM primitives) in parallel with hardware bring-up prep.

### If run 4 CRASHED again
The remaining lever is removing the elaboration/netlist balloon at the source:
do section 3 (RAM primitives) FIRST, then relaunch. If even that fails, fall
back to stripping framework extras (MISTER_DISABLE_YC / MISTER_DISABLE_ALSA
macros are ready, commented at the bottom of Hyprduel.qsf) and, last resort,
ask Lee about the pagefile.

### If run 4 is STILL RUNNING in quartus_map after ~3h (12:45+)
Kill it and do section 3 first; the conversion pays for itself immediately.

## 2. Why section 3 exists (the memory balloon diagnosis)

Every run shows the same profile: elaboration messages finish (video subtree
last), then a ~40 min SILENT phase at 50-65GB while Quartus builds the flat
netlist, and only then do "Inferred RAM node" messages appear. The design
declares ~3.2 Mbit of memory as plain SystemVerilog arrays (three 64Kx16
VRAMs dominate) and relies on inference; Quartus 17 appears to materialise
these structurally before recognising them as RAM. Disproven suspects: fx68k
packed structs (unpacking did not shrink the balloon), jt6295 mif quirk
(neutralised, balloon unchanged). Most MiSTer cores avoid this path entirely
by instantiating RAM primitives directly.

## 3. Change: big memories to explicit RAM primitives

### 3.1 The wrapper (sim behaviour must not change)

Create `rtl/hd_dpram.sv`, a true-dual-port wrapper with byte enables:

```systemverilog
module hd_dpram #(
    parameter int AW = 16,
    parameter int DW = 16
) (
    input  logic              clk,
    input  logic [AW-1:0]     addr_a,
    input  logic [DW-1:0]     d_a,
    input  logic              we_a,
    input  logic [DW/8-1:0]   be_a,
    output logic [DW-1:0]     q_a,
    input  logic [AW-1:0]     addr_b,
    input  logic [DW-1:0]     d_b,
    input  logic              we_b,
    input  logic [DW/8-1:0]   be_b,
    output logic [DW-1:0]     q_b
);
`ifdef VERILATOR
  // identical semantics to today's verified inferred arrays
  logic [DW-1:0] mem [0:(1<<AW)-1];
  always_ff @(posedge clk) begin
    if (we_a) for (int i = 0; i < DW/8; i++)
      if (be_a[i]) mem[addr_a][i*8 +: 8] <= d_a[i*8 +: 8];
    q_a <= mem[addr_a];
  end
  always_ff @(posedge clk) begin
    if (we_b) for (int i = 0; i < DW/8; i++)
      if (be_b[i]) mem[addr_b][i*8 +: 8] <= d_b[i*8 +: 8];
    q_b <= mem[addr_b];
  end
`else
  altsyncram #(
    .operation_mode("BIDIR_DUAL_PORT"),
    .width_a(DW), .widthad_a(AW), .numwords_a(1<<AW),
    .width_b(DW), .widthad_b(AW), .numwords_b(1<<AW),
    .width_byteena_a(DW/8), .width_byteena_b(DW/8),
    .outdata_reg_a("UNREGISTERED"), .outdata_reg_b("UNREGISTERED"),
    .read_during_write_mode_port_a("NEW_DATA_NO_NBE_READ"),
    .read_during_write_mode_port_b("NEW_DATA_NO_NBE_READ"),
    .intended_device_family("Cyclone V"), .lpm_type("altsyncram")
  ) ram (
    .clock0(clk), .clock1(clk),
    .address_a(addr_a), .data_a(d_a), .wren_a(we_a), .byteena_a(be_a), .q_a(q_a),
    .address_b(addr_b), .data_b(d_b), .wren_b(we_b), .byteena_b(be_b), .q_b(q_b),
    .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
    .clocken0(1'b1), .clocken1(1'b1), .clocken2(1'b1), .clocken3(1'b1),
    .eccstatus(), .rden_a(1'b1), .rden_b(1'b1)
  );
`endif
endmodule
```

CAVEATS to verify while implementing, do not skip:
- Check how the existing code reads-during-write on the same port and across
  ports. Today's inferred arrays give old-data on cross-port same-address and
  new-data on same-port. altsyncram BIDIR_DUAL_PORT gives old-data cross-port
  on Cyclone V ("DONT_CARE"/old depending on mode). The VDP design already
  guarantees no same-cycle same-address cross-port collisions for vram
  (renderer reads while CPU/blitter writes are separated by design), but
  CONFIRM per memory before converting it; the frame compare will catch lies.
- `read_during_write_mode_port_*("NEW_DATA_NO_NBE_READ")` matches same-port
  RMW semantics of the current arrays. If Quartus 17 rejects that mode string
  for M10K, use "OLD_DATA" and verify no same-port read-of-written-address
  exists in that cycle (grep the FSMs; for vram ports the read data is not
  consumed on write cycles).
- Simulation gate: the `ifdef VERILATOR` branch must produce BYTE-IDENTICAL
  frames and stats to the current code (it is the same logic, so any diff
  means a wiring mistake in the conversion).

### 3.2 Conversion order (measure between steps, do not batch blindly)

1. `vram0/1/2` in i4220_vdp.sv (3 x 64Kx16, TDP: CPU/blitter port + renderer
   port). This is ~95% of the balloon by bits. Wire be as 2'b11 where the
   existing code writes whole words.
2. Rebuild + full gate suite (see 3.3). Deploy, relaunch, measure: elaboration
   silent-phase duration and peak VM (watcher pattern with WS/VM telemetry is
   in the session transcript; reuse it).
3. Only if still ballooning: convert palette (4Kx16), scratch (4Kx16),
   spr_live/spr_buf (2Kx16 each), tiletable (1Kx16), and the three shared RAMs
   in hyprduel_sys.sv (these are the compile-2 TDP templates; port shapes are
   already explicit there). linebuf/lay_mem/spr_mem stay as-is (they infer
   cleanly and are tiny).

### 3.3 Verification gates (identical discipline to the BRAM plan)

```
cd sim
make boot FRAMES=510 SDRAM=1        # BEFORE edits if no fresh baseline exists
mv build/boot_sdram build/boot_sdram_base
# ...apply changes...
make all && make vdp-verify
make boot FRAMES=510 SDRAM=1
for f in build/boot_sdram_base/*.ppm; do cmp "$f" "build/boot_sdram/$(basename $f)" || echo "MISMATCH $f"; done
```
All stats identical (audio transitions, oki lines, worst_line_cycles=4698).
Note build/boot_sdram_base from 2026-07-05 already exists and is still valid
if no functional RTL changed since (the fx68k ifdef and jt6295 attribute are
non-functional; the BRAM conversion is already baselined).

## 4. Timing closure (only after an rbf exists)

1. Read Hyprduel.sta.rpt worst setup paths for the 80 MHz clocks. Fix ONLY
   what it names. Candidates already suspected: renderer resolve/priority
   cone, SDRAM return mux, fx68k paths.
2. If slack is mildly negative (> -1.5ns), first try re-enabling effort
   knobs ONE at a time in this order, one compile each:
   a. SYNTH_TIMING_DRIVEN_SYNTHESIS ON (watch VM telemetry; abort >100GB)
   b. OPTIMIZATION_MODE "HIGH PERFORMANCE EFFORT"
   The RAM-primitive conversion may make both affordable.
3. If slack is badly negative, pipeline the named paths in RTL instead, with
   the frame-compare gate after each change.
4. Seed sweeps (SEED 1..5) are a legitimate last 0.3ns.

## 5. M5 hardware bring-up (needs Lee present)

1. rbf: copy `Hyprduel.rbf` to the MiSTer at `/media/fat/_Arcade/cores/`;
   the MRA (`mister/releases/Hyprduel.mra` in repo) goes in `/media/fat/_Arcade/`.
   MiSTer is DHCP: `nmap -sn 192.168.1.0/24` first, never assume the IP
   (per CLAUDE.md). ssh root@<mister-ip>, password is the MiSTer default
   unless Lee changed it.
2. ROM: MAME set `hyprduel.zip` goes in `/media/fat/games/mame/` (MRA
   references it; byte order in the MRA was written to match MAME regions
   but has NEVER been validated on hardware - treat the first load as
   suspect if the screen is garbage while sim is clean).
3. QA: run `docs/qa_checklist.md`, including the parked audio listening
   tests at native levels (YM/OKI balance was calibrated against MAME
   captures; verify by ear on hardware).
4. DIP defaults in the MRA are bf,ff (= MAME default 0xFFBF, demo sounds ON).

## 6. Housekeeping

- /ship batch pending (only when Lee invokes /ship): BRAM conversion
  (i4220_vdp.sv, i4220_render.sv), tb_system probe, fx68k ifdef, jt6295
  ramstyle, Hyprduel.qsf (BALANCED + TDS OFF), PATCHES.md, both plan docs,
  memory of compile findings. Suggested message theme: "synthesis: BRAM
  accumulators, vendor RAM/struct workarounds, balanced-effort qsf".
- After any completed compile, harvest map elapsed time + peak VM into the
  memory file so the next session can compare configurations honestly.
- The compile7 map report is saved at sim/build/compile7_map.rpt (do not
  delete; it is the only full record of the high-effort-mode failure).
