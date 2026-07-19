#!/bin/bash
# Waits for the MiSTer, loads Hyper Duel, then captures a screenshot every
# 2s for 4 minutes (covers a full attract rotation incl. both raster
# scenes), and pulls them back for top-scanline analysis.
set -u
SSH="sshpass -p 1 ssh -o StrictHostKeyChecking=no -o PubkeyAuthentication=no -o ConnectTimeout=5"
SCP="sshpass -p 1 scp -O -o StrictHostKeyChecking=no -o PubkeyAuthentication=no"
M=root@192.168.1.208
OUT=/Users/leefoot/python_scripts/hyperduel-mister/hw_shots
PREFIX="${1:-v13_}"
mkdir -p "$OUT"

for i in $(seq 1 480); do  # up to 8h
  if $SSH $M "echo up" >/dev/null 2>&1; then
    sleep 25   # boot settle
    $SSH $M "echo load_core '/media/fat/_Arcade/Hyper Duel.mra' > /dev/MiSTer_cmd"
    sleep 30   # core load + game boot into attract
    $SSH $M "rm -rf /media/fat/screenshots/burst; mkdir -p /media/fat/screenshots"
    for n in $(seq 1 120); do
      $SSH $M "echo screenshot ${PREFIX}$n.png > /dev/MiSTer_cmd"
      sleep 2
    done
    sleep 3
    $SCP -r "$M:/media/fat/screenshots/*" "$OUT/" 2>/dev/null
    echo "CAPTURED: $(ls $OUT | wc -l) files at $(date +%H:%M)"
    exit 0
  fi
  sleep 60
done
echo "TIMED OUT waiting for MiSTer"
exit 1
