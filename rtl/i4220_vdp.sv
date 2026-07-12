// I4220 VDP top (M3).
//
// Binds the verified scanline renderer (i4220_render) and blitter
// (i4220_blitter) to the CPU-visible v2 address map (docs/i4220_spec.md
// sec 2), with internal VRAM/palette/sprite/tiletable BRAMs, register
// file, IRQ controller, video timing, sprite double-buffering, and a
// 3-client GFX ROM arbiter (renderer > CPU window > blitter).
//
// CPU bus: hold i_cs with stable addr/rnw/be/wdata; o_ack rises when the
// operation completes (rdata valid) and stays high until i_cs drops.
//
// External GFX ROM port: same stream protocol as i4220_render (1-cycle
// req pulse with addr+len, then len valid pulses; no new request before
// the stream completes).
//
// IRQ model follows the hyprduel driver's observed behaviour (spec sec
// 10): line 0 sets cause bits 0 and 5 (bit 5 auto-clears after
// P_BIT5_CYCLES), every other line sets bits 1 and 4; write-1 acks clear
// bits 4:0 only; enable register masks with 1 = disabled. o_vbl_pulse
// fires at line 0 for the board-level main-CPU IPL2 wiring.

module i4220_vdp #(
    parameter int GFX_AW = 22,
    parameter int P_PIXDIV = 12,          // sys clocks per pixel
    parameter int P_BIT5_CYCLES = 200000, // ~2.5 ms at 80 MHz
    parameter bit P_SPR_BUFFERED = 1'b1,
    // Which cause bits can drive the IRQ output line. Hyper Duel's board
    // only responds to hblank (bit 1) on IPL3; everything else is polled.
    // (MAME encodes the same fact by forcing the enable register OR 0xFD.)
    parameter logic [7:0] P_IRQ_LINE_MASK = 8'hFF
) (
    input  logic clk,
    input  logic rst_n,

    // CPU slave bus (byte addr within the 512 KB region)
    input  logic        i_cs,
    input  logic [18:0] i_addr,
    input  logic        i_rnw,
    input  logic [1:0]  i_be,      // [1] = high byte (UDS), [0] = low (LDS)
    input  logic [15:0] i_wdata,
    output logic [15:0] o_rdata,
    output logic        o_ack,

    // video out (RGB555, GRB palette decoded here)
    output logic       o_hs,
    output logic       o_vs,
    output logic       o_de,
    output logic       o_hblank,   // separate blanks for the MiSTer
    output logic       o_vblank,   // framework (arcade_video)
    output logic       o_ce_pix,
    output logic [4:0] o_r, o_g, o_b,

    // interrupts
    output logic o_irq,        // level: |(cause & ~enable) -> main IPL3
    output logic o_vbl_pulse,  // 1 sys clock at line 0 -> main IPL2

    // GFX ROM master. Stream data is WORD-mode for even-addr/even-len
    // requests (renderer, CPU window): [15:8] = even byte, [7:0] = odd,
    // two bytes per valid. Byte-mode (blitter, len 1): one byte in [7:0].
    output logic              o_rom_req,
    output logic [GFX_AW-1:0] o_rom_addr,
    output logic [6:0]        o_rom_len,
    input  logic [15:0]       i_rom_data,
    input  logic              i_rom_valid,
    input  logic [23:0]       i_gfx_size,

    // DEBUG: diagnostic flags for hardware bring-up
    output logic o_dbg_vdp_write,    // CPU ever wrote to VDP
    output logic o_dbg_line_start,   // line_start ever fired
    output logic o_dbg_rnd_done,     // renderer ever completed a line
    output logic o_dbg_lb_nonzero,   // linebuf ever had a nonzero pixel
    output logic [15:0] o_dbg_palw,  // count of nonzero palette writes
    output logic [15:0] o_dbg_ovr    // count of dropped render kicks (overrun)
);

  localparam int H_VIS = 320, H_TOTAL = 424;
  localparam int V_VIS = 224, V_TOTAL = 262;
  localparam int HS_BEG = 352, HS_END = 384;
  localparam int VS_BEG = 232, VS_END = 236;

  // ------------------------------------------------------------------
  // memories
  // ------------------------------------------------------------------
  // VRAM: explicit dual-port RAM wrappers (Verilator = inferred array,
  // Quartus = altsyncram) to avoid the 50GB elaboration balloon from
  // Quartus 17 inferring three 64Kx16 memories through its front end.
  // Port A = CPU/blitter (read/write), Port B = renderer (read-only).
  logic [15:0] vr_a_addr, vr_a_d;
  logic        vr_a_we [3];
  logic [1:0]  vr_a_be;
  logic [15:0] q_vram0, q_vram1, q_vram2;

  // Pipeline register on the VRAM port-B address: breaks the long
  // combinational path from the renderer's tileoffs computation into
  // the BRAM address register (the worst timing path at -2.195 ns).
  // The renderer's VR wait states are extended by one cycle to match.
  logic [15:0] rnd_vram_addr_r;
  always_ff @(posedge clk) rnd_vram_addr_r <= rnd_vram_addr;

  hd_dpram #(.AW(16), .DW(16)) u_vram0 (
    .clk(clk),
    .addr_a(vr_a_addr), .d_a(vr_a_d), .we_a(vr_a_we[0]), .be_a(vr_a_be), .q_a(q_vram0),
    .addr_b(rnd_vram_addr_r), .q_b(rnd_vram_q[0])
  );
  hd_dpram #(.AW(16), .DW(16)) u_vram1 (
    .clk(clk),
    .addr_a(vr_a_addr), .d_a(vr_a_d), .we_a(vr_a_we[1]), .be_a(vr_a_be), .q_a(q_vram1),
    .addr_b(rnd_vram_addr_r), .q_b(rnd_vram_q[1])
  );
  hd_dpram #(.AW(16), .DW(16)) u_vram2 (
    .clk(clk),
    .addr_a(vr_a_addr), .d_a(vr_a_d), .we_a(vr_a_we[2]), .be_a(vr_a_be), .q_a(q_vram2),
    .addr_b(rnd_vram_addr_r), .q_b(rnd_vram_q[2])
  );
  // tiletable: port A = CPU r/w, port B = renderer read
  logic [15:0] tt_q_a;
  logic [9:0]  tt_cpu_addr;
  logic        tt_we;
  logic [15:0] tt_rnd_q;
  hd_dpram #(.AW(10), .DW(16), .NUMWORDS(1024)) u_tiletable (
    .clk(clk),
    .addr_a(tt_cpu_addr), .d_a(i_wdata), .we_a(tt_we), .be_a(i_be), .q_a(tt_q_a),
    .addr_b(rnd_tt_addr), .q_b(tt_rnd_q)
  );

  // palette: port A = CPU r/w, port B = scan-out read
  logic [15:0] pal_q_a;
  logic [11:0] pal_cpu_addr;
  logic        pal_we;
  logic [11:0] so_pen;
  logic [15:0] pal_scanout_q;
  hd_dpram #(.AW(12), .DW(16), .NUMWORDS(4096)) u_palette (
    .clk(clk),
    .addr_a(pal_cpu_addr), .d_a(i_wdata), .we_a(pal_we), .be_a(i_be), .q_a(pal_q_a),
    .addr_b(so_pen), .q_b(pal_scanout_q)
  );

  // scratch: port A = CPU r/w, port B = unused
  logic [15:0] scr_q_a;
  logic [11:0] scr_cpu_addr;
  logic        scr_we;
  hd_dpram #(.AW(12), .DW(16), .NUMWORDS(4096)) u_scratch (
    .clk(clk),
    .addr_a(scr_cpu_addr), .d_a(i_wdata), .we_a(scr_we), .be_a(i_be), .q_a(scr_q_a),
    .addr_b(12'd0), .q_b()
  );

  // spr_live: port A = CPU r/w, port B = vblank copy read
  logic [15:0] spr_live_q_a;
  logic [10:0] spr_live_cpu_addr;
  logic        spr_live_we;
  logic [10:0] spr_live_b_addr;
  logic [15:0] spr_live_b_q;
  hd_dpram #(.AW(11), .DW(16), .NUMWORDS(2048)) u_spr_live (
    .clk(clk),
    .addr_a(spr_live_cpu_addr), .d_a(i_wdata), .we_a(spr_live_we), .be_a(i_be), .q_a(spr_live_q_a),
    .addr_b(spr_live_b_addr), .q_b(spr_live_b_q)
  );

  // spr_buf: port A = vblank copy write, port B = renderer read
  logic [10:0] spr_buf_a_addr;
  logic [15:0] spr_buf_a_d;
  logic        spr_buf_a_we;
  logic [15:0] spr_buf_q;
  hd_dpram #(.AW(11), .DW(16), .NUMWORDS(2048)) u_spr_buf (
    .clk(clk),
    .addr_a(spr_buf_a_addr), .d_a(spr_buf_a_d), .we_a(spr_buf_a_we), .be_a(2'b11), .q_a(),
    .addr_b(rnd_spr_addr), .q_b(spr_buf_q)
  );

  // sprite prescan table: port A = vblank copy snoop write, port B =
  // renderer read. One entry per sprite: {dis, y_end[10:0], y[9:0]}
  logic [8:0]  pst_waddr;
  logic [23:0] pst_wdata;
  logic        pst_we;
  logic        pst_valid;   // set once the first full copy refreshed the table
  logic [8:0]  rnd_pst_addr;
  logic [23:0] pst_rnd_q;
  hd_dpram #(.AW(9), .DW(24), .NUMWORDS(512)) u_spr_pst (
    .clk(clk),
    .addr_a(pst_waddr), .d_a(pst_wdata), .we_a(pst_we), .be_a(3'b111), .q_a(),
    .addr_b(rnd_pst_addr), .q_b(pst_rnd_q)
  );

  // linebuf: port A = renderer write, port B = scan-out read
  // padded to 16 bits wide so hd_dpram byte-enable logic covers all bits
  logic [15:0] lb_rq_wide;
  wire  [11:0] lb_rq = lb_rq_wide[11:0];
  hd_dpram #(.AW(11), .DW(16), .NUMWORDS(2048)) u_linebuf (
    .clk(clk),
    .addr_a({lb_bank, lb_x}), .d_a({4'd0, lb_pen}), .we_a(lb_we),
    .be_a(2'b11), .q_a(),
    .addr_b({vcnt[1:0], hcnt[8:0]}), .q_b(lb_rq_wide)
  );

  // ------------------------------------------------------------------
  // registers
  // ------------------------------------------------------------------
  logic [15:0] r_spr_count, r_spr_pri, r_spr_yoff, r_spr_xoff, r_spr_color;
  logic [5:0]  r_layer_pri;
  logic [11:0] r_bg;
  logic [15:0] r_scr_xoff, r_scr_yoff;
  logic [15:0] r_window [6];   // y0,x0,y1,x1,y2,x2
  logic [15:0] r_scroll [6];
  logic [15:0] r_ctrl;
  logic [15:0] r_rombank;
  logic [7:0]  r_irq_cause, r_irq_enable;
  logic        r_crtc_unlock;
  logic [15:0] r_crtc_h, r_crtc_v;
  logic [15:0] blit_regs [7];

  assign o_irq = |(r_irq_cause & ~r_irq_enable & P_IRQ_LINE_MASK);

  // renderer register views
  logic [15:0] rs_scroll_x [3];
  logic [15:0] rs_scroll_y [3];
  logic [15:0] rs_window_x [3];
  logic [15:0] rs_window_y [3];
  always_comb begin
    for (int l = 0; l < 3; l++) begin
      rs_window_y[l] = r_window[l*2 + 0];
      rs_window_x[l] = r_window[l*2 + 1];
      rs_scroll_y[l] = r_scroll[l*2 + 0];
      rs_scroll_x[l] = r_scroll[l*2 + 1];
    end
  end

  // ------------------------------------------------------------------
  // video timing
  // ------------------------------------------------------------------
  logic [$clog2(P_PIXDIV)-1:0] pixdiv;
  logic [8:0] hcnt;   // 0..423
  logic [8:0] vcnt;   // 0..261
  wire ce_pix = (pixdiv == 0);
  assign o_ce_pix = ce_pix;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pixdiv <= '0;
      hcnt <= '0;
      vcnt <= '0;
    end else begin
      pixdiv <= (32'(pixdiv) == P_PIXDIV - 1) ? '0 : pixdiv + 1'b1;
      if (ce_pix) begin
        if (32'(hcnt) == H_TOTAL - 1) begin
          hcnt <= '0;
          vcnt <= (32'(vcnt) == V_TOTAL - 1) ? '0 : vcnt + 1'b1;
        end else
          hcnt <= hcnt + 1'b1;
      end
    end
  end

  wire line_start   = ce_pix && (32'(hcnt) == H_TOTAL - 1);
  wire [8:0] next_v = (32'(vcnt) == V_TOTAL - 1) ? 9'd0 : vcnt + 9'd1;

  // Conditional late-kick predictor for lines 0 and 2 (see the kick
  // comment below). lk_hit[i] latches a CPU write to sy0 (0x78870) or
  // sy2 (0x78878) landing in the kick line's h<120 window; at h120 it
  // hands off to lk_pred[i], which steers NEXT frame's kick point.
  // Ramp scenes write every frame, so the predictor is wrong only for
  // the single frame at a ramp's start or end.
  wire sy_ramp_wr = reg_w && ((i_addr & 19'h7FFFE) == 19'h78870 ||
                              (i_addr & 19'h7FFFE) == 19'h78878);
  logic [1:0] lk_pred, lk_hit;
  wire lk_late = (next_v == 9'd0 && lk_pred[0]) ||
                 (next_v == 9'd2 && lk_pred[1]);

  // ------------------------------------------------------------------
  // IRQ cause events
  // ------------------------------------------------------------------
  logic [31:0] bit5_timer;
  logic        irq_ack_w;
  logic [7:0]  irq_ack_data;
  logic        irq_en_w;
  logic [7:0]  irq_en_data;
  logic        blit_done;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      r_irq_cause  <= 8'h00;
      r_irq_enable <= 8'hFF;
      bit5_timer   <= 0;
      o_vbl_pulse  <= 1'b0;
    end else begin
      o_vbl_pulse <= 1'b0;
      // hardware set events
      if (line_start) begin
        if (next_v == 9'd0) begin
          r_irq_cause[0] <= 1'b1;                 // vblank
          r_irq_cause[5] <= 1'b1;                 // vblank-window flag
          bit5_timer <= P_BIT5_CYCLES;
          o_vbl_pulse <= 1'b1;
        end else begin
          r_irq_cause[1] <= 1'b1;                 // hblank
          r_irq_cause[4] <= 1'b1;                 // per-line flag
        end
      end
      if (blit_done) r_irq_cause[2] <= 1'b1;      // blitter done
      if (bit5_timer != 0) begin
        bit5_timer <= bit5_timer - 1;
        if (bit5_timer == 1) r_irq_cause[5] <= 1'b0;
      end
      // CPU acknowledge (clears bits 4:0 only); keep simultaneous hw sets
      if (irq_ack_w)
        r_irq_cause <= (r_irq_cause & ~(irq_ack_data & 8'h1F))
                       | (line_start ? (next_v == 9'd0 ? 8'h21 : 8'h12) : 8'h00)
                       | (blit_done ? 8'h04 : 8'h00);
      if (irq_en_w) r_irq_enable <= irq_en_data;
    end
  end

  // ------------------------------------------------------------------
  // renderer
  // ------------------------------------------------------------------
  logic        rnd_start;
  logic [7:0]  rnd_line;
  logic        rnd_busy, rnd_done;
  logic [15:0] rnd_vram_addr;
  logic [15:0] rnd_vram_q [3];
  logic [9:0]  rnd_tt_addr;
  logic [15:0] rnd_tt_q;
  logic [10:0] rnd_spr_addr;
  logic [15:0] rnd_spr_q;
  logic              rnd_rom_req;
  logic [GFX_AW-1:0] rnd_rom_addr;
  logic [6:0]        rnd_rom_len;
  logic              rnd_rom_valid;
  logic        lb_we;
  logic [8:0]  lb_x;
  logic [11:0] lb_pen;
  logic [1:0]  lb_bank;      // bank being written
  logic        rnd_overrun;  // debug: kick FIFO overflowed

  i4220_render #(.GFX_AW(GFX_AW)) u_render (
    .clk(clk), .rst_n(rst_n),
    .i_start(rnd_start), .i_line(rnd_line),
    .o_pst_addr(rnd_pst_addr), .i_pst_data(pst_rnd_q),
    .i_pst_valid(pst_valid),
    .o_busy(rnd_busy), .o_done(rnd_done),
    .i_layer_pri(r_layer_pri),
    .i_bg_color(r_bg),
    .i_screen_ctrl(r_ctrl),
    .i_scroll_x(rs_scroll_x), .i_scroll_y(rs_scroll_y),
    .i_window_x(rs_window_x), .i_window_y(rs_window_y),
    .i_spr_count(r_spr_count), .i_spr_pri(r_spr_pri),
    .i_spr_xoff(r_spr_xoff), .i_spr_yoff(r_spr_yoff),
    .i_spr_color(r_spr_color),
    .i_screen_xoff(r_scr_xoff), .i_screen_yoff(r_scr_yoff),
    .i_gfx_size(i_gfx_size),
    .o_vram_addr(rnd_vram_addr), .i_vram_data(rnd_vram_q),
    .o_tt_addr(rnd_tt_addr), .i_tt_data(rnd_tt_q),
    .o_spr_addr(rnd_spr_addr), .i_spr_data(rnd_spr_q),
    .o_rom_req(rnd_rom_req), .o_rom_addr(rnd_rom_addr), .o_rom_len(rnd_rom_len),
    .i_rom_data(i_rom_data), .i_rom_valid(rnd_rom_valid),
    .o_lb_we(lb_we), .o_lb_x(lb_x), .o_lb_pen(lb_pen)
  );

  // kick renderer at hblank start for the next visible line
  // Elastic kick with a 4-deep FIFO and 4 line-buffer banks: bursts of
  // slow (sprite-dense) lines borrow time from cheap neighbours and the
  // vblank gap, up to 3 lines of lookahead. Banks are line[1:0], display
  // reads bank vcnt[1:0], so lookahead <= 3 never collides.
  // Frame parity rides through the kick FIFO so completed lines can be
  // tagged with the frame they belong to (scan-out blanking below).
  // Toggled one line BEFORE line 0's kick is queued so the queue write
  // at vcnt==V_TOTAL-1 sees the settled new value.
  logic       frame_par;
  logic       cur_par;       // parity of the line currently rendering
  logic [9:0] kick_fifo [0:3];   // {par, line[8:0]}
  logic [1:0] kf_wr, kf_rd;
  logic [2:0] kf_cnt;
  always_ff @(posedge clk) begin
    logic kf_push, kf_pop;
    kf_push = 1'b0; kf_pop = 1'b0;
    if (!rst_n) begin
      rnd_start <= 1'b0;
      rnd_overrun <= 1'b0;
      o_dbg_ovr <= '0;
      kf_wr <= '0;
      kf_rd <= '0;
      kf_cnt <= '0;
      frame_par <= 1'b0;
      lk_pred <= '0;
      lk_hit  <= '0;
    end else begin
      rnd_start <= 1'b0;
      if (ce_pix && hcnt == 9'd0 && 32'(vcnt) == V_TOTAL - 2)
        frame_par <= ~frame_par;
      // late-kick predictor bookkeeping
      if (sy_ramp_wr && hcnt < 9'd120) begin
        if (32'(vcnt) == V_TOTAL - 1) lk_hit[0] <= 1'b1;
        if (vcnt == 9'd1)             lk_hit[1] <= 1'b1;
      end
      if (ce_pix && hcnt == 9'd120) begin
        if (32'(vcnt) == V_TOTAL - 1) begin
          lk_pred[0] <= lk_hit[0];
          lk_hit[0]  <= 1'b0;
        end
        if (vcnt == 9'd1) begin
          lk_pred[1] <= lk_hit[1];
          lk_hit[1]  <= 1'b0;
        end
      end
      // queue at the START of each line for the NEXT line: a full line of
      // render lead (banks are 2 bits, display is never within 1 of render).
      // EXCEPTION (measured, 2026-07-12): the game's raster-effect write
      // schedule parks the frame-start scroll values at ~h75 of line 261
      // and writes line N's per-line values at ~h70-100 of line N-1. A
      // kick at h0 samples lines 0 and 2 one phase EARLY (10-17 px of
      // vertical offset in effect scenes - the "clouds" artefact); every
      // other line lands within 1 px of the value real hardware uses. So
      // WHEN THE RAMP IS LIVE (lk_pred, one-frame write predictor above)
      // lines 0 and 2 kick at h=120, after the write slot, trading their
      // render lead 5088 -> 3648 cycles. Scenes without sy0/sy2 raster
      // writes keep the full h0 lead: an unconditional late kick was
      // measured completing mid-scanout 1,357 times over a 5,200-frame
      // soak in heavy stage-2 attract frames, putting stale left-edge
      // pixels on screen (the tb late-line counters watch this).
      if (ce_pix &&
          hcnt == (lk_late ? 9'd120 : 9'd0) &&
          32'(next_v) < V_VIS) begin
        if (kf_cnt == 3'd4) begin
          rnd_overrun <= 1'b1;                     // hopelessly behind
          o_dbg_ovr <= o_dbg_ovr + 16'd1;
        end else begin
          kick_fifo[kf_wr] <= {frame_par, next_v};
          kf_wr <= kf_wr + 2'd1;
          kf_push = 1'b1;
        end
      end
      if (kf_cnt != 0 && !rnd_busy && !rnd_start) begin
        rnd_start <= 1'b1;
        rnd_line  <= kick_fifo[kf_rd][7:0];
        lb_bank   <= kick_fifo[kf_rd][1:0];
        cur_par   <= kick_fifo[kf_rd][9];
        kf_rd <= kf_rd + 2'd1;
        kf_pop = 1'b1;
      end
      // single counter update: a same-edge push+pop must net ZERO. The
      // old two-assignment form lost the push (last write won), so the
      // count drifted low during saturated sections until pops stalled
      // with entries queued, the write pointer lapped the read pointer,
      // and the renderer was fed stale line numbers forever - the
      // permanent post-demo blackout found in the 5200-frame soak.
      unique case ({kf_push, kf_pop})
        2'b10:   kf_cnt <= kf_cnt + 3'd1;
        2'b01:   kf_cnt <= kf_cnt - 3'd1;
        default: ;
      endcase
    end
  end

  // linebuf and tiletable reads handled by BRAM wrappers above

  // renderer-side memory ports (vram port B wired in instances above)
  assign rnd_tt_q = tt_rnd_q;

  // sprite RAM renderer port: buffered path only (P_SPR_BUFFERED=1)
  assign rnd_spr_q = spr_buf_q;

  // ------------------------------------------------------------------
  // sprite buffer copy at vblank start (line V_VIS, after last visible)
  // ------------------------------------------------------------------
  logic        cp_run;
  logic [11:0] cp_cnt;
  logic [15:0] cp_q;

  // read data lags cp_cnt by TWO cycles (registered BRAM q, then cp_q),
  // so the write address must lag by two as well: source word k is read
  // at cnt k, in spr_live_b_q at k+1, in cp_q at k+2, written at cnt k+2
  assign spr_live_b_addr = cp_cnt[10:0];
  assign spr_buf_a_addr  = 11'(cp_cnt - 12'd2);
  assign spr_buf_a_d     = cp_q;
  assign spr_buf_a_we    = cp_run && (cp_cnt >= 12'd2);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cp_run <= 1'b0;
      cp_cnt <= '0;
    end else begin
      if (line_start && next_v == 9'(V_VIS) && P_SPR_BUFFERED) begin
        cp_run <= 1'b1;
        cp_cnt <= '0;
      end else if (cp_run) begin
        cp_q <= spr_live_b_q;
        if (cp_cnt == 12'd2049) cp_run <= 1'b0;
        cp_cnt <= cp_cnt + 12'd1;
      end
    end
  end

  // ------------------------------------------------------------------
  // sprite prescan snoop: as sprite words stream through cp_q, compute
  // each sprite's raw y extent (bit-identical ohv arithmetic to the
  // renderer's ST_S_ZOOM/COVER stages, sprite words only - screen
  // offsets are applied live in the renderer) and write one table entry
  // per sprite. Entry k is written after words 4k..4k+3 have landed in
  // spr_buf, so table and buffer stay consistent.
  // ------------------------------------------------------------------
  // sprite zoom table copy (spec sec 7.1), comb ROM
  function automatic logic [11:0] ztab_of(input logic [5:0] z);
    unique case (z)
      6'd0:  ztab_of = 12'hAAC; 6'd1:  ztab_of = 12'h800;
      6'd2:  ztab_of = 12'h668; 6'd3:  ztab_of = 12'h554;
      6'd4:  ztab_of = 12'h494; 6'd5:  ztab_of = 12'h400;
      6'd6:  ztab_of = 12'h390; 6'd7:  ztab_of = 12'h334;
      6'd8:  ztab_of = 12'h2E8; 6'd9:  ztab_of = 12'h2AC;
      6'd10: ztab_of = 12'h278; 6'd11: ztab_of = 12'h248;
      6'd12: ztab_of = 12'h224; 6'd13: ztab_of = 12'h200;
      6'd14: ztab_of = 12'h1E0; 6'd15: ztab_of = 12'h1C8;
      6'd16: ztab_of = 12'h1B0; 6'd17: ztab_of = 12'h198;
      6'd18: ztab_of = 12'h188; 6'd19: ztab_of = 12'h174;
      6'd20: ztab_of = 12'h164; 6'd21: ztab_of = 12'h154;
      6'd22: ztab_of = 12'h148; 6'd23: ztab_of = 12'h13C;
      6'd24: ztab_of = 12'h130; 6'd25: ztab_of = 12'h124;
      6'd26: ztab_of = 12'h11C; 6'd27: ztab_of = 12'h110;
      6'd28: ztab_of = 12'h108; 6'd29: ztab_of = 12'h100;
      6'd30: ztab_of = 12'h0F8; 6'd31: ztab_of = 12'h0F0;
      6'd32: ztab_of = 12'h0EC; 6'd33: ztab_of = 12'h0E4;
      6'd34: ztab_of = 12'h0DC; 6'd35: ztab_of = 12'h0D8;
      6'd36: ztab_of = 12'h0D4; 6'd37: ztab_of = 12'h0CC;
      6'd38: ztab_of = 12'h0C8; 6'd39: ztab_of = 12'h0C4;
      6'd40: ztab_of = 12'h0C0; 6'd41: ztab_of = 12'h0BC;
      6'd42: ztab_of = 12'h0B8; 6'd43: ztab_of = 12'h0B4;
      6'd44: ztab_of = 12'h0B0; 6'd45: ztab_of = 12'h0AC;
      6'd46: ztab_of = 12'h0A8; 6'd47: ztab_of = 12'h0A4;
      6'd48: ztab_of = 12'h0A0; 6'd49: ztab_of = 12'h09C;
      6'd50: ztab_of = 12'h098; 6'd51: ztab_of = 12'h094;
      6'd52: ztab_of = 12'h090; 6'd53: ztab_of = 12'h08C;
      6'd54: ztab_of = 12'h088; 6'd55: ztab_of = 12'h080;
      6'd56: ztab_of = 12'h078; 6'd57: ztab_of = 12'h070;
      6'd58: ztab_of = 12'h068; 6'd59: ztab_of = 12'h060;
      6'd60: ztab_of = 12'h058; 6'd61: ztab_of = 12'h050;
      6'd62: ztab_of = 12'h048; default: ztab_of = 12'h040;
    endcase
  endfunction

  // cp_q holds word w = cp_cnt-2; sprite k's words w = 4k..4k+3.
  // w%4==0 -> dis, w%4==1 -> y/zoom, w%4==2 -> h, w%4==3 -> multiply and
  // arm the write; the write itself fires one cycle later (past cp_run
  // for the last sprite, hence the registered strobe).
  logic        ps_dis;
  logic [9:0]  ps_y;
  logic [11:0] ps_zoom;
  logic [6:0]  ps_h;
  logic [30:0] ps_ohf;
  wire  [11:0] ps_w = cp_cnt - 12'd2;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pst_we    <= 1'b0;
      pst_valid <= 1'b0;
    end else begin
      pst_we <= 1'b0;
      if (cp_run && cp_cnt >= 12'd2) begin
        unique case (ps_w[1:0])
          2'd0: ps_dis <= (cp_q[15:11] == 5'h1F);
          2'd1: begin
            ps_y    <= cp_q[9:0];
            ps_zoom <= ztab_of(cp_q[15:10]);
          end
          2'd2: ps_h <= (7'(cp_q[10:8]) + 7'd1) << 3;
          default: begin
            ps_ohf    <= 31'({ps_zoom, 8'd0}) * 31'(ps_h) + 31'h8000;
            pst_we    <= 1'b1;
            pst_waddr <= ps_w[10:2];
          end
        endcase
      end
      // renderer may use the table only once a full copy has refreshed it
      if (pst_we && pst_waddr == 9'd511) pst_valid <= 1'b1;
    end
  end

  // y_end = y + ohv; ohv <= 683 (max zoom x max height), so 11 bits hold it
  assign pst_wdata = {2'b00, ps_dis,
                      11'(ps_y) + 11'(ps_ohf[27:16]), ps_y};

  // ------------------------------------------------------------------
  // blitter
  // ------------------------------------------------------------------
  logic        bl_start;
  logic              bl_rom_rd;
  logic [GFX_AW-1:0] bl_rom_addr;
  logic [7:0]        bl_rom_data;
  logic              bl_rom_valid;
  logic        bl_we;
  logic [1:0]  bl_layer;
  logic [15:0] bl_addr, bl_wdata, bl_wmask;
  logic        bl_busy;

  i4220_blitter #(.GFX_AW(GFX_AW)) u_blit (
    .clk(clk), .rst_n(rst_n),
    .i_start(bl_start),
    .i_tmap({blit_regs[0], blit_regs[1]}),
    .i_src ({blit_regs[2], blit_regs[3]}),
    .i_dst ({blit_regs[4], blit_regs[5]}),
    .o_rom_rd(bl_rom_rd), .o_rom_addr(bl_rom_addr),
    .i_rom_data(bl_rom_data), .i_rom_valid(bl_rom_valid),
    .o_vram_we(bl_we), .o_vram_layer(bl_layer), .o_vram_addr(bl_addr),
    .o_vram_wdata(bl_wdata), .o_vram_wmask(bl_wmask),
    .o_busy(bl_busy), .o_done(blit_done)
  );
  assign bl_rom_data = i_rom_data[7:0];   // blitter reads are byte-mode

  // ------------------------------------------------------------------
  // GFX ROM arbiter: renderer > CPU window > blitter
  // ------------------------------------------------------------------
  typedef enum logic [1:0] {GR_NONE, GR_RND, GR_CPU, GR_BLT} grant_e;
  grant_e      gr;
  logic [6:0]  gr_left;

  // pending latches
  logic              rp_pend;
  logic [GFX_AW-1:0] rp_addr;
  logic [6:0]        rp_len;
  logic              cp_pend;        // CPU window read pending
  logic [GFX_AW-1:0] cpw_addr;
  logic              bl_rd_d;
  logic              bp_pend;
  logic [GFX_AW-1:0] bp_addr;

  logic        cpu_gfx_req;          // pulse from bus FSM
  logic [GFX_AW-1:0] cpu_gfx_addr;
  logic [15:0] cpu_gfx_data;
  logic        cpu_gfx_done;
  logic [1:0]  cpu_gfx_cnt;
  // sequential-read prefetch: the word after the requested one
  logic [15:0] cpu_pf_data;
  logic [GFX_AW-1:0] cpu_pf_tag;
  logic        cpu_pf_valid;

  assign rnd_rom_valid = i_rom_valid && (gr == GR_RND);
  assign bl_rom_valid  = i_rom_valid && (gr == GR_BLT);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      gr <= GR_NONE;
      rp_pend <= 1'b0;
      cp_pend <= 1'b0;
      bp_pend <= 1'b0;
      bl_rd_d <= 1'b0;
      o_rom_req <= 1'b0;
      cpu_gfx_done <= 1'b0;
      cpu_pf_valid <= 1'b0;
    end else begin
      o_rom_req <= 1'b0;
      cpu_gfx_done <= 1'b0;
      bl_rd_d <= bl_rom_rd;

      if (rnd_rom_req) begin
        rp_pend <= 1'b1;
        rp_addr <= rnd_rom_addr;
        rp_len  <= rnd_rom_len;
      end
      if (cpu_gfx_req) begin
        cp_pend <= 1'b1;
        cpw_addr <= cpu_gfx_addr;
        cpu_gfx_cnt <= 2'd0;
      end
      if (bl_rom_rd && !bl_rd_d) begin
        bp_pend <= 1'b1;
        bp_addr <= bl_rom_addr;
      end

      // gr_left counts VALID PULSES: word-mode requests (renderer, CPU
      // window - always even addr/len) get len/2 pulses of 2 bytes each;
      // the blitter's 1-byte reads get 1 pulse.
      if (gr == GR_NONE) begin
        if (rp_pend || rnd_rom_req) begin
          gr <= GR_RND;
          o_rom_req  <= 1'b1;
          o_rom_addr <= rnd_rom_req ? rnd_rom_addr : rp_addr;
          o_rom_len  <= rnd_rom_req ? rnd_rom_len : rp_len;
          gr_left    <= (rnd_rom_req ? rnd_rom_len : rp_len) >> 1;
          rp_pend <= 1'b0;
        end else if (cp_pend || cpu_gfx_req) begin
          gr <= GR_CPU;
          o_rom_req  <= 1'b1;
          o_rom_addr <= cpu_gfx_req ? cpu_gfx_addr : cpw_addr;
          if (cpu_gfx_req) cpw_addr <= cpu_gfx_addr;
          o_rom_len  <= 7'd4;        // word + prefetch of the next word
          gr_left    <= 7'd2;        // 2 word pulses
          cp_pend <= 1'b0;
          cpu_gfx_cnt <= 2'd0;
        end else if (bp_pend || (bl_rom_rd && !bl_rd_d)) begin
          gr <= GR_BLT;
          o_rom_req  <= 1'b1;
          o_rom_addr <= (bl_rom_rd && !bl_rd_d) ? bl_rom_addr : bp_addr;
          o_rom_len  <= 7'd1;
          gr_left    <= 7'd1;
          bp_pend <= 1'b0;
        end
      end else if (i_rom_valid) begin
        if (gr == GR_CPU) begin
          if (cpu_gfx_cnt == 2'd0) begin
            cpu_gfx_data <= i_rom_data;
            cpu_gfx_done <= 1'b1;
          end else begin
            cpu_pf_data  <= i_rom_data;
            cpu_pf_tag   <= GFX_AW'(32'(cpw_addr) + 2);
            cpu_pf_valid <= 1'b1;
          end
          cpu_gfx_cnt <= cpu_gfx_cnt + 2'd1;
        end
        if (gr_left == 7'd1) gr <= GR_NONE;
        else gr_left <= gr_left - 7'd1;
      end
    end
  end

  // ------------------------------------------------------------------
  // CPU bus interface
  // ------------------------------------------------------------------
  typedef enum logic [2:0] {B_IDLE, B_RD1, B_RD2, B_GFX, B_ACK} bst_e;
  bst_e bst;

  // decode
  wire in_vram    = (i_addr < 19'h60000);
  wire [1:0] vlyr = i_addr[18:17];
  wire in_gfxwin  = (i_addr[18:16] == 3'b110);            // 0x60000-0x6FFFF
  wire in_scratch = (i_addr[18:13] == 6'b111000);          // 0x70000-0x71FFF
  wire in_pal     = (i_addr[18:13] == 6'b111001);          // 0x72000-0x73FFF
  wire in_spr     = (i_addr[18:12] == 7'b1110100);         // 0x74000-0x74FFF
  wire in_rmw     = (i_addr >= 19'h75000 && i_addr < 19'h78000);
  wire in_tt      = (i_addr >= 19'h78000 && i_addr < 19'h78800);
  wire [1:0] rmw_lyr = 2'((i_addr - 19'h75000) >> 12);
  wire [10:0] rmw_o  = i_addr[11:1];
  // (o & 0x3F) | ((o >> 6) << 8)   (spec sec 2.1)
  wire [15:0] rmw_word = {3'b000, rmw_o[10:6], 2'b00, rmw_o[5:0]};

  // cpu-side memory address (word index within the selected RAM)
  wire [15:0] cpu_vword = in_rmw ? rmw_word : i_addr[16:1];

  // CPU-side reads come from port A of the BRAM wrappers (registered)
  wire [15:0] q_tt  = tt_q_a;
  wire [15:0] q_pal = pal_q_a;
  wire [15:0] q_spr = spr_live_q_a;
  wire [15:0] q_scr = scr_q_a;

  // drive BRAM port A addresses continuously from the CPU bus
  assign tt_cpu_addr       = i_addr[10:1];
  assign pal_cpu_addr      = i_addr[12:1];
  assign spr_live_cpu_addr = i_addr[11:1];
  assign scr_cpu_addr      = i_addr[12:1];

  wire [15:0] wmask_be = {{8{i_be[1]}}, {8{i_be[0]}}};

  // vram port A drive logic (combinational -> hd_dpram instances)
  wire cpu_vram_wr = (bst == B_IDLE) && i_cs && !i_rnw
                   && (in_vram || in_rmw) && !bl_busy;
  wire [1:0] cpu_wr_lyr = in_rmw ? rmw_lyr : vlyr;

  always_comb begin
    vr_a_we = '{default: 1'b0};
    if (bl_we) begin
      vr_a_addr = bl_addr;
      vr_a_d    = bl_wdata;
      vr_a_be   = {bl_wmask[15], bl_wmask[0]};
      vr_a_we[bl_layer] = 1'b1;
    end else if (cpu_vram_wr) begin
      vr_a_addr = cpu_vword;
      vr_a_d    = i_wdata;
      vr_a_be   = i_be;
      vr_a_we[cpu_wr_lyr] = 1'b1;
    end else begin
      vr_a_addr = cpu_vword;
      vr_a_d    = '0;
      vr_a_be   = 2'b11;
    end
  end

  // BRAM write enables (combinational, active on the CPU write commit cycle)
  wire cpu_wr_commit = (bst == B_IDLE) && i_cs && !i_rnw;
  assign scr_we      = cpu_wr_commit && in_scratch;
  assign pal_we      = cpu_wr_commit && in_pal;
  assign spr_live_we = cpu_wr_commit && in_spr;
  assign tt_we       = cpu_wr_commit && in_tt;

  logic reg_w;   // pulse: commit register write this cycle

  // register file write/read
  function automatic logic [15:0] comb16(input logic [15:0] old);
    comb16 = (old & ~wmask_be) | (i_wdata & wmask_be);
  endfunction

  logic [15:0] reg_rdata;
  logic        reg_hit;

  always_comb begin
    reg_hit = 1'b0;
    reg_rdata = 16'h0000;
    case (i_addr & 19'h7FFFE)
      19'h79700: begin reg_rdata = r_spr_count;  reg_hit = 1'b1; end
      19'h79702: begin reg_rdata = r_spr_pri;    reg_hit = 1'b1; end
      19'h79704: begin reg_rdata = r_spr_yoff;   reg_hit = 1'b1; end
      19'h79706: begin reg_rdata = r_spr_xoff;   reg_hit = 1'b1; end
      19'h79708: begin reg_rdata = r_spr_color;  reg_hit = 1'b1; end
      19'h79710: begin reg_rdata = {10'd0, r_layer_pri}; reg_hit = 1'b1; end
      19'h79712: begin reg_rdata = {4'd0, r_bg}; reg_hit = 1'b1; end
      // 0x788xx mirror (no sprite priority at 0x78802)
      19'h78800: begin reg_rdata = r_spr_count;  reg_hit = 1'b1; end
      19'h78804: begin reg_rdata = r_spr_yoff;   reg_hit = 1'b1; end
      19'h78806: begin reg_rdata = r_spr_xoff;   reg_hit = 1'b1; end
      19'h78808: begin reg_rdata = r_spr_color;  reg_hit = 1'b1; end
      19'h78810: begin reg_rdata = {10'd0, r_layer_pri}; reg_hit = 1'b1; end
      19'h78812: begin reg_rdata = {4'd0, r_bg}; reg_hit = 1'b1; end
      19'h78850: begin reg_rdata = r_scr_yoff;   reg_hit = 1'b1; end
      19'h78852: begin reg_rdata = r_scr_xoff;   reg_hit = 1'b1; end
      19'h788A2: begin reg_rdata = {8'd0, r_irq_cause}; reg_hit = 1'b1; end
      default: begin
        if (i_addr >= 19'h78860 && i_addr < 19'h7886C) begin
          reg_rdata = r_window[3'((i_addr - 19'h78860) >> 1)];
          reg_hit = 1'b1;
        end else if (i_addr >= 19'h78870 && i_addr < 19'h7887C) begin
          reg_rdata = r_scroll[3'((i_addr - 19'h78870) >> 1)];
          reg_hit = 1'b1;
        end
      end
    endcase
  end

  assign irq_ack_data = i_wdata[7:0];
  assign irq_en_data  = i_wdata[7:0];

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      r_spr_count <= '0; r_spr_pri <= '0;
      r_spr_xoff <= '0; r_spr_yoff <= '0; r_spr_color <= '0;
      r_layer_pri <= '0; r_bg <= '0;
      r_scr_xoff <= '0; r_scr_yoff <= '0;
      r_ctrl <= '0; r_rombank <= '0;
      r_crtc_unlock <= 1'b0;
      bl_start <= 1'b0;
      for (int i = 0; i < 6; i++) begin
        r_window[i] <= '0;
        r_scroll[i] <= '0;
      end
    end else begin
      bl_start <= 1'b0;
      if (reg_w) begin
        case (i_addr & 19'h7FFFE)
          19'h79700, 19'h78800: r_spr_count <= comb16(r_spr_count);
          19'h79702:            r_spr_pri   <= comb16(r_spr_pri);
          19'h79704, 19'h78804: r_spr_yoff  <= comb16(r_spr_yoff);
          19'h79706, 19'h78806: r_spr_xoff  <= comb16(r_spr_xoff);
          19'h79708, 19'h78808: r_spr_color <= comb16(r_spr_color);
          19'h79710, 19'h78810: r_layer_pri <= 6'(comb16({10'd0, r_layer_pri}));
          19'h79712, 19'h78812: r_bg        <= 12'(comb16({4'd0, r_bg}));
          19'h78850: r_scr_yoff <= comb16(r_scr_yoff);
          19'h78852: r_scr_xoff <= comb16(r_scr_xoff);
          19'h78880: if (r_crtc_unlock) r_crtc_v <= comb16(r_crtc_v);
          19'h78890: if (r_crtc_unlock) r_crtc_h <= comb16(r_crtc_h);
          19'h788A0: r_crtc_unlock <= i_wdata[0];
          19'h788AA: r_rombank <= comb16(r_rombank);
          19'h788AC: r_ctrl <= comb16(r_ctrl);
          default: begin
            if (i_addr >= 19'h78860 && i_addr < 19'h7886C)
              r_window[3'((i_addr - 19'h78860) >> 1)]
                <= comb16(r_window[3'((i_addr - 19'h78860) >> 1)]);
            else if (i_addr >= 19'h78870 && i_addr < 19'h7887C)
              r_scroll[3'((i_addr - 19'h78870) >> 1)]
                <= comb16(r_scroll[3'((i_addr - 19'h78870) >> 1)]);
            else if (i_addr >= 19'h78840 && i_addr < 19'h7884E) begin
              blit_regs[3'((i_addr - 19'h78840) >> 1)]
                <= comb16(blit_regs[3'((i_addr - 19'h78840) >> 1)]);
              if (((i_addr - 19'h78840) >> 1) == 6) bl_start <= 1'b1;
            end
          end
        endcase
      end
    end
  end

  // bus FSM
  wire [GFX_AW-1:0] gfx_addr_c = GFX_AW'((32'(r_rombank) << 16)
                                         + 32'(i_addr[15:1]) * 2);
  wire cpu_pf_valid_bus = cpu_pf_valid;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      bst <= B_IDLE;
      o_ack <= 1'b0;
      reg_w <= 1'b0;
      irq_ack_w <= 1'b0;
      irq_en_w <= 1'b0;
      cpu_gfx_req <= 1'b0;
    end else begin
      reg_w <= 1'b0;
      irq_ack_w <= 1'b0;
      irq_en_w <= 1'b0;
      cpu_gfx_req <= 1'b0;

      case (bst)
        B_IDLE: begin
          o_ack <= 1'b0;
          if (i_cs) begin
            if ((in_vram || in_rmw) && bl_busy) begin
              // stall until blitter releases VRAM
            end else if (i_rnw) begin
              if (in_gfxwin) begin
                if (cpu_pf_valid_bus &&
                    gfx_addr_c == cpu_pf_tag) begin
                  o_rdata <= (32'(gfx_addr_c) < 32'(i_gfx_size))
                             ? cpu_pf_data : 16'hFFFF;
                  bst <= B_ACK;
                end else begin
                  cpu_gfx_req <= 1'b1;
                  cpu_gfx_addr <= gfx_addr_c;
                  bst <= B_GFX;
                end
              end else begin
                bst <= B_RD1;   // registered RAM/regs read path
              end
            end else begin
              // writes commit this cycle in the memory processes above
              reg_w <= 1'b1;
              if ((i_addr & 19'h7FFFE) == 19'h788A2 && i_be[0]) irq_ack_w <= 1'b1;
              if ((i_addr & 19'h7FFFE) == 19'h788A4 && i_be[0]) irq_en_w <= 1'b1;
              bst <= B_ACK;
            end
          end
        end

        B_RD1: bst <= B_RD2;    // wait registered read

        B_RD2: begin
          if (in_vram || in_rmw) begin
            unique case (in_rmw ? rmw_lyr : vlyr)
              2'd0: o_rdata <= q_vram0;
              2'd1: o_rdata <= q_vram1;
              default: o_rdata <= q_vram2;
            endcase
          end else if (in_tt)      o_rdata <= q_tt;
          else if (in_pal)         o_rdata <= q_pal;
          else if (in_spr)         o_rdata <= q_spr;
          else if (in_scratch)     o_rdata <= q_scr;
          else if (reg_hit)        o_rdata <= reg_rdata;
          else                     o_rdata <= 16'h0000;
          bst <= B_ACK;
        end

        B_GFX: begin
          if (cpu_gfx_done) begin
            o_rdata <= (32'(cpu_gfx_addr) < 32'(i_gfx_size))
                       ? cpu_gfx_data : 16'hFFFF;
            bst <= B_ACK;
          end
        end

        B_ACK: begin
          o_ack <= 1'b1;
          if (!i_cs) begin
            o_ack <= 1'b0;
            bst <= B_IDLE;
          end
        end

        default: bst <= B_IDLE;
      endcase
    end
  end

  // ------------------------------------------------------------------
  // scan-out: linebuf -> palette -> GRB555 decode (2 ce_pix pipeline)
  // ------------------------------------------------------------------
  // Scan-out blanking: each linebuffer bank is tagged with {frame parity,
  // line} when the renderer COMPLETES a line into it. The beam shows a
  // line only if its bank holds this frame's copy of this line; otherwise
  // the background pen is substituted. Per-bank tags are immune to renders
  // that straddle the frame boundary (a late tail line only blanks itself,
  // as does a dropped kick - no frame-wide counter to poison). Read-side
  // only - no logic is added to the linebuffer write path.
  logic [8:0] bank_tag [0:3];   // {par, line[7:0]} last completed per bank
  logic       so_stale;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      // init to line 255: matches no visible vcnt, so everything blanks
      // until the renderer has actually delivered a line
      bank_tag[0] <= 9'h1FF;
      bank_tag[1] <= 9'h1FF;
      bank_tag[2] <= 9'h1FF;
      bank_tag[3] <= 9'h1FF;
      so_stale <= 1'b1;
    end else begin
      if (rnd_done)
        bank_tag[rnd_line[1:0]] <= {cur_par, rnd_line};
      so_stale <= (bank_tag[vcnt[1:0]] != {frame_par, vcnt[7:0]});
    end
  end

  // so_pen declared at u_palette instantiation
  logic [15:0] so_pal;
  logic        de0, de1;
  logic        hb0, hb1, vb0, vb1;

  always_ff @(posedge clk) begin
    if (ce_pix) begin
      // stage 0: pen fetch for current hcnt (bank = the line just rendered)
      de0 <= (32'(hcnt) < H_VIS) && (32'(vcnt) < V_VIS);
      hb0 <= !(32'(hcnt) < H_VIS);
      vb0 <= !(32'(vcnt) < V_VIS);
      so_pen <= (32'(hcnt) >= H_VIS) ? 12'd0
              : so_stale              ? r_bg
              :                         lb_rq;
      // stage 1: palette lookup
      de1 <= de0;
      hb1 <= hb0;
      vb1 <= vb0;
      so_pal <= pal_scanout_q;
      // stage 2: RGB out, aligned with de1 -> o_de
      o_r <= so_pal[10:6];
      o_g <= so_pal[15:11];
      o_b <= so_pal[5:1];
      o_de <= de1;
      o_hblank <= hb1;
      o_vblank <= vb1;
      o_hs <= (32'(hcnt) >= HS_BEG && 32'(hcnt) < HS_END);
      o_vs <= (32'(vcnt) >= VS_BEG && 32'(vcnt) < VS_END);
    end
  end

  // ------------------------------------------------------------------
  // DEBUG: sticky diagnostic flags (latch on first occurrence, never clear)
  // ------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      o_dbg_vdp_write  <= 1'b0;
      o_dbg_line_start <= 1'b0;
      o_dbg_rnd_done   <= 1'b0;
      o_dbg_lb_nonzero <= 1'b0;
    end else begin
      if (cpu_wr_commit)  o_dbg_vdp_write  <= 1'b1;
      if (line_start)     o_dbg_line_start <= 1'b1;
      if (rnd_done)       o_dbg_rnd_done   <= 1'b1;
      if (lb_we && lb_pen != 12'd0)
                          o_dbg_lb_nonzero <= 1'b1;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) o_dbg_palw <= '0;
    else if (pal_we && i_wdata != 16'd0) o_dbg_palw <= o_dbg_palw + 16'd1;
  end

endmodule
