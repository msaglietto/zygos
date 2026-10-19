---
# ── enforced by the orchestrating agent; implementation agents cannot override ──
mission: zygos
created: 2026-07-06
status: active
milestone: M4.6
budget:
  delegate_max_time_s: 900
  max_parallel_coding_agents: 2
gates:                              # require Mauricio's explicit ok
  new_dependency: human             # any entry in build.zig.zon
  protocol_change: human            # any edit to docs/PROTOCOL.md
  external_actions: human           # publishing, network services, deploys
escalation:
  test_fail_threshold: 3            # same test red after 3 delegated attempts → stop, redesign
---

# Mission: Zygos

This file is the **goal prompt**. Any agent working in this repo reads this first,
then `AGENTS.md` (how to work), then `docs/ARCHITECTURE.md` and `docs/PROTOCOL.md`
(what to build). The full design rationale lives in `docs/DESIGN.md`; the milestone
tables below are the contract.

## Objective

Build **Zygos**: a single-binary agent harness in Zig. It reimplements the iii
engine kernel — workers connect over WebSocket and register *functions* and
*triggers* on one message bus — and ships harness capabilities (turn loop,
provider routing, policy, approvals, budget, memory) as replaceable workers.
Its end state runs a continuous **mission loop**: role agents (product-owner,
planner, executor, verifier) iterating on the GSD artifact substrate until an
objective completes, each step routable to a different model/provider.

## Success criteria — milestone M0 (the kernel)

