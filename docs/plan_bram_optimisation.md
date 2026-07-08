# Plan: BRAM conversion wave (linebuf + renderer accumulators)

Status: PLANNED, not implemented. Written 2026-07-05 by the session that ran compiles 1-6.
Intended executor: any capable session (written so Opus can implement it without re-deriving
the design). The hazard analysis in section 4 is the hard part and is already done: follow it,
do not improvise a different memory scheme.

## 1. Why

Quartus synthesis (compile 6) confirmed two structures stay as registers instead of M10K:

- `i4220_vdp.sv` line 82: `linebuf [0:3][0:319]` x 12 bits = 15,360 flops, flagged
  "uninferred due to asynchronous read logic" (read at line 739 is same-cycle).
- `i4220_render.sv` lines 101-107: seven per-pixel accumulator arrays = 11,200 flops
  (320 x 35 bits), variable-index read-modify-write, never inferrable as-is.

Consequences: ~26.5K excess flops with 320-way and 1280-way mux/decoder trees. This is
why quartus_map spent 3+ hours in logic optimization, and these trees are the most likely
source of a first-pass timing failure at 80 MHz. Converting both to BRAM fixes compile
time and timing together, and costs about 5 M10K blocks.

Everything else flagged by synthesis is benign: kick_fifo, jt51/jt6295 LUTs, rowcache and
srowcache are tiny (leave them alone). vram/palette/scratch/spr/tiletable/shared RAMs all
infer correctly already.

## 2. Scope

Files changed: `rtl/i4220_vdp.sv`, `rtl/i4220_render.sv`, `sim/tb/tb_system.sv` (probe only).
No interface changes, no new states, no cycle-count changes. The renderer FSM state flow is
untouched; only where pixel data lives changes.

Hard rules:
- Do NOT add wait/priming states. The design below needs none. If you think you need one,
  you have diverged from the plan; re-read section 4.
- Do NOT change `P_PIXDIV`, state encodings, or the kick fifo.
- Verify with the gates in section 6 before any Quartus run. The Verilator frame compare
  is the oracle; a byte-identical result is the definition of correct.

## 3. Change A: linebuf to sync-read BRAM (i4220_vdp.sv)

Current:
- Decl (line ~82): `logic [11:0] linebuf [0:3][0:319];`
- Write (line ~271): `if (lb_we) linebuf[lb_bank][lb_x] <= lb_pen;`
- Read (line ~739, inside the ce_pix scan-out stage 0):
  `so_pen <= (32'(hcnt) < H_VIS) ? linebuf[vcnt[1:0]][hcnt[8:0] % 320] : 12'd0;`

New: flatten to one 2048-deep memory addressed `{bank[1:0], x[8:0]}` (stride 512, entries
320..511 of each bank unused), and read it continuously every clk into a register:

```systemverilog
logic [11:0] linebuf [0:2047];
logic [11:0] lb_rq;

always_ff @(posedge clk)
  if (lb_we) linebuf[{lb_bank, lb_x}] <= lb_pen;

// continuous sync read for scan-out. Correct because hcnt/vcnt only change on
// ce_pix and P_PIXDIV >= 2 always (12 on hardware, 16 in system sim), so lb_rq
// has settled to the current (vcnt, hcnt) long before the next ce_pix sample.
always_ff @(posedge clk)
  lb_rq <= linebuf[{vcnt[1:0], hcnt[8:0]}];
```

Stage 0 becomes: `so_pen <= (32'(hcnt) < H_VIS) ? lb_rq : 12'd0;`

Notes:
- The `% 320` disappears (stride-512 addressing). When hcnt is 320..423 the address reads
  an unused or out-of-bank word; the H_VIS mux already forces 0, same as today.
- Write and read can hit the same M10K in the same cycle but never the same address:
  the renderer writes bank `lb_bank` while scan-out reads bank `vcnt[1:0]`, and the kick
  pipeline guarantees 1-3 lines of lead between them. Mixed-port same-address behavior
  is therefore never exercised.
- Confirm (read the code, 30 seconds) that hcnt/vcnt increment only under `if (ce_pix)`.
  They do; this is just a tripwire in case anything moved.
- Expected inference: 3 M10K (2048x5 slices). Check the map report for
  `linebuf` under Inferred RAM nodes; the old "uninferred due to asynchronous read"
  info line must be gone.

## 4. Change B: renderer accumulators to two SDP BRAMs (i4220_render.sv)

### 4.1 Memories and packing

Replace the seven arrays (lines 101-107) with two memories, one per logical record:

```systemverilog
// {valid, pri[1:0], pen[11:0]}
logic [14:0] lay_mem [0:511];
// {taken, group[4:0], prival[1:0], pen[11:0]}
logic [19:0] spr_mem [0:511];

logic [14:0] lay_q;      logic [19:0] spr_q;
logic        lay_we;     logic        spr_we;
logic [8:0]  lay_waddr;  logic [8:0]  spr_waddr;
logic [14:0] lay_wdata;  logic [19:0] spr_wdata;
```

