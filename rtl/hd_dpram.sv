// Dual-port RAM wrapper: Verilator gets inferred arrays (proven sim path),
// Quartus gets explicit altsyncram.
//
// Port A = read/write with byte enables (CPU/blitter side)
// Port B = read-only (renderer side)
//
// Uses BIDIR_DUAL_PORT with port B write disabled. Port B's write
// infrastructure is tied off so Quartus does not build decoder trees
// for it across 100+ M10K blocks.

module hd_dpram #(
    parameter int AW = 16,
    parameter int DW = 16,
    parameter int NUMWORDS = (1 << AW)
) (
    input  logic              clk,
    input  logic [AW-1:0]     addr_a,
    input  logic [DW-1:0]     d_a,
    input  logic              we_a,
    input  logic [DW/8-1:0]   be_a,
    output logic [DW-1:0]     q_a,
    input  logic [AW-1:0]     addr_b,
    output logic [DW-1:0]     q_b
);

`ifdef VERILATOR
  logic [DW-1:0] mem [0:NUMWORDS-1];

  always_ff @(posedge clk) begin
    if (we_a)
      for (int i = 0; i < DW/8; i++)
        if (be_a[i]) mem[addr_a][i*8 +: 8] <= d_a[i*8 +: 8];
    q_a <= mem[addr_a];
  end

  always_ff @(posedge clk)
    q_b <= mem[addr_b];
`else
  altsyncram #(
    .operation_mode          ("BIDIR_DUAL_PORT"),
    .width_a                 (DW),
    .widthad_a               (AW),
    .numwords_a              (NUMWORDS),
    .width_b                 (DW),
    .widthad_b               (AW),
    .numwords_b              (NUMWORDS),
    .width_byteena_a         (DW / 8),
    .width_byteena_b         (1),
    .clock_enable_input_b    ("BYPASS"),
    .clock_enable_output_a   ("BYPASS"),
    .clock_enable_output_b   ("BYPASS"),
    .indata_reg_b            ("CLOCK1"),
    .outdata_reg_a           ("UNREGISTERED"),
    .outdata_reg_b           ("UNREGISTERED"),
    .read_during_write_mode_port_a ("NEW_DATA_NO_NBE_READ"),
    .read_during_write_mode_port_b ("NEW_DATA_NO_NBE_READ"),
    .wrcontrol_wraddress_reg_b ("CLOCK1"),
    .power_up_uninitialized  ("FALSE"),
    .intended_device_family  ("Cyclone V"),
    .lpm_type                ("altsyncram"),
    .lpm_hint                ("ENABLE_RUNTIME_MOD=NO")
  ) ram (
    .clock0       (clk),
    .address_a    (addr_a),
    .data_a       (d_a),
    .wren_a       (we_a),
    .byteena_a    (be_a),
    .q_a          (q_a),
    .address_b    (addr_b),
    .data_b       ({DW{1'b0}}),
    .wren_b       (1'b0),
    .byteena_b    (1'b1),
    .q_b          (q_b),
    .aclr0        (1'b0),
    .aclr1        (1'b0),
    .addressstall_a (1'b0),
    .addressstall_b (1'b0),
    .clocken0     (1'b1),
    .clocken1     (1'b1),
    .clocken2     (1'b1),
    .clocken3     (1'b1),
    .clock1       (clk),
    .eccstatus    (),
    .rden_a       (1'b1),
    .rden_b       (1'b1)
  );
`endif

endmodule
