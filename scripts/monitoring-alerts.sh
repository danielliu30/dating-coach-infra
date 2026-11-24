#!/usr/bin/env bash
# Idempotent Cloud Monitoring alerting for the Cloud Run deployment.
# Creates/reuses one email notification channel and upserts alert policies by
# display name, so it is safe to re-run between deploys (gcp-bootstrap style).
#
#   PROJECT_ID=my-project ALERT_EMAIL=oncall@example.com ./scripts/monitoring-alerts.sh
#
# What it ensures:
#   - email notification channel (reused when a channel with the same display
#     name already exists)
#   - 5xx request-count ratio on the public services (api + web)
#   - p95 request latency on dating-coach-api
#   - failed executions of the dating-coach-migrate job
#   - oldest unacked message age on each <topic>.worker-push subscription
#   - undelivered messages on each <topic>.dlq-hold subscription
#
# Env knobs:
#   ALERT_EMAIL             (required) channel target address
#   ALERT_CHANNEL_NAME      channel display name (default dating-coach-alerts)
#   ALERT_ERROR_RATE_PCT    5xx ratio percent on api+web (default 1)
#   ALERT_P95_MS            p95 latency ms on api (default 2000)
#   ALERT_UNACKED_AGE_S     oldest unacked message age, seconds (default 600)
#   ALERT_DLQ_MESSAGES      message count on *.dlq-hold that fires (default 0 = any)
set -euo pipefail

usage() {
  cat >&2 <<USAGE
usage: PROJECT_ID=<project> ALERT_EMAIL=<address> $0

Ensures Cloud Monitoring alerting exists between deploys (idempotent).
Required env: PROJECT_ID, ALERT_EMAIL.
Optional: ALERT_CHANNEL_NAME ALERT_ERROR_RATE_PCT ALERT_P95_MS
          ALERT_UNACKED_AGE_S ALERT_DLQ_MESSAGES
USAGE
  exit 2
}

[ -n "${PROJECT_ID:-}" ] || usage
[ -n "${ALERT_EMAIL:-}" ] || usage

CHANNEL_DISPLAY="${ALERT_CHANNEL_NAME:-dating-coach-alerts}"
ERROR_RATE_PCT="${ALERT_ERROR_RATE_PCT:-1}"
P95_MS="${ALERT_P95_MS:-2000}"
UNACKED_AGE_S="${ALERT_UNACKED_AGE_S:-600}"
DLQ_MESSAGES="${ALERT_DLQ_MESSAGES:-0}"

numeric() { case "$1" in ''|*[!0-9.]*) return 1;; *) return 0;; esac; }
for v in "$ERROR_RATE_PCT" "$P95_MS" "$UNACKED_AGE_S" "$DLQ_MESSAGES"; do
  numeric "$v" || { echo "ALERT_* thresholds must be numeric (got '$v')" >&2; exit 2; }
done

ANALYSIS_TOPIC="${ANALYSIS_TOPIC:-conversation.analysis}"
DELETION_TOPIC="${DELETION_TOPIC:-account.deletion}"
EMAIL_TOPIC="${EMAIL_TOPIC:-email.outbox}"
PUBLIC_SERVICES="dating-coach-api dating-coach-web"
TOPICS="$ANALYSIS_TOPIC $DELETION_TOPIC $EMAIL_TOPIC"

