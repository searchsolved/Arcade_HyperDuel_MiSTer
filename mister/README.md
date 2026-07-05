# MiSTer framework integration (M4, in progress)

This directory will hold the Quartus project wrapping `rtl/` in the MiSTer
framework. It cannot be built on macOS; it needs Quartus 17.0.x (the
MiSTer-pinned version) on Linux/Windows, or the community Docker image.

## Plan

- Base: MiSTer-devel/Template_MiSTer (sys/ framework + emu.sv shell).
- Clocks: PLL sys = 80 MHz; VDP P_PIXDIV = 12 (pixel 6.667 MHz, 60.01 Hz);
  68000 enables at /8 (10 MHz); jt51 cen at /20 (4 MHz); jt6295 cen at ~39
  (2.0625 MHz). Renderer worst line measured 4,783 cycles vs 5,088 budget.
- SDRAM map (download stream, matches mra/Hyper Duel.mra):
  - 0x000000 main 68000 ROM (512 KB) - served to hyprduel_sys via a new
    external main-ROM read port (currently an internal sim BRAM; needs the
    port refactor plus a small instruction prefetch to hide latency)
  - 0x080000 GFX ROM (4 MB) - served through the existing stream port
    (o_rom_req/addr/len -> SDRAM burst reads; the port was designed for
    this)
  - 0x480000 OKI samples (256 KB) - jt6295 rom_addr/data/ok port, either
    from SDRAM (low bandwidth) or copied to BRAM at load if space allows
- BRAM budget reminder (docs/hyprduel_system_spec.md sec 8): VRAM 3x128 KB
  stays internal; shared RAM 160 KB internal; palette/spr/tt/linebufs
  internal. Main ROM and OKI go external to fit.
- Video: o_r/g/b (5 bit) + hs/vs/de/ce_pix -> arcade_video / video_mixer.
- Audio: o_audio (16-bit signed mono) -> AUDIO_L = AUDIO_R. Consider
  enabling the jt6295 interpolator (needs jtframe_fir_mono from jtframe)
  once jtframe is vendored for the framework build.
- Inputs: joystick_0/1 -> i_p1p2; start/coin/service -> i_system; OSD
  status bits -> i_dsw per the MRA switches block; i_service = 0xFFFF with
  bit 15 = !service_mode.
- Sim-only constructs to gate out for synthesis: the `ifndef SYNTHESIS
  $readmemh blocks in hyprduel_sys (replaced by the ROM ports).

## Remaining work items

1. hyprduel_sys ROM-port refactor (main ROM + OKI ROM external).
2. SDRAM controller + arbiter glue (stream port -> bursts).
3. emu.sv shell + .qsf pin/clock constraints from the template.
4. Quartus timing closure at 80 MHz.
