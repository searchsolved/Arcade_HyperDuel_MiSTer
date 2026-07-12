#!/bin/bash
# Waits for the MiSTer to come online, then deploys the staged RBF safely:
# menu core first (CRT protect), scp, md5 verify both sides, load MRA.
set -u
RBF=/Users/leefoot/python_scripts/hyperduel-mister/builds/Hyprduel_v2g768.rbf
MISTER=root@192.168.1.208
# MiSTer uses password auth (root/1): everything goes through sshpass
SSH="sshpass -p 1 ssh -o StrictHostKeyChecking=no -o PubkeyAuthentication=no"
SCP="sshpass -p 1 scp -O -o StrictHostKeyChecking=no -o PubkeyAuthentication=no"
LOCAL_MD5=$(md5 -q "$RBF")

for i in $(seq 1 480); do  # up to 8 hours, 60s interval
  if $SSH -o ConnectTimeout=5 $MISTER "echo up" >/dev/null 2>&1; then
    sleep 20  # let it finish booting
    $SSH $MISTER "echo load_core /media/fat/menu.rbf > /dev/MiSTer_cmd"
    sleep 3
    $SCP "$RBF" $MISTER:/media/fat/_Arcade/cores/Hyprduel.rbf || exit 1
    REMOTE_MD5=$($SSH $MISTER "md5sum /media/fat/_Arcade/cores/Hyprduel.rbf" | awk '{print $1}')
    if [ "$LOCAL_MD5" != "$REMOTE_MD5" ]; then
      echo "MD5 MISMATCH: local=$LOCAL_MD5 remote=$REMOTE_MD5"
      exit 1
    fi
    MRA=$($SSH $MISTER "ls /media/fat/_Arcade/*.mra | grep -i 'hyper' | head -1")
    if [ -n "$MRA" ]; then
      $SSH $MISTER "echo load_core '$MRA' > /dev/MiSTer_cmd"
    fi
    echo "DEPLOYED OK md5=$LOCAL_MD5 at $(date)"
    exit 0
  fi
  sleep 60
done
echo "TIMED OUT waiting for MiSTer"
exit 1
