# Opus handoff: magerror bring-up

You are resuming the Hyper Duel MiSTer core project on the `magerror`
branch. Hyper Duel v1.0 is RELEASED and announced; `main` is frozen at
the release state and you do not touch it. Your mission is Magical
Error wo Sagase (magerror), the second game on this hardware. The plan
of record is `docs/plan_magerror.md`; this document is your working
brief and your escalation contract.

## Read before doing anything

1. Memory file `hyperduel_mister_core.md` (auto-memory) - end-of-file
   checkpoints carry the current state and the resume point.
2. `docs/plan_magerror.md` - confirmed hardware deltas and work order.
3. `rtl/vendor/PATCHES.md` - every vendored-core landmine hit so far.
4. `reference/mame/hyprduel.cpp` - the oracle source for both games.
5. `docs/ACCURACY.md` sections 3.3 and 3.5 - what is proven and what
   was never exercised (this defines your escalation triggers).

## State at handoff

- Branch has: scoping plan (673f142), IKAOPLL vendored at
  `rtl/vendor/ikaopll/` + standalone smoke PASS (b5b8efd,
  `cd sim && make opll-smoke`).
- `roms/magerror.zip` present locally (gitignored), all 7 CRCs
  verified against the driver.
- Nothing else magerror-specific exists yet.

## Work order (from the plan, expanded)

**Session 1 goal: magerror boots to its title screen in tb_system.**

1. MAME oracle check: confirm local MAME 0.288 runs magerror headless
   (SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy) and that
   `sim/mame/dump_state.lua` works on it. Known MAME lua landmines are
   in memory: never tap maincpu 0x800000, never call
   screen:frame_number() inside tap callbacks, pin tap handles in _G.
2. ROM builds: `tools/build_gfxrom.py` and the main-ROM build should
   work unchanged (identical region sizes and interleave). Verify
   output sizes/hashes before simming.
3. System glue parameterisation in `rtl/hyprduel_sys.sv` (one RTL
   tree, a game-mode parameter or input, no forking): main-CPU VDP
   decode at 0x8xxxxx, int-enable at 0x8788A5, IRQ mask OR 0xFE,
   sub-CPU map with YM2413 writes at 0x800000-3 (write-only), no YM
   IRQ, periodic 968 Hz IRQ1 to the sub CPU instead. OKI unchanged.
   IKAOPLL wiring: 80 MHz clk + fractional 3.579545 MHz cen exactly as
   in `sim/tb/tb_opll_smoke.sv`.
4. Boot in tb_system with magerror ROMs against MAME state dumps.
   magerror uses empty_init (no cpusync hacks), so expect the shared
   RAM handshake to just work; if boot stalls, diff RAM state vs MAME
   at checkpoints exactly the way the hyprduel bring-up did.

**Session 2: parity + audio + synthesis.** Adapt the frame-parity
suite to magerror scenes; settle the OPLL mix scale/polarity against
MAME audio (the ACC output is near-unipolar impulse form, expected);
translate the magerror DIP table for sims (do NOT reuse +DSW=DF80,
that is Hyper Duel's); then the standard compile pipeline. Expect fit
to improve (jt51 out, IKAOPLL in). Full gates before any deploy: STA
clean, SDRAM-model soak with all integrity counters zero, parity
suite green.

**Session 3: hardware + release polish.** Deploy with the documented
sequence (menu core, scp, md5 both sides, load MRA - ssh options
spelled INLINE, zsh does not word-split variables). Write the magerror
MRA (prefer same RBF + an MRA mod byte to select game mode; second
RBF only if that fails). CRT verification by Lee. Release packaging
only after his verdict.

## Standing rules (violations have burned days; do not relearn them)

- Absolute paths ALWAYS; the shell cwd resets between some calls.
- Compile PC: `ssh leefoot@192.168.1.207`, fire via
  `schtasks /run /tn hyprcompile`, ONE Quartus job at a time, E-core
  affinity is already in runcompile.cmd. If the box IP moved, scan the
  subnet first.
- Never deploy on register metrics alone. STA gate + soak gate first,
  every time.
- Sims that gate deploys use the SDRAM model (+SDRAM=1) and the
  correct DIP word.
- Commit at Lee-approved milestones. NO Co-Authored-By trailers in
  this repo (see memory: feedback-no-claude-trailer-hyperduel).
- Nothing public without Lee's explicit word: no pushes to `main`, no
  release edits, no posts, no replies on the MAME issue.
- No em dashes in any written output.

## When to recommend switching back to Fable

You are the execution engine for a plan that is already de-risked.
The moment the work stops being execution and starts being theory
formation about chip behaviour, say so plainly and recommend Lee
switches models. Concrete triggers:

1. **Unexplained oracle divergence that survives ~2 hours of focused
   debugging.** A parity diff, boot stall, or state mismatch where you
   cannot name the mechanism with evidence. Do not iterate guesses;
   the v7 disaster (a plausible fix that was garbage by construction)
   is the cautionary tale.
2. **The 8bpp / unexercised-corner wildcard fires.** Any evidence
   magerror uses I4220 features Hyper Duel never touched: oracle
   diffs on new scene types, tiles rendering as garbage while VRAM
   state matches MAME, blitter output mismatches on ops the blit
   suite never covered. Extending `i4220_vdp.sv` or `i4220_render.sv`
   internals is Fable work; those files are the hardest-won RTL in the
   repo.
3. **Any change to the renderer or VDP beyond parameter plumbing.**
   If your fix touches scanline scheduling, the line-buffer banks, the
   scroll sampling, or the CRTC window logic, stop and escalate. That
   code encodes a season of silicon-verified lessons.
4. **A Quartus failure with no matching entry** in memory or
   `rtl/vendor/PATCHES.md`. The documented failure modes (elaboration
   balloon, M10K overflow, mif depth crash, P-core instability) have
   known fixes; a NEW failure mode needs the full context. IKAOPLL has
   never been through Quartus 17 - this is the most likely place a new
   one appears.
5. **Timing closure stuck worse than about -0.5 ns after a seed
   sweep.** That was the historical threshold between seed luck and
   structural work; structural timing surgery is Fable work.
6. **Sim-vs-hardware divergence**: anything that is clean in
   simulation but wrong on the box. Historically the most expensive
   class of bug in this project (blank-screen saga, v9 stale lines).
   Escalate after ONE failed evidence-based fix attempt, not after
   five build cycles of guesses.
7. **Anything touching public-facing state**: main branch, releases,
   the MAME issue, announcements. Not a capability question; Lee
   decides those regardless of model.

Anti-triggers - do NOT recommend switching for: compile babysitting,
harness/Makefile adaptation, MRA and DIP translation, ROM tooling,
rerunning suites, or failures that match a documented gotcha. Handle
those.

When a trigger fires, write down: what you observed, what you ruled
out with evidence, and the exact question that needs answering. That
note is the handoff back; it saves the next session an hour of
re-derivation.

## Definition of done

magerror plays start to finish on Lee's CRT, hiscore behaviour
checked, parity and soak suites green in the repo, MRA published with
the same evidence-first documentation standard as v1.0, ACCURACY.md
extended with a magerror section that names what was and was not
verified. Lee's PVM verdict is the final gate, always.
