#!/usr/bin/env bash
# Timeout/hang regression e2e (the 2026-07-15/16 trilogy): a provider that
# accepts the connection and never responds must not wedge or kill a mission
# the wrong way. Three legs against a silent localhost stub:
#   (1) stream guard: ZYGOS_STREAM_IDLE_MS fires, the provider call fails
#       fast, the run ends role_failed — no hang;
#   (2) timeout tiering: with the guard off, a tight ZYGOS_INVOKE_TIMEOUT_MS
#       kills only the sub-call — the mission survives it (role_failed with a
#       turn-level timeout, NOT "mission: errored: timeout"). Also exercises
#       the headless tick pump: without ticks no deadline ever sweeps and the
#       leg watchdog would trip;
#   (3) mission ceiling: ZYGOS_MISSION_TIMEOUT_MS is still enforced
#       ("mission: errored: timeout" at the configured ceiling).
# No real network: the stub binds 127.0.0.1. Exits 0 only if all legs pass.
set -euo pipefail
cd "$(dirname "$0")/../../.."
ROOT="$PWD"

zig build
BIN="$ROOT/zig-out/bin/zygos"

TMP=$(mktemp -d /tmp/zygos-timeouts-XXXXXX)
STUB_PID=""
cleanup() {
  [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

node test/e2e/timeouts/stub.js > "$TMP/port" &
STUB_PID=$!
disown
for _ in $(seq 1 50); do [ -s "$TMP/port" ] && break; sleep 0.1; done
PORT=$(cat "$TMP/port")
[ -n "$PORT" ] || { echo "TIMEOUTS E2E FAIL: stub did not start"; exit 1; }

cat > "$TMP/providers.toml" <<EOF
[[providers]]
name     = "Silent Fake"
type     = "openai_compatible"
key      = "not-a-key"
endpoint = "http://127.0.0.1:$PORT/v1"
model    = "fake-model"
max_tokens  = 256
temperature = 1
EOF

cat > "$TMP/zygos.zon" <<'EOF'
.{
    .default = .{
        .{ .provider_function = "zygos::providers::silent-fake", .model = "fake-model" },
    },
    .routes = .{},
}
EOF

cat > "$TMP/brief.md" <<'EOF'
---
mission: timeouts-e2e
created: 2026-07-16
source: "timeout regression e2e"
budget:
  max_tokens: 10000
gates:
  external_actions: human
escalation:
  test_fail_threshold: 1
---

# Mission: timeout e2e

## Objective

Write a one-line file named hello.md in the workspace.

## Success criteria

| # | Criterion | Verified by |
|---|-----------|-------------|
| 1 | hello.md exists | ls hello.md |

## Non-goals

- Nothing else.
EOF

export AI_PROVIDERS_CONFIG="$TMP/providers.toml"
export ZYGOS_CONFIG="$TMP/zygos.zon"

# Runs the binary with a hang watchdog; a leg that outlives its deadline IS
# the regression this suite guards. Captures output + exit code, never fails
# the script itself (legs assert on the log).
run_leg() { # <deadline_s> <workdir> <logfile> [env pairs...]
  local deadline="$1" workdir="$2" logfile="$3"
  shift 3
  (
    cd "$workdir"
    env "$@" "$BIN" mission start "$TMP/brief.md" --run-stamp < /dev/null > "$logfile" 2>&1
  ) &
  local run_pid=$!
  ( sleep "$deadline"; kill "$run_pid" 2>/dev/null ) &
  local watchdog_pid=$!
  disown "$watchdog_pid"
  wait "$run_pid" 2>/dev/null || true
  kill "$watchdog_pid" 2>/dev/null || true
}

fail() { echo "TIMEOUTS E2E FAIL: $1"; echo "--- log:"; cat "$2"; exit 1; }

# --- Leg 1: stream guard kills the silent socket, run fails fast ------------
mkdir "$TMP/leg1" && cd "$TMP/leg1"
run_leg 30 "$TMP/leg1" "$TMP/leg1.log" \
  ZYGOS_LOG=info ZYGOS_STREAM_IDLE_MS=2000 ZYGOS_INVOKE_TIMEOUT_MS=60000
grep -q "stream idle timeout: shutting down provider socket" "$TMP/leg1.log" ||
  fail "leg1: stream guard never fired" "$TMP/leg1.log"
grep -q '"stop":"role_failed"' "$TMP/leg1.log" ||
  fail "leg1: expected structured role_failed" "$TMP/leg1.log"
grep -q "mission: errored: timeout" "$TMP/leg1.log" &&
  fail "leg1: mission-level timeout must not fire here" "$TMP/leg1.log"
echo "leg1 ok: stream guard aborts a silent provider"

# --- Leg 2: tight invoke timeout kills the sub-call, mission survives -------
mkdir "$TMP/leg2" && cd "$TMP/leg2"
run_leg 30 "$TMP/leg2" "$TMP/leg2.log" \
  ZYGOS_LOG=info ZYGOS_STREAM_IDLE_MS=0 ZYGOS_INVOKE_TIMEOUT_MS=3000
grep -q "mission: errored: timeout" "$TMP/leg2.log" &&
  fail "leg2: flat timeout killed the mission call (tiering regression)" "$TMP/leg2.log"
grep -q '"stop":"role_failed"' "$TMP/leg2.log" ||
  fail "leg2: expected the role to fail on the sub-call timeout" "$TMP/leg2.log"
grep -q 'errored: timeout' "$TMP/leg2.log" ||
  fail "leg2: expected a turn-level timeout in the stop detail" "$TMP/leg2.log"
echo "leg2 ok: sub-call timeout does not kill the mission"

# --- Leg 3: the mission ceiling itself still enforces ------------------------
mkdir "$TMP/leg3" && cd "$TMP/leg3"
run_leg 30 "$TMP/leg3" "$TMP/leg3.log" \
  ZYGOS_LOG=info ZYGOS_STREAM_IDLE_MS=0 ZYGOS_INVOKE_TIMEOUT_MS=60000 \
  ZYGOS_MISSION_TIMEOUT_MS=3000
grep -q "mission: errored: timeout" "$TMP/leg3.log" ||
  fail "leg3: ZYGOS_MISSION_TIMEOUT_MS ceiling never fired" "$TMP/leg3.log"
echo "leg3 ok: mission ceiling enforces"

echo "TIMEOUTS E2E PASS (3 legs)"
