# Zygos roadmap

Drafted 2026-07-18 from the full-codebase review (`docs/RECONCILIATION-2026-07-18.md`).
Two consumers with opposite context profiles anchor every proposed item:

- **RADAR** — zahir-radar: broad, shallow, many transient sources; weekly
  unattended research runs; high-recall / low-depth context.
- **FACTORY** — orchy software factory: narrow, deep, long-lived; codebase
  state + task threads carried across many mission steps.

An item that serves neither is not on this roadmap.

---

## IMPLEMENTED (as of M4.6, 579 tests green — derived from code, not prior docs)

**Kernel (M0)** — iii wire protocol (12 frame types, byte-equivalent
round-trip); function catalog with last-wins + CAS-gated teardown; UUID
invocation router with deadline heap and per-function prefix-matched timeout
overrides; trigger registry (type replay, durable vs connection-owned);
keyed byte channels (single-take endpoints, TTL sweep, observed-clock
stamping); single-thread actor over a bounded MPSC inbox; in-process bus
peers (thread-per-invocation handlers, `CallResult` errors-as-data); WS
gateway (unmodified iii Node SDK passes e2e).

**Turn loop (M1–M2)** — 7-state pure FSM + driver registering
`zygos::turns::{run,abort,steer}`; tool dispatch with fail-closed policy
gate, approval worker (manual/auto, deny-on-timeout), per-step `zygos.zon`
route ladders with cross-provider failover, budget enforcement
(fail-closed check + synchronous usage recording), Z-09 output-trim seam on
every tool result; workspace-confined bash/read/write tools.

**Providers** — anthropic + openai-compat SSE assemblers (dup-key
canonicalization, cross-dialect usage-spelling fallback, thinking/reasoning
capture); provider catalog (`~/.agents/providers.toml` TOML-subset parser,
fail-closed validation); catalog→bus boot with anthropic/openai dialect
selection and unknown-slug boot refusal; stream-idle watchdog
(`ZYGOS_STREAM_IDLE_MS`) + tiered mission/invoke timeouts.

**Mission loop (M3+)** — 7-state mission FSM over a durable `.planning/`
substrate (atomic tmp+rename, mid-flight resume); product-owner / planner /
executor / verifier role turns, each routed per-role; fail-closed structured
output parsing with fence unwrapping and `REJECTED-<role>.md` artifacts;
executor `max_steps` retry-with-feedback and completed-task outcome carry;
hard completion gate through a real approval call; W1 brief lint; escalation
thresholds.

**Memory & gateways (M4)** — tessera orient/continuity/capture/undo workers
over pure vault parsers (shadow-git checkpoint/undo); MCP gateway (tessera
tools outward over stdio); MCP **client** (external servers' tools onto the
bus as `zygos::mcp::<server>::<tool>`, riding policy/trim/budget).

**Research workload (M4.6)** — web_search/web_fetch worker (brave/searxng,
429-retry carve-out, fail-closed parsing) gated like any tool; unattended
rerun semantics (`--run-stamp`, refuse-if-existing) + external cron recipe;
zahir-radar Brief 2 ported and lint-clean. Y5 (real-vault unattended run)
staged at the human gate — currently **blocked by the brave key_env defect**.

**Operator surface** — `zygos mission start|resume|trace` CLI; live mission
TUI (streaming thinking/tool/answer entries, collapse lifecycle,
keypress approvals, markdown-lite answers, truecolor); `events.jsonl`
mission trace, fail-open, with in-process sinks + stream tap feeding the
TUI; `ZYGOS_LOG` progress feed; nine network-free e2e legs + env-gated
real-provider smokes.

---

## PROPOSED

Sizes: S ≈ a session, M ≈ a few sessions, L ≈ a milestone-dominating build.
Tags: which consumer the item is load-bearing for.

### M4.7 — Y5 unblock + seam hardening (close the known gaps first)

| Item | Serves | Size |
|---|---|---|
| **Fix brave `key_env` resolution** — resolve the env var into `key` at boot (or in `web_tools`); regression test; unblocks the Y5 human gate | RADAR | S |
| **Extract `mission_boot` from the CLI** — run-stamp refusal, timeout ceilings, roster/policy seeding, vault-checkpoint protocol behind a testable interface; `cli/mission.zig` drops to argv→config→wire (today: 0 tests on all four fail-closed rules) | RADAR (unattended safety) + FACTORY | M |
| **Shared assembler core** — one `Message/Usage/Block` + helpers behind both SSE dialects; ends the fix-it-twice provider-drift pattern that already bit twice (GLM usage keys, dup-key args). Cross-provider ladders are both consumers' backbone | RADAR + FACTORY | M |
| **Typed `TraceEvent` schema** — tagged union shared by emitters (mission/turn drivers) and consumers (JSONL sink, TUI, `mission trace`); exhaustive switch replaces the string dispatcher; unknown-event silent drops become compile errors. Prereq for M6's control surface | RADAR (unattended diagnosis) + FACTORY | M |
| **Missing specs** — `specs/tui.md`, `specs/mcp-client.md`, `specs/stream-guard.md` (+ short notes for ticker/sse/trace/stream_tap); spec-first is the process both workloads' reliability rests on | RADAR + FACTORY | S |

### M5 — ContextStrategy: the context-passing pillar

