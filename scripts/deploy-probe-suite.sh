#!/usr/bin/env bash
# Active wave verification: runs a probe suite against a revision's tag URL.
# Passive metrics only see what traffic happened to do; probes exercise the
# paths we care about every wave, on every public deploy.
#
#   deploy-probe-suite.sh --base-url URL [--config FILE] [--repeat N]
#                         [--compare OTHER_URL] [--timeout SECS]
#
# Config lines: name|method|path|want_status|body  ('#' comments, blanks ok).
# Exit 0 = all probes passed; 1 = any probe failed (caller rolls back).
# --compare runs the same suite on a second base URL and fails when the two
# return different statuses — a cheap differential check old vs new revision.
set -u

BASE="" CONFIG=""
REPEAT=1 COMPARE="" TIMEOUT=10

while [ $# -gt 0 ]; do
  case "$1" in
    --base-url) BASE=$2 ;;
    --config) CONFIG=$2 ;;
    --repeat) REPEAT=$2 ;;
    --compare) COMPARE=$2 ;;
    --timeout) TIMEOUT=$2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift 2
done
[ -z "$BASE" ] && { echo "need --base-url" >&2; exit 2; }
[ -z "$CONFIG" ] && { echo "need --config (e.g. scripts/probe-suite.api.conf)" >&2; exit 2; }
[ -f "$CONFIG" ] || { echo "config not found: $CONFIG" >&2; exit 2; }

probe() { # probe <base> <method> <path> <body> -> http status
  local m=$2 p=$3 b=$4
  local args=(-s -o /dev/null -w '%{http_code}' --max-time "$TIMEOUT" -X "$m")
  [ -n "$b" ] && args+=(-H 'content-type: application/json' -d "$b")
  curl "${args[@]}" "$1$p" 2>/dev/null || echo 000
}

fail=0 total=0
while IFS='|' read -r name method path want body; do
  case "$name" in ''|\#*) continue ;; esac
  total=$((total+1))
  for _ in $(seq 1 "$REPEAT"); do
    got=$(probe "$BASE" "$method" "$path" "$body")
    if [ "$got" != "$want" ]; then
      echo "  FAIL $name: $method $path -> $got (want $want)"; fail=$((fail+1)); break
    fi
    if [ -n "$COMPARE" ]; then
      other=$(probe "$COMPARE" "$method" "$path" "$body")
      if [ "$other" != "$got" ]; then
        echo "  DIFF $name: $method $path -> $got vs $other on compare target"; fail=$((fail+1)); break
      fi
    fi
  done
done < "$CONFIG"

if [ "$fail" = 0 ]; then
  echo "probe suite passed: $total checks on $BASE"
  exit 0
fi
echo "probe suite FAILED: $fail failure(s) on $BASE"
exit 1
