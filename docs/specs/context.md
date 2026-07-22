# Spec: `src/worker/context*.zig` — ContextStrategy (M5)

The context handed between pipeline steps is a first-class, swappable
strategy — explicitly NOT "dump-the-transcript-into-the-model". Zig shape:
a vtable (`ctx: *anyopaque` + `assembleFn`/`absorbFn`), matching the
Outbound/Caller/Sink idiom. Strategies are config-selected at boot from
`zygos.zon` (`.context_strategy = .{ .kind = "...", .max_tokens = N }`);
the CLI forwards the block in the start request. Absent ⇒ substrate with
the default budget (32k tokens); an unknown kind refuses (fail closed).

## The seam (`context.zig`)

- `assemble(arena, step, budget, diag)` — the next step's content within an
  explicit token budget. **Enforced at the seam**: over-budget output is
  `error.BudgetExceeded`, never a silently oversized prompt. `estTokens` is
  bytes/4 rounded up — a ceiling, not billing.
- `absorb(step, outcome)` — a completed step's outcome offered to the
  strategy's substrate. The driver absorbs every role outcome, fail-open
  (a failed absorb degrades context, never the mission).
- `StepRef` carries a neutral `MissionView` (objective/tasks/feedback) and
  a `Substrate` artifact-reader vtable — strategies never see driver
  internals or the disk directly.
- `Diag` carries the exact failure message for `error.Failed` (the driver
  surfaces it verbatim as mission detail).

## Strategies

- **substrate** (`context_substrate.zig`) — the baseline: today's
  artifacts-as-context assembly (objective / MISSION.md / plan-progress /
  MISSION+PLAN) byte-identical, stateless, absorb is a no-op. Also exported
  as `assembleContent` so richer strategies compose over the same spine.
- **recall** (`context_recall.zig`) — high-recall / low-depth (RADAR):
  rolling source index (`<planning>/memory/sources.jsonl`,
  `memory/*.jsonl`-compatible) over absorbed outcomes and prior briefs;
  lexical word-overlap scoring, per-source freshness TTL, dedup by id
  last-wins; many small ranked excerpts packed to the remaining budget —
  never whole documents. Compaction is summarize-and-pin: past
  `max_sources` the dropped tail merges into one pinned digest and the
  JSONL rewrites to mirror it.
- **thread** (`context_thread.zig`) — narrow / deep (FACTORY): durable
  per-task threads (`<planning>/threads/task-<n>.jsonl`, append-only —
  the executor transcript carry generalized); recent entries verbatim,
  older ones summarized at read time; pinned `DECISIONS.md` rides every
  role; a codebase digest (git ls-files + recent log) rides executor steps
  through an injected `CmdRunner` vtable (popen in production, fakes in
  tests) — fail-open when the workspace is not a repo. Block priority
  under budget pressure: decisions, thread, digest; the base spine always
  survives.

## Conformance (`context_conformance.zig`)

Every strategy's tests call `conform`: budget never exceeded across a
sweep (refusing with BudgetExceeded is valid), deterministic assembly,
absorb never corrupts assembly, resume-from-disk parity via a reopen hook.
