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
