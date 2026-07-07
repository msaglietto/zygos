#!/usr/bin/env bash
# S6 exit test runner: build zygos, start it on a scratch port, run the
# unmodified iii Node SDK against it, tear down. Nonzero exit on any failure.
set -euo pipefail
cd "$(dirname "$0")"
REPO_ROOT="$(cd ../../.. && pwd)"
PORT="${ZYGOS_PORT:-49142}"

(cd "$REPO_ROOT" && zig build)

[ -d node_modules ] || npm install --no-audit --no-fund

ZYGOS_PORT="$PORT" "$REPO_ROOT/zig-out/bin/zygos" &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT

# Wait for the listener to come up (bounded).
for _ in $(seq 1 50); do
  if nc -z 127.0.0.1 "$PORT" 2>/dev/null; then break; fi
  sleep 0.1
done

III_URL="ws://127.0.0.1:$PORT" node e2e.mjs
echo "S6 e2e passed on port $PORT"
