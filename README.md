# Zygos

A single-binary agent harness in Zig. Zygos reimplements the [iii](https://iii.dev)
engine kernel — workers connect over WebSocket and register *functions* and
*triggers* on one message bus — and (in later milestones) ships harness
capabilities as replaceable workers. Wire-compatible with the unmodified iii
SDKs. See `GOAL.md` for the mission, `docs/ARCHITECTURE.md` and
`docs/PROTOCOL.md` for the design, `docs/specs/` for per-module contracts.

## Status: M4.6 — zahir-radar workload (M0–M4.5 closed)

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
| M4 | W1 mission brief validation | ✅ `worker/brief.zig` (fail-closed lint before the FSM) |
| M4 | W2 tessera-orient worker | ✅ `worker/tessera_orient.zig` + `worker/tessera/vault.zig` (fixture vault only) |
| M4 | W3 tessera-continuity + mission auto-log | ✅ `worker/tessera_continuity.zig` + `worker/tessera/session_writer.zig`; continuity seam in the mission driver |
| M4 | W4 tessera-capture (taxonomy from config) | ✅ `worker/tessera_capture.zig` (full fallback, capture never lost) |
| M4 | W5 tessera-undo (shadow git) | ✅ `worker/tessera_undo.zig` (`.zygos-shadow`, checkpoint/undo) |
| M4 | W6 mcp-gateway + M4 e2e | ✅ `worker/mcp/gateway.zig` + `zygos mcp-gateway`; `test/e2e/m4/run.sh` |
| M4.5 | X1 provider catalog (`~/.agents/providers.toml`) | ✅ `config/providers.zig` (TOML subset, fail-closed validation) |
| M4.5 | X2 catalog → bus boot (`zygos::providers::<slug>`) | ✅ `net/provider_boot.zig` (Gemini compat base, checkRoutes refusal) |
| M4.5 | X3 `zygos mission start/resume` CLI | ✅ `cli/mission.zig`; `test/e2e/m45/run.sh` |
| M4.5 | X4 multi-provider smoke (env-gated) | ✅ `test/smoke/providers.sh` (manual, real keys) |
| M4.5 | X5 dogfood exit (real autonomous mission) | ✅ verified 2026-07-10 (see below) |
| M4.6 | Y1 web-tools worker (`web_search`/`web_fetch`) | ✅ `net/web_tools.zig` (fixture-tested, no sockets) |
| M4.6 | Y2 web tools through policy/trim/budget gates | ✅ turn-level policy-URL test + existing seams |
| M4.6 | Y3 unattended reruns + cron recipe | ✅ refuse-if-existing, `--run-stamp`; recipe below |
| M4.6 | Y4 zahir-radar Brief 2 → Z-08 mission brief | ✅ `examples/zahir-radar/` (passes W1 lint) |
| M4.6 | Y5 unattended run vs the real Zahir vault | ⏳ human gate — staged, awaiting Mauricio |

## Build & test

Requires Zig 0.16.0 (and libc — pthread + CSPRNG; macOS or Linux).

```bash
zig build test   # full suite (872 tests, leak-checked, no network)
zig build        # produces zig-out/bin/zygos
```

## Run

```bash
ZYGOS_PORT=49134 ./zig-out/bin/zygos   # 49134 is the iii SDK default
```

## Headless task (offline)

`zygos task` is the entry a benchmark runner calls. It is not a mission: there is no product-owner gate, and exit 0 means the process finished, not that the task succeeded.

```bash
zygos task run --offline --workspace DIR --out trial.json --events events.jsonl
zygos task score --trial trial.json --prices prices.txt
```

`--offline` selects the scripted provider. Live runs require an allowlisted model and a complete invocation; the current Deepseek Flash campaign has standing authorization under [Benchmark operating policy](docs/benchmark-policy.md). Agents review and record evidence at phase boundaries and advance without asking for permission each time. The trial pins the git sha, target triple, optimize level, and adapter version. Bench policy allows only bash, read, and write inside the workspace. Mission policy is unchanged.

`eval/run.sh --dry-run` prints the pinned dataset `terminal-bench/terminal-bench-2-1` and the task command. It is not part of `zig build test`. The contract is `docs/specs/task.md`.

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

## M4 tessera e2e (documented run)

`test/e2e/m4/run.sh` runs two legs against one temp vault. Leg 1
(`zig build e2e-m4`): a scripted mission runs to `done` with the W3
continuity seam (`continuity_function` + `continuity_project` on
`zygos::missions::start`) — the terminal mission session-closes over the bus
and the harness, not a model, writes the `SESSIONS.md` entry (phase log,
accomplished, leaving-behind). Leg 2: this script acts as an **external MCP
client**, piping a newline-JSON session (initialize → tools/list →
tools/call `tessera_project_status`) into a separate `zygos mcp-gateway`
process (stdio transport, `ZYGOS_VAULT_ROOT` pointing at the same vault) and
asserts the auto-logged entry comes back; an unknown tool must return a
JSON-RPC `-32602` error (fail closed).

```console
$ ./test/e2e/m4/run.sh
M4 E2E leg 1 OK: mission auto-logged .../Projects/zygos-e2e/SESSIONS.md
M4 E2E OK: mission auto-log read back through the MCP gateway
```

## M4.5 mission CLI e2e (documented run)

`test/e2e/m45/run.sh` drives the real binary — `zygos mission start <brief.md>`
— against a localhost SSE stub (node, 127.0.0.1) named by a fixture
`~/.agents/providers.toml`-shaped catalog. Leg 1: brief lint → catalog +
route-table boot (`zygos::providers::<slug>` instances) → the full mission
loop to `state:"done"`, with the completion gate approved over piped stdin
and the real bash tool writing into the workspace. Leg 2: a seeded mid-flight
`.planning/` substrate finishes through `zygos mission resume` (earlier roles
not re-run). Leg 3: a route table naming an unknown provider slug exits 2
before any kernel boots (fail closed).

```console
$ ./test/e2e/m45/run.sh
M45 E2E OK: start→done, seeded resume→done, unknown-slug boot refusal
```

The CLI reads the provider catalog from `AI_PROVIDERS_CONFIG` (else
`~/.agents/providers.toml`) and the route table from `ZYGOS_CONFIG` (else
`./zygos.zon`); approvals prompt on stderr and fail closed (manual timeout
denies) when stdin closes. Knobs: `ZYGOS_APPROVAL_TIMEOUT_MS`,
`ZYGOS_INVOKE_TIMEOUT_MS`, `ZYGOS_BUDGET_MAX_TOKENS`, `ZYGOS_ROLE_MAX_STEPS`
(default 24), `ZYGOS_MAX_ROLE_TURNS` (default 48); web-search backend via
`ZYGOS_SEARCH_ENGINE`/`ZYGOS_SEARCH_ENDPOINT`/`ZYGOS_SEARCH_KEY_ENV`
(brave/searxng). Brave resolves that key variable into `SearchConfig.key`
at boot (`searchConfigFromEnv`); an unset key fails each search with
`MissingSearchKey` and does not fail boot. Debugging: `ZYGOS_LOG=info`
streams the harness's progress feed (mission transitions, role turns,
per-step provider/model, tool dispatches) to stderr; `debug` for more.

