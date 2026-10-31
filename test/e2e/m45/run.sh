#!/usr/bin/env bash
# X3 e2e (GOAL.md M4.5, docs/specs/mission-cli.md): the `zygos mission` CLI
# against a localhost SSE stub. Legs: (1) start → done via the real
# binary, catalog providers, console gate approved over piped stdin;
# (2) seeded mid-flight substrate finished by `zygos mission resume`;
# (3) a route table naming an unknown slug exits 2 before any kernel boot;
# (8) a malformed `.policy` exits 2 before any kernel boot (an MCP server
# whose spawn leaves a marker proves it was never spawned), a `.policy` rule
# naming no offered tool exits 2 after the handshake (same marker proves the
# MCP server WAS spawned) but before the mission store is written, and a valid
# `.policy` lands in the trace as a `policy` event right after `pipeline`;
# (9) a `.policy` ask on `bash` answered y then n over piped stdin leaves two
# approval_asked/approval_decided pairs (allowed_once, rejected) in the trace,
# the console prompt shows each input, and the rejected call's tool_result is
# `approval_denied`.
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

# M8: the ledger the operator reads must carry the compression rollup, and the
# filters must have actually engaged on a real command through the real binary
# — the last link in the chain that unit tests, the probe and e2e/m8 each cover
# only in part.
[ -f "$TMP/planning/LEDGER.md" ] || { echo "M45 E2E FAIL leg1: no LEDGER.md"; exit 1; }
grep -q 'Tool-output compression' "$TMP/planning/LEDGER.md" || {
  echo "M45 E2E FAIL leg1: ledger has no compression section"; cat "$TMP/planning/LEDGER.md"; exit 1; }
grep -qE '^filtered: [1-9]' "$TMP/planning/LEDGER.md" || {
  echo "M45 E2E FAIL leg1: no tool output was filtered in a real mission"; cat "$TMP/planning/LEDGER.md"; exit 1; }
grep -qE '^reduction: [0-9]+%' "$TMP/planning/LEDGER.md" || {
  echo "M45 E2E FAIL leg1: ledger reports no reduction"; cat "$TMP/planning/LEDGER.md"; exit 1; }

# ---- Leg 2: a seeded mid-flight substrate resumes through the real CLI -------
# Seed exactly what a killed mission leaves: persisted `running` state at the
# executor step (index 2) with the second task not yet done (the e2e/m3 leg-2
# pattern, via the CLI).
cp "$TMP/brief.md" "$TMP/resume-brief.md"
mkdir -p "$TMP/planning2"
cat > "$TMP/planning2/mission.json" <<'EOF'
{"mission_id":"resume-brief","state":"running","step_index":2,"stop":"none","detail":"","objective":"Ship the gizmo","acceptance":"greeting written and count run","feedback":"","tasks":[{"desc":"write a greeting file","done":true},{"desc":"count to 500","done":false}],"task_index":1,"fail_count":0,"gate_denials":0,"role_turns_used":3}
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

# ---- Leg 6: mission trace — events.jsonl written and rendered ----------------
[ -s "$TMP/planning/events.jsonl" ] || { echo "M45 E2E FAIL leg6: no events.jsonl in the planning root"; exit 1; }
grep -q '"event":"role_start"' "$TMP/planning/events.jsonl" || { echo "M45 E2E FAIL leg6: no role events"; exit 1; }
grep -q '"event":"tool_call"' "$TMP/planning/events.jsonl" || { echo "M45 E2E FAIL leg6: no tool_call events"; exit 1; }
"$BIN" mission trace "$TMP/planning" > "$TMP/trace.txt"
grep -q "role product-owner" "$TMP/trace.txt" || { echo "M45 E2E FAIL leg6: renderer missing roles"; exit 1; }
grep -q "tool bash" "$TMP/trace.txt" || { echo "M45 E2E FAIL leg6: renderer missing tool calls"; exit 1; }

# ---- Leg 7: MCP servers from zygos.zon boot onto the bus ----------------------
cat > "$TMP/mcp-stub.sh" <<'EOF'
#!/bin/sh
while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
  case "$line" in
    *'"initialize"'*) printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"protocolVersion\":\"2025-06-18\"}}" ;;
    *'tools/list'*)   printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"tools\":[{\"name\":\"lookup\"}]}}" ;;
    *'tools/call'*)   printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"stub says hi\"}],\"isError\":false}}" ;;
  esac
