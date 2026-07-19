# Releases

Released bitstreams. Copy the RBF to `/media/fat/_Arcade/cores/` and
the MRA files from `../mra/` to `/media/fat/_Arcade/`, with the
matching ROM set (MAME 0.288 naming) in `/media/fat/games/mame/`.

Hyper Duel uses `hyprduel.zip`; Magical Error uses `magerror.zip`.
Each game has its own RBF (the I4220 is shared but the sound chip and
memory map differ).

| File | md5 | Notes |
|------|-----|-------|
| `Hyprduel_20260719.rbf` | `87b6ee7d275b96c4b01a635fac204335` | Hyper Duel v1.0. Hiscore SDRAM-snoop address fix, verified saving on hardware. |
| `Magerror_20260719.rbf` | `33f7c0de13501a51f48bdffea92d60de` | Magical Error wo Sagase v1.0. IKAOPLL (YM2413), shared1 in SDRAM, verified on hardware. |

Every released RBF passed, in order: the full Verilator parity suite,
the always-on integrity gates over a 2,200-frame SDRAM-model soak with
the hardware DIP configuration, a clean Quartus timing summary (all
clocks non-negative, report timestamps matched to the bitstream), an
md5-verified deploy, and on-hardware verification on a CRT.
