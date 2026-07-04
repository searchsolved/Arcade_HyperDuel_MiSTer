# Hyper Duel (Technosoft 1993, TEC442-A) - System-Level Specification

Source: MAME `src/mame/metro/hyprduel.cpp` (BSD-3-Clause, Luca Elia / Hau),
vendored in `reference/mame/`. Board reference from the driver header.

## 1. Board summary

| Component | Part | Clock |
|-----------|------|-------|
| Main CPU | TMP68000N-10 | 10 MHz (20 MHz OSC / 2) |
| Sub CPU | TMP68000N-10 | 10 MHz |
| VDP | Imagetek I4220 071 | 26.666 MHz OSC |
| FM | YM2151 + YM3012 DAC | 4 MHz |
| ADPCM | OKI M6295 | see 5 (MAME: unverified) |

Mono audio output. 320x224 @ ~60 Hz, 262 lines.

## 2. Main CPU memory map (hyprduel.cpp:236-249)

| Range | Contents |
|-------|----------|
| 0x000000-0x07FFFF | Program ROM (512 KB, 2 x 256 KB byte-interleaved) |
| 0x400000-0x47FFFF | I4220 (v2_map, see i4220_spec.md) |
| 0x4788A5 | VDP IRQ enable (driver wraps it with `data OR 0xFD`, see spec sec 10) |
| 0x800000-0x800001 | Sub CPU control latch (write, see 4.1) |
| 0xC00000-0xC07FFF | Shared RAM 1 (32 KB) |
| 0xE00000-0xE00001 | SERVICE input (r) |
| 0xE00002-0xE00003 | DSW (r) |
| 0xE00004-0xE00005 | P1/P2 inputs (r) |
| 0xE00006-0xE00007 | SYSTEM (coins/start) (r) |
| 0xFE0000-0xFE3FFF | Shared RAM 2 (16 KB) |
| 0xFE4000-0xFFFFFF | Shared RAM 3 (112 KB) |

Total shared/work RAM: 160 KB, ALL of it dual-ported between the CPUs.

## 3. Sub CPU memory map (hyprduel.cpp:251-262)

The sub CPU has NO ROM. Its vectors and code live in shared RAM, written by
the main CPU before it releases the sub from reset.

| Range | Contents |
|-------|----------|
| 0x000000-0x003FFF | Shadow of Shared RAM 1 first 16 KB (vectors + code), r/w |
| 0x004000-0x007FFF | Shadow of Shared RAM 3 first 16 KB, READ ONLY (writes ignored) |
| 0x008000-0x01FFFF | Unmapped |
| 0x400000-0x400003 | YM2151 (8-bit regs on D0-D7, addr/data) |
| 0x400005 | OKI M6295 (8-bit) |
| 0xC00000-0xC07FFF | Shared RAM 1 |
| 0xFE0000-0xFE3FFF | Shared RAM 2 |
| 0xFE4000-0xFFFFFF | Shared RAM 3 |

MAME map-entry ordering note: the 0x000000 region is built from three
overlapping entries; the net effect is the table above (later entries
override earlier within overlap, then 0x8000+ unmapped).

## 4. Inter-CPU mechanics

### 4.1 Sub CPU control latch (main 0x800000, hyprduel.cpp:150-178)

Observed written values and MAME behaviour:

| Value | Effect |
|-------|--------|
| 0x01, 0x0D, 0x0F | Assert sub CPU RESET (hold in reset) |
| 0x00 | Release sub CPU from reset (MAME also spins main until next IRQ, an emulator scheduling aid, not hardware) |
| 0x0C, 0x80 | Pulse sub CPU IPL2 |

Core implementation: bitfield semantics are unknown; implement value-decoded
exactly as above (reset flop + IRQ pulse), log unexpected values. Sub starts
held in reset at power-on (machine_reset, hyprduel.cpp:389-395).

### 4.2 MAME sync hacks to IGNORE

init_hyprduel (hyprduel.cpp:520-527) installs spin_until_trigger handlers on
shared RAM addresses 0xC00408/0xC0040E (main) and 0xFFF34C (sub). These exist
only because MAME timeslices the two 68000s; the comment says "severe
timings". On FPGA both CPUs are truly concurrent and shared RAM is a real
dual-port resource, so these handlers must NOT be replicated. The takeaway
that DOES matter: the game's handshake protocol is timing-sensitive, so
shared RAM arbitration must not add large or asymmetric wait states.
RISK: flag for sim milestone M3 (full-system boot).

### 4.3 Interrupts