| # | Criterion | Verified by |
|---|-----------|-------------|
| S1 | All iii protocol messages round-trip (parse → serialize → parse, byte-equivalent semantics) | `zig build test` — `kernel/protocol.zig` tests, incl. every message type and malformed-input rejection |
| S2 | Function catalog: last-registration-wins; CAS-gated teardown (a stale worker's disconnect never evicts a fresher registration) | `zig build test` — catalog tests incl. reconnect-churn scenario |
| S3 | Invocation router: UUID-correlated request/response; deferred completion; timeout produces an ErrorBody, not a hang | `zig build test` — invocation tests incl. timeout + late-result-after-timeout |
| S4 | Trigger registry: type re-registration replays existing bindings; connection-owned triggers GC'd on disconnect, durable bindings survive | `zig build test` — trigger tests |
| S5 | Keyed byte channels: single-consumer take semantics, access-key gating, TTL sweep | `zig build test` — channel tests |
| S6 | End-to-end: the unmodified **iii Node SDK** connects to a running Zygos kernel, registers a function, and invokes another worker's function successfully | `test/e2e/node-sdk/` script; documented run in README |

## Success criteria — milestone M1 (the turn loop)

M0 closed 2026-07-07 (all S1–S6 green; see README). M1 criteria approved by
Mauricio 2026-07-07.

| # | Criterion | Verified by |
|---|-----------|-------------|
| T1 | In-process workers ride the same bus semantics as WS workers: frame-path registration/invocation, no kernel special-casing beyond delivery; kernel Waiter completions carry real payloads | `zig build test` — inproc worker register/invoke round-trip through the actor |
| T2 | Turn FSM: `provisioning → streaming → dispatching → awaiting_approval → steering → stopped\|failed`; every legal transition tested, illegal transitions rejected as errors | `zig build test` — table-driven FSM tests |
| T3 | provider-anthropic: incremental SSE decoding → channel deltas + assembled terminal message (stop_reason, usage, tool_use with accumulated input JSON); malformed SSE never crashes | `zig build test` — decoder/assembler tests over recorded fixtures, no network |
| T4 | Tool dispatch: model `tool_use` → bus invocation of the named tool function → `tool_result` fed into the next step's messages | `zig build test` — turn tests with fake provider + fake tool |
| T5 | agent-tools worker: `zygos::tools::{bash,read_file,write_file}` registered on the bus, workspace-root confined (path escapes rejected) | `zig build test` — tools tests |
| T6 | e2e: a scripted 2-step tool-use turn (fake provider streaming deltas over a kernel channel) completes and stops cleanly | `test/e2e/turn/` script; documented run in README |

M1 notes: the approval worker is M2 — `awaiting_approval` exists in the FSM and
is tested, the M1 driver auto-approves through it. The real Anthropic HTTP/SSE
client lands in `src/net/` (Z-02 amendment covers it) but is exercised only by
an env-gated manual smoke (`ANTHROPIC_API_KEY`), never by `zig build test`.

## Success criteria — milestone M2 (policy + routing)

M1 closed 2026-07-07 (all T1–T6 green; see README). M2 criteria drafted
2026-07-07 from the ARCHITECTURE.md M2 line, under Mauricio's `/goal` directive
to implement M2 — **ratified by Mauricio 2026-07-07**. All U1–U6 green.

| # | Criterion | Verified by |
|---|-----------|-------------|
| U1 | Fail-closed policy gate: when a `policy_function` rides the turn request, every tool dispatch consults it first; `deny` ⇒ is_error tool_result (turn continues); `ask` ⇒ approval path; missing worker, malformed verdict, or handler error ⇒ deny — never dispatch | `zig build test` — policy worker tests + turn-driver fail-closed tests |
| U2 | Approval worker: `zygos::approvals::{request,resolve,pending}`; an `ask` verdict blocks the turn in `awaiting_approval` on a real bus call until resolved (unresolved timeout ⇒ deny); `zygos::turns::abort` stops a running turn at the next boundary | `zig build test` — approval worker + turn integration tests |
| U3 | Per-step routing: `zygos.zon` config parsed at startup; `zygos::models::resolve(step_id, attempt)` returns `{provider_function, model}`; the driver resolves each step and retries a failed provider with `attempt+1` until routes exhaust (then the turn fails) | `zig build test` — router tests incl. failover turn |
| U4 | provider-openai: incremental chat-completions SSE decoding → channel deltas + assembled terminal message in the provider-neutral shape (finish_reason mapping, tool_calls with accumulated arguments JSON, usage); malformed SSE never crashes | `zig build test` — assembler tests over recorded fixtures, no network |
| U5 | Budget enforcement: `zygos::budget::{configure,record,check}` per-scope counters; the driver records provider usage each step and stops with `stop:"budget_exhausted"` when the scope is over limit; a configured-but-unreachable budget worker also stops the turn (fail closed) | `zig build test` — budget worker + turn tests |
| U6 | output-trim (Z-09): `zygos::output::compress` worker head/tail-trims oversized tool output and reports bytes saved via `zygos::budget::record`; e2e: a scripted turn through policy→approval→routing→budget→trim completes and stops cleanly | `zig build test` + `test/e2e/m2/` script; documented run in README |

M2 notes: `zygos::turns::steer` merges mid-turn input into the next step's
messages (the FSM's steering path, driver-exposed). The real openai-compat
HTTP client lands in `src/net/` under the Z-02 amendment, exercised only by an
env-gated manual smoke (`OPENAI_API_KEY`), never by `zig build test`.

Amended 2026-10-19 (issue #12, **ratified by Mauricio 2026-10-19**): U1 above —
see Amendments.

## Success criteria — milestone M3 (mission loop)

M2 ratified and closed 2026-07-07 (all U1–U6 green; see README). M3 criteria
drafted 2026-07-07 from the ARCHITECTURE.md M3 line, under Mauricio's `/goal`
directive to implement M3 — **ratified by Mauricio 2026-07-07**. All V1–V6
green.

| # | Criterion | Verified by |
|---|-----------|-------------|
| V1 | Mission FSM: `defining → planning → executing → verifying → gating → done\|failed`; every legal transition tested, illegal transitions rejected as errors; terminal states final | `zig build test` — table-driven FSM tests in `worker/mission.zig` |
| V2 | Durable `.planning/` substrate: mission state persisted atomically (tmp+rename) after every transition; role artifacts (`MISSION.md`, `PLAN.md`, `VERIFY.md`) written under the planning root; state round-trips byte-equivalent semantics through save→load | `zig build test` — `worker/mission_store.zig` tests incl. crash-shaped overwrite |
| V3 | Role turns: product-owner/planner/executor/verifier each run as one `zygos::turns::run` turn with a per-role `step_id` (so `zygos::models::resolve` routes each role to its own provider/model); structured role outputs parsed fail-closed — a malformed objective/plan/verdict fails the mission, never guesses | `zig build test` — mission driver tests with scripted fake provider |
| V4 | mission-orchestrator worker: `zygos::missions::{start,status,abort}` on the bus; `start` drives the loop to a terminal state (or resumes one from disk with `resume:true` — earlier roles are not re-run); `abort` stops durably at the next role boundary; `status` reflects the live persisted state | `zig build test` — orchestrator tests incl. mid-mission resume |
| V5 | Hard gates: reaching `done` requires a completion gate through a real approval call — no `gate_function`, an unreachable gate, or a malformed gate reply ⇒ the mission can never complete (fail closed); gate denial feeds back into replanning; `escalation.test_fail_threshold` consecutive verify failures (and likewise gate denials) stop the loop as `failed` | `zig build test` — gate + escalation tests |
| V6 | e2e: a scripted mission (define → plan → execute with the real bash tool → verify → gate-approve) completes over the full M2+M3 stack in one process, and a second leg resumes a mid-flight mission from `.planning/` on a fresh orchestrator and finishes it | `test/e2e/m3/run.sh`; documented run in README |

M3 notes: role prompts are assembled from the persisted artifacts (the GSD
substrate is the context, not conversation memory); the executor is the only
role handed tools. Mission-level budget rides the existing `budget_scope`
passthrough — no new budget machinery. Multi-mission concurrency, context
compaction, and session-store workers stay out of M3.

Amended 2026-10-11 (issue #7, **ratified by Mauricio 2026-10-11**): V1, V5 and the tools
note above — see Amendments.

## Success criteria — milestone M4 (Tessera absorbed)

M3 ratified and closed 2026-07-07 (all V1–V6 green; see README). M4 criteria
drafted 2026-07-09 from the DESIGN.md M4 line (Layer 3b), under Mauricio's
`/goal` directive to implement M4 — **ratified by Mauricio 2026-07-09**.
All W1–W6 green; **closure ratified by Mauricio 2026-07-09**.

| # | Criterion | Verified by |
|---|-----------|-------------|
| W1 | Brief validation (Z-08 leftover from M3): `zygos::missions::start` lints the mission brief before the FSM runs — frontmatter budgets/gates present, success criteria non-empty and verifiable-shaped, non-goals non-empty; a failing lint refuses the mission with a structured reason (fail closed, never starts a mission on a malformed brief) | `zig build test` — brief-validate tests incl. malformed frontmatter |
| W2 | tessera-orient worker: `zygos::tessera::{project_status,open_threads,stale_projects,reflect}` — deterministic filesystem reads of a config-rooted vault (SESSIONS.md / PROJECT.md parsing, stale >14d flagging, stalled-loop detection); no Obsidian dependency; tests run against a temp fixture vault, never the real one | `zig build test` — orient tests over fixture vault |
| W3 | tessera-continuity worker: `zygos::tessera::{session_open,close}` — open reads the last SESSIONS.md entry and returns *Leaving behind* + open threads for prompt assembly; close prepends a session entry (reverse-chronological, frontmatter-safe on first creation) and promotes action items to PROJECT.md; mission phase boundaries auto-log via the existing turn/mission driver seam — continuity is a harness property, no model asked to remember | `zig build test` — continuity tests incl. first-session file creation + mission-boundary auto-log |
| W4 | tessera-capture worker: `zygos::tessera::capture` routes raw input to a destination note using a taxonomy (destinations + tags) injected from `zygos.zon` config, never hardcoded (ADR-004); the classification turn runs through `zygos::turns::run` with `step_id:"tessera-capture"` (routable to a cheap model); malformed classifier output ⇒ fallback to the ideas destination with `#needs-review`, never a lost capture | `zig build test` — capture tests with scripted fake provider |
| W5 | tessera-undo: `zygos::tessera::{checkpoint,undo}` — shadow-git (shell-out to `git`, no new dependency) checkpoint before every capture/continuity write; one-call undo restores the pre-checkpoint vault state; undo with no checkpoint is a structured error, not a crash | `zig build test` — checkpoint/undo tests over a temp git vault |
| W6 | mcp-gateway worker: serves MCP (JSON-RPC 2.0 over stdio, `std` only) exposing exactly the `zygos::tessera::*` functions as MCP tools — `initialize`/`tools/list`/`tools/call` bridge to bus invocations, unknown tool or bus error ⇒ JSON-RPC error (fail closed); e2e: a mission run auto-logs a SESSIONS.md entry, then an external MCP client process calls `tessera::project_status` through the gateway and reads that same entry back | `zig build test` + `test/e2e/m4/run.sh`; documented run in README |

M4 notes: the vault root is config (`zygos.zon`), and `zig build test` only ever
touches temp fixture vaults. Suppression rules ride kernel state
(ADR-007-shaped) but full suppression UX, session-store (SQLite), and
compaction stay out of M4 (M5). No new dependencies anticipated; if zqlite or
an MCP lib ever looks attractive, that's the `new_dependency` human gate.

## Success criteria — milestone M4.5 (providers wired + mission CLI — the dogfood gate)

M4 implementation complete 2026-07-09 (all W1–W6 green; closure ratification
pending). M4.5 criteria drafted 2026-07-09 under Mauricio's directive to wire
the shared provider catalog (`~/.agents/providers.toml`, schema
`~/.agents/providers.schema.json`) into the CLI — **ratified by Mauricio
2026-07-09**. The research web-tools worker and the weekly-trigger decision were
explicitly deferred to the table after M4.5 (Mauricio, 2026-07-09).
All X1–X5 green (X5 dogfood run verified by Mauricio; see README) —
**closure ratified by Mauricio 2026-07-10**.

| # | Criterion | Verified by |
|---|-----------|-------------|
| X1 | Provider catalog parsing: a minimal TOML-subset parser (std only — no new dependency, so no gate) reads the providers.toml shape (`[[providers]]`/`[[clis]]` array-of-tables, string/int/float values, comments); entries validated per providers.schema.json semantics (name/type/model required, endpoint required for `openai_compatible`, temperature 0–2); key resolution `key_env` → inline `key`; `AI_PROVIDERS_CONFIG` env override honored; a malformed or invalid file is a structured error, never a partial catalog (fail closed) | `zig build test` — parser + validation tests over fixture TOMLs incl. malformed input |
| X2 | Catalog → bus wiring: each provider entry boots one openai-compat provider worker instance registered as `zygos::providers::<slug>` carrying the entry's endpoint/model/key/max_tokens/temperature as defaults; `type:"google"` maps through Gemini's OpenAI-compatible endpoint (native provider-google deferred); `[[clis]]` entries ignored; a `zygos.zon` route ladder naming an unknown provider slug refuses to boot — fail closed at startup, never mid-mission | `zig build test` — wiring tests incl. unknown-slug boot refusal |
| X3 | `zygos mission start <brief.md>` subcommand: boots kernel + default worker set + catalog providers, W1-validates the brief, drives the mission loop to a terminal state with progress streamed to stderr; approval/gate requests prompt on the console and fail closed (deny) on EOF/non-tty; `zygos mission resume` continues a mid-flight `.planning/` state | `test/e2e/m45/run.sh` — full CLI run against a localhost SSE stub named by a fixture providers.toml (network-free) |
| X4 | Multi-provider smoke, env-gated: with real keys present, a scripted 2-step turn resolves its two steps to two different catalog providers and both complete; skipped silently when keys are absent — never part of `zig build test` | manual `test/smoke/providers.sh`; documented in README |
| X5 | Dogfood exit (the DESIGN.md M3 exit test, for real): a small real objective (a single-purpose CLI tool) goes brief → completed autonomously via `zygos mission start`, roles routed across ≥3 catalog providers, human touched only at intake and hard gates, and the mission is killed + resumed once mid-flight along the way | documented run in README with the brief, route table, and transcript pointers |

M4.5 notes: the real catalog file is never read by tests and never committed
(it can carry inline key fallbacks) — `zig build test` and e2e use fixtures
only. Real runs ride the existing budget worker; the brief's frontmatter caps
are enforced as usual. The research web-tools worker and scheduled triggers stay out of
M4.5 — they are the next table once the dogfood exit proves the loop.

## Success criteria — milestone M4.6 (research-radar: the research pipeline workload)

M4.5 closed 2026-07-10 (all X1–X5; see README). M4.6 criteria drafted
2026-07-10 from Z-10 and the research-pipeline design note, under Mauricio's
`/goal` directive — **ratified by Mauricio 2026-07-10** (with a standing
directive to implement Y1–Y5 autonomously; the Y5 real-vault run remains a
human gate).

| # | Criterion | Verified by |
|---|-----------|-------------|
| Y1 | web-tools worker: `zygos::tools::{web_search,web_fetch}` on the bus — fetch: URL → size-capped readable text (tags stripped; non-2xx, oversize, or non-text ⇒ structured error, never a crash); search: config-backed HTTP endpoint (provider + key via `zygos.zon`/env — engine choice is config, no new dependency) normalized to `{title,url,snippet}[]`; both fail closed on malformed upstream responses | `zig build test` — tests over recorded fixtures, no network |
| Y2 | Web tools ride the existing harness gates, not around them: policy consulted per call with the URL in the request (deny/ask verdicts honored), fetched pages compressed on the Z-09 trim seam, bytes reported to budget | `zig build test` — gated-dispatch tests + a scripted turn over a localhost stub |
| Y3 | Weekly-trigger decision implemented: external scheduler (cron/launchd) invoking the CLI — `zygos mission start` gains unattended-rerun semantics (a run-stamped planning root or clean refuse-if-terminal, no double-start races); the decision + recipe recorded (GOAL.md amendment + README) | CLI rerun-semantics tests + documented recipe |
| Y4 | research-radar brief port: one area spec (Brief 2) → a Z-08 mission brief in the research vault's `briefs/`; coverage targets become verifiable success criteria, top-3 watch signals become open threads; passes W1 lint | brief committed to the vault + `missions::start` lint accepts it |
| Y5 | Exit: an unattended weekly-shaped run (stdin closed, hard gates fail closed) completes the research mission against the real research vault — executor researches with web tools, artifacts land in the vault behind a tessera-undo checkpoint, output diffed against the SDK-run brief as the Z-10 validation harness | documented run in README with the brief + diff pointers |

M4.6 notes: context compaction (M5) is explicitly watched, not included — if
the first real research mission blows context or budget, compaction jumps
the queue as M4.7. The search engine choice (Brave/Tavily/etc.) is operator
config; any SDK/library for it would trip the `new_dependency` human gate.
`zig build test` never touches the network or the real research vault.

Later milestones (M5 thick) get their own criteria tables when M4.6 closes;
do not start them early.

## Non-goals

- No iii console/UI clone. Observability lands as OTel + logs first.
- No worker registry service (`workers.iii.dev` equivalent). Local `worker add` only.
- No Windows support in v1. macOS + Linux.
- No protocol divergence from iii's wire format — extensions are new `zygos::*` functions, never changed frames.
- No microVM sandbox in M0–M2.
- No use of Zig async/`std.Io` concurrency — kernel actor + threads (decision Z-02).

## Constraints

- **Zig 0.16.0** (the installed toolchain). Code must build warning-clean with it.
- **TDD, strictly.** Tests are written first from the spec, fail red, then implementation
  turns them green. A commit that adds behavior without a test that demanded it is wrong.
- **Dependencies:** M0 kernel modules use `std` only, except the WebSocket/HTTP layer,
  which may use `karlseguin/websocket.zig` + `karlseguin/http.zig` — but adding them
  triggers the `new_dependency` gate.
- **Wire truth:** `docs/PROTOCOL.md` is the single source of truth for frames. Code
  conforms to it, never the other way (changes gated).
- **Memory discipline:** arena per invocation/turn; GPA with leak detection in tests;
  no hidden global allocators.

## Decision authority (for coding agents in this repo)

| Tier | Meaning | Examples |
|------|---------|----------|
| Decide & log (commit message) | Implementation agent decides | internal data structures, test organization, helper naming, error-set granularity |
| Decide & flag (in final report) | Decide, but surface it | deviations from ARCHITECTURE.md module layout, new public API on a kernel module, skipping an edge case with rationale |
| Escalate (stop, report, don't do) | Orchestrator/human decides | anything in `gates:` above, changing PROTOCOL.md or this file, disabling/deleting a test to get green, cross-module refactors |

## Amendments

Append-only. Human-written.
- 2026-07-07 (Mauricio, via session decision): Z-02 scoped exception — `std.Io.Threaded`
  (the blocking OS-thread Io implementation, not async) is permitted in `src/net/` only,
  because karlseguin/websocket.zig migrated to the std.Io interface. Kernel modules
  (`src/kernel/*`) remain std.Io-free; the actor boundary insulates them. Rationale
  discussed and accepted: churn exposure confined to one file + the pinned dep.
- 2026-10-11 (drafted by an agent for issue #7, **ratified by Mauricio 2026-10-11**):
  configurable mission pipeline. Contract: `docs/specs/mission.md`. Supersedes:
  - **V1** — Mission FSM: a step cursor over the configured pipeline (`zygos.zon`
    `.steps`; absent ⇒ product-owner, planner, executor, verifier). States
    `running → gating → done|failed`; status and trace carry `step` and
    `step_index`. Every legal transition tested, illegal transitions rejected as
    errors, terminal states final. Cursor movement (advance, rework target,
    missing-phase fill) is a pure, exhaustively tested function over the pinned
    pipeline. Verified by `zig build test` (FSM + pipeline tests in
    `worker/mission/`).
  - **V5** — The gate keeps its force: every pipeline, with or without a
    verifier, ends at the completion gate; `done` still requires a real approval
    call, and every gate failure mode still fails closed. Changed: a verify
    failure or a gate denial sends the cursor back to an executor with one fix
    task built from the feedback, instead of replanning. Consecutive verify
    failures (across all verifier occurrences) and gate denials still stop the
    loop at `escalation.test_fail_threshold`.
  - **M3 tools note** — Tools are per step. With `.tools` omitted the executor
    gets tools and every other step does not; the verifier never gets tools
    (boot refuses `.tools = true` on it). Every policy request carries the
    calling `step_id`.
  - Extended, not contradicted: **V2** — the substrate gains `EXEC.md`,
    `step-<id>-<n>.md`, and superseded `MISSION-<n>.md`/`PLAN-<n>.md` copies under
    the same atomic-write rule. **V3** — the four known ids keep their step_ids
    and fail-closed reply contracts; any other configured step runs as one turn
    with its own id as `step_id` and a free-text reply (empty ⇒ the step fails).
    **V4** — resume also refuses when the current `.steps` (ids + definition
    hashes) differs from the one pinned in `mission.json`.
- 2026-10-14 (drafted by an agent for issue #12, **ratified by Mauricio 2026-10-19**):
  operator-configured policy rules. Contract: `docs/specs/policy-config.md`. Extends, not contradicts:
  - **U1** — The mission CLI's rule table is operator config (`zygos.zon` `.policy`: ordered
    `{tool, verdict, step?}` rules, first match wins). Absent ⇒ the built-in seed, unchanged.
    Present ⇒ it replaces the seed. A malformed or unparseable block, a `step` matching no
    configured step, or a `tool` matching no offered tool refuses boot (exit 2, before any
    turn); it never falls back to the seed or to allow. No rule matched ⇒ deny. Missing worker,
    malformed verdict, or handler error ⇒ deny, as before. Verified by `zig build test`
    (policy-config tests + a per-step deny/allow mission driver test).
