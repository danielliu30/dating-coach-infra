#!/usr/bin/env bash
# Offline test harness for monitoring-alerts.sh: stubs gcloud on PATH so the
# script's list/create/update calls are recorded and answered from fixture
# files. Run:
#   bash scripts/test-monitoring-alerts.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MON="$ROOT/scripts/monitoring-alerts.sh"
FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT

# Stub gcloud: records every invocation, copies each --policy-from-file JSON
# into the fixture dir, and answers list calls from $FIXTURE_DIR fixtures:
#   channels   - one channel display name per line
#   policies   - one policy display name per line
cat > "$FIX/gcloud" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FIXTURE_DIR/gcloud-calls"
n=0; [ -f "$FIXTURE_DIR/seq" ] && n=$(cat "$FIXTURE_DIR/seq"); echo $((n+1)) > "$FIXTURE_DIR/seq"
for a in "$@"; do
  case "$a" in
    --policy-from-file=*) cp "${a#--policy-from-file=}" "$FIXTURE_DIR/policy-$n.json";;
  esac
done
case "$*" in
  *"channels create"*)             echo "projects/p/notificationChannels/222" ;;
  *"channels"*"value(displayName)"*) cat "$FIXTURE_DIR/channels" 2>/dev/null ;;
  *"channels"*"value(name)"*)      echo "projects/p/notificationChannels/111" ;;
  *"policies"*"value(displayName)"*) cat "$FIXTURE_DIR/policies" 2>/dev/null ;;
  *"policies"*"value(name)"*)      echo "projects/p/alertPolicies/333" ;;
esac
exit 0
EOF
chmod +x "$FIX/gcloud"

pass=0; fail=0
export FIXTURE_DIR="$FIX"
export PATH="$FIX:$PATH"

count_calls() { grep -c -e "$1" "$FIX/gcloud-calls" 2>/dev/null || true; }
expect_calls() { # expect_calls <name> <want> <pattern>
  local n; n=$(count_calls "$3")
  if [ "$n" = "$2" ]; then pass=$((pass+1)); printf 'ok    %s\n' "$1"
  else fail=$((fail+1)); printf 'FAIL  %s (want %s matches of %s, got %s)\n' "$1" "$2" "$3" "$n"; fi
}
expect_policy() { # expect_policy <name> <regex present in some policy-*.json>
  if cat "$FIX"/policy-*.json 2>/dev/null | grep -q -e "$2"; then
    pass=$((pass+1)); printf 'ok    %s\n' "$1"
  else
    fail=$((fail+1)); printf 'FAIL  %s (no policy file matches %s)\n' "$1" "$2"
  fi
}

reset() { rm -f "$FIX"/gcloud-calls "$FIX"/seq "$FIX"/channels "$FIX"/policies "$FIX"/policy-*.json; }
run_mon() { # run_mon <env-assignments...>
  env PROJECT_ID=p ALERT_EMAIL=ops@example.com "$@" bash "$MON" >/dev/null 2>&1
}

ALL_POLICIES='dc 5xx rate: dating-coach-api
dc 5xx rate: dating-coach-web
dc p95 latency: dating-coach-api
dc job failure: dating-coach-migrate
dc pubsub unacked: conversation.analysis.worker-push
dc pubsub unacked: account.deletion.worker-push
dc pubsub unacked: email.outbox.worker-push
dc dlq messages: conversation.analysis.dlq-hold
dc dlq messages: account.deletion.dlq-hold
dc dlq messages: email.outbox.dlq-hold'

# --- required env ------------------------------------------------------------
reset
env -u ALERT_EMAIL PROJECT_ID=p bash "$MON" >/dev/null 2>&1
[ $? = 2 ] && { pass=$((pass+1)); echo 'ok    missing ALERT_EMAIL exits 2'; } \
           || { fail=$((fail+1)); echo 'FAIL  missing ALERT_EMAIL exits 2'; }
[ ! -f "$FIX/gcloud-calls" ] \
  && { pass=$((pass+1)); echo 'ok    missing ALERT_EMAIL touches nothing'; } \
  || { fail=$((fail+1)); echo 'FAIL  missing ALERT_EMAIL touches nothing'; }

reset
env -u PROJECT_ID ALERT_EMAIL=ops@example.com bash "$MON" >/dev/null 2>&1
[ $? = 2 ] && { pass=$((pass+1)); echo 'ok    missing PROJECT_ID exits 2'; } \
           || { fail=$((fail+1)); echo 'FAIL  missing PROJECT_ID exits 2'; }

