#!/bin/bash
# Waits for the MiSTer to come online (mDNS first, DHCP-safe), then rolls
# the core back to v6: menu core first (CRT protect), scp, md5 verify, load MRA.
set -u
RBF=/Users/leefoot/python_scripts/hyperduel-mister/builds/Hyprduel_v6probe.rbf
SSH_OPTS="-o StrictHostKeyChecking=no -o PubkeyAuthentication=no -o ConnectTimeout=5"
LOCAL_MD5=$(md5 -q "$RBF")

find_mister() {
  # mDNS name first (DHCP-safe), then the last known lease
  for h in MiSTer.local 192.168.1.208; do
    if sshpass -p 1 ssh $SSH_OPTS "root@$h" "echo up" >/dev/null 2>&1; then
      echo "$h"; return 0
    fi
  done
  return 1
}

for i in $(seq 1 480); do  # up to 8 hours, 60s interval
  HOST=$(find_mister) || { sleep 60; continue; }
  MISTER="root@$HOST"
  echo "MiSTer up at $HOST $(date +%H:%M)"
  sleep 20  # let it finish booting
  sshpass -p 1 ssh $SSH_OPTS $MISTER "echo load_core /media/fat/menu.rbf > /dev/MiSTer_cmd"
  sleep 3
  sshpass -p 1 scp -O $SSH_OPTS "$RBF" $MISTER:/media/fat/_Arcade/cores/Hyprduel.rbf || exit 1
  REMOTE_MD5=$(sshpass -p 1 ssh $SSH_OPTS $MISTER "md5sum /media/fat/_Arcade/cores/Hyprduel.rbf" | awk '{print $1}')
  if [ "$LOCAL_MD5" != "$REMOTE_MD5" ]; then
    echo "MD5 MISMATCH: local=$LOCAL_MD5 remote=$REMOTE_MD5"
    exit 1
  fi
  MRA=$(sshpass -p 1 ssh $SSH_OPTS $MISTER "ls /media/fat/_Arcade/*.mra | grep -i 'hyper' | head -1")
  if [ -n "$MRA" ]; then
    sshpass -p 1 ssh $SSH_OPTS $MISTER "echo load_core '$MRA' > /dev/MiSTer_cmd"
  fi
  echo "V6PROBE DEPLOYED md5=$LOCAL_MD5 at $(date +%H:%M)"
  exit 0
done
echo "TIMED OUT waiting for MiSTer"
exit 1