Bit map (use these exact positions, define local wires for readability):

| field       | lay_q       | spr_q       |
|-------------|-------------|-------------|
| valid/taken | [14]        | [19]        |
| pri/group   | [13:12]     | [18:14]     |
| prival      | -           | [13:12]     |
| pen         | [11:0]      | [11:0]      |

Read and write ports in their own always_ff blocks (same pattern as the rnd_vram_q reads
in i4220_vdp.sv lines 274-279, which Quartus 17 infers cleanly; do NOT put read and write
in one block, that invites pass-through logic):

```systemverilog
always_ff @(posedge clk) begin
  lay_q <= lay_mem[lay_raddr];
  spr_q <= spr_mem[spr_raddr];
end

always_ff @(posedge clk) begin
  if (lay_we) lay_mem[lay_waddr] <= lay_wdata;
  if (spr_we) spr_mem[spr_waddr] <= spr_wdata;
end
```

`lay_we/spr_we/waddr/wdata` are REGISTERS assigned by the FSM (so all decision logic stays
inside the existing FSM always_ff; writes land one cycle after the decision, which section
4.4 proves safe). Add `lay_we <= 1'b0; spr_we <= 1'b0;` as defaults at the top of the FSM
clocked block, before the case statement (later nonblocking assignments in the same block
override them).

### 4.2 Prefetch addresses (combinational, this is the core of the design)

The FSM consumes `lay_q`/`spr_q` as if they were the old async reads at the current pixel.
That works because every consuming loop walks x sequentially at one pixel per cycle, so the
read address always points one pixel ahead while inside an emit loop, and at the
resume pixel during every other state (fetch stalls, sprite setup, idle), where it gets
refreshed every clk for many cycles before the next consumption:

```systemverilog
// address tracking: one ahead inside advancing states, current otherwise
wire       xadv   = ((st == ST_L_PIX) && (prev_tileoffs == {1'b0, tileoffs}))
                 || (st == ST_CLR) || (st == ST_RESOLVE);
wire [8:0] xnext  = (xcur == 9'(WIDTH-1)) ? 9'd0 : (xcur + 9'd1);
wire [8:0] xtrack = xadv ? xnext : xcur;

assign lay_raddr = xtrack;
assign spr_raddr = (st == ST_S_EMIT) ? 9'(sx0 + xo + 1)
                 : (st == ST_S_RD1 || st == ST_S_RD2 || st == ST_S_RD3 ||
                    st == ST_S_RD4 || st == ST_S_ZOOM || st == ST_S_COVER ||
                    st == ST_S_DIV || st == ST_S_GREQ || st == ST_S_GRCV)
                   ? ((sx0 < 0) ? 9'd0 : 9'(sx0))
                 : xtrack;
```

Why each term is what it is:
- `xadv` mirrors exactly the conditions under which the FSM advances xcur this cycle:
  ST_L_PIX only advances on the cache-hit path (`prev_tileoffs == {1'b0, tileoffs}`,
  see line 291); ST_CLR and ST_RESOLVE always advance. The xnext wrap to 0 primes the
  next pass (layer switch at line 320-325, layer-to-resolve at 323, clr-to-layer at 284).
- Sprite setup states point at the sprite's first visible pixel, which is
  `(sx0 < 0) ? 0 : sx0` (the same clamp as the xo init at line 545). sx0 is computed
  earlier in the sprite sequence, so by the final setup cycle (the one that assigns
  `st <= ST_S_EMIT`) the address is correct and spr_q is primed for the first emit cycle.
- ST_S_RD0 deliberately falls through to `xtrack` (= xcur, which is 0 after the layer
  passes): this primes spr_q with spr_mem[0] for the sprite-to-RESOLVE transition at
  line 323/557 when the sprite list is exhausted. For a normal next sprite, RD1..GRCV
  re-prime with the new sprite's start over ~8 cycles, so the RD0 value is harmlessly
  overwritten.
- ST_IDLE needs no special case: the only direct IDLE-to-RESOLVE path is the blank-line
  path (line 274), and blank RESOLVE writes `i_bg_color` without reading q at all.
- Alignment inside ST_S_EMIT: at the cycle processing offset xo, spr_q holds
  spr_mem[sx0+xo] (prefetched last cycle as sx0+(xo-1)+1, or primed for the first).
  The consumer index `xscr = 9'(sx0 + xo)` matches. xo advances every emit cycle
  regardless of transparency skips (line 576), so alignment never drifts.
- Out-of-range prefetches (e.g. sx0+xo+1 past the row end, or xnext during the last
  RESOLVE pixel) read garbage that is never consumed. Harmless.

