---
title: "Zygos"
status: design
created: 2026-07-06
updated: 2026-07-10
tags: [project, ai-agents, harness-engineering, agentic-coding]
aliases: [zygos, zig-harness]
---

# Zygos

## Goal

A single-binary agent harness in Zig: the [iii](Tools/iii.md) engine kernel (worker/function/trigger on one bus) reimplemented, the harness shipped as replaceable workers, and — as its primary workload — a **continuous mission loop** on the [GSD](https://github.com/opengsd) substrate: role agents (product-owner, planner, executor, verifier) iterating until an objective completes, **every step routable to a different model/provider**. [Tessera Mnemis](Projects/Tessera Mnemis/PROJECT.md) is absorbed as the harness's memory & continuity layer.

## Context

Born from a design challenge (2026-07-06): combine iii's architecture with the "build your own harness" worker decomposition, in Zig, supporting gsd-core natively where each step can run on a different model/provider, with Tessera Mnemis included in the harness. Full architecture: [DESIGN.md](Projects/Zygos/DESIGN.md).

Name: ζυγός — Greek for *yoke*, the literal harness. Starts with Z, like Zig.

Code: `~/Projects/Personal/zygos` — the repo's `GOAL.md` is the mission brief (dogfooding Z-08); `docs/PROTOCOL.md` is the human-gated wire-format source of truth; TDD is mandatory (`AGENTS.md`). Build strategy: Claude orchestrates + makes architectural decisions; well-scoped coding tasks are delegated to `omp` (delegate-omp skill) to conserve credits.

## Sessions

- 2026-08-06 — M8 drafted and implemented same day: Z-09's command-aware filters, absent since M2 despite the decision calling for them. Seam gained tool/input context + a raw escape hatch (S8.1), `worker/filter/` dispatcher and four filters (S8.2-3), session dedup cache and `output::stats` (S8.4-5). 86.6% byte reduction on the fixture corpus against a 60% exit floor; 731 tests green. Ideas ported from ztk rather than depending on it — a build.zig.zon entry is human-gated.
- 2026-07-10 — M4.6 (zahir-radar) ratified and driven to the gate: Y1 web-tools worker, Y2 policy/trim/budget gating, Y3 unattended-rerun semantics + external-cron recipe, Y4 Brief 2 → Z-08 brief port all green same day. Fence-unwrap fix for role JSON landed after the first Y5 attempt. Y5 (unattended run vs the real Zahir vault) staged at the human gate — needs search key, vault-location decision, and the Y3 GOAL.md amendment.
- 2026-07-10 — M4.5 closed: X5 dogfood exit verified (real objective brief → completed autonomously across 3+ catalog providers, killed + resumed mid-flight); closure ratified.
- 2026-07-09 — M4 closed (W1–W6 ratified) and M4.5 ratified: shared provider catalog (`~/.agents/providers.toml`) wired to the CLI + `zygos mission start/resume` — the dogfood gate; X5 exit = DESIGN.md's real autonomous M3 exit test. Zahir web-tools + weekly trigger deferred to the post-M4.5 table.
- 2026-07-09 — Decision Z-10: zahir-radar (Zahir's autonomous research pipeline) adopted as the flagship M3 mission workload; its vault is the portable contract, the SDK orchestrator disposable.
- 2026-07-07 — Design addition: tool-output compression seam (Z-09) — rtk/ztk absorbed as a first-class `output::compress` dispatch step instead of a hook hack; raw output preserved in session store, savings reported to budget.
- 2026-07-06 — Build started: repo scaffolded at `~/Projects/Personal/zygos` (Zig 0.16.0, `zig build test` green), GOAL.md mission brief + PROTOCOL.md wire spec + AGENTS.md TDD rules committed; S1 (protocol module) delegated to omp, TDD red-green-refactor.
- 2026-07-06 — Scope clarification: GSD as substrate, not workflow. Designed the mission loop — mission FSM, product-owner role replacing the human at decision boundaries, hard gates, escalation, anti-runaway (Z-07). Also added the pre-turn prompt pipeline seam (Z-06).
- 2026-07-06 — Design session: explored `~/Projects/iii` + `~/Projects/gsd-core`, wrote DESIGN.md (kernel, worker table, routing, GSD adapter, Tessera integration, milestones M0–M5).

## Decisions

- **Z-01 — Wire-compatible with iii's WS/JSON protocol.** Existing iii SDKs become Zygos worker SDKs for free; the GSD adapter can be a thin TS worker reusing gsd-core internals; exit hatch back to the real iii engine preserved. Divergences namespaced as `zygos::*`, never protocol changes.
- **Z-02 — Kernel actor + thread-per-connection; no Zig async.** All registry mutation on one kernel thread with an MPSC inbox; blocking I/O per connection. Revisit `std.Io` when stable.
- **Z-03 — GSD stays untouched; Zygos implements the host contract.** `modelMode: active` (harness owns every provider call — the per-step routing point), `stateIO: filesystem`, checkpoints via `question::ask`. gsd-tools keeps running via Bash. *Partially superseded by Z-07: the host-primitive mapping survives for role turns; "run GSD's workflow as-is" does not.*
- **Z-04 — Tessera is jobs 12–13 of the harness, backed by the vault.** Continuity/capture/orient/undo as bus workers; `mcp-gateway` re-exports `tessera::*` outward so the cross-agent spine (Tessera ADR-001) survives. Suppression rules enforced as kernel state, not prose (ADR-007).
- **Z-08 — The mission brief is a two-trust-model contract.** Frontmatter (budgets, gates, escalation thresholds) is machine-enforced outside the model; body (objective, verifiable success criteria, non-goals, product intent, decision-authority ladder, PO ambiguity grants) is PO-interpreted. Validated at `mission::start`; PO read-only; amendments human-only, append-only. Full template + rationale: [Mission Brief Template](Projects/Zygos/Mission Brief Template.md).
- **Z-07 — GSD is substrate, not workflow: a mission loop replaces the human-driven command layer.** *(Partially supersedes Z-03.)* Zygos keeps GSD's `.planning/` artifacts, `gsd-tools` CLI, role prompts, and routing semantics, but drops the commands/skills layer. A `mission-orchestrator` worker drives `intake → roadmapping → (shaping → planning → executing → reviewing)* → completed | abandoned | escalated` over a durable state + FIFO queue (restart-safe). A **product-owner agent** replaces the human at decision boundaries (answers discuss questions from the mission brief; accept/redo/replan/pivot/stop), with continuity via an on-disk PO journal. Humans remain at intake, steering (`mission::steer`), and hard gates (installs, external actions, spend caps), which fail closed to the console — never to the PO.
- **Z-06 — Pre-turn prompt pipeline is an FSM seam; fusion is a worker.** `provisioning` runs an ordered list of `prompt::transform` stages (fail-open, generous timeout, armed per-turn via state). Full [pi-fusion](Tools/pi-fusion.md)-style discovery→workers→synthesis composes from `agent::spawn` + per-step routing with no FSM change.
- **Z-09 — Tool-output compression is a dispatch seam, not a hook hack.** rtk/ztk-style command-output filtering becomes an `output-trim` worker (`output::compress`) called by `agent-tools` on every tool result — possible because Zygos owns the tool boundary, unlike the PreToolUse-rewrite workaround those tools need under Claude Code. Deterministic filters (ztk's rule set: strip diff metadata/test noise/listing bloat; never touch errors, exit codes, small or structured output), fail-open, per-call `raw: true` escape hatch, session dedup cache via the `state` worker's TTL keys. Raw output always lands in the session store — only the model-facing transcript is compressed. Savings report to `budget::record` (`rtk gain` for free). Seam lands in M1 as pass-through; filters in M2. **Status 2026-08-06: fully implemented.** The seam shipped in M2 (U6, `worker/trim.zig`) but only the generic half — ANSI strip, blank-run collapse, head/tail elision. M8 built the command-aware half it promised: `worker/filter/` (dispatch + git/testrun/listing/buildlint + dedup cache), the `raw: true` escape hatch, and `output::stats`. The dedup cache lives in the trim worker rather than a `state` worker, which was never built. Measured 86.6% reduction on the fixture corpus. Implementation candidate: depend on or port [ztk](https://github.com/codejunkie99/ztk) (MIT, Zig 0.16+, zero deps — same toolchain).
- **Z-10 — zahir-radar is the flagship mission workload for M3.** Zahir's autonomous research pipeline ([Research Pipelines](Projects/Zahir/Research Pipelines.md)) ships first on the Claude Agent SDK; its Git-versioned vault (`specs/`, `briefs/`, `memory/*.jsonl`) is the stable contract and the orchestrator is disposable. At M3, the five area specs port into mission briefs (each is ~80% of a Z-08 brief: coverage targets = verifiable success criteria, watch signals = open threads) and re-run against the same vault — a real recurring objective for the M3 exit test, with the SDK-vs-Zygos brief diff doubling as a validation harness. Per-step routing (Z-05) resolves the pipeline's acknowledged Anthropic lock-in caveat. New prerequisites this surfaces: a web-tools worker (WebSearch/WebFetch) and a scheduled-trigger path for weekly unattended runs (iii's trigger primitive vs external cron — decide at M3).
- **Z-05 — Provider workers own API normalization.** Tool-call schema differences (Anthropic/OpenAI/Gemini) quarantined in `provider-*`; the turn FSM is provider-agnostic. `openai-compat` worker covers Z.AI/Kimi/Qwen/Ollama/LM Studio via base_url.

## Actions

- [x] M0 — Kernel: five primitives; exit test = unmodified iii Node SDK registers + invokes across two workers, ownership CAS verified under reconnect churn — closed 2026-07-07
- [x] M1 — One turn: 7-state FSM + provider-anthropic + read/bash tools + token streaming to CLI — closed 2026-07-07
- [x] M2 — Safety + routing: fail-closed policy, approval gate, `zygos.zon` step routing table, openai-compat provider, budget — closed 2026-07-07
- [x] M3 — Mission loop v1: mission-orchestrator + role turns on GSD substrate (scripted-provider criteria V1–V6; the real autonomous exit moved to M4.5/X5) — closed 2026-07-07
- [x] Write the mission-brief template (objective, constraints, non-goals, success criteria, gate config) — done 2026-07-06, see [Mission Brief Template](Projects/Zygos/Mission Brief Template.md)
- [x] Implement `mission::brief::validate` lint — landed as M4/W1 brief validation, 2026-07-09
- [x] M4 — Tessera absorbed: continuity/capture/orient/undo workers + mcp-gateway + shadow-git — closed 2026-07-09
- [x] M4.5 — Dogfood gate: providers.toml catalog + `zygos mission start/resume` CLI; exit (X5) = small real objective brief → completed autonomously across 3+ catalog providers, killed + resumed once — closed 2026-07-10
- [x] Port zahir-radar area specs into mission briefs (Z-10) — Brief 2 (verifier infrastructure, the wedge) ported at `examples/zahir-radar/`, passes W1 lint; web-tools worker + external-cron trigger decision landed as M4.6 Y1–Y3 — done 2026-07-10
- [ ] M4.6 — zahir-radar workload: Y1–Y4 green 2026-07-10; **Y5 (unattended run vs the real Zahir vault) is a human gate — awaiting search key, vault decision, GOAL.md amendment**

## Resources

- [DESIGN.md](Projects/Zygos/DESIGN.md) — full architecture
- [Mission Brief Template](Projects/Zygos/Mission Brief Template.md) — the human↔PO contract
- [iii](Tools/iii.md) · `~/Projects/iii` — engine source (protocol.rs, engine/mod.rs, trigger.rs, channels.rs)
- `~/Projects/gsd-core` — host contract (`src/host-integration.cts`), active model seam (`src/model-adapter.cts`), routing (`bin/shared/model-catalog.json`, `src/model-resolver.cts`)
- [How to build your own agent harness](raw/sources/how-to-build-your-own-agent-harness-2026-06-02.md) — the 15-job worker decomposition
- [Tessera Mnemis](Projects/Tessera Mnemis/PROJECT.md) · [ADRs](Projects/Tessera Mnemis/ADRs.md)
- Zig deps: karlseguin/websocket.zig, karlseguin/http.zig, zqlite.zig
- [ztk](https://github.com/codejunkie99/ztk) — Zig tool-output compressor (MIT), prior art / dependency candidate for Z-09; rtk is the Rust original (`~/.claude/RTK.md`)
- [Research Pipelines](Projects/Zahir/Research Pipelines.md) — zahir-radar, the flagship M3 mission workload (Z-10); its vault layout is the contract Zygos must serve
