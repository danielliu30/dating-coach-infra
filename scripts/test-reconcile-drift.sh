#!/usr/bin/env bash
# Offline test harness for reconcile-drift.sh: stubs gcloud (service describe)
# and git (ls-remote/fetch/show) so no GCP or network access is needed. Run:
#   bash scripts/test-reconcile-drift.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
RECON="$ROOT/scripts/reconcile-drift.sh"
FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT
export FIXTURE_DIR="$FIX"

cat > "$FIX/gcloud" <<'EOF'
#!/usr/bin/env bash
# Returns the contents of $FIXTURE_DIR/image-<svc> for `run services describe`.
echo "$*" >> "$FIXTURE_DIR/gcloud-calls"
svc="" prev=""
for a in "$@"; do
  if [ "$prev" = "describe" ]; then svc=$a; break; fi
  prev=$a
done
[ -n "$svc" ] && [ -f "$FIXTURE_DIR/image-$svc" ] || exit 1
cat "$FIXTURE_DIR/image-$svc"
EOF
cat > "$FIX/git" <<'EOF'
#!/usr/bin/env bash
# Stub git: ls-remote prints $STUB_TIP; fetch honours git-fetch-fail;
# show -s --format=%ct prints $STUB_TIP_EPOCH.
echo "$*" >> "$FIXTURE_DIR/git-calls"
sub="" prev=""
for a in "$@"; do
  if [ "$prev" = "-C" ]; then prev=""; continue; fi
  case "$a" in
    -C) prev="-C" ;;
    ls-remote|init|fetch|show) sub=$a; break ;;
  esac
done
case "$sub" in
  ls-remote)
    [ -f "$FIXTURE_DIR/git-lsremote-fail" ] && exit 1
    printf '%s\t%s\n' "$STUB_TIP" "refs/heads/main" ;;
  init) exit 0 ;;
  fetch) [ -f "$FIXTURE_DIR/git-fetch-fail" ] && exit 1; exit 0 ;;
  show) echo "${STUB_TIP_EPOCH:-0}" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$FIX/gcloud" "$FIX/git"

TIP=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OLD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
NOW=$(date +%s)
SVCS="dating-coach-api dating-coach-web dating-coach-ml dating-coach-worker"

pass=0; fail=0
reset() {
  rm -f "$FIX"/image-* "$FIX/git-calls" "$FIX/gcloud-calls" \
    "$FIX/git-fetch-fail" "$FIX/git-lsremote-fail"
}
deploy_all() { # deploy_all <tag>
  for s in $SVCS; do echo "docker.io/x/$s:$1" > "$FIX/image-$s"; done
}
run() { # run <name> <want-exit>
  local name=$1 want=$2
  GCLOUD="$FIX/gcloud" GIT="$FIX/git" STUB_TIP="$TIP" STUB_TIP_EPOCH="$EPOCH" \
    PROJECT=p REGION=r SERVICES="$SVCS" GRACE_MINUTES=60 \
    bash "$RECON" > "$FIX/out" 2>&1
  local got=$?
  if [ "$want" = "$got" ]; then pass=$((pass+1)); printf 'ok    %s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL  %s (want %s, got %s)\n' "$name" "$want" "$got"; cat "$FIX/out"; fi
}
expect() { # expect <name> <count> <pattern> — grep the last run's output
  local n; n=$(grep -c -e "$3" "$FIX/out" || true)
  if [ "$n" = "$2" ]; then pass=$((pass+1)); printf 'ok    %s\n' "$1"
  else fail=$((fail+1)); printf 'FAIL  %s (want %s matches of %s, got %s)\n' "$1" "$2" "$3" "$n"; fi
}

# all four deployed at the tip -> in sync, exit 0
reset; deploy_all "$TIP"; EPOCH=$((NOW - 7200))
run 'all in sync' 0
expect 'four in-sync rows' 4 'IN-SYNC'

# deployed at an old tag, tip older than the grace window -> drift, exit 1
reset; deploy_all "$OLD"; EPOCH=$((NOW - 7200))
run 'drifted old tip fails' 1
expect 'four drifted rows' 4 'DRIFTED'

# deployed at an old tag but the tip just landed (within grace) -> exit 0
reset; deploy_all "$OLD"; EPOCH=$((NOW - 60))
run 'fresh tip within grace' 0
expect 'four grace rows' 4 'GRACE'

# a service with no describe result is PENDING, not drift -> exit 0
reset; deploy_all "$TIP"; rm "$FIX/image-dating-coach-ml"; EPOCH=$((NOW - 7200))
run 'undeployed service pending' 0
expect 'one pending row' 1 'PENDING'
expect 'no drift rows' 0 'DRIFTED'

# unfetchable tip commit + a mismatch -> fail closed, exit 1
reset; deploy_all "$OLD"; EPOCH=$NOW; touch "$FIX/git-fetch-fail"
run 'unfetchable tip fails closed' 1
expect 'drifted on unresolvable tip' 4 'DRIFTED'

# missing required env -> usage error 2
reset
GIT="$FIX/git" bash "$RECON" >/dev/null 2>&1
[ $? = 2 ] && { pass=$((pass+1)); echo 'ok    missing env error'; } \
           || { fail=$((fail+1)); echo 'FAIL  missing env error'; }

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