reset
run_mon ALERT_ERROR_RATE_PCT=abc >/dev/null 2>&1
[ $? = 2 ] && { pass=$((pass+1)); echo 'ok    non-numeric threshold exits 2'; } \
           || { fail=$((fail+1)); echo 'FAIL  non-numeric threshold exits 2'; }

# --- fresh project: everything is created ------------------------------------
reset
run_mon
[ $? = 0 ] && { pass=$((pass+1)); echo 'ok    fresh run exits 0'; } \
           || { fail=$((fail+1)); echo 'FAIL  fresh run exits 0'; }
expect_calls 'channel created'       1 'channels create'
expect_calls 'no channel reuse'      0 'channels list.*value(name)'
expect_calls 'ten policies created' 10 'policies create'
expect_calls 'no policies updated'   0 'policies update'

expect_policy 'api 5xx policy'      'dc 5xx rate: dating-coach-api'
expect_policy 'web 5xx policy'      'dc 5xx rate: dating-coach-web'
expect_policy 'api 5xx filter'      'service_name=\\"dating-coach-api\\" AND metric.labels.response_code_class=\\"5xx\\"'
expect_policy 'api 5xx ratio 1%'    '"thresholdValue": 0.010000'
expect_policy '5xx denominator'     'denominatorFilter'
expect_policy 'api p95 policy'      'dc p95 latency: dating-coach-api'
expect_policy 'api p95 threshold'   '"thresholdValue": 2000'
expect_policy 'api p95 aligner'     'ALIGN_PERCENTILE_95'
expect_policy 'migrate job policy'  'dc job failure: dating-coach-migrate'
expect_policy 'migrate job metric'  'job/completed_execution_count.*result=\\"failed\\"'
for t in conversation.analysis account.deletion email.outbox; do
  expect_policy "unacked $t"        "dc pubsub unacked: $t.worker-push"
  expect_policy "dlq $t"            "dc dlq messages: $t.dlq-hold"
done
expect_policy 'unacked metric'      'oldest_unacked_message_age'
expect_policy 'dlq metric'          'num_undelivered_messages'
expect_policy 'channel wired in'    'projects/p/notificationChannels/222'
grep -q 'email_address=ops@example.com' "$FIX/gcloud-calls" \
  && { pass=$((pass+1)); echo 'ok    channel uses ALERT_EMAIL'; } \
  || { fail=$((fail+1)); echo 'FAIL  channel uses ALERT_EMAIL'; }

# --- existing project: everything is updated ---------------------------------
reset
echo 'dating-coach-alerts' > "$FIX/channels"
printf '%s\n' "$ALL_POLICIES" > "$FIX/policies"
run_mon
[ $? = 0 ] && { pass=$((pass+1)); echo 'ok    rerun exits 0'; } \
           || { fail=$((fail+1)); echo 'FAIL  rerun exits 0'; }
expect_calls 'channel reused'         0 'channels create'
expect_calls 'channel name resolved'  1 'channels list.*value(name)'
expect_calls 'nothing created'        0 'policies create'
expect_calls 'ten policies updated'  10 'policies update'
expect_calls 'update targets name'   10 'policies update projects/p/alertPolicies/333'

# --- mixed state: channel exists, policies absent ----------------------------
reset
echo 'dating-coach-alerts' > "$FIX/channels"
run_mon ALERT_ERROR_RATE_PCT=2.5 ALERT_P95_MS=3500
[ $? = 0 ] && { pass=$((pass+1)); echo 'ok    mixed run exits 0'; } \
           || { fail=$((fail+1)); echo 'FAIL  mixed run exits 0'; }
expect_calls 'mixed: no channel create'  0 'channels create'
expect_calls 'mixed: creates policies'  10 'policies create'
expect_policy 'custom error rate'       '"thresholdValue": 0.025000'
expect_policy 'custom p95'              '"thresholdValue": 3500'

# --- partial policy state: only missing ones are created ----------------------
reset
echo 'dating-coach-alerts' > "$FIX/channels"
printf 'dc 5xx rate: dating-coach-api\ndc job failure: dating-coach-migrate\n' > "$FIX/policies"
run_mon
expect_calls 'partial: 2 updated'  2 'policies update'
expect_calls 'partial: 8 created'  8 'policies create'

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