The context handed between pipeline steps becomes a first-class, swappable
**`ContextStrategy`** — not a utility, and explicitly not
"dump-the-transcript-into-the-model", which is the anti-pattern this layer
exists to replace. Zig shape (decided, not open): a **vtable**
(`ctx: *anyopaque` + fn pointers), matching the codebase's existing
Outbound/Caller/Sink idiom — strategies are config-selected at boot from
`zygos.zon`, and comptime/tagged-union dispatch would force every strategy
into one compilation unit and make out-of-repo strategies impossible.

```zig
pub const ContextStrategy = struct {
    ctx: *anyopaque,
    /// Assemble the next step's messages within an explicit token budget.
    assembleFn: *const fn (ctx, arena, step: StepRef, budget: TokenBudget) Error!Assembled,
    /// Absorb a completed step's outcome into the strategy's substrate.
    absorbFn: *const fn (ctx, step: StepRef, outcome: Outcome) Error!void,
};
```

The seam lands where `mission.zig` hand-assembles role prompts today.

| Item | Serves | Size |
|---|---|---|
| **`ContextStrategy` interface + config selection** — vtable, `zygos.zon` `.context_strategy` block, wired through the mission driver; every strategy declares a hard token budget (enforced, not advisory) | RADAR + FACTORY | M |
| **`SubstrateStrategy` (baseline extraction)** — today's artifacts-as-context behavior refactored behind the interface unchanged; the second adapter that makes the seam real, and the byte-identical regression anchor | RADAR + FACTORY | M |
| **`RecallStrategy`** — high-recall / low-depth for radar: rolling source index over fetched pages + prior briefs (`memory/*.jsonl`-compatible), lexical relevance scoring (std-only), per-source freshness TTL, dedup, many small ranked excerpts packed to budget — never whole documents | RADAR | L |
| **`ThreadStrategy`** — narrow/deep for the factory: durable per-task threads (executor transcript carry generalized), codebase-state digest (file map + recent-diff summary via shell-out `git`), pinned decisions that survive every step, oldest-thread-turns summarized while the working set stays verbatim | FACTORY | L |
| **Compaction on the strategy seam** — the M5-watched compaction lands *inside* strategies (summarize-and-pin), not as a separate worker bolted on the turn loop; triggered by budget pressure, with the raw artifact always still on disk | RADAR (research blows context first) + FACTORY | M |
| **Strategy conformance harness** — one test suite every strategy must pass (budget never exceeded, absorb→assemble round-trip, resume-from-disk parity), mirroring the FSM table-test discipline | RADAR + FACTORY | M |

### M6 — Mission control surface + full-harness TUI

The grok-build-style operator experience: live step state, logs, and
**intervention** — for the factory operator steering a build, and for
spot-checking a radar run mid-flight.

| Item | Serves | Size |
|---|---|---|
| **`missions::steer` + `missions::pause/resume`** — steer text consumed at the next role boundary (turn-steer semantics one level up); pause parks durably at a boundary (the substrate already resumes) | FACTORY + RADAR | M |
| **`zygos mission attach`** — attach a TUI to a running (or crashed) mission by tailing `events.jsonl` + a control socket for steer/approve; unattended runs become inspectable without being interactive | RADAR + FACTORY | M |
| **Intervention TUI** — on the typed-event stream: per-role step timeline with live state, scrollable log pane, steer input line, approval queue, pause/abort keys; the existing render stack (band/chatlog/frame) is the base | FACTORY + RADAR | L |
| **Multi-mission dashboard + queue** — run N missions (factory phases, radar area briefs) under one kernel with per-mission budget scopes; dashboard lists/attaches; refuse-if-existing generalizes to a mission queue | FACTORY (primary) + RADAR (5 area briefs) | L |
| **PO decision journal** — every accept/redo/replan lands in `DECISIONS.md` (append-only) and rides `ThreadStrategy` as pinned context; the brief-contradiction audit trail for long factory missions | FACTORY | M |

### M7 — Unattended-scale robustness

| Item | Serves | Size |
|---|---|---|
| **Role playbook as data** — role prompts/reply-shapes out of `mission.zig` into per-role files the brief can override; orchy defines factory-specific roles (reviewer, integrator), radar tunes its researcher without a rebuild | FACTORY (primary) + RADAR | M |
| **Executor worktree isolation** — `git worktree` per executor task wave; parallel task execution without workspace races (v1 stays sequential per wave) | FACTORY | L |
| **Net hardening** — the two flagged never-built items: bounded per-conn writer queue (a stalled consumer must not back-pressure the kernel) and SIGINT graceful shutdown (cron kills mid-run must land as clean aborts, not process death) | RADAR (cron lifecycle) + FACTORY | M |
| **Mission-level budget ledger** — per-mission spend rollup (tokens + saved_bytes) written into the substrate and printed at terminal state; weekly radar cost tracking and factory per-phase cost attribution from the existing budget worker's data | RADAR + FACTORY | S |

---

**Sequencing rationale:** M4.7 closes known defects/gaps that everything
later builds on (typed events precede the control surface; mission_boot
precedes multi-mission). M5 before M6 because steering and dashboards are
worthless if step context is still ad-hoc — the ContextStrategy pillar is
what makes both consumers' pipelines actually different in kind, not just
in prompt. M7 is scale-out once the loop is controllable.

Deliberately absent (traces to neither consumer): iii console clone, worker
registry service, Windows, protocol divergence, Zig async — all standing
GOAL.md non-goals — plus DESIGN.md's fusion/prompt-pipeline (Z-06) and the
`directory` skills worker, which serve neither radar nor orchy today.
