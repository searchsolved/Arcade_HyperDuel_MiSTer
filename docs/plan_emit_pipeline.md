# Plan: skewed-prefetch pipeline for the sprite emit loop (compile 13 -> 14)

Written 2026-07-07 after compile 13. Prior fixes in this chain:
plan_timing_closure.md (SDC multicycles), plan_render_pipeline.md
(ST_S_GREQ 3-state split, DONE, Fmax 55 -> 65 MHz).

## Current state

Compile 13: SUCCESS, core clock slack -2.834 ns (TNS -99.6), Fmax 65.21 MHz
vs 80 needed. rbf NOT deployed. All 100 worst paths (paths_c13.txt, Mac
scratchpad + PC C:\hyprduel\mister\paths_setup.txt) are one path shape:
`xo[1]/xo[3]` -> `spr_waddr[0..8]` in i4220_render, data delay ~14.7 ns.

## Why the path is long (read this before editing)

In ST_S_EMIT (i4220_render.sv ~595-619) the write to the sprite line
accumulator is qualified by the texel opacity test. The chain from xo:

    xsel     = sattr[15] ? (out_w - 1 - xo) : xo        // line ~250, sub+mux
    s_xidx   = s_xsel * dx_q                            // line ~253, 12x24 MULT
    s_pixidx = s_xidx[27:16]
    texel    = srowcache[s_pixidx[...]]                 // 64:1 mux (+nibble sel)
    opaque   = bpp8 ? texel!=FF : texel[3:0]!=F
    enable   = opaque && (!spr_q[19] || s_group < spr_q[18:14])
    -> clock-enable of spr_waddr / spr_wdata / spr_we   // ~14.7 ns total

The DATA into spr_waddr (`xscr = sx0 + xo`) is trivial; the ENABLE is the
critical arc (TimeQuest reports enable paths against the register). The
same chain also feeds spr_wdata's data (texel merged into the pen).

## The fix: skewed prefetch (zero cycles per pixel, +1 cycle per sprite)

xo advances by exactly +1 every ST_S_EMIT iteration. So compute the pixel
index for iteration N+1 during iteration N and register it. The emit cycle
then starts from a REGISTERED index: srowcache mux + compare + enable only
(~6-7 ns), and the multiply lands in its own register stage (~9-10 ns).
Output is bit-identical: same texels, same writes, same order.

### RTL changes (i4220_render.sv only)

1. New register: `logic [11:0] s_pixidx_q;`

2. New enum state `ST_S_PRIME` (add after ST_S_GISS in the st_e enum).

3. Helper function or expression for the index of a GIVEN xo value
   (mirror of the existing combinational s_xsel/s_xidx, lines ~246-254):

       // pixel index for output offset v (flip X + zoom scale)
       function automatic logic [11:0] pixidx_of(input int v);
         logic [11:0] xs;
         logic [35:0] xi;
         xs = 12'(sattr[15] ? (int'(out_w) - 1 - v) : v);
         xi = 36'(xs) * 36'(dx_q);
         return xi[27:16];
       endfunction

4. ST_S_GRCV (lines ~573-584): unchanged except the exit goes to
   ST_S_PRIME instead of ST_S_EMIT. (xo and xo_end are set here already.)

5. New ST_S_PRIME: one cycle to prime the first index:

       ST_S_PRIME: begin
         s_pixidx_q <= pixidx_of(xo);
         st <= ST_S_EMIT;
       end

   (Path here: registered xo -> sub/mux -> 12x24 mult -> reg. No srowcache
   after it. ~10 ns, fits.)

