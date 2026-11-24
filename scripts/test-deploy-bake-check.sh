#!/usr/bin/env bash
# Offline test harness for deploy-bake-check.sh: feeds "status latency"
# fixture lines through --lines-file instead of calling gcloud. Run:
#   bash scripts/test-deploy-bake-check.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CHK="$ROOT/scripts/deploy-bake-check.sh"
FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT

pass=0; fail=0
t() { # t <name> <want-exit> <cmd...>
  local name=$1 want=$2; shift 2
  "$@" >/dev/null 2>&1; local got=$?
  if [ "$want" = "$got" ]; then pass=$((pass+1)); printf 'ok    %s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL  %s (want %s, got %s)\n' "$name" "$want" "$got"; fi
}
lines() { # lines <file> <status> <latency_s> <count>
  local f=$FIX/$1; : >"$f"
  for _ in $(seq 1 "$4"); do echo "$2 $3" >>"$f"; done
  echo "$f"
}
mix() { # mix <file> <spec...> where spec = status:latency:count
  local f=$FIX/$1; : >"$f"; shift
  for spec in "$@"; do
    IFS=: read -r st lat n <<<"$spec"
    for _ in $(seq 1 "$n"); do echo "$st $lat" >>"$f"; done
  done
  echo "$f"
}
C() { bash "$CHK" --lines-file "$1" "${@:2}"; }

# coverage floor
t 'zero traffic refused'         1 C "$(lines empty.log 200 0.05 0)"
t 'below floor refused'          1 C "$(lines few.log 200 0.05 5)" --min-requests 20
t 'at floor passes'              0 C "$(lines ok.log 200 0.05 20)" --min-requests 20

# 5xx rate: 1 in 100 = 1%, ceiling 1% passes (not >); 2 in 100 = 2% fails
t '1 pct 5xx passes'             0 C "$(mix m1.log 200:0.05:99 500:0.05:1)" --min-requests 20 --max-error-rate 1
t '2 pct 5xx refused'            1 C "$(mix m2.log 200:0.05:98 500:0.05:2)" --min-requests 20 --max-error-rate 1
t '4xx not faults'               0 C "$(mix m3.log 200:0.05:60 404:0.05:40)" --min-requests 20 --max-error-rate 1

# slow-request ratio: threshold 2000ms = 2s; 3/100 slow vs 5% ceiling passes, 6% fails
t '3 pct slow passes'            0 C "$(mix s1.log 200:0.10:97 200:3.0:3)" --min-requests 20 --max-slow-rate 5
t '6 pct slow refused'           1 C "$(mix s2.log 200:0.10:94 200:3.0:6)" --min-requests 20 --max-slow-rate 5
t 'under threshold not slow'     0 C "$(lines fast.log 200 1.999 30)" --min-requests 20 --slow-threshold-ms 2000 --max-slow-rate 1

# missing/garbage latency tolerated
printf '200\n200 abc\n200 None\n' >"$FIX/bad.log"
for _ in $(seq 1 18); do echo '200 0.05' >>"$FIX/bad.log"; done
t 'bad latency lines tolerated'  0 C "$FIX/bad.log" --min-requests 20

# service-wide regression gate (--service-lines-file fixtures all revisions)
REV_OK=$(lines rev.log 200 0.05 25)
SVC_BAD=$(mix svc1.log 200:0.05:97 500:0.05:3)   # 3% > 2% ceiling
SVC_OK=$(lines svc2.log 200 0.05 60)
SVC_QUIET=$(lines svc3.log 200 0.05 5)
t 'service-wide 5xx refused'     1 bash "$CHK" --lines-file "$REV_OK" --service-lines-file "$SVC_BAD" --min-requests 20
t 'service-wide ok passes'       0 bash "$CHK" --lines-file "$REV_OK" --service-lines-file "$SVC_OK" --min-requests 20
t 'service-wide quiet skipped'   0 bash "$CHK" --lines-file "$REV_OK" --service-lines-file "$SVC_QUIET" --min-requests 20
t 'fixture w/o svc skips check'  0 C "$REV_OK" --min-requests 20

# args required without --lines-file
t 'no args errors'               2 bash "$CHK"

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
