#!/bin/bash
# Overnight verification ladder for the 261-line (60.2408 Hz) timing.
# Waits for the in-flight v2 soak to finish, then runs sequentially:
#   1. 5,200-frame SDRAM soak with late-completion logging
#   2. scripted bomb test (worst-case gameplay)
#   3. audio run for the closing-the-loop timing check vs the PCB videos
#   4. raster kick/write log for the freshness re-analysis
# Everything logs under sim/build/v261_*; PPMs land in sim/build/boot
# (plusarg quirk) and are snapshotted after each stage.
set -u
cd /Users/leefoot/python_scripts/hyperduel-mister/sim

# 1. wait for the v2 soak
while pgrep -f "OUTDIR=build/v2soak52" > /dev/null; do sleep 120; done
echo "=== v2 soak clear, starting V261 ladder at $(date) ==="

mkdir -p build/v261soak build/v261bomb build/v261audio build/v261raster

echo "--- stage 1: 5200-frame soak ---"
make boot FRAMES=5200 PLUSARGS="+SDRAM=1 +LATELOG=build/v261soak/late.csv" \
  > build/v261soak/run.log 2>&1
grep -E "render|simulated" build/v261soak/run.log
cp build/boot/boot_51*.ppm build/boot/boot_3000.ppm build/v261soak/ 2>/dev/null

echo "--- stage 2: bomb test ---"
make boot FRAMES=2500 PLUSARGS="+SDRAM=1 +INPUTS=inputs/inputs_bombtest.txt +LATELOG=build/v261bomb/late.csv" \
  > build/v261bomb/run.log 2>&1
grep -E "render|simulated" build/v261bomb/run.log

echo "--- stage 3: audio timing run ---"
make boot FRAMES=2500 AUDIODUMP=build/v261audio/mix.raw \
  PLUSARGS="+AUDIOSPLIT=build/v261audio/split" \
  > build/v261audio/run.log 2>&1
grep -E "simulated" build/v261audio/run.log

echo "--- stage 4: raster kick log ---"
make boot FRAMES=1700 PLUSARGS="+SDRAM=1 +RASTERLOG=1" \
  > build/v261raster/run.log 2>&1
cp build/raster_kicks_sim.csv build/raster_writes_sim.csv build/v261raster/ 2>/dev/null
grep -E "render|simulated" build/v261raster/run.log

echo "=== V261 ladder complete at $(date) ==="
