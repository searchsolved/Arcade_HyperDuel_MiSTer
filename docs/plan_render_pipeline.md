# Plan: pipeline the sprite ROM-address computation in i4220_render

Written 2026-07-07 after compile 12. Prereq reading: docs/plan_timing_closure.md
(steps 1-2 done: multicycle SDC in place, failing paths extracted).

## The failing path (confirmed, not guessed)

All 100 worst setup paths (paths_setup.txt, Mac scratchpad + PC
C:\hyprduel\mister\paths_setup.txt) are `sy0[*]`/`line_r[*]` ->
`o_rom_addr[*]` inside `i4220_render`. That is state ST_S_GREQ
(rtl/i4220_render.sv lines ~550-571), which currently does ALL of this in
one 12.5 ns cycle (measured data delay ~18 ns):

    rowoff = 12'(int'(line_r) - sy0);                        // 32-bit sub
    rowsel = sattr[14] ? (out_h - 12'd1 - rowoff) : rowoff;  // sub + mux
    yidx   = 36'(rowsel) * 36'(dy_q);                        // 12x24 MULT
    rowb   = sgfx + (s_bpp8 ? 26'(yidx[27:16]) * 26'(sw_pix)
                            : 26'(yidx[27:16]) * 26'(sw_pix >> 1)); // MULT + add
    o_rom_addr <= rowb[GFX_AW-1:0];

Two chained multiplies + subtracts + a wide add. The fix: split across
three FSM states so no cycle contains more than one multiply.

## The change (i4220_render.sv only)

Replace ST_S_GREQ with three states (add 2 enum entries, e.g. ST_S_GREQ,
ST_S_GMUL, ST_S_GISS):

1. **ST_S_GREQ** (keeps the existing guard, drops the math):
   - Guard unchanged: `if (int'(line_r) < sy0 || int'(line_r) >= sy0 +
     int'(out_h) || sx0 >= WIDTH || sx0 + int'(out_w) <= 0)` -> skip sprite
     (scur+1, ST_S_RD0). Note this guard is a re-test of ST_S_COVER's and
     is believed redundant, but do NOT remove it in this change.
   - Else register the row selection:
     `rowsel_q <= sattr[14] ? (out_h - 12'd1 - 12'(int'(line_r) - sy0))
                            : 12'(int'(line_r) - sy0);`
     and go to ST_S_GMUL. (rowsel_q is a new `logic [11:0]` reg.)

2. **ST_S_GMUL**: one multiply only:
   `yidx_q <= 36'(rowsel_q) * 36'(dy_q);` (new `logic [35:0]` reg; the
   fitter will drop this into a DSP), go to ST_S_GISS.

3. **ST_S_GISS**: second multiply + add + issue:
   `o_rom_addr <= (sgfx + (s_bpp8 ? 26'(yidx_q[27:16]) * 26'(sw_pix)
                                  : 26'(yidx_q[27:16]) * 26'(sw_pix >> 1)))[GFX_AW-1:0];`
   (mind SystemVerilog part-select-of-expression: compute into a local
   `logic [25:0] rowb` first, as the current code does)
   `o_rom_len <= s_bpp8 ? sw_pix : (sw_pix >> 1);`
   `o_rom_req <= 1'b1; rx2 <= 6'd0; st <= ST_S_GRCV;`

Optional micro-opt if the GISS cycle is still tight after compile: register
`sw_bytes_q <= s_bpp8 ? sw_pix : (sw_pix >> 1)` back in ST_S_ZOOM and use it
in GISS/o_rom_len (removes the bpp8 mux from the multiply input).

Everything the three states consume (sattr, out_h, sy0, sx0, out_w, dy_q,
sgfx, s_bpp8, sw_pix, line_r) is registered before ST_S_GREQ and stable
until the sprite completes, so splitting is functionally transparent.

Cost: +2 cycles per sprite that actually intersects the line (skipped
sprites still exit in 1 cycle from GREQ). Line budget check: worst line was
4783 of 5088 at P_PIXDIV=12-equivalent budget; tens of on-line sprites x2
cycles fits easily, but VERIFY the printed `worst_line_cycles` stays under
5088 after the change - it is printed by both tb_vdp and tb_system runs.

## What NOT to touch

- The tilemap ROM-address site ST_L_TT3 (line ~419, `rowbase = {tile2,5'd0}
  + rowsel*rowbytes`) also chains from line_r via the combinational pix_y
  derivation, but it is a 5x5 multiply, much shallower, and did NOT appear
  in the top 100. Leave it alone in this pass. IF compile 13's STA shows it
  as the new critical path still below 80 MHz: register `pix_y_q <= pix_y`
  in ST_L_TT2 (a wait state, zero added latency) and use pix_y_q in TT3's
  flip/rowsel. Only do this if actually needed.
- fx68k / jt51 / jt6295: covered by SDC multicycles already, leave alone.
- Do not remove the redundant GREQ guard.
- Do not change hyprduel_sys / hyprduel_sdram in this pass.

## Verification gates (all BEFORE compiling)

cd /Users/leefoot/python_scripts/hyperduel-mister/sim
1. `make verify blit-verify` -> 22/22 PASS (blitter untouched; render
   oracle scenes must stay pixel-identical - the pipeline must not change
   OUTPUT, only internal latency).
2. `make vdp-verify` -> frame 500 PASS (900/1500 fail pre-existing,
   mid-frame raster writes).
3. `make boot FRAMES=240` -> POST passes, boots clean, PPM frames identical
   to the current run, and check the printed `render: worst_line_cycles`
   stays < 5088.

## Compile 13 and deploy

PC: ssh leefoot@192.168.1.207. tar+scp rtl/i4220_render.sv to
C:\hyprduel\rtl\, then `schtasks /run /tn hyprcompile` (E-core pinned via
runcompile.cmd; ONE job; log C:\hyprduel\mister\compile8.log append-mode;
~14 min). QSF currently AGGRESSIVE PERFORMANCE + timing-driven synth ON +
packing HIGH; SDC has the multicycles - leave both as-is.

Timing gate: pull Hyprduel.sta.rpt, check the Setup Summary slack for the
core clock (emu|pll ... divclk). Target >= 0. If a NEW module dominates the
remaining violations, re-run the path extractor: `schtasks /run /tn hyprsta`
(runs C:\hyprduel\mister\report_paths.tcl -> paths_setup.txt).

Deploy on pass:
  sshpass -p "1" scp -o PubkeyAuthentication=no \
    <rbf> root@192.168.1.208:/media/fat/_Arcade/cores/Hyprduel.rbf
  sshpass -p "1" ssh -o PubkeyAuthentication=no root@192.168.1.208 \
    "echo 'load_core /media/fat/_Arcade/Hyper Duel.mra' > /dev/MiSTer_cmd"
MRA + hyprduel.zip are already on the MiSTer.

Hardware readout: LED_USER blinking = vblank running (video side alive);
LED_DISK lit = main CPU fetching ROM (CPU executing). Both dark = PLL/reset
problem; LEDs alive but screen black = follow plan_timing_closure.md
bring-up list (P_RET=4 SDRAM capture first, then MRA byte-lane order, then
hs/vs polarity).
