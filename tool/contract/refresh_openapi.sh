#!/usr/bin/env bash
# Refreshes test/contract/openapi.json, the backend document the schema-drift
# test (test/contract/schema_drift_test.dart) checks the phone's readers
# against (DAS-136).
#
#   tool/contract/refresh_openapi.sh                 from a server already on :8000
#   E2E_PORT=8010 tool/contract/refresh_openapi.sh   another port
#   tool/contract/refresh_openapi.sh --start         start the backend's e2e server, fetch, stop it
#
# The contract is the backend's main (what the next deploy ships), so the
# server should be running main's app/. Production is ahead of nothing and
# behind main, so a fetch from it is a report, not a contract.
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
BACKEND_DIR="${E2E_BACKEND_DIR:-$APP_DIR/../bahi_backend}"
PORT="${E2E_PORT:-8000}"
OUT="$APP_DIR/test/contract/openapi.json"

started=0
if [ "${1:-}" = "--start" ]; then
  (cd "$BACKEND_DIR" && E2E_PORT="$PORT" ops/e2e_server.sh up >/dev/null)
  started=1
  trap '(cd "$BACKEND_DIR" && E2E_PORT="$PORT" ops/e2e_server.sh down >/dev/null 2>&1)' EXIT
fi

tmp="$(mktemp)"
curl -sf -m 20 "http://127.0.0.1:$PORT/openapi.json" -o "$tmp"
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); json.dump(d, open(sys.argv[2], "w"), indent=1, sort_keys=True); print(d["info"]["title"], len(d["paths"]), "paths,", len(d["components"]["schemas"]), "schemas")' "$tmp" "$OUT"
rm -f "$tmp"
echo "wrote $OUT (backend branch: $(git -C "$BACKEND_DIR" branch --show-current 2>/dev/null || echo unknown))"
[ "$started" = 1 ] && echo "stopped the e2e server"
cd "$APP_DIR" && git --no-pager diff --stat -- test/contract/openapi.json || true
