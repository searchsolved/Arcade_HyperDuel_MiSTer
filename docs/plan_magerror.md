# Plan: Magical Error wo Sagase (magerror)

Second game on the same dual-68000 + Imagetek I4220 architecture
(Technosoft / Jaleco, 1994; same MAME driver, `hyprduel.cpp`). The
whole VDP, renderer, SDRAM layer, CRTC window logic and shell carry
over. This branch tracks the delta work; `main` stays frozen at the
released v1.0 state until this is CRT-verified.

## Confirmed deltas (from the vendored driver)

1. **Main CPU map relocation**: the VDP block sits in the 0x8xxxxx
   window (int enable at 0x8788A5). Decode change in system glue.
2. **IRQ enable mask**: `irq_enable_w(data | 0xFE)` (hyprduel uses
   0xFD). One constant.
3. **Sound**: YM2413 (OPLL) at 3.579545 MHz replaces the YM2151.
   Sub CPU writes it at 0x800000-0x800003 (write-only). The YM IRQ to
   the sub CPU is gone; instead the sub CPU takes a periodic IRQ1 at
   968 Hz (MAME comments "tempo?"). OKI M6295 unchanged (same clock
   config inherited in MAME; keep our measured 80/40 divider unless
   magerror recordings say otherwise).
4. **No cpusync init hacks**: magerror uses `empty_init`. Our real
   shared RAM made those moot for hyprduel already; boot should be
   simpler, not harder.
5. **DIPs**: own INPUT_PORTS block (translate to MRA/OSD).
6. **ROMs**: maincpu 2x256KB (24.u24 CRC 5e78027f, 23.u23 CRC
   7271ec70), vdp 4x1MB mr93046-01/02/03/04 (same LOAD64_WORD
   interleave as hyprduel, so `build_gfxrom.py` works as is), oki
   256KB 97.u97 CRC 2e62bca8. Region sizes identical to hyprduel:
   SDRAM layout unchanged.

## OPLL core decision (first task)

Candidates: IKAOPLL (cycle-level YM2413) or jotego's jtopl-family
2413 if one exists in usable form. Evaluate licence, Verilator
compatibility and MiSTer track record before wiring anything; vendor
with PATCHES.md discipline like jt51/jt6295. Removing jt51 frees
logic/BRAM, so fit should improve, but timing gets re-closed and
STA-gated regardless.

## Order of work

1. OPLL core selection + vendored, verilated standalone.
2. System glue: address decode variant, IRQ mask, 968 Hz timer,
   sub map. Parameterise hyprduel-vs-magerror as a build config or
   MRA-selected mode; do NOT fork the RTL.
3. Sim bring-up against MAME magerror as oracle (same harness:
   dump_state, frame parity, state diffs). Needs the magerror ROM set
   locally (MAME 0.288 naming) - blocker until supplied.
4. Full gates: parity suite, SDRAM soak, STA, deploy, CRT verify.
5. MRA + release: second core RBF or same RBF with MRA-driven config
   (decide at step 2; same-RBF preferred if fit allows).

## Verification bar

Same as hyprduel v1.0: no deploy on register metrics alone; STA clean
plus soak gates before hardware; MAME-parity evidence banked; accuracy
claims land in ACCURACY.md with evidence class named.
