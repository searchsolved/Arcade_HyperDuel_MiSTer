// End-to-end testbench for rtl/i4220_vdp.sv.
//
// Loads a MAME state dump by writing EVERYTHING through the CPU bus
// (VRAM/palette/sprite/tiletable via their windows, registers via their
// addresses), then lets the VDP free-run its own video timing and captures
// the scan-out RGB of a later frame (so the vblank sprite-buffer copy has
// happened). Output PPM is diffed against MAME's snapshot.
//
// Usage: +SCENE=<dir> +OUT=<file.ppm> [+GFXSIZE=<bytes>]

`timescale 1ns/1ps

module tb_vdp;

  localparam int GFX_AW = 22;
  localparam int WIDTH = 320, HEIGHT = 224;

  logic clk;
  logic rst_n;
  initial clk = 0;
  always #5 clk = ~clk;

  logic [15:0] img_vram0 [0:65535];
  logic [15:0] img_vram1 [0:65535];
  logic [15:0] img_vram2 [0:65535];
  logic [15:0] img_tt [0:1023];
  logic [15:0] img_pal [0:4095];
  logic [15:0] img_spr [0:2047];
  logic [15:0] img_regs [0:21];
  logic [7:0]  gfxrom [0:(1<<GFX_AW)-1];

  int gfx_size;

  // DUT
  logic        cs;
  logic [18:0] addr;
  logic        rnw;
  logic [1:0]  be;
  logic [15:0] wdata, rdata;
  logic        ack;
  logic        hs, vs, de, ce_pix;
  logic [4:0]  r5, g5, b5;
  logic        irq, vbl;
  logic              rom_req;
  logic [GFX_AW-1:0] rom_addr;
  logic [6:0]        rom_len;
  logic [7:0]        rom_data;
  logic              rom_valid;

  // P_PIXDIV 32 gives the renderer sim headroom; closing real-time at the
  // hardware ratio (~12-14 sys clocks per pixel) is an M4 task with a
  // defined optimization menu (parallel layer/sprite engines, per-frame
  // sprite setup cache, multi-pixel emit).
  i4220_vdp #(.GFX_AW(GFX_AW), .P_PIXDIV(32)) dut (
    .clk(clk), .rst_n(rst_n),
    .i_cs(cs), .i_addr(addr), .i_rnw(rnw), .i_be(be),
    .i_wdata(wdata), .o_rdata(rdata), .o_ack(ack),
    .o_hs(hs), .o_vs(vs), .o_de(de), .o_ce_pix(ce_pix),
    /* verilator lint_off PINCONNECTEMPTY */
    .o_hblank(), .o_vblank(),
    /* verilator lint_on PINCONNECTEMPTY */
    .o_r(r5), .o_g(g5), .o_b(b5),
    .o_irq(irq), .o_vbl_pulse(vbl),
    .o_rom_req(rom_req), .o_rom_addr(rom_addr), .o_rom_len(rom_len),
    .i_rom_data(rom_data), .i_rom_valid(rom_valid),
    .i_gfx_size(24'(gfx_size)),
    /* verilator lint_off PINCONNECTEMPTY */
    .o_dbg_vdp_write(), .o_dbg_line_start(),
    .o_dbg_rnd_done(), .o_dbg_lb_nonzero(), .o_dbg_palw()
    /* verilator lint_on PINCONNECTEMPTY */
  );

  // ROM stream server (pulse req -> latency -> len bytes with a gap)
  logic [GFX_AW-1:0] srv_addr;
  logic [6:0]        srv_left;
  int                srv_wait;
  logic              srv_active;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      srv_active <= 1'b0;
      rom_valid  <= 1'b0;
    end else begin
      rom_valid <= 1'b0;
      if (!srv_active) begin
        if (rom_req) begin
          srv_active <= 1'b1;
          srv_addr   <= rom_addr;
          srv_left   <= rom_len;
          srv_wait   <= int'(rom_addr[1:0]) + 1;
        end
      end else if (srv_wait > 0) begin
        srv_wait <= srv_wait - 1;
      end else begin
        rom_valid <= 1'b1;
        rom_data  <= gfxrom[srv_addr];
        srv_addr  <= srv_addr + 1'b1;
        if (srv_left == 7'd1) srv_active <= 1'b0;
        else begin
          srv_left <= srv_left - 7'd1;
          if (srv_addr[2:0] == 3'd4) srv_wait <= 2;
        end
      end
    end
  end

  // frame capture (resynced to vsync so cap_y 0 = screen line 0)
  logic [23:0] frame [0:HEIGHT-1][0:WIDTH-1];
  int cap_x, cap_y;
  logic de_d, vs_d;
  int frames_seen;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cap_x <= 0;
      cap_y <= 0;
      frames_seen <= 0;
      de_d <= 0;
      vs_d <= 0;
    end else if (ce_pix) begin
      de_d <= de;
      vs_d <= vs;
      if (vs && !vs_d) begin        // frame boundary
        cap_x <= 0;
        cap_y <= 0;
        frames_seen <= frames_seen + 1;
      end else if (de) begin
        if (cap_y < HEIGHT && cap_x < WIDTH)
          frame[cap_y][cap_x] <= {r5, r5[4:2], g5, g5[4:2], b5, b5[4:2]};
        cap_x <= cap_x + 1;
      end else if (de_d) begin      // falling edge: end of visible line
        cap_x <= 0;
        cap_y <= cap_y + 1;
      end
    end
  end

  // lateness probe: report renders finishing after their display started
  longint disp_start [0:223];
  longint t_now;
  int cur_render_line;
  always_ff @(posedge clk) begin
    t_now <= t_now + 1;
    if (ce_pix && dut.hcnt == 0 && dut.vcnt < 224) disp_start[dut.vcnt[7:0]] <= t_now;
    if (dut.rnd_start) cur_render_line <= int'(dut.rnd_line);

  end

  // render timing instrumentation (hierarchical probes)
  int rt_cycles, rt_max, rt_line_of_max, rt_active;
  int lateness_max;
  always_ff @(posedge clk) begin
    if (dut.rnd_start) begin
      rt_active <= 1;
      rt_cycles <= 0;
    end else if (rt_active != 0) begin
      rt_cycles <= rt_cycles + 1;
      if (dut.rnd_done) begin
        rt_active <= 0;
        if (rt_cycles > rt_max) begin
          rt_max <= rt_cycles;
          rt_line_of_max <= int'(dut.rnd_line);
        end
      end
    end
  end

  task automatic bus_write(input logic [18:0] a, input logic [15:0] d);
    @(posedge clk);
    cs = 1; addr = a; rnw = 0; be = 2'b11; wdata = d;
    do @(posedge clk); while (!ack);
    cs = 0;
    @(posedge clk);
  endtask

  initial begin : run
    string scene, outpath;
    int fh, x, y, i, startframes;

    if (!$value$plusargs("SCENE=%s", scene))  $fatal(1, "need +SCENE=<dir>");
    if (!$value$plusargs("OUT=%s", outpath))  $fatal(1, "need +OUT=<file>");
    if (!$value$plusargs("GFXSIZE=%d", gfx_size)) gfx_size = 1 << GFX_AW;

    $readmemh({scene, "/vram0.hex"},     img_vram0);
    $readmemh({scene, "/vram1.hex"},     img_vram1);
    $readmemh({scene, "/vram2.hex"},     img_vram2);
    $readmemh({scene, "/tiletable.hex"}, img_tt);
    $readmemh({scene, "/palette.hex"},   img_pal);
    $readmemh({scene, "/spriteram.hex"}, img_spr);
    $readmemh({scene, "/regs.hex"},      img_regs);
    $readmemh({scene, "/gfxrom.hex"},    gfxrom);

    cs = 0; addr = '0; rnw = 1; be = 2'b11; wdata = '0;
    rst_n = 0;
    repeat (8) @(posedge clk);
    rst_n = 1;
    repeat (4) @(posedge clk);

    // registers first (so rendering during the load is harmless), then RAMs
    bus_write(19'h79700, img_regs[0]);   // sprite count
    bus_write(19'h79702, img_regs[1]);   // sprite priority
    bus_write(19'h79704, img_regs[2]);   // sprite y offset
    bus_write(19'h79706, img_regs[3]);   // sprite x offset
    bus_write(19'h79708, img_regs[4]);   // sprite color code
    bus_write(19'h79710, img_regs[5]);   // layer priority
    bus_write(19'h79712, img_regs[6]);   // background color
    bus_write(19'h78852, img_regs[7]);   // screen x offset
    bus_write(19'h78850, img_regs[8]);   // screen y offset
    bus_write(19'h788AC, img_regs[9]);   // screen control
    for (i = 0; i < 6; i++) begin
      bus_write(19'(19'h78860 + i*2), img_regs[10 + i]);  // windows
      bus_write(19'(19'h78870 + i*2), img_regs[16 + i]);  // scrolls
    end

    for (i = 0; i < 1024; i++) bus_write(19'(19'h78000 + i*2), img_tt[i]);
    for (i = 0; i < 4096; i++) bus_write(19'(19'h72000 + i*2), img_pal[i]);
    for (i = 0; i < 2048; i++) bus_write(19'(19'h74000 + i*2), img_spr[i]);
    for (i = 0; i < 65536; i++) begin
      bus_write(19'(19'h00000 + i*2), img_vram0[i]);
      bus_write(19'(19'h20000 + i*2), img_vram1[i]);
      bus_write(19'(19'h40000 + i*2), img_vram2[i]);
    end
    $display("tb_vdp: state loaded via bus (%0d frames elapsed)", frames_seen);

    // wait 3 more complete frames: one to hit the vblank sprite copy,
    // one fully-rendered afterwards, capture the third
    startframes = frames_seen;
    wait (frames_seen == startframes + 3);

    fh = $fopen(outpath, "w");
    if (fh == 0) $fatal(1, "cannot open %s", outpath);
    $fwrite(fh, "P3\n%0d %0d\n255\n", WIDTH, HEIGHT);
    for (y = 0; y < HEIGHT; y++) begin
      for (x = 0; x < WIDTH; x++)
        $fwrite(fh, "%0d %0d %0d ",
                frame[y][x][23:16], frame[y][x][15:8], frame[y][x][7:0]);
      $fwrite(fh, "\n");
    end
    $fclose(fh);
    $display("tb_vdp: rendered %s -> %s", scene, outpath);
    $display("tb_vdp: max line render = %0d cycles (line %0d), budget/line = %0d, fifo overrun=%0d",
             rt_max, rt_line_of_max, 424*32, dut.rnd_overrun);
    $display("tb_vdp: bpp8 probe: fetched=%0d opaque_px=%0d", bpp8_fetch, bpp8_px);
    $finish;
  end

  // 8bpp tile probe: count tile fetches flagged 8bpp and opaque 8bpp pixels
  int bpp8_fetch, bpp8_px;
  logic bpp8_d;
  always_ff @(posedge clk) begin
    bpp8_d <= dut.u_render.cache_bpp8;
    if (dut.u_render.cache_bpp8 && !bpp8_d) bpp8_fetch <= bpp8_fetch + 1;
    if (dut.u_render.cache_bpp8 && dut.u_render.tile_opaque
        && dut.u_render.st == dut.u_render.ST_L_PIX) bpp8_px <= bpp8_px + 1;
  end

endmodule