6. ST_S_EMIT: replace uses of the combinational `s_pixidx` with
   `s_pixidx_q`, and register the NEXT index each iteration:

       ST_S_EMIT: begin
         if (xo >= xo_end) begin
           scur <= scur + 10'd1;
           st <= ST_S_RD0;
         end else begin
           logic [7:0] texel;
           logic [8:0] xscr;
           if (s_bpp8) texel = srowcache[s_pixidx_q[5:0]];
           else texel = s_pixidx_q[0] ? {4'd0, srowcache[s_pixidx_q[6:1]][7:4]}
                                      : {4'd0, srowcache[s_pixidx_q[6:1]][3:0]};
           xscr = 9'(sx0 + xo);
           ... (write block unchanged, uses texel) ...
           s_pixidx_q <= pixidx_of(xo + 1);
           xo <= xo + 1;
         end
       end

   Note the two paths this creates, both short:
   - s_pixidx_q -> srowcache mux -> opacity -> enable of spr_* regs
   - xo -> +1 -> sub/mux -> mult -> s_pixidx_q register
   Computing pixidx_of(xo+1) on the last iteration (xo+1 == xo_end) is
   harmless: the value is registered but never consumed (next state is
   RD0/PRIME which overwrites it). srowcache indices are 6-7 bit slices,
   no out-of-bounds possible.

7. The old combinational `s_xsel`/`s_xidx`/`s_pixidx` block (lines
   ~246-254) becomes dead once EMIT uses the function - DELETE it (or fold
   it into the function) so Verilator -Wall in the render TB stays clean.
   Check tb_render.sv / tb_vdp.sv do not reference s_pixidx hierarchically
   (grep first).

### Accuracy statement

This is a latency-only restructure. Pixel values, write order, and write
addresses are unchanged; the renderer is a functional line renderer whose
accuracy contract is (a) pixel-exact output vs MAME and (b) finishing
within the line budget - both preserved. +1 cycle per sprite that reaches
the emit phase; per-pixel cost unchanged. Expected worst_line_cycles:
~5550 + (sprites on worst line), still absorbed by the 4-bank elastic
kick FIFO (3 lines of lookahead).

## Verification gates (all BEFORE compiling)

cd /Users/leefoot/python_scripts/hyperduel-mister/sim
1. `make verify blit-verify` -> 22/22, pixel-identical.
2. `make vdp-verify` -> frame 500 PASS (900/1500 pre-existing fails).
3. `make boot FRAMES=240` -> boots, PPMs identical to compile-13 run,
   note `render: worst_line_cycles` (expect ~5550-5600; do not gate hard
   on 5088 - that is the single-line budget, the elastic FIFO absorbs
   spikes - but report the number).

## Compile 14

Transfer i4220_render.sv (scp to leefoot@192.168.1.207:C:/hyprduel/rtl/),
launch `schtasks /run /tn hyprcompile` (E-core rules, one job, log
C:\hyprduel\mister\compile8.log, ~15 min). Keep QSF (AGGRESSIVE
PERFORMANCE etc.) and SDC as they are.

STA gate: Setup Summary slack on `emu|pll...divclk`. Target >= 0.

### If a NEW path is critical (likely candidate, be ready)

The TILE emit path has the same shape minus the multiply: xcur ->
resx add/mask chain (lines ~201-223, combinational tilemap derivation) ->
pix_x -> flip mux -> rowcache 16:1 mux -> opacity -> lay_we/lay_wdata
enable in ST_L_PIX. It did not make the top 100 (all <= -2.75) so it is
somewhere better than -2.7; after this fix it may surface at a small
negative. Same trick applies if needed: the FSM already computes
`xnext`/`xtrack` for BRAM prefetch (lines ~264-276), so a registered
`pix_x_q` primed from xnext can be added - but ONLY do this if compile
14's STA still fails and `schtasks /run /tn hyprsta` shows the tile path.
Do not pre-apply.

If the remaining violation is < ~1 ns on a misc path, a seed sweep is
acceptable last resort: `set_global_assignment -name SEED 2` (then 3) in
Hyprduel.qsf.

## Deploy on timing pass

    sshpass -p "1" scp -o PubkeyAuthentication=no \
      <Hyprduel.rbf> root@192.168.1.208:/media/fat/_Arcade/cores/Hyprduel.rbf
    sshpass -p "1" ssh -o PubkeyAuthentication=no root@192.168.1.208 \
      "echo 'load_core /media/fat/_Arcade/Hyper Duel.mra' > /dev/MiSTer_cmd"

MRA + hyprduel.zip already in place. Readout: LED_USER blinking = vblank
alive; LED_DISK lit = main CPU fetching. Timing clean + LEDs alive + black
screen -> hardware bring-up list in plan_timing_closure.md (SDRAM P_RET=4
first, then MRA byte-lane order, then hs/vs polarity).