Timeouts are tiered — one flat deadline cannot serve both a whole mission
and the calls inside it:

- `ZYGOS_MISSION_TIMEOUT_MS` (default 24h) — ceiling on the blocking
  mission call itself; the only knob that bounds total mission duration.
- `ZYGOS_INVOKE_TIMEOUT_MS` (default 1h) — every other bus invocation
  (role turns, provider calls, gates). A provider call that times out
  escalates the route ladder like any provider failure.
- `ZYGOS_STREAM_IDLE_MS` (default 120s, `0` disables) — HTTP-level idle
  guard on provider streams: a connection that goes this long without
  sending a byte is shut down and the call fails over. This is the hang
  protection; the invoke timeout is only the outer net.

`test/e2e/timeouts/run.sh` locks the contract in: a silent localhost
provider (accepts, never responds) must trip the idle guard, must not let
a tight invoke timeout kill the mission call, and must still honor the
mission ceiling.

## M8 output-compression e2e (documented run)

`test/e2e/m8/run.sh` (= `zig build e2e-m8`) proves decision Z-09's
command-aware half (M8). It builds a **real** scratch git repo with a real
uncommitted change, then runs the turn loop with the **real** bash tool
executing real `git` commands, and asserts four things a fixture cannot:
the driver's seam context reaches the filter dispatcher, a repeated
`git status` collapses to a one-line "unchanged" reply, `raw: true` in the
tool input bypasses compression entirely, and the savings reach the budget
ledger.

