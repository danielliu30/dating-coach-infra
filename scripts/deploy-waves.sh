#!/usr/bin/env bash
# Wave-staircase promoter for Cloud Run services. Walks a fixed "percent:bake"
# plan — traffic only ever moves forward — and after each bake runs the bake
# gate (deploy-bake-check.sh). A failed gate reverts traffic to the revisions
# serving before the deploy and exits 1; a passed 100 wave is the only path
# to full traffic.
#
#   deploy-waves.sh --project P --region R --service S \
#                   --new-revision REV --prev-revision OLD \
#                   [--prev-split "OLD=90,OTHER=10"]  # rollback target; default OLD=100
#                   [--plan "10:15 25:30 50:45 100:0"] # percent:bake-minutes pairs
#                   [--min-requests N] [--max-error-rate PCT]
#                   [--slow-threshold-ms MS] [--max-slow-rate PCT]
#                   [--tag-url URL --probe-config FILE]
#
# With --tag-url, every wave also runs deploy-probe-suite.sh against the
# candidate revision's tag URL before and after the bake — active
# verification on top of the passive traffic metrics.
#
# Injectable for tests: GCLOUD, SLEEP, BAKE_CHECK, PROBE_SUITE, LOG_LOCATION.
set -u

PROJECT="" REGION="" SERVICE="" NEW_REV="" PREV_REV="" PREV_SPLIT=""
PLAN="10:15 25:30 50:45 100:0"
MIN_REQUESTS=20 MAX_ERROR_RATE=1 SLOW_MS=2000 MAX_SLOW_RATE=5
TAG_URL="" PROBE_CONFIG=""

GCLOUD=${GCLOUD:-gcloud}
SLEEP=${SLEEP:-sleep}
BAKE_CHECK=${BAKE_CHECK:-"$(cd "$(dirname "$0")" && pwd)/deploy-bake-check.sh"}
PROBE_SUITE=${PROBE_SUITE:-"$(cd "$(dirname "$0")" && pwd)/deploy-probe-suite.sh"}
LOG_LOCATION=${LOG_LOCATION:-global}

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT=$2 ;;
    --region) REGION=$2 ;;
    --service) SERVICE=$2 ;;
    --new-revision) NEW_REV=$2 ;;
    --prev-revision) PREV_REV=$2 ;;
    --prev-split) PREV_SPLIT=$2 ;;
    --plan) PLAN=$2 ;;
    --min-requests) MIN_REQUESTS=$2 ;;
    --max-error-rate) MAX_ERROR_RATE=$2 ;;
    --slow-threshold-ms) SLOW_MS=$2 ;;
    --max-slow-rate) MAX_SLOW_RATE=$2 ;;
    --tag-url) TAG_URL=$2 ;;
    --probe-config) PROBE_CONFIG=$2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift 2
done
for v in PROJECT REGION SERVICE NEW_REV PREV_REV; do
  [ -z "${!v}" ] && { echo "missing --${v,,}" | tr '_' '-' >&2; exit 2; }
done
[ -z "$PREV_SPLIT" ] && PREV_SPLIT="$PREV_REV=100"

rollback() {
  echo "rolling $SERVICE back to previous traffic split: $PREV_SPLIT" >&2
  "$GCLOUD" run services update-traffic "$SERVICE" \
    --project "$PROJECT" --region "$REGION" --to-revisions "$PREV_SPLIT"
  exit 1
}

for step in $PLAN; do
  pct=${step%%:*}; bake=${step#*:}
  if [ "$pct" -ge 100 ]; then
    echo "== wave 100%: sending all traffic to $NEW_REV"
    "$GCLOUD" run services update-traffic "$SERVICE" \
      --project "$PROJECT" --region "$REGION" --to-latest || rollback
  else
    echo "== wave ${pct}%: $NEW_REV / $PREV_REV split"
    "$GCLOUD" run services update-traffic "$SERVICE" \
      --project "$PROJECT" --region "$REGION" \
      --to-revisions "$NEW_REV=$pct,$PREV_REV=$((100-pct))" || rollback
  fi

  # Active verification: probes hit the candidate's tag URL directly, so a
  # semantically broken canary fails fast instead of baking quietly. They
  # also land in the revision's request logs — synthetic coverage.
  if [ -n "$TAG_URL" ]; then
    "$PROBE_SUITE" --base-url "$TAG_URL" --config "$PROBE_CONFIG" || {
      echo "   wave ${pct}% probe suite FAILED"
      rollback
    }
  fi

  [ "$bake" -gt 0 ] || continue
  echo "   baking ${bake}m"
  "$SLEEP" "$((bake*60))"

  if [ -n "$TAG_URL" ]; then
    "$PROBE_SUITE" --base-url "$TAG_URL" --config "$PROBE_CONFIG" || {
      echo "   wave ${pct}% post-bake probe suite FAILED"
      rollback
    }
  fi
  if "$BAKE_CHECK" --project "$PROJECT" --location "$LOG_LOCATION" \
        --service "$SERVICE" --revision "$NEW_REV" \
        --window-minutes "$bake" --min-requests "$MIN_REQUESTS" \
        --max-error-rate "$MAX_ERROR_RATE" \
        --slow-threshold-ms "$SLOW_MS" --max-slow-rate "$MAX_SLOW_RATE"; then
    echo "   wave ${pct}% bake passed"
  else
    echo "   wave ${pct}% bake FAILED"
    rollback
  fi
done

echo "rollout complete: $SERVICE on $NEW_REV"
