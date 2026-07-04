// I4220 frame-render model (M1).
//
// Behavioural SystemVerilog implementation of the render semantics in
// docs/i4220_spec.md, verified pixel-for-pixel against the Python oracle
// (itself a direct port of MAME's imagetek_i4100.cpp draw path).
//
// This is NOT the final pipelined RTL: it renders a whole frame procedurally
// from memory dumps. Its purpose is to lock down semantics; the decode
// functions below are the pieces that migrate into the real per-scanline
// pipeline (M3+). Memory access discipline (one port per BRAM per cycle,
// shared GFX ROM arbitration) is deliberately ignored here.
//
// Usage: +SCENE=<dir with .hex dumps> +OUT=<out.ppm> [+GFXSIZE=<bytes>]

`timescale 1ns/1ps

module i4220_model;

  localparam int WIDTH  = 320;
  localparam int HEIGHT = 224;
  localparam int MAX_GFX = 32'h0080_0000; // array upper bound (8 MB)

  // ------------------------------------------------------------------
  // Memories (dump images)
  // ------------------------------------------------------------------
  logic [15:0] vram0     [0:65535];
  logic [15:0] vram1     [0:65535];
  logic [15:0] vram2     [0:65535];
  logic [15:0] tiletable [0:1023];
  logic [15:0] palette   [0:4095];
  logic [15:0] spriteram [0:2047];
  logic [7:0]  gfxrom    [0:MAX_GFX-1];
  logic [15:0] regs      [0:21];

  int gfx_size;

  // reg file indices (order = REG_KEYS in the oracle)
  localparam int R_SPRCNT = 0,  R_SPRPRI = 1,  R_SPRYOFF = 2, R_SPRXOFF = 3;
  localparam int R_SPRCOL = 4,  R_LAYPRI = 5,  R_BGCOL   = 6;
  localparam int R_SCRXOFF = 7, R_SCRYOFF = 8, R_SCRCTRL = 9;
  localparam int R_WIN = 10; // +layer*2 : y, +layer*2+1 : x
  localparam int R_SCROLL = 16;

  // Exponential sprite zoom table (spec sec 7.1)
  logic [15:0] zoomtable [0:63];
  initial begin
    zoomtable[ 0]=16'h0AAC; zoomtable[ 1]=16'h0800; zoomtable[ 2]=16'h0668; zoomtable[ 3]=16'h0554;
    zoomtable[ 4]=16'h0494; zoomtable[ 5]=16'h0400; zoomtable[ 6]=16'h0390; zoomtable[ 7]=16'h0334;
    zoomtable[ 8]=16'h02E8; zoomtable[ 9]=16'h02AC; zoomtable[10]=16'h0278; zoomtable[11]=16'h0248;
    zoomtable[12]=16'h0224; zoomtable[13]=16'h0200; zoomtable[14]=16'h01E0; zoomtable[15]=16'h01C8;
    zoomtable[16]=16'h01B0; zoomtable[17]=16'h0198; zoomtable[18]=16'h0188; zoomtable[19]=16'h0174;
    zoomtable[20]=16'h0164; zoomtable[21]=16'h0154; zoomtable[22]=16'h0148; zoomtable[23]=16'h013C;
    zoomtable[24]=16'h0130; zoomtable[25]=16'h0124; zoomtable[26]=16'h011C; zoomtable[27]=16'h0110;
    zoomtable[28]=16'h0108; zoomtable[29]=16'h0100; zoomtable[30]=16'h00F8; zoomtable[31]=16'h00F0;
    zoomtable[32]=16'h00EC; zoomtable[33]=16'h00E4; zoomtable[34]=16'h00DC; zoomtable[35]=16'h00D8;
    zoomtable[36]=16'h00D4; zoomtable[37]=16'h00CC; zoomtable[38]=16'h00C8; zoomtable[39]=16'h00C4;
    zoomtable[40]=16'h00C0; zoomtable[41]=16'h00BC; zoomtable[42]=16'h00B8; zoomtable[43]=16'h00B4;
    zoomtable[44]=16'h00B0; zoomtable[45]=16'h00AC; zoomtable[46]=16'h00A8; zoomtable[47]=16'h00A4;
    zoomtable[48]=16'h00A0; zoomtable[49]=16'h009C; zoomtable[50]=16'h0098; zoomtable[51]=16'h0094;
    zoomtable[52]=16'h0090; zoomtable[53]=16'h008C; zoomtable[54]=16'h0088; zoomtable[55]=16'h0080;
    zoomtable[56]=16'h0078; zoomtable[57]=16'h0070; zoomtable[58]=16'h0068; zoomtable[59]=16'h0060;
    zoomtable[60]=16'h0058; zoomtable[61]=16'h0050; zoomtable[62]=16'h0048; zoomtable[63]=16'h0040;
  end

  // ------------------------------------------------------------------
  // Decode functions (these migrate to the real pipeline)
  // ------------------------------------------------------------------

  function automatic logic [15:0] vram_rd(input int layer, input int offs);
    case (layer)
      0: vram_rd = vram0[offs];
      1: vram_rd = vram1[offs];
      default: vram_rd = vram2[offs];
    endcase
  endfunction

  // GRBx_555 palette entry -> RGB888
  function automatic logic [23:0] pal_rgb(input logic [11:0] pen);
    logic [15:0] v;
    logic [4:0] r5, g5, b5;
    v  = palette[pen];
    g5 = v[15:11]; r5 = v[10:6]; b5 = v[5:1];
    pal_rgb = {r5, r5[4:2], g5, g5[4:2], b5, b5[4:2]};
  endfunction

  // Tile pixel decode: spec sec 3.2-3.4 (get_tile_pix equivalent).
  // Returns {opaque, rgb888}.
  function automatic logic [24:0] tile_pix(input int layer,
                                           input logic [15:0] code,
                                           input int x_in, input int y_in,
                                           input logic big);
    int table_index, tilesize, tileshift, x, y;
    logic [31:0] tile;
    logic [11:0] color;      // pre-shifted color bits (colorbyte << 4)
    logic        bpp8;
    logic [7:0]  trans, data, rom_byte;
    int tile2, base, rowbytes;
    begin
      x = x_in; y = y_in;
      table_index = int'({code[12:4], 1'b0}); // (code & 0x1FF0) >> 3
      tile = {tiletable[table_index], tiletable[table_index | 1]};

      if (code[15]) begin // solid color tile
        tile_pix = {(code[3:0] != 4'hF), pal_rgb(code[11:0])};
      end else begin
        tilesize = big ? 16 : 8;
        color = 12'((tile & 32'h0FF0_0000) >> 16);
        if ((color & 12'h0F0) == 12'h0F0) begin // 8bpp tile
          color = color & 12'hF00;
          trans = 8'hFF;
          tileshift = big ? 3 : 1;
          bpp8 = 1'b1;
        end else begin
          trans = 8'h0F;
          tileshift = big ? 2 : 0;
          bpp8 = 1'b0;
        end
        tile2 = int'(tile & 32'h000F_FFFF) + (int'(code[3:0]) << tileshift);

        if (tile2 >= gfx_size / 32) begin
          tile_pix = 25'd0; // out of range: transparent
        end else begin
          if (code[13]) y = tilesize - y - 1; // flip Y
          if (code[14]) x = tilesize - x - 1; // flip X
          base = tile2 * 32;
          if (bpp8) begin
            rowbytes = tilesize;             // 8 or 16
            data = gfxrom[base + y * rowbytes + x];
          end else begin
            rowbytes = tilesize / 2;         // 4 or 8
            rom_byte = gfxrom[base + y * rowbytes + (x >> 1)];
            // 4bpp packing: LEFT pixel = LOW nibble (same as sprites)
            data = ((x & 1) != 0) ? {4'd0, rom_byte[7:4]} : {4'd0, rom_byte[3:0]};
          end
          tile_pix = {((data & trans) != trans),
                      pal_rgb(12'(data) | color)};
        end
      end
    end
  endfunction

  // Layer pixel for screen coordinate: spec sec 3.1 address derivation.
  function automatic logic [24:0] layer_pix(input int layer,
                                            input int scr_x, input int scr_y);
    int sx, sy, wx, wy, tileshift, tilemask, w, h, winw, winh;
    int resx, resy, scrollx, scrolly, srcline, srccol, srctilerow, srctilecol;
    int tileoffs;
    logic big;
    logic [15:0] code;
    begin
      big = regs[R_SCRCTRL][5 + layer];
      sy = int'(regs[R_SCROLL + layer*2 + 0]);
      sx = int'(regs[R_SCROLL + layer*2 + 1]);
      wy = int'(regs[R_WIN + layer*2 + 0]);
      wx = int'(regs[R_WIN + layer*2 + 1]);
      tileshift = big ? 4 : 3;
      tilemask  = (1 << tileshift) - 1;
      w = 32'h100 << tileshift;
      h = 32'h100 << tileshift;
      winw = w >> 2;
      winh = h >> 3;

      resy = sy + scr_y - wy;
      scrolly = resy & (winh - 1);
      srcline = (wy + scrolly) & (h - 1);
      srctilerow = srcline >> tileshift;
      srcline = srcline & tilemask;

      resx = sx + scr_x - wx;
      scrollx = resx & (winw - 1);
      srccol = (wx + scrollx) & (w - 1);
      srctilecol = srccol >> tileshift;
      srccol = srccol & tilemask;

      tileoffs = srctilecol + srctilerow * 32'h100;
      code = vram_rd(layer, tileoffs);
      layer_pix = tile_pix(layer, code, srccol, srcline, big);
    end
  endfunction

  // ------------------------------------------------------------------
  // Sprite list (built once per frame, drawn per line)
  // ------------------------------------------------------------------
  int          spr_n;                 // list length
  int          spr_pri   [0:511];
  int          spr_x     [0:511];
  int          spr_y     [0:511];
  logic        spr_fx    [0:511];
  logic        spr_fy    [0:511];
  logic [3:0]  spr_color [0:511];
  int          spr_zoom  [0:511];     // 16.16 scale
  int          spr_w     [0:511];
  int          spr_h     [0:511];
  int          spr_gfx   [0:511];     // byte address
  int          draworder [0:511];     // stable sort by pri

  task automatic build_sprite_list();
    int sprites, j, k, idx, g;
    logic [15:0] w0, w1, attr, code;
    logic lp_dis;
    begin
      spr_n = 0;
      sprites = int'(regs[R_SPRCNT]) % 512;
      lp_dis = regs[R_SPRPRI][15];
      for (k = 0; k < sprites; k++) begin
        // list build order: backward unless layerpri_disable (spec 7.2)
        j = lp_dis ? k : (sprites - 1 - k);
        w0   = spriteram[j*4 + 0];
        w1   = spriteram[j*4 + 1];
        attr = spriteram[j*4 + 2];
        code = spriteram[j*4 + 3];
        if (w0[15:11] == 5'h1F) continue; // disabled
        spr_pri[spr_n]   = int'(w0[15:11]);
        spr_x[spr_n]     = int'(w0[10:0]);
        spr_y[spr_n]     = int'(w1[9:0]);
        spr_fx[spr_n]    = attr[15];
        spr_fy[spr_n]    = attr[14];
        spr_w[spr_n]     = (int'(attr[13:11]) + 1) * 8;
        spr_h[spr_n]     = (int'(attr[10:8])  + 1) * 8;
        spr_color[spr_n] = attr[7:4];
        spr_zoom[spr_n]  = int'(zoomtable[w1[15:10]]) << 8;
        spr_gfx[spr_n]   = 32 * ((int'(attr[3:0]) << 16) + int'(code));
        spr_n++;
      end
      // stable counting sort by priority group (draw order groups 0..31)
      idx = 0;
      for (g = 0; g < 32; g++)
        for (k = 0; k < spr_n; k++)
          if (spr_pri[k] == g) begin
            draworder[idx] = k;
            idx++;
          end
    end
  endtask

  // Per-line sprite buffer: first opaque sprite texel wins and blocks
  logic        lin_taken  [0:WIDTH-1];
  logic [23:0] lin_rgb    [0:WIDTH-1];
  int          lin_prival [0:WIDTH-1];

  task automatic sprite_line(input int line);
    int oi, s, pri, prival;
    int sprite_xoffs, sprite_yoffs;
    int lp_masknum, lp_pri, lp_masklayer;
    logic lp_dis;
    int sx0, sy0, out_w, out_h, dx, dy, x_index_base, y_index, x_index;
    int xa, xb, x, p, srow;
    logic [7:0] c, trans, rom_byte;
    logic [11:0] colbits, palbase;
    logic bpp8;
    begin
      for (x = 0; x < WIDTH; x++) lin_taken[x] = 1'b0;

      sprite_xoffs = int'(regs[R_SPRXOFF]) - (int'(regs[R_SCRXOFF]) + 1);
      sprite_yoffs = int'(regs[R_SPRYOFF]) - (int'(regs[R_SCRYOFF]) + 1);
      lp_dis       = regs[R_SPRPRI][15];
      lp_masknum   = int'(regs[R_SPRPRI][4:0]);
      lp_pri       = int'(regs[R_SPRPRI][9:8]);
      lp_masklayer = int'(regs[R_SPRPRI][11:10]);
      palbase      = 12'(regs[R_SPRCOL][3:0]) << 8;

      for (oi = 0; oi < spr_n; oi++) begin
        s = draworder[oi];
        pri = lp_pri;
        if (!lp_dis && spr_pri[s] > lp_masknum) pri = lp_masklayer;
        prival = 3 - pri;

        if (spr_zoom[s] == 0) continue;
        bpp8 = (spr_color[s] == 4'hF);
        if (bpp8) begin
          if (spr_gfx[s] + spr_w[s] * spr_h[s] - 1 >= gfx_size) continue;
          trans = 8'hFF;
          colbits = 12'd0;
        end else begin
          if (spr_gfx[s] + (spr_w[s] / 2) * spr_h[s] - 1 >= gfx_size) continue;
          trans = 8'h0F;
          colbits = 12'(spr_color[s]) << 4;
        end

        out_h = (spr_zoom[s] * spr_h[s] + 32'h8000) >>> 16;
        out_w = (spr_zoom[s] * spr_w[s] + 32'h8000) >>> 16;
        if (out_w == 0 || out_h == 0) continue;

        sx0 = spr_x[s] - sprite_xoffs;
        sy0 = spr_y[s] - sprite_yoffs;
        if (line < sy0 || line >= sy0 + out_h || line >= HEIGHT) continue;

        dx = (spr_w[s] << 16) / out_w;
        dy = (spr_h[s] << 16) / out_h;
        x_index_base = spr_fx[s] ? (out_w - 1) * dx : 0;
        y_index      = spr_fy[s] ? (out_h - 1) * dy : 0;
        if (spr_fx[s]) dx = -dx;
        if (spr_fy[s]) dy = -dy;

        y_index += (line - sy0) * dy;

        xa = (sx0 < 0) ? 0 : sx0;
        xb = (sx0 + out_w > WIDTH) ? WIDTH : sx0 + out_w;
        if (xb <= xa) continue;
        x_index = x_index_base + (xa - sx0) * dx;

        srow = (y_index >>> 16) * spr_w[s];
        for (x = xa; x < xb; x++) begin
          if (bpp8) begin
            p = spr_gfx[s] + srow + (x_index >>> 16);
            c = gfxrom[p];
          end else begin
            p = spr_gfx[s] * 2 + srow + (x_index >>> 16); // pixel index
            rom_byte = gfxrom[p >> 1];
            // sprite packing: LEFT pixel = LOW nibble
            c = ((p & 1) != 0) ? {4'd0, rom_byte[7:4]} : {4'd0, rom_byte[3:0]};
          end
          if (c != trans) begin
            if (!lin_taken[x]) begin
              lin_taken[x]  = 1'b1;
              lin_rgb[x]    = pal_rgb(palbase + colbits + 12'(c));
              lin_prival[x] = prival;
            end
          end
          x_index += dx;
        end
      end
    end
  endtask

  // ------------------------------------------------------------------
  // Frame render + PPM out
  // ------------------------------------------------------------------
  logic [23:0] fb [0:HEIGHT-1][0:WIDTH-1];

  initial begin : render
    string scene, outpath;
    int fh, x, y, layer, pri_l [0:2];
    logic [24:0] lp [0:2];
    int win_l, win_pri, laypri_code;
    logic [23:0] base_rgb, bg_rgb;
    logic blanked;

    if (!$value$plusargs("SCENE=%s", scene))  $fatal(1, "need +SCENE=<dir>");
    if (!$value$plusargs("OUT=%s", outpath))  $fatal(1, "need +OUT=<file>");
    if (!$value$plusargs("GFXSIZE=%d", gfx_size)) gfx_size = 32'h80000;

    $readmemh({scene, "/vram0.hex"},     vram0);
    $readmemh({scene, "/vram1.hex"},     vram1);
    $readmemh({scene, "/vram2.hex"},     vram2);
    $readmemh({scene, "/tiletable.hex"}, tiletable);
    $readmemh({scene, "/palette.hex"},   palette);
    $readmemh({scene, "/spriteram.hex"}, spriteram);
    $readmemh({scene, "/gfxrom.hex"},    gfxrom);
    $readmemh({scene, "/regs.hex"},      regs);

    if (regs[R_SCRCTRL][0]) $fatal(1, "flip screen out of scope for M1");

    pri_l[0] = int'(regs[R_LAYPRI][1:0]);
    pri_l[1] = int'(regs[R_LAYPRI][3:2]);
    pri_l[2] = int'(regs[R_LAYPRI][5:4]);
    bg_rgb   = pal_rgb(regs[R_BGCOL][11:0]);
    blanked  = regs[R_SCRCTRL][1];

    build_sprite_list();

    for (y = 0; y < HEIGHT; y++) begin
      if (!blanked) sprite_line(y);
      for (x = 0; x < WIDTH; x++) begin
        if (blanked) begin
          fb[y][x] = bg_rgb;
        end else begin
          for (layer = 0; layer < 3; layer++)
            lp[layer] = layer_pix(layer, x, y);
          // winner among opaque layers: min pri, tie -> lowest layer index
          win_l = -1; win_pri = 4;
          for (layer = 2; layer >= 0; layer--)
            if (lp[layer][24] && pri_l[layer] <= win_pri) begin
              win_l = layer; win_pri = pri_l[layer];
            end
          if (win_l >= 0) begin
            laypri_code = 3 - win_pri;
            base_rgb = lp[win_l][23:0];
          end else begin
            laypri_code = 0;
            base_rgb = bg_rgb;
          end
          if (lin_taken[x] && laypri_code <= lin_prival[x])
            fb[y][x] = lin_rgb[x];
          else
            fb[y][x] = base_rgb;
        end
      end
    end

    fh = $fopen(outpath, "w");
    if (fh == 0) $fatal(1, "cannot open %s", outpath);
    $fwrite(fh, "P3\n%0d %0d\n255\n", WIDTH, HEIGHT);
    for (y = 0; y < HEIGHT; y++) begin
      for (x = 0; x < WIDTH; x++)
        $fwrite(fh, "%0d %0d %0d ", fb[y][x][23:16], fb[y][x][15:8], fb[y][x][7:0]);
      $fwrite(fh, "\n");
    end
    $fclose(fh);
    $display("rtl-model: rendered %s -> %s", scene, outpath);
    $finish;
  end

endmodule
