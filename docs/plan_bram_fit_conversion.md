# Plan: BRAM conversion to fix Quartus fit failure (compile 8)

Status: ready to implement. Written 2026-07-07 after compile 8 failed to fit.

## Context

Compile 8 (2026-07-06 19:31 run) passed synthesis (2h01m) but the fitter failed
after 4h06m with Error 11802 "Can't fit design in device":

| Resource        | Used            | Available | Util  |
|-----------------|-----------------|-----------|-------|
| ALMs            | 1,426,275       | 41,910    | 3403% |
| Registers       | 1,514,056       | ~167,640  | ~903% |
| Block mem bits  | 3,768,064       | 5,662,720 | 67%   |
| DSP             | 46              | 112       | 41%   |

Root cause (from `Hyprduel.map.rpt` entity table, copy on the Mac scratchpad):
plain SystemVerilog arrays flattened into flip-flops plus mux trees.

1. `rtl/hyprduel_sys.sv:66-68`: `shared1 [0:16383]`, `shared2 [0:8191]`,
   `shared3 [0:57343]`, all 16-bit. 1,310,720 bits, which matches the
   1,310,892 self-registers reported for `hyprduel_sys:core` almost exactly.
2. `rtl/i4220_vdp.sv:98-103`: `tiletable [0:1023]`, `palette [0:4095]`,
   `spr_live [0:2047]`, `spr_buf [0:2047]`, `scratch [0:4095]` (all 16-bit),
   `linebuf [0:2047]` (12-bit). ~237k bits, matching the VDP's 181k
   self-registers (Quartus managed to infer part of it).

fx68k, jt51, jt6295, sys framework are all fine. The three 64Kx16 VRAMs were
already fixed with the `hd_dpram` wrapper in compile 8 and elaborated cleanly.
This plan applies the same treatment to everything that remains.

## Step 0: reconcile the PC tree with the local repo (do this first)

The `hd_dpram.sv` altsyncram port/clock fix was made ON THE PC between the
19:28 failed run and the 19:31 run (errors 272006/287078 at hd_dpram.sv:85).
The local `rtl/hd_dpram.sv` looks like it already carries the fix
(`indata_reg_b CLOCK1`, `wrcontrol_wraddress_reg_b CLOCK1`, `clock1` wired),
but do not assume.

- `scp` the PC's `C:/hyprduel/rtl/` and `C:/hyprduel/mister/*.qsf` back and
  diff against the local repo. Fold any PC-only fixes into the repo before
  touching anything.
- The PC is `ssh leefoot@192.168.1.207` (DHCP, rescan subnet if dead). No git
  on the PC; transfer via scp/tar.

## Step 1: extend the RAM wrappers

All converted memories keep the existing semantics: synchronous write,
registered read, 1-cycle read latency. Every current access site already reads
with `q <= mem[addr]` inside a clocked block, so no consumer timing changes.

### 1a. `hd_dpram`: replace `1<<AW` sizing with a NUMWORDS parameter

`shared3` is 57,344 words (112 KB, not a power of two). Padding to 64K wastes
131 Kbit of a budget that ends around 94%. altsyncram accepts arbitrary
`numwords_a/b`, so:

```systemverilog
parameter int AW = 16,
parameter int DW = 16,
parameter int NUMWORDS = (1 << AW)   // override for non-pow2 depths
```

Verilator path becomes `mem [0:NUMWORDS-1]`. Existing instantiations are
unaffected (default preserves behaviour).

### 1b. New `hd_tdpram`: true dual port, both ports read/write

`shared1/2/3` are written by BOTH CPUs (port A = main 68000, port B = sub
68000), each with byte enables from uds/lds. The existing `hd_dpram` ties off
port B writes, so a second module (same file or `rtl/hd_tdpram.sv`, add to
`files.qip` and the sim Makefile) is needed:

- Ports: `addr_a, d_a, we_a, be_a, q_a` and the same for `_b`. Single clock.
- Quartus: altsyncram `BIDIR_DUAL_PORT` with `wren_b`/`byteena_b` actually
  wired, `width_byteena_b (DW/8)`, `indata_reg_b ("CLOCK1")`,
  `wrcontrol_wraddress_reg_b ("CLOCK1")`, `clock1(clk)`, both outputs
  UNREGISTERED. Mirror whatever exact parameter set survived tonight's
  clear-box/dual-clock errors in the fixed `hd_dpram` (see Step 0).
- Verilator: two clocked blocks, one per port, byte-lane writes then
  registered read, same shape as `hd_dpram`.
- Note: the game never has the two CPUs hitting the same address in the same
  cycle by design (handshake word 0xFFF34C mediates); do not add bypass logic.

### 1c. Byte-enable-free narrow RAM for `linebuf`

`linebuf` is 12 bits wide (byteena needs DW divisible by 8) and its write is
always full-width (`lb_we`, no byte lanes). Either:

- preferred: give `hd_dpram` a `parameter bit USE_BE = 1`; when 0, tie
  `width_byteena_a (1)` and drop the `be_a` port from use; or
- pad linebuf to 16 bits (wastes 8 Kbit, trivial) and write all lanes.

Pick whichever keeps the Verilator and Quartus paths simplest; do not add a
third module for this alone.

## Step 2: convert `hyprduel_sys.sv` shared RAMs

Current code (all inside clocked always blocks, `hyprduel_sys.sv:447-481`):
port A = main CPU (`sr*_addr_a`, `m_dout`, `m_udsn/m_ldsn`, q into `sr*_q_a`),
port B = sub CPU (`sr*_addr_b`, `s_dout`, `s_udsn/s_ldsn`, q into `sr*_q_b`).

Replace each array + always block pair with one `hd_tdpram`:

| RAM     | Depth  | NUMWORDS | we_a (main)                  | we_b (sub)                   |
|---------|--------|----------|------------------------------|------------------------------|
| shared1 | 16384  | 16384    | existing main-write cond 447 | existing sub-write cond 452  |
| shared2 | 8192   | 8192     | cond at 460                  | cond at 465                  |
| shared3 | 57344  | 57344    | cond at 473                  | cond at 476                  |

be = `{~udsn, ~ldsn}` per side. we = the existing enclosing write condition
(select + write strobe). Keep the exact select/decode logic; only the storage
moves. `sr*_q_a/b` become the wrapper's q outputs (delete the local regs).

Careful with the shared1 sub-side shadow reads (`s_sel_vec`, line 352) and the
shared3 RO shadow (`s_sel_ro3`, line 353): these route through the same port B
read path today; confirm the address mux feeding `sr*_addr_b` is untouched.

## Step 3: convert `i4220_vdp.sv` arrays

Port assignment per array (all single clock, all reads already registered):

| Array     | Bits    | Wrapper    | Port A (r/w)                          | Port B (read)              |
|-----------|---------|------------|---------------------------------------|----------------------------|
| tiletable | 16K     | hd_dpram   | CPU: read 494, write 543              | renderer read 300          |
| palette   | 64K     | hd_dpram   | CPU: read 495, write 535              | scan-out read 750          |
| scratch   | 64K     | hd_dpram   | CPU: read 497, write 531              | unused (tie addr 0)        |
| spr_live  | 32K     | hd_dpram   | CPU: read 496, write 539              | vblank copy read 325       |
| spr_buf   | 32K     | hd_dpram   | vblank copy write 326 (full width)    | renderer read 305          |
| linebuf   | 24K     | 1c variant | renderer write 293 (lb_we)            | scan-out read 296          |

The one real wrinkle is `spr_live`, which today has THREE read sites (306
renderer, 325 copy, 496 CPU). The renderer read at 305-308 only matters when
`P_SPR_BUFFERED == 0`:

```systemverilog
assign rnd_spr_q = P_SPR_BUFFERED ? spr_buf_q : spr_live_rq;   // line 308
```