done
EOF
chmod +x "$TMP/mcp-stub.sh"
sed '$d' "$TMP/zygos.zon" > "$TMP/zygos-mcp.zon" # drop the closing brace…
cat >> "$TMP/zygos-mcp.zon" <<EOF
    .mcp_servers = .{ .{ .name = "stub", .argv = .{ "$TMP/mcp-stub.sh" } } },
}
EOF
mkdir -p "$TMP/ws7"
( cd "$TMP/ws7" && printf 'y\ny\ny\n' | ZYGOS_CONFIG="$TMP/zygos-mcp.zon" ZYGOS_LOG=info \
    "$BIN" mission start "$TMP/brief.md" --planning "$TMP/planning7" > "$TMP/out7.json" 2> "$TMP/err7.log" )
grep -q '"state":"done"' "$TMP/out7.json" || { echo "M45 E2E FAIL leg7: $(cat "$TMP/out7.json")"; cat "$TMP/err7.log"; exit 1; }
grep -q "registered zygos::mcp::stub::lookup" "$TMP/err7.log" \
  || { echo "M45 E2E FAIL leg7: MCP tool not registered"; cat "$TMP/err7.log"; exit 1; }

# A configured-but-broken MCP server refuses the run (fail closed).
cat > "$TMP/zygos-mcp-bad.zon" <<EOF
.{
    .default = .{ .{ .provider_function = "zygos::providers::stub-one", .model = "stub-model-a" } },
    .mcp_servers = .{ .{ .name = "dead", .argv = .{ "/bin/sh", "-c", "exit 0" } } },
}
EOF
set +e
( cd "$TMP/ws7" && ZYGOS_CONFIG="$TMP/zygos-mcp-bad.zon" "$BIN" mission start "$TMP/brief.md" --planning "$TMP/planning8" > /dev/null 2> "$TMP/err8.log" < /dev/null )
CODE=$?
set -e
[ "$CODE" = "2" ] || { echo "M45 E2E FAIL leg7b: expected exit 2, got $CODE"; cat "$TMP/err8.log"; exit 1; }
grep -q "MCP server handshake failed" "$TMP/err8.log" || { echo "M45 E2E FAIL leg7b: wrong error"; cat "$TMP/err8.log"; exit 1; }

# ---- Leg 8 (policy-config): an invalid .policy refuses the mission (exit 2) ---
# Each of 8a/8b configures an MCP server through a wrapper that touches a marker
# file and then execs the working stub from leg 7. The marker is the witness of
# "the MCP server was spawned", so the refusal point is observable: absent for
# a pre-boot refusal, present for a post-handshake one.
cat > "$TMP/mcp-marker.sh" <<'EOF'
#!/bin/sh
touch "$1"
shift
exec "$@"
EOF
chmod +x "$TMP/mcp-marker.sh"

# 8a: a malformed entry refuses before the kernel boots, so no trace exists and
# the MCP server was never spawned.
cat > "$TMP/zygos-policy-bad.zon" <<EOF
.{
    .default = .{ .{ .provider_function = "zygos::providers::stub-one", .model = "stub-model-a" } },
    .mcp_servers = .{ .{ .name = "stub", .argv = .{ "$TMP/mcp-marker.sh", "$TMP/mcp-spawned-8a", "$TMP/mcp-stub.sh" } } },
    .policy = .{ .{ .tool = "bash", .verdict = "allow" } },
}
EOF
mkdir -p "$TMP/ws8"
set +e
( cd "$TMP/ws8" && ZYGOS_CONFIG="$TMP/zygos-policy-bad.zon" "$BIN" mission start "$TMP/brief.md" --planning "$TMP/planning9" > /dev/null 2> "$TMP/err9.log" < /dev/null )
CODE=$?
set -e
[ "$CODE" = "2" ] || { echo "M45 E2E FAIL leg8a: expected exit 2, got $CODE"; cat "$TMP/err9.log"; exit 1; }
grep -q "invalid .policy" "$TMP/err9.log" || { echo "M45 E2E FAIL leg8a: wrong error"; cat "$TMP/err9.log"; exit 1; }
grep -qF 'policy[0]: bad verdict' "$TMP/err9.log" || { echo "M45 E2E FAIL leg8a: reason does not name the entry"; cat "$TMP/err9.log"; exit 1; }
[ ! -e "$TMP/planning9/events.jsonl" ] || { echo "M45 E2E FAIL leg8a: kernel booted (events.jsonl exists)"; exit 1; }
[ ! -e "$TMP/mcp-spawned-8a" ] || { echo "M45 E2E FAIL leg8a: MCP server spawned before the refusal"; exit 1; }

