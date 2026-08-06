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

## PROPOSED — ALL IMPLEMENTED (2026-07-21..22, commits 1ebe1aa..43ef187)

Every item below landed TDD-first (579 → 670 tests green; all five
network-free e2e legs + the Node SDK leg pass). Section headers below keep
the original planning text; per-item status:

- **M4.7** — brave key_env fix (1ebe1aa, closes issues/0001), mission_boot
  extraction (1ebe1aa), shared assembler core (d8e66e9), typed TraceEvent
  (e942078), missing specs (3c42159). Y5's harness blocker is gone; the
  real-vault unattended rerun remains at the human gate.
- **M5** — ContextStrategy seam + zygos.zon config (55eeea7), conformance
  harness (8106c56), SubstrateStrategy (55eeea7), RecallStrategy (cb6748f),
  ThreadStrategy + compaction-inside-strategies (b54a981, cb6748f);
  spec: docs/specs/context.md.
- **M6** — missions::steer/pause/resume (afa3a49), control channel +
  `mission attach` (f4df8e2, docs/specs/mission-attach.md), PO decision
  journal (ca91f41), intervention TUI keys (f070b0a), missions::list +
  `mission queue`/`mission dashboard` (503533a).
- **M7** — role playbook as data (4e3c149), budget ledger (4c6f98e), net
  hardening: writer queue + SIGINT graceful shutdown (40b2c51), executor
  worktree isolation (43ef187).

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

---

## IMPLEMENTED — M8: command-aware output compression (Z-09, second half)

Drafted and implemented 2026-08-06 (commits 3ddba50..a3eb78c, 719 → 731 tests
green). ROADMAP.md was exhausted after M7; this was the first milestone of the
next cycle, and it closed a gap rather than opening a frontier: **decision Z-09
was only half-built.**

Result on **real** command output from this repo: **51% fewer model-facing
bytes** (43092 → 24126 over a seven-command mix, `zig build filter-probe`).
The fixture corpus shows 86.6% and the e2e leg 63%; the probe number is the
honest one, because it is the only one measured over output nobody authored.
All five items landed; per-item status:

- **S8.1** seam context + `raw: true` escape hatch (3b2b3a7)
- **S8.2/S8.3** dispatcher, guards, and the four filters (8394ce1)
- **S8.4/S8.5** dedup cache, `output::stats`, seam wiring (a3eb78c)
- **S8-exit** `test/e2e/m8` against real git output + the production fixes it
  caught (5a4c032, 720ee44), the operator-facing ledger ratio (e2ec487), and
  `zig build filter-probe` + the fixes *it* caught (f47d8d4, 8b0af27)

**Two rounds of reality-checking, both of which overturned a green suite.**

The e2e leg found the filters were **inert on the real path**: every tool
replies with a JSON envelope the structured-data guard skipped, and trimming
that envelope generically handed the model unparseable JSON.

`filter-probe` (real commands → real filters → a savings table) then reported
**6%** overall, with four of six filters silently declining. Two more causes:
`hasErrorSignal` substring-matched the whole text, so this repo's own git log
(commit messages say "assertion") disabled the git filter; and real runners
flood output with identical repeated lines, a shape no fixture had.

Measured on this repo after both rounds — **6% → 51% overall**:

| command | saved |
|---|---|
| `git log -20` | 89% |
| `zig build test` | 78% (was 0%) |
| `ls -la src/worker` | 77% |
| `git status` | 57% |
| `git diff HEAD~1` | 11% (that diff is 84% real changes) |
| `find src -name '*.zig'` | 0% (nothing to strip — correct) |

End of chain: `test/e2e/m45` now asserts the rollup in `LEDGER.md` from the
**real `zygos mission` binary** — a live mission compressed 57214 → 2079 bytes
(**96%**) on its tool output.

Lesson, recorded because it will apply to every future filter: **a fixture
proves the algorithm, a real command proves the wiring, a probe proves the
ratio, and only the real binary proves the outcome.** The headline 86.6% measured earlier was
fixture-inflated; 51% is what this repo's actual command mix yields.

`src/worker/trim.zig` (U6) delivers the generic seam — ANSI strip, blank-run
collapse, head/tail elision, `saved_bytes` to the budget worker. What Z-09
also promised and nobody built: *"deterministic filters (ztk's rule set: strip
diff metadata/test noise/listing bloat; never touch errors, exit codes, small
or structured output), per-call `raw: true` escape hatch, session dedup cache"*.

The difference is not cosmetic. Blunt head/tail elision cuts the **middle** out
of a `git diff` — the part with the changes — and compresses a green test run
exactly as hard as a stack trace. Command-aware filtering keeps the signal and
drops the noise; ztk reports ~90% on a real command mix where truncation gets
a fraction of that, with worse fidelity.

Full design: `docs/specs/filter.md`. **Port the ideas, not the code** — taking
ztk as a `build.zig.zon` entry is a human-gated `new_dependency`, and our seam
sees structured tool input that ztk's hook-rewrite approach never gets.

| Item | Serves | Size |
|---|---|---|
| **S8.1 Seam context** — `output::compress` request gains optional `tool` + `input` (the driver has both in scope at the call site); `raw: true` in a tool's input bypasses the seam. Additive: content-only requests still trim, every existing test stays green. The enabling change — no filter can dispatch without it | RADAR + FACTORY | S |
| **S8.2 Filter dispatcher** — `filter/dispatch.zig`: basenamed argv[0] (+argv[1]) → filter table, so `/usr/bin/git` cannot dodge compression; shell metacharacters ⇒ fail open. Filter output still passes through the generic `trim()` as a budget backstop | RADAR + FACTORY | S |
| **S8.3 The filters** — one small module per family, each pure + fixture-tested: `filter/git.zig` (hunks, not index/mode metadata — the highest-value one, lands first), `filter/testrun.zig` (failures + tally, not per-test PASS lines), `filter/listing.zig` (names, not permission bits), `filter/buildlint.zig` (diagnostics, not `Compiling …`). Universal invariants tested per filter: never touch errors, <80 bytes passes, JSON passes, markers count honestly | FACTORY (primary — build/test/diff output dominates executor turns) + RADAR | M |
| **S8.4 Session dedup cache** — `filter/cache.zig` owned by `TrimWorker`: repeat command + unchanged output within a class TTL (30s volatile / 120s tests / 300s log) ⇒ one-line "unchanged" reply; mutating commands invalidate; bounded 64-entry LRU | FACTORY (executors re-run the same checks constantly) | S |
| **S8.5 Savings evidence** — `zygos::output::stats` (calls, raw vs sent bytes, by-filter breakdown) feeding M7's mission budget ledger; `test/e2e/m8/` asserts an end-to-end ratio floor of **≥60%** over the golden fixture corpus | RADAR (weekly cost) + FACTORY (per-phase attribution) | S |

**Sequencing:** S8.1 → S8.2 → S8.3 (git first, then testrun, listing,
buildlint — each independently shippable) → S8.4 → S8.5. Each filter is its
own file with its own test block, per the file-size-creep note: this milestone
adds modules, it does not grow `trim.zig`.

**Exit criterion (S8-exit):** a scripted turn over the golden fixture corpus
sends ≥60% fewer bytes to the model than the same turn with filters disabled,
with every error message, exit code, and JSON payload byte-identical.
