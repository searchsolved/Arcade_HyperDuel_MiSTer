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

## OPLL core decision (DONE)

IKAOPLL selected (die-shot cycle-accurate, BSD-2, pure Verilog).
Vendored unmodified at `rtl/vendor/ikaopll/`, smoke test PASS
(`sim/make opll-smoke`). See `rtl/vendor/PATCHES.md`.

## Order of work

1. DONE: OPLL core selection + vendored, verilated standalone.
2. DONE: System glue parameterised via `GAME_MAGERROR` on
   `hyprduel_sys` (one RTL tree, no fork). Verified through Quartus
   17 synthesis with GAME_MAGERROR=0 (dead code eliminated cleanly).
3. DONE: Sim bring-up against MAME magerror as oracle: boot to
   attract in 600 frames, VDP state matches MAME at frame 510
   (registers identical, vram1/vram2 zero diffs, vram0 0.11%).
   All integrity gates PASS. Commit 79c4b8f.
4. IN PROGRESS: SDRAM soak (2200 frames), Quartus compile with
   IKAOPLL in file list, STA gate.
5. MRA + release: second core RBF (template does not support mod
   bytes natively; same-RBF requires adding mod byte support to
   hps_io wiring, deferred).

## Verification bar

Same as hyprduel v1.0: no deploy on register metrics alone; STA clean
plus soak gates before hardware; MAME-parity evidence banked; accuracy
claims land in ACCURACY.md with evidence class named.
