// Testbench for rtl/i4220_render.sv - renders a full frame from scene /
// MAME-dump hex files through the real scanline RTL and writes a P3 PPM.
//
// Serves registered 1-cycle BRAM ports and the streaming ROM port (variable
// initial latency, optional mid-stream gaps) to prove the FSM is
// latency-insensitive.
//
// Usage: +SCENE=<dir> +OUT=<file.ppm> [+GFXSIZE=<bytes>]

`timescale 1ns/1ps

module tb_render;

  localparam int GFX_AW = 22;
  localparam int WIDTH = 320, HEIGHT = 224;

  logic clk;
  logic rst_n;
  initial clk = 0;
  always #5 clk = ~clk;

  logic [15:0] vram0 [0:65535];
  logic [15:0] vram1 [0:65535];
  logic [15:0] vram2 [0:65535];
  logic [15:0] tiletable [0:1023];
  logic [15:0] palette [0:4095];
  logic [15:0] spriteram [0:2047];
  logic [7:0]  gfxrom [0:(1<<GFX_AW)-1];
  logic [15:0] regs [0:21];

  int gfx_size;

  // DUT hookup
  logic        start;
  logic [7:0]  line;
  logic        busy, done;
  logic [15:0] scroll_x [3];
  logic [15:0] scroll_y [3];
  logic [15:0] window_x [3];
  logic [15:0] window_y [3];
  logic [15:0] sw_x [3];
  logic [15:0] sw_y [3];
  logic [15:0] vram_addr16;
  logic [15:0] vram_q [3];
  logic [9:0]  tt_addr;
  logic [15:0] tt_q;
  logic [10:0] spr_addr;
  logic [15:0] spr_q;
  logic              rom_req;
  logic [GFX_AW-1:0] rom_addr;
  logic [6:0]        rom_len;
  logic [15:0]       rom_data;
  logic              rom_valid;
  logic        lb_we;
  logic [8:0]  lb_x;
  logic [11:0] lb_pen;
  logic [8:0]  pst_addr;   // prescan port unused: table absent, valid tied 0

  i4220_render #(.GFX_AW(GFX_AW)) dut (
    .clk(clk), .rst_n(rst_n),
    .i_start(start), .i_line(line), .o_busy(busy), .o_done(done),
    .i_layer_pri(regs[5][5:0]),
    .i_bg_color(regs[6][11:0]),
    .i_screen_ctrl(regs[9]),
    .i_window_x(window_x), .i_window_y(window_y),
    .i_sw_x(sw_x), .i_sw_y(sw_y),
    .i_spr_count(regs[0]), .i_spr_pri(regs[1]),
    .i_spr_xoff(regs[3]), .i_spr_yoff(regs[2]),
    .i_spr_color(regs[4]),
    .i_screen_xoff(regs[7]), .i_screen_yoff(regs[8]),
    .i_gfx_size(24'(gfx_size)),
    .o_vram_addr(vram_addr16), .i_vram_data(vram_q),
    .o_tt_addr(tt_addr), .i_tt_data(tt_q),
    .o_spr_addr(spr_addr), .i_spr_data(spr_q),
    .o_pst_addr(pst_addr), .i_pst_data(24'd0), .i_pst_valid(1'b0),
    .o_rom_req(rom_req), .o_rom_addr(rom_addr), .o_rom_len(rom_len),
    .i_rom_data(rom_data), .i_rom_valid(rom_valid),
    .o_lb_we(lb_we), .o_lb_x(lb_x), .o_lb_pen(lb_pen)
  );

  // register file decode into arrays (window/scroll: y,x per layer)
  always_comb begin
    for (int l = 0; l < 3; l++) begin
      window_y[l] = regs[10 + l*2];
      window_x[l] = regs[11 + l*2];
      scroll_y[l] = regs[16 + l*2];
      scroll_x[l] = regs[17 + l*2];
      sw_y[l] = scroll_y[l] - window_y[l];
      sw_x[l] = scroll_x[l] - window_x[l];
    end
  end

  // BRAM models (registered 1-cycle reads)
  always_ff @(posedge clk) begin
    vram_q[0] <= vram0[vram_addr16];
    vram_q[1] <= vram1[vram_addr16];
    vram_q[2] <= vram2[vram_addr16];
    tt_q      <= tiletable[tt_addr];
    spr_q     <= spriteram[spr_addr];
  end

  // ROM stream server: pulse request -> initial latency -> len bytes,
  // with a gap every 5th byte to prove latency insensitivity
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
      end else begin
        if (srv_wait > 0) begin
          srv_wait <= srv_wait - 1;
        end else begin
          // word-mode stream: two bytes per valid, even byte in [15:8]
          rom_valid <= 1'b1;
          rom_data  <= {gfxrom[srv_addr], gfxrom[srv_addr + 1]};
          srv_addr  <= srv_addr + 22'd2;
          if (srv_left == 7'd2) srv_active <= 1'b0;
          else begin
            srv_left <= srv_left - 7'd2;
            if (srv_addr[3:0] == 4'd4) srv_wait <= 2;  // mid-stream gap
          end
        end
      end
    end
  end

  // line capture
  logic [11:0] linebuf [0:WIDTH-1];
  always_ff @(posedge clk) if (lb_we) linebuf[lb_x] <= lb_pen;

  logic [11:0] frame [0:HEIGHT-1][0:WIDTH-1];

  function automatic logic [23:0] pal_rgb(input logic [11:0] pen);
    logic [15:0] v;
    logic [4:0] r5, g5, b5;
    v  = palette[pen];
    g5 = v[15:11]; r5 = v[10:6]; b5 = v[5:1];
    pal_rgb = {r5, r5[4:2], g5, g5[4:2], b5, b5[4:2]};
  endfunction

  initial begin : run
    string scene, outpath;
    int fh, x, y, t;
    logic [23:0] rgb;

    if (!$value$plusargs("SCENE=%s", scene))  $fatal(1, "need +SCENE=<dir>");
    if (!$value$plusargs("OUT=%s", outpath))  $fatal(1, "need +OUT=<file>");
    if (!$value$plusargs("GFXSIZE=%d", gfx_size)) gfx_size = 1 << GFX_AW;

    $readmemh({scene, "/vram0.hex"},     vram0);
    $readmemh({scene, "/vram1.hex"},     vram1);
    $readmemh({scene, "/vram2.hex"},     vram2);
    $readmemh({scene, "/tiletable.hex"}, tiletable);
    $readmemh({scene, "/palette.hex"},   palette);
    $readmemh({scene, "/spriteram.hex"}, spriteram);
    $readmemh({scene, "/gfxrom.hex"},    gfxrom);
    $readmemh({scene, "/regs.hex"},      regs);

    start = 0;
    rst_n = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);

    for (y = 0; y < HEIGHT; y++) begin
      line = 8'(y);
      @(posedge clk);
      start = 1;
      @(posedge clk);
      start = 0;
      t = 0;
      do begin
        @(posedge clk);
        t++;
        if (t > 2_000_000) $fatal(1, "line %0d timeout", y);
      end while (!done);
      @(posedge clk);   // let the final buffered write land
      for (x = 0; x < WIDTH; x++) frame[y][x] = linebuf[x];
    end

    fh = $fopen(outpath, "w");
    if (fh == 0) $fatal(1, "cannot open %s", outpath);
    $fwrite(fh, "P3\n%0d %0d\n255\n", WIDTH, HEIGHT);
    for (y = 0; y < HEIGHT; y++) begin
      for (x = 0; x < WIDTH; x++) begin
        rgb = pal_rgb(frame[y][x]);
        $fwrite(fh, "%0d %0d %0d ", rgb[23:16], rgb[15:8], rgb[7:0]);
      end
      $fwrite(fh, "\n");
    end
    $fclose(fh);
    $display("tb_render: rendered %s -> %s", scene, outpath);
    $finish;
  end

endmodule
