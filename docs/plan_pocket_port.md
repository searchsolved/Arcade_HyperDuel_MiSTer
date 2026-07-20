# Plan: Analogue Pocket port (Hyper Duel + Magical Error)

Port the released MiSTer core (v1.1, both games) to the Analogue
Pocket via openFPGA. The core RTL (i4220_vdp, i4220_render,
i4220_blitter, hyprduel_sys, fx68k, jt51, jt6295, IKAOPLL) is
target-agnostic SystemVerilog and carries over; the MiSTer shell,
SDRAM controller and framework glue get replaced.

## Verified facts vs to-verify

**Measured from the v1.1 magerror fit report (Quartus 17, 5CSEBA6):**
- Each 64Kx16 VRAM = exactly 128 M10K blocks; 3 VRAMs = 384 of the
  518 total. Everything else in the `emu` hierarchy = 83 blocks
  (palette 8, shared2 16, spr_buf 4, tiletable 2, sr3 cache 2, fx68k
  microcode, linebuf, FIFOs, remainder).
- `emu` hierarchy (our core + shell, NO MiSTer framework): 467 M10K,
  3.72 Mbit, and ~22,800 "ALMs needed" - BUT this compile used
  AGGRESSIVE PERFORMANCE + timing-driven synthesis, which inflates
  ALM usage for speed. The older BALANCED hyprduel builds fitted in
  ~16k ALMs whole-chip.