The shipping core uses the buffered path, so gate the unbuffered read out
under a generate on `P_SPR_BUFFERED` (tie `spr_live_rq` to '0 when buffered)
rather than spending a third port. Keep the unbuffered generate branch working
for sim configs that use it, if any (check how the testbenches set the param;
if nothing uses 0, delete the path and the mux entirely and note it in the
module header).

`spr_buf` port A carries the copy write; note the copy engine reads `spr_live`
and writes `spr_buf` with a one-entry pipeline (`cp_q`, lines 325-326); the
1-cycle registered read it already relies on is unchanged by the wrapper.

## Step 4: read-during-write note (no action expected)

`hd_dpram`'s Verilator path returns OLD data on a same-cycle same-address
write+read on port A; altsyncram is configured `NEW_DATA_NO_NBE_READ` (new
data). This divergence is benign for every port in this plan because a 68000
bus cycle is either a read or a write (q is ignored during writes), the
renderer never writes, and the copy engine's read and write target different
RAMs. Do not "fix" this; just do not introduce any new consumer that reads q
on the cycle it writes.

## Step 5: verification gate (all must pass before compile 9)

Verilator behaviour should be bit-identical since the wrapper's sim path is
the same registered-read array. Prove it:

1. `sim/make verify blit-verify vdp-verify`: full suite, 22/22.
2. `tb_system` boot: 17/17 frames byte-identical vs the golden run, stats
   match (`worst_line_cycles=4698`).
3. Long boot to first music (1300 frames) unaffected; spot-check voice/jingle
   RMS as in the audio post-mortem.
4. Lint pass of `mister/Hyprduel.sv` against `lint_stubs.sv` still clean.

If any frame diffs, the likely cause is a dropped write condition or a port
mux error in Step 2/3, not the wrapper.

## Step 6: compile 9 on the PC

Budget check first. Expected block memory bits:

| Item                          | Bits       |
|-------------------------------|------------|
| Current (compile 8 map)       | 3,768,064  |
| shared1/2/3 (exact numwords)  | 1,310,720  |
| VDP arrays (linebuf at 12b)   | 237,568    |
| Total                         | 5,316,352  |
| Device                        | 5,662,720  |
| Utilisation                   | ~94%       |

M10K block granularity will push the real figure a few points higher; if the
fitter runs out of M10Ks, first fallback is dropping the hq2x scandoubler
buffers or ascal features from the sys side, second is moving shared3 (the
112 KB block) behind the SDRAM controller. Do not pre-emptively do either.

Transfer and run, obeying the standing PC rules (they have cost days):

- tar the changed files, scp to the PC, extract over `C:/hyprduel/`.
- ALWAYS `start /AFFINITY FFFF0000` (E-cores only). P-cores crash the machine
  under sustained load (HYPERVISOR_ERROR).
- One Quartus job at a time. Launch detached via `schtasks /run /tn
  hyprcompile` only; sshd kills child processes.
- `compile8.log` is append mode with `===== flow start` banners; keep using it
  (or start compile9.log, same convention).
- Expected timeline based on compile 8: ~2h synthesis, fitter should be far
  faster than 4h once it is not placing 1.4M ALMs. Elaboration staying at
  ~2min/10GB confirms the wrappers took.
- On success pull back: `output_files/Hyprduel.rbf`, `Hyprduel.fit.summary`,
  `Hyprduel.sta.rpt`. Check Fmax on the sys/video clocks against the PLL
  targets before calling it done. Then M5: MRA + ROM load on the real MiSTer.

## Files touched

- `rtl/hd_dpram.sv` (NUMWORDS param, optional USE_BE)
- `rtl/hd_tdpram.sv` (new) or same-file second module
- `rtl/hyprduel_sys.sv` (shared1/2/3)
- `rtl/i4220_vdp.sv` (six arrays)
- `mister/files.qip`, `sim/` Makefile file lists if a new file is added
- `vendor/PATCHES.md` only if anything vendored moves (nothing should)
