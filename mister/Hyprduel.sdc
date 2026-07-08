derive_pll_clocks
derive_clock_uncertainty

# --------------------------------------------------------------------------
# Multicycle constraints for clock-enable-gated cores.
#
# The 80 MHz sys clock drives everything, but the CPU and audio cores only
# advance on clock enables many sys-clocks apart:
#   fx68k:   enPhi1/enPhi2, P_CPUDIV=8 -> 4 sys clocks between edges (10 MHz)
#   jt51:    ym_cen at ~4 MHz -> 20 sys clocks
#   jt6295:  oki_cen at ~2 MHz -> ~39 sys clocks
#
# TimeQuest defaults to single-cycle analysis for all paths on the 80 MHz
# clock, but intra-core paths in these modules have multiple clock edges to
# settle. Multicycle 2 is conservative (25 ns vs 12.5 ns, real budget is
# 50+ ns) and closes the 55->80 MHz gap with zero accuracy impact.
#
# ONLY intra-core paths are relaxed. Cross-boundary paths (CPU -> bus FSM,
# BRAM, dtack) remain single-cycle constrained.
# --------------------------------------------------------------------------

# fx68k main CPU: internal paths get 2 cycles
set_multicycle_path -setup -end 2 \
    -from [get_registers {emu|core|u_maincpu|*}] \
    -to   [get_registers {emu|core|u_maincpu|*}]
set_multicycle_path -hold -end 1 \
    -from [get_registers {emu|core|u_maincpu|*}] \
    -to   [get_registers {emu|core|u_maincpu|*}]

# fx68k sub CPU: internal paths get 2 cycles
set_multicycle_path -setup -end 2 \
    -from [get_registers {emu|core|u_subcpu|*}] \
    -to   [get_registers {emu|core|u_subcpu|*}]
set_multicycle_path -hold -end 1 \
    -from [get_registers {emu|core|u_subcpu|*}] \
    -to   [get_registers {emu|core|u_subcpu|*}]

# jt51 (YM2151): internal paths get 2 cycles (real budget is 20+)
set_multicycle_path -setup -end 2 \
    -from [get_registers {emu|core|u_ym|*}] \
    -to   [get_registers {emu|core|u_ym|*}]
set_multicycle_path -hold -end 1 \
    -from [get_registers {emu|core|u_ym|*}] \
    -to   [get_registers {emu|core|u_ym|*}]

# jt6295 (OKI M6295): internal paths get 2 cycles (real budget is ~39)
set_multicycle_path -setup -end 2 \
    -from [get_registers {emu|core|u_oki|*}] \
    -to   [get_registers {emu|core|u_oki|*}]
set_multicycle_path -hold -end 1 \
    -from [get_registers {emu|core|u_oki|*}] \
    -to   [get_registers {emu|core|u_oki|*}]
