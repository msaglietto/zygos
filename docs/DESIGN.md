---
title: "Zygos — Design"
status: design
created: 2026-07-06
updated: 2026-07-11
tags: [project, ai-agents, harness-engineering, agentic-coding, software-engineering]
aliases: [zygos, zygos-design, zig-harness]
---

# Zygos — a Zig agent harness

**Zygos** (ζυγός, "yoke") is a single-binary agent harness written in Zig. It reimplements the [iii](Tools/iii.md) engine kernel — worker / function / trigger on one message bus — and ships the harness as a stack of replaceable workers per Mike Piccolo's decomposition ([source](raw/sources/how-to-build-your-own-agent-harness-2026-06-02.md)). Its primary workload is a **continuous mission loop** built on the [GSD](https://github.com/opengsd) substrate: role agents — one owning product decisions, one planning, one executing, one verifying — iterating phase after phase until an objective is complete, with **every step routable to a different model/provider**. [Tessera Mnemis](Projects/Tessera Mnemis/PROJECT.md) is embedded as the harness's memory & continuity layer.

## Thesis

Three sources, one shape:

1. **iii** proves the substrate: an engine whose entire core is five primitives, with everything else — state, queues, cron, HTTP, the harness itself — implemented as ordinary workers on the bus. A harness built this way is a *composition*, not a framework: swap a worker, keep the rest.
2. **The harness article** enumerates the ~15 jobs a production harness must do (turn FSM, provider routing, credentials, policy, approvals, budget, hooks, session tree, compaction, event stream, tracing) and argues each should be an independently replaceable worker. Zygos adopts that worker table almost verbatim.
3. **gsd-core** turns out to already be harness-shaped: 34 agent definitions (markdown prompt + tool list), disk artifacts as the inter-step bus (`.planning/`), a deterministic CLI (`gsd-tools`) for state/git/config, and — critically — an **`active` model adapter seam** (`src/model-adapter.cts`: `createModelAdapter({modelMode:'active'}, {sendRequest})`) built for a host that owns the LLM calls. Zygos is that host.

Tessera slots in because a harness needs jobs 12–13 anyway (session persistence, memory): Zygos implements them *as the vault*. Session continuity isn't a JSON blob in a sidecar DB — it's SESSIONS.md entries a human also reads.

## Architecture — four layers

```
Layer 3  ADAPTERS      gsd-adapter · tessera-mnemis · mcp-gateway
Layer 2  HARNESS       turn-orchestrator · provider-* · model-router ·
         WORKERS       auth-credentials · policy · approval-gate ·
                       llm-budget · hook-fanout · session-store ·
                       context-compaction · agent-tools
Layer 1  BUILT-IN      state · queue · cron · http · channels ·
         WORKERS       pubsub · observability
Layer 0  KERNEL        WS server · function catalog · invocation router ·
         (Zig)         trigger registry · byte channels
```

Layers 0–1 are the Zig binary. Layer 2 workers are Zig, compiled into the same binary but registered through the same bus API as external workers (so any one of them can be replaced by an out-of-process worker in any language). Layer 3 adapters may be polyglot — see the wire-compatibility decision below.

### Decision Z-01: wire-compatible with iii's protocol

Zygos speaks iii's exact wire protocol: WebSocket, JSON text frames, one tagged union with lowercase tags (`registerfunction`, `registertrigger`, `invokefunction`, `invocationresult`, `registerservice`, `ping`/`pong`, `workerregistered`), `invocation_id` UUID correlation, `traceparent`/`baggage` as optional sidecar strings on every invoke/result, `TriggerAction` (`enqueue`/`void`), and `StreamChannelRef {channel_id, access_key, direction}`.

**Why:** the existing iii SDKs (Node, Python, Rust, Go) become Zygos worker SDKs for free. That's the whole leverage play — the GSD adapter can be a thin TypeScript worker reusing `gsd-core`'s own compiled internals (`createHub`/`dispatch`, `model-resolver.cjs`) via the iii Node SDK, instead of porting 153 TS files to Zig. It also means any worker from the iii ecosystem can be plugged in unchanged, and Zygos workers can later run against a real iii engine if this project dies. Divergences from iii get namespaced under `zygos::*` functions, never protocol changes.

