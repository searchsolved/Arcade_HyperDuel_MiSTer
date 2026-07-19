# Releases

`Hyprduel_YYYYMMDD.rbf` files here are the released bitstreams. Copy
the RBF to `/media/fat/_Arcade/cores/` and the MRA files from `../mra/`
to `/media/fat/_Arcade/`, with your `hyprduel.zip` ROM set (MAME 0.288
naming) in `/media/fat/games/mame/`.

| File | md5 | Notes |
|------|-----|-------|
| `Hyprduel_20260719.rbf` | `87b6ee7d275b96c4b01a635fac204335` | First release. Includes the hiscore SDRAM-snoop address fix (bit 16 of the sr3 word address), verified saving on hardware. |

Every released RBF passed, in order: the full Verilator parity suite,
the always-on integrity gates over a 2,200-frame SDRAM-model soak with
the hardware DIP configuration, a clean Quartus timing summary (all
clocks non-negative, report timestamps matched to the bitstream), an
md5-verified deploy, and on-hardware verification on a CRT.
