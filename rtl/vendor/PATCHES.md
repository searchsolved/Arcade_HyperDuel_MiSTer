# Vendor patches

## fx68k (github.com/ijor/fx68k, cloned 2026-07-04)

- `fx68k.sv`: all three `typedef struct` made `typedef struct packed`.
  Reason: Verilator 5.x rejects mixed blocking (`assign`) and non-blocking
  (`<=`) writes to different fields of the same UNPACKED struct
  (BLKANDNBLK on `Nanod`); packed structs are splittable and accepted.
  No functional change; Quartus accepts packed structs equally.
