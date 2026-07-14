#!/usr/bin/env python3
"""Cross-check the RTL frame-global scroll predictor against a software
replay of the same algorithm, event by event, using one sim run's outputs:

  raster_writes_sim.csv  (all scroll register writes: frame,vpos,hpos,addr,data)
  fg.csv                 (+FGLOG probe: frame,reg,written,pred,err at each
                          line-0 write to sx0/sy1/sx1/sx2)

The RTL latches prev_fg on every write to a scroll reg and computes
pred = cur + (cur - prev) at the line-0 kick (start of frame). The replay
mirrors that from the write log and diffs against the RTL's logged pred.

Usage: fgpred_crosscheck.py <rundir>   (dir containing both CSVs)
Exit 0 = every event matches, nonzero otherwise.
"""
import sys, os

REGS = {'478872': 1, '478874': 2, '478876': 3, '47887a': 5}
IDX2NAME = {1: 'sx0', 2: 'sy1', 3: 'sx1', 5: 'sx2'}

rundir = sys.argv[1]

# Replay: track (cur, prev) per reg from the write log; snapshot pred at
# each frame boundary (kick happens at the start of the frame, before any
# writes logged with that frame number).
cur = {i: 0 for i in REGS.values()}
prev = {i: 0 for i in REGS.values()}
pred_at_frame = {}          # (frame, idx) -> predicted value
last_frame = -1

with open(os.path.join(rundir, 'raster_writes_sim.csv')) as f:
    next(f)
    for line in f:
        parts = line.strip().split(',')
        if len(parts) != 5:
            continue
        frame, vpos, hpos, addr, data = parts
        frame = int(frame)
        if frame != last_frame:
            for fr in range(last_frame + 1, frame + 1):
                for i in cur:
                    pred_at_frame[(fr, i)] = (cur[i] + (cur[i] - prev[i])) & 0xFFFF
            last_frame = frame
        if addr in REGS:
            i = REGS[addr]
            prev[i] = cur[i]
            cur[i] = int(data, 16)

events = matches = 0
mismatches = []
with open(os.path.join(rundir, 'fg.csv')) as f:
    next(f)
    for line in f:
        parts = line.strip().split(',')
        if len(parts) != 5:
            continue
        frame, reg, written, rtl_pred, err = (int(x) for x in parts)
        events += 1
        want = pred_at_frame.get((frame, reg))
        if want is None:
            mismatches.append((frame, reg, 'no-replay-pred', rtl_pred))
        elif want == rtl_pred:
            matches += 1
        else:
            mismatches.append((frame, reg, want, rtl_pred))

print(f"fg cross-check: events={events} match={matches} mismatch={len(mismatches)}")
for m in mismatches[:20]:
    fr, reg, want, got = m
    print(f"  frame {fr} {IDX2NAME.get(reg, reg)}: replay={want} rtl={got}")
sys.exit(0 if events > 0 and not mismatches else 1)