# 8b: a rule naming a tool no step is offered refuses after the handshake but
# before the mission store is written. The MCP server was spawned first.
cat > "$TMP/zygos-policy-dead.zon" <<EOF
.{
    .default = .{ .{ .provider_function = "zygos::providers::stub-one", .model = "stub-model-a" } },
    .mcp_servers = .{ .{ .name = "stub", .argv = .{ "$TMP/mcp-marker.sh", "$TMP/mcp-spawned-8b", "$TMP/mcp-stub.sh" } } },
    .policy = .{ .{ .tool = "read_file", .verdict = .allow } },
}
EOF
set +e
( cd "$TMP/ws8" && ZYGOS_CONFIG="$TMP/zygos-policy-dead.zon" "$BIN" mission start "$TMP/brief.md" --planning "$TMP/planning10" > /dev/null 2> "$TMP/err10.log" < /dev/null )
CODE=$?
set -e
[ "$CODE" = "2" ] || { echo "M45 E2E FAIL leg8b: expected exit 2, got $CODE"; cat "$TMP/err10.log"; exit 1; }
grep -q 'invalid .policy' "$TMP/err10.log" || { echo "M45 E2E FAIL leg8b: wrong error"; cat "$TMP/err10.log"; exit 1; }
grep -qF 'policy[0]: tool "read_file" matches no offered tool' "$TMP/err10.log" || { echo "M45 E2E FAIL leg8b: wrong reason"; cat "$TMP/err10.log"; exit 1; }
[ -e "$TMP/mcp-spawned-8b" ] || { echo "M45 E2E FAIL leg8b: MCP server was not spawned before the refusal"; exit 1; }
[ ! -e "$TMP/planning10/events.jsonl" ] || { echo "M45 E2E FAIL leg8b: trace written before the refusal"; exit 1; }
[ ! -e "$TMP/planning10/mission.json" ] || { echo "M45 E2E FAIL leg8b: mission store written before the refusal"; exit 1; }

# 8c: a valid .policy runs the mission and the trace carries a `policy` event
# right after `pipeline`, with the configured rules in file order. This proves
# the CLI wires the rule list into the start request.
cat > "$TMP/zygos-policy-ok.zon" <<EOF
.{
    .default = .{ .{ .provider_function = "zygos::providers::stub-one", .model = "stub-model-a" } },
    .policy = .{
        .{ .tool = "web_*", .verdict = .deny, .step = "verifier" },
        .{ .tool = "bash", .verdict = .allow },
    },
}
EOF
mkdir -p "$TMP/ws8c"
( cd "$TMP/ws8c" && printf 'y\ny\ny\n' | ZYGOS_CONFIG="$TMP/zygos-policy-ok.zon" "$BIN" mission start "$TMP/brief.md" --planning "$TMP/planning11" > "$TMP/out11.json" 2> "$TMP/err11.log" )
grep -q '"state":"done"' "$TMP/out11.json" || { echo "M45 E2E FAIL leg8c: $(cat "$TMP/out11.json")"; cat "$TMP/err11.log"; exit 1; }
[ -s "$TMP/planning11/events.jsonl" ] || { echo "M45 E2E FAIL leg8c: no events.jsonl"; exit 1; }
sed -n 1p "$TMP/planning11/events.jsonl" | grep -q '"event":"pipeline"' || { echo "M45 E2E FAIL leg8c: first event is not pipeline"; head -2 "$TMP/planning11/events.jsonl"; exit 1; }
POLICY_LINE=$(sed -n 2p "$TMP/planning11/events.jsonl")
EXPECT='"event":"policy","source":"config","rules":[{"tool":"web_*","verdict":"deny","step":"verifier"},{"tool":"bash","verdict":"allow","step":null}]'
case "$POLICY_LINE" in
  *"$EXPECT"*) ;;
  *) echo "M45 E2E FAIL leg8c: second event is not the configured policy"; echo "$POLICY_LINE"; exit 1 ;;
esac
# A mission with no .policy (leg 1) traces no policy event.
! grep -q '"event":"policy"' "$TMP/planning/events.jsonl" || { echo "M45 E2E FAIL leg8c: absent .policy traced a policy event"; exit 1; }

