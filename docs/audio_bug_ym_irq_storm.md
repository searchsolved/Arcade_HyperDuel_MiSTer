# OPEN BUG: audio silent - YM2151 timer IRQ storm

Status as of 2026-07-05. Video is unaffected (boot to title pixel-clean);
this is the only known functional bug. Resume here.

## Symptom

`o_audio` (hyprduel_sys mono mix) never changes across a 470-frame boot
that includes ~110 frames of title music (tb_system prints
`audio transitions=0`). Demo Sounds DIP is ON (tb uses i_dsw=0xFFBF;
bit 6 = 0 = demo sounds on; the earlier all-ones DSW was a red herring).

## Probe data (tb/tb_system.sv "sound-path probes" block, still in tree)

470-frame boot (`make boot FRAMES=470`):

- ym_writes = 23,294 (~50/frame: the MUSE driver is alive and sequencing)
- last YM write: reg 0x14, value 0x1F
- sub IPL1 (YM IRQ) acks = 359,080  <- ~764/frame, pathological
  (a music driver takes ~5-50 timer IRQs/frame)
- sub IPL2 (latch 0x0C kick) acks = 15,152 (~32/frame, plausible)
- ym irq_n LOW for 253,525,056 sys cycles = ~85% of the whole run

Conclusion: the sub CPU lives inside its YM timer IRQ handler; the
sequencer never gets time to program voices, so silence.

## Wiring facts (rtl/hyprduel_sys.sv)

- jt51 at sub 0x400000-0x400003; a0 = s_a[1]; write = 1-cycle cs_n low
  pulse during the SB_IDLE commit cycle (ym_wr_n = s_rw); status read
  returns {8'h00, ym_dout} via s_rdata_q (SB_WAIT). Writes demonstrably
  land (23K of them; the MUSE init busy-flag handshake worked, which is
  what unblocked the boot in the first place).
- irq_n -> s_ipl level 1 combinationally; autovectored via VPA.
- cen: P_YMDIV = (P_PIXDIV*5)/3 sys clocks (PIXDIV=16 -> 26 -> 4.103 MHz
  vs real 4.000 MHz); cen_p1 = every other cen (ym_phase toggle).

## YM2151 register reference for this bug

- reg 0x10 CLKA1, 0x11 CLKA2 (timer A period), 0x12 CLKB (timer B period)
- reg 0x14: b0 load A, b1 load B, b2 IRQ enable A, b3 IRQ enable B,
  b4 flag reset A, b5 flag reset B, b6 CSM
- status (dout): b0 = flag A, b1 = flag B, b7 = busy
- Observed last write 0x14 = 0x1F: loads+enables BOTH timers but resets
  ONLY flag A (b5 = 0).

## Ranked hypotheses

1. Flag B never cleared: timers both enabled, handler resets only A
   (0x1F). If the game's handler reads status, sees flag B, and issues a
   separate 0x14 write with b5 that we lose or that jt51 ignores, irq_n
   stays low forever. Check what status values the sub actually reads
   and whether ANY 0x14 write has b5 set.
2. Timer period registers (0x10/0x11/0x12) never written or written to
   the wrong register (e.g. a lost reg-select byte pairs data with the
   wrong register under storm conditions) -> default/short period ->
   max-rate IRQ.
3. jt51 flag-reset semantics deviation vs real chip/MAME (check
   rtl/vendor/jt51/hdl timer module: is flag reset edge-triggered on the
   0x14 write? is irq = (flagA&enA)|(flagB&enB)?).
4. cen_p1 phasing subtlety affecting the busy/write pipeline such that
   some writes are swallowed (less likely: init handshake worked).

## Prepared next diagnostics (in order)

1. Extend the tb probe block: pair register writes (latch a0=0 value as
   cur_reg; on a0=1 log into a 256-entry histogram). Print counts +
   last values for 0x10, 0x11, 0x12, 0x14, and the full set of distinct
   0x14 values seen (specifically: does 0x14 with bit5 ever get
   written?). Also capture the last ~16 status values returned on sub
   YM reads, and whether irq_n rises at all after any 0x14 write.
2. Oracle comparison: run MAME with a Lua write-tap on sub-CPU
   0x400000-0x400003 (same technique as sim/mame/dump_state.lua's
   install_write_tap, but on the ":sub" CPU space) logging (reg, val)
   pairs for the first ~500 frames. Diff the 0x10/0x11/0x12/0x14
   sequences ours-vs-MAME. Divergence point = the bug.
3. If jt51 semantics are implicated, read rtl/vendor/jt51/hdl timer
   source and compare against MAME src/devices/sound/ym2151.cpp flag
   handling; patch jt51 only with a PATCHES.md entry.

## How to run

- Boot with probes: `cd sim && make boot FRAMES=470` (probe summary
  prints at the end; frame PPMs land in sim/build/boot/).
- Do not regress video: `make all render-verify mame-verify vdp-verify`
  must stay 22/22 PASS after any change.
