// I4220 scanline renderer (M3).
//
// Renders one line at a time into an external line buffer, from BRAM-style
// memory ports (registered 1-cycle reads) and a streaming GFX ROM port.
// Semantics as verified against the M1 oracle and real MAME frame dumps.
//
// Per line: three sequential tilemap passes (layer 2 -> 1 -> 0, keep the
// lowest priority value, later pass wins ties => lowest layer wins), then
// one sprite pass in list order keeping the smallest priority group per
// pixel (first writer wins within a group) - this single pass reproduces
// MAME's group-by-group draw order exactly. A final resolve pass applies
// the sprite-vs-layer mask rule and writes pens to the line buffer.
//
// GFX ROM stream port protocol: o_rom_req is a 1-cycle pulse; o_rom_addr /
// o_rom_len stay stable until all o_rom_len bytes have arrived as
// i_rom_valid pulses (not necessarily consecutive). No new request before
// the previous stream completes.
//
// Line accumulators are packed into two SDP BRAMs (lay_mem 15-bit,
// spr_mem 20-bit) with one-ahead prefetch addressing.

module i4220_render #(
    parameter int GFX_AW = 22
) (
    input  logic clk,
    input  logic rst_n,

    // line control
    input  logic        i_start,      // pulse: render line i_line
    input  logic [7:0]  i_line,       // 0..223
    output logic        o_busy,
    output logic        o_done,       // pulse with last line-buffer write

    // register state (live values; raster effects come from mid-frame updates)
    input  logic [5:0]  i_layer_pri,       // [1:0] L0, [3:2] L1, [5:4] L2
    input  logic [11:0] i_bg_color,
    input  logic [15:0] i_screen_ctrl,
    input  logic [15:0] i_scroll_x [3],
    input  logic [15:0] i_scroll_y [3],
    input  logic [15:0] i_window_x [3],
    input  logic [15:0] i_window_y [3],
    input  logic [15:0] i_spr_count,
    input  logic [15:0] i_spr_pri,
    input  logic [15:0] i_spr_xoff,
    input  logic [15:0] i_spr_yoff,
    input  logic [15:0] i_spr_color,
    input  logic [15:0] i_screen_xoff,
    input  logic [15:0] i_screen_yoff,
    input  logic [23:0] i_gfx_size,        // ROM bytes (bounds checks)

    // VRAM read ports (one per layer, shared address, registered 1-cycle)
    output logic [15:0] o_vram_addr,
    input  logic [15:0] i_vram_data [3],

    // tile table read port
    output logic [9:0]  o_tt_addr,
    input  logic [15:0] i_tt_data,

    // sprite RAM read port (buffered copy)
    output logic [10:0] o_spr_addr,
    input  logic [15:0] i_spr_data,

    // GFX ROM stream port
    output logic              o_rom_req,
    output logic [GFX_AW-1:0] o_rom_addr,
    output logic [6:0]        o_rom_len,   // 1..64 bytes
    input  logic [7:0]        i_rom_data,
    input  logic              i_rom_valid,

    // line buffer write (final pen per pixel)
    output logic        o_lb_we,
    output logic [8:0]  o_lb_x,
    output logic [11:0] o_lb_pen
);

  localparam int WIDTH = 320;

  // sprite zoom table (spec sec 7.1)
  logic [11:0] ztab [0:63];
  initial begin
    ztab[ 0]=12'hAAC; ztab[ 1]=12'h800; ztab[ 2]=12'h668; ztab[ 3]=12'h554;
    ztab[ 4]=12'h494; ztab[ 5]=12'h400; ztab[ 6]=12'h390; ztab[ 7]=12'h334;
    ztab[ 8]=12'h2E8; ztab[ 9]=12'h2AC; ztab[10]=12'h278; ztab[11]=12'h248;
    ztab[12]=12'h224; ztab[13]=12'h200; ztab[14]=12'h1E0; ztab[15]=12'h1C8;
    ztab[16]=12'h1B0; ztab[17]=12'h198; ztab[18]=12'h188; ztab[19]=12'h174;
    ztab[20]=12'h164; ztab[21]=12'h154; ztab[22]=12'h148; ztab[23]=12'h13C;
    ztab[24]=12'h130; ztab[25]=12'h124; ztab[26]=12'h11C; ztab[27]=12'h110;
    ztab[28]=12'h108; ztab[29]=12'h100; ztab[30]=12'h0F8; ztab[31]=12'h0F0;
    ztab[32]=12'h0EC; ztab[33]=12'h0E4; ztab[34]=12'h0DC; ztab[35]=12'h0D8;
    ztab[36]=12'h0D4; ztab[37]=12'h0CC; ztab[38]=12'h0C8; ztab[39]=12'h0C4;
    ztab[40]=12'h0C0; ztab[41]=12'h0BC; ztab[42]=12'h0B8; ztab[43]=12'h0B4;
    ztab[44]=12'h0B0; ztab[45]=12'h0AC; ztab[46]=12'h0A8; ztab[47]=12'h0A4;
    ztab[48]=12'h0A0; ztab[49]=12'h09C; ztab[50]=12'h098; ztab[51]=12'h094;
    ztab[52]=12'h090; ztab[53]=12'h08C; ztab[54]=12'h088; ztab[55]=12'h080;
    ztab[56]=12'h078; ztab[57]=12'h070; ztab[58]=12'h068; ztab[59]=12'h060;
    ztab[60]=12'h058; ztab[61]=12'h050; ztab[62]=12'h048; ztab[63]=12'h040;
  end

  // line accumulators: packed into two SDP BRAMs
  // lay_mem: {valid, pri[1:0], pen[11:0]}
  logic [14:0] lay_mem [0:511];
  // spr_mem: {taken, group[4:0], prival[1:0], pen[11:0]}
  logic [19:0] spr_mem [0:511];

  logic [14:0] lay_q;      logic [19:0] spr_q;
  logic        lay_we;     logic        spr_we;
  logic [8:0]  lay_waddr;  logic [8:0]  spr_waddr;
  logic [14:0] lay_wdata;  logic [19:0] spr_wdata;
  logic [8:0]  lay_raddr;  logic [8:0]  spr_raddr;

  always_ff @(posedge clk) begin
    lay_q <= lay_mem[lay_raddr];
    spr_q <= spr_mem[spr_raddr];
  end

  always_ff @(posedge clk) begin
    if (lay_we) lay_mem[lay_waddr] <= lay_wdata;
    if (spr_we) spr_mem[spr_waddr] <= spr_wdata;
  end

  typedef enum logic [4:0] {
    ST_IDLE,
    ST_CLR,
    ST_L_PIX, ST_L_VR0, ST_L_VR1, ST_L_VR2, ST_L_VR3,
    ST_L_TT1, ST_L_TT2, ST_L_TT3,
    ST_L_GRCV,
    ST_S_RD0, ST_S_RD1, ST_S_RD2, ST_S_RD3, ST_S_RD4,
    ST_S_ZOOM, ST_S_COVER, ST_S_DIV, ST_S_GREQ, ST_S_GMUL, ST_S_GISS, ST_S_GRCV,
    ST_S_PRIME, ST_S_PRIM2, ST_S_EMIT,
    ST_L_TT3B,
    ST_RESOLVE
  } st_e;

  st_e st;

  logic        did_init;
  logic [7:0]  line_r;
  logic [8:0]  xcur;
  logic [1:0]  layer;

  // tile fetch context
  logic [15:0] vdata_r;            // registered layer-muxed VRAM word
  logic [15:0] code_r;
  logic [15:0] cache_code;
  logic        cache_valid;
  logic        cache_solid;
  logic        cache_opaque_solid;
  logic [11:0] cache_solid_pen;
  logic        cache_oor;
  logic        cache_bpp8;
  logic [11:0] cache_color;
  logic [7:0]  rowcache [0:15];
  logic [4:0]  rx;
  logic [15:0] tt0_r;
  logic [16:0] prev_tileoffs;    // [16] = invalid marker
  logic [22:0] tt_tile2_q;       // TT3 -> TT3B pipeline
  logic [4:0]  tt_rowbytes_q;
  logic [4:0]  tt_rowsel_q;

  // sprite pass context
  logic [9:0]  scount;
  logic [9:0]  scur;
  logic [15:0] sw0, sw1, sattr;
  logic [25:0] sgfx;             // byte address (26b: attr nibble << 21)
  logic [19:0] szoom;            // 16.16 scale
  logic [6:0]  sw_pix, sh_pix;   // 8..64
  logic [11:0] out_w, out_h;
  int          sx0, sy0;         // signed screen start
  int          xo, xo_end;       // output-offset walk bounds
  logic [23:0] dx_q, dy_q;
  logic [11:0] rowsel_q;           // pipelined row selection for ROM addr
  logic [35:0] yidx_q;             // pipelined zoom-scaled row index
  logic [11:0] s_xs;               // pixel-index multiplier input (v or W-1-v)
  logic [35:0] s_xi;               // running product xs*dx; steps by +-dx per pixel
  wire  [11:0] s_pixidx = s_xi[27:16];   // current sprite pixel index
  logic        s_bpp8;
  logic [1:0]  s_prival;
  logic [4:0]  s_group;
  logic [7:0]  srowcache [0:63];
  logic [5:0]  rx2;

  // serial divider (shared, phase 0 = dy, 1 = dx)
  logic        div_phase;
  logic [23:0] div_num, div_rem, div_quot;
  logic [11:0] div_den;
  logic [4:0]  div_cnt;

  // register decodes
  wire        blank      = i_screen_ctrl[1];
  wire        lp_dis     = i_spr_pri[15];
  wire [4:0]  lp_masknum = i_spr_pri[4:0];
  wire [1:0]  lp_gpri    = i_spr_pri[9:8];
  wire [1:0]  lp_mask    = i_spr_pri[11:10];
  wire [11:0] spr_palbase = {i_spr_color[3:0], 8'h00};

  function automatic logic [1:0] layer_pri_of(input logic [1:0] l);
    unique case (l)
      2'd0: layer_pri_of = i_layer_pri[1:0];
      2'd1: layer_pri_of = i_layer_pri[3:2];
      default: layer_pri_of = i_layer_pri[5:4];
    endcase
  endfunction

  // ------------------------------------------------------------------
  // tilemap address derivation (combinational, spec sec 3.1)
  // ------------------------------------------------------------------
  logic        big;
  logic [4:0]  tsz;
  logic [15:0] tileoffs;
  logic [4:0]  pix_x, pix_y;

  always_comb begin
    logic [31:0] winw_m, winh_m, big_m;
    logic [31:0] resx, resy, scx, scy, srcc, srcl;
    int ts;
    big  = i_screen_ctrl[5 + 32'(layer)];
    ts   = big ? 4 : 3;
    tsz  = big ? 5'd16 : 5'd8;
    winw_m = big ? 32'h3FF : 32'h1FF;
    winh_m = big ? 32'h1FF : 32'hFF;
    big_m  = big ? 32'hFFF : 32'h7FF;

    resy = 32'(i_scroll_y[layer]) + 32'(line_r) - 32'(i_window_y[layer]);
    scy  = resy & winh_m;
    srcl = (32'(i_window_y[layer]) + scy) & big_m;

    resx = 32'(i_scroll_x[layer]) + 32'(xcur) - 32'(i_window_x[layer]);
    scx  = resx & winw_m;
    srcc = (32'(i_window_x[layer]) + scx) & big_m;

    tileoffs = 16'(((srcl >> ts) << 8) | (srcc >> ts));
    pix_x    = 5'(srcc) & (tsz - 5'd1);
    pix_y    = 5'(srcl) & (tsz - 5'd1);
  end

  // tile pixel from row cache (combinational)
  logic [7:0]  tile_texel;
  logic        tile_opaque;
  logic [11:0] tile_pen;
  always_comb begin
    logic [4:0] xe;
    xe = code_r[14] ? ((tsz - 5'd1) - pix_x) : pix_x;   // flip X
    if (cache_bpp8) begin
      tile_texel = rowcache[xe[3:0]];
      tile_opaque = (tile_texel != 8'hFF);
    end else begin
      // 4bpp: LEFT pixel = LOW nibble
      tile_texel = xe[0] ? {4'd0, rowcache[xe[4:1]][7:4]}
                         : {4'd0, rowcache[xe[4:1]][3:0]};
      tile_opaque = (tile_texel[3:0] != 4'hF);
    end
    tile_pen = 12'(tile_texel) | cache_color;
  end

  // Sprite pixel index: pixidx(v) = ((flipX ? out_w-1-v : v) * dx) >> 16.
  // Computed once per sprite with a registered-input multiply (PRIME/PRIM2),
  // then advanced by +-dx per emitted pixel (exact by linearity of the
  // product in v) so the emit loop carries only a 36-bit add.

  // divider next-step values (combinational)
  wire [23:0] div_rem_sh = {div_rem[22:0], div_num[23]};
  wire        div_ge     = (div_rem_sh >= 24'(div_den));
  wire [23:0] div_q_next = {div_quot[22:0], div_ge};

  // ------------------------------------------------------------------
  // prefetch addresses for BRAM accumulators
  // ------------------------------------------------------------------
  wire       xadv   = ((st == ST_L_PIX) && (prev_tileoffs == {1'b0, tileoffs}))
                   || (st == ST_CLR) || (st == ST_RESOLVE);
  wire [8:0] xnext  = (xcur == 9'(WIDTH-1)) ? 9'd0 : (xcur + 9'd1);
  wire [8:0] xtrack = xadv ? xnext : xcur;

  always_comb begin
    lay_raddr = xtrack;
    spr_raddr = (st == ST_S_EMIT) ? 9'(sx0 + xo + 1)
              : (st == ST_S_PRIME || st == ST_S_PRIM2) ? 9'(sx0 + xo)
              : (st == ST_S_RD1 || st == ST_S_RD2 || st == ST_S_RD3 ||
                 st == ST_S_RD4 || st == ST_S_ZOOM || st == ST_S_COVER ||
                 st == ST_S_DIV || st == ST_S_GREQ || st == ST_S_GRCV)
                ? ((sx0 < 0) ? 9'd0 : 9'(sx0))
              : xtrack;
  end

  // ------------------------------------------------------------------
  // main FSM
  // ------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st <= ST_IDLE;
      o_busy <= 1'b0;
      o_done <= 1'b0;
      o_lb_we <= 1'b0;
      o_rom_req <= 1'b0;
      did_init <= 1'b0;
    end else begin
      o_done <= 1'b0;
      o_lb_we <= 1'b0;
      o_rom_req <= 1'b0;
      lay_we <= 1'b0;
      spr_we <= 1'b0;

      unique case (st)
        ST_IDLE: begin
          if (i_start) begin
            line_r <= i_line;
            o_busy <= 1'b1;
            xcur   <= 9'd0;
            layer  <= 2'd2;
            prev_tileoffs <= 17'h10000;
            cache_valid <= 1'b0;
            // accumulators are pre-cleared by the previous line's resolve
            // pass; a full clear runs only once after reset
            st <= !did_init ? ST_CLR : (blank ? ST_RESOLVE : ST_L_PIX);
          end
        end

        ST_CLR: begin
          lay_we <= 1'b1;  lay_waddr <= xcur;  lay_wdata <= '0;
          spr_we <= 1'b1;  spr_waddr <= xcur;  spr_wdata <= '0;
          if (xcur == 9'(WIDTH - 1)) begin
            xcur  <= 9'd0;
            did_init <= 1'b1;
            st <= blank ? ST_RESOLVE : ST_L_PIX;
          end else
            xcur <= xcur + 9'd1;
        end

        // ---------------- tilemap passes ----------------
        ST_L_PIX: begin
          if (prev_tileoffs != {1'b0, tileoffs}) begin
            o_vram_addr   <= tileoffs;
            prev_tileoffs <= {1'b0, tileoffs};
            st <= ST_L_VR0;
          end else begin
            logic do_write;
            logic [11:0] wpen;
            do_write = 1'b0;
            wpen = 12'd0;
            if (!cache_oor) begin
              if (cache_solid) begin
                do_write = cache_opaque_solid;
                wpen = cache_solid_pen;
              end else begin
                do_write = tile_opaque;
                wpen = tile_pen;
              end
            end
            if (do_write &&
                (!lay_q[14] ||
                 layer_pri_of(layer) <= lay_q[13:12])) begin
              lay_we    <= 1'b1;
              lay_waddr <= xcur;
              lay_wdata <= {1'b1, layer_pri_of(layer), wpen};
            end
            if (xcur == 9'(WIDTH - 1)) begin
              xcur <= 9'd0;
              prev_tileoffs <= 17'h10000;
              cache_valid <= 1'b0;
              if (layer == 2'd0) begin
                scur   <= 10'd0;
                scount <= {1'b0, i_spr_count[8:0]};   // count % 512
                st <= (i_spr_count[8:0] == 9'd0) ? ST_RESOLVE : ST_S_RD0;
              end else
                layer <= layer - 2'd1;
            end else
              xcur <= xcur + 9'd1;
          end
        end

        ST_L_VR0: st <= ST_L_VR1;   // absorb VDP-side addr pipeline register
        ST_L_VR1: st <= ST_L_VR2;

        ST_L_VR2: begin
          // register the layer-muxed VRAM word; the compare/branch runs on
          // the registered copy next cycle (breaks the layer -> mux ->
          // compare -> decode timing path)
          vdata_r <= i_vram_data[layer];
          st <= ST_L_VR3;
        end

        ST_L_VR3: begin
          code_r <= vdata_r;
          if (cache_valid && vdata_r == cache_code) begin
            st <= ST_L_PIX;                            // same code: cache hit
          end else begin
            cache_code  <= vdata_r;
            cache_valid <= 1'b1;
            if (vdata_r[15]) begin                     // solid color tile
              cache_solid <= 1'b1;
              cache_oor   <= 1'b0;
              cache_opaque_solid <= (vdata_r[3:0] != 4'hF);
              cache_solid_pen    <= vdata_r[11:0];
              st <= ST_L_PIX;
            end else begin
              cache_solid <= 1'b0;
              o_tt_addr <= {vdata_r[12:4], 1'b0};
              st <= ST_L_TT1;
            end
          end
        end

        ST_L_TT1: begin
          o_tt_addr <= {code_r[12:4], 1'b1};
          st <= ST_L_TT2;
        end

        ST_L_TT2: begin
          tt0_r <= i_tt_data;
          st <= ST_L_TT3;
        end

        ST_L_TT3: begin
          // stage 1: decode tile word, register the row-address operands;
          // the multiply-add and ROM issue run on registered values in TT3B
          logic [31:0] tile;
          logic [7:0]  colorbyte;
          logic        bpp8;
          logic [22:0] tile2;
          logic [1:0]  tshift;
          tile = {tt0_r, i_tt_data};
          colorbyte = tile[27:20];
          bpp8 = (colorbyte[3:0] == 4'hF);
          tshift = big ? (bpp8 ? 2'd3 : 2'd2) : (bpp8 ? 2'd1 : 2'd0);
          tile2 = 23'((tile & 32'h000F_FFFF) + (32'(code_r[3:0]) << tshift));
          cache_bpp8 <= bpp8;
          cache_color <= bpp8 ? {colorbyte[7:4], 8'h00} : {colorbyte, 4'h0};
          tt_tile2_q   <= tile2;
          tt_rowbytes_q <= big ? (bpp8 ? 5'd16 : 5'd8) : (bpp8 ? 5'd8 : 5'd4);
          tt_rowsel_q  <= code_r[13] ? ((tsz - 5'd1) - pix_y) : pix_y; // flip Y
          st <= ST_L_TT3B;
        end

        ST_L_TT3B: begin
          logic [27:0] rowbase;
          if (32'(tt_tile2_q) >= (32'(i_gfx_size) >> 5)) begin
            cache_oor <= 1'b1;
            st <= ST_L_PIX;
          end else begin
            cache_oor <= 1'b0;
            rowbase = {tt_tile2_q, 5'd0} + 28'(tt_rowsel_q) * 28'(tt_rowbytes_q);
            o_rom_addr <= rowbase[GFX_AW-1:0];
            o_rom_len  <= {2'd0, tt_rowbytes_q};
            o_rom_req  <= 1'b1;
            rx <= 5'd0;
            st <= ST_L_GRCV;
          end
        end

        ST_L_GRCV: begin
          if (i_rom_valid) begin
            rowcache[rx[3:0]] <= i_rom_data;
            if ({2'd0, rx} == o_rom_len - 7'd1) st <= ST_L_PIX;
            else rx <= rx + 5'd1;
          end
        end

        // ---------------- sprite pass ----------------
        ST_S_RD0: begin
          if (scur == scount) st <= ST_RESOLVE;
          else begin
            o_spr_addr <= {(lp_dis ? scur[8:0]
                                   : (scount[8:0] - 9'd1 - scur[8:0])), 2'd0};
            st <= ST_S_RD1;
          end
        end

        ST_S_RD1: begin
          o_spr_addr <= {o_spr_addr[10:2], 2'd1};
          st <= ST_S_RD2;
        end

        ST_S_RD2: begin
          sw0 <= i_spr_data;
          o_spr_addr <= {o_spr_addr[10:2], 2'd2};
          if (i_spr_data[15:11] == 5'h1F) begin        // disabled: skip
            scur <= scur + 10'd1;
            st <= ST_S_RD0;
          end else
            st <= ST_S_RD3;
        end

        ST_S_RD3: begin
          sw1 <= i_spr_data;
          o_spr_addr <= {o_spr_addr[10:2], 2'd3};
          st <= ST_S_RD4;
        end

        ST_S_RD4: begin
          sattr <= i_spr_data;
          st <= ST_S_ZOOM;
        end

        ST_S_ZOOM: begin
          // i_spr_data delivers the code low word this cycle
          sgfx <= (26'(sattr[3:0]) << 21) | (26'(i_spr_data) << 5);
          szoom <= {ztab[sw1[15:10]], 8'd0};
          sw_pix <= (7'(sattr[13:11]) + 7'd1) << 3;
          sh_pix <= (7'(sattr[10:8])  + 7'd1) << 3;
          s_bpp8 <= (sattr[7:4] == 4'hF);
          s_group <= sw0[15:11];
          s_prival <= 2'd3 - ((!lp_dis && {27'd0, sw0[15:11]} > 32'(lp_masknum))
                              ? lp_mask : lp_gpri);
          st <= ST_S_COVER;
        end

        ST_S_COVER: begin
          logic [30:0] oh_full, ow_full;
          logic [11:0] ohv, owv;
          logic [25:0] extent;
          int sxv, syv;
          oh_full = 31'(szoom) * 31'(sh_pix) + 31'h8000;
          ow_full = 31'(szoom) * 31'(sw_pix) + 31'h8000;
          ohv = oh_full[27:16];
          owv = ow_full[27:16];
          out_h <= ohv;
          out_w <= owv;
          sxv = int'({21'd0, sw0[10:0]})
              - (int'({16'd0, i_spr_xoff}) - (int'({16'd0, i_screen_xoff}) + 1));
          syv = int'({22'd0, sw1[9:0]})
              - (int'({16'd0, i_spr_yoff}) - (int'({16'd0, i_screen_yoff}) + 1));
          sx0 <= sxv;
          sy0 <= syv;
          extent = s_bpp8 ? 26'(sw_pix) * 26'(sh_pix)
                          : 26'(sw_pix >> 1) * 26'(sh_pix);
          // coverage/bounds tests BEFORE the serial divider: sprites that
          // do not touch this line must cost only a few cycles each
          if (ohv == 0 || owv == 0 ||
              (32'(sgfx) + 32'(extent) - 1 >= 32'(i_gfx_size)) ||
              int'(line_r) < syv || int'(line_r) >= syv + int'(ohv) ||
              sxv >= WIDTH || sxv + int'(owv) <= 0) begin
            scur <= scur + 10'd1;
            st <= ST_S_RD0;
          end else if (szoom == 20'h10000) begin
            // 1:1 zoom (the common case): out = dim, step = 1.0 exactly;
            // skip the ~50-cycle serial divider entirely
            dy_q <= 24'h010000;
            dx_q <= 24'h010000;
            st <= ST_S_GREQ;
          end else begin
            div_num  <= {1'd0, sh_pix, 16'd0};
            div_den  <= ohv;
            div_quot <= 24'd0;
            div_rem  <= 24'd0;
            div_cnt  <= 5'd23;
            div_phase <= 1'b0;
            st <= ST_S_DIV;
          end
        end

        ST_S_DIV: begin
          div_num  <= {div_num[22:0], 1'b0};
          div_rem  <= div_ge ? (div_rem_sh - 24'(div_den)) : div_rem_sh;
          div_quot <= div_q_next;
          if (div_cnt == 0) begin
            if (!div_phase) begin
              dy_q <= div_q_next;
              div_num  <= {1'd0, sw_pix, 16'd0};
              div_den  <= out_w;
              div_quot <= 24'd0;
              div_rem  <= 24'd0;
              div_cnt  <= 5'd23;
              div_phase <= 1'b1;
            end else begin
              dx_q <= div_q_next;
              st <= ST_S_GREQ;
            end
          end else
            div_cnt <= div_cnt - 5'd1;
        end

        ST_S_GREQ: begin
          logic [11:0] rowoff;
          if (int'(line_r) < sy0 || int'(line_r) >= sy0 + int'(out_h) ||
              sx0 >= WIDTH || sx0 + int'(out_w) <= 0) begin
            scur <= scur + 10'd1;
            st <= ST_S_RD0;
          end else begin
            rowoff = 12'(int'(line_r) - sy0);
            rowsel_q <= sattr[14] ? (out_h - 12'd1 - rowoff) : rowoff;
            st <= ST_S_GMUL;
          end
        end

        ST_S_GMUL: begin
          yidx_q <= 36'(rowsel_q) * 36'(dy_q);
          st <= ST_S_GISS;
        end

        ST_S_GISS: begin
          logic [25:0] rowb;
          rowb = sgfx + (s_bpp8
                 ? 26'(yidx_q[27:16]) * 26'(sw_pix)
                 : 26'(yidx_q[27:16]) * 26'(sw_pix >> 1));
          o_rom_addr <= rowb[GFX_AW-1:0];
          o_rom_len  <= s_bpp8 ? sw_pix : (sw_pix >> 1);
          o_rom_req  <= 1'b1;
          rx2 <= 6'd0;
          st <= ST_S_GRCV;
        end

        ST_S_GRCV: begin
          if (i_rom_valid) begin
            srowcache[rx2] <= i_rom_data;
            if ({1'd0, rx2} == o_rom_len - 7'd1) begin
              xo     <= (sx0 < 0) ? -sx0 : 0;
              xo_end <= (sx0 + int'(out_w) > WIDTH) ? (WIDTH - sx0)
                                                    : int'(out_w);
              st <= ST_S_PRIME;
            end else
              rx2 <= rx2 + 6'd1;
          end
        end

        ST_S_PRIME: begin
          // stage 1: resolve the flip-adjusted start index (subtract only)
          s_xs <= 12'(sattr[15] ? (int'(out_w) - 1 - xo) : xo);
          st <= ST_S_PRIM2;
        end

        ST_S_PRIM2: begin
          // stage 2: one registered-input multiply seeds the accumulator
          s_xi <= 36'(s_xs) * 36'(dx_q);
          st <= ST_S_EMIT;
        end

        ST_S_EMIT: begin
          if (xo >= xo_end) begin
            scur <= scur + 10'd1;
            st <= ST_S_RD0;
          end else begin
            logic [7:0] texel;
            logic [8:0] xscr;
            if (s_bpp8) texel = srowcache[s_pixidx[5:0]];
            else texel = s_pixidx[0] ? {4'd0, srowcache[s_pixidx[6:1]][7:4]}
                                     : {4'd0, srowcache[s_pixidx[6:1]][3:0]};
            xscr = 9'(sx0 + xo);
            if ((s_bpp8 && texel != 8'hFF) ||
                (!s_bpp8 && texel[3:0] != 4'hF)) begin
              if (!spr_q[19] || s_group < spr_q[18:14]) begin
                spr_we    <= 1'b1;
                spr_waddr <= xscr;
                spr_wdata <= {1'b1, s_group, s_prival,
                              spr_palbase
                    | (s_bpp8 ? 12'(texel)
                              : ({4'd0, sattr[7:4], 4'd0} | 12'(texel)))};
              end
            end
            s_xi <= sattr[15] ? (s_xi - 36'(dx_q)) : (s_xi + 36'(dx_q));
            xo <= xo + 1;
          end
        end

        // ---------------- resolve ----------------
        ST_RESOLVE: begin
          logic [1:0] laycode;
          logic [11:0] pen;
          if (blank) pen = i_bg_color;
          else begin
            laycode = lay_q[14] ? (2'd3 - lay_q[13:12]) : 2'd0;
            if (spr_q[19] && laycode <= spr_q[13:12])
              pen = spr_q[11:0];
            else if (lay_q[14])
              pen = lay_q[11:0];
            else
              pen = i_bg_color;
          end
          o_lb_we  <= 1'b1;
          o_lb_x   <= xcur;
          o_lb_pen <= pen;
          lay_we <= 1'b1;  lay_waddr <= xcur;  lay_wdata <= '0;
          spr_we <= 1'b1;  spr_waddr <= xcur;  spr_wdata <= '0;
          if (xcur == 9'(WIDTH - 1)) begin
            o_done <= 1'b1;
            o_busy <= 1'b0;
            st <= ST_IDLE;
          end else
            xcur <= xcur + 9'd1;
        end

        default: st <= ST_IDLE;
      endcase
    end
  end

endmodule
