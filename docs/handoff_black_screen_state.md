# Handoff: all-green black screen (2026-07-08 ~02:00)

## RESOLVED 2026-07-08 afternoon: sr3 arbiter starvation

The 510-frame sim reproduced the black screen exactly (palette/VRAM all
zero, sprite RAM initialised, VDP regs written - main CPU stalled
mid-boot). Root cause: the shared3 arbiter in hyprduel_sys.sv could
NEVER grant the SDRAM port to the sub CPU. Its "pick next" branch
required o_sr3_req == 0, but o_sr3_req = m_req || s_req, so the branch
was dead code and sr3_grant_s was permanently 0. The sub CPU hung
forever on its first sr3 access (0xFE5500, sound driver data) inside
the YM2151 IRQ handler; the IRQ line stayed asserted, the 0xFFF34C
handshake never completed, and the main CPU waited forever at ROM
0x86A8 without writing palette or tilemaps. Evidence: frame-10 frozen
bus dump "STUCK sub: asn=0 a=fe5500 sbst=SB_SR3 s_req=1 grant_s=0".

Fix: arbiter rewritten with explicit in-flight tracking (sr3_infly) and
a REGISTERED request line (sr3_req_r) so the addr/we mux is stable
before the controller latches. After the fix the 510-frame sim BOOTS:
memory check screen at frame 150 ("IC U24: GOOD"), attract-mode Earth
intro from frame 360. First boot ever. Hardware compile in flight at
handoff-update time; gate on STA as usual, then deploy.

Note for audio follow-up: this same starvation is almost certainly the
old "audio dead / YM IRQ storm" bug (docs/audio_bug_ym_irq_storm.md) -
recheck audio on hardware before chasing anything else. OKI still
silent in sim (oki writes=0 by frame 510) - may simply be that attract
mode hasn't triggered samples yet.

Everything below is the pre-fix state, kept for reference.

State written before a context compact. Everything below is verified fact
unless marked open. Prior arc: docs/plan_timing_closure_download.md and
commit 4123892 (all of tonight's RTL is committed; working tree since then
only adds the COVER split + this file).

## Where we are

The machine is ALIVE on hardware but the screen is black:

- All 8 flag bands GREEN, including band 8 = lb_nonzero (renderer writes
  non-black PENS into the line buffer). Bands L-R: mrom_rd, vdp_cs,
  vdp_write, past_vectors, line_start, rnd_done, sr3_ack, lb_nonzero.
- All memory probes correct on the CRT (latest deployed build):
  TEST=00FF (early main-ROM w0), PDLD/GFXP=3422 (GFX region word
  GFX_WBASE+4, matches sim gfxrom.bin -> MRA interleave CORRECT),
  ROM0=00FF, ROM1=FD00, DLBT=0000 (first ioctl addr), DLCT=4C00,
  DLWR=4C00, RSDP=0100, REFC live (refresh alive).
- Since pens are palette INDICES, black + lb_nonzero green points at the
  palette BRAM containing zeros: the game likely never wrote its colours,
  i.e. it is stuck mid-boot (prime suspect: sub-CPU sound handshake in
  shared3 = SDRAM sr3, which tonight moved to read-modify-write).

## PENDING: the deciding sim (was running at compact time)

`make boot SDRAM=1 FRAMES=510` in sim/ (background task btlbqoj0x).
PPMs land in sim/build/boot_sdram/ every 30 frames. The game first draws
at ~frame 300 (memory check), title ~500.

- If frames 300-510 show pictures: tonight's RTL boots fine; the black
  screen is a HARDWARE-side difference. Next probe build shows
  dbg_subctl (sys already exports it), a palette-write counter
  (pal_we && wdata != 0), and consider P_PIXDIV: hardware runs 12, sim
  runs 16; renderer real-time at 12 was closed pre-tonight (worst 4783
  vs 5088) but tonight added +1 cycle each to tile fetch (VR0, VR3,
  TT3B) and sprite setup (PRIM2, COVER2) - re-check worst_line at
  PIXDIV=12 in sim (tb_system parameter) and the rnd_overrun flag
  (exists in vdp, NOT yet displayed).
- If sim is black too: tonight's RTL broke late boot. Prime suspect
  sr3 RMW (handshake word 0xFFF34C lives in shared3). Debug offline in
  sim with tb_system state dumps; no compiles needed.

## Tonight's fixes (all sim-verified, all deployed except COVER split)

1. Timing closure on BALANCED (15-min compiles): overlay 3-stage
   pipeline + vsync snapshot + modulo-free row decode; rnd_vram_addr_r
   pipeline reg (+ST_L_VR0); registered CPU->VDP inputs; ST_L_VR2/VR3
   split; ST_L_TT3/TT3B split; sprite emit multiply -> exact +-dx
   accumulator (PRIME/PRIM2); ST_S_COVER/COVER2 split (in working tree,
   deployed in the latest RBF, slack +1.089).
2. THE BIG ONE: MiSTer SDRAM board ties DQML/DQMH LOW - byte-masked
   writes clobber the whole word ({odd,odd} signature). Download now
   pairs bytes into full-word writes; sr3 partial writes are RMW
   (ret tag 5, sr3_busy guards duplicate acks); sdram_model DQM tied
   low in BOTH testbenches so sim now matches the board.
3. Probes (current CRT row map): TEST=early main w0, PDLD=GFX probe
   (tag 6, expect 3422), ROM0/1=CPU-side first fetches, DLBT=first
   ioctl addr, DLCT/DLWR=bytes received/written [23:8], RSDP=resets+
   drops, FSMQ=live refresh counter. Font: 16px cells, 3px dots.

## Runbook

- Compile: scp files to leefoot@192.168.1.207 C:/hyprduel/{rtl,mister}/,
  then `schtasks /run /tn hyprcompile`, ~15 min (QSF: BALANCED, TDS OFF,
  SEED 2). GATE: Setup Summary in output_files/Hyprduel.sta.rpt must be
  >= 0 on every clock. NEVER deploy a failing build.
- Deploy: scp RBF from PC output_files/ -> scratchpad -> sshpass -p "1"
  scp to root@192.168.1.208:/media/fat/_Arcade/cores/Hyprduel.rbf, then
  echo 'load_core /media/fat/_Arcade/Hyper Duel.mra' > /dev/MiSTer_cmd.
- CRT burn protection between tests: Sonic runs via
  echo "load_core /tmp/sonic.mgl" > /dev/MiSTer_cmd (mgl already on the
  MiSTer at /tmp/sonic.mgl; recreate after MiSTer reboot).
- Sim: cd sim; make download (T1-T6+probes), make render-verify /
  mame-verify / vdp-verify (frame 500 must PASS; 900/1500 fail =
  pre-existing raster issue), make boot SDRAM=1 FRAMES=N.
- Every renderer edit: full parity suite before compiling. Every
  hyprduel_sdram edit: make download + boot.

## Open items

- The 510-frame sim verdict (above) drives everything.
- Uncommitted: COVER2 split (i4220_render.sv), this file.
- dbg_subctl / palette-write-counter / rnd_overrun probe build: designed
  but not written; only build it after the sim verdict.
- Session log to Obsidian note (Projects/Personal Projects/MiSTer FPGA/
  Hyper Duel Core.md) pending at session end; memory topic file
  hyperduel_mister_core.md updated through the DQM discovery but not
  the GFXP=3422 / all-green result.