**From Analogue's developer docs (to re-verify against the
core-template pinout in Phase 0):**
- Core FPGA: Cyclone V, 49k LE class (about 18,480 ALMs), 3.08 Mbit
  M10K = 308 blocks, speed grade C8 (SLOWER than the DE10-Nano's I7).
- External memories available to a core: 64 MB SDRAM (16-bit), two
  independent 16 MB cellular RAM (PSRAM) chips (async low-latency,
  or 133 MHz sync burst), 256 KB async SRAM.
- Framework: APF bridge for data loading (up to 32 data slots),
  74.25 MHz base clocks (core makes its own PLLs), video through
  Analogue's scaler (core outputs RGB + syncs at its own dot clock),
  i2s audio. Build flow targets Quartus 18.1 + a bitstream reversal
  step.

## The two headline risks (they compound)

1. **ALMs.** The Pocket has 18,480; our core needs somewhere between
   ~16k (BALANCED-mode history) and ~23k (current aggressive compile).
   The MiSTer-only logic we shed (hiscore module, ioctl glue) buys a
   little; the framework (ascal etc.) was outside `emu` and does not
   count. If the BALANCED number on the Pocket part lands above
   ~17.5k, the port needs a logic diet or is in trouble.
2. **Speed grade.** 80 MHz is architecturally required: the line
   budget is 424 dots x P_PIXDIV sys-cycles and hyprduel's measured
   worst line (4,987 cycles) only fits at PIXDIV=12 = 80 MHz. Timing
   closure at 80 MHz took AGGRESSIVE + seed sweeps on the FASTER I7
   part; C8 is a slower grade, and BALANCED (which we may need for
   ALMs) makes timing worse. These two push against each other.

**Therefore Phase 0 ends with a trial fit that converts both unknowns
into numbers before any real porting work.** If the trial fit fails
both modes, the honest fallback options are: render-pipeline
throughput work to tolerate a lower clock (real surgery), or park the
port. Decision point, not a surprise at week two.

The M10K story, by contrast, is comfortable: with VRAMs external,
core BRAM is ~83 blocks + new controller FIFOs against 308 available.

## Target memory architecture (cleaner than MiSTer)

MiSTer forces everything through one SDRAM. The Pocket has four
independent memories, which un-shares almost everything:

| Pocket memory | Contents | Notes |
|---|---|---|
| SDRAM 64 MB | main ROM, GFX ROM, OKI samples | new controller timed for the Pocket part; real DQM byte lanes mean the MiSTer no-byte-mask RMW hack can go |
| PSRAM 0 (16 MB) | the three 128 KB VRAMs | async mode first (simplest, ~low-latency single reads); sync burst held in reserve for blitter speed |
| SRAM 256 KB | shared1 + shared3 (240 KB worst case, magerror) | async SRAM with UB/LB byte enables: kills the sr3 RMW path AND the sub-CPU starvation cache; both CPUs arbitrate a near-BRAM-speed port |
| BRAM | palette, spr_buf/live, tiletable, linebuf, shared2, fx68k microcode, FIFOs | ~100 blocks, fits 3x over |

## Phases

**Phase 0 - Platform facts + feasibility trial fit (GO/NO-GO gate).**
Clone the openFPGA core-template; pin down from its pinout and docs:
exact FPGA part/speed grade, PSRAM part + async timing, SRAM byte
lanes, SDRAM part + timing, bridge write bandwidth, whether data
slots can read from inside zips (ROM UX), video dot-clock/refresh
constraints (will the panel take 60.24 Hz, or does the Pocket build
default to the existing 60 Hz compat option?). Install Quartus 18.1
on the compile PC alongside 17. Then the trial fit: bare Pocket-target
project, our core RTL as-is, VRAMs stubbed to an external port,
compile BALANCED and AGGRESSIVE for the 5CE part. Deliverables:
docs/pocket_platform_facts.md with numbers, and the ALM/Fmax verdict.
Fable work (feasibility judgement).

**Phase 1 - VRAM externalization (target-agnostic, sim-first).**
The only core-RTL surgery in the port, and it is renderer-adjacent:
- Probe first: instrument tb_system to count VRAM port accesses per
  line by source (renderer tile fetch, blitter, CPU) across boot +
  attract + worst scenes of BOTH games. Design from measured numbers,
  not guesses.
- New external-VRAM port on i4220_vdp (req/valid, latency-tolerant),
  arbitration renderer > CPU > blitter, and a per-line row cache in
  front of the renderer's tile fetches if the numbers say so.
- Latency-injection VRAM model in the tb at Pocket-PSRAM worst-case
  timing. The full existing gate stack must stay green: parity suite,
  SDRAM soak equivalents, line-budget/exposure/stale counters all
  zero, for both games.
- Watch blit-done IRQ timing specifically: games wait on it, and
  external VRAM slows blits vs 1-cycle BRAM. Compare against MAME
  parity; if a game misbehaves, sync-burst mode is the lever.
Verified entirely in sim before any Pocket hardware exists in the
loop. Fable work per the escalation contract (renderer internals).

**Phase 2 - Pocket platform layer.** core_top shell over the
template; PLL (80 MHz from 74.25); PSRAM controller (async FSM;
vendor a proven MIT-licensed openFPGA PSRAM controller as reference
if suitable); SRAM controller + simplified shared-RAM arbiter; new
SDRAM controller for the Pocket part; APF bridge loader implementing
the 4-file GFX interleave as scattered writes at download time (no
user-side ROM building if slots allow); interact.json for DIPs +
video option; video/audio glue; AND a debug overlay build variant
resurrected from the v6probe era, because there is no ssh into a
Pocket - on-screen state is the only telemetry. Largely Opus-executable
against a handoff doc once Phase 1 lands.

**Phase 3 - Hardware bring-up.** Build, reverse bitstream, SD card,
test on Lee's Pocket. Every iteration costs a physical card swap, so:
batch probes (the histogram-overlay philosophy), boot-status overlay
on from the first build, and every question that CAN be answered in
sim MUST be answered in sim first. Expect the SDRAM/PSRAM capture
timing to be the fight (it was on MiSTer: P_RET, phase shift).

**Phase 4 - Release.** Pocket packaging (core JSON set, platform
image), both games, README/ACCURACY updated with Pocket-specific
notes (scaler in the path, panel refresh behaviour), announce.

## Effort and sequencing

Phase 0: one session (and it can kill the project cheaply if the
numbers say no). Phase 1: one to two sessions. Phase 2: one to two.
Phase 3: one to three (manual loop uncertainty). Total: roughly five
to eight sessions of the kind this project runs.

## Standing constraints carried over

- No deploy without sim gates green; STA clean at whatever clock the
  trial fit blesses.
- Quartus 18.1 re-validation: the Quartus-17-era workarounds
  (altsyncram power-of-2 depths, jt6295 ramstyle, fx68k unpacked
  structs, elaboration balloon) may not apply or may need new forms.
  Treat every one as unproven on 18.1 until a compile says otherwise.
- The MiSTer release stays untouched on main; this branch owns the
  port. Shared RTL fixes flow main -> pocket, never diverge.
