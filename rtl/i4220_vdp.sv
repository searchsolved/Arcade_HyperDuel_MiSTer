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
    output logic       o_ce_pix,
    output logic [4:0] o_r, o_g, o_b,

    // interrupts
    output logic o_irq,        // level: |(cause & ~enable) -> main IPL3
    output logic o_vbl_pulse,  // 1 sys clock at line 0 -> main IPL2

    // GFX ROM master
    output logic              o_rom_req,
    output logic [GFX_AW-1:0] o_rom_addr,
    output logic [6:0]        o_rom_len,
    input  logic [7:0]        i_rom_data,
    input  logic              i_rom_valid,
    input  logic [23:0]       i_gfx_size
);

  localparam int H_VIS = 320, H_TOTAL = 424;
  localparam int V_VIS = 224, V_TOTAL = 262;
  localparam int HS_BEG = 352, HS_END = 384;
  localparam int VS_BEG = 232, VS_END = 236;

  // ------------------------------------------------------------------
  // memories
  // ------------------------------------------------------------------
  logic [15:0] vram0 [0:65535];
  logic [15:0] vram1 [0:65535];
  logic [15:0] vram2 [0:65535];
  logic [15:0] tiletable [0:1023];
  logic [15:0] palette [0:4095];
  logic [15:0] spr_live [0:2047];
  logic [15:0] spr_buf [0:2047];
  logic [15:0] scratch [0:4095];
  logic [11:0] linebuf [0:3][0:319];   // 4 banks: up to 3 lines of render lookahead

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
  logic [8:0] kick_fifo [0:3];
  logic [1:0] kf_wr, kf_rd;
  logic [2:0] kf_cnt;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rnd_start <= 1'b0;
      rnd_overrun <= 1'b0;
      kf_wr <= '0;
      kf_rd <= '0;
      kf_cnt <= '0;
    end else begin
      rnd_start <= 1'b0;
      // queue at the START of each line for the NEXT line: a full line of
      // render lead (banks are 2 bits, display is never within 1 of render)
      if (ce_pix && hcnt == 9'd0 && 32'(next_v) < V_VIS) begin
        if (kf_cnt == 3'd4) rnd_overrun <= 1'b1;   // hopelessly behind
        else begin
          kick_fifo[kf_wr] <= next_v;
          kf_wr <= kf_wr + 2'd1;
          kf_cnt <= kf_cnt + 3'd1;
        end
      end
      if (kf_cnt != 0 && !rnd_busy && !rnd_start) begin
        rnd_start <= 1'b1;
        rnd_line  <= kick_fifo[kf_rd][7:0];
        lb_bank   <= kick_fifo[kf_rd][1:0];
        kf_rd <= kf_rd + 2'd1;
        kf_cnt <= kf_cnt - 3'd1;
      end
    end
  end

  always_ff @(posedge clk)
    if (lb_we) linebuf[lb_bank][lb_x] <= lb_pen;

  // renderer-side memory ports (dedicated port B on each BRAM)
  always_ff @(posedge clk) begin
    rnd_vram_q[0] <= vram0[rnd_vram_addr];
    rnd_vram_q[1] <= vram1[rnd_vram_addr];
    rnd_vram_q[2] <= vram2[rnd_vram_addr];
    rnd_tt_q      <= tiletable[rnd_tt_addr];
  end

  // sprite RAM renderer port: buffered copy (or live if not buffered)
  logic [15:0] spr_buf_q, spr_live_rq;
  always_ff @(posedge clk) begin
    spr_buf_q   <= spr_buf[rnd_spr_addr];
    spr_live_rq <= spr_live[rnd_spr_addr];
  end
  assign rnd_spr_q = P_SPR_BUFFERED ? spr_buf_q : spr_live_rq;

  // ------------------------------------------------------------------
  // sprite buffer copy at vblank start (line V_VIS, after last visible)
  // ------------------------------------------------------------------
  logic        cp_run;
  logic [11:0] cp_cnt;
  logic [15:0] cp_q;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cp_run <= 1'b0;
      cp_cnt <= '0;
    end else begin
      if (line_start && next_v == 9'(V_VIS) && P_SPR_BUFFERED) begin
        cp_run <= 1'b1;
        cp_cnt <= '0;
      end else if (cp_run) begin
        cp_q <= spr_live[cp_cnt[10:0]];
        if (cp_cnt != 0) spr_buf[cp_cnt[10:0] - 11'd1] <= cp_q;
        if (cp_cnt == 12'd2048) cp_run <= 1'b0;
        cp_cnt <= cp_cnt + 12'd1;
      end
    end
  end

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
  assign bl_rom_data = i_rom_data;

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

      if (gr == GR_NONE) begin
        if (rp_pend || rnd_rom_req) begin
          gr <= GR_RND;
          o_rom_req  <= 1'b1;
          o_rom_addr <= rnd_rom_req ? rnd_rom_addr : rp_addr;
          o_rom_len  <= rnd_rom_req ? rnd_rom_len : rp_len;
          gr_left    <= rnd_rom_req ? rnd_rom_len : rp_len;
          rp_pend <= 1'b0;
        end else if (cp_pend || cpu_gfx_req) begin
          gr <= GR_CPU;
          o_rom_req  <= 1'b1;
          o_rom_addr <= cpu_gfx_req ? cpu_gfx_addr : cpw_addr;
          if (cpu_gfx_req) cpw_addr <= cpu_gfx_addr;
          o_rom_len  <= 7'd4;        // word + prefetch of the next word
          gr_left    <= 7'd4;
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
          unique case (cpu_gfx_cnt)
            2'd0: cpu_gfx_data[15:8] <= i_rom_data;
            2'd1: begin
              cpu_gfx_data[7:0] <= i_rom_data;
              cpu_gfx_done <= 1'b1;
            end
            2'd2: cpu_pf_data[15:8] <= i_rom_data;
            default: begin
              cpu_pf_data[7:0] <= i_rom_data;
              cpu_pf_tag   <= GFX_AW'(32'(cpw_addr) + 2);
              cpu_pf_valid <= 1'b1;
            end
          endcase
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

  // registered CPU-side reads (port A)
  logic [15:0] q_vram0, q_vram1, q_vram2, q_tt, q_pal, q_spr, q_scr;
  always_ff @(posedge clk) begin
    q_tt  <= tiletable[i_addr[10:1]];
    q_pal <= palette[i_addr[12:1]];
    q_spr <= spr_live[i_addr[11:1]];
    q_scr <= scratch[i_addr[12:1]];
  end

  // vram port A: blitter has priority
  wire [15:0] wmask_be = {{8{i_be[1]}}, {8{i_be[0]}}};
  always_ff @(posedge clk) begin
    if (bl_we) begin
      unique case (bl_layer)
        2'd0: vram0[bl_addr] <= (vram0[bl_addr] & ~bl_wmask) | (bl_wdata & bl_wmask);
        2'd1: vram1[bl_addr] <= (vram1[bl_addr] & ~bl_wmask) | (bl_wdata & bl_wmask);
        default: vram2[bl_addr] <= (vram2[bl_addr] & ~bl_wmask) | (bl_wdata & bl_wmask);
      endcase
    end else if (bst == B_IDLE && i_cs && !i_rnw && (in_vram || in_rmw) && !bl_busy) begin
      unique case (in_rmw ? rmw_lyr : vlyr)
        2'd0: vram0[cpu_vword] <= (vram0[cpu_vword] & ~wmask_be) | (i_wdata & wmask_be);
        2'd1: vram1[cpu_vword] <= (vram1[cpu_vword] & ~wmask_be) | (i_wdata & wmask_be);
        default: vram2[cpu_vword] <= (vram2[cpu_vword] & ~wmask_be) | (i_wdata & wmask_be);
      endcase
    end else begin
      q_vram0 <= vram0[cpu_vword];
      q_vram1 <= vram1[cpu_vword];
      q_vram2 <= vram2[cpu_vword];
    end
  end

  // other RAM writes + register writes
  logic reg_w;   // pulse: commit register write this cycle
  always_ff @(posedge clk) begin
    if (bst == B_IDLE && i_cs && !i_rnw) begin
      if (in_scratch) scratch[i_addr[12:1]]
          <= (q_scr & ~wmask_be) | (i_wdata & wmask_be);
      if (in_pal) palette[i_addr[12:1]]
          <= (palette[i_addr[12:1]] & ~wmask_be) | (i_wdata & wmask_be);
      if (in_spr) spr_live[i_addr[11:1]]
          <= (spr_live[i_addr[11:1]] & ~wmask_be) | (i_wdata & wmask_be);
      if (in_tt) tiletable[i_addr[10:1]]
          <= (tiletable[i_addr[10:1]] & ~wmask_be) | (i_wdata & wmask_be);
    end
  end

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
  logic [11:0] so_pen;
  logic [15:0] so_pal;
  logic        de0, de1;

  always_ff @(posedge clk) begin
    if (ce_pix) begin
      // stage 0: pen fetch for current hcnt (bank = the line just rendered)
      de0 <= (32'(hcnt) < H_VIS) && (32'(vcnt) < V_VIS);
      so_pen <= (32'(hcnt) < H_VIS) ? linebuf[vcnt[1:0]][hcnt[8:0] % 320] : 12'd0;
      // stage 1: palette lookup
      de1 <= de0;
      so_pal <= palette[so_pen];
      // stage 2: RGB out, aligned with de1 -> o_de
      o_r <= so_pal[10:6];
      o_g <= so_pal[15:11];
      o_b <= so_pal[5:1];
      o_de <= de1;
      o_hs <= (32'(hcnt) >= HS_BEG && 32'(hcnt) < HS_END);
      o_vs <= (32'(vcnt) >= VS_BEG && 32'(vcnt) < VS_END);
    end
  end

endmodule
