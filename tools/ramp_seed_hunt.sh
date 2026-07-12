#!/bin/bash
# Find a sim rotation that actually plays the scroll-ramp (clouds) scenes.
# The attract rotation is seeded from uninitialized RAM, so we randomise
# uninit state per run (+verilator+rand+reset+2 +verilator+seed+N) and
# check the raster write log for the ramp signature: sy0/sy2 (regs 0/4)
# written during vblank lines (vpos >= 224), hundreds of times per cycle.
# On a hit, keep the CSVs + LATELOG for the write-schedule analysis and
# stop. Waits for the V261 ladder to finish first.
set -u
cd /Users/leefoot/python_scripts/hyperduel-mister/sim

while pgrep -f "v261_ladder.sh" > /dev/null; do sleep 300; done
echo "=== ladder clear, seed hunt starts $(date) ==="

for SEED in 11 23 37 51 68 84 97 113; do
  echo "--- seed $SEED $(date +%H:%M) ---"
  OUT=build/ramphunt_$SEED
  mkdir -p $OUT
  make boot FRAMES=3600 PLUSARGS="+SDRAM=1 +RASTERLOG=1 +LATELOG=$OUT/late.csv +verilator+rand+reset+2 +verilator+seed+$SEED" \
    > $OUT/run.log 2>&1
  cp build/raster_writes_sim.csv build/raster_kicks_sim.csv $OUT/ 2>/dev/null
  RAMP=$(awk -F, 'NR>1 && ($4=="478870" || $4=="478878") && $2>=224 {n++} END {print n+0}' $OUT/raster_writes_sim.csv 2>/dev/null)
  echo "seed $SEED: vblank sy-writes = $RAMP"
  grep -E "render|late" $OUT/run.log | head -5
  if [ "${RAMP:-0}" -gt 200 ]; then
    echo "=== RAMP SCENE FOUND with seed $SEED ==="
    break
  fi
done
echo "=== seed hunt done $(date) ==="
