#!/bin/bash
# Waits for the hyprcompile flow fired at $1 (HH:MM) to produce a fresh RBF,
# gates on STA (ALL clock slacks >= 0 in sta.summary), stages the RBF as
# builds/Hyprduel_v6probe.rbf, then deploys to the MiSTer (menu core first,
# md5 verify both sides, reload MRA).
set -u
PC=leefoot@192.168.1.207
RBF_WIN='C:/hyprduel/mister/output_files/Hyprduel.rbf'
SUM_WIN='C:/hyprduel/mister/output_files/Hyprduel.sta.summary'
DEST=/Users/leefoot/python_scripts/hyperduel-mister/builds/Hyprduel_v6probe.rbf
FIRED_EPOCH=$(date +%s)
SSHPC="ssh -o ConnectTimeout=8 -o BatchMode=yes $PC"

echo "pipeline armed $(date +%H:%M), waiting for RBF newer than fire time"
for i in $(seq 1 40); do
  sleep 90
  MT=$($SSHPC "powershell -NoProfile -c \"(Get-Item '$RBF_WIN').LastWriteTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')\"" 2>/dev/null | tr -d '\r')
  [ -z "$MT" ] && continue
  MT_EPOCH=$(date -ju -f "%Y-%m-%dT%H:%M:%SZ" "$MT" +%s 2>/dev/null) || continue
  if [ "$MT_EPOCH" -gt "$FIRED_EPOCH" ]; then
    echo "RBF fresh: $MT"
    sleep 60  # let STA finish and summary flush
    $SSHPC "cmd /c type C:\\hyprduel\\mister\\output_files\\Hyprduel.sta.summary" | tr -d '\r' > /tmp/sta.summary
    echo "--- sta.summary slack lines ---"
    grep -E "Type|Slack" /tmp/sta.summary | paste - - | sed 's/\s\+/ /g'
    NEG=$(grep -E "^ *Slack" /tmp/sta.summary | awk '{print $3}' | grep -c "^-" || true)
    if [ "$NEG" -ne 0 ]; then
      echo "STA GATE FAILED: $NEG negative slack entries. NOT deploying."
      exit 1
    fi
    echo "STA GATE PASSED (no negative slack)"
    scp -o ConnectTimeout=8 "$PC:$RBF_WIN" "$DEST" || exit 1
    LOCAL_MD5=$(md5 -q "$DEST")
    echo "staged $DEST md5=$LOCAL_MD5"
    # deploy (mDNS first, DHCP-safe)
    SSH_OPTS="-o StrictHostKeyChecking=no -o PubkeyAuthentication=no -o ConnectTimeout=5"
    for j in $(seq 1 240); do
      for h in MiSTer.local 192.168.1.208; do
        if sshpass -p 1 ssh $SSH_OPTS "root@$h" "echo up" >/dev/null 2>&1; then
          M="root@$h"
          sshpass -p 1 ssh $SSH_OPTS $M "echo load_core /media/fat/menu.rbf > /dev/MiSTer_cmd"
          sleep 3
          sshpass -p 1 scp -O $SSH_OPTS "$DEST" $M:/media/fat/_Arcade/cores/Hyprduel.rbf || exit 1
          RMD5=$(sshpass -p 1 ssh $SSH_OPTS $M "md5sum /media/fat/_Arcade/cores/Hyprduel.rbf" | awk '{print $1}')
          if [ "$LOCAL_MD5" != "$RMD5" ]; then echo "MD5 MISMATCH"; exit 1; fi
          MRA=$(sshpass -p 1 ssh $SSH_OPTS $M "ls /media/fat/_Arcade/*.mra | grep -i hyper | head -1")
          [ -n "$MRA" ] && sshpass -p 1 ssh $SSH_OPTS $M "echo load_core '$MRA' > /dev/MiSTer_cmd"
          echo "V6PROBE DEPLOYED AND LOADED $(date +%H:%M) md5=$LOCAL_MD5"
          exit 0
        fi
      done
      sleep 60
    done
    echo "MiSTer never came up; RBF staged at $DEST"
    exit 0
  fi
done
echo "TIMED OUT waiting for compile"
exit 1
