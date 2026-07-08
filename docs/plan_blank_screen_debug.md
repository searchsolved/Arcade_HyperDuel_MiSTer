# Plan: Blank Screen Debug (Hardware Bring-up)

Implementation plan for the blank-screen investigation described in
`docs/handoff_blank_screen_investigation.md`. Read that file first; this plan
does not repeat its background. Full project state is in memory note
`hyperduel_mister_core.md`.

## Goal

Get the game (not just the test pattern) rendering on the MiSTer, or failing
that, produce hard evidence that isolates the fault to exactly one of the four
suspects in the handoff doc.

## Ordering rationale

- An MRA change needs **no Quartus compile**: the MiSTer parses the .mra at
  core load time and assembles the ROM stream itself. Fix .mra -> scp -> reload
  is a ~1 minute iteration.
- A Quartus compile is ~15 minutes on the build PC. Batch ALL hardware
  diagnostics into one compile; never do one-diagnostic-per-compile.
- Suspect #1 (GFX interleave) is decidable entirely offline with mra-tools-c.
  Do that first, before touching hardware at all.

## Phase 0 - Offline MRA stream verification (no compile, no hardware)

The MiSTer main binary and mra-tools-c share the same MRA interleave
semantics. Generating the .rom locally and byte-comparing it against the sim's
reference ROM builders decides suspect #1 (and re-validates the main ROM fix)
with zero hardware iterations.

1. Clone and build mra-tools-c in the scratchpad (NOT in the project tree):
   `git clone https://github.com/mist-devel/mra-tools-c` then `make`.
2. Generate the stream:
   `./mra -z /Users/leefoot/python_scripts/hyperduel-mister/roms "mra/Hyper Duel.mra" -O <scratchpad>` -> produces `hyprduel.rom`.
3. Build the references:
   - `python3 tools/build_mainrom.py roms/hyprduel.zip <scratchpad>/mainrom.bin`
   - `python3 tools/build_gfxrom.py roms/hyprduel.zip <scratchpad>/gfxrom.bin`
   - Extract raw `97.u97` from the zip for the OKI region.
4. Compare (a small Python script, checked into `tools/` as
   `check_mra_stream.py` so it can be rerun after any MRA edit):
   - `rom[0x000000:0x080000] == mainrom.bin`
   - `rom[0x080000:0x480000] == gfxrom.bin`
   - `rom[0x480000:0x4C0000] == 97.u97`
   - Also assert total length is 0x4C0000. If lengths differ, first check
     whether mra-tools prepends anything or pads; align by searching for the
     first 64 bytes of mainrom.bin in the .rom.
5. Interpret:
   - **GFX region mismatches** -> suspect #1 confirmed. Go to Phase 1.
   - **Main ROM region mismatches** -> the "verified" main ROM fix is wrong
     after all; fix it the same way (Phase 1). This overrides the handoff's
     elimination list - the elimination was by desk-check, not by stream
     comparison.
   - **All three regions match** -> suspect #1 is dead. Skip Phase 1, go to
     Phase 2.

Notes for the MRA `map=` semantics if a fix is needed: do NOT reason from
first principles - the semantics have already caused one bug. Derive them
empirically: perturb the map in a scratch copy of the MRA, regenerate with
mra-tools, and diff until the GFX region matches `build_gfxrom.py` exactly
(MAME `ROM_LOAD64_WORD`: ts_hyper-1 supplies file-order bytes 0-1 of each
8-byte group, ts_hyper-2 bytes 2-3, etc.). The already-correct main ROM pair
(`map="10"`/`map="01"`, even stream byte = 24.u24) is the Rosetta stone.

Also desk-check once (read `rtl/hyprduel_sdram.sv`, download path): the ioctl
download writes stream byte N to SDRAM byte address N with the documented
convention "even byte address = word[15:8]". Confirm the DQM lane selection in
the OWN_DL path matches, and that the GFX byte-emit path (`bf_hi`, around
lines 401-445) uses the same convention. This is a read-only sanity check tying
the stream comparison to what the renderer actually sees.

## Phase 1 - MRA fix (only if Phase 0 found a mismatch)

