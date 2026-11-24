#!/usr/bin/env bash
# Deploy-drift reconciler (app repo issue #9): a lost repository_dispatch
# silently skips a deploy, leaving Cloud Run running an older app SHA than the
# app repo's main tip. This script describes each service, extracts the
# deployed image tag and compares it to that tip.
#
#   PROJECT=p REGION=r ./scripts/reconcile-drift.sh
#
# Statuses per service:
#   IN-SYNC  deployed tag == app main tip
#   PENDING  service not deployed yet (never drift)
#   GRACE    tag differs but the tip commit is younger than GRACE_MINUTES —
#            the dispatch is probably still in flight
#   DRIFTED  tag differs and the tip is older than GRACE_MINUTES, or the tip's
#            commit time cannot be established (fail closed)
#
# Exit 0 when everything is IN-SYNC / PENDING / GRACE; 1 on any DRIFTED.
# Fails closed: an unresolvable tip or unfetchable commit => drift.
#
# Env: PROJECT (required), REGION (required), APP_REPO
# (default danielliu30/dating-coach), SERVICES (default the four Cloud Run
# services), GRACE_MINUTES (default 60). GCLOUD/GIT injectable for tests.
set -u

GCLOUD=${GCLOUD:-gcloud}
GIT=${GIT:-git}
APP_REPO=${APP_REPO:-danielliu30/dating-coach}
GRACE_MINUTES=${GRACE_MINUTES:-60}
SERVICES=${SERVICES:-"dating-coach-api dating-coach-web dating-coach-ml dating-coach-worker"}

missing=0
for v in PROJECT REGION; do
  [ -z "${!v:-}" ] && { echo "missing env: $v" >&2; missing=1; }
done
[ "$missing" = 1 ] && exit 2

# --- app main tip -----------------------------------------------------------
tip=$("$GIT" ls-remote "https://github.com/$APP_REPO" main | cut -f1)
if [ -z "$tip" ]; then
  echo "could not resolve https://github.com/$APP_REPO main tip — failing closed" >&2
  exit 1
fi

# Tip commit time needs a real object: fetch the sha into a scratch repo and
# read %ct. An unfetchable sha leaves tip_epoch empty -> any mismatch fails
# closed as DRIFTED.
tip_epoch=""
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
if "$GIT" -C "$work" init -q 2>/dev/null \
  && "$GIT" -C "$work" fetch -q --depth=1 "https://github.com/$APP_REPO" "$tip" 2>/dev/null; then
  tip_epoch=$("$GIT" -C "$work" show -s --format=%ct "$tip" 2>/dev/null || true)
fi
[ -z "$tip_epoch" ] && echo "WARNING: tip commit $tip not fetchable; any mismatch will count as drift" >&2

now=$(date +%s)
grace_sec=$((GRACE_MINUTES * 60))
[ -n "$tip_epoch" ] && tip_age_min=$(( (now - tip_epoch) / 60 )) || tip_age_min="?"

echo "app main tip: $tip (age: ${tip_age_min}m, grace: ${GRACE_MINUTES}m)"
printf '%-22s %-42s %-42s %s\n' SERVICE DEPLOYED EXPECTED STATUS

drift=0
for svc in $SERVICES; do
  image=$("$GCLOUD" run services describe "$svc" --project "$PROJECT" --region "$REGION" \
    --format='value(spec.template.spec.containers[0].image)' 2>/dev/null)
  if [ -z "$image" ]; then
    printf '%-22s %-42s %-42s %s\n' "$svc" "-" "$tip" "PENDING"
    continue
  fi
  deployed=${image##*:}
  if [ "$deployed" = "$tip" ]; then
    status="IN-SYNC"
  elif [ -z "$tip_epoch" ]; then
    status="DRIFTED"          # tip age unresolvable => fail closed
  elif [ $((now - tip_epoch)) -gt "$grace_sec" ]; then
    status="DRIFTED"
  else
    status="GRACE"
  fi
  [ "$status" = "DRIFTED" ] && drift=1
  printf '%-22s %-42s %-42s %s\n' "$svc" "$deployed" "$tip" "$status"
done

exit "$drift"
