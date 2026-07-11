#!/usr/bin/env bash
# X3 e2e (GOAL.md M4.5, docs/specs/mission-cli.md): the `zygos mission` CLI
# against a localhost SSE stub. Three legs: (1) start → done via the real
# binary, catalog providers, console gate approved over piped stdin;
# (2) seeded mid-flight substrate finished by `zygos mission resume`;
# (3) a route table naming an unknown slug exits 2 before any kernel boot.
# No real network: the stub binds 127.0.0.1. Exits 0 only if all legs pass.
set -euo pipefail
cd "$(dirname "$0")/../../.."
ROOT="$PWD"

zig build
BIN="$ROOT/zig-out/bin/zygos"

TMP=$(mktemp -d /tmp/zygos-m45-XXXXXX)
STUB_PID=""
cleanup() {
  [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

node test/e2e/m45/stub.js > "$TMP/port" &
STUB_PID=$!
disown
for _ in $(seq 1 50); do [ -s "$TMP/port" ] && break; sleep 0.1; done
PORT=$(cat "$TMP/port")
[ -n "$PORT" ] || { echo "M45 E2E FAIL: stub did not start"; exit 1; }

cat > "$TMP/providers.toml" <<EOF
[[providers]]
name     = "Stub One"
type     = "openai_compatible"
key      = "stub-key"
endpoint = "http://127.0.0.1:$PORT/v1"
model    = "stub-model-a"

[[providers]]
name     = "Stub Two"
type     = "openai_compatible"
key      = "stub-key"
endpoint = "http://127.0.0.1:$PORT/v1"
model    = "stub-model-b"
EOF

cat > "$TMP/zygos.zon" <<EOF
.{
    .default = .{
        .{ .provider_function = "zygos::providers::stub-one", .model = "stub-model-a" },
    },
    .routes = .{
        .{ .step_id = "product-owner", .attempts = .{
            .{ .provider_function = "zygos::providers::stub-one", .model = "stub-model-a" },
        } },
        .{ .step_id = "planner", .attempts = .{
            .{ .provider_function = "zygos::providers::stub-two", .model = "stub-model-b" },
        } },
        .{ .step_id = "executor", .attempts = .{
            .{ .provider_function = "zygos::providers::stub-two", .model = "stub-model-b" },
        } },
        .{ .step_id = "verifier", .attempts = .{
            .{ .provider_function = "zygos::providers::stub-one", .model = "stub-model-a" },
        } },
    },
}
EOF

cat > "$TMP/brief.md" <<'EOF'
---
mission: m45-e2e
budget:
  max_tokens: 100000
gates:
  external_actions: human
---

# Mission: m45 e2e

## Objective

Ship the gizmo: write a greeting file and count to 500 in the workspace.

## Success criteria

| # | Criterion | Verified by |
|---|-----------|-------------|
| C1 | greeting.txt exists with "hello" | `cat greeting.txt` |

## Non-goals

- Anything beyond the two scripted tasks.
EOF

export AI_PROVIDERS_CONFIG="$TMP/providers.toml"
export ZYGOS_CONFIG="$TMP/zygos.zon"
export ZYGOS_APPROVAL_TIMEOUT_MS=15000
export ZYGOS_INVOKE_TIMEOUT_MS=60000

# ---- Leg 1: start → done (gate approved via piped stdin) ---------------------
mkdir -p "$TMP/ws"
( cd "$TMP/ws" && printf 'y\ny\ny\n' | "$BIN" mission start "$TMP/brief.md" --planning "$TMP/planning" > "$TMP/out1.json" 2> "$TMP/err1.log" )
grep -q '"state":"done"' "$TMP/out1.json" || { echo "M45 E2E FAIL leg1: $(cat "$TMP/out1.json")"; cat "$TMP/err1.log"; exit 1; }
[ "$(cat "$TMP/ws/greeting.txt")" = "hello" ] || { echo "M45 E2E FAIL leg1: greeting.txt missing/wrong"; exit 1; }
grep -q '"state":"done"' "$TMP/planning/mission.json" || { echo "M45 E2E FAIL leg1: substrate not terminal"; exit 1; }

# ---- Leg 2: a seeded mid-flight substrate resumes through the real CLI -------
# Seed exactly what a killed mission leaves: persisted `executing` state with
# the second task not yet done (the e2e/m3 leg-2 pattern, via the CLI).
cp "$TMP/brief.md" "$TMP/resume-brief.md"
mkdir -p "$TMP/planning2"
cat > "$TMP/planning2/mission.json" <<'EOF'
{"mission_id":"resume-brief","state":"executing","stop":"none","detail":"","objective":"Ship the gizmo","acceptance":"greeting written and count run","feedback":"","tasks":[{"desc":"write a greeting file","done":true},{"desc":"count to 500","done":false}],"task_index":1,"fail_count":0,"gate_denials":0,"role_turns_used":3}
EOF
printf '# Mission resume-brief\n\nShip the gizmo\n' > "$TMP/planning2/MISSION.md"
printf '# Plan\n\n- [x] write a greeting file\n- [ ] count to 500\n' > "$TMP/planning2/PLAN.md"

( cd "$TMP/ws" && printf 'y\ny\n' | "$BIN" mission resume "$TMP/resume-brief.md" --planning "$TMP/planning2" > "$TMP/out2.json" 2> "$TMP/err2.log" )
grep -q '"state":"done"' "$TMP/out2.json" || { echo "M45 E2E FAIL leg2: $(cat "$TMP/out2.json")"; cat "$TMP/err2.log"; exit 1; }

# ---- Leg 3: unknown slug in the route table refuses to boot (exit 2) ---------
cat > "$TMP/bad.zon" <<EOF
.{
    .default = .{
        .{ .provider_function = "zygos::providers::no-such-provider", .model = "m" },
    },
}
EOF
set +e
ZYGOS_CONFIG="$TMP/bad.zon" "$BIN" mission start "$TMP/brief.md" --planning "$TMP/planning3" > /dev/null 2> "$TMP/err3.log"
CODE=$?
set -e
[ "$CODE" = "2" ] || { echo "M45 E2E FAIL leg3: expected exit 2, got $CODE"; cat "$TMP/err3.log"; exit 1; }
grep -q "unknown zygos::providers" "$TMP/err3.log" || { echo "M45 E2E FAIL leg3: wrong error"; cat "$TMP/err3.log"; exit 1; }

# ---- Leg 4 (Y3): a non-resume start over an existing substrate refuses ------
set +e
( cd "$TMP/ws" && "$BIN" mission start "$TMP/brief.md" --planning "$TMP/planning" > /dev/null 2> "$TMP/err4.log" < /dev/null )
CODE=$?
set -e
[ "$CODE" = "2" ] || { echo "M45 E2E FAIL leg4: expected exit 2, got $CODE"; cat "$TMP/err4.log"; exit 1; }
grep -q "already holds a mission" "$TMP/err4.log" || { echo "M45 E2E FAIL leg4: wrong error"; cat "$TMP/err4.log"; exit 1; }

# ---- Leg 5 (Y5 seam): ZYGOS_VAULT_ROOT checkpoints the vault pre-mission -----
mkdir -p "$TMP/vault" "$TMP/ws5"
printf 'seed\n' > "$TMP/vault/seed.md"
( cd "$TMP/ws5" && printf 'y\ny\ny\n' | ZYGOS_VAULT_ROOT="$TMP/vault" "$BIN" mission start "$TMP/brief.md" --planning "$TMP/planning5" > "$TMP/out5.json" 2> "$TMP/err5.log" )
grep -q '"state":"done"' "$TMP/out5.json" || { echo "M45 E2E FAIL leg5: $(cat "$TMP/out5.json")"; cat "$TMP/err5.log"; exit 1; }
git --git-dir="$TMP/vault/.zygos-shadow" log --oneline | grep -q "brief" \
  || { echo "M45 E2E FAIL leg5: no pre-mission checkpoint in the vault shadow repo"; exit 1; }

# A vault root that cannot be checkpointed refuses the mission (fail closed).
set +e
( cd "$TMP/ws5" && ZYGOS_VAULT_ROOT="$TMP/no-such-vault" "$BIN" mission start "$TMP/brief.md" --planning "$TMP/planning6" > /dev/null 2> "$TMP/err6.log" < /dev/null )
CODE=$?
set -e
[ "$CODE" = "2" ] || { echo "M45 E2E FAIL leg5b: expected exit 2, got $CODE"; cat "$TMP/err6.log"; exit 1; }
grep -q "vault checkpoint" "$TMP/err6.log" || { echo "M45 E2E FAIL leg5b: wrong error"; cat "$TMP/err6.log"; exit 1; }

echo "M45 E2E OK: start→done, seeded resume→done, unknown-slug boot refusal, rerun refusal, vault checkpoint"
