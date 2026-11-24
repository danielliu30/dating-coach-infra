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
#           --service-wide-max-error-rate  service-wide (all revisions) 5xx
#                            percent ceiling — catches a canary degrading
#                            customers it doesn't even serve (default 2)
#           --warmup-seconds   sleep this long before the first collection —
#                            Cloud Logging ingestion lags a fresh revision, so
#                            an immediate read can show zero coverage
#                            spuriously (default 0)
#           --retries          extra collection attempts while coverage is
#                            below the floor — only no-data retries; a fault or
#                            latency breach is evidence and fails at once
#                            (default 0)
#           --retry-delay      seconds between retries     (default 60)
#           --lines-file F     read "status latency_s" lines from F instead of
#                            calling gcloud (offline tests)
#           --service-lines-file F  service-wide fixture for offline tests
#
# Injectable for tests: SLEEP (sleep command; also used for warmup/retry
# waits) and LINES_FILE_CMD (a command that prints fixture lines on each poll
# — a stub can grow coverage between retries).
set -u

PROJECT="" SERVICE="" REVISION="" LOCATION=global
WINDOW_MIN=15 MIN_REQUESTS=20 MAX_ERROR_RATE=1 SLOW_MS=2000 MAX_SLOW_RATE=5
LIMIT=10000 LINES_FILE="" SERVICE_WIDE_MAX_ERROR_RATE=2 SERVICE_LINES_FILE=""
WARMUP_SECONDS=0 RETRIES=0 RETRY_DELAY=60

SLEEP=${SLEEP:-sleep}
LINES_FILE_CMD=${LINES_FILE_CMD:-}

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
    --service-wide-max-error-rate) SERVICE_WIDE_MAX_ERROR_RATE=$2 ;;
    --warmup-seconds) WARMUP_SECONDS=$2 ;;
    --retries) RETRIES=$2 ;;
    --retry-delay) RETRY_DELAY=$2 ;;
    --lines-file) LINES_FILE=$2 ;;
    --service-lines-file) SERVICE_LINES_FILE=$2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift 2
done
[ -z "$LINES_FILE" ] && [ -z "$LINES_FILE_CMD" ] &&
  { [ -z "$PROJECT" ] || [ -z "$SERVICE" ] || [ -z "$REVISION" ]; } && {
  echo "need --project --service --revision (or --lines-file)" >&2; exit 2; }

collect() {
  if [ -n "$LINES_FILE_CMD" ]; then "$LINES_FILE_CMD"; return; fi
  if [ -n "$LINES_FILE" ]; then cat "$LINES_FILE"; return; fi
  gcloud logging read \
    "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"$SERVICE\" AND resource.labels.revision_name=\"$REVISION\" AND httpRequest.status>=0" \
    --project "$PROJECT" --location "$LOCATION" \
    --freshness "${WINDOW_MIN}m" --limit "$LIMIT" \
    --format='value(httpRequest.status,httpRequest.latency)' \
  | awk 'NF==0{next} {s=$1; l=$2; sub(/s$/,"",l); if (l !~ /^[0-9.]+$/) l=0; print s, l}'
}

# All revisions of the service: a bad canary can degrade customers it does
# not even serve (locks, shared resources), so service-wide health gates too.
collect_service() {
  if [ -n "$SERVICE_LINES_FILE" ]; then cat "$SERVICE_LINES_FILE"; return; fi
  # Fixture mode without a service fixture: nothing to check, skip.
  { [ -n "$LINES_FILE" ] || [ -n "$LINES_FILE_CMD" ]; } && return
  gcloud logging read \
    "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"$SERVICE\" AND httpRequest.status>=0" \
    --project "$PROJECT" --location "$LOCATION" \
    --freshness "${WINDOW_MIN}m" --limit "$LIMIT" \
    --format='value(httpRequest.status)' \
  | awk 'NF==0{next} {print $1, 0}'
}

slow_s=$(awk "BEGIN{print $SLOW_MS/1000}")

# Cloud Logging ingestion lags a fresh revision: give entries time to land
# before the first read so a healthy wave isn't refused on stale emptiness.
if [ "$WARMUP_SECONDS" -gt 0 ]; then
  echo "warming up ${WARMUP_SECONDS}s for log ingestion before reading"
  "$SLEEP" "$WARMUP_SECONDS"
fi

# Poll until coverage meets the floor or retries run out. Only no-data
# retries — a fault or latency breach is evidence and fails immediately below.
attempt=0
while :; do
  read -r total faults slow <<<"$(collect | awk -v lat="$slow_s" '
    { n++; if ($1+0 >= 500) e++; if ($2+0 >= lat) s++ }
    END { print n+0, e+0, s+0 }')"
  total=${total:-0} faults=${faults:-0} slow=${slow:-0}
  echo "bake stats: revision=$REVISION window=${WINDOW_MIN}m requests=$total 5xx=$faults slow(>=${SLOW_MS}ms)=$slow"
  [ "$total" -ge "$MIN_REQUESTS" ] && break
  [ "$attempt" -ge "$RETRIES" ] && break
  attempt=$((attempt+1))
  echo "coverage still below floor — waiting ${RETRY_DELAY}s for late log" \
    "ingestion (retry $attempt/$RETRIES)"
  "$SLEEP" "$RETRY_DELAY"
done

pct() { awk "BEGIN{print ($2 == 0) ? 0 : $1*100/$2}"; }

if [ "$total" -lt "$MIN_REQUESTS" ]; then
  echo "INSUFFICIENT COVERAGE: $total requests < $MIN_REQUESTS minimum after" \
    "$((attempt+1)) poll(s) — the wave saw"
  echo "too little traffic to prove health. Extend the bake window or send synthetic"
  echo "traffic, then re-run; do not promote on no data."
  exit 1
fi
err_rate=$(pct "$faults" "$total")
if awk "BEGIN{exit !($err_rate > $MAX_ERROR_RATE)}"; then
  echo "FAULTS: 5xx rate ${err_rate}% > ${MAX_ERROR_RATE}% ceiling"
  exit 1
fi

read -r svc_total svc_faults _ <<EOF
$(collect_service | awk '{ n++; if ($1+0 >= 500) e++ } END { print n+0, e+0, 0 }')
EOF
svc_total=${svc_total:-0} svc_faults=${svc_faults:-0}
if [ "$svc_total" -ge "$MIN_REQUESTS" ]; then
  svc_rate=$(pct "$svc_faults" "$svc_total")
  if awk "BEGIN{exit !($svc_rate > $SERVICE_WIDE_MAX_ERROR_RATE)}"; then
    echo "SERVICE-WIDE FAULTS: ${svc_rate}% 5xx across all revisions ($svc_faults/$svc_total)"
    echo "> ${SERVICE_WIDE_MAX_ERROR_RATE}% ceiling — the wave is hurting traffic beyond the canary"
    exit 1
  fi
  echo "service-wide 5xx ${svc_rate}% ($svc_faults/$svc_total) within ceiling"
else
  echo "service-wide check skipped: only $svc_total requests total"
fi
slow_rate=$(pct "$slow" "$total")
if awk "BEGIN{exit !($slow_rate > $MAX_SLOW_RATE)}"; then
  echo "LATENCY: ${slow_rate}% of requests slower than ${SLOW_MS}ms > ${MAX_SLOW_RATE}% ceiling"
  exit 1
fi

echo "bake passed: coverage ok, 5xx ${err_rate}%, slow ${slow_rate}%"
exit 0
