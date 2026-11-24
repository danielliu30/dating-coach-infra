#!/usr/bin/env bash
# Offline test harness for release-window.sh: drives it with a fixed
# DEPLOY_WINDOW_NOW_EPOCH instead of the clock. Run:
#   bash scripts/test-release-window.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
GATE="$ROOT/scripts/release-window.sh"

pass=0; fail=0
t() { # t <name> <want-exit> <cmd...>
  local name=$1 want=$2; shift 2
  "$@" >/dev/null 2>&1; local got=$?
  if [ "$want" = "$got" ]; then pass=$((pass+1)); printf 'ok    %s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL  %s (want %s, got %s)\n' "$name" "$want" "$got"; fi
}
W() { env DEPLOY_WINDOW_NOW_EPOCH="$1" "${@:2}" bash "$GATE"; }
# usage: W <epoch> [VAR=val ...] — DEPLOY_WINDOW_NOW_EPOCH always first

# Fixed clock: 2024-06-17 was a Monday (%w=1), 2024-06-15 Sat, 2024-06-16 Sun.
MON_1400=$(date -u -d '2024-06-17 14:00:00' +%s)
MON_0200=$(date -u -d '2024-06-17 02:00:00' +%s)
MON_2100=$(date -u -d '2024-06-17 21:00:00' +%s)
SAT_1400=$(date -u -d '2024-06-15 14:00:00' +%s)
SUN_2300=$(date -u -d '2024-06-16 23:00:00' +%s)

t 'unset window open'            0 W "$SAT_1400"

# hour windows; end hour is exclusive
t 'inside hour window'           0 W "$MON_1400" DEPLOY_WINDOW_START_UTC=14 DEPLOY_WINDOW_END_UTC=21
t 'before hour window refused'   1 W "$MON_0200" DEPLOY_WINDOW_START_UTC=14 DEPLOY_WINDOW_END_UTC=21
t 'end hour exclusive'           1 W "$MON_2100" DEPLOY_WINDOW_START_UTC=14 DEPLOY_WINDOW_END_UTC=21
t 'equal bounds open'            0 W "$MON_0200" DEPLOY_WINDOW_START_UTC=9 DEPLOY_WINDOW_END_UTC=9

# wrap-around window 22-06
t 'wrap window inside'           0 W "$SUN_2300" DEPLOY_WINDOW_START_UTC=22 DEPLOY_WINDOW_END_UTC=6
t 'wrap window refused'          1 W "$MON_1400" DEPLOY_WINDOW_START_UTC=22 DEPLOY_WINDOW_END_UTC=6

# day lists and ranges (%w: 0=Sun, 1=Mon)
t 'weekday range inside'         0 W "$MON_1400" DEPLOY_WINDOW_DAYS=1-4
t 'saturday refused'             1 W "$SAT_1400" DEPLOY_WINDOW_DAYS=1-4
t 'sunday list inside'           0 W "$SUN_2300" DEPLOY_WINDOW_DAYS=0,6
t 'wrap day range inside'        0 W "$SUN_2300" DEPLOY_WINDOW_DAYS=5-1
t 'monday outside 2-4 refused'   1 W "$MON_1400" DEPLOY_WINDOW_DAYS=2-4

# day + hour combine
t 'day+hour inside'              0 W "$SAT_1400" DEPLOY_WINDOW_DAYS=6 DEPLOY_WINDOW_START_UTC=9 DEPLOY_WINDOW_END_UTC=17
t 'day ok hour refused'          1 W "$SAT_1400" DEPLOY_WINDOW_DAYS=6 DEPLOY_WINDOW_START_UTC=16 DEPLOY_WINDOW_END_UTC=20

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
