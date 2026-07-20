# Reply draft: mamedev/mame#15732, answer to angelosa on the 655k writes

Paste-ready reply below the line. Evidence produced 2026-07-20 with
sim/mame/tap_crtc_horz.lua / horz2 / horz3 / tap_scrctl.lua (PC-stamped
write taps) plus the row-shift stability metric over the first 12 s of
the PCB footage. This reply CORRECTS one sentence of the original
report (the bulk writes run with the unlock latch set, not cleared)
and adds the horizontal parameter decode.

---

Good question, and re-tracing it with PC capture improved the answer
and corrects one sentence of the report.

**The bulk is a calibrated delay loop.** All 655,360 bulk writes come
from one routine, executed once during each of the two long blank
pauses in the boot sequence:

```
00869E  move.w #$0001,$4788A0    ; unlock
0086A6  clr.w  d0
0086A8  move.w d0,$478890        ; x5, unrolled
  ...
0086C6  nop                      ; x60
  ...
00873E  addq.w #1,d0
008740  bne.w  $86A8             ; 65,536 iterations
008744  clr.w  $4788A0           ; lock
```

2 passes x 5 writes x 65,536 = 655,360. The written data is the loop
counter itself (each of the five write PCs sweeps 0000-FFFF), which
rules out programming intent. With the NOP sled and five wait-stated
VDP bus writes per iteration it reads as a delay timed against the VDP
bus rather than raw CPU speed. So not lock-style obfuscation: the
noise is a timer, and the real programming is cleanly bracketed
elsewhere.

**Correction to the report, and the part your question flushed out.**
Two things the original trace got wrong or missed:

1. The bulk writes happen with the unlock latch SET as currently
   modeled (the 0x869E write above), not cleared as the report said.
2. 40 writes to 0x78890 in the first 450 frames are real parameter
   programming: the routine that writes the vertical set also writes a
   five-parameter horizontal set inside its own unlock brackets (lock
   at PC 0x8744, unlock written twice at 0x874C and 0x8754, vertical
   params, horizontal params, lock at 0x87A4; final set at
   0x8802..0x886C; screen control 0x700 written at the end of the same
   routine).

Decoding the horizontal words as {param[15:10], value[9:0]} (the
vertical register uses {param[15:8], value[7:0]}; horizontal needs the
wider value field since the line is longer than 256 dots):

| set | p0 | p1 | p2 | p3 | p4 |
|---|---|---|---|---|---|
| transitional | 21 | 338 | 374 | 380 | 422 |
| final | 19 | 342 | 352 | 395 | 422 |

These are coherent positions in a 424-dot line: p0 = first visible dot
(the horizontal analogue of vertical p7 = first visible line, with the
same 2-unit transitional shift), and p4 + 2 = 424 = exactly the htotal
the refresh measurement implies (26.666 MHz / 4 / (424 x 261) =
60.2408 Hz). So both CRTC registers program the display window, and
the game's own horizontal programming now corroborates the htotal in
the suggested set_raw.

**Which leaves the real question: why does silicon ignore the sweep?**
The second delay pass runs after screen control has been set to 0x700,
with the memory check screen up, and the PCB footage shows no
horizontal disturbance anywhere in the boot (checked with a per-frame
row-shift stability metric over the first 12 s, not just eyeballed).
So the chip cannot be applying raw writes as parameter updates even
though the unlock latch, as modeled, is set. Two hypotheses fit
everything observable:

1. Unlock is a key sequence rather than a level: the real programming
   is always preceded by lock-then-unlock-written-twice, while the
   delay loop only ever writes unlock once. Under that protocol the
   sweep runs effectively locked.
2. Writes stage and only commit on the lock edge: sweep garbage would
   stage but be replaced by the real set microseconds before every
   commit, and would never be visible for more than a fraction of a
   frame.

Write traces from other i4100/i4220 titles (or a test on a live board)
would discriminate between the two. Happy to share the PC-stamped
traces if useful.