## Layer 0 — the kernel in Zig

The irreducible core, per the iii source (five primitives):

1. **WS message loop** — accept worker connections, parse the tagged union, route.
2. **Function catalog** — `StringHashMap(Function)` where insert overwrites (*last registration wins*), plus `function_owners: StringHashMap(WorkerId)` with **compare-and-release teardown**: on disconnect, a registration is only removed if the departing worker still owns it. This is what makes fast reconnects and hot worker replacement safe — iii gets this subtly right and it must be preserved.
3. **Invocation router** — `AutoHashMap(Uuid, PendingInvocation)`. Dispatch to a worker sends `InvokeFunction` and parks a oneshot; the matching `InvocationResult` completes it. In-process handlers complete synchronously. One mechanism serves direct calls, trigger firings, and enqueue redirects.
4. **Trigger registry** — `StringHashMap(TriggerType)` (each holding a registrator vtable) + `StringHashMap(Trigger)` bindings. Event sources (cron, http, state, queue) are workers that own a registrator and call `engine.call(function_id, event)` when their event fires. Re-registering a trigger type replays existing bindings to the new registrator (reconnect support). Connection-owned triggers are GC'd on disconnect; durable bindings survive.
5. **Byte channels** — single-consumer bounded pipes with capability keys, created via `engine::channels::create`, bridged to clients at `GET /ws/channels/{id}?key=…&dir=read|write`. This is the *only* streaming substrate: provider token streams, HTTP request/response bodies, UI event feeds all ride channels.

### Concurrency model (the honest Zig answer)

Zig's `std.Io` async story is still settling; don't bet the core on it.

