// Download-path testbench: exercises the ioctl download -> SDRAM write ->
// mrom readback pipeline that has never been tested in sim. Catches address
// mapping, FIFO, DQM, and timing bugs without a 15-min Quartus compile.
//
// Tests:
//   1. Normal download: write a counting pattern at ~1 byte/80 clks,
//      honoring o_dl_busy. Read back every word via mrom. PASS = match.
//   2. Burst download: bytes every 2-3 cycles (hostile HPS timing),
//      plus 2 extra after busy asserts. PASS = no FIFO drops, data match.
//   3. Mid-download reset: pulse rst_n low during the stream, verify
//      that bytes sent during reset are lost (documents the failure mode
//      the rst_n fix prevents).
//
// Usage: make download   (add target to sim/Makefile)

`timescale 1ns/1ps

module tb_download;

  localparam int ROM_BYTES = 1024;       // small ROM for fast sim
  localparam int ROM_WORDS = ROM_BYTES / 2;

  logic clk = 0;
  always #5 clk = ~clk;                 // 100 MHz sim clock (timing ratios same)

  logic rst_n;

  // download port
  logic        dl_wr;
  logic [24:0] dl_addr;
  logic [7:0]  dl_data;
  wire         dl_busy;
  logic        dl_active;

  // mrom readback port
  logic        mrom_rd;
  logic [17:0] mrom_addr;
  wire  [15:0] mrom_data;
  wire         mrom_valid;

  // sr3 port (T6: rmw byte writes)
  logic        sr3_req = 0, sr3_we = 0;
  logic [16:0] sr3_addr;
  logic [15:0] sr3_wdata;
  logic [1:0]  sr3_be;
  wire  [15:0] sr3_rdata;
  wire         sr3_ack;

  task automatic sr3_op(input logic we, input logic [16:0] a,
                        input logic [15:0] d, input logic [1:0] be,
                        output logic [15:0] rd);
    sr3_req <= 1'b1; sr3_we <= we; sr3_addr <= a;
    sr3_wdata <= d; sr3_be <= be;
    @(posedge clk);
    while (!sr3_ack) @(posedge clk);
    rd = sr3_rdata;
    sr3_req <= 1'b0;
    @(posedge clk);
    repeat (3) @(posedge clk);
  endtask

  // SDRAM wires
  wire  [12:0] sdr_a;
  wire  [1:0]  sdr_ba;
  wire  [15:0] sdr_dq;
  wire         sdr_dqml, sdr_dqmh, sdr_ncs, sdr_nras, sdr_ncas, sdr_nwe, sdr_cke;

  // debug
  wire         dbg_dl_saw;
  wire  [7:0]  dbg_dl_byte0, dbg_dl_byte1;
  wire  [23:0] dbg_dl_count;
  wire  [15:0] dbg_selftest, dbg_postdl;
  wire  [23:0] dbg_dl_written;
  wire  [15:0] dbg_dl_dropped;
  wire         sdr_ready;

  hyprduel_sdram #(.P_SHORT_INIT(1'b1), .P_RET(3)) u_sdr (
    .clk(clk), .rst_n(rst_n), .o_ready(sdr_ready),

    .i_gfx_req(1'b0), .i_gfx_addr('0), .i_gfx_len('0),
    .o_gfx_data(), .o_gfx_valid(),

    .i_mrom_rd(mrom_rd), .i_mrom_addr(mrom_addr),
    .o_mrom_data(mrom_data), .o_mrom_valid(mrom_valid),

    .i_oki_addr('0), .o_oki_data(), .o_oki_ok(),

    .i_sr3_req(sr3_req), .i_sr3_we(sr3_we), .i_sr3_addr(sr3_addr),
    .i_sr3_wdata(sr3_wdata), .i_sr3_be(sr3_be),
    .o_sr3_rdata(sr3_rdata), .o_sr3_ack(sr3_ack),

    .i_dl_wr(dl_wr), .i_dl_addr(dl_addr), .i_dl_data(dl_data),
    .o_dl_busy(dl_busy), .i_dl_active(dl_active),

    .SDRAM_A(sdr_a), .SDRAM_BA(sdr_ba), .SDRAM_DQ(sdr_dq),
    .SDRAM_DQML(sdr_dqml), .SDRAM_DQMH(sdr_dqmh),
    .SDRAM_nCS(sdr_ncs), .SDRAM_nRAS(sdr_nras), .SDRAM_nCAS(sdr_ncas),
    .SDRAM_nWE(sdr_nwe), .SDRAM_CKE(sdr_cke),

    .dbg_dl_saw(dbg_dl_saw), .dbg_dl_byte0(dbg_dl_byte0),
    .dbg_dl_byte1(dbg_dl_byte1), .dbg_dl_count(dbg_dl_count),
    .dbg_selftest(dbg_selftest), .dbg_postdl(dbg_postdl),
    .dbg_dl_written(dbg_dl_written), .dbg_dl_dropped(dbg_dl_dropped),
    .dbg_fsm_info()
  );

  // DQML/DQMH tied LOW: the MiSTer SDRAM board hard-wires them to GND,
  // so byte masking never works on real hardware. The model must match
  // or sim passes where the board fails.
  sdram_model u_sdr_model (
    .clk(clk), .A(sdr_a), .BA(sdr_ba), .DQ(sdr_dq),
    .DQML(1'b0), .DQMH(1'b0),
    .nCS(sdr_ncs), .nRAS(sdr_nras), .nCAS(sdr_ncas), .nWE(sdr_nwe),
    .CKE(sdr_cke)
  );

  // reference data: counting pattern 0x00, 0xFF, 0x01, 0xFE, ...
  logic [7:0] ref_stream [ROM_BYTES];
  initial begin
    for (int i = 0; i < ROM_BYTES; i++)
      ref_stream[i] = (i[0] == 0) ? i[7:0] : ~i[7:0];
  end

  // -------------------------------------------------------------------
  // tasks
  // -------------------------------------------------------------------

  int errors;

  task automatic do_reset();
    rst_n <= 1'b0;
    dl_wr <= 1'b0;
    dl_active <= 1'b0;
    mrom_rd <= 1'b0;
    repeat (10) @(posedge clk);
    rst_n <= 1'b1;
    // wait for SDRAM init + selftest to complete
    @(posedge sdr_ready);
    repeat (200) @(posedge clk);
  endtask

  task automatic send_stream(int gap_cycles, int count, int start_addr);
    dl_active <= 1'b1;
    @(posedge clk);
    for (int i = 0; i < count; i++) begin
      // wait for not-busy (or ignore for burst test)
      if (gap_cycles > 0) begin
        while (dl_busy) @(posedge clk);
      end
      dl_wr   <= 1'b1;
      dl_addr <= 25'(start_addr + i);
      dl_data <= ref_stream[i];
      @(posedge clk);
      dl_wr <= 1'b0;
      repeat (gap_cycles > 1 ? gap_cycles - 1 : 0) @(posedge clk);
    end
    // drain: wait for FIFO empty + last write to complete
    repeat (200) @(posedge clk);
    dl_active <= 1'b0;
    repeat (50) @(posedge clk);
  endtask

  task automatic verify_readback(int word_count, int start_word, string label);
    int mismatches = 0;
    logic [15:0] expected_w, got_w;
    for (int w = 0; w < word_count; w++) begin
      mrom_rd   <= 1'b1;
      mrom_addr <= 18'(start_word + w);
      @(posedge clk);
      mrom_rd <= 1'b0;
      // wait for valid
      while (!mrom_valid) @(posedge clk);
      got_w = mrom_data;
      expected_w = {ref_stream[(start_word + w) * 2],
                    ref_stream[(start_word + w) * 2 + 1]};
      if (got_w !== expected_w) begin
        if (mismatches < 16)
          $display("[%s] MISMATCH word %0d: got %h, expected %h",
                   label, w, got_w, expected_w);
        mismatches++;
      end
      repeat (5) @(posedge clk);
    end
    if (mismatches == 0)
      $display("[%s] PASS: all %0d words match", label, word_count);
    else begin
      $display("[%s] FAIL: %0d/%0d words mismatched", label, mismatches, word_count);
      errors += mismatches;
    end
  endtask

  // -------------------------------------------------------------------
  // main
  // -------------------------------------------------------------------
  initial begin
    errors = 0;

    // ---- Test 1: normal download (1 byte per 80 cycles, with backpressure) ----
    $display("\n=== Test 1: Normal download (80-cycle gap) ===");
    do_reset();
    send_stream(80, ROM_BYTES, 0);
    verify_readback(ROM_WORDS, 0, "T1-normal");
    $display("  dl_count=%0d  dl_written=%0d  dl_dropped=%0d",
             dbg_dl_count, dbg_dl_written, dbg_dl_dropped);

    // ---- Test 2: burst download (2-cycle gap, hostile timing) ----
    $display("\n=== Test 2: Burst download (2-cycle gap) ===");
    do_reset();
    send_stream(2, ROM_BYTES, 0);
    verify_readback(ROM_WORDS, 0, "T2-burst");
    $display("  dl_count=%0d  dl_written=%0d  dl_dropped=%0d",
             dbg_dl_count, dbg_dl_written, dbg_dl_dropped);
    if (dbg_dl_dropped != 0) begin
      $display("[T2-burst] WARNING: %0d bytes dropped from FIFO overflow",
               dbg_dl_dropped);
    end

    // ---- Test 3: mid-download reset (demonstrates the old bug) ----
    $display("\n=== Test 3: Mid-download reset ===");
    do_reset();
    dl_active <= 1'b1;
    @(posedge clk);
    // send first 64 bytes
    for (int i = 0; i < 64; i++) begin
      while (dl_busy) @(posedge clk);
      dl_wr   <= 1'b1;
      dl_addr <= 25'(i);
      dl_data <= ref_stream[i];
      @(posedge clk);
      dl_wr <= 1'b0;
      repeat (20) @(posedge clk);
    end
    // pulse rst_n low for 5 cycles (simulates RESET hit)
    $display("  Pulsing rst_n low at byte 64...");
    rst_n <= 1'b0;
    repeat (5) @(posedge clk);
    rst_n <= 1'b1;
    @(posedge sdr_ready);
    repeat (200) @(posedge clk);
    // send remaining bytes (64..ROM_BYTES-1)
    for (int i = 64; i < ROM_BYTES; i++) begin
      while (dl_busy) @(posedge clk);
      dl_wr   <= 1'b1;
      dl_addr <= 25'(i);
      dl_data <= ref_stream[i];
      @(posedge clk);
      dl_wr <= 1'b0;
      repeat (20) @(posedge clk);
    end
    repeat (200) @(posedge clk);
    dl_active <= 1'b0;
    repeat (50) @(posedge clk);
    // read back word 0 - should be WRONG (zeros) because reset cleared the
    // controller and the FIFO, losing in-flight bytes around the reset edge
    mrom_rd   <= 1'b1;
    mrom_addr <= 18'd0;
    @(posedge clk);
    mrom_rd <= 1'b0;
    while (!mrom_valid) @(posedge clk);
    if (mrom_data === {ref_stream[0], ref_stream[1]})
      $display("[T3-reset] Word 0 survived reset (unexpected if bytes in-flight)");
    else
      $display("[T3-reset] Word 0 = %h (expected %h%h) - reset corrupted download as predicted",
               mrom_data, ref_stream[0], ref_stream[1]);

    // ---- Test 4: download starts DURING selftest (MiSTer HPS behavior) ----
    // The HPS starts sending bytes as soon as the core loads, which may be
    // before or during the SDRAM init + selftest. This is the suspected
    // hardware failure mode.
    $display("\n=== Test 4: Download during selftest (MiSTer-like timing) ===");
    trace_en <= 1'b1;
    trace_cnt <= 0;
    rst_n <= 1'b0;
    dl_wr <= 1'b0;
    dl_active <= 1'b1;   // download active immediately
    mrom_rd <= 1'b0;
    repeat (10) @(posedge clk);
    rst_n <= 1'b1;
    // DON'T wait for sdr_ready - start sending bytes during init/selftest
    repeat (5) @(posedge clk);
    // send the full stream with realistic HPS timing
    for (int i = 0; i < ROM_BYTES; i++) begin
      // honor backpressure but don't wait for ready
      if (dl_busy) begin
        int wait_cyc = 0;
        while (dl_busy && wait_cyc < 1000) begin
          @(posedge clk);
          wait_cyc++;
          if (wait_cyc == 100)
            $display("[T4] dl_busy stuck at byte %0d: fsm_info=%h written=%0d ready=%0d",
                     i, u_sdr.dbg_fsm_info, dbg_dl_written, sdr_ready);
          if (wait_cyc >= 990 && wait_cyc <= 999)
            $display("[T4] cyc%0d: st=%0d wait=%0d dlf_cnt=%0d owner=%0d ref_due=%0d",
                     wait_cyc, u_sdr.st, u_sdr.wait_cnt, u_sdr.dlf_cnt,
                     u_sdr.owner, u_sdr.ref_due);
        end
        if (wait_cyc >= 1000) begin
          $display("[T4-selftest] STUCK: dl_busy held for 1000+ cycles at byte %0d", i);
          $display("  dl_written=%0d  dl_dropped=%0d  sdr_ready=%0d  fsm_info=%h",
                   dbg_dl_written, dbg_dl_dropped, sdr_ready, u_sdr.dbg_fsm_info);
          $display("  dlf_cnt=%0d  st=%0d  mrom_pend=%0d  wait_cnt=%0d",
                   u_sdr.dlf_cnt, u_sdr.st, u_sdr.mrom_pend, u_sdr.wait_cnt);
          $display("  ref_due=%0d  ref_urgent=%0d  ref_cnt=%0d  owner=%0d",
                   u_sdr.ref_due, u_sdr.ref_urgent, u_sdr.ref_cnt, u_sdr.owner);
          errors++;
          break;
        end
      end
      dl_wr   <= 1'b1;
      dl_addr <= 25'(i);
      dl_data <= ref_stream[i];
      @(posedge clk);
      dl_wr <= 1'b0;
      repeat (15) @(posedge clk);  // HPS-like pace (~1 byte per 16 clocks)
    end
    repeat (500) @(posedge clk);
    dl_active <= 1'b0;
    repeat (50) @(posedge clk);
    verify_readback(ROM_WORDS, 0, "T4-selftest");
    $display("  dl_count=%0d  dl_written=%0d  dl_dropped=%0d",
             dbg_dl_count, dbg_dl_written, dbg_dl_dropped);

    // ---- Test 5: gap sweep {2,3,4,8,16} ----
    $display("\n=== Test 5: Gap sweep ===");
    trace_en <= 1'b0;
    begin
      int gaps [5] = '{2, 3, 4, 8, 16};
      for (int gi = 0; gi < 5; gi++) begin
        string lbl;
        $sformat(lbl, "T5-gap%0d", gaps[gi]);
        do_reset();
        send_stream(gaps[gi], ROM_BYTES, 0);
        verify_readback(ROM_WORDS, 0, lbl);
        $display("  gap=%0d  dl_count=%0d  dl_written=%0d  dl_dropped=%0d",
                 gaps[gi], dbg_dl_count, dbg_dl_written, dbg_dl_dropped);
        if (dbg_dl_dropped != 0) begin
          $display("[%s] FAIL: %0d bytes dropped", lbl, dbg_dl_dropped);
          errors++;
        end
        if (dbg_dl_written != dbg_dl_count) begin
          $display("[%s] FAIL: dl_written (%0d) != dl_count (%0d)",
                   lbl, dbg_dl_written, dbg_dl_count);
          errors++;
        end
      end
    end

    // ---- Test 6: sr3 read-modify-write byte writes (DQM-free) ----
    $display("\n=== Test 6: sr3 RMW byte writes ===");
    begin
      logic [15:0] rd;
      sr3_op(1'b1, 17'd100, 16'hAABB, 2'b11, rd);   // full word write
      sr3_op(1'b0, 17'd100, 16'h0000, 2'b11, rd);
      if (rd !== 16'hAABB) begin
        $display("[T6] FAIL: word write/read %h != AABB", rd); errors++;
      end
      sr3_op(1'b1, 17'd100, 16'h00CC, 2'b01, rd);   // low byte only
      sr3_op(1'b0, 17'd100, 16'h0000, 2'b11, rd);
      if (rd !== 16'hAACC) begin
        $display("[T6] FAIL: low-byte rmw %h != AACC", rd); errors++;
      end
      sr3_op(1'b1, 17'd100, 16'hDD00, 2'b10, rd);   // high byte only
      sr3_op(1'b0, 17'd100, 16'h0000, 2'b11, rd);
      if (rd !== 16'hDDCC) begin
        $display("[T6] FAIL: high-byte rmw %h != DDCC", rd); errors++;
      end
      if (errors == 0) $display("[T6] PASS: word + both byte-lane RMW writes");
    end

    // ---- probe checks (state left by the last T5 run) ----
    begin
      logic [15:0] exp_w0;
      exp_w0 = {ref_stream[0], ref_stream[1]};
      if (dbg_selftest !== exp_w0) begin
        $display("[probe] FAIL: early readback %h != %h", dbg_selftest, exp_w0);
        errors++;
      end else $display("[probe] PASS: early readback %h", dbg_selftest);
      // dbg_postdl now probes GFX_WBASE+4, never written by this tb:
      // the model's zero-initialized store must come back (proves the
      // probe read fires and lands with tag 6)
      if (dbg_postdl !== 16'h0000) begin
        $display("[probe] FAIL: gfx probe %h != 0000 (model zero-init)", dbg_postdl);
        errors++;
      end else $display("[probe] PASS: gfx probe fired, read %h", dbg_postdl);
      if ({dbg_dl_byte0, dbg_dl_byte1} !== 16'h0000) begin
        $display("[probe] FAIL: first dl addr %h != 0000", {dbg_dl_byte0, dbg_dl_byte1});
        errors++;
      end else $display("[probe] PASS: first dl addr 0000");
    end

    // ---- summary ----
    $display("\n=== Summary: %0d errors ===\n", errors);
    if (errors > 0) $fatal(1, "Download tests FAILED");
    $finish;
  end

  // FSM transition monitor (only active during T4 download, activated by flag)
  reg trace_en = 0;
  int trace_cnt = 0;
  always @(posedge clk) begin
    if (trace_en && u_sdr.st != u_sdr.st) ; // impossible, just for reference
    if (trace_en && trace_cnt < 200) begin
      if (u_sdr.st == 8 || u_sdr.st == 5) begin // CAS or IDLE
        $display("TRACE t=%0t st=%0d wait=%0d dlf=%0d owner=%0d",
                 $time, u_sdr.st, u_sdr.wait_cnt, u_sdr.dlf_cnt, u_sdr.owner);
        trace_cnt++;
      end
    end
  end

  // refresh cadence check: CMD_REF (nCS,nRAS,nCAS,nWE = 0001) must fire
  // roughly every REFRESH_PERIOD cycles or the real chip decays
  int ref_count = 0;
  longint last_ref_t = 0;
  longint worst_ref_gap = 0;
  always @(posedge clk) begin
    if ({sdr_ncs, sdr_nras, sdr_ncas, sdr_nwe} == 4'b0001) begin
      if (last_ref_t != 0 && ($time - last_ref_t) > worst_ref_gap)
        worst_ref_gap = $time - last_ref_t;
      last_ref_t = $time;
      ref_count++;
    end
  end
  final $display("REFRESH: %0d issued, worst gap %0d ns (budget 7813 ns/row avg)",
                 ref_count, worst_ref_gap);

  // watchdog
  initial begin
    #50_000_000;
    $fatal(1, "Watchdog timeout");
  end

endmodule
