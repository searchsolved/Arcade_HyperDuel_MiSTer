// Hyper Duel board level (M3): 2x fx68k, shared RAM, I4220 VDP, control
// latch, IRQ wiring, sound stubs. Memory maps per
// docs/hyprduel_system_spec.md.
//
// Sim-focused but synthesizable-shaped: main ROM is an internal BRAM
// loaded via +MAINROM=<hex> (SIM only); GFX ROM is the external stream
// port (TB or SDRAM). Sound: real jt51 (YM2151) with its IRQ on sub IPL1;
// OKI M6295 is still a stub (reads 0x00 = never busy). MAME's inter-CPU
// spin hacks are deliberately NOT modelled; shared RAM is true dual-port.

module hyprduel_sys #(
    parameter int GFX_AW = 22,
    parameter int P_PIXDIV = 6,     // sys clocks per pixel (sim speed)
    parameter int P_CPUDIV = 8      // sys clocks per 68k clock
) (
    input  logic clk,
    input  logic rst_n,

    // video
    output logic       o_hs, o_vs, o_de, o_ce_pix,
    output logic       o_hblank, o_vblank,
    output logic [4:0] o_r, o_g, o_b,

    // audio (signed mono mix, MAME weights: YM 0.80, OKI 0.57)
    output logic signed [15:0] o_audio,

    // inputs (active low), spec sec 6
    input  logic [15:0] i_p1p2,
    input  logic [15:0] i_system,
    input  logic [15:0] i_dsw,
    input  logic [15:0] i_service,

    // main 68000 ROM read port (request/valid; SDRAM-friendly)
    output logic        o_mrom_rd,     // pulse; addr stable until valid
    output logic [17:0] o_mrom_addr,   // word address (512 KB)
    input  logic [15:0] i_mrom_data,
    input  logic        i_mrom_valid,

    // OKI sample ROM port (jt6295 native ok-handshake)
    output logic [17:0] o_oki_addr,
    input  logic [7:0]  i_oki_data,
    input  logic        i_oki_ok,

    // shared3 SDRAM port (word R/W)
    output logic        o_sr3_req,
    output logic        o_sr3_we,
    output logic [16:0] o_sr3_addr,
    output logic [15:0] o_sr3_wdata,
    output logic [1:0]  o_sr3_be,
    input  logic [15:0] i_sr3_rdata,
    input  logic        i_sr3_ack,

    // GFX ROM stream port
    output logic              o_rom_req,
    output logic [GFX_AW-1:0] o_rom_addr,
    output logic [6:0]        o_rom_len,
    input  logic [7:0]        i_rom_data,
    input  logic              i_rom_valid,
    input  logic [23:0]       i_gfx_size,

    // debug
    output logic [7:0] dbg_subctl,
    output logic       dbg_sub_in_reset,
    output logic       dbg_vdp_write,
    output logic       dbg_line_start,
    output logic       dbg_rnd_done,
    output logic       dbg_lb_nonzero,
    output logic       dbg_cpu_past_vectors,
    output logic       dbg_vdp_cs_seen,
    output logic [15:0] dbg_mrom_word0,
    output logic [15:0] dbg_mrom_word1,
    output logic [15:0] dbg_mrom_word2,
    output logic [15:0] dbg_mrom_word3,
    output logic [15:0] dbg_sack_cnt,   // sr3 acks granted to the sub CPU
    output logic [15:0] dbg_palw,       // nonzero palette writes (from VDP)
    output logic [15:0] dbg_hshk,       // last data written to sr3 word 0xD9A6 (0xFFF34C)
    output logic [7:0]  dbg_iack1,      // sub CPU level-1 (YM) interrupt acks
    output logic [15:0] dbg_wadr,       // last GFX-window read addr (word offset)
    output logic [15:0] dbg_wcnt,       // GFX-window read count
    output logic [15:0] dbg_srrc,       // main CPU sr3 read acks
    output logic [15:0] dbg_ovr,        // dropped render kicks (line overrun)
    output logic [15:0] dbg_wda [0:3],  // window read data at offsets 0,2,4,6
    output logic [15:0] dbg_b3e_w0,     // first window word0 read with bank==0x3E
    output logic [15:0] dbg_b3e_w1,     // first window word1 read with bank==0x3E
    output logic [15:0] dbg_bank        // {bank write count, current bank}
);

  // ------------------------------------------------------------------
  // memories (shared RAM declarations moved to hd_tdpram instances below)
  // ------------------------------------------------------------------


  // ------------------------------------------------------------------
  // CPU clock enables (two-phase)
  // ------------------------------------------------------------------
  logic [$clog2(P_CPUDIV)-1:0] cpudiv;
  wire enPhi1 = (32'(cpudiv) == 0);
  wire enPhi2 = (32'(cpudiv) == P_CPUDIV / 2);
  always_ff @(posedge clk)
    if (!rst_n) cpudiv <= '0;
    else cpudiv <= (32'(cpudiv) == P_CPUDIV - 1) ? '0 : cpudiv + 1'b1;

  // ------------------------------------------------------------------
  // main CPU
  // ------------------------------------------------------------------
  logic        m_rw, m_asn, m_ldsn, m_udsn;
  logic        m_dtackn, m_vpan;
  logic        m_fc0, m_fc1, m_fc2;
  logic [23:1] m_a;
  logic [15:0] m_din, m_dout;
  logic [2:0]  m_ipl;

  fx68k u_maincpu (
    .clk(clk), .HALTn(1'b1),
    .extReset(!rst_n), .pwrUp(!rst_n),
    .enPhi1(enPhi1), .enPhi2(enPhi2),
    .eRWn(m_rw), .ASn(m_asn), .LDSn(m_ldsn), .UDSn(m_udsn),
    .E(), .VMAn(),
    .FC0(m_fc0), .FC1(m_fc1), .FC2(m_fc2),
    .BGn(), .oRESETn(), .oHALTEDn(),
    .DTACKn(m_dtackn), .VPAn(m_vpan),
    .BERRn(1'b1), .BRn(1'b1), .BGACKn(1'b1),
    .IPL0n(~m_ipl[0]), .IPL1n(~m_ipl[1]), .IPL2n(~m_ipl[2]),
    .iEdb(m_din), .oEdb(m_dout), .eab(m_a)
  );

  // ------------------------------------------------------------------
  // sub CPU (no ROM; boots from shared1, held in reset by the latch)
  // ------------------------------------------------------------------
  logic        s_rw, s_asn, s_ldsn, s_udsn;
  logic        s_dtackn, s_vpan;
  logic        s_fc0, s_fc1, s_fc2;
  logic [23:1] s_a;
  logic [15:0] s_din, s_dout;
  logic [2:0]  s_ipl;
  logic        sub_rst;   // 1 = held in reset

  fx68k u_subcpu (
    .clk(clk), .HALTn(1'b1),
    .extReset(!rst_n || sub_rst), .pwrUp(!rst_n),
    .enPhi1(enPhi1), .enPhi2(enPhi2),
    .eRWn(s_rw), .ASn(s_asn), .LDSn(s_ldsn), .UDSn(s_udsn),
    .E(), .VMAn(),
    .FC0(s_fc0), .FC1(s_fc1), .FC2(s_fc2),
    .BGn(), .oRESETn(), .oHALTEDn(),
    .DTACKn(s_dtackn), .VPAn(s_vpan),
    .BERRn(1'b1), .BRn(1'b1), .BGACKn(1'b1),
    .IPL0n(~s_ipl[0]), .IPL1n(~s_ipl[1]), .IPL2n(~s_ipl[2]),
    .iEdb(s_din), .oEdb(s_dout), .eab(s_a)
  );

  // ------------------------------------------------------------------
  // VDP
  // ------------------------------------------------------------------
  logic        vdp_cs;
  logic [18:0] vdp_addr;
  logic        vdp_rnw_r;
  logic [1:0]  vdp_be_r;
  logic [15:0] vdp_wdata_r;
  logic [15:0] vdp_rdata;
  logic        vdp_ack;
  logic        vdp_irq, vbl_pulse;

  i4220_vdp #(.GFX_AW(GFX_AW), .P_PIXDIV(P_PIXDIV),
              .P_BIT5_CYCLES(2500 * P_PIXDIV * 20 / 3),
              .P_IRQ_LINE_MASK(8'h02)) u_vdp (
    // 2500 us at the sys clock implied by P_PIXDIV vs the 6.667 MHz pixel
    .clk(clk), .rst_n(rst_n),
    .i_cs(vdp_cs), .i_addr(vdp_addr), .i_rnw(vdp_rnw_r),
    .i_be(vdp_be_r), .i_wdata(vdp_wdata_r),
    .o_rdata(vdp_rdata), .o_ack(vdp_ack),
    .o_hs(o_hs), .o_vs(o_vs), .o_de(o_de), .o_ce_pix(o_ce_pix),
    .o_hblank(o_hblank), .o_vblank(o_vblank),
    .o_r(o_r), .o_g(o_g), .o_b(o_b),
    .o_irq(vdp_irq), .o_vbl_pulse(vbl_pulse),
    .o_rom_req(o_rom_req), .o_rom_addr(o_rom_addr), .o_rom_len(o_rom_len),
    .i_rom_data(i_rom_data), .i_rom_valid(i_rom_valid),
    .i_gfx_size(i_gfx_size),
    .o_dbg_vdp_write(dbg_vdp_write),
    .o_dbg_line_start(dbg_line_start),
    .o_dbg_rnd_done(dbg_rnd_done),
    .o_dbg_lb_nonzero(dbg_lb_nonzero),
    .o_dbg_palw(dbg_palw),
    .o_dbg_ovr(dbg_ovr)
  );


  // YM2151 (jt51) at sub 0x400000-0x400003, IRQ -> sub IPL1
  // ------------------------------------------------------------------
  localparam int P_YMDIV = (P_PIXDIV * 5) / 3;   // 4 MHz from the sys clock
  logic [$clog2(P_YMDIV)-1:0] ymdiv;
  logic ym_phase;
  wire ym_cen    = (32'(ymdiv) == 0);
  wire ym_cen_p1 = ym_cen && ym_phase;
  always_ff @(posedge clk)
    if (!rst_n) begin
      ymdiv <= '0;
      ym_phase <= 1'b0;
    end else begin
      ymdiv <= (32'(ymdiv) == P_YMDIV - 1) ? '0 : ymdiv + 1'b1;
      if (ym_cen) ym_phase <= ~ym_phase;
    end

  logic       ym_cs_n, ym_wr_n, ym_a0;
  logic [7:0] ym_din;
  logic [7:0] ym_dout;
  logic       ym_irq_n;

  jt51 u_ym (
    .rst(!rst_n), .clk(clk), .cen(ym_cen), .cen_p1(ym_cen_p1),
    .cs_n(ym_cs_n), .wr_n(ym_wr_n), .a0(ym_a0), .din(ym_din),
    .dout(ym_dout),
    .ct1(), .ct2(), .irq_n(ym_irq_n),
    .sample(), .left(), .right(), .xleft(ym_xl), .xright(ym_xr)
  );

  // ------------------------------------------------------------------
  // OKI M6295 (jt6295) at sub 0x400004-0x400005, samples from oki_rom
  // ------------------------------------------------------------------
  localparam int P_OKIDIV = (P_PIXDIV * 3232) / 1000;  // ~2.0625 MHz
  logic [$clog2(P_OKIDIV)-1:0] okidiv;
  wire oki_cen = (32'(okidiv) == 0);
  always_ff @(posedge clk)
    if (!rst_n) okidiv <= '0;
    else okidiv <= (32'(okidiv) == P_OKIDIV - 1) ? '0 : okidiv + 1'b1;

  logic        oki_wrn;
  logic [7:0]  oki_din, oki_dout;
  logic signed [13:0] oki_snd;

  jt6295 #(.INTERPOL(0)) u_oki (
    .rst(!rst_n), .clk(clk), .cen(oki_cen), .ss(1'b1),
    .wrn(oki_wrn), .din(oki_din), .dout(oki_dout),
    .rom_addr(o_oki_addr), .rom_data(i_oki_data), .rom_ok(i_oki_ok),
    .sound(oki_snd), .sample()
  );

  // mono mix, matched to MAME's measured stream levels (2026-07-05
  // split-capture calibration): YM x1.20, OKI x0.57 after the 14->16
  // bit scale. 26-bit intermediates: the old 18-bit ones WRAPPED for
  // any sample above ~640, mangling the output (docs/qa_checklist.md).
  logic signed [15:0] ym_xl, ym_xr;
  always_comb begin
    logic signed [25:0] ymm, okim, mix;
    ymm  = (26'(ym_xl) + 26'(ym_xr)) >>> 1;
    ymm  = (ymm * 26'sd307) >>> 8;              // x1.20
    okim = (26'(oki_snd) <<< 2);
    okim = (okim * 26'sd457) >>> 8;             // x1.79 (calibrated:
    // jt6295's scale sits ~2 bits under MAME's okim6295 stream)
    mix  = ymm + okim;
    if (mix > 26'sd32767)       o_audio = 16'sd32767;
    else if (mix < -26'sd32768) o_audio = -16'sd32768;
    else                        o_audio = mix[15:0];
  end

  // ------------------------------------------------------------------
  // sub CPU control latch (main writes 0x800000), spec sec 4.1
  // ------------------------------------------------------------------
  logic sub_cmd_pend;   // sub IPL2 held until acked
  assign dbg_sub_in_reset = sub_rst;

  // DEBUG: capture first 4 mrom reads (reset vector) and CPU address range
  logic [2:0] mrom_cap_cnt;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      mrom_cap_cnt <= 3'd0;
      dbg_mrom_word0 <= '0;
      dbg_mrom_word1 <= '0;
      dbg_mrom_word2 <= '0;
      dbg_mrom_word3 <= '0;
      dbg_cpu_past_vectors <= 1'b0;
      dbg_vdp_cs_seen <= 1'b0;
    end else begin
      if (i_mrom_valid && mrom_cap_cnt < 3'd4) begin
        case (mrom_cap_cnt)
          3'd0: dbg_mrom_word0 <= i_mrom_data;
          3'd1: dbg_mrom_word1 <= i_mrom_data;
          3'd2: dbg_mrom_word2 <= i_mrom_data;
          3'd3: dbg_mrom_word3 <= i_mrom_data;
          default: ;
        endcase
        mrom_cap_cnt <= mrom_cap_cnt + 3'd1;
      end
      if (m_strobe && m_ba >= 24'h000800)
        dbg_cpu_past_vectors <= 1'b1;
      if (vdp_cs)
        dbg_vdp_cs_seen <= 1'b1;
    end
  end

  // ------------------------------------------------------------------
  // interrupts
  // ------------------------------------------------------------------
  logic vbl_pend;
  wire m_iack = m_fc2 && m_fc1 && m_fc0 && !m_asn;
  wire s_iack = s_fc2 && s_fc1 && s_fc0 && !s_asn;

  always_ff @(posedge clk) begin
    if (!rst_n) vbl_pend <= 1'b0;
    else begin
      if (vbl_pulse) vbl_pend <= 1'b1;
      if (m_iack && m_a[3:1] == 3'd2) vbl_pend <= 1'b0;   // HOLD_LINE ack
    end
  end

  always_comb begin
    m_ipl = vdp_irq ? 3'd3 : (vbl_pend ? 3'd2 : 3'd0);
    s_ipl = sub_cmd_pend ? 3'd2 : (!ym_irq_n ? 3'd1 : 3'd0);
  end

  assign m_vpan = ~m_iack;   // autovector all interrupt acks
  assign s_vpan = ~s_iack;

  // ------------------------------------------------------------------
  // main CPU bus decode
  // ------------------------------------------------------------------
  // regions
  wire [23:0] m_ba = {m_a, 1'b0};
  wire m_sel_rom  = (m_ba < 24'h080000);
  wire m_sel_vdp  = (m_ba >= 24'h400000 && m_ba < 24'h480000);
  wire m_sel_ctl  = (m_ba >= 24'h800000 && m_ba < 24'h800002);
  wire m_sel_sr1  = (m_ba >= 24'hC00000 && m_ba < 24'hC08000);
  wire m_sel_io   = (m_ba >= 24'hE00000 && m_ba < 24'hE00008);
  wire m_sel_sr2  = (m_ba >= 24'hFE0000 && m_ba < 24'hFE4000);
  wire m_sel_sr3  = (m_ba >= 24'hFE4000);

  wire m_strobe = !m_asn && !(m_udsn && m_ldsn);
  wire [15:0] m_wmask = {{8{~m_udsn}}, {8{~m_ldsn}}};

  always_ff @(posedge clk)
    if (!rst_n) begin
      vdp_cs      <= 1'b0;
      vdp_addr    <= '0;
      vdp_rnw_r   <= 1'b1;
      vdp_be_r    <= 2'b00;
      vdp_wdata_r <= '0;
    end else begin
      vdp_cs      <= m_strobe && m_sel_vdp;
      vdp_addr    <= m_ba[18:0];
      vdp_rnw_r   <= m_rw;
      vdp_be_r    <= {~m_udsn, ~m_ldsn};
      vdp_wdata_r <= m_dout;
    end

  typedef enum logic [2:0] {MB_IDLE, MB_WAIT, MB_ROM, MB_SR3, MB_ACK} mb_e;
  mb_e mbst;
  logic [15:0] m_rdata_q;
  logic        m_wr_done;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      mbst <= MB_IDLE;
      m_wr_done <= 1'b0;
      o_mrom_rd <= 1'b0;
      sr3_m_req <= 1'b0;
      sub_rst <= 1'b1;         // sub held in reset at power-on
      sub_cmd_pend <= 1'b0;
      dbg_subctl <= 8'h00;
    end else begin
      // sub command ack
      if (s_iack && s_a[3:1] == 3'd2) sub_cmd_pend <= 1'b0;

      case (mbst)
        MB_IDLE: begin
          m_wr_done <= 1'b0;
          sr3_m_req <= 1'b0;
          if (m_strobe && !m_sel_vdp && !m_iack) begin
            if (m_rw) begin
              if (m_sel_rom) begin
                o_mrom_rd   <= 1'b1;
                o_mrom_addr <= m_ba[18:1];
                mbst <= MB_ROM;
              end else if (m_sel_sr3) begin
                sr3_m_req <= 1'b1;
                mbst <= MB_SR3;
              end else
                mbst <= MB_WAIT;   // registered reads settle next cycle
            end else begin
              // shared RAM writes (sr1/sr2 commit in TDP blocks below)
              if (m_sel_ctl && !m_ldsn) begin
                dbg_subctl <= m_dout[7:0];
                case (m_dout[7:0])
                  8'h01, 8'h0D, 8'h0F: sub_rst <= 1'b1;
                  8'h00:               sub_rst <= 1'b0;
                  8'h0C, 8'h80:        sub_cmd_pend <= 1'b1;
                  default: ;
                endcase
              end
              if (m_sel_sr3) begin
                sr3_m_req <= 1'b1;
                mbst <= MB_SR3;        // sr3 writes go through SDRAM
              end else
                mbst <= MB_ACK;
            end
          end
        end
        MB_ROM: begin
          o_mrom_rd <= 1'b0;
          if (i_mrom_valid) begin
            m_rdata_q <= i_mrom_data;
            mbst <= MB_ACK;
          end
        end
        MB_SR3: begin
          sr3_m_req <= 1'b1;
          if (sr3_m_ack) begin
            sr3_m_req <= 1'b0;
            if (m_rw) m_rdata_q <= i_sr3_rdata;
            mbst <= MB_ACK;
          end
        end
        MB_WAIT: begin
          if (m_sel_sr1) m_rdata_q <= sr1_q_a;
          else if (m_sel_sr2) m_rdata_q <= sr2_q_a;
          else if (m_sel_io) begin
            case (m_ba[2:1])
              2'd0: m_rdata_q <= i_service;
              2'd1: m_rdata_q <= i_dsw;
              2'd2: m_rdata_q <= i_p1p2;
              default: m_rdata_q <= i_system;
            endcase
          end else m_rdata_q <= 16'hFFFF;
          mbst <= MB_ACK;
        end
        MB_ACK: begin
          if (m_asn) mbst <= MB_IDLE;
        end
        default: mbst <= MB_IDLE;
      endcase
    end
  end

  assign m_din = m_sel_vdp ? vdp_rdata : m_rdata_q;
  assign m_dtackn = !((mbst == MB_ACK) || (m_sel_vdp && vdp_ack));

  // ------------------------------------------------------------------
  // sub CPU bus decode
  // ------------------------------------------------------------------
  wire [23:0] s_ba = {s_a, 1'b0};
  wire s_sel_vec  = (s_ba < 24'h004000);                       // shared1 shadow
  wire s_sel_ro3  = (s_ba >= 24'h004000 && s_ba < 24'h020000); // shared3 RO shadow
  wire s_sel_ym   = (s_ba >= 24'h400000 && s_ba < 24'h400004); // jt51
  wire s_sel_snd  = (s_ba >= 24'h400004 && s_ba < 24'h400010); // OKI stub
  wire s_sel_sr1  = (s_ba >= 24'hC00000 && s_ba < 24'hC08000);
  wire s_sel_sr2  = (s_ba >= 24'hFE0000 && s_ba < 24'hFE4000);
  wire s_sel_sr3  = (s_ba >= 24'hFE4000);

  wire s_strobe = !s_asn && !(s_udsn && s_ldsn);
  wire [15:0] s_wmask = {{8{~s_udsn}}, {8{~s_ldsn}}};

  typedef enum logic [1:0] {SB_IDLE, SB_WAIT, SB_SR3, SB_ACK} sb_e;
  sb_e sbst;
  logic [15:0] s_rdata_q;

  // ------------------------------------------------------------------
  // Sub-CPU shared3 read cache (1024 x 16-bit direct-mapped)
  // The real board uses dual-port SRAM with zero wait; our SDRAM adds
  // ~11 clocks per access. This cache serves sub-CPU reads in 1 clock
  // on hit, cutting the effective slowdown from ~10x to near-zero for
  // code loops and repeated data reads. Writes from either CPU
  // invalidate the matching line.
  // ------------------------------------------------------------------
  localparam int SR3C_AW = 10;  // 1024 entries
  localparam int SR3C_TW = 7;   // tag width = 17 - 10

  logic [15:0]       sr3c_data [0:1023];
  logic [SR3C_TW:0]  sr3c_tag  [0:1023]; // {valid, tag[6:0]}

  wire [SR3C_AW-1:0] sr3c_idx   = sr3_s_addr[SR3C_AW-1:0];
  wire [SR3C_TW-1:0] sr3c_stag  = sr3_s_addr[16:SR3C_AW];
  wire               sr3c_valid = sr3c_tag[sr3c_idx][SR3C_TW];
  wire               sr3c_match = sr3c_valid &&
                                  (sr3c_tag[sr3c_idx][SR3C_TW-1:0] == sr3c_stag);
  wire [15:0]        sr3c_rdata = sr3c_data[sr3c_idx];

  // main-CPU sr3 write invalidation: when the main CPU writes shared3,
  // invalidate the cache line at that address so the sub sees fresh data
  wire [SR3C_AW-1:0] sr3c_m_idx  = sr3_m_addr[SR3C_AW-1:0];
  wire               sr3c_m_inv  = sr3_m_ack && !m_rw;

  // sub-CPU sr3 write invalidation
  wire               sr3c_s_inv  = sr3_s_ack && !s_rw;

  integer sr3c_i;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (sr3c_i = 0; sr3c_i < 1024; sr3c_i = sr3c_i + 1)
        sr3c_tag[sr3c_i] <= '0;
    end else begin
      // fill on SDRAM read completion
      if (sr3_s_ack && s_rw) begin
        sr3c_data[sr3c_idx] <= i_sr3_rdata;
        sr3c_tag[sr3c_idx]  <= {1'b1, sr3c_stag};
      end
      // invalidate on writes from either CPU
      if (sr3c_m_inv)
        sr3c_tag[sr3c_m_idx] <= '0;
      if (sr3c_s_inv)
        sr3c_tag[sr3c_idx] <= '0;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      sbst <= SB_IDLE;
      sr3_s_req <= 1'b0;
    end else begin
      case (sbst)
        SB_IDLE: begin
          sr3_s_req <= 1'b0;
          if (s_strobe && !s_iack) begin
            if (s_rw) begin
              if (s_sel_ro3 || s_sel_sr3) begin
                if (sr3c_match) begin
                  s_rdata_q <= sr3c_rdata;
                  sbst <= SB_ACK;
                end else begin
                  sr3_s_req <= 1'b1;
                  sbst <= SB_SR3;
                end
              end else
                sbst <= SB_WAIT;
            end else begin
              if (s_sel_sr3) begin
                sr3_s_req <= 1'b1;
                sbst <= SB_SR3;
              end else
                sbst <= SB_ACK;
            end
          end
        end
        SB_WAIT: begin
          if (s_sel_vec)      s_rdata_q <= sr1_q_b;
          else if (s_sel_sr1) s_rdata_q <= sr1_q_b;
          else if (s_sel_sr2) s_rdata_q <= sr2_q_b;
          else if (s_sel_ym)  s_rdata_q <= {8'h00, ym_dout};
          else if (s_sel_snd) s_rdata_q <= {8'h00, oki_dout};
          else                s_rdata_q <= 16'hFFFF;
          sbst <= SB_ACK;
        end
        SB_SR3: begin
          sr3_s_req <= 1'b1;
          if (sr3_s_ack) begin
            sr3_s_req <= 1'b0;
            if (s_rw) s_rdata_q <= i_sr3_rdata;
            sbst <= SB_ACK;
          end
        end
        SB_ACK: begin
          if (s_asn) sbst <= SB_IDLE;
        end
        default: sbst <= SB_IDLE;
      endcase
    end
  end

  // jt51 / jt6295 write strobes: exactly the SB_IDLE commit cycle
  always_comb begin
    ym_cs_n = !(sbst == SB_IDLE && s_strobe && s_sel_ym && !s_iack);
    ym_wr_n = s_rw;
    ym_a0   = s_a[1];
    ym_din  = s_dout[7:0];
    oki_wrn = !(sbst == SB_IDLE && s_strobe && s_sel_snd && !s_rw && !s_iack);
    oki_din = s_dout[7:0];
  end

  assign s_din = s_rdata_q;
  assign s_dtackn = !(sbst == SB_ACK);

  // ------------------------------------------------------------------
  // shared RAM TDP ports (port A = main, port B = sub)
  // shared1/shared2 stay in BRAM; shared3 moved to SDRAM
  // ------------------------------------------------------------------
  logic [13:0] sr1_addr_a, sr1_addr_b;
  logic [12:0] sr2_addr_a, sr2_addr_b;
  logic        sr1_we_a, sr1_we_b, sr2_we_a, sr2_we_b;
  logic [15:0] sr1_q_a, sr1_q_b, sr2_q_a, sr2_q_b;

  wire m_wr_commit = (mbst == MB_IDLE) && m_strobe && !m_sel_vdp
                     && !m_iack && !m_rw;
  wire s_wr_commit = (sbst == SB_IDLE) && s_strobe && !s_iack && !s_rw;

  assign sr1_addr_a = m_ba[14:1];
  assign sr2_addr_a = m_ba[13:1];
  assign sr1_we_a = m_wr_commit && m_sel_sr1;
  assign sr2_we_a = m_wr_commit && m_sel_sr2;

  assign sr1_addr_b = s_sel_vec ? {2'b00, s_ba[13:1]} : s_ba[14:1];
  assign sr2_addr_b = s_ba[13:1];
  assign sr1_we_b = s_wr_commit && (s_sel_vec || s_sel_sr1);
  assign sr2_we_b = s_wr_commit && s_sel_sr2;


  hd_tdpram #(.AW(14), .DW(16)) u_shared1 (
    .clk(clk),
    .addr_a(sr1_addr_a), .d_a(m_dout), .we_a(sr1_we_a),
    .be_a({~m_udsn, ~m_ldsn}), .q_a(sr1_q_a),
    .addr_b(sr1_addr_b), .d_b(s_dout), .we_b(sr1_we_b),
    .be_b({~s_udsn, ~s_ldsn}), .q_b(sr1_q_b)
  );

  hd_tdpram #(.AW(13), .DW(16)) u_shared2 (
    .clk(clk),
    .addr_a(sr2_addr_a), .d_a(m_dout), .we_a(sr2_we_a),
    .be_a({~m_udsn, ~m_ldsn}), .q_a(sr2_q_a),
    .addr_b(sr2_addr_b), .d_b(s_dout), .we_b(sr2_we_b),
    .be_b({~s_udsn, ~s_ldsn}), .q_b(sr2_q_b)
  );

  // ------------------------------------------------------------------
  // shared3 SDRAM arbiter (two CPUs, one SDRAM port)
  // Round-robin: the real board uses dual-port SRAM with zero wait for
  // both CPUs. Our serial SDRAM port must emulate that fairness or the
  // sub-CPU (which fetches every instruction from sr3) starves under
  // main-CPU traffic, causing frozen game state and speed surges.
  // After each grant, the "last served" flag flips so the other CPU
  // wins on the next simultaneous request.
  // ------------------------------------------------------------------
  logic sr3_m_req, sr3_s_req;      // level-held by each FSM while in MB_SR3/SB_SR3
  logic sr3_grant_s;               // 0 = main granted (or idle), 1 = sub granted

  // address computation (reuses the original mapping)
  wire [16:0] sr3_m_addr = m_ba[17:1] - 17'h2000;
  // shadow 0x4000-0x1FFFF aliases 0xFE4000-0xFFFFFF (same sr3 words):
  // shadow byte A corresponds to main byte (A - 0x4000 + 0xFE4000),
  // so sr3 word = s_ba[17:1] + 0xE000 for the shadow window
  wire [16:0] sr3_s_addr = s_sel_ro3 ? (s_ba[17:1] + 17'hE000)
                                     : (s_ba[17:1] - 17'h2000);

  // grant decided while idle, held for the whole op; o_sr3_req is
  // registered so the addr/wdata/we mux is stable before the SDRAM
  // controller can latch the op
  logic sr3_infly;
  logic sr3_req_r;
  logic sr3_last_s;                // 1 = sub was last served; toggles per grant
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      sr3_grant_s <= 1'b0; sr3_infly <= 1'b0; sr3_req_r <= 1'b0;
      sr3_last_s <= 1'b0;
    end else if (sr3_infly) begin
      if (i_sr3_ack) begin
        sr3_infly <= 1'b0; sr3_req_r <= 1'b0;
      end
    end else begin
      if (sr3_m_req && sr3_s_req) begin
        // both want: serve whoever was NOT served last (round-robin)
        sr3_grant_s <= sr3_last_s ? 1'b0 : 1'b1;
        sr3_last_s  <= sr3_last_s ? 1'b0 : 1'b1;
        sr3_infly   <= 1'b1; sr3_req_r <= 1'b1;
      end else if (sr3_m_req) begin
        sr3_grant_s <= 1'b0; sr3_last_s <= 1'b0;
        sr3_infly <= 1'b1; sr3_req_r <= 1'b1;
      end else if (sr3_s_req) begin
        sr3_grant_s <= 1'b1; sr3_last_s <= 1'b1;
        sr3_infly <= 1'b1; sr3_req_r <= 1'b1;
      end
    end
  end

  wire sr3_m_ack = i_sr3_ack && !sr3_grant_s;
  wire sr3_s_ack = i_sr3_ack && sr3_grant_s;

  assign o_sr3_req = sr3_req_r;

  assign o_sr3_addr  = sr3_grant_s ? sr3_s_addr  : sr3_m_addr;
  assign o_sr3_wdata = sr3_grant_s ? s_dout      : m_dout;
  assign o_sr3_be    = sr3_grant_s ? {~s_udsn, ~s_ldsn} : {~m_udsn, ~m_ldsn};
  assign o_sr3_we    = sr3_grant_s ? (s_strobe && !s_rw) : (m_strobe && !m_rw);

  // bring-up probes: sub-side sr3 grants, handshake word snoop, YM iacks
  logic s_iack_d1;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      dbg_sack_cnt <= '0; dbg_hshk <= 16'hDEAD; dbg_iack1 <= '0; s_iack_d1 <= 1'b0;
    end else begin
      if (sr3_s_ack) dbg_sack_cnt <= dbg_sack_cnt + 16'd1;
      // byte 0xFFF34C -> sr3 word addr (0xFFF34C[17:1]) - 0x2000 = 0x1D9A6
      if (i_sr3_ack && o_sr3_we && o_sr3_addr == 17'h1D9A6)
        dbg_hshk <= o_sr3_wdata;
      s_iack_d1 <= s_iack;
      if (s_iack && !s_iack_d1 && s_a[3:1] == 3'd1)
        dbg_iack1 <= dbg_iack1 + 8'd1;
    end
  end

  // copy-phase probes: GFX-window (0x460000+) reads and main sr3 reads
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      dbg_wadr <= '0; dbg_wcnt <= '0; dbg_srrc <= '0;
      dbg_wda[0] <= '0; dbg_wda[1] <= '0; dbg_wda[2] <= '0; dbg_wda[3] <= '0;
      dbg_b3e_w0 <= 16'hDEAD; dbg_b3e_w1 <= 16'hDEAD; dbg_bank <= '0;
    end else begin
      if (vdp_cs && vdp_ack && vdp_rnw_r && vdp_addr[18:17] == 2'b11) begin
        dbg_wadr <= vdp_addr[16:1];
        dbg_wcnt <= dbg_wcnt + 16'd1;
        if (vdp_addr[16:3] == 14'd0)
          dbg_wda[vdp_addr[2:1]] <= vdp_rdata;
        // bank-gated capture: first words 0/1 seen while bank == 0x3E
        if (dbg_bank[7:0] == 8'h3E && vdp_addr[16:1] == 16'd0 && dbg_b3e_w0 == 16'hDEAD)
          dbg_b3e_w0 <= vdp_rdata;
        if (dbg_bank[7:0] == 8'h3E && vdp_addr[16:1] == 16'd1 && dbg_b3e_w1 == 16'hDEAD)
          dbg_b3e_w1 <= vdp_rdata;
      end
      if (vdp_cs && vdp_ack && !vdp_rnw_r && vdp_addr == 19'h788AA)
        dbg_bank <= {dbg_bank[15:8] + 8'd1, vdp_wdata_r[7:0]};
      if (sr3_m_ack && m_rw) dbg_srrc <= dbg_srrc + 16'd1;
    end
  end

endmodule