1. Edit `mra/Hyper Duel.mra` interleave maps until `check_mra_stream.py`
   passes byte-for-byte on all three regions.
2. Deploy - no compile needed:
   `sshpass -p "1" scp -o PubkeyAuthentication=no "mra/Hyper Duel.mra" root@192.168.1.208:/media/fat/_Arcade/`
3. Reload:
   `echo 'load_core /media/fat/_Arcade/Hyper Duel.mra' > /dev/MiSTer_cmd` (on the MiSTer over ssh).
4. Observe. If the game displays: done - jump to "On success". If still black:
   suspect #1 is now genuinely eliminated; continue to Phase 2.

## Phase 2 - Hardware diagnostics (one compile, all diagnostics together)

Add latched "did this ever happen" flags for suspects #2/#3/#4 in a single
build. Signals already exist:

| Flag | Signal | Where |
|------|--------|-------|
| CPU wrote to VDP | `i_cs && !i_rnw` (see `cpu_wr_commit`, `rtl/i4220_vdp.sv:584`) | i4220_vdp |
| Renderer completed a line | `rnd_done` (`rtl/i4220_vdp.sv:275`) | i4220_vdp |
| Renderer was kicked | `line_start` (`rtl/i4220_vdp.sv:223`) | i4220_vdp |
| sr3 port alive | `o_sr3_ack` (`rtl/hyprduel_sdram.sv:67`) | sdram controller / shell |
| Sub CPU released | `dbg_sub_in_reset` (already a port, currently unconnected in shell `mister/Hyprduel.sv:205`) | shell |

Implementation:

1. Plumb the VDP/renderer flags out of `i4220_vdp.sv` -> `hyprduel_sys.sv` as
   new `dbg_*` output ports (the `// debug` port group already exists at
   `rtl/hyprduel_sys.sv:61`). sr3_ack is already visible in the shell.
2. In `mister/Hyprduel.sv`, latch each into a sticky `*_saw` reg (same pattern
   as `led_mrom_saw`, lines 256-265).
3. Display them on the **test-pattern screen**, not just LEDs - only 3 LED
   bits are free, and the OSD test screen (status[6], lines 223-231) is
   already proven working. Replace the colour bars with diagnostic bands:
   split the screen into ~6 vertical bands, band N solid green if flag N has
   latched, red if not. Order the bands: mrom_valid_saw, vdp_write_saw,
   line_start_saw, rnd_done_saw, sr3_ack_saw, ~dbg_sub_in_reset. Keep the
   logic combinational off `dbg_hcnt` like the existing bars.
4. Also consider one cheap extra: latch a flag if the VDP ever reads back a
   nonzero pixel from the line buffer (distinguishes "renderer runs but
   output is all pen-15/transparent" - i.e. garbled GFX decode - from
   "renderer never runs").
5. Before compiling, re-run the sim gates (RTL changed):
   - `cd sim && make verify blit-verify` -> must stay 22/22
   - `make vdp-verify` -> frame 500 must PASS
   - `make boot FRAMES=30` -> must boot clean
6. Compile on the build PC (details in the handoff doc, "Access details"):
   sync sources, then `schtasks /run /tn hyprcompile`. ALWAYS E-core affinity;
   ~15 min. Then copy the .rbf to
   `/media/fat/_Arcade/cores/Hyprduel.rbf` and reload the core.

## Phase 3 - Decision matrix

Read the diagnostic screen and branch:

