// Testbench for rtl/i4220_blitter.sv against the blitter oracle.
//
// Loads a blit scene (initial VRAM images, GFX ROM, blit register list),
// runs every blit through the RTL with a variable-latency ROM handshake,
// dumps final VRAM as hex and the observed done/IRQ count.
//
// Usage: +SCENE=<dir> +NBLITS=<n> +OUTDIR=<dir> [+GFXSIZE=<bytes>]

`timescale 1ns/1ps

module tb_blitter;

  localparam int GFX_AW = 19;   // 512 KB synthetic scenes
  localparam int MAXBLITS = 64;

  logic clk;
  logic rst_n;
  initial clk = 0;
  always #5 clk = ~clk;

  logic [15:0] vram0 [0:65535];
  logic [15:0] vram1 [0:65535];
  logic [15:0] vram2 [0:65535];
  logic [7:0]  gfxrom [0:(1<<GFX_AW)-1];
  logic [31:0] blits [0:MAXBLITS*3-1];

  int gfx_size, nblits;

  // DUT
  logic        start;
  logic [31:0] r_tmap, r_src, r_dst;
  logic              rom_rd;
  logic [GFX_AW-1:0] rom_addr;
  logic [7:0]        rom_data;
  logic              rom_valid;
  logic        vram_we;
  logic [1:0]  vram_layer;
  logic [15:0] vram_addr, vram_wdata, vram_wmask;
  logic        busy, done;

  i4220_blitter #(.GFX_AW(GFX_AW)) dut (
    .clk(clk), .rst_n(rst_n),
    .i_start(start), .i_tmap(r_tmap), .i_src(r_src), .i_dst(r_dst),
    .o_rom_rd(rom_rd), .o_rom_addr(rom_addr),
    .i_rom_data(rom_data), .i_rom_valid(rom_valid),
    .o_vram_we(vram_we), .o_vram_layer(vram_layer), .o_vram_addr(vram_addr),
    .o_vram_wdata(vram_wdata), .o_vram_wmask(vram_wmask),
    .o_busy(busy), .o_done(done)
  );

  // ROM model: variable latency (1..4 cycles, derived from address bits),
  // request = rom_rd high; one valid pulse per request; back-to-back
  // requests with rom_rd held high are re-latched after each valid.
  logic              req_pending;
  logic [GFX_AW-1:0] req_addr;
  int                req_lat;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      req_pending <= 1'b0;
      rom_valid   <= 1'b0;
    end else begin
      rom_valid <= 1'b0;
      if (!req_pending) begin
        // protocol: rd during the delivery cycle is the tail of the old
        // request, not a new one (requester clears rd one edge after valid)
        if (rom_rd && !rom_valid) begin
          req_pending <= 1'b1;
          req_addr    <= rom_addr;
          req_lat     <= int'(rom_addr[1:0]) + 1;
        end
      end else begin
        if (req_lat > 1) begin
          req_lat <= req_lat - 1;
        end else begin
          rom_valid   <= 1'b1;
          rom_data    <= gfxrom[req_addr];
          req_pending <= 1'b0;
        end
      end
    end
  end

  // VRAM write port
  int trace_n;
  always_ff @(posedge clk) begin
    if (vram_we) begin
      if ($test$plusargs("TRACE") && trace_n < 60) begin
        $display("wr layer=%0d addr=%04x data=%04x mask=%04x",
                 vram_layer, vram_addr, vram_wdata, vram_wmask);
        trace_n <= trace_n + 1;
      end
      unique case (vram_layer)
        2'd0: vram0[vram_addr] <= (vram0[vram_addr] & ~vram_wmask) | (vram_wdata & vram_wmask);
        2'd1: vram1[vram_addr] <= (vram1[vram_addr] & ~vram_wmask) | (vram_wdata & vram_wmask);
        default: vram2[vram_addr] <= (vram2[vram_addr] & ~vram_wmask) | (vram_wdata & vram_wmask);
      endcase
    end
  end

  int irq_count;
  always_ff @(posedge clk)
    if (!rst_n) irq_count <= 0;
    else if (done) irq_count <= irq_count + 1;

  initial begin : run
    string scene, outdir;
    int b, t, fh, i, l;

    if (!$value$plusargs("SCENE=%s", scene))   $fatal(1, "need +SCENE=<dir>");
    if (!$value$plusargs("OUTDIR=%s", outdir)) $fatal(1, "need +OUTDIR=<dir>");
    if (!$value$plusargs("NBLITS=%d", nblits)) $fatal(1, "need +NBLITS=<n>");
    if (!$value$plusargs("GFXSIZE=%d", gfx_size)) gfx_size = 1 << GFX_AW;

    $readmemh({scene, "/vram0.hex"},  vram0);
    $readmemh({scene, "/vram1.hex"},  vram1);
    $readmemh({scene, "/vram2.hex"},  vram2);
    $readmemh({scene, "/gfxrom.hex"}, gfxrom);
    $readmemh({scene, "/blits.hex"},  blits);

    start = 0;
    rst_n = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);

    for (b = 0; b < nblits; b++) begin
      r_tmap = blits[b*3 + 0];
      r_src  = blits[b*3 + 1];
      r_dst  = blits[b*3 + 2];
      @(posedge clk);
      start = 1;
      @(posedge clk);
      start = 0;
      // invalid-tmap blits never raise busy; give them a few idle cycles
      repeat (4) @(posedge clk);
      t = 0;
      while (busy) begin
        @(posedge clk);
        t++;
        if (t > 8_000_000) $fatal(1, "blit %0d timeout", b);
      end
      repeat (4) @(posedge clk);
      if ($test$plusargs("SIGS")) begin : sig
        logic [31:0] s0, s1, s2;
        s0 = 0; s1 = 0; s2 = 0;
        for (i = 0; i < 65536; i++) begin
          s0 += 32'(vram0[i]); s1 += 32'(vram1[i]); s2 += 32'(vram2[i]);
        end
        $display("after blit %2d: ['0x%08x', '0x%08x', '0x%08x']", b, s0, s1, s2);
      end
    end

    for (l = 0; l < 3; l++) begin
      fh = $fopen($sformatf("%s/vram%0d.out.hex", outdir, l), "w");
      if (fh == 0) $fatal(1, "cannot open output %0d", l);
      for (i = 0; i < 65536; i++)
        $fwrite(fh, "%04x\n", (l == 0) ? vram0[i] : (l == 1) ? vram1[i] : vram2[i]);
      $fclose(fh);
    end
    fh = $fopen({outdir, "/irqs.out"}, "w");
    $fwrite(fh, "%0d\n", irq_count);
    $fclose(fh);

    $display("tb_blitter: %0d blits done, %0d IRQs -> %s", nblits, irq_count, outdir);
    $finish;
  end

endmodule
