# Releases

`Hyprduel_YYYYMMDD.rbf` files here are the released bitstreams. Copy
the RBF to `/media/fat/_Arcade/cores/` and the MRA files from `../mra/`
to `/media/fat/_Arcade/`, with your `hyprduel.zip` ROM set (MAME 0.288
naming) in `/media/fat/games/mame/`.

Every released RBF passed, in order: the full Verilator parity suite,
the always-on integrity gates over a 2,200-frame SDRAM-model soak with
the hardware DIP configuration, a clean Quartus timing summary (all
clocks non-negative, report timestamps matched to the bitstream), an
md5-verified deploy, and on-hardware verification on a CRT.
