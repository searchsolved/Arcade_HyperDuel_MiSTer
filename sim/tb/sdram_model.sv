// Behavioral SDRAM model for Verilator (16 Mword x 16, 4 banks x 8192
// rows x 512 cols = 32 MB, the MiSTer module baseline).
//
// Purpose: prove hyprduel_sdram.sv drives a real part correctly before
// any Quartus build. Models CL2 read latency, BL1, per-bank open rows,
// auto precharge (A10), DQM byte masking, and flags protocol errors
// with $error:
//   - ACT on a bank whose row is already open
//   - READ/WRITE on a bank with no open row, or before tRCD
//   - AUTO REFRESH with any row open
//   - access before the init sequence (PALL + 2x REF + MODE, CL2/BL1)
//
// Backing store is a plain byte array; the TB loads ROM images into it
// hierarchically (u_sdram_model.mem_b). Even byte address = word[15:8]
// (the 68000/build_mainrom.py lane convention used across the project).
//
// Timing alignment (matches hyprduel_sdram P_RET=3): the model samples
// a READ at posedge E1 (command was launched by the controller's
// register at E0), registers an internal fetch at E2, and drives DQ
// during the E2->E3 cycle, i.e. data on the bus two full cycles after
// the command cycle: CAS latency 2.

module sdram_model (
    input  logic        clk,
    input  logic [12:0] A,
    input  logic [1:0]  BA,
    inout  wire  [15:0] DQ,
    input  logic        DQML,
    input  logic        DQMH,
    input  logic        nCS,
    input  logic        nRAS,
    input  logic        nCAS,
    input  logic        nWE,
    input  logic        CKE
);

  logic [7:0] mem_b [0:33554431];   // 32 MB

  // command decode
  wire [3:0] cmd = {nCS, nRAS, nCAS, nWE};
  localparam logic [3:0] CMD_NOP  = 4'b0111;
  localparam logic [3:0] CMD_ACT  = 4'b0011;
  localparam logic [3:0] CMD_READ = 4'b0101;
  localparam logic [3:0] CMD_WRIT = 4'b0100;
  localparam logic [3:0] CMD_PALL = 4'b0010;
  localparam logic [3:0] CMD_REF  = 4'b0001;
  localparam logic [3:0] CMD_MODE = 4'b0000;

  // per-bank state (Verilator zero-initializes; no initial block, it
  // would trip MULTIDRIVEN against the always_ff)
  logic        row_open [4];
  logic [12:0] open_row [4];
  int          act_time [4];
  int          now = 0;

  // init tracking
  int  init_refs = 0;
  bit  saw_pall = 0, mode_set = 0;

  // read pipeline (CL2)
  logic        rd_pend = 1'b0;  // stage 1: sampled READ
  logic [23:0] rd_word;
  logic        drv_en = 1'b0;   // stage 2: driving DQ this cycle
  logic [15:0] drv_data;

  assign DQ = drv_en ? drv_data : 16'hzzzz;

  // debug: +SDRTRACE=1 prints every non-NOP command
  int trace = 0;
  initial void'($value$plusargs("SDRTRACE=%d", trace));
  always @(posedge clk)
    if (trace != 0 && CKE && cmd != CMD_NOP && cmd[3] == 1'b0)
      $display("SDR t=%0d cmd=%b A=%h BA=%b", now, cmd, A, BA);

  always_ff @(posedge clk) begin
    logic [23:0] w;
    now <= now + 1;

    // stage 2: drive previously fetched data for exactly one cycle
    drv_en <= rd_pend;
    if (rd_pend)
      drv_data <= {mem_b[{rd_word, 1'b0}], mem_b[{rd_word, 1'b1}]};
    rd_pend <= 1'b0;

    if (CKE) begin
      case (cmd)
        CMD_MODE: begin
          if (A[6:4] != 3'b010)
            $error("sdram_model: mode register CL=%0d, expected CL2", A[6:4]);
          if (A[2:0] != 3'b000)
            $error("sdram_model: mode register BL!=1 (A=%h)", A);
          mode_set <= 1'b1;
        end

        CMD_PALL: begin
          if (A[10]) begin
            for (int b = 0; b < 4; b++) row_open[b] <= 1'b0;
            saw_pall <= 1'b1;
          end
        end

        CMD_REF: begin
          for (int b = 0; b < 4; b++)
            if (row_open[b])
              $error("sdram_model: AUTO REFRESH with bank %0d row open", b);
          if (!saw_pall)
            $error("sdram_model: AUTO REFRESH before PRECHARGE ALL");
          init_refs <= init_refs + 1;
        end

        CMD_ACT: begin
          if (row_open[BA])
            $error("sdram_model: ACT on bank %0d with row already open", BA);
          if (init_refs < 2 || !mode_set)
            $error("sdram_model: ACT before init complete (refs=%0d mode=%0d)",
                   init_refs, mode_set);
          row_open[BA] <= 1'b1;
          open_row[BA] <= A;
          act_time[BA] <= now;
        end

        CMD_READ: begin
          if (!row_open[BA])
            $error("sdram_model: READ on bank %0d with no open row", BA);
          if (now - act_time[BA] < 2)
            $error("sdram_model: READ violates tRCD on bank %0d", BA);
          rd_pend <= 1'b1;
          rd_word <= {BA, open_row[BA], A[8:0]};
          if (A[10]) row_open[BA] <= 1'b0;   // auto precharge
        end

        CMD_WRIT: begin
          if (!row_open[BA])
            $error("sdram_model: WRITE on bank %0d with no open row", BA);
          if (now - act_time[BA] < 2)
            $error("sdram_model: WRITE violates tRCD on bank %0d", BA);
          w = {BA, open_row[BA], A[8:0]};
          if (!DQMH) mem_b[{w, 1'b0}] <= DQ[15:8];  // even byte = high lane
          if (!DQML) mem_b[{w, 1'b1}] <= DQ[7:0];
          if (A[10]) row_open[BA] <= 1'b0;
        end

        default: ;  // NOP / unencoded
      endcase
    end
  end

endmodule
