#!/bin/bash
# v13probe: sync changed sources to the compile PC, fire hyprcompile, wait
# for a fresh RBF, STA-gate, stage as builds/Hyprduel_v13probe.rbf, deploy
# to the MiSTer, then run the screenshot burst (prefix v13probe_).
set -u
PC=leefoot@192.168.1.207
RBF_WIN='C:/hyprduel/mister/output_files/Hyprduel.rbf'
REPO=/Users/leefoot/python_scripts/hyperduel-mister
DEST=$REPO/builds/Hyprduel_v13probe.rbf
SSHPC="ssh -o ConnectTimeout=8 -o BatchMode=yes $PC"

# 1. sync the two changed sources
scp -o ConnectTimeout=8 "$REPO/rtl/i4220_vdp.sv" "$PC:C:/hyprduel/rtl/i4220_vdp.sv" || exit 1
scp -o ConnectTimeout=8 "$REPO/mister/Hyprduel.sv" "$PC:C:/hyprduel/mister/Hyprduel.sv" || exit 1
echo "sources synced $(date +%H:%M)"

# 2. fire the compile
FIRED_EPOCH=$(date +%s)
$SSHPC "schtasks /run /tn hyprcompile" || exit 1
echo "hyprcompile fired $(date +%H:%M)"

# 3. wait for fresh RBF + STA gate
for i in $(seq 1 40); do
  sleep 90
  MT=$($SSHPC "powershell -NoProfile -c \"(Get-Item '$RBF_WIN').LastWriteTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')\"" 2>/dev/null | tr -d '\r')
  [ -z "$MT" ] && continue
  MT_EPOCH=$(date -ju -f "%Y-%m-%dT%H:%M:%SZ" "$MT" +%s 2>/dev/null) || continue
  if [ "$MT_EPOCH" -gt "$FIRED_EPOCH" ]; then
    echo "RBF fresh: $MT"
    sleep 60  # let STA finish and summary flush
    $SSHPC "cmd /c type C:\\hyprduel\\mister\\output_files\\Hyprduel.sta.summary" | tr -d '\r' > /tmp/sta_v13probe.summary
    grep -E "Type|Slack" /tmp/sta_v13probe.summary | paste - - | head -4
    NEG=$(grep -E "^ *Slack" /tmp/sta_v13probe.summary | awk '{print $3}' | grep -c "^-" || true)
    if [ "$NEG" -ne 0 ]; then
      echo "STA GATE FAILED: $NEG negative slack entries. NOT deploying."
      exit 1
    fi
    echo "STA GATE PASSED"
    scp -o ConnectTimeout=8 "$PC:$RBF_WIN" "$DEST" || exit 1
    LOCAL_MD5=$(md5 -q "$DEST")
    echo "staged $DEST md5=$LOCAL_MD5"
    # 4. deploy when the MiSTer is up (DHCP-safe: mDNS first)
    SSH_OPTS="-o StrictHostKeyChecking=no -o PubkeyAuthentication=no -o ConnectTimeout=5"
    for j in $(seq 1 480); do
      for h in MiSTer.local 192.168.1.208; do
        if sshpass -p 1 ssh $SSH_OPTS "root@$h" "echo up" >/dev/null 2>&1; then
          M="root@$h"
          sshpass -p 1 ssh $SSH_OPTS $M "echo load_core /media/fat/menu.rbf > /dev/MiSTer_cmd"
          sleep 3
          sshpass -p 1 scp -O $SSH_OPTS "$DEST" $M:/media/fat/_Arcade/cores/Hyprduel.rbf || exit 1
          RMD5=$(sshpass -p 1 ssh $SSH_OPTS $M "md5sum /media/fat/_Arcade/cores/Hyprduel.rbf" | awk '{print $1}')
          if [ "$LOCAL_MD5" != "$RMD5" ]; then echo "MD5 MISMATCH"; exit 1; fi
          echo "V13PROBE DEPLOYED $(date +%H:%M) md5=$LOCAL_MD5"
          # 5. burst (loads the MRA itself, prefix v13probe_)
          bash "$REPO/tools/hw_screenshot_burst.sh" v13probe_
          exit $?
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
