#!/usr/bin/env bash
# Bake gate for wave deploys. Evaluates the traffic a canary revision actually
# saw during its bake window and exits 0 (promote) or 1 (hold/roll back).
#
# Signals (all three must pass):
#   coverage : requests served by the revision >= MIN_REQUESTS. A wave that saw
#              no traffic proves nothing — refuse to promote on "no data".
#   faults   : 5xx share of requests <= MAX_ERROR_RATE_PCT.
#   latency  : share of requests slower than SLOW_THRESHOLD_MS <= MAX_SLOW_RATE_PCT.
#
# Required: --project --service --revision
# Optional: --location (default global, Cloud Run logs are global)
#           --window-minutes   log freshness window        (default 15)
#           --min-requests     coverage floor              (default 20)
#           --max-error-rate   5xx percent ceiling         (default 1)
#           --slow-threshold-ms  latency ceiling per req   (default 2000)
#           --max-slow-rate    slow-request percent ceiling(default 5)
#           --limit            max log entries to pull     (default 10000)
#           --lines-file F     read "status latency_s" lines from F instead of
#                            calling gcloud (offline tests)
set -u

PROJECT="" SERVICE="" REVISION="" LOCATION=global
WINDOW_MIN=15 MIN_REQUESTS=20 MAX_ERROR_RATE=1 SLOW_MS=2000 MAX_SLOW_RATE=5
LIMIT=10000 LINES_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT=$2 ;;
    --service) SERVICE=$2 ;;
    --revision) REVISION=$2 ;;
    --location) LOCATION=$2 ;;
    --window-minutes) WINDOW_MIN=$2 ;;
    --min-requests) MIN_REQUESTS=$2 ;;
    --max-error-rate) MAX_ERROR_RATE=$2 ;;
    --slow-threshold-ms) SLOW_MS=$2 ;;
    --max-slow-rate) MAX_SLOW_RATE=$2 ;;
    --limit) LIMIT=$2 ;;
    --lines-file) LINES_FILE=$2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift 2
done
[ -z "$LINES_FILE" ] && { [ -z "$PROJECT" ] || [ -z "$SERVICE" ] || [ -z "$REVISION" ]; } && {
  echo "need --project --service --revision (or --lines-file)" >&2; exit 2; }

collect() {
  if [ -n "$LINES_FILE" ]; then cat "$LINES_FILE"; return; fi
  gcloud logging read \
    "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"$SERVICE\" AND resource.labels.revision_name=\"$REVISION\" AND httpRequest.status>=0" \
    --project "$PROJECT" --location "$LOCATION" \
    --freshness "${WINDOW_MIN}m" --limit "$LIMIT" \
    --format='value(httpRequest.status,httpRequest.latency)' \
  | awk 'NF==0{next} {s=$1; l=$2; sub(/s$/,"",l); if (l !~ /^[0-9.]+$/) l=0; print s, l}'
}

slow_s=$(awk "BEGIN{print $SLOW_MS/1000}")
read -r total faults slow <<EOF
$(collect | awk -v lat="$slow_s" '
    { n++; if ($1+0 >= 500) e++; if ($2+0 >= lat) s++ }
    END { print n+0, e+0, s+0 }')
EOF
total=${total:-0} faults=${faults:-0} slow=${slow:-0}

echo "bake stats: revision=$REVISION window=${WINDOW_MIN}m requests=$total 5xx=$faults slow(>=${SLOW_MS}ms)=$slow"

pct() { awk "BEGIN{print ($2 == 0) ? 0 : $1*100/$2}"; }

if [ "$total" -lt "$MIN_REQUESTS" ]; then
  echo "INSUFFICIENT COVERAGE: $total requests < $MIN_REQUESTS minimum — the wave saw"
  echo "too little traffic to prove health. Extend the bake window or send synthetic"
  echo "traffic, then re-run; do not promote on no data."
  exit 1
fi
err_rate=$(pct "$faults" "$total")
if awk "BEGIN{exit !($err_rate > $MAX_ERROR_RATE)}"; then
  echo "FAULTS: 5xx rate ${err_rate}% > ${MAX_ERROR_RATE}% ceiling"
  exit 1
fi
slow_rate=$(pct "$slow" "$total")
if awk "BEGIN{exit !($slow_rate > $MAX_SLOW_RATE)}"; then
  echo "LATENCY: ${slow_rate}% of requests slower than ${SLOW_MS}ms > ${MAX_SLOW_RATE}% ceiling"
  exit 1
fi

echo "bake passed: coverage ok, 5xx ${err_rate}%, slow ${slow_rate}%"
exit 0