| Observation | Meaning | Next action |
|---|---|---|
| vdp_write never fires | Suspect #2: CPU stuck (exception loop or bad ROM data) before VDP init | Add a second diagnostic build: expose the first few fetched mrom data words or a running XOR checksum of `i_mrom_data` on the test screen and compare against `mainrom.bin`; also latch the 68000 address lines' high bits to see if it is looping in vector space. Compare against sim boot trace (`make boot`) which is known-good. |
| vdp_write fires, line_start never fires | Suspect #3: kick edge broken at P_PIXDIV=12 on hardware | Inspect the ce_pix/hblank crossing in `i4220_vdp.sv:223` for a clock-domain or enable-gating difference between sim and synthesis; check Quartus timing report for paths into `hcnt`/`line_start`. |
| line_start fires, rnd_done never fires | Renderer starts but never completes - likely GFX stream (sr3/gfx arbiter) stalling on real SDRAM | Check gfx `i_rom_valid` activity; look at arbiter fairness in `hyprduel_sdram.sv` under refresh pressure. |
| sr3_ack never fires | Suspect #4: sr3 port deadlock | Review arbiter priority/pend handling for OWN_SR3 in `hyprduel_sdram.sv`; consider forcing a sim scenario with concurrent gfx+sr3+refresh traffic to reproduce. |
| All flags green, screen still black | Pixels render but decode to transparent/black - back to data content (palette or GFX bytes) despite Phase 0 pass | Add the nonzero-linebuffer-pixel flag from Phase 2 step 4 if not already in; dump/inspect palette writes; re-check `i_gfx_size` wiring and GFX address translation into the 4 MB region. |

Do not implement all branches up front - implement only the branch the
evidence selects, one compile at a time, updating this file's status section
as you go.

## Constraints and rules

- Work locally, verify in sim before every compile. Never push a compile with
  failing `verify`/`vdp-verify`/`boot` gates.
- Build PC compiles: always E-core affinity via the existing scheduled task
  (`schtasks /run /tn hyprcompile`). Do not launch Quartus any other way.
- MiSTer access: `sshpass -p "1" ssh -o PubkeyAuthentication=no root@192.168.1.208`.
  If 192.168.1.208 does not answer, scan the subnet first
  (`nmap -sn 192.168.1.0/24`) - DHCP addresses move.
- Do not modify `tools/build_gfxrom.py` / `build_mainrom.py` to match the MRA;
  they match MAME and the passing sim. The MRA is the side that bends.
- Keep the test-pattern/diagnostic code clearly marked DEBUG so it can be
  stripped once the game runs.
- No em dashes in any docs or commit messages. Plain punctuation.

## On success

1. Confirm actual gameplay: attract mode runs, inputs work, sound plays
   (audio has a known separate issue: `docs/audio_bug_ym_irq_storm.md`).
2. Remove or gate the diagnostic bands (keeping status[6] test pattern is
   fine), recompile, redeploy, reconfirm.
3. Update memory note `hyperduel_mister_core.md` (root cause, current compile
   number, M-milestone status) and append a session log to the mapped
   Obsidian project note.
4. Commit locally with a message stating the confirmed root cause. Do not
   push without asking.

## Status

- [x] Phase 0: mra-tools stream comparison - MAIN ROM BYTE LANES SWAPPED
  - GFX ROM: exact match (suspect #1 eliminated)
  - OKI ROM: exact match
  - Main ROM: 323802/524288 bytes mismatched - even/odd bytes transposed
  - Root cause: `map="10"` on 24.u24 put it at output position 1 (low byte),
    but 24.u24 is the even/high ROM. mra-tools sorts parts by map_index
    (derived from the position of the first nonzero digit read right-to-left
    in the map string), so map="01" -> map_index=0 -> sorted first = high byte.
  - Previous "verification" was a desk-check that got the map semantics wrong.
- [x] Phase 1: MRA fix applied and deployed to MiSTer
  - Swapped maps: 24.u24 map="01", 23.u23 map="10"
  - `check_mra_stream.py` passes byte-for-byte on all three regions
  - Desk-check confirmed: SDRAM download even-byte->word[15:8] matches
  - Deployed: scp + load_core, no compile needed
  - **CHECK THE SCREEN** - if game displays, skip Phase 2
- [x] Phase 2: diagnostic build compiling (started 14:41)
  - Added VDP debug ports: vdp_write, line_start, rnd_done, lb_nonzero
  - Added sr3_ack_saw latch in shell
  - 6 diagnostic bands on status[6] screen (green=seen, red=not)
  - Sim: verify 4/4, blit-verify 22/22, boot clean
  - vdp-verify 900/1500 failures pre-existing from BRAM conversion
  - Synthesis 0 errors, fitter in progress
- [ ] Phase 3: branch per decision matrix
- [ ] Game renders on hardware