This leg found what 731 unit tests could not: the filters were **inert on the
real path**, because every tool replies with a JSON envelope
(`{"exit_code":0,"output":"..."}`) that the structured-data guard skipped —
and trimming that envelope generically handed the model unparseable JSON. A
fixture proves the algorithm; only a real command proves the wiring.

```console
$ ./test/e2e/m8/run.sh
M8 E2E OK: real git output 1013 -> 378 bytes (63% saved), filtered=2 deduped=1 budget_saved=680
```

`zig build filter-probe` measures the filters against a mix of real commands
on this repo — a measurement tool, not a gate. Its first run reported 6%, with
four of six filters silently declining on real output that every fixture had
passed:

```console
$ zig build filter-probe
command                          raw  filtered   saved  filter
--------------------------------------------------------------------------
git status                       557       239    +57%  git_status
git log -20                    15141      1627    +89%  git_log
git diff HEAD~1                19957     17584    +11%  git_diff
ls -la src/worker               2430       537    +77%  listing
find src -name *.zig            1945      1945     +0%  listing
zig build test                 10081      2194    +78%  testrun
--------------------------------------------------------------------------
TOTAL                          50111     24126     51%
```

`find` declines because there is nothing to strip, and that `git diff` is 84%
real changes — the filters do not invent savings where there is no noise.

`./test/mutation/guards.sh` deletes each load-bearing guard in turn and
requires `zig build test` to go red for every one. It exists because two M8
tests passed with the invariant they claimed to protect deleted:

```console
$ ./test/mutation/guards.sh
KILLED guard: diff-payload skip in hasErrorSignal
KILLED guard: error signals bail out git/listing
KILLED guard: small-output threshold
KILLED guard: structured output is never reshaped
KILLED guard: keepIfSmaller rejects non-savings
KILLED trim: UTF-8 boundary walk in byteFallback
KILLED trim: stats mutex in note()
KILLED turn: raw:true bypasses the seam
KILLED turn: seam carries the tool name

MUTATION CHECK OK: every guard is pinned by a test that detects its removal.
```

The per-mission rollup lands in `LEDGER.md` at terminal state. This is real
output from `zygos mission start` in `test/e2e/m45` — the actual binary, the
real bash tool, the ledger an operator reads:

```
# Ledger — brief

used_tokens: 105
saved_bytes: 55861
role_turns: 5
state: done (completed)

## Tool-output compression

calls: 2
filtered: 1
deduped: 0
raw_bytes: 57214
sent_bytes: 2079
reduction: 96%
```

## Mission TUI — live progress view

When `zygos mission start` runs on a real terminal (tty on stdin and
stderr), it takes over the screen with a live progress view instead of the
plain banner: a header with mission state, tasks, and elapsed time (the
spinner rides the status line); an objective echo; a live current-task line
that collapses to a dim `✓` line when the task lands; role/step lines with
the routed model; a **live `❙ Thinking…` block** streaming the model's
reasoning (anthropic `thinking_delta`, openai-compatible `reasoning_content`
— DeepSeek/GLM/Minimax) that collapses to `◆ Thought for Ns` in history;
**rail-guttered live tool entries** (`┃`) showing the command/file being
composed as the arguments stream (extracted from the partial JSON); running
tool calls that collapse into `◆`/`✗` summary lines as results land;
assistant tokens streaming at full color, promoted answers rendered
markdown-lite (headers, bold, bullets, numbered lists, fenced code with
keyword syntax highlighting on a panel background); captured warn/err log
lines as dim footnotes; and a token counter fed by per-step `usage` trace
events. Truecolor when `COLORTERM` says so, indexed-256 fallback otherwise.
History scrolls into the terminal's own scrollback (no alternate screen) —
only the bottom band repaints, wrapped in synchronized output (`?2026`).

