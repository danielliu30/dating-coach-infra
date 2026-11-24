#!/usr/bin/env bash
# Offline test harness for deploy-waves.sh: stubs gcloud, sleep and the bake
# gate so the staircase logic runs instantly. Run:
#   bash scripts/test-deploy-waves.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WAVES="$ROOT/scripts/deploy-waves.sh"
FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT

cat > "$FIX/gcloud" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FIXTURE_DIR/gcloud-calls"
[ -f "$FIXTURE_DIR/gcloud-fail" ] && exit 1
exit 0
EOF
cat > "$FIX/true" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$FIX/probe" <<'EOF'
#!/usr/bin/env bash
echo "probe $*" >> "$FIXTURE_DIR/probe-calls"
[ -f "$FIXTURE_DIR/probe-fail" ] && exit 1
exit 0
EOF
cat > "$FIX/bake-check" <<'EOF'
#!/usr/bin/env bash
# Returns the nth value of $BAKE_RESULTS on the nth invocation.
f="$FIXTURE_DIR/bake-calls"; n=0
[ -f "$f" ] && n=$(cat "$f")
echo $((n+1)) > "$f"
set -- $BAKE_RESULTS
eval "echo \$((n+1))" >/dev/null
res=$(eval "echo \${$((n+1)):-0}")
exit "$res"
EOF
chmod +x "$FIX/gcloud" "$FIX/true" "$FIX/bake-check" "$FIX/probe"

pass=0; fail=0
export FIXTURE_DIR="$FIX"
run() { # run <name> <want-exit> <bake_results> [extra args...]
  local name=$1 want=$2 results=$3; shift 3
  rm -f "$FIX/gcloud-calls" "$FIX/bake-calls" "$FIX/gcloud-fail" "$FIX/probe-calls" "$FIX/probe-fail"
  GCLOUD="$FIX/gcloud" SLEEP="$FIX/true" BAKE_CHECK="$FIX/bake-check" \
    PROBE_SUITE="$FIX/probe" BAKE_RESULTS="$results" \
    bash "$WAVES" --project p --region r --service svc \
      --new-revision svc-0002 --prev-revision svc-0001 "$@" >/dev/null 2>&1
  local got=$?
  if [ "$want" = "$got" ]; then pass=$((pass+1)); printf 'ok    %s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL  %s (want %s, got %s)\n' "$name" "$want" "$got"; fi
}
calls() { cat "$FIX/gcloud-calls" 2>/dev/null; }
expect() { # expect <name> <regex-match-count> <pattern>
  local n; n=$(calls | grep -c -e "$3" || true)
  if [ "$n" = "$2" ]; then pass=$((pass+1)); printf 'ok    %s\n' "$1"
  else fail=$((fail+1)); printf 'FAIL  %s (want %s matches of %s, got %s)\n' "$1" "$2" "$3" "$n"; fi
}

# happy path: 3 splits then to-latest, no rollback
run 'full staircase passes'        0 "0 0 0" --plan "10:1 25:1 50:1 100:0"
expect 'three splits sent'         3 'run services update-traffic svc .*--to-revisions'
expect 'final to-latest'           1 'run services update-traffic svc .*--to-latest'
expect 'no rollback'               0 'svc-0001=100'
calls | grep -q -- '--to-revisions svc-0002=10,svc-0001=90' \
  && { pass=$((pass+1)); echo 'ok    wave 10 split correct'; } \
  || { fail=$((fail+1)); echo 'FAIL  wave 10 split correct'; }
calls | grep -q -- '--to-revisions svc-0002=50,svc-0001=50' \
  && { pass=$((pass+1)); echo 'ok    wave 50 split correct'; } \
  || { fail=$((fail+1)); echo 'FAIL  wave 50 split correct'; }

# bake failure on wave 2: stop, single rollback to prev split, never to-latest
run 'bake fail rolls back'         1 "0 1" --plan "10:1 25:1 50:1 100:0"
expect 'rollback issued'           1 'update-traffic svc .*--to-revisions svc-0001=100'
expect 'never reached 100'         0 '--to-latest'
expect 'stopped before wave 50'    0 '--to-revisions svc-0002=50'

# failing traffic command rolls back immediately
touch "$FIX/gcloud-fail"
GCLOUD="$FIX/gcloud" SLEEP="$FIX/true" BAKE_CHECK="$FIX/bake-check" \
  BAKE_RESULTS="0" bash "$WAVES" --project p --region r --service svc \
  --new-revision svc-0002 --prev-revision svc-0001 --plan "10:1 100:0" >/dev/null 2>&1
[ $? = 1 ] && { pass=$((pass+1)); echo 'ok    traffic cmd fail exits 1'; } \
           || { fail=$((fail+1)); echo 'FAIL  traffic cmd fail exits 1'; }
rm -f "$FIX/gcloud-fail"

# custom prev-split honoured on rollback
run 'custom prev-split'            1 "1" --plan "10:1" --prev-split "svc-0001=80,svc-0000=20"
expect 'prev split restored'       1 'update-traffic svc .*--to-revisions svc-0001=80,svc-0000=20'

# tag-url probes run per wave (pre+post bake, plus once at the no-bake 100
# wave); a probe failure rolls back immediately
run 'probes run per wave'          0 "0 0" --plan "10:1 100:0" --tag-url http://tag --probe-config c
n=$(grep -c 'probe' "$FIX/probe-calls" 2>/dev/null || echo 0)
[ "$n" = 3 ] && { pass=$((pass+1)); echo 'ok    probes ran per wave'; } \
             || { fail=$((fail+1)); echo "FAIL  probes ran per wave (got $n)"; }

rm -f "$FIX/probe-calls" "$FIX/gcloud-calls"; touch "$FIX/probe-fail"
GCLOUD="$FIX/gcloud" SLEEP="$FIX/true" BAKE_CHECK="$FIX/bake-check" \
  PROBE_SUITE="$FIX/probe" BAKE_RESULTS="0" \
  bash "$WAVES" --project p --region r --service svc \
    --new-revision svc-0002 --prev-revision svc-0001 \
    --plan "10:1 100:0" --tag-url http://tag --probe-config c >/dev/null 2>&1
[ $? = 1 ] && { pass=$((pass+1)); echo 'ok    probe fail rolls back'; } \
           || { fail=$((fail+1)); echo 'FAIL  probe fail rolls back'; }
grep -q -- '--to-revisions svc-0001=100' "$FIX/gcloud-calls" \
  && { pass=$((pass+1)); echo 'ok    probe fail restored prev split'; } \
  || { fail=$((fail+1)); echo 'FAIL  probe fail restored prev split'; }
grep -q -- '--to-latest' "$FIX/gcloud-calls" \
  && { fail=$((fail+1)); echo 'FAIL  reached 100 despite probe fail'; } \
  || { pass=$((pass+1)); echo 'ok    stopped before 100 on probe fail'; }

# missing required args
GCLOUD="$FIX/gcloud" bash "$WAVES" --project p --region r >/dev/null 2>&1
[ $? = 2 ] && { pass=$((pass+1)); echo 'ok    missing args error'; } \
           || { fail=$((fail+1)); echo 'FAIL  missing args error'; }

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