# ---- Leg 9 (approval outcomes): a policy ask approved once, rejected once ----
# `bash` is `.ask`; the scripted executor calls bash twice. Piped stdin answers
# the console prompts in order: y (first ask), n (second ask), y (completion
# gate). Policy asks and the gate share stdin (docs/specs/policy-config.md,
# "Known limits"), so the answer count is part of the contract.
cat > "$TMP/zygos-policy-ask.zon" <<EOF
.{
    .default = .{ .{ .provider_function = "zygos::providers::stub-one", .model = "stub-model-a" } },
    .policy = .{
        .{ .tool = "bash", .verdict = .ask },
    },
}
EOF
mkdir -p "$TMP/ws9"
set +e
( cd "$TMP/ws9" && printf 'y\nn\ny\n' | ZYGOS_CONFIG="$TMP/zygos-policy-ask.zon" "$BIN" mission start "$TMP/brief.md" --planning "$TMP/planning12" > "$TMP/out12.json" 2> "$TMP/err12.log" )
CODE=$?
set -e
[ "$CODE" = "0" ] || { echo "M45 E2E FAIL leg9: expected exit 0, got $CODE"; cat "$TMP/out12.json"; cat "$TMP/err12.log"; exit 1; }
grep -q '"state":"done"' "$TMP/out12.json" || { echo "M45 E2E FAIL leg9: mission not done: $(cat "$TMP/out12.json")"; cat "$TMP/err12.log"; exit 1; }
grep -qF 'approve bash [step executor] {"command":"echo approved-run"}' "$TMP/err12.log" \
  || { echo "M45 E2E FAIL leg9: no console prompt with the first input"; cat "$TMP/err12.log"; exit 1; }
grep -qF 'approve bash [step executor] {"command":"echo rejected-run"}' "$TMP/err12.log" \
  || { echo "M45 E2E FAIL leg9: no console prompt with the second input"; cat "$TMP/err12.log"; exit 1; }
cat > "$TMP/leg9-check.js" <<'EOF'
const fs = require('fs');
const ev = fs.readFileSync(process.argv[2], 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
const fail = (m) => { console.error('M45 E2E FAIL leg9: ' + m); process.exit(1); };
const asked = ev.map((e, i) => [e, i]).filter(([e]) => e.event === 'approval_asked');
const decided = ev.map((e, i) => [e, i]).filter(([e]) => e.event === 'approval_decided');
if (asked.length !== 2 || decided.length !== 2) fail('want 2 asked + 2 decided, got ' + asked.length + '/' + decided.length);
const want = [['echo approved-run', 'allowed_once', false], ['echo rejected-run', 'rejected', true]];
want.forEach(([cmd, outcome, isErr], n) => {
  const [a, ai] = asked[n];
  const [d, di] = decided[n];
  if (!a.input.includes(cmd)) fail('asked[' + n + '] input lacks ' + cmd + ': ' + a.input);
  if (d.id !== a.id) fail('decided[' + n + '] id ' + d.id + ' != asked id ' + a.id);
  if (d.outcome !== outcome) fail('decided[' + n + '] outcome ' + d.outcome + ' != ' + outcome);
  if (!(ai < di)) fail('asked[' + n + '] does not precede its decided');
  const tr = ev.slice(di + 1).find((e) => e.event === 'tool_result');
  if (!tr) fail('no tool_result after decided[' + n + ']');
  if (tr.is_error !== isErr) fail('tool_result[' + n + '] is_error ' + tr.is_error + ' != ' + isErr);
  if (isErr) {
    if (tr.output !== 'approval_denied') fail('rejected tool_result output ' + JSON.stringify(tr.output));
  } else if (!tr.output.includes('approved-run')) fail('approved tool_result lacks approved-run: ' + JSON.stringify(tr.output));
});
EOF
node "$TMP/leg9-check.js" "$TMP/planning12/events.jsonl" || { cat "$TMP/planning12/events.jsonl"; exit 1; }
"$BIN" mission trace "$TMP/planning12" > "$TMP/trace12.txt"
grep -qE '\? approval a-' "$TMP/trace12.txt" || { echo "M45 E2E FAIL leg9: trace has no '? approval a-' line"; cat "$TMP/trace12.txt"; exit 1; }
grep -qE '✓ approval' "$TMP/trace12.txt" || { echo "M45 E2E FAIL leg9: trace has no approved decision line"; cat "$TMP/trace12.txt"; exit 1; }
grep -qE '✗ approval .*rejected' "$TMP/trace12.txt" || { echo "M45 E2E FAIL leg9: trace has no rejected decision line"; cat "$TMP/trace12.txt"; exit 1; }
echo "--- leg 9 prompts (stderr) ---"
grep -F 'approve bash' "$TMP/err12.log" || true
echo "--- leg 9 trace approval lines ---"
grep -E 'approval' "$TMP/trace12.txt"

echo "--- LEDGER.md (leg 1, from the real binary) ---"
cat "$TMP/planning/LEDGER.md"
echo "M45 E2E OK: start→done, seeded resume→done, unknown-slug boot refusal, rerun refusal, vault checkpoint, trace, mcp, ledger compression, invalid .policy refusals, valid .policy traced, policy ask approved once and rejected once"