Approvals resolve on a single keypress: the pending ask renders as a
highlighted keys-first `[y/N] approve? <summary>` band (`y` approves; `n`,
Enter, or the server-side `ZYGOS_APPROVAL_TIMEOUT_MS` denies — fail
closed). Ctrl-C restores the terminal before exiting; a panic path
(`emergencyRestore`) repairs the terminal too. While the TUI owns fd 2,
stray stderr writers are redirected to a log file; `ZYGOS_TUI_CAPTURE=<path>`
tees raw frames for debugging. The final mission JSON still prints to
stdout after the TUI tears down, so `| jq` pipelines and exit codes are
unchanged.

Opt out with `--no-tui` or `ZYGOS_NO_TUI=1`; piped/CI runs (no tty) keep
the plain path automatically — the `trace →` banner, stderr approval
prompts, and stdout JSON are byte-identical to before. The TUI is a second
consumer of the same trace event stream (`src/worker/trace.zig` sinks) plus
a live delta observer on the turn loop; rendering is hand-rolled ANSI in
`src/tui/` (no deps, libc terminal control confined there like the `net/`
exception).

## Mission trace — the harness view

Every `zygos mission start` writes a structured event log to
`<planning>/events.jsonl`: mission transitions, role boundaries, per-step
provider/model, and **every tool call with its input and (clipped) output**.
Emission is fail-open — an unwritable trace never changes a run's outcome.
Render it live or post-mortem:

```console
$ zygos mission trace .planning-20260711-015510
02:13:20 ── role executor (turn 3, tools on)
02:13:22   step 1: glm-5.2 via zygos::providers::glm-5-2
02:13:23     tool web_search {"query":"neural provers 2026"}
02:13:24       → 5120B: [{"title":"DeepSeek-Prover-V4"},...]
02:13:25   turn end: max_steps (24 steps)
02:13:26 ── role executor: failed — executor turn stopped: max_steps
```

`zig build test` covers the emitters (turn + mission drivers) and the
renderer; the raw JSONL is the source of truth, the renderer never hides
unparseable lines.

## MCP servers as tool providers

`zygos.zon` may carry an `.mcp_servers` table; each entry is spawned over
stdio (JSON-RPC 2.0, MCP `2025-06-18`), handshaken, and its tools registered
on the bus as `zygos::mcp::<server>::<tool>` — exposed to the model as
`<server>_<tool>` and riding the same policy/trim/budget gates as native
tools (Y2 semantics). A configured-but-broken server refuses the run at boot
(fail closed); a server dying mid-run yields structured
`{"error":"McpServerUnavailable"}` tool results, never a hang.

```zon
.{
    .routes = .{ ... },
    .mcp_servers = .{
        .{ .name = "tavily", .argv = .{ "npx", "-y", "tavily-mcp" } },
    },
}
```

The X4 companion is a manual smoke over the **real** catalog — two turns
routed to two different live providers:

```bash
./test/smoke/providers.sh                  # auto-picks two keyed entries
zig build smoke-providers -- <slug-a> <slug-b>
```

## Scheduled (unattended) missions — the Y3 recipe

The weekly-trigger decision (M4.6/Y3): scheduling lives **outside** the
binary — cron/launchd invoke the CLI; the kernel stays schedule-free. The
CLI's guarantees make this safe unattended: approvals fail closed on a
closed stdin, a non-resume start over an existing substrate refuses (exit 2)
instead of clobbering it, and `--run-stamp` gives every invocation its own
planning root (`<root>-YYYYMMDD-HHMMSS`).

```cron
# weekly zahir-radar refresh, Mondays 07:00 — each run gets its own .planning
0 7 * * 1  cd /path/to/workspace && ZYGOS_CONFIG=/path/to/zygos.zon \
  /path/to/zygos mission start /path/to/brief.md --run-stamp < /dev/null
```

## X5 dogfood run (documented, 2026-07-10)

The M4.5 exit: `examples/x5-dogfood/brief.md` (a `wordfreq` POSIX CLI with a
self-test) run through the real binary against live catalog providers, roles
routed per `examples/x5-dogfood/zygos.zon` (GLM 5.2 / DeepSeek V4 Pro /
Minimax M3 / Gemini 3.5-flash, with cross-provider failover ladders), the
human at intake and the completion gate only. Both `mission start` and a
mid-flight `mission resume` verified by Mauricio. Dogfood findings folded
back the same day: provider warnings now name the failing instance
(rate-limit attribution), and the CLI requests real-mission
`role_max_steps`/`max_role_turns` instead of the scripted-test defaults that
starved the first executor run.
