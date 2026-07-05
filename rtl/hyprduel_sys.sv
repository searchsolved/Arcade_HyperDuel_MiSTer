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

    // GFX ROM stream port
    output logic              o_rom_req,
    output logic [GFX_AW-1:0] o_rom_addr,
    output logic [6:0]        o_rom_len,
    input  logic [7:0]        i_rom_data,
    input  logic              i_rom_valid,
    input  logic [23:0]       i_gfx_size,

    // debug
    output logic [7:0] dbg_subctl,
    output logic       dbg_sub_in_reset
);

  // ------------------------------------------------------------------
  // memories
  // ------------------------------------------------------------------
  // True dual-port shared RAMs: port A = main CPU, port B = sub CPU.
  // Reads and writes for both ports live in ONE always block per memory
  // (Intel single-clock TDP template) so Quartus infers M10K; writes use
  // byte-enable part-selects, reads land in continuously-updated q regs
  // that the bus FSMs consume one state later (addresses are stable from
  // the strobe cycle, so the q value matches the old direct read).
  logic [15:0] shared1 [0:16383];     // 32 KB (sub vectors live here)
  logic [15:0] shared2 [0:8191];      // 16 KB
  logic [15:0] shared3 [0:57343];     // 112 KB


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
  logic [15:0] vdp_rdata;
  logic        vdp_ack;
  logic        vdp_irq, vbl_pulse;

  i4220_vdp #(.GFX_AW(GFX_AW), .P_PIXDIV(P_PIXDIV),
              .P_BIT5_CYCLES(2500 * P_PIXDIV * 20 / 3),
              .P_IRQ_LINE_MASK(8'h02)) u_vdp (
    // 2500 us at the sys clock implied by P_PIXDIV vs the 6.667 MHz pixel
    .clk(clk), .rst_n(rst_n),
    .i_cs(vdp_cs), .i_addr(vdp_addr), .i_rnw(m_rw),
    .i_be({~m_udsn, ~m_ldsn}), .i_wdata(m_dout),
    .o_rdata(vdp_rdata), .o_ack(vdp_ack),
    .o_hs(o_hs), .o_vs(o_vs), .o_de(o_de), .o_ce_pix(o_ce_pix),
    .o_hblank(o_hblank), .o_vblank(o_vblank),
    .o_r(o_r), .o_g(o_g), .o_b(o_b),
    .o_irq(vdp_irq), .o_vbl_pulse(vbl_pulse),
    .o_rom_req(o_rom_req), .o_rom_addr(o_rom_addr), .o_rom_len(o_rom_len),
    .i_rom_data(i_rom_data), .i_rom_valid(i_rom_valid),
    .i_gfx_size(i_gfx_size)
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

  assign vdp_cs   = m_strobe && m_sel_vdp;
  assign vdp_addr = m_ba[18:0];

  typedef enum logic [1:0] {MB_IDLE, MB_WAIT, MB_ROM, MB_ACK} mb_e;
  mb_e mbst;
  logic [15:0] m_rdata_q;
  logic        m_wr_done;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      mbst <= MB_IDLE;
      m_wr_done <= 1'b0;
      o_mrom_rd <= 1'b0;
      sub_rst <= 1'b1;         // sub held in reset at power-on
      sub_cmd_pend <= 1'b0;
      dbg_subctl <= 8'h00;
    end else begin
      // sub command ack
      if (s_iack && s_a[3:1] == 3'd2) sub_cmd_pend <= 1'b0;

      case (mbst)
        MB_IDLE: begin
          m_wr_done <= 1'b0;
          if (m_strobe && !m_sel_vdp && !m_iack) begin
            if (m_rw) begin
              if (m_sel_rom) begin
                o_mrom_rd   <= 1'b1;
                o_mrom_addr <= m_ba[18:1];
                mbst <= MB_ROM;
              end else
                mbst <= MB_WAIT;   // registered reads settle next cycle
            end else begin
              // shared RAM writes commit in the TDP blocks below
              if (m_sel_ctl && !m_ldsn) begin
                dbg_subctl <= m_dout[7:0];
                case (m_dout[7:0])
                  8'h01, 8'h0D, 8'h0F: sub_rst <= 1'b1;
                  8'h00:               sub_rst <= 1'b0;
                  8'h0C, 8'h80:        sub_cmd_pend <= 1'b1;
                  default: ;
                endcase
              end
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
        MB_WAIT: begin
          if (m_sel_sr1) m_rdata_q <= sr1_q_a;
          else if (m_sel_sr2) m_rdata_q <= sr2_q_a;
          else if (m_sel_sr3) m_rdata_q <= sr3_q_a;
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
  wire s_sel_ro3  = (s_ba >= 24'h004000 && s_ba < 24'h008000); // shared3 RO shadow
  wire s_sel_ym   = (s_ba >= 24'h400000 && s_ba < 24'h400004); // jt51
  wire s_sel_snd  = (s_ba >= 24'h400004 && s_ba < 24'h400010); // OKI stub
  wire s_sel_sr1  = (s_ba >= 24'hC00000 && s_ba < 24'hC08000);
  wire s_sel_sr2  = (s_ba >= 24'hFE0000 && s_ba < 24'hFE4000);
  wire s_sel_sr3  = (s_ba >= 24'hFE4000);

  wire s_strobe = !s_asn && !(s_udsn && s_ldsn);
  wire [15:0] s_wmask = {{8{~s_udsn}}, {8{~s_ldsn}}};

  typedef enum logic [1:0] {SB_IDLE, SB_WAIT, SB_ACK} sb_e;
  sb_e sbst;
  logic [15:0] s_rdata_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      sbst <= SB_IDLE;
    end else begin
      case (sbst)
        SB_IDLE: begin
          if (s_strobe && !s_iack) begin
            if (s_rw) begin
              sbst <= SB_WAIT;
            end else begin
              // shared RAM writes commit in the TDP blocks below
              // (s_sel_ro3 writes ignored: read-only shadow)
              // s_sel_snd writes ignored (sound stubs)
              sbst <= SB_ACK;
            end
          end
        end
        SB_WAIT: begin
          if (s_sel_vec)      s_rdata_q <= sr1_q_b;
          else if (s_sel_ro3) s_rdata_q <= sr3_q_b;
          else if (s_sel_sr1) s_rdata_q <= sr1_q_b;
          else if (s_sel_sr2) s_rdata_q <= sr2_q_b;
          else if (s_sel_sr3) s_rdata_q <= sr3_q_b;
          else if (s_sel_ym)  s_rdata_q <= {8'h00, ym_dout};
          else if (s_sel_snd) s_rdata_q <= {8'h00, oki_dout};
          else                s_rdata_q <= 16'hFFFF;
          sbst <= SB_ACK;
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
  // ------------------------------------------------------------------
  logic [13:0] sr1_addr_a, sr1_addr_b;
  logic [12:0] sr2_addr_a, sr2_addr_b;
  logic [16:0] sr3_addr_a, sr3_addr_b;
  logic        sr1_we_a, sr1_we_b, sr2_we_a, sr2_we_b, sr3_we_a, sr3_we_b;
  logic [15:0] sr1_q_a, sr1_q_b, sr2_q_a, sr2_q_b, sr3_q_a, sr3_q_b;

  wire m_wr_commit = (mbst == MB_IDLE) && m_strobe && !m_sel_vdp
                     && !m_iack && !m_rw;
  wire s_wr_commit = (sbst == SB_IDLE) && s_strobe && !s_iack && !s_rw;

  assign sr1_addr_a = m_ba[14:1];
  assign sr2_addr_a = m_ba[13:1];
  assign sr3_addr_a = m_ba[17:1] - 17'h2000;
  assign sr1_we_a = m_wr_commit && m_sel_sr1;
  assign sr2_we_a = m_wr_commit && m_sel_sr2;
  assign sr3_we_a = m_wr_commit && m_sel_sr3;

  assign sr1_addr_b = s_sel_vec ? {2'b00, s_ba[13:1]} : s_ba[14:1];
  assign sr2_addr_b = s_ba[13:1];
  assign sr3_addr_b = s_sel_ro3 ? {4'b0000, s_ba[13:1]}
                                : (s_ba[17:1] - 17'h2000);
  assign sr1_we_b = s_wr_commit && (s_sel_vec || s_sel_sr1);
  assign sr2_we_b = s_wr_commit && s_sel_sr2;
  assign sr3_we_b = s_wr_commit && s_sel_sr3;


  always_ff @(posedge clk) begin
    if (sr1_we_a) begin
      if (!m_udsn) shared1[sr1_addr_a][15:8] <= m_dout[15:8];
      if (!m_ldsn) shared1[sr1_addr_a][7:0]  <= m_dout[7:0];
    end
    sr1_q_a <= shared1[sr1_addr_a];
    if (sr1_we_b) begin
      if (!s_udsn) shared1[sr1_addr_b][15:8] <= s_dout[15:8];
      if (!s_ldsn) shared1[sr1_addr_b][7:0]  <= s_dout[7:0];
    end
    sr1_q_b <= shared1[sr1_addr_b];
  end

  always_ff @(posedge clk) begin
    if (sr2_we_a) begin
      if (!m_udsn) shared2[sr2_addr_a][15:8] <= m_dout[15:8];
      if (!m_ldsn) shared2[sr2_addr_a][7:0]  <= m_dout[7:0];
    end
    sr2_q_a <= shared2[sr2_addr_a];
    if (sr2_we_b) begin
      if (!s_udsn) shared2[sr2_addr_b][15:8] <= s_dout[15:8];
      if (!s_ldsn) shared2[sr2_addr_b][7:0]  <= s_dout[7:0];
    end
    sr2_q_b <= shared2[sr2_addr_b];
  end

  always_ff @(posedge clk) begin
    if (sr3_we_a) begin
      if (!m_udsn) shared3[sr3_addr_a][15:8] <= m_dout[15:8];
      if (!m_ldsn) shared3[sr3_addr_a][7:0]  <= m_dout[7:0];
    end
    sr3_q_a <= shared3[sr3_addr_a];
    if (sr3_we_b) begin
      if (!s_udsn) shared3[sr3_addr_b][15:8] <= s_dout[15:8];
      if (!s_ldsn) shared3[sr3_addr_b][7:0]  <= s_dout[7:0];
    end
    sr3_q_b <= shared3[sr3_addr_b];
  end

endmodule
