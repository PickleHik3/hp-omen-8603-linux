#!/usr/bin/env bash
S="$(cd "$(dirname "$0")" && pwd)"; cd "$S"
LT(){ powershell.exe -NoProfile -ExecutionPolicy Bypass -File loadtest.ps1 "$@"; }
KILL(){ powershell.exe -NoProfile -ExecutionPolicy Bypass -File e3wait.ps1 -MaxSec 1 >/dev/null 2>&1; }
last40(){ grep '# AVG' "$1" | sed -E 's/.*last40s: ([0-9.]+).*/\1/'; }
holds(){ awk -v w="$(last40 "$1")" 'BEGIN{exit !(w>=60)}'; }
until grep -q CHAIN-DONE e3.log; do sleep 5; done
echo "=== SERIES start $(date +%T) ==="
sleep 45
KILL; echo "--- Run A: fresh 0x1A + 0x23/30s + 0x10/60s ---"; LT -Label runA -Seconds 200 -Interval 5 -SetPerfFirst -HbEvery 30 -OccnEvery 60 > runA.log 2>&1; echo "A last40s=$(last40 runA.log) W"
sleep 60
if holds runA.log; then
  KILL; echo "--- Run B: fresh 0x1A + 0x10/60s (no 0x23) ---"; LT -Label runB -Seconds 200 -Interval 5 -SetPerfFirst -OccnEvery 60 > runB.log 2>&1; echo "B last40s=$(last40 runB.log) W"
  sleep 60
  if holds runB.log; then
    KILL; echo "--- Run E: fresh 0x1A only, nothing periodic ---"; LT -Label runE -Seconds 200 -Interval 5 -SetPerfFirst > runE.log 2>&1; echo "E last40s=$(last40 runE.log) W"
  else
    KILL; echo "--- Run C: fresh 0x1A + 0x23/30s (no 0x10) ---"; LT -Label runC -Seconds 200 -Interval 5 -SetPerfFirst -HbEvery 30 > runC.log 2>&1; echo "C last40s=$(last40 runC.log) W"
  fi
else
  KILL; echo "--- Run D: 0x1A every 60s + 0x23/30s + 0x10/60s ---"; LT -Label runD -Seconds 200 -Interval 5 -SetPerfFirst -ModeEvery 60 -HbEvery 30 -OccnEvery 60 > runD.log 2>&1; echo "D last40s=$(last40 runD.log) W"
fi
sleep 60
echo "--- E4: balanced via WMI, then direct EC write OCCM=1 at 70s ---"; powershell.exe -NoProfile -ExecutionPolicy Bypass -File e4.ps1 -Seconds 180 -Interval 5 -SwitchAt 70 > e4.log 2>&1; tail -n 30 e4.log | cut -c1-80
echo "=== SERIES done $(date +%T) ==="
