#!/bin/bash
# v14: sync changed sources to the compile PC, fire hyprcompile, wait
# for a fresh RBF, STA-gate, stage as builds/Hyprduel_rc2.rbf.
# STAGE ONLY - deploy is gated on the SDRAM soak verdict.
set -u
PC=leefoot@192.168.1.207
RBF_WIN='C:/hyprduel/mister/output_files/Hyprduel.rbf'
REPO=/Users/leefoot/python_scripts/hyperduel-mister
DEST=$REPO/builds/Hyprduel_rc2.rbf
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
    $SSHPC "cmd /c type C:\\hyprduel\\mister\\output_files\\Hyprduel.sta.summary" | tr -d '\r' > /tmp/sta_rc2.summary
    grep -E "Type|Slack" /tmp/sta_rc2.summary | paste - - | head -4
    NEG=$(grep -E "^ *Slack" /tmp/sta_rc2.summary | awk '{print $3}' | grep -c "^-" || true)
    if [ "$NEG" -ne 0 ]; then
      echo "STA GATE FAILED: $NEG negative slack entries. NOT deploying."
      exit 1
    fi
    echo "STA GATE PASSED"
    scp -o ConnectTimeout=8 "$PC:$RBF_WIN" "$DEST" || exit 1
    echo "STAGED $DEST md5=$(md5 -q "$DEST") - deploy gated on SDRAM soak"
    exit 0
  fi
done
echo "TIMED OUT waiting for compile"
exit 1
