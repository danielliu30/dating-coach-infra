#!/usr/bin/env bash
# Drift check for the e2e gate mirror (issue #10).
#
# .github/workflows/gate-e2e.yml mirrors the app repo's
# .github/workflows/e2e.yml. The mirror is allowed structural differences —
# checkout args, `app/` path prefixes, working-directory overrides,
# reusable-workflow boilerplate — so we compare only the meaningful signal:
# the ordered `- name:` step names plus the first line of each step's `run:`
# command. Drift = a step name added/removed/renamed, or a same-named step
# whose run command differs.
#
# Exit codes — every non-zero code is "not ok" for gate-drift.yml:
#   0  in sync
#   1  drift detected (both step lists are printed)
#   2  could not verify: fetch or parse failure. Fails closed — a scheduled
#      check that cannot verify must alert, not pass silently.
#
# Overrides (used by test-check-e2e-drift.sh):
#   --ours F       our gate yaml        (default .github/workflows/gate-e2e.yml)
#   --file F       read the app e2e.yml from F instead of fetching
#   APP_REPO       app repo slug        (default danielliu30/dating-coach)
#   APP_E2E_URL    fetch URL            (default raw .../$APP_REPO/main e2e.yml)
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OURS="$ROOT/.github/workflows/gate-e2e.yml"
APP_FILE=""
APP_REPO=${APP_REPO:-danielliu30/dating-coach}
APP_E2E_URL=${APP_E2E_URL:-https://raw.githubusercontent.com/$APP_REPO/main/.github/workflows/e2e.yml}

while [ $# -gt 0 ]; do
  case "$1" in
    --ours) OURS=$2 ;;
    --file) APP_FILE=$2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift 2
done

# emit_steps <yaml> -> "N:<step name>" for every `- name:` step and "R:<cmd>"
# for the first line of its `run:` (inline `run: cmd` or first line of a
# `run: |`/`run: >` block). `uses:`-only detail, `with:` args, env, defaults
# and working-directory are ignored — allowed mirror differences.
emit_steps() {
  awk '
    function indent(s) { match(s, /^[ ]*/); return RLENGTH }

    # first line inside a `run: |`/`run: >` block: more indented than the key
    wantblock && NF && indent($0) > blockindent {
      r = $0
      sub(/^[ ]+/, "", r); sub(/[ ]+$/, "", r)
      print "R:" r
      gotrun = 1; wantblock = 0
      next
    }
    # dedented out of an empty run block: end it and fall through
    wantblock && NF { wantblock = 0 }

    # any `- ` list item is a step boundary; keys of the step sit at keyindent
    /^[ ]*-[ ]*/ {
      match($0, /^[ ]*-[ ]*/); keyindent = RLENGTH; instep = 1
      gotrun = 0
      if ($0 ~ /^[ ]*-[ ]*name:[ ]*/) {
        n = $0
        sub(/^[ ]*-[ ]*name:[ ]*/, "", n); sub(/[ ]+$/, "", n)
        print "N:" n
      } else if ($0 ~ /^[ ]*-[ ]*run:[ ]*/) {
        r = $0
        sub(/^[ ]*-[ ]*run:[ ]*/, "", r)
        if (r ~ /^[|>]/ || r == "") { wantblock = 1; blockindent = keyindent }
        else { sub(/[ ]+$/, "", r); print "R:" r; gotrun = 1 }
      }
      next
    }

    # continuation `run:` key of the current step (e.g. under `- name:`);
    # keyindent excludes lookalikes like defaults.run.working-directory
    instep && !gotrun && /^[ ]*run:[ ]*/ && indent($0) == keyindent {
      r = $0
      sub(/^[ ]*run:[ ]*/, "", r)
      if (r ~ /^[|>]/ || r == "") { wantblock = 1; blockindent = keyindent; next }
      sub(/[ ]+$/, "", r)
      print "R:" r
      gotrun = 1
      next
    }
  ' "$1" | tr -d "\"'"   # strip quotes so 'name' and name compare equal
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

[ -f "$OURS" ] || { echo "parse failure: our gate yaml not found: $OURS" >&2; exit 2; }
emit_steps "$OURS" >"$TMP/ours.txt" || { echo "parse failure: $OURS" >&2; exit 2; }
grep -q '^N:' "$TMP/ours.txt" || { echo "parse failure: no steps found in $OURS" >&2; exit 2; }

if [ -n "$APP_FILE" ]; then
  APP_SRC=$APP_FILE
  [ -f "$APP_SRC" ] || { echo "fetch failure: --file not found: $APP_SRC" >&2; exit 2; }
else
  APP_SRC=$TMP/app-e2e.yml
  echo "fetching $APP_E2E_URL"
  curl -fsSL --max-time 30 -o "$APP_SRC" "$APP_E2E_URL" \
    || { echo "fetch failure: $APP_E2E_URL" >&2; exit 2; }
fi
emit_steps "$APP_SRC" >"$TMP/app.txt" || { echo "parse failure: $APP_SRC" >&2; exit 2; }
grep -q '^N:' "$TMP/app.txt" || { echo "parse failure: no steps found in $APP_SRC" >&2; exit 2; }

if diff -u "$TMP/ours.txt" "$TMP/app.txt" >/dev/null; then
  echo "in sync: gate-e2e.yml matches $APP_REPO e2e.yml ($(grep -c '^N:' "$TMP/ours.txt") steps)"
  exit 0
fi

echo "DRIFT: gate-e2e.yml and $APP_REPO e2e.yml have diverged" >&2
echo "--- our steps (N: name, R: first run line) ---" >&2
cat "$TMP/ours.txt" >&2
echo "--- app steps ---" >&2
cat "$TMP/app.txt" >&2
echo "--- diff (ours vs app) ---" >&2
diff -u "$TMP/ours.txt" "$TMP/app.txt" >&2
exit 1
