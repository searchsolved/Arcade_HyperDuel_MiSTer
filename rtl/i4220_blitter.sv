// I4220 blitter (docs/i4220_spec.md sec 4).
//
// Reads an opcode stream from GFX ROM and writes one byte lane of VRAM
// words. Semantics verified against the MAME-port oracle
// (sim/oracle/i4220_blitter_oracle.py) by sim/tb/tb_blitter.sv.
//
// ROM port is a request/valid handshake so the integration can arbitrate
// GFX ROM (SDRAM) between blitter, tile fetch and sprite fetch. Protocol:
// o_rom_rd rises with a stable o_rom_addr and stays high until i_rom_valid
// delivers the byte; o_rom_rd then drops for at least one cycle before the
// next request. Because o_rom_rd is registered it is still high during the
// delivery cycle itself: the server MUST NOT treat that cycle as a new
// request (accept only when rd is high and its own valid is low). VRAM
// port carries a 16-bit write mask, always one byte lane.
//
// o_done pulses only when a blit terminates on the STOP opcode (0x00);
// this drives IRQ cause bit 2. A start with an invalid destination tilemap
// returns to idle without o_done, matching MAME.

module i4220_blitter #(
    parameter int GFX_AW = 22   // GFX ROM address bits (4 MB on TEC442-A)
) (
    input  logic        clk,
    input  logic        rst_n,

    // register interface: values of the 3 blitter register pairs,
    // start pulses when the trigger register (0x7884C) is written
    input  logic        i_start,
    input  logic [31:0] i_tmap,
    input  logic [31:0] i_src,
    input  logic [31:0] i_dst,

    // GFX ROM read port (byte)
    output logic              o_rom_rd,
    output logic [GFX_AW-1:0] o_rom_addr,
    input  logic [7:0]        i_rom_data,
    input  logic              i_rom_valid,

    // VRAM write port
    output logic        o_vram_we,
    output logic [1:0]  o_vram_layer,   // 0..2
    output logic [15:0] o_vram_addr,
    output logic [15:0] o_vram_wdata,
    output logic [15:0] o_vram_wmask,

    output logic        o_busy,
    output logic        o_done
);

  typedef enum logic [1:0] {
    S_IDLE, S_OP_RD, S_DATA_RD, S_WRITE
  } state_e;

  state_e      state;
  logic [1:0]  layer;          // tmap - 1
  logic [31:0] src;            // masked to GFX_AW on the bus
  logic [31:0] dst;            // raw >> 8 word offset, upper bits live
  logic        lane_lo;        // dst raw bit 7: 1 = low byte lane
  logic [7:0]  col_restore;    // dst raw bits 15:8
  logic [15:0] b2;             // fill value (inc fills count past 8 bits)
  logic [6:0]  count;          // 1..64
  logic [1:0]  op;

  wire [15:0] dst_word = dst[15:0];
  wire [15:0] wmask = lane_lo ? 16'h00FF : 16'hFF00;

  function automatic logic [15:0] lane_data(input logic [15:0] v);
    // (value << shift) truncated to 16 bits; shift = 8 unless low lane
    lane_data = lane_lo ? v : {v[7:0], 8'h00};
  endfunction

  // count = ((~opcode_byte) & 0x3F) + 1, range 1..64
  function automatic logic [6:0] blit_count(input logic [7:0] b);
    blit_count = {1'b0, ~b[5:0]} + 7'd1;
  endfunction

  assign o_rom_addr = src[GFX_AW-1:0];
  assign o_busy = (state != S_IDLE);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state        <= S_IDLE;
      o_vram_we    <= 1'b0;
      o_done       <= 1'b0;
      o_rom_rd     <= 1'b0;
      layer        <= '0;
      src          <= '0;
      dst          <= '0;
      lane_lo      <= 1'b0;
      col_restore  <= '0;
      b2           <= '0;
      count        <= '0;
      op           <= '0;
    end else begin
      o_vram_we <= 1'b0;
      o_done    <= 1'b0;

      unique case (state)
        S_IDLE: begin
          if (i_start) begin
            lane_lo     <= i_dst[7];
            col_restore <= i_dst[15:8];
            dst         <= i_dst >> 8;
            src         <= i_src;
            if (i_tmap >= 32'd1 && i_tmap <= 32'd3) begin
              layer <= 2'(i_tmap - 32'd1);
              state <= S_OP_RD;   // S_OP_RD arms the read itself
            end
            // invalid tilemap: stay idle, no done (MAME: return, no IRQ)
          end
        end

        // fetch opcode byte
        S_OP_RD: begin
          if (!o_rom_rd && !i_rom_valid) begin
            o_rom_rd <= 1'b1;                        // arm (addr now stable)
          end else if (i_rom_valid) begin
            o_rom_rd <= 1'b0;                        // consume, one bubble
            src <= src + 1;
            op  <= i_rom_data[7:6];
            count <= blit_count(i_rom_data);
            unique case (i_rom_data[7:6])
              2'd0: begin
                if (i_rom_data == 8'h00) begin       // STOP
                  o_done <= 1'b1;
                  state  <= S_IDLE;
                end else begin                       // COPY: data per write
                  state <= S_DATA_RD;
                end
              end
              2'd1, 2'd2: state <= S_DATA_RD;        // one data byte first
              2'd3: begin                            // SKIP, no data bytes
                if (i_rom_data == 8'hC0) begin       // next row, restore col
                  dst <= ((dst + 32'h100) & ~32'hFF) | 32'(col_restore);
                end else begin
                  dst <= dst + {25'd0, blit_count(i_rom_data)};
                end
                // stay in S_OP_RD; re-arms next cycle
              end
            endcase
          end
        end

        // fetch a data byte (copy: every write; fills: once)
        S_DATA_RD: begin
          if (!o_rom_rd && !i_rom_valid) begin
            o_rom_rd <= 1'b1;                        // arm
          end else if (i_rom_valid) begin
            o_rom_rd <= 1'b0;
            src   <= src + 1;
            b2    <= {8'h00, i_rom_data};
            state <= S_WRITE;
          end
        end

        S_WRITE: begin
          o_vram_we    <= 1'b1;
          o_vram_layer <= layer;
          o_vram_addr  <= dst_word;
          o_vram_wdata <= lane_data(b2);
          o_vram_wmask <= wmask;
          // dst &= 0xFFFF, then wrap increment within the 256-word row
          dst <= {16'h0000, dst_word[15:8], dst_word[7:0] + 8'd1};
          if (op == 2'd1) b2 <= b2 + 16'd1;
          if (count == 7'd1) begin
            state <= S_OP_RD;
          end else begin
            count <= count - 7'd1;
            if (op == 2'd0) state <= S_DATA_RD;  // COPY: next byte from ROM
            // fills: stay in S_WRITE
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
