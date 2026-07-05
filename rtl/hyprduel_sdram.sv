// SDRAM controller + ROM arbiter for the Hyper Duel core.
//
// Serves hyprduel_sys's three read clients from one 16-bit SDRAM
// (MiSTer 32 MB module baseline: 4 banks x 8192 rows x 512 cols) plus
// the ioctl download write path:
//
//   priority 0  GFX stream  (i_gfx_req/addr/len -> len byte pulses)
//   priority 1  main 68000 ROM (single word, req/valid)
//   priority 2  OKI sample ROM (jt-style addr/ok, byte held stable)
//   refresh     slots into idle gaps, forced ahead of grants if overdue
//   download    byte writes via DQM masks (highest priority; the core
//               is held in reset during loading anyway)
//
// SDRAM byte map (matches mister/README.md and the MRA):
//   0x000000 main ROM (512 KB)   0x080000 GFX ROM (4 MB)
//   0x480000 OKI samples (256 KB)
//
// Policy: close-page. Every access is ACT, tRCD, CAS(+auto precharge
// on the last read), so banks are always precharged and refresh can
// slot in whenever the FSM is idle. A GFX stream is up to 64 bytes =
// 33 words; reads issue back-to-back (one word per cycle after CL2)
// and byte pulses drain from a small FIFO at one per cycle. Streams
// crossing a 512-word row boundary re-activate internally.
//
// Byte lanes follow the 68000/build_mainrom.py convention everywhere:
// even byte address = word[15:8], odd byte address = word[7:0].
//
// Timing at 80 MHz CL2: tRCD/tRP = 2 cycles, tRFC = 8, refresh every
// 625 cycles (64 ms / 8192 rows). On hardware SDRAM_CLK is the
// PLL-phase-shifted copy of clk (set in the .qsf); if board-level
// capture needs an extra cycle, bump P_RET by one.

