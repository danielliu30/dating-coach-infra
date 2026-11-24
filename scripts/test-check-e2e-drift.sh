#!/usr/bin/env bash
# Offline test harness for check-e2e-drift.sh: feeds fixture yaml pairs through
# --ours/--file instead of fetching the live app e2e.yml. Run:
#   bash scripts/test-check-e2e-drift.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CHK="$ROOT/scripts/check-e2e-drift.sh"
FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT

pass=0; fail=0
t() { # t <name> <want-exit> <cmd...>
  local name=$1 want=$2; shift 2
  "$@" >/dev/null 2>&1; local got=$?
  if [ "$want" = "$got" ]; then pass=$((pass+1)); printf 'ok    %s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL  %s (want %s, got %s)\n' "$name" "$want" "$got"; fi
}
C() { bash "$CHK" --ours "$1" --file "$2"; }

# app-side e2e.yml fixture: the meaningful steps the mirror must track.
cat >"$FIX/app-base.yml" <<'EOF'
name: E2E (Playwright against the full stack)
on:
  pull_request:
concurrency:
  group: e2e-${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
jobs:
  e2e:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - name: Use the E2E environment
        run: cp e2e/.env .env
      - name: Bring up the gateway stack
        run: docker compose --env-file e2e/.env --profile gateway up -d --build
      - name: Wait for /healthz through nginx
        run: |
          for i in $(seq 1 90); do
            curl -fsS http://localhost:80/healthz && exit 0
            sleep 2
          done
      - name: Run Playwright
        working-directory: e2e
        run: npx playwright test
      - name: Upload Playwright report + traces
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: playwright-report
          path: e2e/playwright-report
      - name: Tear down
        if: always()
        run: docker compose --env-file e2e/.env --profile gateway down -v
EOF

# mirror fixture: same named steps/run commands plus allowed structural noise —
# reusable-workflow boilerplate, checkout args, app/ prefixes, extra unnamed
# uses steps, working-directory overrides. Expect: in sync (0).
cat >"$FIX/gate-same.yml" <<'EOF'
name: Gate — app e2e at a given SHA
on:
  workflow_call:
    inputs:
      app_sha:
        required: true
        type: string
env:
  APP_REPO: danielliu30/dating-coach
jobs:
  e2e:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: app
    steps:
      - uses: actions/checkout@v4
        with:
          repository: ${{ env.APP_REPO }}
          ref: ${{ inputs.app_sha }}
          path: app
      - uses: docker/setup-buildx-action@v3
      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache-dependency-path: app/e2e/package-lock.json
      - name: Use the E2E environment
        run: cp e2e/.env .env
      - name: Bring up the gateway stack
        run: docker compose --env-file e2e/.env --profile gateway up -d --build
      - name: Wait for /healthz through nginx
        run: |
          for i in $(seq 1 90); do
            curl -fsS http://localhost:80/healthz && exit 0
            sleep 2
          done
      - name: Run Playwright
        working-directory: app/e2e
        run: npx playwright test
      - name: Upload Playwright report + traces
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: playwright-report
          path: app/e2e/playwright-report
      - name: Tear down
        if: always()
        run: docker compose --env-file e2e/.env --profile gateway down -v
EOF

# app adds a step -> drift (1)
sed '/- name: Run Playwright/i\
      - name: Seed test users\
        run: bash e2e/seed.sh' "$FIX/app-base.yml" >"$FIX/app-added.yml"

# app renames a step -> drift (1)
sed 's/name: Run Playwright/name: Run the Playwright suite/' \
  "$FIX/app-base.yml" >"$FIX/app-renamed.yml"

# same names, different run command -> drift (1)
sed 's|run: npx playwright test|run: npx playwright test --grep @smoke|' \
  "$FIX/app-base.yml" >"$FIX/app-runchange.yml"

t 'identical steps in sync'            0 C "$FIX/gate-same.yml" "$FIX/app-base.yml"
t 'app adds a step drifts'             1 C "$FIX/gate-same.yml" "$FIX/app-added.yml"
t 'app renames a step drifts'          1 C "$FIX/gate-same.yml" "$FIX/app-renamed.yml"
t 'changed run command drifts'         1 C "$FIX/gate-same.yml" "$FIX/app-runchange.yml"
t 'infra-only extras stay in sync'     0 C "$FIX/gate-same.yml" "$FIX/app-base.yml"

# comparison is symmetric in what it extracts: same streams either way
t 'reversed pair still in sync'        0 C "$FIX/app-base.yml" "$FIX/gate-same.yml"

# fail closed: missing fixture file, unparsable yaml
t 'missing --file fails closed'        2 bash "$CHK" --ours "$FIX/gate-same.yml" --file "$FIX/nope.yml"
printf 'not yaml at all\n' >"$FIX/garbage.yml"
t 'no steps fails closed'              2 C "$FIX/gate-same.yml" "$FIX/garbage.yml"
t 'missing --ours fails closed'        2 bash "$CHK" --ours "$FIX/nope.yml" --file "$FIX/app-base.yml"

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
