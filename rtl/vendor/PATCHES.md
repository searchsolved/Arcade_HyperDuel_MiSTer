# Vendor patches

## fx68k (github.com/ijor/fx68k, cloned 2026-07-04)

- `fx68k.sv`: all three `typedef struct` made `typedef struct packed`.
  Reason: Verilator 5.x rejects mixed blocking (`assign`) and non-blocking
  (`<=`) writes to different fields of the same UNPACKED struct
  (BLKANDNBLK on `Nanod`); packed structs are splittable and accepted.
  No functional change; Quartus accepts packed structs equally.

- `fx68k.sv`, `fx68kAlu.sv`: all `unique case` changed to `case`.
  Reason: Verilator enforces unique-case no-match as a runtime $stop; the
  ALU hits a benign no-match at time 0 before reset settles (X-init).
  Behaviour-neutral: the alternatives are mutually exclusive by
  construction; `unique` only added checking.

## fx68kAlu.sv ccrTable default (2026-07-05)
The `unique case` -> `case` Verilator patch removed the full-coverage
guarantee on the col-2/3 `case (1'b1)` in ccrTable, so Quartus 17.0.2
inferred a latch inside always_comb (Error 10166). Restored the
commented-out `default: ccrMask = CUNUSED;` which is behavior-neutral
(the branch was unreachable under the original unique semantics).

## jt6295_adpcm.v ramstyle attributes (2026-07-06)
Added `(* ramstyle = "logic" *)` to `lut[0:48]` and `gain_lut[0:15]`.
Reason: Quartus 17.0 inferred the 49-entry lut as a memory, padded the
depth to 64 but emitted a 49-deep .mif (Critical Warning 127005 depth
mismatch), immediately before quartus_map died with an access violation
(compile 7). Both tables are tiny; keeping them in logic is what
compile 6 did anyway ("uninferred, inappropriate RAM size") and
sidesteps the buggy path. Verilator ignores the attribute; no
functional change.

## fx68k.sv packed structs made Verilator-only (2026-07-06)
The 2026-07-04 packed-struct patch is now wrapped in `ifdef VERILATOR`
so Quartus elaborates the upstream UNPACKED structs. Working theory for
the 1h / 20-50GB Quartus 17 elaboration phase: s_nanod is ~90 fields
referenced throughout two CPU instances, and packing it turns every
field reference into part-select arithmetic in the Quartus front end.
Upstream unpacked structs are what every other MiSTer fx68k core
compiles. Verilator sees the packed form, unchanged, so sim behaviour
is bit-identical.

## ikaopll vendored (2026-07-19, magerror branch)
IKAOPLL (cycle-accurate, die-shot based YM2413) by Sehyeon Kim
(ika-musume), BSD-2-Clause, vendored UNMODIFIED from upstream commit
4d393238d1be33ea428a454956270504f037dfa3 (2025-01-04). Selected over
jtopl's jt2413 for the die-derived cycle accuracy; licence sits fine
beside the GPL cores (BSD-2 is GPL-compatible). Verilator 5.050 lint:
0 errors, 16 benign width warnings, no UNOPTFLAT/BLKANDNBLK/LATCH.