- **Kernel actor:** all registry mutation (catalog, owners, triggers, invocations) happens on one kernel thread draining an MPSC inbox. No sharded locks, no DashMap emulation, no lock-order bugs. At personal-harness scale (tens of workers, not tens of thousands) this is nowhere near a bottleneck.
- **Thread per connection:** each worker WS connection gets a reader thread (parses frames, posts commands to the kernel inbox) and a writer fed by a bounded MPSC queue (mirrors iii's buffer-64 outbound queue). Blocking I/O per thread — boring, debuggable.
- **Channels:** mutex + condvar ring buffers. `take_sender`/`take_receiver` hand out each endpoint exactly once, gated on the access key; 5-minute TTL sweep; reaped on owner disconnect.
- **Memory:** arena per invocation and arena per turn — parse the frame, handle it, free the arena. GPA (debug: leak-checking) for long-lived registries. This is where Zig genuinely pays off: the per-turn allocation profile is explicit and flat.

### Dependencies (deliberately few)

| Need | Choice |
|------|--------|
| WebSocket server/client | `karlseguin/websocket.zig` |
| HTTP server (REST + channel bridge) | `karlseguin/http.zig` |
| JSON | `std.json` |
| Session store | SQLite via `zqlite.zig` |
| CLI | `zig-clap` or hand-rolled |
| Git (shadow-git, commits) | shell out to `git` (v1); libgit2 later if needed |
| TLS for provider HTTPS | `std.http.Client` (native TLS) |

### Module layout

```
src/
  kernel/        protocol.zig  catalog.zig  invocation.zig
                 trigger.zig  channel.zig  actor.zig
  builtin/       state.zig  queue.zig  cron.zig  http.zig  pubsub.zig
  harness/       turn.zig  provider/{anthropic,openai,google,local}.zig
                 router.zig  auth.zig  policy.zig  approval.zig
                 budget.zig  hooks.zig  session.zig  compaction.zig
                 trim.zig  tools/{read,write,edit,glob,grep,bash,question}.zig
  tessera/       continuity.zig  capture.zig  orient.zig  shadowgit.zig
  otel/          baggage.zig  spans.zig  export.zig
  main.zig       config.zig
```

## Layer 2 — the harness worker table

The article's 15 jobs, as Zygos workers. Every one is reachable through one or two function IDs on the bus; replacing a layer = registering the same IDs from a different worker.

| # | Job | Worker | Key function IDs |
|---|-----|--------|------------------|
| 1 | Accept & persist turn | `turn-orchestrator` | `run::start`, `turn::steer`, `turn::abort` |
| 2 | Credentials | `auth-credentials` | `auth::get_token` |
| 3 | Model capabilities | `model-router` | `models::list`, `models::get`, `models::resolve` |
| 4 | Turn FSM | `turn-orchestrator` | (internal; state at `session/<sid>/turn_state`) |
| 5 | Skills/tool docs | `directory` | `directory::skills::get/list/download` |
| 6 | System prompt assembly | `turn-orchestrator` | override via `system_prompt` on `run::start` |
| 7 | Token streaming | `provider-*` + channels | `provider::<name>::stream/complete` |
| 8 | Policy | `policy` | `policy::check_permissions` |
| 9 | Approvals & questions | `approval-gate` | `approval::resolve`, `question::ask` |
| 10 | Budget | `llm-budget` | `budget::record`, `budget::check` |
| 11 | Hooks | `hook-fanout` | `hooks::publish_collect` |
| 12 | Session tree | `session-store` (SQLite) + **`tessera-continuity`** (vault) | `session::create/fork/append/read` |
| 13 | Compaction | `context-compaction` | subscribes `agent::turn_end` |
| 14 | Event stream (UI) | channels | `agent::events` per session |
| 15 | Tracing | kernel + `otel` | baggage: `zygos.session.id/.message.id/.function.id` |
| + | Agent tool surface | `agent-tools` | `tool::read/write/edit/glob/grep/bash` |
| + | Sub-agent spawn | `turn-orchestrator` | `agent::spawn` (the Task-tool equivalent) |
| + | Prompt pipeline (opt) | `prompt-refiner`, `fusion` | `prompt::transform`, `fusion::start` |
| + | Tool-output compression | `output-trim` | `output::compress` |
| + | Web research (Z-10) | `web-tools` | `tools::web_search/web_fetch` |
| + | Mission loop | `mission-orchestrator` | `mission::start/steer/pause/resume/status` |

Design points carried over from iii's production learnings, adopted as requirements:

- **Turn FSM is seven states**, not more: `provisioning → streaming → dispatching → awaiting_approval → steering → stopped | failed`. Teardown is an inline `finishSession()`, not a state.
- **One reactive approval trigger.** The orchestrator registers a single `turn::on_approval` state trigger on scope `approvals`. `approval::resolve` writes `approvals/<sid>/<cid> = {decision, reason}`; the state-change trigger wakes exactly the affected session. No per-call resume registration, no startup re-scan.
- **Fail closed.** `dispatchWithHook` is the single tool-dispatch chokepoint. Policy unreachable or 5s timeout → deny with `gate_unavailable`. Hook publish failure → deny.
- **Needs-approval parks the call, not the batch** — the rest of the tool batch keeps dispatching; the turn only transitions to `awaiting_approval` when entries are actually pending.
- **Web tools ride the same gates and fail closed, with one carve-out for rate limits** (Z-10, decision 2026-07-11): `web-tools` returns every upstream failure as a structured tool-result error (never a crash), but HTTP 429 on search gets a small polite retry budget (default one retry, ~1.1s delay — sized to Brave's free-tier 1 rps) before failing, because burning executor turn steps on transient rate limits is spend, not safety. All other statuses fail immediately; failed attempts are logged with status and attempt number so unattended-run diagnosis doesn't need provider dashboards. The search engine is operator config (brave/searxng), never a dependency.
- **Baggage-first tracing.** `traceparent` + `baggage` ride every invoke/result; a baggage span processor stamps session/message/function IDs onto every span so traces group without per-worker plumbing. When a call is re-targeted (enqueue, state fan-out), rewrite `zygos.function.id` to the target.

### Per-step model/provider routing (the requirement that shapes everything)

Each provider is one worker registering `provider::<name>::stream` and `provider::<name>::complete`, doing HTTPS + SSE-parse into a channel, and reporting usage via `budget::record`. V1 providers: `anthropic`, `openai`, `google`, `openai-compat` (one worker, many base URLs — covers Z.AI, Kimi, Qwen, OpenRouter, Ollama, LM Studio).

The `model-router` worker owns `models::resolve(step_id, attempt) → {provider, model, effort, max_tokens}`. Routing config lives in `zygos.zon`:

```zig
.routing = .{
    .default = .{ .provider = "anthropic", .model = "claude-sonnet-5" },
    .steps = .{
        .@"gsd-planner"      = .{ .provider = "anthropic", .model = "claude-fable-5", .effort = "high" },
        .@"gsd-plan-checker" = .{ .provider = "openai", .model = "gpt-5.5", .effort = "medium" },
        .@"gsd-executor"     = .{ .provider = "openai-compat", .base_url = "https://api.z.ai/v1", .model = "glm-4.7" },
        .@"gsd-verifier"     = .{ .provider = "google", .model = "gemini-3.5-pro" },
        .@"gsd-researcher"   = .{ .provider = "openai-compat", .base_url = "http://localhost:11434/v1", .model = "qwen3-coder" },
        .@"tessera-capture"  = .{ .provider = "anthropic", .model = "claude-haiku-4-5" },
    },
    .escalation = .{ .enabled = true, .max = 2 },  // bump tier on step failure, GSD dynamic_routing semantics
}
```

Resolution precedence (mirrors GSD's `model-resolver.cts` so the two systems agree): exact step pin → phase-type tier → profile default → harness default. The turn-orchestrator resolves at `run::start` using the run's `step_id`, then calls whichever `provider::<name>::stream` the resolution names. **A new provider becomes routable the instant its worker connects** — no engine change, exactly iii's provider-kimi story.

Cross-provider caveat handled centrally: the orchestrator normalizes tool-call schemas per provider family (Anthropic tools vs OpenAI function-calling vs Gemini), so step prompts stay provider-agnostic. This normalization lives in the provider workers, not the FSM.

### Pre-turn prompt pipeline (the [pi-fusion](Tools/pi-fusion.md) seam)

One seam the original design missed: **transforming the turn input before the FSM runs it.** The `provisioning` state gains a *prompt pipeline* — an ordered list of `prompt::transform` function IDs read from config or from state at `session/<sid>/prompt_pipeline`. Each stage receives `{prompt, session_id, mode, workspace}` and returns `{prompt, notes?}`.

Rules that make it safe:

- **Fail-open, unlike tool policy.** A refiner outage or timeout must never block a turn — on error, the original prompt proceeds and the event stream notes the skip. (Policy gates fail closed because they *deny*; the pipeline only *improves*.)
- **Generous, configurable timeout** (default ~30s) — an AI review is a real model call, not a 5s policy check.
- **Armed per-turn, pi-fusion style.** `zygos fusion on` writes a one-shot state key that the next eligible turn consumes and auto-disarms; always-on is a config choice.
- **The refiner is just a routed step.** `.@"prompt-refiner" = .{ .provider = "anthropic", .model = "claude-haiku-4-5" }` — review runs on a cheap model while the turn runs on the big one. Per-role model selection is a config line, exactly pi-fusion's pitch.

Full pi-fusion (discovery → rewrite → N parallel workers → synthesis) needs **no FSM change at all** — it composes from existing primitives: a `fusion` worker registers `fusion::start`, runs a discovery turn (cheap model, read-only tools via policy), generates prompt variations at complementary angles, fans out N `agent::spawn` worker turns (each independently routed to a different provider — this is where per-step routing shines), then a synthesis turn merges findings. Worker transcripts are ordinary sessions in `session-store` (fully auditable, pi-fusion's archived-transcripts property for free); only the compact synthesis handoff enters the parent turn's context (its `fusion-resume-bytes` cap, done with primitives we already have).

Why design the pipeline hook now even though fusion doesn't need it: it's the single place where "transform the turn input" becomes an FSM-level seam. Prompt review, prompt-guard rules, injection scanning, and PII redaction all become pipeline subscribers instead of forks of the orchestrator.

### Tool-output compression (the rtk / ztk seam) — decision Z-09

The other half of context hygiene: Z-06 transforms the turn *input*; this seam compresses tool *output* before it enters the transcript. [rtk](https://github.com/rtk) (Rust) and [ztk](https://github.com/codejunkie99/ztk) (Zig, MIT, rtk-inspired) prove the value — ztk reports 78–90% token reduction on real command output. But both are **workarounds for harnesses that don't own the tool boundary**: they proxy the shell via PreToolUse hook rewrites (`git status` → `ztk git status`) because Claude Code gives them no other seam. Zygos owns `dispatchWithHook`, so compression is a dispatch step, not a hook hack — and that ownership buys one property neither tool can offer: **the raw output still lands in the session store and event stream; only the model-facing transcript gets the compressed form.** Auditability is never traded for tokens.

Design:

- An `output-trim` worker registers `output::compress({tool_id, command, output, exit_code}) → {output, saved_bytes}`. `agent-tools` calls it on every tool result before the result frame returns to the orchestrator.
- **Deterministic filters, zero model calls** — pattern-based compressors per command family (ztk's proven rule set): diff metadata stripped, test-runner noise dropped keeping failures + summary, directory listings folded to counts/structure, repeated log lines deduplicated. **Never touched:** error output, exit codes, outputs under a size floor (~80 bytes), structured JSON/YAML/TOML, unrecognized commands.
- **Fail-open, like Z-06** (it only *improves*, so it must never block): filter error → raw output proceeds, event stream notes the skip.
- **Per-call escape hatch:** tools accept `raw: true` so the model can demand exact output when precision matters (ztk's `--raw`, but per-call and model-drivable).
- **Session dedup cache:** repeated identical commands within a TTL (`git status` 30s, tests 2min) return an "unchanged since last call" stub; mutating commands invalidate related keys. Rides the `state` built-in worker's TTL keys — no separate cache infrastructure.
- **Savings are budget data.** `output::compress` reports `saved_bytes` to `budget::record`, so `rtk gain`-style analytics fall out of the existing budget worker for free.
- **Implementation path:** ztk is MIT, Zig 0.16+, zero deps — the same toolchain as Zygos. Options, in preference order: (a) depend on it as a Zig package and call its filter layer in-process (dep-gated: `new_dependency: human` per GOAL.md); (b) port the filter rules natively (its ~400-line Thompson-NFA regex engine and SIMD line splitting are directly liftable); (c) shell out to the binary as a stopgap. Decide at M2 when the worker is actually built.
- **Milestones:** the seam (one function call in `agent-tools`' result path, pass-through implementation) lands with M1 so the dispatch shape is right from the start; real filters + gain accounting land with M2 alongside `llm-budget`, since compression is spend reduction.

## Layer 3a — the mission loop: GSD as substrate, not workflow

**Scope clarification (2026-07-06, supersedes the original "run GSD as-is" framing — see Z-07):** Zygos does not run GSD's human-driven command layer (`/gsd-plan-phase`, `/gsd-execute-phase`, …). It runs a **continuous mission loop**: role agents iterate phase after phase — product decisions, planning, execution, verification — until an objective is met or the mission escalates. GSD contributes the substrate that makes such a loop safe and legible; the *drive* comes from the harness.

**Kept from gsd-core (the substrate):**
- The `.planning/` artifact contract — STATE / ROADMAP / PLAN / SUMMARY / CONTEXT schemas, disk-as-bus between steps.
- The `gsd-tools` deterministic CLI (state transitions, atomic per-task commit protocol, frontmatter validation) — still invoked via Bash inside role turns.
- The agent role prompts (`agents/gsd-*.md`) as starting material, adapted per role.
- The checkpoint / structured-return protocol and the model-routing semantics (`model_overrides`, `dynamic_routing`) merged into `models::resolve`.

**Dropped:** the commands/skills layer, Claude Code hooks, human-driven discuss. The host-primitive mapping survives because role turns still need tools, spawning, and gates:

| Role turns need | Zygos provides |
|---|---|
| Subagent spawn with per-step model | `agent::spawn(step_id, …)` → `models::resolve` → child turn |
| Read/Write/Edit/Glob/Grep/Bash | `agent-tools`, policy-gated through `dispatchWithHook` |
| `## CHECKPOINT REACHED` stop/resume | Structured returns + fresh continuation turns (GSD's own protocol) |
| `AskUserQuestion` | `question::ask` → answered by the **product-owner agent**; escalates to the human console only on hard gates |
| Worktree isolation | v1 sequential waves (`use_worktrees=false`); v2 `worktree::create` |
| Passive model field | **Active** — Zygos owns every provider call |

### The mission FSM

A `mission-orchestrator` worker sits one level above the turn FSM. It registers `mission::start(objective, constraints, budget)`, `mission::steer`, `mission::pause/resume`, `mission::status`. Mission state lives at `mission/<id>/state`; transitions are woken by a durable `mission-step` FIFO queue — iii's turn-step pattern, one level up. Because both state and queue are durable, **a mission survives harness restarts** and resumes at the last boundary.

```
intake → roadmapping → [ phase loop: shaping → planning → executing → reviewing ]*
       → milestone_review → completed | abandoned | escalated
```

Each state runs one or more turns via `run::start`, each independently routed — this is where per-step multi-provider routing earns its keep:

| Role | Replaces | Owns | Typical routing |
|---|---|---|---|
| `product-owner` | **the human** at every decision boundary | mission brief interpretation; CONTEXT.md decisions; accept / redo / replan / pivot / stop | frontier model, high effort |
| `roadmapper` | gsd-roadmapper | ROADMAP.md, REQUIREMENTS.md | heavy tier |
| `planner` + `plan-checker` | plan-phase pair | PLAN.md, iterated until checker passes | heavy; checker on a *different provider* |
| `executor` | execute-phase | code, atomic commits, SUMMARY.md | fast, cheap coder model |
| `verifier` | verify-work | VERIFICATION.md evidence | different provider than executor |

**The key inversion is discuss-phase.** In GSD, discuss gathers *human* context into CONTEXT.md as locked decisions. In mission mode, the `shaping` state has the product-owner turn answer those questions itself, seeded by the **mission brief** — the objective, constraints, non-goals, and success criteria the human writes once at intake. Everything GSD's workflow would ask a human, the PO answers — except the hard gates. The brief is the control surface of the whole loop and has its own designed contract: [Mission Brief Template](Projects/Zygos/Mission Brief Template.md). Its frontmatter (budgets, gates, escalation thresholds) is machine-enforced; its body (intent, authority ladder, non-goals) is PO-interpreted; `mission::brief::validate` lints it at `mission::start` and refuses briefs with unverifiable success criteria, empty non-goals, or missing budgets. The PO can read the brief but never write it — amendments are human-only and append-only, which is what makes "the PO contradicted the brief" a checkable claim.

**PO continuity without a long-lived context.** Role turns stay fresh-context per invocation (GSD is right about this). The PO's memory is on disk: the mission brief + a **PO journal** (`.planning/mission/DECISIONS.md` — every accept/redo/pivot with rationale) + the current artifacts. Each PO turn reloads those three. Tessera mirrors phase boundaries into SESSIONS.md automatically, so the human can audit a running mission the way they'd audit any project.

**Where the human still sits:**
- **Intake** — writes the mission brief; optionally approves the roadmap once before the loop starts.
- **Steering** — `mission::steer "<text>"` at any time; consumed at the next state boundary, same semantics as turn steering.
- **Hard gates** — approval-gate policy fail-closes to the *human console*, never the PO, on: package installs, anything that leaves the machine (deploys, publishes, side-effecting external APIs), spend beyond caps.
- **Escalation** — the mission parks in `escalated` (human paged via the event stream) when the verifier fails the same plan N times, the PO proposes a pivot contradicting the brief, budget is exhausted, or the PO self-reports low confidence.

**Anti-runaway, mechanically:** per-phase and per-mission budgets enforced by `llm-budget` (`budget::check` precedes every provider call — enforcement outside the model); a max-phase cap; stall detection — if consecutive phase reviews repeat the same leaving-behind pattern, escalate. That last one is Tessera's `/reflect` stalled-loop heuristic, applied by the machine to itself.

**Done test:** `completed` requires verifier evidence satisfying every success criterion in the brief *plus* a final PO sign-off turn writing the closing rationale. The PO may conclude `abandoned` (with rationale) but can never silently stop.

The **gsd-adapter** shrinks accordingly: a thin worker that loads role prompts from `agents/*.md`, maps GSD's routing config into `models::resolve`, and lays down the substrate templates. The orchestration logic that lived in GSD's workflow markdown moves into the mission FSM — deterministic Zig, not prompt-hoped behavior.

## Layer 3b — Tessera Mnemis as the memory layer

Tessera stops being an external MCP server bolted onto other people's agents and becomes **the harness's own jobs 12–13, backed by the vault**. This is Tessera Phase C, absorbed ([PROJECT.md](Projects/Tessera Mnemis/PROJECT.md)) — and it honors every standing ADR:

| Worker | Function IDs | What it does |
|---|---|---|
| `tessera-continuity` | `tessera::session_open/close`, `tessera::context_reload` | Subscribes to `agent::turn_end` + session create. On session open for a project-mapped workspace, reads the last SESSIONS.md entry and returns *Leaving behind* + open threads — the orchestrator's prompt assembler injects it as a fourth system-prompt layer. On close, writes the session entry and promotes actions to PROJECT.md. |
| `tessera-capture` | `tessera::capture` | Routing taxonomy (destinations + tags) injected from one config block (**ADR-004**), never hardcoded. Runs on a cheap routed model (see routing table). Handles cross-project leakage: capture for project B while a session runs on A. |
| `tessera-orient` | `tessera::project_status`, `tessera::open_threads`, `tessera::stale_projects`, `tessera::reflect` | Deterministic vault readouts — direct filesystem reads, no Obsidian dependency (resolving ADR-003's constraint). |
| `tessera-undo` | `tessera::checkpoint`, `tessera::undo` | Shadow-git checkpoint per capture task; one-call undo (**ADR-008**). Prose constraints stay the first line; this is the net. |
| `mcp-gateway` | (serves MCP over stdio/HTTP) | Exposes selected bus functions — all `tessera::*` — as MCP tools *outward*, so Claude Code, Codex, Cursor, and Opencode keep their Tessera access. The cross-agent spine (ADR-001) survives; the server just lives inside Zygos now. |

Two integration behaviors that only work because Tessera is *on the bus*:

- **Automatic session logging for GSD work.** `hook-fanout`'s `hooks::turn_end` feeds `tessera-continuity`: when a GSD execute-phase turn completes, the session log gets an interstitial entry (phase, plans completed, leaving-behind extracted from the SUMMARY) without any agent being asked to remember. Continuity becomes a property of the harness, not a discipline of the model.
- **Suppression rules as state, not prose** (**ADR-007**). Decline flags and the per-session prompt cap live at `session/<sid>/tessera_suppression` in kernel state. The continuity worker checks state before prompting — enforcement is mechanical, so no model can nag.

## The thin↔thick slider

Zygos keeps iii's best property: thin vs thick is worker count, not architecture.

- **Thin** (autonomous personal runs): kernel + `turn-orchestrator` + `provider-anthropic` + `auth-credentials` + `agent-tools`. No policy, no approvals, no budget.
- **Default** (daily driver): + `policy` + `approval-gate` + `llm-budget` + `session-store` + `tessera-*` + `mcp-gateway`.
- **Thick** (GSD milestone runs): + `gsd-adapter` + `context-compaction` + `hook-fanout` + all four provider workers + escalation routing.

The slider moves in `zygos.zon`'s worker boot list. Same protocol, same traces at every position.

## Milestones

- **M0 — Kernel** (the five primitives + `Ping`/`WorkerRegistered` handshake). Exit test: iii's *Node* SDK connects unmodified, registers a function, invokes another worker's function, correlation and last-wins/CAS ownership verified under reconnect churn.
- **M1 — One turn.** `turn-orchestrator` (7-state FSM) + `provider-anthropic` + `agent-tools` (read/bash) + channels streaming to a CLI client, `output::compress` seam in the tool-result path (pass-through). Exit: a single-step agent turn streams tokens and executes a policy-free tool call end-to-end.
- **M2 — Safety + routing.** `policy` (fail-closed), `approval-gate` + `question::ask`, `model-router` with `zygos.zon` step table, `openai-compat` provider, `llm-budget`, `output-trim` filters (Z-09) reporting savings through `budget::record`. Exit: a two-step run where step 1 and step 2 demonstrably hit different providers, one tool call requires console approval.
- **M3 — Mission loop v1.** `mission-orchestrator` + role turns (product-owner, planner, checker, executor, verifier) on the GSD substrate; durable mission state + step queue; hard gates + escalation states. Exit: a small objective (a single-purpose CLI tool) goes **brief → completed autonomously**, roles spread across 3+ providers, human touched only at intake and hard gates, mission resumable after a harness restart mid-phase.
- **M4 — Tessera absorbed.** All four tessera workers + mcp-gateway + shadow-git. Exit: a GSD session auto-logs to SESSIONS.md; Claude Code (as an external MCP client) calls `tessera::project_status` served by Zygos.
- **M5 — Thick.** hook-fanout, compaction, session forking, `zygos worker add` for out-of-process workers.

## Risks & honest tradeoffs

- **Zig async immaturity is real.** Mitigated by not using it: kernel actor + thread-per-connection is a deliberately boring concurrency model that Zig does superbly today. Revisit `std.Io` when it stabilizes; the actor boundary makes that swap internal.
- **You're rebuilding a maintained OSS engine.** True — and iii's engine alone is a large Rust workspace. The counter: Zygos's kernel is ~5 primitives (a few thousand lines of Zig), the harness workers are the actual product, and wire compatibility means you can defect back to iii's engine at any time with your workers intact. That exit hatch is the insurance policy on the whole project.
- **Provider API drift.** Tool-call schema normalization is quarantined inside provider workers; adding/fixing a provider never touches the FSM.
- **gsd-core version coupling.** The adapter pins a gsd-core version and talks to it through its published seams (model-resolver, gsd-tools CLI verbs, artifact templates). GSD upstream changes land as adapter bumps, not harness changes. Forking the substrate outright is acceptable — Z-07 already abandons upstream's command layer.
- **The product-owner agent replaces the human — the riskiest delegation in the design.** Mitigations are structural, not prompt-based: hard gates fail closed to the human console; budgets are enforced outside the model; `escalated` is a real FSM state, not a suggestion; every PO decision lands in an auditable journal; and missions start small, widening autonomy as trust accrues. The failure mode to watch is not malice but drift — a PO that keeps "reasonably" reinterpreting the brief. The brief-contradiction escalation check exists for exactly this.
- **Scope.** This is a big build for one person. The slider is also the scope control: M1 alone (thin harness, one provider) is already a usable daily agent; every later milestone is optional thickness.

## Sources

- [iii](Tools/iii.md) — engine architecture; five-primitive kernel confirmed against `~/Projects/iii` source (protocol enum in `engine/src/protocol.rs`, catalog/owner CAS in `engine/src/engine/mod.rs`, trigger registry in `engine/src/trigger.rs`, channels in `engine/src/workers/worker/channels.rs`).
- [How to build your own agent harness](raw/sources/how-to-build-your-own-agent-harness-2026-06-02.md) — the 15-job decomposition, FSM/approval/fail-closed patterns, thin↔thick slider.
- `~/Projects/gsd-core` — agent definitions (`agents/*.md`), artifact schemas (`gsd-core/templates/`), model routing (`bin/shared/model-catalog.json`, `src/model-resolver.cts`), host contract (`src/host-integration.cts`), active model seam (`src/model-adapter.cts`).
- [Tessera Mnemis](Projects/Tessera Mnemis/PROJECT.md) + [ADRs](Projects/Tessera Mnemis/ADRs.md) — continuity loop, config-block taxonomy, suppression rules, shadow-git undo.
- [ztk](https://github.com/codejunkie99/ztk) (Zig, MIT) + rtk (`~/.claude/RTK.md`) — tool-output compression prior art: filter rule set, never-touch list, session dedup cache, savings analytics. ztk shares Zygos's exact toolchain (Zig 0.16+, zero deps).
