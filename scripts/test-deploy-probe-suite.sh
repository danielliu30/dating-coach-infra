#!/usr/bin/env bash
# Offline test for deploy-probe-suite.sh: a tiny node fixture server returns
# per-path statuses; the suite is run against it with a fixture config. Run:
#   bash scripts/test-deploy-probe-suite.sh   (needs node on PATH)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SUITE="$ROOT/scripts/deploy-probe-suite.sh"
FIX=$(mktemp -d)
trap 'rm -rf "$FIX"; [ -n "${SRV_PID:-}" ] && kill "$SRV_PID" 2>/dev/null' EXIT

cat > "$FIX/server.js" <<'EOF'
const http = require('http');
const map = {
  '/healthz': 200,
  '/api/v1/auth/signup': 400,
  '/api/v1/me': 401,
  '/flaky': 200,
};
http.createServer((req, res) => {
  const status = map[req.url] || 404;
  res.writeHead(status).end('{}');
}).listen(8189, '127.0.0.1');
EOF
node "$FIX/server.js" &
SRV_PID=$!
sleep 1

cat > "$FIX/suite.conf" <<'EOF'
health|GET|/healthz|200|
signup|POST|/api/v1/auth/signup|400|{}
me|GET|/api/v1/me|401|
EOF
cat > "$FIX/failing.conf" <<'EOF'
health|GET|/healthz|200|
missing|GET|/nope|200|
EOF
cat > "$FIX/flaky.conf" <<'EOF'
flaky|GET|/flaky|200|
EOF

pass=0; fail=0
t() { local name=$1 want=$2; shift 2
  "$@" >/dev/null 2>&1; local got=$?
  if [ "$want" = "$got" ]; then pass=$((pass+1)); printf 'ok    %s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL  %s (want %s, got %s)\n' "$name" "$want" "$got"; fi
}
P() { bash "$SUITE" --base-url http://127.0.0.1:8189 "$@"; }

t 'suite passes'                  0 P --config "$FIX/suite.conf"
t 'fails on wrong status'         1 P --config "$FIX/failing.conf"
t 'repeat ok'                     0 P --config "$FIX/suite.conf" --repeat 3
t 'missing config errors'         2 P --config "$FIX/none.conf"
t 'unreachable host fails'        1 bash "$SUITE" --base-url http://127.0.0.1:9 --config "$FIX/flaky.conf" --timeout 2
t 'compare matching passes'       0 P --config "$FIX/suite.conf" --compare http://127.0.0.1:8189

# compare against a second fixture that disagrees
cat > "$FIX/server2.js" <<'EOF'
const http = require('http');
http.createServer((req, res) => { res.writeHead(200).end('{}'); }).listen(8190, '127.0.0.1');
EOF
node "$FIX/server2.js" &
SRV_PID2=$!
sleep 1
# me probe: 401 on base (passes its want), 200 on server2 -> divergence fails
t 'compare divergence fails'      1 P --config "$FIX/suite.conf" --compare http://127.0.0.1:8190
kill "$SRV_PID2" 2>/dev/null

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
