//============================================================================
//  Hyper Duel for MiSTer - framework shell (M4)
//
//  Wraps rtl/hyprduel_sys.sv + rtl/hyprduel_sdram.sv in the MiSTer
//  Template_MiSTer `emu` interface. Needs the template's sys/ framework
//  and Quartus 17.0.x to build; everything below the port list is
//  complete and lint-clean, so the Quartus session is mechanical:
//    - generate the PLL (pll.qip): outclk_0 = 80 MHz, outclk_1 = 80 MHz
//      with -90 degree phase for SDRAM_CLK
//    - add sys/, this file, rtl/*.sv and rtl/vendor/{fx68k,jt51,jt6295}
//    - unused template ports (UART, SD, DDRAM, ADC...) are tied off by
//      the template's stub defaults
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
);

  // ------------------------------------------------------------------
  // Clocks: 80 MHz system (P_PIXDIV=12 -> 6.667 MHz pixel, 60.01 Hz;
  // P_YMDIV=20 -> exactly 4.000 MHz YM2151 cen)
  // ------------------------------------------------------------------
  wire clk_sys, clk_sdram, pll_locked;

  pll pll (
    .refclk(CLK_50M),
    .rst(1'b0),
    .outclk_0(clk_sys),
    .outclk_1(clk_sdram),   // 80 MHz, -90 deg for the SDRAM chip
    .locked(pll_locked)
  );

  assign SDRAM_CLK = clk_sdram;

  wire reset = RESET | status[0] | buttons[1] | ~pll_locked | ioctl_download;

  // ------------------------------------------------------------------
  // hps_io
  // ------------------------------------------------------------------
  `include "build_id.v"
  localparam CONF_STR = {
    "Hyprduel;;",
    "-;",
    "O[5:3],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
    "-;",
    "DIP;",
    "-;",
    "R[0],Reset;",
    "J1,Shot,Change,Bomb,Start,Coin,Service;",
    "jn,A,B,X,Start,Select,L;",
    "V,v",`BUILD_DATE
  };

  wire  [1:0] buttons;
  wire [127:0] status;
  wire [31:0] joystick_0, joystick_1;
  wire        forced_scandoubler;
  wire        direct_video;
  wire [21:0] gamma_bus;

  wire        ioctl_download;
  wire        ioctl_wr;
  wire [26:0] ioctl_addr;
  wire  [7:0] ioctl_dout;
  wire  [7:0] ioctl_index;

  hps_io #(.CONF_STR(CONF_STR)) hps_io (
    .clk_sys(clk_sys),
    .HPS_BUS(HPS_BUS),
    .EXT_BUS(),
    .gamma_bus(gamma_bus),

    .buttons(buttons),
    .status(status),
    .status_menumask({15'd0, direct_video}),
    .forced_scandoubler(forced_scandoubler),
    .direct_video(direct_video),

    .ioctl_download(ioctl_download),
    .ioctl_wr(ioctl_wr),
    .ioctl_addr(ioctl_addr),
    .ioctl_dout(ioctl_dout),
    .ioctl_index(ioctl_index),

    .joystick_0(joystick_0),
    .joystick_1(joystick_1)
  );

  // DIPs arrive as raw DSW port bytes on ioctl index 254 (MRA switches,
  // default bf,ff = 0xFFBF = MAME defaults, demo sounds ON)
  reg [15:0] dsw = 16'hFFBF;
  always @(posedge clk_sys)
    if (ioctl_wr && ioctl_index == 8'd254 && ioctl_addr < 27'd2) begin
      if (ioctl_addr[0]) dsw[15:8] <= ioctl_dout;
      else               dsw[7:0]  <= ioctl_dout;
    end

  // ------------------------------------------------------------------
  // SDRAM: ioctl download writes the MRA stream at byte address 0
  // (stream order = SDRAM map: main 512 KB, GFX 4 MB, OKI 256 KB)
  // ------------------------------------------------------------------
  wire        mrom_rd, mrom_valid;
  wire [17:0] mrom_addr;
  wire [15:0] mrom_data;
  wire [17:0] oki_addr;
  wire  [7:0] oki_data;
  wire        oki_ok;
  wire        gfx_req, gfx_valid;
  wire [21:0] gfx_addr;
  wire  [6:0] gfx_len;
  wire  [7:0] gfx_data;
  wire        dl_busy;
  wire        rom_load = ioctl_download && (ioctl_index == 8'd0);

  hyprduel_sdram sdram (
    .clk(clk_sys),
    .rst_n(pll_locked & ~RESET),
    .o_ready(),

    .i_gfx_req(gfx_req), .i_gfx_addr(gfx_addr), .i_gfx_len(gfx_len),
    .o_gfx_data(gfx_data), .o_gfx_valid(gfx_valid),

    .i_mrom_rd(mrom_rd), .i_mrom_addr(mrom_addr),
    .o_mrom_data(mrom_data), .o_mrom_valid(mrom_valid),

    .i_oki_addr(oki_addr), .o_oki_data(oki_data), .o_oki_ok(oki_ok),

    .i_dl_wr(ioctl_wr && rom_load),
    .i_dl_addr(ioctl_addr[24:0]),
    .i_dl_data(ioctl_dout),
    .o_dl_busy(dl_busy),

    .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQ(SDRAM_DQ),
    .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
    .SDRAM_nCS(SDRAM_nCS), .SDRAM_nRAS(SDRAM_nRAS),
    .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nWE(SDRAM_nWE),
    .SDRAM_CKE(SDRAM_CKE)
  );

  // ------------------------------------------------------------------
  // inputs (board ports are active low; MAME hyprduel.cpp:348-372)
  // P1/P2: bit0 U, 1 D, 2 L, 3 R, 4 shot, 5 change, 6 bomb
  // MiSTer joystick: bit0 R, 1 L, 2 D, 3 U, then J1 order from bit 4
  // ------------------------------------------------------------------
  wire [15:0] p1p2 = ~{
      1'b0, joystick_1[6], joystick_1[5], joystick_1[4],
      joystick_1[0], joystick_1[1], joystick_1[2], joystick_1[3],
      1'b0, joystick_0[6], joystick_0[5], joystick_0[4],
      joystick_0[0], joystick_0[1], joystick_0[2], joystick_0[3]};

  // SYSTEM: bit0 coin1, 1 coin2, 2 service1, 3 service2, 4 start1, 5 start2
  wire [15:0] system_in = ~{10'd0,
      joystick_1[7], joystick_0[7],           // start2, start1
      1'b0, joystick_0[9] | joystick_1[9],    // service2, service1
      joystick_1[8], joystick_0[8]};          // coin2, coin1

  // SERVICE port: bit15 service mode (low = on), bit14 Show Warning off
  wire [15:0] service_in = 16'hFFFF;

  // ------------------------------------------------------------------
  // core
  // ------------------------------------------------------------------
  wire        hs, vs, de, ce_pix, hbl, vbl;
  wire  [4:0] r5, g5, b5;
  wire signed [15:0] audio;

  hyprduel_sys #(.GFX_AW(22), .P_PIXDIV(12)) core (
    .clk(clk_sys), .rst_n(~reset),
    .o_hs(hs), .o_vs(vs), .o_de(de), .o_ce_pix(ce_pix),
    .o_hblank(hbl), .o_vblank(vbl),
    .o_r(r5), .o_g(g5), .o_b(b5),
    .o_audio(audio),
    .i_p1p2(p1p2), .i_system(system_in),
    .i_dsw(dsw), .i_service(service_in),
    .o_mrom_rd(mrom_rd), .o_mrom_addr(mrom_addr),
    .i_mrom_data(mrom_data), .i_mrom_valid(mrom_valid),
    .o_oki_addr(oki_addr), .i_oki_data(oki_data), .i_oki_ok(oki_ok),
    .o_rom_req(gfx_req), .o_rom_addr(gfx_addr), .o_rom_len(gfx_len),
    .i_rom_data(gfx_data), .i_rom_valid(gfx_valid),
    .i_gfx_size(24'h400000),
    .dbg_subctl(), .dbg_sub_in_reset()
  );

  // ------------------------------------------------------------------
  // video: 320x224, RGB555 expanded to 8:8:8 through arcade_video
  // (handles scandoubler fx, gamma, aspect)
  // ------------------------------------------------------------------
  // CLK_VIDEO and CE_PIXEL are driven by arcade_video via .*
  assign VGA_F1 = 1'b0;
  assign VGA_SCALER = 1'b0;
  assign VGA_DISABLE = 1'b0;
  assign HDMI_FREEZE = 1'b0;
  assign HDMI_BLACKOUT = 1'b0;
  assign HDMI_BOB_DEINT = 1'b0;

  assign VIDEO_ARX = 13'd4;    // arcade 4:3 monitor
  assign VIDEO_ARY = 13'd3;

  arcade_video #(.WIDTH(320), .DW(15)) arcade_video (
    .*,
    .clk_video(clk_sys),
    .ce_pix(ce_pix),
    .RGB_in({r5, g5, b5}),
    .HBlank(hbl),
    .VBlank(vbl),
    .HSync(hs),
    .VSync(vs),
    .fx(status[5:3])
  );

  // ------------------------------------------------------------------
  // audio / LEDs
  // ------------------------------------------------------------------
  assign AUDIO_L = audio;
  assign AUDIO_R = audio;
  assign AUDIO_S = 1'b1;          // signed
  assign AUDIO_MIX = 2'b00;

  assign LED_USER = {1'b0, ioctl_download};
  assign LED_POWER = 2'b00;
  assign LED_DISK = 2'b00;

endmodule