### 4.3 FSM rewrites (four sites, keep everything else byte-identical)

ST_CLR (lines 279-280): replace the two array writes with

```systemverilog
lay_we <= 1'b1;  lay_waddr <= xcur;  lay_wdata <= '0;
spr_we <= 1'b1;  spr_waddr <= xcur;  spr_wdata <= '0;
```

ST_L_PIX (lines 309-315): the condition reads become q-field reads:

```systemverilog
if (do_write && (!lay_q[14] || layer_pri_of(layer) <= lay_q[13:12])) begin
  lay_we    <= 1'b1;
  lay_waddr <= xcur;
  lay_wdata <= {1'b1, layer_pri_of(layer), wpen};
end
```

ST_S_EMIT (lines 567-574):

```systemverilog
if (!spr_q[19] || s_group < spr_q[18:14]) begin
  spr_we    <= 1'b1;
  spr_waddr <= xscr;
  spr_wdata <= {1'b1, s_group, s_prival,
                spr_palbase | (s_bpp8 ? 12'(texel)
                                      : ({4'd0, sattr[7:4], 4'd0} | 12'(texel)))};
end
```

ST_RESOLVE (lines 586-599):

```systemverilog
laycode = lay_q[14] ? (2'd3 - lay_q[13:12]) : 2'd0;
if (spr_q[19] && laycode <= spr_q[13:12])
  pen = spr_q[11:0];
else if (lay_q[14])
  pen = lay_q[11:0];
else
  pen = i_bg_color;
...
// pre-clear for the next line (replaces lines 598-599)
lay_we <= 1'b1;  lay_waddr <= xcur;  lay_wdata <= '0;
spr_we <= 1'b1;  spr_waddr <= xcur;  spr_wdata <= '0;
```

Then delete the seven old array declarations. `grep -n 'lay_valid\|lay_pri\|lay_pen\|spr_taken\|spr_group\|spr_prival\|spr_pen'`
must return only the new mem/q/wdata code when you are done.

### 4.4 Hazard analysis (why no bypass logic is needed)

The only failure mode of this design is consuming a q value captured before a relevant
write landed. Writes land at the end of the cycle AFTER the decision (registered write
regs). Enumerating every consume-after-write pair:

- Within one layer pass: each x is visited once. Write [x] decided at cycle N lands end
  of N+1; the only reads in flight are [x+1] (captured end of N) and [x+2] (end of N+1).
  Different addresses, never a conflict.
- Between layer passes (layer 2 writes, layer 1 reads the same x): separated by a full
  320-pixel pass plus a tile fetch (the layer switch invalidates prev_tileoffs, line 318,
  forcing >= 4 fetch cycles before the first consumption, during which the prefetch
  re-reads x=0 every clk). Minimum separation is hundreds of cycles.
- Between sprites (sprite A writes [x], later sprite B reads [x]): B's first consumption
  happens after ST_S_RD0..ST_S_GRCV, at least ~8 cycles after A's last write landed, and
  spr_raddr points at B's first pixel throughout the setup states, refreshing q every clk.
- Sprite to RESOLVE: the last possible spr write lands one cycle into ST_S_RD0;
  RESOLVE's first q (spr_mem[0]) is captured at the end of the same ST_S_RD0 cycle or
  later. A sprite's last write is its highest x (xscr strictly increases), never x=0,
  and any earlier sprite's write to [0] landed long before.
- RESOLVE clears vs RESOLVE reads: clear of [x] lands end of N+1; reads captured at
  end of N+1 are for [x+2]. Two addresses apart, in the safe direction.
- Same-cycle same-address on the two physical ports never occurs (read is always at
  least one address ahead of any write in every pass). M10K mixed-port read-during-write
  "don't care" behavior is therefore never exercised. In Verilator the separate
  always_ff blocks give old-data semantics, which by the above is never observable
  either, so sim and silicon agree.

If the frame compare fails anyway, the bug is prefetch misalignment at a pass boundary.
Instrument by dumping (st, xcur, lay_raddr, spr_raddr) around the first mismatching
pixel's line; check the transition cycles listed in 4.2 before touching anything else.

## 5. TB probe: renderer line budget (sim/tb/tb_system.sv)

The system sim runs at P_PIXDIV=16 (budget 6784 clk/line) but hardware is effectively
~12 (424 x 12 = 5088 clk/line). A bug that added a cycle per pixel would pass the frame
compare at 16 and fail on hardware. Add a max-busy-cycles probe so the gate is explicit
(prior measured worst line: 4783). In tb_system.sv, alongside the other probes:

```systemverilog
int rb_cyc, rb_max;
always @(posedge clk) begin
  if (dut.u_vdp.rnd_busy) rb_cyc <= rb_cyc + 1;
  else begin
    if (rb_cyc > rb_max) rb_max <= rb_cyc;
    rb_cyc <= 0;
  end
end
```

