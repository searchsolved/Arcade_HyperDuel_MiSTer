//============================================================================
//  Hyper Duel for MiSTer - framework shell (M4 SKELETON, not yet built)
//
//  Wraps rtl/hyprduel_sys.sv in the MiSTer Template_MiSTer `emu` interface.
//  Requires the template's sys/ framework and Quartus 17.0.x to build.
//  See mister/README.md for the plan; this file pins the structure so the
//  Quartus bring-up session is mechanical.
//============================================================================

module emu
(
    input         CLK_50M,
    input         RESET,
    inout  [48:0] HPS_BUS,
    output        CLK_VIDEO,
    output        CE_PIXEL,
    output [12:0] VIDEO_ARX,
    output [12:0] VIDEO_ARY,
    output  [7:0] VGA_R,
    output  [7:0] VGA_G,
    output  [7:0] VGA_B,
    output        VGA_HS,
    output        VGA_VS,
    output        VGA_DE,
    output        VGA_F1,
    output  [1:0] VGA_SL,
    output        VGA_SCALER,
    output        VGA_DISABLE,
    input  [11:0] HDMI_WIDTH,
    input  [11:0] HDMI_HEIGHT,
    output        HDMI_FREEZE,
    output        HDMI_BLACKOUT,
    output        HDMI_BOB_DEINT,
    output  [1:0] LED_POWER,
    output  [1:0] LED_DISK,
    output  [1:0] LED_USER,
    output [15:0] AUDIO_L,
    output [15:0] AUDIO_R,
    output        AUDIO_S,
    output  [1:0] AUDIO_MIX,
    // SDRAM
    output        SDRAM_CLK,
    output        SDRAM_CKE,
    output [12:0] SDRAM_A,
    output  [1:0] SDRAM_BA,
    inout  [15:0] SDRAM_DQ,
    output        SDRAM_DQML,
    output        SDRAM_DQMH,
    output        SDRAM_nCS,
    output        SDRAM_nCAS,
    output        SDRAM_nRAS,
    output        SDRAM_nWE
    // (remaining template ports tied off in the real build)
);

  // ------------------------------------------------------------------
  // Clocks: pll -> clk_sys 80 MHz. P_PIXDIV = 12 (6.667 MHz pixel).
  // ------------------------------------------------------------------
  wire clk_sys, pll_locked;
  // pll pll (.refclk(CLK_50M), .rst(0), .outclk_0(clk_sys), .locked(pll_locked));

  wire reset = RESET | ~pll_locked | ioctl_download;

  // ------------------------------------------------------------------
  // hps_io: OSD config string, joysticks, dips, ioctl download
  // ------------------------------------------------------------------
  localparam CONF_STR = {
    "Hyprduel;;",
    "-;",
    "DIP;",
    "-;",
    "R0,Reset;",
    "J1,Shot,Change,Bomb,Start,Coin,Service;",
    "V,v",`BUILD_DATE
  };

  wire [31:0] joystick_0, joystick_1;
  wire [15:0] dipsw;              // from status bits per MRA switches
  wire        ioctl_download, ioctl_wr;
  wire [26:0] ioctl_addr;
  wire [15:0] ioctl_dout;
  // hps_io #(.CONF_STR(CONF_STR), .WIDE(1)) hps_io (...);

  // ------------------------------------------------------------------
  // SDRAM: download writes; runtime serves 3 read clients
  //   0x000000 main ROM (512 KB), 0x080000 GFX (4 MB), 0x480000 OKI (256 KB)
  // ------------------------------------------------------------------
  wire        mrom_rd, mrom_valid;
  wire [17:0] mrom_addr;
  wire [15:0] mrom_data;
  wire [17:0] oki_addr;
  wire  [7:0] oki_data;
  wire        oki_ok;
  wire              gfx_req;
  wire [21:0]       gfx_addr;
  wire  [6:0]       gfx_len;
  wire  [7:0]       gfx_data;
  wire              gfx_valid;
  // sdram + rom mux instance: serves mrom (word), gfx (byte burst),
  // oki (byte, ok-tracked); download port writes during ioctl_download.

  // ------------------------------------------------------------------
  // core
  // ------------------------------------------------------------------
  wire        hs, vs, de, ce_pix;
  wire  [4:0] r5, g5, b5;
  wire signed [15:0] audio;

  // inputs per docs/hyprduel_system_spec.md sec 6 (active low)
  wire [15:0] p1p2 = ~{
      joystick_1[7], joystick_1[6], joystick_1[5], joystick_1[4],
      joystick_1[0], joystick_1[1], joystick_1[2], joystick_1[3],
      joystick_0[7], joystick_0[6], joystick_0[5], joystick_0[4],
      joystick_0[0], joystick_0[1], joystick_0[2], joystick_0[3]};
  wire [15:0] system_in = ~{10'd0, joystick_1[7], joystick_0[7],
                            1'b0, 1'b0, joystick_1[8], joystick_0[8]};

  hyprduel_sys #(.GFX_AW(22), .P_PIXDIV(12)) core (
    .clk(clk_sys), .rst_n(~reset),
    .o_hs(hs), .o_vs(vs), .o_de(de), .o_ce_pix(ce_pix),
    .o_r(r5), .o_g(g5), .o_b(b5),
    .o_audio(audio),
    .i_p1p2(p1p2), .i_system(system_in),
    .i_dsw(~dipsw), .i_service(16'hFFFF),
    .o_mrom_rd(mrom_rd), .o_mrom_addr(mrom_addr),
    .i_mrom_data(mrom_data), .i_mrom_valid(mrom_valid),
    .o_oki_addr(oki_addr), .i_oki_data(oki_data), .i_oki_ok(oki_ok),
    .o_rom_req(gfx_req), .o_rom_addr(gfx_addr), .o_rom_len(gfx_len),
    .i_rom_data(gfx_data), .i_rom_valid(gfx_valid),
    .i_gfx_size(24'h400000),
    .dbg_subctl(), .dbg_sub_in_reset()
  );

  // video: arcade_video #(320, 224, 15) with RGB555, or video_mixer
  assign CLK_VIDEO = clk_sys;
  assign CE_PIXEL  = ce_pix;
  assign {VGA_R, VGA_G, VGA_B} = {r5, r5[4:2], g5, g5[4:2], b5, b5[4:2]};
  assign VGA_HS = hs;
  assign VGA_VS = vs;
  assign VGA_DE = de;

  assign AUDIO_L = audio;
  assign AUDIO_R = audio;
  assign AUDIO_S = 1'b1;   // signed

endmodule
