# Zygos Onboarding Guide

> Generated from the Understand-Anything knowledge graph (`.ua/knowledge-graph.json`),
> commit `9b4be8d`, 2026-07-17. 118 files, 274 graph nodes, 609 edges.

## Project Overview

**Zygos** is a single-binary agent harness in **Zig 0.16** that reimplements the
[iii](https://iii.dev) engine kernel: workers connect over WebSocket and register
*functions* and *triggers* on one message bus. It is wire-compatible with the
unmodified iii SDKs — proven by e2e tests, not asserted. Harness capabilities
(policy, approval, budget, routing, missions, memory) ship as replaceable workers
on that same bus.

- **Languages:** Zig (kernel + workers), Markdown (specs), shell/JS (e2e harnesses), ZON (configs)
- **Dependencies:** `websocket.zig` only — external deps are human-gated (`GOAL.md`)
- **Status:** M4.6 (M0–M4.5 closed); `zig build test` runs 385 leak-checked tests, no network
- **Process:** TDD is law (`AGENTS.md`); wire format is human-gated (`docs/PROTOCOL.md`)

## Architecture Layers

The dependency flow is strict: workers → kernel, net → kernel, tests → src.
Only `actor.zig` and `net/` compose kernel modules; kernel modules know nothing
of each other or of sockets.

### 1. Entry & Build (5 files)
Binary and module entry points plus the build definition.
Key files: `src/main.zig` (thin subcommand dispatch: mission / trace / mcp-gateway),
`src/root.zig` (module barrel and test root — highest fan-out in the graph),
`src/cli/mission.zig` (the `zygos mission` CLI), `build.zig`, `build.zig.zon`.

### 2. Kernel Layer (9 files, `src/kernel/`)
The message-bus kernel. Five independent subsystems — `protocol.zig` (S1, wire
frames), `catalog.zig` (S2, function registry with CAS ownership), `invocation.zig`
(S3, pending calls + timeouts), `trigger.zig` (S4), `channel.zig` (S5, keyed byte
channels) — composed by `actor.zig`'s single command-loop inbox. `inproc.zig` is
the socket-free transport for native workers; `sync.zig` provides pthread
Mutex/Condition/ResetEvent (Zig 0.16 has no std.Thread primitives; std.Io ones
barred by decision Z-02); `types.zig` holds WorkerId/Uuid.

### 3. Network & Providers Layer (10 files, `src/net/` + `src/config/`)
Bridges the kernel to the outside world. `ws.zig` is the **only module that touches
sockets**. Provider clients (`anthropic.zig`, `openai.zig`) stream SSE; `provider_boot.zig`
registers catalog providers from `~/.agents/providers.toml` (`config/providers.zig`)
as ordinary kernel functions. `stream_guard.zig` + `ticker.zig` kill hung streams.
`web_tools.zig` registers `zygos::tools::{web_search,web_fetch}`.

### 4. Worker Layer (25 files, `src/worker/`)
The agent side. `turn.zig` is the core agentic loop (pure table-driven FSM + effectful
driver); `mission.zig` composes role turns (po → planner → executor → verifier) into
long-running objectives persisted by `mission_store.zig` (tmp+rename atomic writes).
Guardrails are ordinary bus workers: `policy.zig` (fail-closed), `approval.zig`
(human-in-the-loop), `budget.zig`, `trim.zig` (Z-09 output compression). Memory is
the tessera worker family (`tessera_orient/continuity/capture/undo` over pure parsers
in `tessera/`). `mcp/gateway.zig` exposes tessera over MCP stdio; `mcp/client.zig`
plugs external MCP servers onto the bus.

### 5. TUI Layer (10 files, `src/tui/`)
Live mission progress: hand-rolled ANSI, zero external deps, Elm-style model/view
split (`model.zig` state under a mutex, `frame.zig` scrollback-flow renderer,
`loop.zig` render thread). libc terminal control is confined here, mirroring the
net/ Z-02 exception. stdout stays reserved for the final mission JSON.

### 6. Test Layer (21 files, `test/`)
Milestone exit tests (`e2e/m2`–`m45`), the S6 wire-compatibility proof
(`e2e/node-sdk/` runs the **unmodified** iii Node SDK against the Zig kernel),
the timeout/hang regression suite (`e2e/timeouts/` with a silent-provider stub),
and env-gated real-provider smokes (never in `zig build test`).

### 7. Documentation & Examples (38 files)
`GOAL.md` (human-gated mission brief + decision authority), `docs/PROTOCOL.md`
(human-gated wire source of truth), `docs/ARCHITECTURE.md`, `docs/DESIGN.md`,
`docs/PROJECT.md` (decisions Z-01–Z-10), 26 per-module specs in `docs/specs/`,
and example missions (`examples/x5-dogfood/`, `examples/zahir-radar/`) with their
`zygos.zon` route tables.

## Key Concepts

- **Spec-first, RED-first.** Every module has a spec in `docs/specs/` with an
  exactly-named test contract; tests are written from the spec before code.
  Never weaken a test to get green — that's an escalation (`GOAL.md`).
- **Everything is a bus function.** Providers, tools, policy, approvals, budget,
  trim, memory — all registered functions invoked over the bus. Nothing is
  special-cased kernel code, so everything is swappable (including for tests:
  `provider_fake.zig` is interchangeable with real providers).
- **Fail closed.** No matching policy rule → deny; unparseable result frame →
  caller gets an answer, not a hang; invalid providers.toml → no catalog; failing
  brief lint → mission refused. The two deliberate fail-*open* exceptions are
  `trace.zig` and `stream_tap.zig` (observability must never change outcomes).
- **Pure core / effectful shell.** FSMs (`turn.zig`, `mission.zig`) and parsers
  (`tessera/vault.zig`, `session_writer.zig`, `brief.zig`) are pure and I/O-free;
  drivers and workers own the effects. Unlisted FSM transitions are
  `error.IllegalTransition`.
- **Confinement rules.** Sockets only in `net/ws.zig` and provider HTTP legs;
  termios/ioctl only in `tui/`; tool file/bash access lexically confined to the
  workspace root (`tools_ops.zig`).
- **Durability by rename.** All `.planning/` and vault writes go through
  tmp-file + `rename(2)` so a crash never corrupts the previous state; missions
  resume mid-flight.
- **Allocators are passed in, never global**; tests use the leak-checking
  `std.testing.allocator` — a leaking test is a failing test.

## Guided Tour (13 steps)

1. **Project Overview** — `README.md`, `GOAL.md`: what Zygos is and the gate-driven process that builds it.
2. **Entry Points and Build** — `src/main.zig`, `src/root.zig`, `build.zig`.
3. **The Wire Protocol** — `docs/PROTOCOL.md` + `src/kernel/protocol.zig`: one JSON frame format, spec-first.
4. **Kernel Building Blocks** — catalog, invocation, trigger, channel, sync: independent subsystems, composition happens one level up.
5. **The Kernel Actor** — `src/kernel/actor.zig` (+spec): the single inbox everything goes through (fan-in 25, highest in the graph).
6. **Two Transports** — `src/net/ws.zig` (external SDK workers) and `src/kernel/inproc.zig` (native workers, fan-in 20).
7. **LLM Providers** — provider_boot/anthropic/openai + `config/providers.zig`: providers are just kernel functions.
8. **The Turn Loop** — `src/worker/turn.zig`, `tools.zig`, `router.zig` + `docs/specs/turn.md`: pure FSM, effectful driver.
9. **Guardrails** — policy, approval, budget, trim: safety features as replaceable bus workers.
10. **Missions** — `mission.zig`, `mission_store.zig`, `cli/mission.zig` + spec: role turns driven to a terminal state over durable `.planning/`.
11. **The Mission TUI** — `tui.zig`, `model.zig`, `loop.zig`.
12. **Proving Wire Compatibility** — `test/e2e/node-sdk/`, `test/e2e/turn/`, `test/smoke/providers.sh`.
13. **Architecture Docs and Working Rules** — `docs/ARCHITECTURE.md`, `AGENTS.md`: now a map of territory you've walked.

## File Map (selected key files)

| File | Role |
|---|---|
| `src/kernel/protocol.zig` | Message tagged union + parse/serialize; knows nothing of catalog or sockets |
| `src/kernel/actor.zig` | Command-loop inbox composing all kernel subsystems |
| `src/kernel/inproc.zig` | Socket-free worker transport; fails closed on unparseable results |
| `src/net/ws.zig` | WebSocket gateway — the only socket-touching module |
| `src/net/provider_boot.zig` | Boots catalog providers onto the bus; refuses bad route tables at startup |
| `src/worker/turn.zig` | Core agentic loop: context → stream → tool dispatch → repeat |
| `src/worker/mission.zig` | Mission FSM: po → planner → executor → verifier → hard human gate |
| `src/worker/mission_store.zig` | Durable `.planning/` substrate (atomic tmp+rename) |
| `src/worker/policy.zig` | `zygos::policy::check`, fail-closed at both ends |
| `src/worker/trim.zig` | Z-09 output compression seam on every tool result |
| `src/worker/router.zig` | Per-step model escalation ladders from `zygos.zon` |
| `src/tui/model.zig` | TUI view model; every entry point takes the model mutex |
| `src/config/providers.zig` | Hand-rolled TOML-subset parser for `~/.agents/providers.toml`, fail-closed |
| `test/e2e/node-sdk/e2e.mjs` | S6: unmodified iii Node SDK round-trips against the Zig kernel |

## Complexity Hotspots

Approach these with the spec open and run `zig build test` often:

1. **`src/worker/mission.zig`** (2039 lines) — mission FSM + driver + continuity/trace seams; the most tightly coupled cluster in the graph (with `mission_store.zig` and its spec).
2. **`src/worker/turn.zig`** (1805 lines) — turn FSM + orchestrator; policy/approval/router/budget/trim seams all converge here.
3. **`src/kernel/protocol.zig`** (1390 lines) — every wire frame; changes are human-gated via `docs/PROTOCOL.md`.
4. **`src/kernel/actor.zig`** (1371 lines) — highest fan-in (25); check callers before touching shared behavior.
5. **`src/tui/model.zig`** (1046 lines) — mutates under a mutex from multiple foreign threads.
6. **`src/worker/mcp/client.zig`** (859 lines) and **`src/net/web_tools.zig`** (886 lines) — protocol bridges with fail-closed parsing.
7. **`src/config/providers.zig`** / **`src/net/provider_boot.zig`** — fail-closed config parsing and boot refusal; errors here stop the binary by design.

## Where to Start Contributing

1. Read `GOAL.md` (decision authority) and `AGENTS.md` (TDD law, commands, conventions).
2. Walk the tour above — or open the interactive dashboard: `/understand-dashboard`.
3. Pick the spec in `docs/specs/` for the module you're touching; write the RED test first.
4. Gate: `zig build test` green and `zig fmt --check src/` clean before any commit.
