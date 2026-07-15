// Full-system boot testbench: real game ROM, both CPUs, real VDP.
// Dumps a PPM of the scan-out every +DUMPEVERY frames (default 60) up to
// +FRAMES total, into +OUTDIR. Reports sub-CPU latch activity.
//
// Usage: +MAINROM=<hex> +GFXROM=<hex> +OUTDIR=<dir>
//        [+FRAMES=n] [+DUMPEVERY=n] [+GFXSIZE=bytes]

`timescale 1ns/1ps

module tb_system;

  localparam int GFX_AW = 22;
`ifdef PIXDIV12
  localparam int PIXDIV = 12;   // hardware value
`else
  localparam int PIXDIV = 16;   // sim-default (legacy parity baselines)
`endif
  localparam int WIDTH = 320, HEIGHT = 224;

  logic clk;
  logic rst_n;
  initial clk = 0;
  always #5 clk = ~clk;

  logic [7:0] gfxrom [0:(1<<GFX_AW)-1];
  logic [15:0] mainrom [0:262143];
  logic [7:0]  okirom [0:262143];
  int gfx_size;

  logic       hs, vs, de, ce_pix;
  logic [4:0] r5, g5, b5;
  logic              rom_req;
  logic [GFX_AW-1:0] rom_addr;
  logic [6:0]        rom_len;
  logic [15:0]       rom_data;
  logic              rom_valid;
  logic [7:0] dbg_subctl;
  logic       dbg_subrst;
  logic signed [15:0] audio;
  logic tb_compat60;
  initial begin
    tb_compat60 = 1'b0;                 // default = measured 261-line frame
    if ($test$plusargs("COMPAT60")) tb_compat60 = 1'b1;
  end
  longint audio_activity;
  logic signed [15:0] audio_d;
  always_ff @(posedge clk) begin
    audio_d <= audio;
    if (audio != audio_d) audio_activity <= audio_activity + 1;
  end

  // +SDRAM=1 routes all three ROM ports through hyprduel_sdram + the
  // behavioral sdram_model instead of the ideal servers below.
  int use_sdram;
  initial if (!$value$plusargs("SDRAM=%d", use_sdram)) use_sdram = 0;

  logic sdr_ready;
  wire rst_n_sys = rst_n && (use_sdram == 0 || sdr_ready);

  wire [15:0] mrom_data_mx  = (use_sdram != 0) ? ctl_mrom_data  : mrom_data;
  wire        mrom_valid_mx = (use_sdram != 0) ? ctl_mrom_valid : mrom_valid;
  wire [7:0]  oki_data_mx   = (use_sdram != 0) ? ctl_oki_data   : oki_data;
  wire        oki_ok_mx     = (use_sdram != 0) ? ctl_oki_ok     : oki_ok;
  wire [15:0] rom_data_mx   = (use_sdram != 0) ? ctl_gfx_data   : rom_data;
  wire        rom_valid_mx  = (use_sdram != 0) ? ctl_gfx_valid  : rom_valid;

  // shared3 SDRAM port wires
  wire        sr3_req, sr3_we;
  wire [16:0] sr3_addr;
  wire [15:0] sr3_wdata;
  wire  [1:0] sr3_be;
  logic [15:0] ctl_sr3_rdata;
  logic        ctl_sr3_ack;

  // shared3 behavioral server (non-SDRAM path)
  logic [15:0] shared3_mem [0:57343];
  logic        sr3_p1;
  logic [15:0] sr3_rdata_ideal;
  logic        sr3_ack_ideal;
  always_ff @(posedge clk) begin
    sr3_ack_ideal <= 1'b0;
    sr3_p1 <= sr3_req && !sr3_p1 && !sr3_ack_ideal;
    if (sr3_p1) begin
      if (sr3_we) begin
        if (sr3_be[1]) shared3_mem[sr3_addr][15:8] <= sr3_wdata[15:8];
        if (sr3_be[0]) shared3_mem[sr3_addr][7:0]  <= sr3_wdata[7:0];
      end else begin
        sr3_rdata_ideal <= shared3_mem[sr3_addr];
      end
      sr3_ack_ideal <= 1'b1;
    end
  end

  wire [15:0] sr3_rdata_mx = (use_sdram != 0) ? ctl_sr3_rdata : sr3_rdata_ideal;
  wire        sr3_ack_mx   = (use_sdram != 0) ? ctl_sr3_ack   : sr3_ack_ideal;

  // scripted inputs: +INPUTS=<file>, lines of "<frame> <p1p2hex> <systemhex>"
  // (active-low, applied at that frame and held until the next line)
  logic [15:0] inp_p1p2   = 16'hFFFF;
  logic [15:0] inp_system = 16'hFFFF;
  int          inp_fh, inp_frame;
  logic [15:0] inp_v1, inp_v2;
  bit          inp_pending;
  initial begin
    string inpath;
    inp_pending = 0;
    inp_fh = 0;
    if ($value$plusargs("INPUTS=%s", inpath)) begin
      inp_fh = $fopen(inpath, "r");
      if (inp_fh == 0) $fatal(1, "cannot open +INPUTS file");
      if ($fscanf(inp_fh, "%d %h %h", inp_frame, inp_v1, inp_v2) == 3)
        inp_pending = 1;
    end
  end
  hyprduel_sys #(.GFX_AW(GFX_AW), .P_PIXDIV(PIXDIV)) dut (
    .clk(clk), .rst_n(rst_n_sys),
    .o_hs(hs), .o_vs(vs), .o_de(de), .o_ce_pix(ce_pix),
    .o_hblank(), .o_vblank(),
    .o_r(r5), .o_g(g5), .o_b(b5),
    .o_audio(audio),
    .i_compat60(tb_compat60),
    .i_p1p2(inp_p1p2), .i_system(inp_system),
    .i_dsw(16'hFFBF), .i_service(16'hFFFF),  // dsw bit6=0: demo sounds ON
    .o_mrom_rd(mrom_rd), .o_mrom_addr(mrom_addr),
    .i_mrom_data(mrom_data_mx), .i_mrom_valid(mrom_valid_mx),
    .o_oki_addr(oki_addr), .i_oki_data(oki_data_mx), .i_oki_ok(oki_ok_mx),
    .o_sr3_req(sr3_req), .o_sr3_we(sr3_we), .o_sr3_addr(sr3_addr),
    .o_sr3_wdata(sr3_wdata), .o_sr3_be(sr3_be),
    .i_sr3_rdata(sr3_rdata_mx), .i_sr3_ack(sr3_ack_mx),
    .o_rom_req(rom_req), .o_rom_addr(rom_addr), .o_rom_len(rom_len),
    .i_rom_data(rom_data_mx), .i_rom_valid(rom_valid_mx),
    .i_gfx_size(24'(gfx_size)),
    .dbg_subctl(dbg_subctl), .dbg_sub_in_reset(dbg_subrst),
    /* verilator lint_off PINCONNECTEMPTY */
    .dbg_vdp_write(), .dbg_line_start(),
    .dbg_rnd_done(), .dbg_lb_nonzero(),
    .dbg_cpu_past_vectors(), .dbg_vdp_cs_seen(),
    .dbg_mrom_word0(), .dbg_mrom_word1(),
    .dbg_mrom_word2(), .dbg_mrom_word3()
    /* verilator lint_on PINCONNECTEMPTY */
  );

  // SDRAM controller + behavioral model (active when +SDRAM=1)
  logic [15:0] ctl_mrom_data;
  logic        ctl_mrom_valid;
  logic [7:0]  ctl_oki_data;
  logic [15:0] ctl_gfx_data;
  logic        ctl_oki_ok, ctl_gfx_valid;
  wire  [12:0] sdr_a;
  wire  [1:0]  sdr_ba;
  wire  [15:0] sdr_dq;
  wire         sdr_dqml, sdr_dqmh, sdr_ncs, sdr_nras, sdr_ncas, sdr_nwe, sdr_cke;

  hyprduel_sdram #(.P_SHORT_INIT(1'b1)) u_sdr (
    .clk(clk), .rst_n(rst_n), .o_ready(sdr_ready),
    .i_gfx_req(rom_req && use_sdram != 0),
    .i_gfx_addr(rom_addr), .i_gfx_len(rom_len),
    .o_gfx_data(ctl_gfx_data), .o_gfx_valid(ctl_gfx_valid),
    .i_mrom_rd(mrom_rd && use_sdram != 0), .i_mrom_addr(mrom_addr),
    .o_mrom_data(ctl_mrom_data), .o_mrom_valid(ctl_mrom_valid),
    .i_oki_addr(oki_addr),
    .o_oki_data(ctl_oki_data), .o_oki_ok(ctl_oki_ok),
    .i_sr3_req(sr3_req && use_sdram != 0),
    .i_sr3_we(sr3_we), .i_sr3_addr(sr3_addr),
    .i_sr3_wdata(sr3_wdata), .i_sr3_be(sr3_be),
    .o_sr3_rdata(ctl_sr3_rdata), .o_sr3_ack(ctl_sr3_ack),
    .i_dl_wr(1'b0), .i_dl_addr('0), .i_dl_data('0), .o_dl_busy(), .i_dl_active(1'b0),
    .SDRAM_A(sdr_a), .SDRAM_BA(sdr_ba), .SDRAM_DQ(sdr_dq),
    .SDRAM_DQML(sdr_dqml), .SDRAM_DQMH(sdr_dqmh),
    .SDRAM_nCS(sdr_ncs), .SDRAM_nRAS(sdr_nras), .SDRAM_nCAS(sdr_ncas),
    .SDRAM_nWE(sdr_nwe), .SDRAM_CKE(sdr_cke),
    /* verilator lint_off PINCONNECTEMPTY */
    .dbg_dl_saw(), .dbg_dl_byte0(), .dbg_dl_byte1(), .dbg_dl_count(),
    .dbg_selftest(), .dbg_postdl(),
    .dbg_dl_written(), .dbg_dl_dropped(), .dbg_fsm_info()
    /* verilator lint_on PINCONNECTEMPTY */
  );

  sdram_model u_sdr_model (
    .clk(clk), .A(sdr_a), .BA(sdr_ba), .DQ(sdr_dq),
    // tied LOW like the real MiSTer SDRAM board (no byte masking exists)
    .DQML(1'b0), .DQMH(1'b0),
    .nCS(sdr_ncs), .nRAS(sdr_nras), .nCAS(sdr_ncas), .nWE(sdr_nwe),
    .CKE(sdr_cke)
  );

  // main ROM server: 2-cycle latency (SDRAM-ish)
  logic        mrom_rd, mrom_valid;
  logic [17:0] mrom_addr;
  logic [15:0] mrom_data;
  logic        mrom_p1;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      mrom_valid <= 0; mrom_p1 <= 0;
    end else begin
      mrom_valid <= 0;
      mrom_p1 <= mrom_rd;
      if (mrom_p1) begin
        mrom_data  <= mainrom[mrom_addr];
        mrom_valid <= 1;
      end
    end
  end

  // OKI ROM server: registered read with ok tracking
  logic [17:0] oki_addr, oki_addr_d;
  logic [7:0]  oki_data;
  logic        oki_ok;
  always_ff @(posedge clk) begin
    oki_data   <= okirom[oki_addr];
    oki_addr_d <= oki_addr;
    oki_ok     <= (oki_addr_d == oki_addr);
  end

  // GFX ROM stream server
  logic [GFX_AW-1:0] srv_addr;
  logic [6:0]        srv_left;
  int                srv_wait;
  logic              srv_active;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      srv_active <= 1'b0;
      rom_valid  <= 1'b0;
    end else begin
      rom_valid <= 1'b0;
      if (!srv_active) begin
        if (rom_req) begin
          srv_active <= 1'b1;
          srv_addr   <= rom_addr;
          srv_left   <= rom_len;
          srv_wait   <= 2;
        end
      end else if (srv_wait > 0) srv_wait <= srv_wait - 1;
      else if (!srv_addr[0] && !srv_left[0]) begin
        // word-mode: 2 bytes per valid, even byte in [15:8]
        rom_valid <= 1'b1;
        rom_data  <= {gfxrom[srv_addr], gfxrom[srv_addr + 1]};
        srv_addr  <= srv_addr + 2'd2;
        if (srv_left == 7'd2) srv_active <= 1'b0;
        else srv_left <= srv_left - 7'd2;
      end else begin
        // byte-mode (blitter): one byte per valid in [7:0]
        rom_valid <= 1'b1;
        rom_data  <= {8'd0, gfxrom[srv_addr]};
        srv_addr  <= srv_addr + 1'b1;
        if (srv_left == 7'd1) srv_active <= 1'b0;
        else srv_left <= srv_left - 7'd1;
      end
    end
  end

  // frame capture
  logic [23:0] frame [0:HEIGHT-1][0:WIDTH-1];
  int cap_x, cap_y, frames_seen;
  logic de_d, vs_d;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cap_x <= 0; cap_y <= 0; frames_seen <= 0; de_d <= 0; vs_d <= 0;
    end else if (ce_pix) begin
      de_d <= de;
      vs_d <= vs;
      if (vs && !vs_d) begin
        cap_x <= 0; cap_y <= 0;
        frames_seen <= frames_seen + 1;
      end else if (de) begin
        if (cap_y < HEIGHT && cap_x < WIDTH)
          frame[cap_y][cap_x] <= {r5, r5[4:2], g5, g5[4:2], b5, b5[4:2]};
        cap_x <= cap_x + 1;
      end else if (de_d) begin
        cap_x <= 0; cap_y <= cap_y + 1;
      end
    end
  end

  // sub-CPU latch activity log (first few events)
  logic [7:0] subctl_d;
  int subctl_events;
  always_ff @(posedge clk) begin
    subctl_d <= dbg_subctl;
    if (dbg_subctl != subctl_d && subctl_events < 20) begin
      subctl_events <= subctl_events + 1;
      $display("t=%0t subctl write: %02x (sub_in_reset=%0d) frame=%0d",
               $time, dbg_subctl, dbg_subrst, frames_seen);
    end
  end

  // scripted-input playback (declarations near the dut instantiation)
  always @(posedge clk) begin
    if (inp_pending && frames_seen >= inp_frame) begin
      inp_p1p2   <= inp_v1;
      inp_system <= inp_v2;
      $display("INPUT f=%0d p1p2=%04x system=%04x", frames_seen, inp_v1, inp_v2);
      if ($fscanf(inp_fh, "%d %h %h", inp_frame, inp_v1, inp_v2) != 3)
        inp_pending <= 0;
    end
  end

  // main CPU bus trace: first N completed cycles
  logic m_asn_d;
  int bus_traced, loop_traced, iack_traced, latch_traced, sub_traced, vdp_traced;
  always_ff @(posedge clk) begin
    m_asn_d <= dut.m_asn;
    if (!dut.m_asn && m_asn_d) begin
      // all writes (first 60), and 20 consecutive cycles after frame 1
      if (!dut.m_rw && bus_traced < 60) begin
        bus_traced <= bus_traced + 1;
        $display("WR a=%06x wd=%04x f=%0d", {dut.m_a, 1'b0}, dut.m_dout, frames_seen);
      end
      if (dut.m_iack && iack_traced < 10) begin
        iack_traced <= iack_traced + 1;
        $display("IACK main level=%0d f=%0d", dut.m_a[3:1], frames_seen);
      end
      if (!dut.m_rw && {dut.m_a, 1'b0} == 24'h800000 && latch_traced < 20) begin
        latch_traced <= latch_traced + 1;
        $display("LATCH wd=%02x f=%0d", dut.m_dout[7:0], frames_seen);
      end
      if ({dut.m_a, 1'b0} >= 24'h460000 && {dut.m_a, 1'b0} < 24'h460010
          && vdp_traced < 24) begin
        vdp_traced <= vdp_traced + 1;
        $display("WIN %s a=%06x f=%0d", dut.m_rw ? "R" : "W",
                 {dut.m_a, 1'b0}, frames_seen);
      end
      if (!dut.m_rw && {dut.m_a, 1'b0} == 24'h4788AA && vdp_traced < 40) begin
        $display("BANK wd=%04x f=%0d", dut.m_dout, frames_seen);
      end
    end
  end

  // raster write log (matches MAME's tap_raster.lua format)
  int raster_fh, kick_fh;
  initial begin
    if ($test$plusargs("RASTERLOG")) begin
      raster_fh = $fopen("build/raster_writes_sim.csv", "w");
      $fwrite(raster_fh, "frame,vpos,hpos,addr,data\n");
      kick_fh = $fopen("build/raster_kicks_sim.csv", "w");
      $fwrite(kick_fh, "frame,line,vpos,hpos,sy0,sx0,sy1,sx1,sy2,sx2\n");
    end else begin raster_fh = 0; kick_fh = 0; end
  end
  // renderer kick probe: the line number and the live scroll registers
  // at the moment the render pass for that line starts (top-lines
  // delayed-parallax investigation: compare against the write log)
  always_ff @(posedge clk) begin
    if (kick_fh != 0 && dut.u_vdp.rnd_start)
      $fwrite(kick_fh, "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
              frames_seen, dut.u_vdp.rnd_line,
              dut.u_vdp.vcnt, dut.u_vdp.hcnt,
              dut.u_vdp.r_scroll[0], dut.u_vdp.r_scroll[1],
              dut.u_vdp.r_scroll[2], dut.u_vdp.r_scroll[3],
              dut.u_vdp.r_scroll[4], dut.u_vdp.r_scroll[5]);
  end
  always_ff @(posedge clk) begin
    if (raster_fh != 0 && !dut.m_asn && m_asn_d && !dut.m_rw) begin
      logic [23:0] wa;
      wa = {dut.m_a, 1'b0};
      if ((wa >= 24'h478800 && wa <= 24'h4788ff) ||
          (wa >= 24'h479700 && wa <= 24'h47971f))
        $fwrite(raster_fh, "%0d,%0d,%0d,%06x,%04x\n",
                frames_seen, dut.u_vdp.vcnt, dut.u_vdp.hcnt,
                wa, dut.m_dout);
    end
  end

  // sound-path probes
  longint ymwr_cnt, s_iack1_cnt, s_iack2_cnt, ymirq_seen;
  logic [7:0] last_ym_a0_0, last_ym_a0_1;
  // extended diagnostics (docs/audio_bug_ym_irq_storm.md step 1)
  int         ym_hist [256];       // data-write count per register
  logic [7:0] ym_lastv[256];       // last value written per register
  int         ym_ffirst[256];      // frame of first write per register (-1 = never)
  logic [7:0] cur_reg;
  bit         r14_vals[256];       // distinct values ever written to reg 0x14
  int         iack1_edges, iack2_edges, irq_falls, st_reads;
  logic [23:0] okiw_log [40];
  int          oki_mism, oki_lat, oki_maxlat;
  logic        oki_ok_d;
  logic [23:0] okir_log [20];
  int          okiw_n, okir_n;
  longint      oki_nz;
  int          oki_first;
  initial oki_first = -1;
  int         rb_cyc, rb_max, rb_over, rb_over_frame, rb_late;
  int         rb_late_vis, rb_late_maxh, rb_late_chg, late_fh;
  int         fg_pred_exact, fg_pred_miss, fg_pred_maxerr;
  int         fg_fh;
  int         topline_mm;   // registered topline select vs live decode
  logic [8:0] lk_nv;
  logic [31:0] lk_snap [2];      // [0]=line0, [1]=line2 sy0/sy2 at h0
  logic       lk_changed [2];
  initial begin
    string lpath;
    late_fh = 0;
    if ($value$plusargs("LATELOG=%s", lpath)) begin
      late_fh = $fopen(lpath, "w");
      $fwrite(late_fh, "frame,line,hcnt,sy_changed\n");
    end
    fg_fh = 0;
    if ($value$plusargs("FGLOG=%s", lpath)) begin
      fg_fh = $fopen(lpath, "w");
      $fwrite(fg_fh, "frame,reg,written,pred,err\n");
    end
  end
  int         st_flagA, st_flagB, st_busy;
  logic [7:0] st_last[16];         // last 16 status values returned
  int         st_lidx;
  logic       s_iack_d, ym_irq_d;
  initial for (int i = 0; i < 256; i++) ym_ffirst[i] = -1;
  always_ff @(posedge clk) begin
    if (!dut.ym_cs_n && !dut.ym_wr_n) begin
      ymwr_cnt <= ymwr_cnt + 1;
      if (!dut.ym_a0) begin
        last_ym_a0_0 <= dut.ym_din;
        cur_reg      <= dut.ym_din;
      end else begin
        last_ym_a0_1 <= dut.ym_din;
        ym_hist[cur_reg] <= ym_hist[cur_reg] + 1;
        ym_lastv[cur_reg] <= dut.ym_din;
        if (ym_ffirst[cur_reg] < 0) ym_ffirst[cur_reg] <= frames_seen;
        if (cur_reg == 8'h14) r14_vals[dut.ym_din] = 1'b1;
      end
    end
    if (!dut.ym_cs_n && dut.ym_wr_n) begin  // status read access
      st_reads <= st_reads + 1;
      st_last[st_lidx & 15] <= dut.ym_dout;
      st_lidx <= st_lidx + 1;
      if (dut.ym_dout[0]) st_flagA <= st_flagA + 1;
      if (dut.ym_dout[1]) st_flagB <= st_flagB + 1;
      if (dut.ym_dout[7]) st_busy  <= st_busy  + 1;
    end
    // OKI diagnostics: command writes, status reads, output activity
    if (!dut.oki_wrn) begin
      if (okiw_n < 40) begin
        okiw_log[okiw_n] <= {16'(frames_seen), dut.oki_din};
        okiw_n <= okiw_n + 1;
      end
    end
    if (dut.sbst == 1 && dut.s_sel_snd && dut.s_rw && okir_n < 20) begin
      okir_log[okir_n] <= {16'(frames_seen), dut.oki_dout};
      okir_n <= okir_n + 1;
    end
    // SDRAM OKI client honesty checks
    if (use_sdram != 0) begin
      if (ctl_oki_ok && ctl_oki_data != okirom[oki_addr]) oki_mism <= oki_mism + 1;
      oki_ok_d <= ctl_oki_ok;
      if (!ctl_oki_ok) begin
        oki_lat <= oki_lat + 1;
        if (oki_lat + 1 > oki_maxlat) oki_maxlat <= oki_lat + 1;
      end else
        oki_lat <= 0;
    end
    if (dut.oki_snd != 0) begin
      oki_nz <= oki_nz + 1;
      if (oki_first < 0) oki_first <= frames_seen;
    end
    s_iack_d <= dut.s_iack;
    ym_irq_d <= dut.ym_irq_n;
    if (dut.s_iack && !s_iack_d && dut.s_a[3:1] == 3'd1) iack1_edges <= iack1_edges + 1;
    if (dut.s_iack && !s_iack_d && dut.s_a[3:1] == 3'd2) iack2_edges <= iack2_edges + 1;
    if (!dut.ym_irq_n && ym_irq_d) irq_falls <= irq_falls + 1;
    if (dut.s_iack && dut.s_a[3:1] == 3'd1) s_iack1_cnt <= s_iack1_cnt + 1;
    if (dut.s_iack && dut.s_a[3:1] == 3'd2) s_iack2_cnt <= s_iack2_cnt + 1;
    if (!dut.ym_irq_n) ymirq_seen <= ymirq_seen + 1;
    // renderer line-budget probe (budget = 424 * PIXDIV clocks per line)
    // visible-artefact counter: a line completing while its own scan-out
    // row is already displaying showed background on its left portion
    if (dut.u_vdp.rnd_done && dut.u_vdp.vcnt == {1'b0, dut.u_vdp.rnd_line} &&
        dut.u_vdp.hcnt > 9'd8)
      rb_late <= rb_late + 1;
    // late-completion characterisation: resolve is the final 320-clk
    // monotonic pass at 1 px/clk, beam consumes 1 px / 12 clk, so a
    // completion at hcnt >= 28 means the beam already read pixels the
    // resolver had not written (stale bank content on the left edge).
    // Track whether sy0/sy2 changed between h0 and h120 of the kick line
    // to evaluate a conditional (ramp-active-only) late kick.
    if (dut.u_vdp.ce_pix && dut.u_vdp.hcnt == 9'd0) begin
      lk_nv = (dut.u_vdp.vcnt == dut.u_vdp.vlast) ? 9'd0 : dut.u_vdp.vcnt + 9'd1;
      if (lk_nv == 9'd0 || lk_nv == 9'd2)
        lk_snap[lk_nv[1]] <= {dut.u_vdp.r_scroll[0], dut.u_vdp.r_scroll[4]};
    end
    if (dut.u_vdp.ce_pix && dut.u_vdp.hcnt == 9'd120) begin
      lk_nv = (dut.u_vdp.vcnt == dut.u_vdp.vlast) ? 9'd0 : dut.u_vdp.vcnt + 9'd1;
      if (lk_nv == 9'd0 || lk_nv == 9'd2)
        lk_changed[lk_nv[1]] <=
          lk_snap[lk_nv[1]] != {dut.u_vdp.r_scroll[0], dut.u_vdp.r_scroll[4]};
    end
    // frame-global scroll prediction accuracy: at each fg write during
    // line 0, the value should equal what pred_fg gave lines 0/1.
    if (dut.u_vdp.reg_w && dut.u_vdp.vcnt == 9'd0 &&
        (dut.u_vdp.i_addr & 19'h7FFFE) inside {19'h78872, 19'h78874, 19'h78876, 19'h7887A}) begin
      automatic logic [2:0] fgi = 3'((dut.u_vdp.i_addr - 19'h78870) >> 1);
      automatic logic [15:0] newv =
        {dut.u_vdp.i_be[1] ? dut.u_vdp.i_wdata[15:8] : dut.u_vdp.r_scroll[fgi][15:8],
         dut.u_vdp.i_be[0] ? dut.u_vdp.i_wdata[7:0]  : dut.u_vdp.r_scroll[fgi][7:0]};
      automatic int err;
      err = int'(newv) - int'(dut.u_vdp.pred_fg[fgi]);
      if (err > 32768) err -= 65536;
      if (err < -32768) err += 65536;
      if (fg_fh != 0)
        $fwrite(fg_fh, "%0d,%0d,%0d,%0d,%0d\n", frames_seen, fgi,
                newv, dut.u_vdp.pred_fg[fgi], err);
      if (err == 0) fg_pred_exact <= fg_pred_exact + 1;
      else begin
        fg_pred_miss <= fg_pred_miss + 1;
        if (err < 0) err = -err;
        if (err > fg_pred_maxerr) fg_pred_maxerr <= err;
      end
    end
    // registered topline select must equal the live decode whenever the
    // renderer is busy (the only time rs_scroll views are consumed)
    if (dut.u_vdp.rnd_busy &&
        (dut.u_vdp.rnd_topline !== (dut.u_vdp.rnd_line < 8'd2)))
      topline_mm <= topline_mm + 1;
    if (dut.u_vdp.rnd_done && dut.u_vdp.vcnt == {1'b0, dut.u_vdp.rnd_line} &&
        dut.u_vdp.hcnt > 9'd8) begin
      if (dut.u_vdp.hcnt >= 9'd28) rb_late_vis <= rb_late_vis + 1;
      if (32'(dut.u_vdp.hcnt) > rb_late_maxh) rb_late_maxh <= 32'(dut.u_vdp.hcnt);
      if (lk_changed[dut.u_vdp.rnd_line[1]]) rb_late_chg <= rb_late_chg + 1;
      if (late_fh != 0)
        $fwrite(late_fh, "%0d,%0d,%0d,%0d\n", frames_seen,
                dut.u_vdp.rnd_line, dut.u_vdp.hcnt,
                32'(lk_changed[dut.u_vdp.rnd_line[1]]));
    end
    if (dut.u_vdp.rnd_busy) rb_cyc <= rb_cyc + 1;
    else begin
      if (rb_cyc > rb_max) rb_max <= rb_cyc;
      if (rb_cyc > 424 * PIXDIV) begin
        rb_over <= rb_over + 1;
        rb_over_frame <= frames_seen;
      end
      rb_cyc <= 0;
    end
  end

  // audio capture: +AUDIODUMP=<path> writes raw s16le mono at sys/2048
  // (~52 kHz); convert with sim/mame/raw_to_wav.py.
  // +AUDIOSPLIT=<prefix> additionally writes <prefix>_ym.raw and
  // <prefix>_oki.raw (pre-mix component taps) for mix-balance work.
  int fh_audio, fh_ym, fh_oki;
  logic [10:0] adiv;
  initial begin
    string apath;
    fh_audio = 0; fh_ym = 0; fh_oki = 0;
    if ($value$plusargs("AUDIODUMP=%s", apath)) fh_audio = $fopen(apath, "wb");
    if ($value$plusargs("AUDIOSPLIT=%s", apath)) begin
      fh_ym  = $fopen({apath, "_ym.raw"}, "wb");
      fh_oki = $fopen({apath, "_oki.raw"}, "wb");
    end
  end
  logic signed [15:0] tap_ym, tap_oki;
  always_ff @(posedge clk) begin
    adiv <= adiv + 1'b1;
    tap_ym  <= 16'((18'(dut.ym_xl) + 18'(dut.ym_xr)) >>> 1);
    tap_oki <= {dut.oki_snd, 2'b00};
    if (fh_audio != 0 && adiv == 0)
      $fwrite(fh_audio, "%c%c", dut.o_audio[7:0], dut.o_audio[15:8]);
    if (fh_ym != 0 && adiv == 0)
      $fwrite(fh_ym, "%c%c", tap_ym[7:0], tap_ym[15:8]);
    if (fh_oki != 0 && adiv == 0)
      $fwrite(fh_oki, "%c%c", tap_oki[7:0], tap_oki[15:8]);
  end

  // sr3 arbiter contention counters
  longint sub_sr3_wait, main_sr3_wait, sub_sr3_grants, main_sr3_grants;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      sub_sr3_wait <= 0; main_sr3_wait <= 0;
      sub_sr3_grants <= 0; main_sr3_grants <= 0;
    end else begin
      if (dut.sbst == 2'b10 && !dut.sr3_s_ack) sub_sr3_wait <= sub_sr3_wait + 1;
      if (dut.mbst == 3'b011 && !dut.sr3_m_ack) main_sr3_wait <= main_sr3_wait + 1;
      if (dut.sr3_s_ack) sub_sr3_grants <= sub_sr3_grants + 1;
      if (dut.sr3_m_ack) main_sr3_grants <= main_sr3_grants + 1;
    end
  end

  // sub CPU activity trace + per-frame samplers
  logic s_asn_d;
  int samp_frame;
  initial if (!$value$plusargs("SAMPFRAME=%d", samp_frame)) samp_frame = 20;
  always_ff @(posedge clk) begin
    s_asn_d <= dut.s_asn;
    if (!dut.s_asn && s_asn_d) begin
      if (sub_traced < 25) begin
        sub_traced <= sub_traced + 1;
        $display("SUB %s a=%06x wd=%04x f=%0d", dut.s_rw ? "R" : "W",
                 {dut.s_a, 1'b0}, dut.s_dout, frames_seen);
      end
      if (frames_seen == samp_frame && sub_samp < 20) begin
        sub_samp <= sub_samp + 1;
        $display("SSAMP %s a=%06x wd=%04x", dut.s_rw ? "R" : "W",
                 {dut.s_a, 1'b0}, dut.s_dout);
      end
    end
    if (!dut.m_asn && m_asn_d && frames_seen == samp_frame && main_samp < 20) begin
      main_samp <= main_samp + 1;
      $display("MSAMP %s a=%06x wd=%04x", dut.m_rw ? "R" : "W",
               {dut.m_a, 1'b0}, dut.m_dout);
    end
    // one-shot frozen-bus dump: sub CPU stuck mid-cycle never produces AS edges
    if (frames_seen == samp_frame && !stuck_dumped) begin
      stuck_dumped <= 1'b1;
      $display("STUCK sub: asn=%0d rw=%0d a=%06x sbst=%0d s_req=%0d m_req=%0d grant_s=%0d ipl=%0d",
               dut.s_asn, dut.s_rw, {dut.s_a, 1'b0}, dut.sbst,
               dut.sr3_s_req, dut.sr3_m_req, dut.sr3_grant_s, dut.s_ipl);
    end
  end
  int sub_samp, main_samp;
  logic stuck_dumped;

  // renderer/GFX-stream wedge watchdog: if a render runs 4x the line
  // budget, snapshot the FSM and stream state (one-shot per wedge)
  int  wd_cyc;
  int  wd_shots;
  always_ff @(posedge clk) begin
    if (dut.u_vdp.rnd_busy) wd_cyc <= wd_cyc + 1;
    else wd_cyc <= 0;
    if (wd_cyc == 424 * PIXDIV * 4 && wd_shots < 8) begin
      wd_shots <= wd_shots + 1;
      $display("WEDGE f=%0d render st=%0d line=%0d romlen=%0d rx=%0d rx2=%0d scur=%0d wcur=%0d",
               frames_seen, dut.u_vdp.u_render.st, dut.u_vdp.u_render.line_r,
               dut.u_vdp.u_render.o_rom_len, dut.u_vdp.u_render.rx,
               dut.u_vdp.u_render.rx2, dut.u_vdp.u_render.scur,
               dut.u_vdp.u_render.wcur);
      $display("WEDGE arb gr=%0d gr_left=%0d rp_pend=%0d sdram gfx: pend=%0d left=%0d wmode=%0d bfcnt=%0d owner=%0d sdst=%0d",
               dut.u_vdp.gr, dut.u_vdp.gr_left, dut.u_vdp.rp_pend,
               u_sdr.gfx_pend, u_sdr.gfx_left, u_sdr.gfx_wmode,
               u_sdr.bf_cnt, u_sdr.owner, u_sdr.st);
    end
  end

  task automatic dump_state(input string outdir, input int n);
    int fh;
    $writememh($sformatf("%s/st%0d_vram0.hex", outdir, n), dut.u_vdp.u_vram0.mem);
    $writememh($sformatf("%s/st%0d_vram1.hex", outdir, n), dut.u_vdp.u_vram1.mem);
    $writememh($sformatf("%s/st%0d_vram2.hex", outdir, n), dut.u_vdp.u_vram2.mem);
    $writememh($sformatf("%s/st%0d_tiletable.hex", outdir, n), dut.u_vdp.u_tiletable.mem);
    $writememh($sformatf("%s/st%0d_palette.hex", outdir, n), dut.u_vdp.u_palette.mem);
    $writememh($sformatf("%s/st%0d_spriteram.hex", outdir, n), dut.u_vdp.u_spr_buf.mem);
    fh = $fopen($sformatf("%s/st%0d_regs.txt", outdir, n), "w");
    $fdisplay(fh, "sprite_count=0x%x", dut.u_vdp.r_spr_count);
    $fdisplay(fh, "sprite_priority=0x%x", dut.u_vdp.r_spr_pri);
    $fdisplay(fh, "sprite_yoffset=0x%x", dut.u_vdp.r_spr_yoff);
    $fdisplay(fh, "sprite_xoffset=0x%x", dut.u_vdp.r_spr_xoff);
    $fdisplay(fh, "sprite_color_code=0x%x", dut.u_vdp.r_spr_color);
    $fdisplay(fh, "layer_priority=0x%x", dut.u_vdp.r_layer_pri);
    $fdisplay(fh, "background_color=0x%x", dut.u_vdp.r_bg);
    $fdisplay(fh, "screen_yoffset=0x%x", dut.u_vdp.r_scr_yoff);
    $fdisplay(fh, "screen_xoffset=0x%x", dut.u_vdp.r_scr_xoff);
    $fdisplay(fh, "screen_ctrl=0x%x", dut.u_vdp.r_ctrl);
    for (int l = 0; l < 3; l++) begin
      $fdisplay(fh, "window_y%0d=0x%x", l, dut.u_vdp.r_window[l*2+0]);
      $fdisplay(fh, "window_x%0d=0x%x", l, dut.u_vdp.r_window[l*2+1]);
      $fdisplay(fh, "scroll_y%0d=0x%x", l, dut.u_vdp.r_scroll[l*2+0]);
      $fdisplay(fh, "scroll_x%0d=0x%x", l, dut.u_vdp.r_scroll[l*2+1]);
    end
    $fclose(fh);
    $display("state dumped at frame %0d", n);
  endtask

  task automatic dump_frame(input string outdir, input int n);
    int fh, x, y;
    fh = $fopen($sformatf("%s/boot_%04d.ppm", outdir, n), "w");
    if (fh == 0) $fatal(1, "cannot open dump");
    $fwrite(fh, "P3\n%0d %0d\n255\n", WIDTH, HEIGHT);
    for (y = 0; y < HEIGHT; y++) begin
      for (x = 0; x < WIDTH; x++)
        $fwrite(fh, "%0d %0d %0d ",
                frame[y][x][23:16], frame[y][x][15:8], frame[y][x][7:0]);
      $fwrite(fh, "\n");
    end
    $fclose(fh);
    $display("dumped frame %0d", n);
  endtask

  initial begin : run
    string gfxpath, outdir;
    int total_frames, dump_every, last_dumped;
    int dump_from, dump_to;

    begin
      string mrpath, okrpath;
      if ($value$plusargs("MAINROM=%s", mrpath)) $readmemh(mrpath, mainrom);
      else $fatal(1, "need +MAINROM=");
      if ($value$plusargs("OKIROM=%s", okrpath)) $readmemh(okrpath, okirom);
    end
    if (!$value$plusargs("GFXROM=%s", gfxpath)) $fatal(1, "need +GFXROM=");
    if (!$value$plusargs("OUTDIR=%s", outdir))  $fatal(1, "need +OUTDIR=");
    if (!$value$plusargs("FRAMES=%d", total_frames)) total_frames = 360;
    if (!$value$plusargs("DUMPEVERY=%d", dump_every)) dump_every = 60;
    // +DUMPFROM/+DUMPTO: additionally dump EVERY frame in [from, to]
    // (blink-constant measurement etc.)
    if (!$value$plusargs("DUMPFROM=%d", dump_from)) dump_from = -1;
    if (!$value$plusargs("DUMPTO=%d",   dump_to))   dump_to   = -1;
    if (!$value$plusargs("GFXSIZE=%d", gfx_size)) gfx_size = 1 << GFX_AW;

    $readmemh(gfxpath, gfxrom);

    if (use_sdram != 0) begin
      // populate the SDRAM model at the mister/README.md byte map;
      // even byte address = word[15:8] (68000 lane convention)
      for (int i = 0; i < 262144; i++) begin
        u_sdr_model.mem_b[2*i]     = mainrom[i][15:8];
        u_sdr_model.mem_b[2*i + 1] = mainrom[i][7:0];
      end
      for (int i = 0; i < gfx_size; i++)
        u_sdr_model.mem_b[32'h080000 + i] = gfxrom[i];
      for (int i = 0; i < 262144; i++)
        u_sdr_model.mem_b[32'h480000 + i] = okirom[i];
      $display("tb_system: SDRAM path enabled (controller + model)");
    end

    rst_n = 0;
    repeat (32) @(posedge clk);
    rst_n = 1;

    last_dumped = 0;
    while (frames_seen < total_frames) begin
      @(posedge clk);
      if (frames_seen >= last_dumped + dump_every ||
          (frames_seen > last_dumped &&
           frames_seen >= dump_from && frames_seen <= dump_to)) begin
        last_dumped = frames_seen;
        dump_frame(outdir, frames_seen);
        if (frames_seen == 510 || frames_seen == 750) dump_state(outdir, frames_seen);
      end
    end
    dump_frame(outdir, frames_seen);
    $display("tb_system: %0d frames simulated, audio transitions=%0d",
             frames_seen, audio_activity);
    $display("probes: ym_writes=%0d (last reg=%02x val=%02x) sub_iack1=%0d sub_iack2=%0d ym_irq_cycles=%0d",
             ymwr_cnt, last_ym_a0_0, last_ym_a0_1, s_iack1_cnt, s_iack2_cnt, ymirq_seen);
    $display("edges: iack1=%0d iack2=%0d irq_falls=%0d", iack1_edges, iack2_edges, irq_falls);
    $display("hwprobes: sack=%04x palw=%04x hshk=%04x subctl=%02x iack1=%02x",
             dut.dbg_sack_cnt, dut.dbg_palw, dut.dbg_hshk, dut.dbg_subctl, dut.dbg_iack1);
    $display("hwprobes2: wadr=%04x wcnt=%04x srrc=%04x",
             dut.dbg_wadr, dut.dbg_wcnt, dut.dbg_srrc);
    $display("hwprobes3: wda0=%04x wda1=%04x wda2=%04x wda3=%04x",
             dut.dbg_wda[0], dut.dbg_wda[1], dut.dbg_wda[2], dut.dbg_wda[3]);
    $display("hwprobes4: b3e_w0=%04x b3e_w1=%04x bank=%04x",
             dut.dbg_b3e_w0, dut.dbg_b3e_w1, dut.dbg_bank);
    $display("hwprobes5: sums=%04x sumb1=%04x sumb2=%04x (expect be3a x3)",
             u_sdr.dbg_sums, u_sdr.dbg_sumb1, u_sdr.dbg_sumb2);
    $display("sr3arb: sub_wait_cyc=%0d main_wait_cyc=%0d sub_grants=%0d main_grants=%0d",
             sub_sr3_wait, main_sr3_wait, sub_sr3_grants, main_sr3_grants);
    $display("status reads=%0d flagA_set=%0d flagB_set=%0d busy_set=%0d",
             st_reads, st_flagA, st_flagB, st_busy);
    $write("status last16:");
    for (int i = 0; i < 16; i++) $write(" %02x", st_last[(st_lidx + i) & 15]);
    $write("\n");
    $display("ym reg histogram (reg count lastval firstframe):");
    for (int i = 0; i < 256; i++)
      if (ym_hist[i] != 0)
        $display("  HIST %02x %0d %02x %0d", i, ym_hist[i], ym_lastv[i], ym_ffirst[i]);
    $write("reg14 distinct values:");
    for (int i = 0; i < 256; i++) if (r14_vals[i]) $write(" %02x", i);
    $write("\n");
    $display("oki: writes=%0d status_reads=%0d nz_samples=%0d first_nz_frame=%0d",
             okiw_n, okir_n, oki_nz, oki_first);
    if (use_sdram != 0)
      $display("oki sdram: data_mismatches=%0d max_ok_latency=%0d", oki_mism, oki_maxlat);
    $display("render: worst_line_cycles=%0d prescan_rejects=%0d over_budget_lines=%0d last_over_frame=%0d",
             rb_max, dut.u_vdp.u_render.dbg_pst_rej, rb_over, rb_over_frame);
    $display("render late_lines=%0d (completed mid-scanout)", rb_late);
    $display("render late detail: beam_visible=%0d (hcnt>=28) max_hcnt=%0d sy_changed=%0d",
             rb_late_vis, rb_late_maxh, rb_late_chg);
    $display("fg scroll prediction: exact=%0d miss=%0d maxerr=%0dpx",
             fg_pred_exact, fg_pred_miss, fg_pred_maxerr);
    $display("topline select mismatches=%0d", topline_mm);
    if (late_fh != 0) $fclose(late_fh);
    $display("render load: div_cycles=%0d ovl_stall_cycles=%0d",
             dut.u_vdp.u_render.dbg_div_cyc, dut.u_vdp.u_render.dbg_ovl_stall);
    $display("render envelope: tm_worst_line=%0d sp_worst_line=%0d fill_pulses=%0d fill_cycles=%0d (bytes/cyc=%0d.%02d)",
             dut.u_vdp.u_render.dbg_tm_max, dut.u_vdp.u_render.dbg_sp_max,
             dut.u_vdp.u_render.dbg_fill_pulse, dut.u_vdp.u_render.dbg_fill_cyc,
             (64'd200 * 64'(dut.u_vdp.u_render.dbg_fill_pulse) / (64'(dut.u_vdp.u_render.dbg_fill_cyc) + 1)) / 100,
             (64'd200 * 64'(dut.u_vdp.u_render.dbg_fill_pulse) / (64'(dut.u_vdp.u_render.dbg_fill_cyc) + 1)) % 100);
    for (int i = 0; i < okiw_n; i++)
      $display("  OKIW f=%0d val=%02x", okiw_log[i][23:8], okiw_log[i][7:0]);
    for (int i = 0; i < okir_n; i++)
      $display("  OKIR f=%0d val=%02x", okir_log[i][23:8], okir_log[i][7:0]);
    if (fh_audio != 0) $fclose(fh_audio);
    $finish;
  end

endmodule