and print `render: worst_line_cycles=%0d` in the end-of-run stats block. Gate: the
value must be <= the baseline run's value (measure baseline first, see below); it should
be IDENTICAL, since the design adds zero cycles.

## 6. Verification gates (all must pass before any Quartus run)

Run from `sim/`. Everything is deterministic; "identical" means byte-identical.

1. Baseline capture at current HEAD (BEFORE editing RTL), with the probe from section 5
   added first (TB-only change, does not perturb the DUT):
   ```
   make boot FRAMES=510 SDRAM=1
   mv build/boot_sdram build/boot_sdram_base
   ```
   Record the printed stats: audio transitions, oki writes/nz_samples/first_nz_frame,
   oki sdram mismatches (must be 0), worst_line_cycles.
2. Apply changes A and B.
3. Unit oracles: `make all` (verify + blit-verify, 22/22) and `make vdp-verify`
   (3 MAME frames, pixel-exact). vdp-verify exercises Change A directly.
   Note: tb_vdp has PINCONNECTEMPTY lint_off pragmas already; if Verilator complains
   about anything new, fix the RTL, do not relax lint.
4. System regression: `make boot FRAMES=510 SDRAM=1` then
   `for f in build/boot_sdram_base/*.ppm; do cmp "$f" "build/boot_sdram/$(basename $f)" || echo "MISMATCH $f"; done`
   Zero mismatches, and every stat from step 1 identical, including worst_line_cycles.
5. Optional but cheap confidence: `make boot FRAMES=510` (no SDRAM, ideal path) and
   compare against its own base the same way if you captured one.

Do not skip gate 1 to save time; without the baseline, gate 4 has nothing to compare
against and MAME dumps only cover a few static frames.

## 7. Quartus compile 7 (PC build box)

Machine: `ssh leefoot@192.168.1.207` (Win11, key auth; DHCP, rescan subnet if the IP
moved). Quartus 17.0.2 at `C:\intelFPGA_lite\17.0`. Layout: `C:\hyprduel\{rtl,mister}`.
No git on the PC; transfer files with tar/scp using ABSOLUTE mac paths (background
shells reset CWD).

1. If a compile 6 process is still alive (check
   `Get-Process quartus_map,quartus_fit -ErrorAction SilentlyContinue`), it is from the
   pre-BRAM netlist; kill it (`taskkill /IM quartus_map /F`) before starting compile 7.
   If compile 6 already finished, harvest its verdict and numbers from
   `C:\hyprduel\mister\compile6.log` for the record first.
2. Copy only the changed RTL: `rtl/i4220_vdp.sv`, `rtl/i4220_render.sv` into
   `C:\hyprduel\rtl\` (scp is fine for two files).
3. Edit `C:\hyprduel\runcompile.cmd` so the log redirect says `compile7.log`
   (check its current content with `type` first).
4. NEVER run quartus_sh in the ssh session directly: Windows sshd kills child processes
   on disconnect (this silently killed compile 5). Launch detached:
   ```
   schtasks /create /f /tn hyprcompile /tr C:\hyprduel\runcompile.cmd /sc once /st 23:59
   schtasks /run /tn hyprcompile
   ```
5. Poll `compile7.log` for `was successful` / `was unsuccessful` (Select-String).
   Expect quartus_map to be dramatically faster than compile 6's 3+ hours; if it is
   not, the RAMs did not infer, stop and check the map report's Inferred RAM section
   for linebuf, lay_mem, spr_mem before burning hours.
6. On completion pull from `C:\hyprduel\mister\output_files\`:
   - `Hyprduel.fit.summary`: ALM, register, M10K counts. M10K budget: the part
     (5CSEBA6U23I7) has 557 blocks; vram0/1/2 alone are ~307. If utilization is
     near the ceiling, note it; the fallback is repacking linebuf to 4x320 or moving
     scratch, not panic.
   - `Hyprduel.sta.rpt`: Fmax Summary and Setup Slack per clock. The clocks that matter
     are the two 80 MHz PLL outputs; framework HDMI clocks come constrained by sys.tcl.
   - `Hyprduel.rbf`: produced whenever the fitter completes, even with negative slack.
7. If timing still misses: read the worst setup paths in sta.rpt and fix what it
   actually names (likely candidates in order: renderer resolve/priority logic, SDRAM
   return mux, fx68k). Do not pre-emptively pipeline anything the report does not name.

## 8. After it works

- Ship only when Lee invokes /ship (commit message should cover: linebuf BRAM
  conversion, accumulator SDP BRAMs with one-ahead prefetch, TB budget probe,
  compile 7 results).
- A negative-slack rbf is still worth a smoke test on the real MiSTer (M5 prep), but
  say so honestly in the report.
- Update `docs/qa_checklist.md` only if hardware behavior observations change it.
