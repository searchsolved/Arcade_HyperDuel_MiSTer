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
	`include "sys/emu_ports.vh"
);

///////// defaults for ports this core does not use /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;
assign BUTTONS = 0;


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
    "O[6],Test Pattern,Off,On;",
    "O[7],Video Timing,Native 60.24Hz,60Hz Compat;",
    "O[8],Boot Warning,Show,Skip;",
    "O[9],Autosave Hiscores,Off,On;",
    "-;",
    "DIP;",
    "-;",
    "R[0],Reset;",
    "J1,Shot,Change,Bomb,Start,Coin,Service;",
    "jn,A,B,X,Start,Select,L;",
    "v,0;",
    "V,v",`BUILD_DATE
  };

  wire  [1:0] buttons;
  wire [127:0] status;
  wire [31:0] joystick_0, joystick_1;
  wire        forced_scandoubler;
  wire        direct_video;
  wire [21:0] gamma_bus;

  wire        ioctl_download;
  wire        ioctl_upload;
  wire        ioctl_upload_req;
  wire  [7:0] ioctl_din;
  wire        ioctl_wr;
  wire [26:0] ioctl_addr;
  wire  [7:0] ioctl_dout;
  wire [15:0] ioctl_index;

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
    .ioctl_wait(dl_busy),

    .ioctl_upload(ioctl_upload),
    .ioctl_upload_req(ioctl_upload_req),
    .ioctl_upload_index(8'd4),
    .ioctl_din(ioctl_din),

    .joystick_0(joystick_0),
    .joystick_1(joystick_1)
  );

  // DIPs arrive as raw DSW port bytes on ioctl index 254 (MRA switches,
  // default bf,ff = 0xFFBF = MAME defaults, demo sounds ON)
  reg [15:0] dsw = 16'hFFBF;
  always @(posedge clk_sys)
    if (ioctl_wr && ioctl_index[7:0] == 8'd254 && ioctl_addr < 27'd2) begin
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
  wire [15:0] gfx_data;   // word-mode GFX stream (2 bytes/valid)
  wire        dl_busy;
  wire        rom_load = ioctl_download && (ioctl_index[7:0] == 8'd0);
  wire        sr3_req, sr3_we, sr3_ack;
  wire [16:0] sr3_addr;
  wire [15:0] sr3_wdata, sr3_rdata;
  wire  [1:0] sr3_be;

  // P_RET must match the value the sim suite validates (3, = CL2 + capture
  // reg). The old 4 was a blind bring-up guess: single reads still worked
  // (bus hold), but burst data came back shifted one word, so the MUSE
  // signature scan never matched and boot never released the sub CPU.
  hyprduel_sdram #(.P_RET(3)) sdram (
    .clk(clk_sys),
    .rst_n(pll_locked),
    .o_ready(),

    .i_gfx_req(gfx_req), .i_gfx_addr(gfx_addr), .i_gfx_len(gfx_len),
    .o_gfx_data(gfx_data), .o_gfx_valid(gfx_valid),

    .i_mrom_rd(mrom_rd), .i_mrom_addr(mrom_addr),
    .o_mrom_data(mrom_data), .o_mrom_valid(mrom_valid),

    .i_oki_addr(oki_addr), .o_oki_data(oki_data), .o_oki_ok(oki_ok),

    .i_sr3_req(hs_owns ? hsq_pend : sr3_req),
    .i_sr3_we(hs_owns ? 1'b1 : sr3_we),
    .i_sr3_addr(hs_owns ? hsq_addr : sr3_addr),
    .i_sr3_wdata(hs_owns ? hsq_data : sr3_wdata),
    .i_sr3_be(hs_owns ? hsq_be : sr3_be),
    .o_sr3_rdata(sr3_rdata), .o_sr3_ack(sr3_ack),

    .i_dl_wr(ioctl_wr && rom_load),
    .i_dl_addr(ioctl_addr[24:0]),
    .i_dl_data(ioctl_dout),
    .o_dl_busy(dl_busy),
    .i_dl_active(ioctl_download),

    .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQ(SDRAM_DQ),
    .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
    .SDRAM_nCS(SDRAM_nCS), .SDRAM_nRAS(SDRAM_nRAS),
    .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nWE(SDRAM_nWE),
    .SDRAM_CKE(SDRAM_CKE),
    .dbg_dl_saw(dbg_dl_saw), .dbg_dl_byte0(dbg_dl_byte0),
    .dbg_dl_byte1(dbg_dl_byte1), .dbg_dl_count(dbg_dl_count),
    .dbg_selftest(dbg_selftest), .dbg_postdl(dbg_postdl),
    .dbg_dl_written(dbg_dl_written), .dbg_dl_dropped(dbg_dl_dropped),
    .dbg_fsm_info(dbg_fsm_info),
    .dbg_sums(dbg_sums), .dbg_sumb1(dbg_sumb1), .dbg_sumb2(dbg_sumb2)
  );
  wire dbg_dl_saw;
  wire [7:0] dbg_dl_byte0, dbg_dl_byte1;
  wire [23:0] dbg_dl_count, dbg_dl_written;
  wire [15:0] dbg_selftest, dbg_postdl, dbg_fsm_info;
  wire [15:0] dbg_sums, dbg_sumb1, dbg_sumb2;
  wire [15:0] dbg_dl_dropped;

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
  // SERVICE port: bit15 = Service Mode (1 = off), bit14 = Show Warning
  // (0 = show, matching MAME's default and the unmodified PCB line; our
  // old constant FFFF silently skipped the boot legal screen).
  wire [15:0] service_in = {1'b1, status[8], 14'h3FFF};

  // ------------------------------------------------------------------
  // core
  // ------------------------------------------------------------------
  wire        hs, vs, de, ce_pix, hbl, vbl;
  wire  [4:0] r5, g5, b5;
  wire signed [15:0] audio;

  hyprduel_sys #(.GFX_AW(22), .P_PIXDIV(12)) core (
    .i_compat60(status[7]),
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
    .o_sr3_req(sr3_req), .o_sr3_we(sr3_we), .o_sr3_addr(sr3_addr),
    .o_sr3_wdata(sr3_wdata), .o_sr3_be(sr3_be),
    .i_sr3_rdata(sr3_rdata), .i_sr3_ack(sr3_ack & ~hs_owns),
    .o_rom_req(gfx_req), .o_rom_addr(gfx_addr), .o_rom_len(gfx_len),
    .i_rom_data(gfx_data), .i_rom_valid(gfx_valid),
    .i_gfx_size(24'h400000),
    .dbg_subctl(dbg_subctl), .dbg_sub_in_reset(dbg_sub_in_reset),
    .dbg_vdp_write(dbg_vdp_write), .dbg_line_start(dbg_line_start),
    .dbg_rnd_done(dbg_rnd_done), .dbg_lb_nonzero(dbg_lb_nonzero),
    .dbg_cpu_past_vectors(dbg_cpu_past_vectors),
    .dbg_vdp_cs_seen(dbg_vdp_cs_seen),
    .dbg_mrom_word0(dbg_mrom_word0), .dbg_mrom_word1(dbg_mrom_word1),
    .dbg_mrom_word2(dbg_mrom_word2), .dbg_mrom_word3(dbg_mrom_word3),
    .dbg_sack_cnt(dbg_sack_cnt), .dbg_palw(dbg_palw),
    .dbg_hshk(dbg_hshk), .dbg_iack1(dbg_iack1),
    .dbg_wadr(dbg_wadr), .dbg_wcnt(dbg_wcnt), .dbg_srrc(dbg_srrc),
    .dbg_ovr(dbg_ovr),
    .dbg_wda(dbg_wda),
    .dbg_b3e_w0(dbg_b3e_w0), .dbg_b3e_w1(dbg_b3e_w1), .dbg_bank(dbg_bank)
  );
  // ------------------------------------------------------------------
  // High score save/restore (MAME hiscore.dat via Hiscores_MiSTer).
  // Table = sharedram3 bytes 0xFFF2A2-0xFFF2DD (0x3C) + flag 0xFFF2E2
  // = sr3 words 0xD951-0xD971. A 64-word shadow snoops every CPU write
  // on the already-muxed sr3 port (both 68000s funnel through it), so
  // hiscore reads are single-cycle BRAM reads; hiscore restore writes
  // update the shadow and flush one byte at a time to SDRAM through a
  // grab-when-idle arbiter (the CPUs' level-held requests always win;
  // config header spaces writes 128 clks apart so the 1-deep queue
  // always drains). The sub-CPU sr3 read cache is not invalidated by
  // restore writes, but only the main CPU touches the score table.
  // ------------------------------------------------------------------
  localparam [16:0] HSW0 = 17'h0D951;
  localparam [16:0] HSW1 = 17'h0D971;

  wire [23:0] hs_ram_addr;
  wire  [7:0] hs_dout;
  wire        hs_write;

  hiscore #(
    .HS_ADDRESSWIDTH(24), .HS_SCOREWIDTH(7),
    .CFG_ADDRESSWIDTH(2), .CFG_LENGTHWIDTH(1)
  ) u_hiscore (
    .clk(clk_sys), .paused(1'b0), .reset(reset), .autosave(status[9]),
    .ioctl_upload(ioctl_upload), .ioctl_upload_req(ioctl_upload_req),
    .ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr),
    .ioctl_addr(ioctl_addr[24:0]), .ioctl_index(ioctl_index[7:0]),
    .OSD_STATUS(OSD_STATUS),
    .data_from_hps(ioctl_dout), .data_from_ram(hs_din_q),
    .ram_address(hs_ram_addr), .data_to_hps(ioctl_din),
    .data_to_ram(hs_dout), .ram_write(hs_write),
    .ram_intent_read(), .ram_intent_write(),
    .pause_cpu(), .configured()
  );

  reg  [15:0] hs_shadow [0:63];
  wire [16:0] hs_word = 17'((hs_ram_addr - 24'hFE4000) >> 1);
  wire [5:0]  hs_sidx = 6'(hs_word - HSW0);
  wire [1:0]  hs_wbe  = hs_ram_addr[0] ? 2'b01 : 2'b10;
  reg   [7:0] hs_din_q;
  reg         hs_write_d;
  wire        hs_wr_pulse = hs_write && !hs_write_d;

  reg         hsq_pend, hs_owns;
  reg  [16:0] hsq_addr;
  reg  [15:0] hsq_data;
  reg  [1:0]  hsq_be;

  always @(posedge clk_sys) begin
    hs_write_d <= hs_write;
    // snoop CPU writes to the score region
    if (sr3_req && sr3_we && sr3_ack && !hs_owns &&
        sr3_addr >= HSW0 && sr3_addr <= HSW1) begin
      if (sr3_be[1]) hs_shadow[6'(sr3_addr - HSW0)][15:8] <= sr3_wdata[15:8];
      if (sr3_be[0]) hs_shadow[6'(sr3_addr - HSW0)][7:0]  <= sr3_wdata[7:0];
    end
    // hiscore restore writes: shadow at once, SDRAM via the queue
    if (hs_wr_pulse) begin
      if (hs_wbe[1]) hs_shadow[hs_sidx][15:8] <= hs_dout;
      if (hs_wbe[0]) hs_shadow[hs_sidx][7:0]  <= hs_dout;
      hsq_pend <= 1'b1;
      hsq_addr <= hs_word;
      hsq_data <= {hs_dout, hs_dout};
      hsq_be   <= hs_wbe;
    end
    hs_din_q <= hs_ram_addr[0] ? hs_shadow[hs_sidx][7:0]
                               : hs_shadow[hs_sidx][15:8];
    // grab the SDRAM sr3 port only when the core side is idle
    if (!hs_owns) begin
      if (hsq_pend && !sr3_req) hs_owns <= 1'b1;
    end else if (sr3_ack) begin
      hsq_pend <= 1'b0;
      hs_owns  <= 1'b0;
    end
    if (reset) begin
      hsq_pend <= 1'b0;
      hs_owns  <= 1'b0;
      hs_write_d <= 1'b0;
    end
  end

  wire dbg_sub_in_reset, dbg_vdp_write, dbg_line_start;
  wire dbg_rnd_done, dbg_lb_nonzero;
  wire dbg_cpu_past_vectors, dbg_vdp_cs_seen;
  wire [15:0] dbg_mrom_word0, dbg_mrom_word1, dbg_mrom_word2, dbg_mrom_word3;
  wire [7:0]  dbg_subctl, dbg_iack1;
  wire [15:0] dbg_sack_cnt, dbg_palw, dbg_hshk;
  wire [15:0] dbg_wadr, dbg_wcnt, dbg_srrc, dbg_ovr;
  wire [15:0] dbg_wda [0:3];
  wire [15:0] dbg_b3e_w0, dbg_b3e_w1, dbg_bank;

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

  // DEBUG: diagnostic screen (status[6]=1 via OSD, else normal core output)
  //
  // All debug values are vsync-snapshotted into s_* registers so the
  // display reads stable data. The overlay computation is pipelined
  // over 3 registered stages to keep it off the critical timing paths.
  //
  // Layout (320x224):
  //   rows 0-27:   8 flag bands (each 40px wide), green=seen red=not
  //   rows 32+:    9 rows of "LABEL XXXX" hex values
  //
  reg [8:0] dbg_hcnt;
  reg [8:0] dbg_vcnt;
  always @(posedge clk_sys)
    if (ce_pix) begin
      dbg_hcnt <= hbl ? 9'd0 : dbg_hcnt + 9'd1;
      if (vbl)
        dbg_vcnt <= 9'd0;
      else if (dbg_hcnt == 9'd319)
        dbg_vcnt <= dbg_vcnt + 9'd1;
    end

  reg sr3_ack_saw;
  always @(posedge clk_sys)
    if (sr3_ack) sr3_ack_saw <= 1'b1;

  reg [7:0] dbg_reset_count = 8'd0;
  reg       reset_prev = 1'b0;
  always @(posedge clk_sys) begin
    reset_prev <= RESET;
    if (RESET && !reset_prev)
      dbg_reset_count <= dbg_reset_count + 8'd1;
  end

  // vsync snapshot: capture all debug words once per frame
  reg [15:0] s_selftest, s_postdl, s_mrom_word0, s_mrom_word1;
  reg [7:0]  s_dl_byte0, s_dl_byte1;
  reg [23:0] s_dl_count, s_dl_written;
  reg [15:0] s_dl_dropped, s_fsm_info;
  reg [15:0] s_sack_cnt, s_palw, s_hshk;
  reg [7:0]  s_subctl, s_iack1;
  reg [15:0] s_wadr, s_wcnt, s_srrc;
  reg [15:0] s_wda0, s_wda1, s_wda2, s_wda3;
  reg [15:0] s_b3e_w0, s_b3e_w1, s_bank;
  reg [15:0] s_sums, s_sumb1, s_sumb2;
  reg [7:0]  s_reset_count;
  reg [7:0]  s_flags;
  always @(posedge clk_sys)
    if (vbl & ce_pix) begin
      s_selftest    <= dbg_selftest;
      s_postdl      <= dbg_postdl;
      s_mrom_word0  <= dbg_mrom_word0;
      s_mrom_word1  <= dbg_mrom_word1;
      s_dl_byte0    <= dbg_dl_byte0;
      s_dl_byte1    <= dbg_dl_byte1;
      s_dl_count    <= dbg_dl_count;
      s_dl_written  <= dbg_dl_written;
      s_dl_dropped  <= dbg_dl_dropped;
      s_fsm_info    <= dbg_fsm_info;
      s_reset_count <= dbg_reset_count;
      s_sack_cnt    <= dbg_sack_cnt;
      s_palw        <= dbg_palw;
      s_hshk        <= dbg_hshk;
      s_subctl      <= dbg_subctl;
      s_iack1       <= dbg_iack1;
      s_wadr        <= dbg_wadr;
      s_wcnt        <= dbg_wcnt;
      s_srrc        <= dbg_srrc;
      s_wda0        <= dbg_wda[0];
      s_wda1        <= dbg_wda[1];
      s_wda2        <= dbg_wda[2];
      s_wda3        <= dbg_wda[3];
      s_b3e_w0      <= dbg_b3e_w0;
      s_b3e_w1      <= dbg_b3e_w1;
      s_bank        <= dbg_bank;
      s_sums        <= dbg_sums;
      s_sumb1       <= dbg_ovr;      // overrun count (repurposed row)
      s_sumb2       <= dsw;          // live DSW word (DIP debug, was p1p2)
      // band 8 = lb_nonzero: renderer ever produced a non-black pixel
      // (download liveness is proven by the DLCT/DLWR rows instead)
      s_flags       <= {led_mrom_saw, dbg_vdp_cs_seen, dbg_vdp_write,
                        dbg_cpu_past_vectors,
                        dbg_line_start, dbg_rnd_done,
                        sr3_ack_saw, dbg_lb_nonzero};
    end

  // --- pipeline stage 1: decode row/col/value from snapshotted data ---
  reg [3:0]  p1_hex_row;
  reg [3:0]  p1_char_col;
  reg [15:0] p1_hex_val;
  reg [3:0]  p1_char_y;
  reg [1:0]  p1_font_x;
  reg        p1_px_gap;
  reg        p1_in_char_area;
  reg        p1_in_flag_row;
  reg        p1_flag_green;
  reg [8:0]  p1_hcnt, p1_vcnt;

  always @(posedge clk_sys) begin
    logic [3:0] hr;
    logic [3:0] fidx;
    logic [3:0] cy;
    logic [8:0] cxr;

    p1_hcnt <= dbg_hcnt;
    p1_vcnt <= dbg_vcnt;

    hr = (dbg_vcnt >= 9'd32  && dbg_vcnt < 9'd52)  ? 4'd0 :
         (dbg_vcnt >= 9'd52  && dbg_vcnt < 9'd72)  ? 4'd1 :
         (dbg_vcnt >= 9'd72  && dbg_vcnt < 9'd92)  ? 4'd2 :
         (dbg_vcnt >= 9'd92  && dbg_vcnt < 9'd112) ? 4'd3 :
         (dbg_vcnt >= 9'd112 && dbg_vcnt < 9'd132) ? 4'd4 :
         (dbg_vcnt >= 9'd132 && dbg_vcnt < 9'd152) ? 4'd5 :
         (dbg_vcnt >= 9'd152 && dbg_vcnt < 9'd172) ? 4'd6 :
         (dbg_vcnt >= 9'd172 && dbg_vcnt < 9'd192) ? 4'd7 :
         (dbg_vcnt >= 9'd192 && dbg_vcnt < 9'd212) ? 4'd8 : 4'd15;
    p1_hex_row <= hr;

    case (hr)
      4'd0: p1_hex_val <= s_sums;                 // single-read checksum (expect BE3A)
      4'd1: p1_hex_val <= s_sumb1;                // OVRC: dropped render kicks
      4'd2: p1_hex_val <= s_sumb2;                // P1P2: live input word
      4'd3: p1_hex_val <= s_b3e_w0;               // bank-3E window word0 (expect 4D55)
      4'd4: p1_hex_val <= {s_subctl, s_iack1};    // SCTL/IAK1
      4'd5: p1_hex_val <= s_wcnt;                 // WCNT: GFX-window read count
      4'd6: p1_hex_val <= s_srrc;                 // SRRC: main sr3 read acks
      4'd7: p1_hex_val <= {s_reset_count, s_dl_dropped[7:0]};
      default: p1_hex_val <= s_fsm_info;
    endcase

    // char_y = pixel row within the 20px row (0..19); rows start at
    // vcnt 32,52,72,...,192.  Use the row start derived from hex_row
    // instead of a modulo divider.
    case (hr)
      4'd0:    cy = 4'(dbg_vcnt - 9'd32);
      4'd1:    cy = 4'(dbg_vcnt - 9'd52);
      4'd2:    cy = 4'(dbg_vcnt - 9'd72);
      4'd3:    cy = 4'(dbg_vcnt - 9'd92);
      4'd4:    cy = 4'(dbg_vcnt - 9'd112);
      4'd5:    cy = 4'(dbg_vcnt - 9'd132);
      4'd6:    cy = 4'(dbg_vcnt - 9'd152);
      4'd7:    cy = 4'(dbg_vcnt - 9'd172);
      4'd8:    cy = 4'(dbg_vcnt - 9'd192);
      default: cy = 4'd15;
    endcase
    p1_char_y <= cy;

    // 16px character cells: 4 font columns x 4px, with the last pixel of
    // every 4px column blanked (3px dots + 1px gaps = readable on CRT)
    cxr = dbg_hcnt - 9'd16;
    p1_char_col <= cxr[7:4];
    p1_font_x <= cxr[3:2];
    p1_px_gap <= (cxr[1:0] == 2'b11);
    p1_in_char_area <= (dbg_hcnt >= 9'd16 && dbg_hcnt < 9'd160)
                     && (hr != 4'd15) && (cy < 4'd14);  // 7 font rows * 2x scale

    p1_in_flag_row <= (dbg_vcnt < 9'd28);
    fidx = (dbg_hcnt < 40) ? 4'd0 : (dbg_hcnt < 80) ? 4'd1 :
           (dbg_hcnt < 120) ? 4'd2 : (dbg_hcnt < 160) ? 4'd3 :
           (dbg_hcnt < 200) ? 4'd4 : (dbg_hcnt < 240) ? 4'd5 :
           (dbg_hcnt < 280) ? 4'd6 : 4'd7;
    p1_flag_green <= s_flags[4'd7 - fidx];
  end

  // --- pipeline stage 2: character resolve + font lookup ---
  reg        p2_font_pixel;
  reg        p2_in_flag_row;
  reg        p2_flag_green;

  always @(posedge clk_sys) begin
    logic [4:0] lch;
    logic [4:0] cch;
    logic [3:0] nib;
    logic [2:0] fy;
    logic [3:0] frow;

    // label character decode
    lch = 5'd31;
    case ({p1_hex_row, p1_char_col})
      {4'd0,4'd0}: lch=5'd16; {4'd0,4'd1}: lch=5'd17; {4'd0,4'd2}: lch=5'd18; {4'd0,4'd3}: lch=5'd16;
      {4'd1,4'd0}: lch=5'd19; {4'd1,4'd1}: lch=5'd20; {4'd1,4'd2}: lch=5'd21; {4'd1,4'd3}: lch=5'd20;
      {4'd2,4'd0}: lch=5'd22; {4'd2,4'd1}: lch=5'd23; {4'd2,4'd2}: lch=5'd26; {4'd2,4'd3}: lch=5'd0;
      {4'd3,4'd0}: lch=5'd22; {4'd3,4'd1}: lch=5'd23; {4'd3,4'd2}: lch=5'd26; {4'd3,4'd3}: lch=5'd1;
      {4'd4,4'd0}: lch=5'd20; {4'd4,4'd1}: lch=5'd21; {4'd4,4'd2}: lch=5'd25; {4'd4,4'd3}: lch=5'd16;
      {4'd5,4'd0}: lch=5'd20; {4'd5,4'd1}: lch=5'd21; {4'd5,4'd2}: lch=5'd12; {4'd5,4'd3}: lch=5'd16;
      {4'd6,4'd0}: lch=5'd20; {4'd6,4'd1}: lch=5'd21; {4'd6,4'd2}: lch=5'd24; {4'd6,4'd3}: lch=5'd22;
      {4'd7,4'd0}: lch=5'd22; {4'd7,4'd1}: lch=5'd18; {4'd7,4'd2}: lch=5'd20; {4'd7,4'd3}: lch=5'd19;
      {4'd8,4'd0}: lch=5'd15; {4'd8,4'd1}: lch=5'd18; {4'd8,4'd2}: lch=5'd26; {4'd8,4'd3}: lch=5'd27;
      default: lch = 5'd31;
    endcase

    nib = (p1_char_col == 4'd5) ? p1_hex_val[15:12] :
          (p1_char_col == 4'd6) ? p1_hex_val[11:8] :
          (p1_char_col == 4'd7) ? p1_hex_val[7:4] :
          p1_hex_val[3:0];

    cch = (p1_char_col <= 4'd3) ? lch :
          (p1_char_col == 4'd4) ? 5'd31 : {1'b0, nib};

    fy = p1_char_y[3:1];

    frow = 4'b0000;
    case ({cch, fy})
      {5'd0,3'd0}: frow=4'b0110; {5'd0,3'd1}: frow=4'b1001; {5'd0,3'd2}: frow=4'b1011;
      {5'd0,3'd3}: frow=4'b1101; {5'd0,3'd4}: frow=4'b1001; {5'd0,3'd5}: frow=4'b1001;
      {5'd0,3'd6}: frow=4'b0110;
      {5'd1,3'd0}: frow=4'b0010; {5'd1,3'd1}: frow=4'b0110; {5'd1,3'd2}: frow=4'b0010;
      {5'd1,3'd3}: frow=4'b0010; {5'd1,3'd4}: frow=4'b0010; {5'd1,3'd5}: frow=4'b0010;
      {5'd1,3'd6}: frow=4'b0111;
      {5'd2,3'd0}: frow=4'b0110; {5'd2,3'd1}: frow=4'b1001; {5'd2,3'd2}: frow=4'b0001;
      {5'd2,3'd3}: frow=4'b0010; {5'd2,3'd4}: frow=4'b0100; {5'd2,3'd5}: frow=4'b1000;
      {5'd2,3'd6}: frow=4'b1111;
      {5'd3,3'd0}: frow=4'b1110; {5'd3,3'd1}: frow=4'b0001; {5'd3,3'd2}: frow=4'b0001;
      {5'd3,3'd3}: frow=4'b0110; {5'd3,3'd4}: frow=4'b0001; {5'd3,3'd5}: frow=4'b0001;
      {5'd3,3'd6}: frow=4'b1110;
      {5'd4,3'd0}: frow=4'b1001; {5'd4,3'd1}: frow=4'b1001; {5'd4,3'd2}: frow=4'b1001;
      {5'd4,3'd3}: frow=4'b1111; {5'd4,3'd4}: frow=4'b0001; {5'd4,3'd5}: frow=4'b0001;
      {5'd4,3'd6}: frow=4'b0001;
      {5'd5,3'd0}: frow=4'b1111; {5'd5,3'd1}: frow=4'b1000; {5'd5,3'd2}: frow=4'b1110;
      {5'd5,3'd3}: frow=4'b0001; {5'd5,3'd4}: frow=4'b0001; {5'd5,3'd5}: frow=4'b1001;
      {5'd5,3'd6}: frow=4'b0110;
      {5'd6,3'd0}: frow=4'b0110; {5'd6,3'd1}: frow=4'b1000; {5'd6,3'd2}: frow=4'b1000;
      {5'd6,3'd3}: frow=4'b1110; {5'd6,3'd4}: frow=4'b1001; {5'd6,3'd5}: frow=4'b1001;
      {5'd6,3'd6}: frow=4'b0110;
      {5'd7,3'd0}: frow=4'b1111; {5'd7,3'd1}: frow=4'b0001; {5'd7,3'd2}: frow=4'b0010;
      {5'd7,3'd3}: frow=4'b0010; {5'd7,3'd4}: frow=4'b0100; {5'd7,3'd5}: frow=4'b0100;
      {5'd7,3'd6}: frow=4'b0100;
      {5'd8,3'd0}: frow=4'b0110; {5'd8,3'd1}: frow=4'b1001; {5'd8,3'd2}: frow=4'b1001;
      {5'd8,3'd3}: frow=4'b0110; {5'd8,3'd4}: frow=4'b1001; {5'd8,3'd5}: frow=4'b1001;
      {5'd8,3'd6}: frow=4'b0110;
      {5'd9,3'd0}: frow=4'b0110; {5'd9,3'd1}: frow=4'b1001; {5'd9,3'd2}: frow=4'b1001;
      {5'd9,3'd3}: frow=4'b0111; {5'd9,3'd4}: frow=4'b0001; {5'd9,3'd5}: frow=4'b0001;
      {5'd9,3'd6}: frow=4'b0110;
      {5'd10,3'd0}: frow=4'b0110; {5'd10,3'd1}: frow=4'b1001; {5'd10,3'd2}: frow=4'b1001;
      {5'd10,3'd3}: frow=4'b1111; {5'd10,3'd4}: frow=4'b1001; {5'd10,3'd5}: frow=4'b1001;
      {5'd10,3'd6}: frow=4'b1001;
      {5'd11,3'd0}: frow=4'b1110; {5'd11,3'd1}: frow=4'b1001; {5'd11,3'd2}: frow=4'b1001;
      {5'd11,3'd3}: frow=4'b1110; {5'd11,3'd4}: frow=4'b1001; {5'd11,3'd5}: frow=4'b1001;
      {5'd11,3'd6}: frow=4'b1110;
      {5'd12,3'd0}: frow=4'b0110; {5'd12,3'd1}: frow=4'b1001; {5'd12,3'd2}: frow=4'b1000;
      {5'd12,3'd3}: frow=4'b1000; {5'd12,3'd4}: frow=4'b1000; {5'd12,3'd5}: frow=4'b1001;
      {5'd12,3'd6}: frow=4'b0110;
      {5'd13,3'd0}: frow=4'b1110; {5'd13,3'd1}: frow=4'b1001; {5'd13,3'd2}: frow=4'b1001;
      {5'd13,3'd3}: frow=4'b1001; {5'd13,3'd4}: frow=4'b1001; {5'd13,3'd5}: frow=4'b1001;
      {5'd13,3'd6}: frow=4'b1110;
      {5'd14,3'd0}: frow=4'b1111; {5'd14,3'd1}: frow=4'b1000; {5'd14,3'd2}: frow=4'b1000;
      {5'd14,3'd3}: frow=4'b1110; {5'd14,3'd4}: frow=4'b1000; {5'd14,3'd5}: frow=4'b1000;
      {5'd14,3'd6}: frow=4'b1111;
      {5'd15,3'd0}: frow=4'b1111; {5'd15,3'd1}: frow=4'b1000; {5'd15,3'd2}: frow=4'b1000;
      {5'd15,3'd3}: frow=4'b1110; {5'd15,3'd4}: frow=4'b1000; {5'd15,3'd5}: frow=4'b1000;
      {5'd15,3'd6}: frow=4'b1000;
      {5'd16,3'd0}: frow=4'b1111; {5'd16,3'd1}: frow=4'b0110; {5'd16,3'd2}: frow=4'b0110;
      {5'd16,3'd3}: frow=4'b0110; {5'd16,3'd4}: frow=4'b0110; {5'd16,3'd5}: frow=4'b0110;
      {5'd16,3'd6}: frow=4'b0110;
      {5'd17,3'd0}: frow=4'b1111; {5'd17,3'd1}: frow=4'b1000; {5'd17,3'd2}: frow=4'b1000;
      {5'd17,3'd3}: frow=4'b1110; {5'd17,3'd4}: frow=4'b1000; {5'd17,3'd5}: frow=4'b1000;
      {5'd17,3'd6}: frow=4'b1111;
      {5'd18,3'd0}: frow=4'b0110; {5'd18,3'd1}: frow=4'b1001; {5'd18,3'd2}: frow=4'b1000;
      {5'd18,3'd3}: frow=4'b0110; {5'd18,3'd4}: frow=4'b0001; {5'd18,3'd5}: frow=4'b1001;
      {5'd18,3'd6}: frow=4'b0110;
      {5'd19,3'd0}: frow=4'b1110; {5'd19,3'd1}: frow=4'b1001; {5'd19,3'd2}: frow=4'b1001;
      {5'd19,3'd3}: frow=4'b1110; {5'd19,3'd4}: frow=4'b1000; {5'd19,3'd5}: frow=4'b1000;
      {5'd19,3'd6}: frow=4'b1000;
      {5'd20,3'd0}: frow=4'b1110; {5'd20,3'd1}: frow=4'b1001; {5'd20,3'd2}: frow=4'b1001;
      {5'd20,3'd3}: frow=4'b1001; {5'd20,3'd4}: frow=4'b1001; {5'd20,3'd5}: frow=4'b1001;
      {5'd20,3'd6}: frow=4'b1110;
      {5'd21,3'd0}: frow=4'b1000; {5'd21,3'd1}: frow=4'b1000; {5'd21,3'd2}: frow=4'b1000;
      {5'd21,3'd3}: frow=4'b1000; {5'd21,3'd4}: frow=4'b1000; {5'd21,3'd5}: frow=4'b1000;
      {5'd21,3'd6}: frow=4'b1111;
      {5'd22,3'd0}: frow=4'b1110; {5'd22,3'd1}: frow=4'b1001; {5'd22,3'd2}: frow=4'b1001;
      {5'd22,3'd3}: frow=4'b1110; {5'd22,3'd4}: frow=4'b1010; {5'd22,3'd5}: frow=4'b1001;
      {5'd22,3'd6}: frow=4'b1001;
      {5'd23,3'd0}: frow=4'b0110; {5'd23,3'd1}: frow=4'b1001; {5'd23,3'd2}: frow=4'b1001;
      {5'd23,3'd3}: frow=4'b1001; {5'd23,3'd4}: frow=4'b1001; {5'd23,3'd5}: frow=4'b1001;
      {5'd23,3'd6}: frow=4'b0110;
      {5'd24,3'd0}: frow=4'b1001; {5'd24,3'd1}: frow=4'b1001; {5'd24,3'd2}: frow=4'b1001;
      {5'd24,3'd3}: frow=4'b1001; {5'd24,3'd4}: frow=4'b1011; {5'd24,3'd5}: frow=4'b1101;
      {5'd24,3'd6}: frow=4'b1001;
      {5'd25,3'd0}: frow=4'b1110; {5'd25,3'd1}: frow=4'b1001; {5'd25,3'd2}: frow=4'b1001;
      {5'd25,3'd3}: frow=4'b1110; {5'd25,3'd4}: frow=4'b1001; {5'd25,3'd5}: frow=4'b1001;
      {5'd25,3'd6}: frow=4'b1110;
      {5'd26,3'd0}: frow=4'b1001; {5'd26,3'd1}: frow=4'b1111; {5'd26,3'd2}: frow=4'b1111;
      {5'd26,3'd3}: frow=4'b1001; {5'd26,3'd4}: frow=4'b1001; {5'd26,3'd5}: frow=4'b1001;
      {5'd26,3'd6}: frow=4'b1001;
      {5'd27,3'd0}: frow=4'b0110; {5'd27,3'd1}: frow=4'b1001; {5'd27,3'd2}: frow=4'b1001;
      {5'd27,3'd3}: frow=4'b1001; {5'd27,3'd4}: frow=4'b1011; {5'd27,3'd5}: frow=4'b0110;
      {5'd27,3'd6}: frow=4'b0001;
      default: frow = 4'b0000;
    endcase

    p2_font_pixel <= p1_in_char_area && !p1_px_gap && frow[2'd3 - p1_font_x];
    p2_in_flag_row <= p1_in_flag_row;
    p2_flag_green <= p1_flag_green;
  end

  // --- pipeline stage 3: RGB output ---
  reg [23:0] p3_overlay_rgb;
  always @(posedge clk_sys) begin
    if (p2_in_flag_row)
      p3_overlay_rgb <= p2_flag_green ? 24'h00CC00 : 24'hCC0000;
    else if (p2_font_pixel)
      p3_overlay_rgb <= 24'hCCCC00;
    else
      p3_overlay_rgb <= 24'h000000;
  end

  wire [23:0] core_rgb = {r5, r5[4:2], g5, g5[4:2], b5, b5[4:2]};
  wire [23:0] vid_rgb = status[6] ? p3_overlay_rgb : core_rgb;

  arcade_video #(.WIDTH(320), .DW(24)) arcade_video (
    .*,
    .clk_video(clk_sys),
    .ce_pix(ce_pix),
    .RGB_in(vid_rgb),
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

  // heartbeat: LED_USER toggles on vblank so "LED blinks = core alive + video
  // timing running" vs "LED dark = CPU/PLL dead". LED_DISK[0] = mrom_rd
  // activity (main CPU fetching ROM = CPU alive and executing)
  reg led_vbl_toggle;
  reg led_mrom_saw;
  always @(posedge clk_sys) begin
    if (vbl & ~led_vbl_toggle) led_vbl_toggle <= 1'b1;
    else if (~vbl) led_vbl_toggle <= 1'b0;
    if (mrom_rd) led_mrom_saw <= 1'b1;
  end
  assign LED_USER = {led_vbl_toggle, ioctl_download};
  assign LED_POWER = 2'b00;
  assign LED_DISK = {1'b0, led_mrom_saw};

endmodule
