#!/bin/bash
# Hunt for a rotation that plays the scroll-ramp (clouds) scenes with the
# CURRENT binary (X-prediction fix + FGLOG probe), and collect everything
# needed to gate the fix in the same run: raster write log, late-kick log,
# and the per-event frame-global prediction log (+FGLOG).
# Ramp signature: sy0/sy2 (478870/478878) written during vblank (vpos>=224),
# hundreds of times per rotation cycle.
set -u
cd /Users/leefoot/python_scripts/hyperduel-mister/sim

echo "=== xpred hunt starts $(date) ==="
for SEED in 7 13 29 42 57 71 88 101; do
  echo "--- seed $SEED $(date +%H:%M) ---"
  OUT=build/xpredhunt_$SEED
  mkdir -p $OUT
  make boot FRAMES=3600 PLUSARGS="+SDRAM=1 +RASTERLOG=1 +LATELOG=$OUT/late.csv +FGLOG=$OUT/fg.csv +verilator+rand+reset+2 +verilator+seed+$SEED" \
    > $OUT/run.log 2>&1
  cp build/raster_writes_sim.csv build/raster_kicks_sim.csv $OUT/ 2>/dev/null
  RAMP=$(awk -F, 'NR>1 && ($4=="478870" || $4=="478878") && $2>=224 {n++} END {print n+0}' $OUT/raster_writes_sim.csv 2>/dev/null)
  echo "seed $SEED: vblank sy-writes = $RAMP"
  grep -E "render|late|fg scroll" $OUT/run.log | head -8
  if [ "${RAMP:-0}" -gt 200 ]; then
    echo "=== RAMP SCENE FOUND with seed $SEED ==="
    break
  fi
done
echo "=== xpred hunt done $(date) ==="