| CPU | Level | Source |
|-----|-------|--------|
| Main | IPL2 | Vblank (direct, outside VDP), pulsed at line 0 |
| Main | IPL3 | I4220 IRQ output (game enables only the hblank source) |
| Sub | IPL1 | YM2151 IRQ (timer) |
| Sub | IPL2 | Main CPU via control latch (0x0C/0x80) |

Magical Error (same board family, TEC5000) instead runs sub IPL1 from a
~968 Hz periodic source with a YM2413; out of scope for v1 but keep the
top level flexible.

## 5. Sound

- YM2151 @ 4 MHz -> JT51. IRQ line to sub IPL1. Route: mono, MAME weight 0.80.
- OKI M6295: MAME instantiates clock = 4 MHz/16/16*132 = 2.0625 MHz with
  pin7 = HIGH -> 15,625 Hz sample rate, flagged "clock frequency & pin 7 not
  verified". Use jt6295 with equivalent divider. Sample ROM 256 KB. Route
  weight 0.57.
- Final mix: (YM * 0.80 + OKI * 0.57), mono, saturating.

## 6. Inputs and DIP switches (hyprduel.cpp:299-374)

- P1/P2: 8-way stick + 3 buttons each, active low, one 16-bit port.
- SYSTEM: coin1/coin2 (impulse), service1/service2, start1/start2.
- SERVICE port: bit 15 service mode toggle, bit 14 "Show Warning".
- DSW: coinage A/B (3 bits each incl. free play), demo sounds, "Start Up
  Mode", flip screen, difficulty (2 bits), lives (2 bits).
- MRA dip definitions to mirror these exactly.

## 7. ROM sets (hyprduel.cpp:474-517)

Set `hyprduel` (Japan set 1):

| File | Size | Region | Load |
|------|------|--------|------|
| 24.u24 | 0x40000 | maincpu | even bytes (ROM_LOAD16_BYTE @ 0) |
| 23.u23 | 0x40000 | maincpu | odd bytes (@ 1) |
| ts_hyper-1.u74 | 0x100000 | vdp (GFX) | ROM_LOAD64_WORD @ 0 |
| ts_hyper-2.u75 | 0x100000 | vdp | @ 2 |
| ts_hyper-3.u76 | 0x100000 | vdp | @ 4 |
| ts_hyper-4.u77 | 0x100000 | vdp | @ 6 |
| 97.u97 | 0x40000 | oki | linear |

GFX interleave: 64-bit groups, each ROM contributes one 16-bit word per
group (byte offsets n*8 + {0,2,4,6}). In MRA terms: interleave output width
64, four parts mapped to word lanes. Set 2 (`hyprduel2`) differs only in the
two program ROMs (24a/23a). CRCs in the driver; MRA will carry them.

## 8. SDRAM / BRAM budget plan (MiSTer, DE10-Nano)

SDRAM regions (32 MB module, one bank layout TBD):

| Region | Size | Clients |
|--------|------|---------|
| Main CPU ROM | 512 KB | main 68k fetch (cacheable in BRAM later if needed) |
| GFX ROM | 4 MB | tile fetcher, sprite fetcher, blitter, CPU window |
| OKI samples | 256 KB | jt6295 |

BRAM (Cyclone V 5CSEBA6U23I7, ~5.5 Mbit):

| Block | Size |
|-------|------|
| VRAM x3 | 384 KB (3,072 kbit) - the big one; fits, but leaves ~2.4 Mbit for everything else. Fallback: move VRAM to SDRAM with per-line tile-row prefetch |
| Shared RAM 1/2/3 | 160 KB (1,280 kbit) true dual port |
| Palette | 8 KB |
| Sprite RAM x2 (live + buffer) | 8 KB |
| Tile table | 2 KB |
| Scratch RAM | 8 KB |
| Line buffers, FIFOs, zoom table, JT51/fx68k internals | remainder |

384 + 160 + ~30 KB is roughly 4.6 Mbit of 5.5 Mbit: tight, likely over
budget once CPU cores and framework are in. DECISION POINT for M4: first
candidate to spill to SDRAM is VRAM (predictable row-major line fetch).
Shared RAM must stay BRAM (latency-critical CPU handshake).

## 9. Reference stack for verification

- MAME as oracle: Lua/debugger scripts to dump VDP register state + VRAM +
  tile table + sprite RAM + palette at chosen frames; RTL testbench replays
  the dump and diffs the rendered frame pixel-for-pixel.
- Frame-level dumps cannot capture the per-scanline register writes the game
  does off hblank IRQ (spec sec 10); those need full-system sim or trace
  replay with line granularity.
- fx68k (cycle-accurate 68000), jt51, jt6295 as vendored cores; MiSTer
  Template_MiSTer for the framework shell.
