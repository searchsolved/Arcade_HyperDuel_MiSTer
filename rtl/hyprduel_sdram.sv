// SDRAM controller + ROM arbiter for the Hyper Duel core.
//
// Serves hyprduel_sys's three read clients plus a CPU shared-RAM port
// from one 16-bit SDRAM (MiSTer 32 MB module baseline: 4 banks x 8192
// rows x 512 cols) plus the ioctl download write path:
//
//   priority 0  download    byte pairs written as words (highest; core in reset)
//   priority 1  shared3 CPU RAM (single word R/W, byte enables via DQM)
//   priority 2  GFX stream  (i_gfx_req/addr/len -> len byte pulses)
//   priority 3  main 68000 ROM (single word, req/valid)
//   priority 4  OKI sample ROM (jt-style addr/ok, byte held stable)
//   refresh     slots into idle gaps, forced ahead of grants if overdue
//
// SDRAM byte map (matches mister/README.md and the MRA):
//   0x000000 main ROM (512 KB)   0x080000 GFX ROM (4 MB)
//   0x480000 OKI samples (256 KB)
//   0x500000 shared3 CPU RAM (112 KB, not downloaded via MRA)
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

    // shared3 CPU RAM (word R/W, byte enables via DQM)
    input  logic        i_sr3_req,      // level-held until ack
    input  logic        i_sr3_we,
    input  logic [16:0] i_sr3_addr,     // word address 0..57343
    input  logic [15:0] i_sr3_wdata,
    input  logic [1:0]  i_sr3_be,       // {UDS,LDS} byte enables
    output logic [15:0] o_sr3_rdata,
    output logic        o_sr3_ack,      // 1-cycle pulse (rdata valid on reads)

    // download write port (byte writes)
    input  logic        i_dl_wr,        // 1-cycle pulse per byte
    input  logic [24:0] i_dl_addr,      // byte address in SDRAM space
    input  logic [7:0]  i_dl_data,
    output logic        o_dl_busy,
    input  logic        i_dl_active,    // high during download (ioctl_download)

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
    output logic        SDRAM_CKE,

    // DEBUG: download verification
    output logic        dbg_dl_saw,       // dl_wr ever fired
    output logic [7:0]  dbg_dl_byte0,     // first download byte ADDRESS [15:8] (expect 00)
    output logic [7:0]  dbg_dl_byte1,     // first download byte ADDRESS [7:0]  (expect 00)
    output logic [23:0] dbg_dl_count,     // total download writes (full stream = 0x4C0000)
    output logic [15:0] dbg_selftest,     // EARLY readback of word 0 (us after write; decay probe)
    output logic [15:0] dbg_postdl,       // post-download GFX region probe (expect 0x3422)
    output logic [23:0] dbg_dl_written,   // SDRAM write CAS issued for DL owner
    output logic [15:0] dbg_dl_dropped,   // bytes lost to FIFO overflow (saturating)
    output logic [15:0] dbg_fsm_info,     // CMD_REF issue counter (live = refresh alive)
    output logic [15:0] dbg_sums,         // checksum self-test: 64 words via single reads
    output logic [15:0] dbg_sumb1,        // same 64 words via one 64-word burst, pass 1
    output logic [15:0] dbg_sumb2         // burst pass 2 (mismatch vs pass 1 = marginal capture)
);

  // word-address bases (byte base / 2)
  localparam logic [23:0] MROM_WBASE = 24'h000000;
  localparam logic [23:0] GFX_WBASE  = 24'h040000;
  localparam logic [23:0] OKI_WBASE  = 24'h240000;
  localparam logic [23:0] SR3_WBASE  = 24'h280000; // shared3 CPU RAM (112 KB)

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
  /* verilator lint_off PROCASSINIT */
  logic [3:0] cmd = CMD_NOP;
  /* verilator lint_on PROCASSINIT */
  assign {SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} = cmd;
  assign SDRAM_CKE = 1'b1;

  logic [15:0] dq_out;
  logic        dq_oe;
  assign SDRAM_DQ = dq_oe ? dq_out : 16'hzzzz;

  logic [15:0] dq_in;
  always_ff @(posedge clk) dq_in <= SDRAM_DQ;

  // ------------------------------------------------------------------
  // read-return tag pipeline: written by the FSM at CAS issue, lands
  // in sync with dq_in P_RET cycles later.
  // 0=none, 1=gfx, 2=mrom, 3=oki, 4=sr3
  // ------------------------------------------------------------------
  logic [2:0] ret_tag [P_RET+1];
  always_ff @(posedge clk)
    for (int i = P_RET; i > 0; i--) ret_tag[i] <= ret_tag[i-1];
  wire [2:0] land_tag = ret_tag[P_RET];

  // ------------------------------------------------------------------
  // main FSM (single driver for: cmd/addr/dqm, state, pends, refresh)
  // ------------------------------------------------------------------
  typedef enum logic [3:0] {
    ST_INIT_WAIT, ST_INIT_PALL, ST_INIT_REF1, ST_INIT_REF2, ST_INIT_MODE,
    ST_IDLE, ST_ACT, ST_RCD, ST_CAS, ST_ROWGAP, ST_WWAIT, ST_RFC
  } st_e;
  st_e st;

  typedef enum logic [2:0] {OWN_GFX, OWN_MROM, OWN_OKI, OWN_DL, OWN_SR3} own_e;
  own_e owner;

  logic        gfx_pend, mrom_pend, oki_pend, sr3_pend;
  logic [1:0]  pdl_st;
  logic [1:0]  early_st;
  logic [15:0] dbg_refc;           // steady-state CMD_REF issue counter
  logic [7:0]  dl_grant_cnt;       // times FSM granted OWN_DL in ST_IDLE
  logic [21:0] gfx_addr_q;
  logic [6:0]  gfx_len_q;
  logic [17:0] mrom_addr_q;
  logic [17:0] oki_addr_q;
  logic [15:0] dl_data_q;          // full word {even byte, odd byte}
  logic [7:0]  dl_even_byte;       // stashed even byte awaiting its odd pair
  logic        sr3_rmw_fly;        // read-modify-write read in flight
  logic        sr3_busy;           // sr3 op accepted, ack not yet issued
  logic        probe_pend;         // GFX probe read request
  logic        probe_fly;          // GFX probe read in flight (ret tag 6)
  logic [23:0] probe_addr;         // word address for the next probe read
  // checksum self-test (runs once after the post-download probe):
  // 64 GFX words at SUM_BASE summed three ways - single reads (tag 6),
  // then two identical 64-word bursts (tag 7). Content wrong -> SUMS bad;
  // deterministic burst bug -> SUMB1 == SUMB2 both bad; marginal capture
  // -> SUMB1 != SUMB2.
  localparam logic [23:0] SUM_BASE = GFX_WBASE + 24'h032000;
  logic [3:0]  sum_st;
  logic [6:0]  sum_i;
  logic [15:0] sum_acc;
  logic        sumb_pend;          // burst-pass request
  logic        sum_fly;            // burst pass in flight (ret tag 7)
  logic [16:0] sum_wait;           // no-download fallback timer (sim preload)
  logic [16:0] sr3_addr_q;
  logic [15:0] sr3_wdata_q;
  logic [1:0]  sr3_be_q;
  logic        sr3_we_q;
  logic        sr3_wr_done;        // set in FSM at write CAS, cleared by landing block
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
  logic [17:0] oki_fly;      // address of the in-flight OKI read: a new
                             // request may relatch oki_addr_q before the
                             // previous word lands (pend clears at CAS)
  wire oki_want = !oki_have || (i_oki_addr != oki_served);

  wire [9:0] col_room = 10'd512 - {1'b0, cur_word[8:0]};

  always_ff @(posedge clk) begin
    cmd        <= CMD_NOP;
    SDRAM_A    <= '0;
    SDRAM_BA   <= cur_word[23:22];
    dq_oe      <= 1'b0;
    ret_tag[0] <= 3'd0;
    gfx_start  <= 1'b0;
    sr3_wr_done <= 1'b0;
    dlf_pop    <= 1'b0;

    if (!rst_n) begin
      st <= ST_INIT_WAIT;
      owner <= OWN_GFX;
      o_ready <= 1'b0;
      gfx_pend <= 1'b0; mrom_pend <= 1'b0;
      oki_pend <= 1'b0; sr3_pend <= 1'b0;
      sr3_wr_done <= 1'b0;
      sr3_rmw_fly <= 1'b0;
      sr3_busy <= 1'b0;
      probe_pend <= 1'b0;
      probe_fly <= 1'b0;
      init_cnt <= '0; wait_cnt <= '0;
      cur_word <= '0; words_left <= '0; cas_left <= '0;
      ref_cnt <= '0; ref_due <= 1'b0; ref_urgent <= 1'b0;
      SDRAM_DQML <= 1'b1; SDRAM_DQMH <= 1'b1;
      dbg_dl_saw <= 1'b0;
      dbg_dl_byte0 <= '0;
      dbg_dl_byte1 <= '0;
      dbg_dl_count <= '0;
      dbg_dl_written <= '0;
      dbg_dl_dropped <= '0;
      dl_grant_cnt <= '0;
      dbg_selftest <= 16'hDEAD;
      dbg_postdl   <= 16'hDEAD;
      dbg_refc     <= '0;
      pdl_st       <= 2'd0;
      early_st     <= 2'd0;
      dbg_sums     <= 16'hDEAD;
      dbg_sumb1    <= 16'hDEAD;
      dbg_sumb2    <= 16'hDEAD;
      sum_st       <= 4'd0;
      sum_i        <= '0;
      sum_acc      <= '0;
      sumb_pend    <= 1'b0;
      sum_fly      <= 1'b0;
      sum_wait     <= '0;
      probe_addr   <= '0;
    end else begin
      // EARLY readback probe: read word 0 back microseconds after its two
      // bytes are written, while the download is still streaming. Compared
      // against dbg_postdl (same word, seconds later) this discriminates
      // "write never landed" from "data decayed = refresh dead on hardware".
      case (early_st)
        2'd0: if (dbg_dl_written >= 24'd4 && i_dl_active
                   && st == ST_IDLE && !mrom_pend) begin
                mrom_pend   <= 1'b1;
                mrom_addr_q <= 18'd0;
                early_st    <= 2'd1;
              end
        2'd1: if (o_mrom_valid && mrom_addr_q == 18'd0) begin
                dbg_selftest <= o_mrom_data;
                early_st     <= 2'd2;
              end
        default: ;
      endcase

      // post-download GFX probe: read GFX region word GFX_WBASE+4 (SDRAM
      // bytes 0x080008-9). Expected 0x3422 per the sim-verified
      // gfxrom.bin; anything else means the MRA GFX interleave is wrong.
      if (pdl_st == 2'd0 && dbg_dl_saw && !i_dl_active && dlf_empty) begin
        probe_pend <= 1'b1;
        probe_addr <= GFX_WBASE + 24'd4;
        pdl_st     <= 2'd1;
      end
      if (land_tag == 3'd6) begin
        probe_fly  <= 1'b0;
        if (pdl_st == 2'd1) begin
          dbg_postdl <= dq_in;
          pdl_st     <= 2'd2;
        end else begin
          // checksum single-read landing
          sum_acc <= sum_acc + dq_in;
          sum_i   <= sum_i + 7'd1;
          if (sum_i == 7'd63) sum_st <= 4'd3;
          else                sum_st <= 4'd1;
        end
      end

      // checksum burst landing (tag 7)
      if (land_tag == 3'd7) begin
        sum_acc <= sum_acc + dq_in;
        sum_i   <= sum_i + 7'd1;
        if (sum_i == 7'd63) sum_st <= (sum_st == 4'd4) ? 4'd5 : 4'd7;
      end

      // checksum self-test sequencer
      if (o_ready && !dbg_dl_saw && !sum_wait[16])
        sum_wait <= sum_wait + 17'd1;
      case (sum_st)
        4'd0: if (pdl_st == 2'd2 || sum_wait[16]) begin
                sum_i <= '0; sum_acc <= '0; sum_st <= 4'd1;
              end
        4'd1: if (!probe_pend && !probe_fly) begin
                probe_pend <= 1'b1;
                probe_addr <= SUM_BASE + 24'(sum_i);
                sum_st     <= 4'd2;
              end
        // 4'd2: waiting for the tag-6 landing above
        4'd3: begin
                dbg_sums <= sum_acc;
                sum_i <= '0; sum_acc <= '0;
                sumb_pend <= 1'b1; sum_st <= 4'd4;
              end
        // 4'd4: burst pass 1 in flight (tag-7 landings above)
        4'd5: begin
                dbg_sumb1 <= sum_acc;
                sum_i <= '0; sum_acc <= '0;
                sumb_pend <= 1'b1; sum_st <= 4'd6;
              end
        4'd6: sum_st <= 4'd7;   // hop so the ==63 landing maps pass 2 -> done
        // 4'd7: burst pass 2 in flight
        default: ;
      endcase
      if (sum_st == 4'd7 && sum_i == 7'd64) begin
        dbg_sumb2 <= sum_acc;
        sum_st <= 4'd8;
      end

      // DEBUG: capture download writes; byte0/1 hold the FIRST BYTE'S
      // ADDRESS (expect 0000) to rule out an ioctl offset
      if (i_dl_wr) begin
        dbg_dl_saw <= 1'b1;
        dbg_dl_count <= dbg_dl_count + 24'd1;
        if (dbg_dl_count == 24'd0) {dbg_dl_byte0, dbg_dl_byte1} <= i_dl_addr[15:0];
        if (i_dl_addr[0] && dlf_full && !(&dbg_dl_dropped))
          dbg_dl_dropped <= dbg_dl_dropped + 16'd2;  // word lost = 2 bytes
      end
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
      // sr3_busy holds off relatching while the op is in flight: pend
      // clears at CAS but the requester keeps req asserted until ack,
      // and a relatch in that window would issue a duplicate op whose
      // phantom ack could complete a LATER request with stale data
      if (i_sr3_req && !sr3_pend && !sr3_busy) begin
        sr3_pend <= 1'b1; sr3_busy <= 1'b1;
        sr3_addr_q <= i_sr3_addr;
        sr3_wdata_q <= i_sr3_wdata; sr3_be_q <= i_sr3_be;
        sr3_we_q <= i_sr3_we;
      end
      if (o_sr3_ack) sr3_busy <= 1'b0;
      // rmw read landed: merge the untouched lanes into the write data and
      // promote to a full-word write (re-granted from ST_IDLE)
      if (land_tag == 3'd5) begin
        sr3_wdata_q <= {sr3_be_q[1] ? sr3_wdata_q[15:8] : dq_in[15:8],
                        sr3_be_q[0] ? sr3_wdata_q[7:0]  : dq_in[7:0]};
        sr3_be_q    <= 2'b11;
        sr3_rmw_fly <= 1'b0;
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
                                  && !oki_pend && dlf_empty && !sr3_pend)) begin
            cmd <= CMD_REF;
            ref_due <= 1'b0; ref_urgent <= 1'b0;
            dbg_refc <= dbg_refc + 16'd1;
            wait_cnt <= 4'd8; st <= ST_RFC;
          end else if (!dlf_empty) begin
            owner <= OWN_DL;
            dl_data_q <= dlf[dlf_rp][15:0];
            dlf_pop   <= 1'b1;
            cur_word <= dlf[dlf_rp][39:16];
            if (!(&dl_grant_cnt)) dl_grant_cnt <= dl_grant_cnt + 8'd1;
            st <= ST_ACT;
          end else if (sr3_pend && !sr3_rmw_fly) begin
            owner <= OWN_SR3;
            cur_word <= SR3_WBASE + 24'(sr3_addr_q);
            words_left <= 7'd1;
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
          end else if (probe_pend) begin
            owner <= OWN_MROM;                 // rides the mrom read path
            probe_fly <= 1'b1;                 // but lands with tag 6
            probe_pend <= 1'b0;
            cur_word <= probe_addr;
            words_left <= 7'd1;
            st <= ST_ACT;
          end else if (sumb_pend) begin
            owner <= OWN_GFX;                  // rides the gfx burst path
            sum_fly <= 1'b1;                   // but lands with tag 7
            sumb_pend <= 1'b0;
            cur_word <= SUM_BASE;
            words_left <= 7'd64;
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
          // The MiSTer SDRAM board ties DQML/DQMH low, so byte masking is
          // impossible on hardware: ALL writes are full 16-bit words. The
          // download path pairs bytes into words; partial sr3 writes go
          // through read-modify-write (rmw read tagged 5, merged below).
          if (owner == OWN_DL) begin
            cmd <= CMD_WRIT; dq_oe <= 1'b1;
            dq_out <= dl_data_q;                     // {even byte, odd byte}
            SDRAM_A <= {4'b0010, cur_word[8:0]};     // A10 = auto precharge
            SDRAM_DQML <= 1'b0; SDRAM_DQMH <= 1'b0;
            dbg_dl_written <= dbg_dl_written + 24'd2;  // counts BYTES
            wait_cnt <= 4'd3;                        // tWR + tRP
            st <= ST_WWAIT;
          end else if (owner == OWN_SR3 && sr3_we_q && sr3_be_q == 2'b11) begin
            // sr3 full-word write (partial writes arrive here only after
            // the rmw merge promotes be to 2'b11)
            cmd <= CMD_WRIT; dq_oe <= 1'b1;
            dq_out <= sr3_wdata_q;
            SDRAM_A <= {4'b0010, cur_word[8:0]};     // A10 = auto precharge
            SDRAM_DQML <= 1'b0; SDRAM_DQMH <= 1'b0;
            sr3_pend <= 1'b0;
            sr3_wr_done <= 1'b1;                     // landing block pulses ack
            wait_cnt <= 4'd3;                        // tWR + tRP
            st <= ST_WWAIT;
          end else if (owner != OWN_GFX || sum_fly || bf_room) begin
            cmd <= CMD_READ;
            SDRAM_A <= {(cas_left == 6'd1) ? 4'b0010 : 4'b0000,
                        cur_word[8:0]};              // AP on the last CAS
            ret_tag[0] <= (owner == OWN_GFX)  ? (sum_fly ? 3'd7 : 3'd1) :
                          (owner == OWN_MROM) ? (probe_fly ? 3'd6 : 3'd2) :
                          (owner == OWN_SR3)  ? (sr3_we_q ? 3'd5 : 3'd4) : 3'd3;
            if (owner == OWN_OKI) oki_fly <= oki_addr_q;
            if (owner == OWN_SR3) begin
              if (sr3_we_q) sr3_rmw_fly <= 1'b1;     // rmw read: keep pend
              else          sr3_pend <= 1'b0;
            end
            cur_word <= cur_word + 24'd1;
            words_left <= words_left - 7'd1;
            cas_left <= cas_left - 6'd1;
            if (cas_left == 6'd1) begin
              if (owner == OWN_GFX && words_left != 7'd1) begin
                wait_cnt <= 4'd1;                    // tRP after AP
                st <= ST_ROWGAP;                     // row-crossing re-ACT
              end else begin
                if (owner == OWN_GFX) begin
                  if (sum_fly) sum_fly <= 1'b0;
                  else         gfx_pend <= 1'b0;
                end
                if (owner == OWN_MROM && !probe_fly) mrom_pend <= 1'b0;
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
  // mrom / oki / sr3 landing (single driver for their outputs)
  // ------------------------------------------------------------------
  always_ff @(posedge clk) begin
    o_mrom_valid <= 1'b0;
    o_sr3_ack <= 1'b0;
    if (!rst_n) begin
      oki_have <= 1'b0; oki_served <= '0;
      o_mrom_data <= '0; o_oki_data <= '0;
      o_sr3_rdata <= '0;
    end else begin
      if (land_tag == 3'd2) begin
        o_mrom_data <= dq_in;
        o_mrom_valid <= 1'b1;
      end
      if (land_tag == 3'd3) begin
        o_oki_data <= oki_fly[0] ? dq_in[7:0] : dq_in[15:8];
        oki_served <= oki_fly;
        oki_have <= 1'b1;
      end
      if (land_tag == 3'd4) begin
        o_sr3_rdata <= dq_in;
        o_sr3_ack <= 1'b1;
      end
      if (sr3_wr_done) begin
        o_sr3_ack <= 1'b1;         // write ack (data already committed)
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
        if (land_tag == 3'd1) begin
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

  // ------------------------------------------------------------------
  // download FIFO (16-deep, one WORD per entry): the ioctl byte stream
  // is strictly sequential from address 0, so bytes are paired into
  // words before entering the FIFO (even byte stashed, pushed with its
  // odd sibling). Full-word writes are mandatory because the MiSTer
  // SDRAM board ties DQML/DQMH low (no byte masking).
  // ------------------------------------------------------------------
  logic [39:0] dlf [0:15];      // {word_addr[23:0], data[15:0]}
  logic [3:0]  dlf_wp, dlf_rp;
  logic [4:0]  dlf_cnt;         // 0..16
  wire         dlf_empty = (dlf_cnt == 5'd0);
  wire         dlf_full  = (dlf_cnt == 5'd16);
  logic        dlf_pop;         // set by main FSM when it consumes a FIFO entry
  wire         dlf_push = i_dl_wr && i_dl_addr[0] && !dlf_full;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      dlf_wp  <= '0;
      dlf_rp  <= '0;
      dlf_cnt <= '0;
    end else begin
      if (i_dl_wr && !i_dl_addr[0])
        dl_even_byte <= i_dl_data;
      if (dlf_push) begin
        dlf[dlf_wp] <= {i_dl_addr[24:1], dl_even_byte, i_dl_data};
        dlf_wp <= dlf_wp + 4'd1;
      end
      if (dlf_pop) begin
        dlf_rp <= dlf_rp + 4'd1;
      end
      case ({dlf_push, dlf_pop})
        2'b10:   dlf_cnt <= dlf_cnt + 5'd1;
        2'b01:   dlf_cnt <= dlf_cnt - 5'd1;
        default: ;
      endcase
    end
  end

  assign o_dl_busy = !o_ready || (dlf_cnt >= 5'd12);
  assign dbg_fsm_info = dbg_refc;   // REFC row: changing digits = refresh alive

endmodule
