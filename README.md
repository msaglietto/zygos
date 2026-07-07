# Zygos

A single-binary agent harness in Zig. Zygos reimplements the [iii](https://iii.dev)
engine kernel — workers connect over WebSocket and register *functions* and
*triggers* on one message bus — and (in later milestones) ships harness
capabilities as replaceable workers. Wire-compatible with the unmodified iii
SDKs. See `GOAL.md` for the mission, `docs/ARCHITECTURE.md` and
`docs/PROTOCOL.md` for the design, `docs/specs/` for per-module contracts.

## Status: M3 — mission loop (M0 kernel, M1 turn loop, M2 policy+routing closed)

| Milestone | Criterion | State |
|---|---|---|
| M0 | S1 wire protocol round-trip | ✅ 43 tests (`kernel/protocol.zig`) |
| M0 | S2 function catalog, owner CAS | ✅ 12 tests (`kernel/catalog.zig`) |
| M0 | S3 invocation router | ✅ 11 tests (`kernel/invocation.zig`) |
| M0 | S4 trigger registry | ✅ 14 tests (`kernel/trigger.zig`) |
| M0 | S5 keyed byte channels | ✅ 13 tests (`kernel/channel.zig`) |
| M0 | S6 unmodified Node SDK e2e | ✅ `test/e2e/node-sdk/run.sh` |
| M1 | T1 in-process bus workers | ✅ `kernel/inproc.zig` (frame-path peers, Outbound mux) |
| M1 | T2 turn FSM | ✅ `worker/turn.zig` (exhaustive legal/illegal transitions) |
| M1 | T3 provider-anthropic SSE | ✅ `worker/sse.zig` + `worker/anthropic.zig` (fixtures, no network) |
| M1 | T4 tool dispatch loop | ✅ turn driver tests (fake provider + fake tool) |
| M1 | T5 agent-tools worker | ✅ `worker/tools{,_ops}.zig` (workspace-confined bash/read/write) |
| M1 | T6 scripted turn e2e | ✅ `test/e2e/turn/run.sh` |
| M2 | U1 fail-closed policy gate | ✅ `worker/policy.zig` + turn-driver fail-closed tests |
| M2 | U2 approval worker, turns::abort/steer | ✅ `worker/approval.zig` (park/resolve/timeout) |
| M2 | U3 zygos.zon per-step routing + failover | ✅ `worker/router.zig` (`models::resolve`, escalation ladder) |
| M2 | U4 provider-openai (chat-completions SSE) | ✅ `worker/openai.zig` + `net/{openai,provider_openai}.zig` (fixtures, no network) |
| M2 | U5 budget enforcement | ✅ `worker/budget.zig` (`stop:"budget_exhausted"`, fail closed) |
| M2 | U6 output-trim (Z-09) + M2 e2e | ✅ `worker/trim.zig`; `test/e2e/m2/run.sh` |
| M3 | V1 mission FSM | ✅ `worker/mission.zig` (exhaustive legal/illegal transitions) |
| M3 | V2 durable `.planning/` substrate | ✅ `worker/mission_store.zig` (tmp+rename atomic saves) |
| M3 | V3 role turns (po/planner/executor/verifier) | ✅ per-role `step_id` routing, fail-closed output parsing |
| M3 | V4 missions::{start,status,abort} + resume | ✅ mission driver tests incl. mid-flight resume |
| M3 | V5 hard completion gate + escalation | ✅ fail-closed gate tests, verify/gate thresholds |
| M3 | V6 mission e2e + resume leg | ✅ `test/e2e/m3/run.sh` |

## Build & test

Requires Zig 0.16.0 (and libc — pthread + CSPRNG; macOS or Linux).

```bash
zig build test   # full suite (281 tests, leak-checked, no network)
zig build        # produces zig-out/bin/zygos
```

## Run

```bash
ZYGOS_PORT=49134 ./zig-out/bin/zygos   # 49134 is the iii SDK default
```

Any iii SDK connects unmodified:

```javascript
import { registerWorker } from 'iii-sdk'
const iii = registerWorker('ws://localhost:49134')
iii.registerFunction('hello::greet', async (input) => ({ hi: input.name }))
```

## S6 end-to-end test (documented run)

`test/e2e/node-sdk/run.sh` builds the binary, starts a kernel on a scratch
port (`ZYGOS_PORT`, default 49142), `npm install`s the **unmodified**
`iii-sdk` package from npm, and runs `e2e.mjs`: worker A registers
`echo::reverse`, worker B invokes it through the kernel and asserts the
result. Exits nonzero on any failure.

```console
$ ./test/e2e/node-sdk/run.sh
[iii] Worker registered with ID: 8f55dac3-0881-4d07-87ca-687ffbd67044
[iii] Worker registered with ID: 2c46efc0-e598-4fd6-8428-4d90e9a302ac
E2E OK: {"reversed":"sogyz"}
S6 e2e passed on port 49142
```

Requires `node` + `npm` on PATH (network on first run for the SDK install).

## M1 turn-loop e2e (documented run)

`test/e2e/turn/run.sh` (= `zig build e2e-turn`) runs a scripted 2-step
tool-use turn through the full M1 stack in one process: kernel actor, inproc
bus workers, turn FSM driver, a fake provider streaming deltas over a kernel
channel, and the **real** `zygos::tools::bash` tool in a scratch workspace.

```console
$ ./test/e2e/turn/run.sh
TURN E2E OK: stop=end_turn steps=2 deltas="hello worldhello world"
```

The real Anthropic provider (`net/anthropic.zig` + `net/provider_anthropic.zig`)
is exercised only by an env-gated manual smoke — one real streaming API call:

```bash
ANTHROPIC_API_KEY=... ./test/e2e/anthropic/run.sh   # zig build smoke-anthropic
```

It exits 2 (skipped) without the key and is never part of `zig build test`.
The openai-compat provider has the same arrangement (`OPENAI_BASE_URL` points
it at any chat-completions-compatible endpoint):

```bash
OPENAI_API_KEY=... ./test/e2e/openai/run.sh   # zig build smoke-openai
```

## M2 policy+routing e2e (documented run)

`test/e2e/m2/run.sh` (= `zig build e2e-m2`) runs a scripted 2-step tool-use
turn through the full M2 stack in one process: the fail-closed policy gate
(`ask` verdict on bash), the approval worker, `zygos.zon` routing parsed from
a real file (`models::resolve`), budget enforcement with per-step usage
accounting, and the Z-09 output-trim filter compressing the real bash tool's
500-line output on the `zygos::output::compress` seam — savings reported to
`zygos::budget::record`.

```console
$ ./test/e2e/m2/run.sh
M2 E2E OK: stop=end_turn steps=2 used_tokens=30 saved_bytes=1861
```

## M3 mission-loop e2e (documented run)

`test/e2e/m3/run.sh` (= `zig build e2e-m3`) runs the mission loop over the
full M2+M3 stack in one process, in two legs. Leg 1: a scripted mission
(`zygos::missions::start`) walks define → plan → execute → verify → gate to
`done` — the product-owner/planner/executor/verifier roles each run as one
turn routed per-role through `zygos.zon` (`models::resolve`), the **real**
bash tool executes both plan tasks in a scratch workspace behind the
fail-closed policy gate (`ask` → approval worker), budget accounting sees
every role turn, the Z-09 trim seam compresses the 500-line task output, and
the hard completion gate goes through a real `zygos::approvals::request`
call. Leg 2: a **fresh** orchestrator instance resumes a mid-flight
`.planning/` substrate (`resume:true`) and finishes it without re-running
the earlier roles.

```console
$ ./test/e2e/m3/run.sh
M3 E2E OK: live=done/completed resumed=done/completed role_turns=5+5 used_tokens=105 saved_bytes=1861
```