g() { gcloud --project "$PROJECT_ID" --quiet "$@"; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "== enabling APIs"
g services enable monitoring.googleapis.com

echo "== notification channel ($CHANNEL_DISPLAY -> $ALERT_EMAIL)"
if g alpha monitoring channels list --format='value(displayName)' | grep -qxF "$CHANNEL_DISPLAY"; then
  channel=$(g alpha monitoring channels list --format='value(name)' \
    --filter="displayName=\"$CHANNEL_DISPLAY\"" | head -1)
  echo "reusing channel $channel"
else
  channel=$(g alpha monitoring channels create --type email \
    --display-name "$CHANNEL_DISPLAY" \
    --channel-labels "email_address=$ALERT_EMAIL" \
    --format='value(name)')
  echo "created channel $channel"
fi

# Upsert an alert policy keyed on its display name.
upsert_policy() { # <display-name> <policy-file>
  local display="$1" file="$2" pname
  if printf '%s\n' "$existing_policies" | grep -qxF "$display"; then
    pname=$(g alpha monitoring policies list --format='value(name)' \
      --filter="displayName=\"$display\"" | head -1)
    g alpha monitoring policies update "$pname" --policy-from-file="$file" >/dev/null
    echo "updated policy: $display"
  else
    g alpha monitoring policies create --policy-from-file="$file" >/dev/null
    echo "created policy: $display"
  fi
}

# 5xx / total request ratio as a fraction (pct/100) without bc/python.
error_ratio=$(awk 'BEGIN{printf "%.6f", '"$ERROR_RATE_PCT"'/100}')

existing_policies=$(g alpha monitoring policies list --format='value(displayName)')

echo "== alert policies"
for svc in $PUBLIC_SERVICES; do
  display="dc 5xx rate: $svc"
  cat > "$WORK/5xx-$svc.json" <<POLICY
{
  "displayName": "$display",
  "combiner": "OR",
  "enabled": true,
  "documentation": {
    "content": "5xx fraction of run.googleapis.com/request_count on $svc is above $ERROR_RATE_PCT% for 5 minutes (service-wide, all revisions).",
    "mimeType": "text/markdown"
  },
  "conditions": [{
    "displayName": "5xx ratio over $ERROR_RATE_PCT% for 5m",
    "conditionThreshold": {
      "filter": "metric.type=\"run.googleapis.com/request_count\" AND resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"$svc\" AND metric.labels.response_code_class=\"5xx\"",
      "comparison": "COMPARISON_GT",
      "thresholdValue": $error_ratio,
      "duration": "300s",
      "trigger": {"count": 1},
      "aggregations": [{
        "alignmentPeriod": "60s",
        "perSeriesAligner": "ALIGN_RATE",
        "crossSeriesReducer": "REDUCE_SUM",
        "groupByFields": ["resource.labels.service_name"]
      }],
      "denominatorFilter": "metric.type=\"run.googleapis.com/request_count\" AND resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"$svc\"",
      "denominatorAggregations": [{
        "alignmentPeriod": "60s",
        "perSeriesAligner": "ALIGN_RATE",
        "crossSeriesReducer": "REDUCE_SUM",
        "groupByFields": ["resource.labels.service_name"]
      }]
    }
  }],
  "notificationChannels": ["$channel"],
  "alertStrategy": {"autoClose": "1800s"}
}
POLICY
  upsert_policy "$display" "$WORK/5xx-$svc.json"
done

display="dc p95 latency: dating-coach-api"
cat > "$WORK/p95-api.json" <<POLICY
{
  "displayName": "$display",
  "combiner": "OR",
  "enabled": true,
  "documentation": {
    "content": "p95 request latency on dating-coach-api is above ${P95_MS}ms for 5 minutes.",
    "mimeType": "text/markdown"
  },
  "conditions": [{
    "displayName": "p95 latency over ${P95_MS}ms for 5m",
    "conditionThreshold": {
      "filter": "metric.type=\"run.googleapis.com/request_latencies\" AND resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"dating-coach-api\"",
      "comparison": "COMPARISON_GT",
      "thresholdValue": $P95_MS,
      "duration": "300s",
      "trigger": {"count": 1},
      "aggregations": [{
        "alignmentPeriod": "60s",
        "perSeriesAligner": "ALIGN_PERCENTILE_95",
        "crossSeriesReducer": "REDUCE_PERCENTILE_95",
        "groupByFields": ["resource.labels.service_name"]
      }]
    }
  }],
  "notificationChannels": ["$channel"],
  "alertStrategy": {"autoClose": "1800s"}
}
POLICY
upsert_policy "$display" "$WORK/p95-api.json"

display="dc job failure: dating-coach-migrate"
cat > "$WORK/job-migrate.json" <<POLICY
{
  "displayName": "$display",
  "combiner": "OR",
  "enabled": true,
  "documentation": {
    "content": "An execution of the dating-coach-migrate Cloud Run job finished with result=failed. Schema may not be where the deploy expects it.",
    "mimeType": "text/markdown"
  },
  "conditions": [{
    "displayName": "dating-coach-migrate execution failed",
    "conditionThreshold": {
      "filter": "metric.type=\"run.googleapis.com/job/completed_execution_count\" AND resource.type=\"cloud_run_job\" AND resource.labels.job_name=\"dating-coach-migrate\" AND metric.labels.result=\"failed\"",
      "comparison": "COMPARISON_GT",
      "thresholdValue": 0,
      "duration": "0s",
      "trigger": {"count": 1},
      "aggregations": [{
        "alignmentPeriod": "60s",
        "perSeriesAligner": "ALIGN_DELTA",
        "crossSeriesReducer": "REDUCE_SUM"
      }]
    }
  }],
  "notificationChannels": ["$channel"],
  "alertStrategy": {"autoClose": "1800s"}
}
POLICY
upsert_policy "$display" "$WORK/job-migrate.json"

for topic in $TOPICS; do
  display="dc pubsub unacked: $topic.worker-push"
  cat > "$WORK/unacked-$topic.json" <<POLICY
{
  "displayName": "$display",
  "combiner": "OR",
  "enabled": true,
  "documentation": {
    "content": "Oldest unacked message on subscription $topic.worker-push is over ${UNACKED_AGE_S}s old for 5 minutes — the worker is not keeping up or is down.",
    "mimeType": "text/markdown"
  },
  "conditions": [{
    "displayName": "$topic.worker-push unacked over ${UNACKED_AGE_S}s",
    "conditionThreshold": {
      "filter": "metric.type=\"pubsub.googleapis.com/subscription/oldest_unacked_message_age\" AND resource.type=\"pubsub_subscription\" AND resource.labels.subscription_id=\"$topic.worker-push\"",
      "comparison": "COMPARISON_GT",
      "thresholdValue": $UNACKED_AGE_S,
      "duration": "300s",
      "trigger": {"count": 1},
      "aggregations": [{
        "alignmentPeriod": "60s",
        "perSeriesAligner": "ALIGN_MAX",
        "crossSeriesReducer": "REDUCE_MAX"
      }]
    }
  }],
  "notificationChannels": ["$channel"],
  "alertStrategy": {"autoClose": "1800s"}
}
POLICY
  upsert_policy "$display" "$WORK/unacked-$topic.json"

  display="dc dlq messages: $topic.dlq-hold"
  cat > "$WORK/dlq-$topic.json" <<POLICY
{
  "displayName": "$display",
  "combiner": "OR",
  "enabled": true,
  "documentation": {
    "content": "More than $DLQ_MESSAGES undelivered message(s) on $topic.dlq-hold — the worker exhausted retries on $topic and dead-lettered. Inspect and replay from the dlq-hold pull subscription.",
    "mimeType": "text/markdown"
  },
  "conditions": [{
    "displayName": "$topic.dlq-hold has messages",
    "conditionThreshold": {
      "filter": "metric.type=\"pubsub.googleapis.com/subscription/num_undelivered_messages\" AND resource.type=\"pubsub_subscription\" AND resource.labels.subscription_id=\"$topic.dlq-hold\"",
      "comparison": "COMPARISON_GT",
      "thresholdValue": $DLQ_MESSAGES,
      "duration": "0s",
      "trigger": {"count": 1},
      "aggregations": [{
        "alignmentPeriod": "60s",
        "perSeriesAligner": "ALIGN_MAX",
        "crossSeriesReducer": "REDUCE_SUM"
      }]
    }
  }],
  "notificationChannels": ["$channel"],
  "alertStrategy": {"autoClose": "1800s"}
}
POLICY
  upsert_policy "$display" "$WORK/dlq-$topic.json"
done

echo "done: 1 channel + policies for 5xx (api, web), p95 (api), migrate job, worker-push backlog, dlq messages"