module hyprduel_sdram #(
    parameter bit P_SHORT_INIT = 1'b0,  // sim: skip the 100 us power-up wait
    parameter int P_RET = 3             // CAS cmd reg -> dq_in reg, cycles
) (
    input  logic        clk,
    input  logic        rst_n,
    output logic        o_ready,        // init done

    // GFX ROM stream client (byte addresses within the 4 MB region)
    input  logic        i_gfx_req,      // 1-cycle pulse; addr/len then stable
    input  logic [21:0] i_gfx_addr,
    input  logic [6:0]  i_gfx_len,      // bytes, 1..64
    output logic [7:0]  o_gfx_data,
    output logic        o_gfx_valid,

    // main 68000 ROM client (word address within 512 KB)
    input  logic        i_mrom_rd,      // 1-cycle pulse
    input  logic [17:0] i_mrom_addr,
    output logic [15:0] o_mrom_data,
    output logic        o_mrom_valid,

    // OKI sample ROM client (byte address within 256 KB, jt ok-style)
    input  logic [17:0] i_oki_addr,
    output logic [7:0]  o_oki_data,
    output logic        o_oki_ok,

    // download write port (byte writes)
    input  logic        i_dl_wr,        // 1-cycle pulse per byte
    input  logic [24:0] i_dl_addr,      // byte address in SDRAM space
    input  logic [7:0]  i_dl_data,
    output logic        o_dl_busy,

    // SDRAM pins
    output logic [12:0] SDRAM_A,
    output logic [1:0]  SDRAM_BA,
    inout  wire  [15:0] SDRAM_DQ,
    output logic        SDRAM_DQML,
    output logic        SDRAM_DQMH,
    output logic        SDRAM_nCS,
    output logic        SDRAM_nRAS,
    output logic        SDRAM_nCAS,
    output logic        SDRAM_nWE,
    output logic        SDRAM_CKE
);

  // word-address bases (byte base / 2)
  localparam logic [23:0] MROM_WBASE = 24'h000000;
  localparam logic [23:0] GFX_WBASE  = 24'h040000;
  localparam logic [23:0] OKI_WBASE  = 24'h240000;

  // command encoding {nCS, nRAS, nCAS, nWE}
  localparam logic [3:0] CMD_NOP  = 4'b0111;
  localparam logic [3:0] CMD_ACT  = 4'b0011;
  localparam logic [3:0] CMD_READ = 4'b0101;
  localparam logic [3:0] CMD_WRIT = 4'b0100;
  localparam logic [3:0] CMD_PALL = 4'b0010;
  localparam logic [3:0] CMD_REF  = 4'b0001;
  localparam logic [3:0] CMD_MODE = 4'b0000;

  localparam logic [12:0] MODE_REG = 13'h020;   // BL1, sequential, CL2

  localparam int REFRESH_PERIOD = 625;          // 7.8125 us at 80 MHz
  localparam int INIT_WAIT = P_SHORT_INIT ? 32 : 8000;

  // initialized so the pins never show a live command (4'b0000 = MODE)
  // before the first clock edge
  logic [3:0] cmd = CMD_NOP;
  assign {SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} = cmd;
  assign SDRAM_CKE = 1'b1;

  logic [15:0] dq_out;
  logic        dq_oe;
  assign SDRAM_DQ = dq_oe ? dq_out : 16'hzzzz;

  logic [15:0] dq_in;
  always_ff @(posedge clk) dq_in <= SDRAM_DQ;

  // ------------------------------------------------------------------
  // read-return tag pipeline: written by the FSM at CAS issue, lands
  // in sync with dq_in P_RET cycles later. 0 none, 1 gfx, 2 mrom, 3 oki
  // ------------------------------------------------------------------
  logic [1:0] ret_tag [P_RET+1];
  always_ff @(posedge clk)
    for (int i = P_RET; i > 0; i--) ret_tag[i] <= ret_tag[i-1];
  wire [1:0] land_tag = ret_tag[P_RET];

  // ------------------------------------------------------------------
  // main FSM (single driver for: cmd/addr/dqm, state, pends, refresh)
  // ------------------------------------------------------------------
  typedef enum logic [3:0] {
    ST_INIT_WAIT, ST_INIT_PALL, ST_INIT_REF1, ST_INIT_REF2, ST_INIT_MODE,
    ST_IDLE, ST_ACT, ST_RCD, ST_CAS, ST_ROWGAP, ST_WWAIT, ST_RFC
  } st_e;
  st_e st;

  typedef enum logic [1:0] {OWN_GFX, OWN_MROM, OWN_OKI, OWN_DL} own_e;
  own_e owner;

  logic        gfx_pend, mrom_pend, oki_pend, dl_pend;
  logic [21:0] gfx_addr_q;
  logic [6:0]  gfx_len_q;
  logic [17:0] mrom_addr_q;
  logic [17:0] oki_addr_q;
  logic [24:0] dl_addr_q;
  logic [7:0]  dl_data_q;
  logic        gfx_start;          // pulse to the byte-path block

  logic [23:0] cur_word;
  logic [6:0]  words_left;         // words remaining in the whole request
  logic [5:0]  cas_left;           // words remaining in this activation
  logic [3:0]  wait_cnt;
  logic [12:0] init_cnt;

  logic [9:0]  ref_cnt;
  logic        ref_due, ref_urgent;

  // gfx byte-path backpressure (from the block below)
  logic        bf_room;

  // oki request detection: serve whenever addr differs from last served
  logic        oki_have;
  logic [17:0] oki_served;
  wire oki_want = !oki_have || (i_oki_addr != oki_served);

  wire [9:0] col_room = 10'd512 - {1'b0, cur_word[8:0]};

  always_ff @(posedge clk) begin
    cmd        <= CMD_NOP;
    SDRAM_A    <= '0;
    SDRAM_BA   <= cur_word[23:22];
    dq_oe      <= 1'b0;
    ret_tag[0] <= 2'd0;
    gfx_start  <= 1'b0;

    if (!rst_n) begin
      st <= ST_INIT_WAIT;
      owner <= OWN_GFX;
      o_ready <= 1'b0;
      gfx_pend <= 1'b0; mrom_pend <= 1'b0;
      oki_pend <= 1'b0; dl_pend <= 1'b0;
      init_cnt <= '0; wait_cnt <= '0;
      cur_word <= '0; words_left <= '0; cas_left <= '0;
      ref_cnt <= '0; ref_due <= 1'b0; ref_urgent <= 1'b0;
      SDRAM_DQML <= 1'b1; SDRAM_DQMH <= 1'b1;
    end else begin
      // refresh bookkeeping
      if (32'(ref_cnt) == REFRESH_PERIOD - 1) begin
        ref_cnt <= '0;
        ref_urgent <= ref_due;
        ref_due <= 1'b1;
      end else
        ref_cnt <= ref_cnt + 1'b1;

      // latch incoming requests (any state)
      if (i_gfx_req) begin
        gfx_pend <= 1'b1; gfx_addr_q <= i_gfx_addr; gfx_len_q <= i_gfx_len;
      end
      if (i_mrom_rd) begin
        mrom_pend <= 1'b1; mrom_addr_q <= i_mrom_addr;
      end
      if (i_dl_wr) begin
        dl_pend <= 1'b1; dl_addr_q <= i_dl_addr; dl_data_q <= i_dl_data;
      end
      if (oki_want && !oki_pend && st == ST_IDLE) begin
        oki_pend <= 1'b1; oki_addr_q <= i_oki_addr;
      end

      case (st)
        // ---------------- init ----------------
        ST_INIT_WAIT: begin
          SDRAM_DQML <= 1'b1; SDRAM_DQMH <= 1'b1;
          init_cnt <= init_cnt + 1'b1;
          if (32'(init_cnt) == INIT_WAIT) st <= ST_INIT_PALL;
        end
        ST_INIT_PALL: begin
          cmd <= CMD_PALL; SDRAM_A <= 13'h400;
          wait_cnt <= 4'd2; st <= ST_INIT_REF1;
        end
        ST_INIT_REF1:
          if (wait_cnt != 0) wait_cnt <= wait_cnt - 1'b1;
          else begin cmd <= CMD_REF; wait_cnt <= 4'd8; st <= ST_INIT_REF2; end
        ST_INIT_REF2:
          if (wait_cnt != 0) wait_cnt <= wait_cnt - 1'b1;
          else begin cmd <= CMD_REF; wait_cnt <= 4'd8; st <= ST_INIT_MODE; end
        ST_INIT_MODE:
          if (wait_cnt != 0) wait_cnt <= wait_cnt - 1'b1;
          else begin
            cmd <= CMD_MODE; SDRAM_A <= MODE_REG; SDRAM_BA <= 2'b00;
            wait_cnt <= 4'd2; st <= ST_IDLE; o_ready <= 1'b1;
          end

        // ---------------- grant ----------------
        ST_IDLE: begin
          SDRAM_DQML <= 1'b0; SDRAM_DQMH <= 1'b0;
          if (wait_cnt != 0) wait_cnt <= wait_cnt - 1'b1;
          else if (ref_urgent || (ref_due && !gfx_pend && !mrom_pend
                                  && !oki_pend && !dl_pend)) begin
            cmd <= CMD_REF;
            ref_due <= 1'b0; ref_urgent <= 1'b0;
            wait_cnt <= 4'd8; st <= ST_RFC;
          end else if (dl_pend) begin
            owner <= OWN_DL;
            cur_word <= dl_addr_q[24:1];
            st <= ST_ACT;
          end else if (gfx_pend) begin
            owner <= OWN_GFX;
            cur_word <= GFX_WBASE + 24'(gfx_addr_q[21:1]);
            // ceil((start_is_odd + len) / 2) words cover the byte span
            words_left <= 7'((8'(gfx_addr_q[0]) + 8'(gfx_len_q) + 8'd1) >> 1);
            gfx_start <= 1'b1;
            st <= ST_ACT;
          end else if (mrom_pend) begin
            owner <= OWN_MROM;
            cur_word <= MROM_WBASE + 24'(mrom_addr_q);
            words_left <= 7'd1;
            st <= ST_ACT;
          end else if (oki_pend) begin
            owner <= OWN_OKI;
            cur_word <= OKI_WBASE + 24'(oki_addr_q[17:1]);
            words_left <= 7'd1;
            st <= ST_ACT;
          end
        end

        // ---------------- access ----------------
        ST_ACT: begin
          cmd <= CMD_ACT;
          SDRAM_A <= cur_word[21:9];
          cas_left <= (owner == OWN_GFX)
                      ? ((13'(words_left) > 13'(col_room))
                         ? 6'(col_room) : 6'(words_left))
                      : 6'd1;
          st <= ST_RCD;
        end
        ST_RCD: st <= ST_CAS;       // tRCD = 2 cycles (ACT, this, CAS)
        ST_CAS: begin
          if (owner == OWN_DL) begin
            cmd <= CMD_WRIT; dq_oe <= 1'b1;
            dq_out <= {dl_data_q, dl_data_q};
            SDRAM_A <= {4'b0010, cur_word[8:0]};     // A10 = auto precharge
            // even byte address = high lane; DQM=1 masks the other lane
            SDRAM_DQML <= !dl_addr_q[0];
            SDRAM_DQMH <=  dl_addr_q[0];
            dl_pend <= 1'b0;
            wait_cnt <= 4'd3;                        // tWR + tRP
            st <= ST_WWAIT;
          end else if (owner != OWN_GFX || bf_room) begin
            cmd <= CMD_READ;
            SDRAM_A <= {(cas_left == 6'd1) ? 4'b0010 : 4'b0000,
                        cur_word[8:0]};              // AP on the last CAS
            ret_tag[0] <= (owner == OWN_GFX)  ? 2'd1 :
                          (owner == OWN_MROM) ? 2'd2 : 2'd3;
            cur_word <= cur_word + 24'd1;
            words_left <= words_left - 7'd1;
            cas_left <= cas_left - 6'd1;
            if (cas_left == 6'd1) begin
              if (owner == OWN_GFX && words_left != 7'd1) begin
                wait_cnt <= 4'd1;                    // tRP after AP
                st <= ST_ROWGAP;                     // row-crossing re-ACT
              end else begin
                if (owner == OWN_GFX)  gfx_pend  <= 1'b0;
                if (owner == OWN_MROM) mrom_pend <= 1'b0;
                if (owner == OWN_OKI)  oki_pend  <= 1'b0;
                wait_cnt <= 4'd2;                    // cover tRP
                st <= ST_IDLE;
              end
            end
          end
          // else: gfx FIFO lacks room, stall with NOP (row stays open)
        end
        ST_ROWGAP:
          if (wait_cnt != 0) wait_cnt <= wait_cnt - 1'b1;
          else st <= ST_ACT;
        ST_WWAIT: begin
          SDRAM_DQML <= 1'b0; SDRAM_DQMH <= 1'b0;
          if (wait_cnt != 0) wait_cnt <= wait_cnt - 1'b1;
          else st <= ST_IDLE;
        end
        ST_RFC:
          if (wait_cnt != 0) wait_cnt <= wait_cnt - 1'b1;
          else st <= ST_IDLE;
        default: st <= ST_IDLE;
      endcase
    end
  end

  // ------------------------------------------------------------------
  // mrom / oki landing (single driver for their outputs)
  // ------------------------------------------------------------------
  always_ff @(posedge clk) begin
    o_mrom_valid <= 1'b0;
    if (!rst_n) begin
      oki_have <= 1'b0; oki_served <= '0;
      o_mrom_data <= '0; o_oki_data <= '0;
    end else begin
      if (land_tag == 2'd2) begin
        o_mrom_data <= dq_in;
        o_mrom_valid <= 1'b1;
      end
      if (land_tag == 2'd3) begin
        o_oki_data <= oki_addr_q[0] ? dq_in[7:0] : dq_in[15:8];
        oki_served <= oki_addr_q;
        oki_have <= 1'b1;
      end
    end
  end
  // ok is only presented while the requester's address matches what we
  // hold, so an address change drops ok on the same cycle (jt style)
  assign o_oki_ok = oki_have && (i_oki_addr == oki_served);

  // ------------------------------------------------------------------
  // gfx byte path (single driver for FIFO + byte emit state)
  // 16-word FIFO; the FSM stalls CAS when fewer than 12 slots remain,
  // covering the P_RET words already in flight.
  // ------------------------------------------------------------------
  logic [15:0] bfifo [16];
  logic [3:0]  bf_wp, bf_rp;
  logic [4:0]  bf_cnt;
  logic        bf_hi;              // next byte from high lane (even addr)
  logic [6:0]  gfx_left;
  logic        skip_first;         // odd start address: drop first byte

  assign bf_room = (bf_cnt < 5'd12);

  always_ff @(posedge clk) begin
    logic push, pop;
    push = 1'b0; pop = 1'b0;
    o_gfx_valid <= 1'b0;

    if (!rst_n) begin
      bf_wp <= '0; bf_rp <= '0; bf_cnt <= '0;
      bf_hi <= 1'b1; gfx_left <= '0; skip_first <= 1'b0;
      o_gfx_data <= '0;
    end else begin
      if (gfx_start) begin
        bf_wp <= '0; bf_rp <= '0; bf_cnt <= '0;
        bf_hi <= 1'b1;
        gfx_left <= gfx_len_q;
        skip_first <= gfx_addr_q[0];
      end else begin
        if (land_tag == 2'd1) begin
          bfifo[bf_wp] <= dq_in;
          bf_wp <= bf_wp + 1'b1;
          push = 1'b1;
        end
        if (bf_cnt != 0 && gfx_left != 0) begin
          if (skip_first) begin
            skip_first <= 1'b0;
            bf_hi <= 1'b0;         // word stays; low lane is byte one
          end else begin
            o_gfx_data <= bf_hi ? bfifo[bf_rp][15:8] : bfifo[bf_rp][7:0];
            o_gfx_valid <= 1'b1;
            gfx_left <= gfx_left - 7'd1;
            bf_hi <= !bf_hi;
            if (!bf_hi || gfx_left == 7'd1) begin
              bf_rp <= bf_rp + 1'b1; // low lane emitted (or stream done)
              pop = 1'b1;
            end
          end
        end
        case ({push, pop})
          2'b10: bf_cnt <= bf_cnt + 1'b1;
          2'b01: bf_cnt <= bf_cnt - 1'b1;
          default: ;
        endcase
      end
    end
  end

  assign o_dl_busy = dl_pend;

endmodule
