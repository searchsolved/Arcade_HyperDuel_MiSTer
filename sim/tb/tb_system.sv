// Full-system boot testbench: real game ROM, both CPUs, real VDP.
// Dumps a PPM of the scan-out every +DUMPEVERY frames (default 60) up to
// +FRAMES total, into +OUTDIR. Reports sub-CPU latch activity.
//
// Usage: +MAINROM=<hex> +GFXROM=<hex> +OUTDIR=<dir>
//        [+FRAMES=n] [+DUMPEVERY=n] [+GFXSIZE=bytes]

`timescale 1ns/1ps

module tb_system;

  localparam int GFX_AW = 22;
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
  logic [7:0]        rom_data;
  logic              rom_valid;
  logic [7:0] dbg_subctl;
  logic       dbg_subrst;
  logic signed [15:0] audio;
  longint audio_activity;
  logic signed [15:0] audio_d;
  always_ff @(posedge clk) begin
    audio_d <= audio;
    if (audio != audio_d) audio_activity <= audio_activity + 1;
  end

  hyprduel_sys #(.GFX_AW(GFX_AW), .P_PIXDIV(16)) dut (
    .clk(clk), .rst_n(rst_n),
    .o_hs(hs), .o_vs(vs), .o_de(de), .o_ce_pix(ce_pix),
    .o_r(r5), .o_g(g5), .o_b(b5),
    .o_audio(audio),
    .i_p1p2(16'hFFFF), .i_system(16'hFFFF),
    .i_dsw(16'hFFBF), .i_service(16'hFFFF),  // dsw bit6=0: demo sounds ON
    .o_mrom_rd(mrom_rd), .o_mrom_addr(mrom_addr),
    .i_mrom_data(mrom_data), .i_mrom_valid(mrom_valid),
    .o_oki_addr(oki_addr), .i_oki_data(oki_data), .i_oki_ok(oki_ok),
    .o_rom_req(rom_req), .o_rom_addr(rom_addr), .o_rom_len(rom_len),
    .i_rom_data(rom_data), .i_rom_valid(rom_valid),
    .i_gfx_size(24'(gfx_size)),
    .dbg_subctl(dbg_subctl), .dbg_sub_in_reset(dbg_subrst)
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
      else begin
        rom_valid <= 1'b1;
        rom_data  <= gfxrom[srv_addr];
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
    s_iack_d <= dut.s_iack;
    ym_irq_d <= dut.ym_irq_n;
    if (dut.s_iack && !s_iack_d && dut.s_a[3:1] == 3'd1) iack1_edges <= iack1_edges + 1;
    if (dut.s_iack && !s_iack_d && dut.s_a[3:1] == 3'd2) iack2_edges <= iack2_edges + 1;
    if (!dut.ym_irq_n && ym_irq_d) irq_falls <= irq_falls + 1;
    if (dut.s_iack && dut.s_a[3:1] == 3'd1) s_iack1_cnt <= s_iack1_cnt + 1;
    if (dut.s_iack && dut.s_a[3:1] == 3'd2) s_iack2_cnt <= s_iack2_cnt + 1;
    if (!dut.ym_irq_n) ymirq_seen <= ymirq_seen + 1;
  end

  // audio capture: +AUDIODUMP=<path> writes raw s16le mono at sys/2048
  // (~52 kHz); convert with sim/mame/raw_to_wav.py
  int fh_audio;
  logic [10:0] adiv;
  initial begin
    string apath;
    fh_audio = 0;
    if ($value$plusargs("AUDIODUMP=%s", apath)) fh_audio = $fopen(apath, "wb");
  end
  always_ff @(posedge clk) begin
    adiv <= adiv + 1'b1;
    if (fh_audio != 0 && adiv == 0)
      $fwrite(fh_audio, "%c%c", dut.o_audio[7:0], dut.o_audio[15:8]);
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
  end
  int sub_samp, main_samp;

  task automatic dump_state(input string outdir, input int n);
    int fh;
    $writememh($sformatf("%s/st%0d_vram0.hex", outdir, n), dut.u_vdp.vram0);
    $writememh($sformatf("%s/st%0d_vram1.hex", outdir, n), dut.u_vdp.vram1);
    $writememh($sformatf("%s/st%0d_vram2.hex", outdir, n), dut.u_vdp.vram2);
    $writememh($sformatf("%s/st%0d_tiletable.hex", outdir, n), dut.u_vdp.tiletable);
    $writememh($sformatf("%s/st%0d_palette.hex", outdir, n), dut.u_vdp.palette);
    $writememh($sformatf("%s/st%0d_spriteram.hex", outdir, n), dut.u_vdp.spr_buf);
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
    if (!$value$plusargs("GFXSIZE=%d", gfx_size)) gfx_size = 1 << GFX_AW;

    $readmemh(gfxpath, gfxrom);

    rst_n = 0;
    repeat (32) @(posedge clk);
    rst_n = 1;

    last_dumped = 0;
    while (frames_seen < total_frames) begin
      @(posedge clk);
      if (frames_seen >= last_dumped + dump_every) begin
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
    if (fh_audio != 0) $fclose(fh_audio);
    $finish;
  end

endmodule
