# Zygos Onboarding Guide

> Generated from the Understand Anything knowledge graph
> (`.understand-anything/knowledge-graph.json`, the same tree as `.ua/`
> through a symlink), commit `e1e0149`, 2026-10-08.
>
> The scan followed the existing `.understandignore`. Docs, examples, and
> tests stay in the graph. Build caches and tool directories stay out.
> The tree is large. Zig `@import` edges were linked locally, because the
> stock extractor does not parse Zig.

## Project Overview

**Zygos** is a local agent harness in one Zig binary. Workers register
functions and triggers on one message bus. A mission loop drives four roles
over a durable planning directory until a brief is done or the run stops.

- **Version:** 4.1.0, Zig 0.16.0 (`build.zig.zon`). The pinned dependency is `websocket.zig`.
- **Languages in the tree:** Zig, ZON, Markdown, shell, Python, JavaScript, JSON, TOML, YAML.
- **CI:** GitHub Actions (`.github/workflows/ci.yml`, `verify.yml`). `zig build test` stays offline.
- **How to run it:** `README.md`. **What a human must approve:** `GOAL.md`. **How to change the code:** `AGENTS.md`.

The binary has two doors onto the same kernel. A bare `zygos` opens a loopback
WebSocket gateway (`ZYGOS_PORT`, default 49134). `zygos mission` and
`zygos task` boot the kernel in-process and drive it themselves.
`zygos mcp-gateway` speaks MCP on stdio.

## Architecture Layers

Dependency direction is one way. Kernel modules share identity types and
otherwise stay independent. `actor.zig` is the only composer of catalog,
invocation, trigger, and channel. Sockets live in `src/net/`. Terminal control
lives in `src/tui/`. Workers call the bus the way a WebSocket peer would.

### 1. Entry and build

Binary entry, the public module root, the CLI, the Zig build manifest, and the
workflows that verify the tree.

| File | What it does |
|---|---|
| `src/main.zig` | Starts the kernel actor, then the WebSocket gateway or `zygos mcp-gateway`. A TUI panic restores the terminal. The process stops by being killed. |
| `src/root.zig` | Re-exports kernel, net, worker, and TUI. Importing them pulls their tests into `zig build test`. |
| `src/cli/mission.zig` | `zygos mission start`, `resume`, `queue`, `attach`, `dashboard`, and `trace`. Lints the brief, claims a planning root, boots one in-process worker. Config errors exit 2. Only state `done` exits 0. |
| `src/cli/task.zig` | Headless `zygos task run` and `zygos task score`. |
| `build.zig` | Module and executable. Links libc, imports `websocket.zig` into the module, embeds `examples/providers.toml` for catalog tests, stamps a clean git SHA. |
| `build.zig.zon` | Package name, version 4.1.0, Zig 0.16.0, pinned websocket dependency. |
| `.github/workflows/ci.yml` | Checksum-pinned Zig 0.16.0 on Ubuntu and macOS. Format, offline tests, a system-cache build, scripted mission and WebSocket checks. |

`src/cli/mission/req.zig` and `view.zig` shape the start request and the
dashboard line. The scan also placed `reports/benchmarks/deepseek-canary-2026-10-06.json`
in this layer.

### 2. Kernel (`src/kernel/`)

The message bus. Wire frames, catalog, invocations, triggers, channels, and
the single kernel actor.

| File | What it does |
|---|---|
| `protocol.zig` | Public facade: message types, `parseMessage`, `serialize`. Round-trip tests live here. |
| `protocol/types.zig` | `Message` tagged union and the frame bodies. |
| `protocol/parse.zig` | One JSON text frame into an arena-owned `Message`, switched on the lowercased `type` tag. |
| `protocol/serialize.zig` | `Message` to minified JSON whose tag and field order match the documented examples. |
| `actor.zig` | Single thread. Drains an MPSC inbox. The only module that composes the four registries. |
| `actor/command.zig` | Inbox `Command` union, outbound frame sink, channel create/take bridge. |
| `actor/inbox.zig` | Bounded MPSC ring. |
| `catalog.zig` | Function and service registry. Last registration wins. Teardown is CAS-gated by owner. Schemas stay raw JSON. |
| `invocation.zig` | Parks a call until a UUID-correlated result arrives or an injected-time sweep times it out. |
| `trigger.zig` | Trigger types and bindings. Type owners are replayed. Takes injected `now_ms`. |
| `channel.zig` | Keyed byte channels. Each endpoint is taken once. Idle channels are TTL-swept. Each `Pipe` is a cross-thread ring. |
| `inproc.zig` | In-process workers with a `WorkerId`. A router thread per worker. Handlers run on another thread so a blocking bus call can proceed. |
| `sync.zig` | pthread mutex, condition variable, one-shot event, counted retire gate. Zig 0.16 moved threading into `std.Io`; this restores the lock API the kernel uses. |
| `types.zig` | Shared `WorkerId` and `Uuid`. |
| `entropy.zig` | CSPRNG bytes for ids and channel keys. |

Posters stamp time. The net layer delivers outbound frames. The actor reads
neither a clock nor a socket.

### 3. Network and providers (`src/net/`)

The WebSocket gateway and the HTTP legs that speak to model providers.

| File | What it does |
|---|---|
| `ws.zig` | The module that accepts TCP. Handshake, fresh `WorkerId`, posts connect / frame / disconnect, writes outbound on the owning connection. |
| `writer_queue.zig` | Bounded per-connection writer queue (capacity 64) so a stalled TCP consumer does not block the kernel thread. |
| `provider_boot.zig` | One `zygos::providers::<slug>` worker per catalog entry, Anthropic or OpenAI-compatible. A route that names a missing slug refuses boot. |
| `provider_anthropic.zig`, `provider_openai.zig` | Bus handlers in front of the HTTP clients. |
| `anthropic.zig`, `openai.zig` | Streaming HTTP/SSE. Unit tests drive the SSE pump. Live HTTP is an env-gated smoke. |
| `stream_guard.zig` | Idle watchdog for a blocking provider stream. |
| `ticker.zig` | Posts `.tick` so a headless kernel still sweeps invocation, trigger, and channel deadlines. |
| `web_tools.zig` | `zygos::tools::web_search` and `web_fetch`. URL and SSRF screening run before any socket opens in `zig build test`. |
| `web/search.zig`, `web/html.zig` | Neutral search records, and HTML stripped and capped for token cost. |

### 4. Harness workers

The turn loop, tools, policy, approval, budget, routing, context strategies,
MCP, Tessera, and the output filters. These are in-process bus peers.

Bus functions a new reader should be able to name:

| Worker | Registration |
|---|---|
| `turn.zig` | `zygos::turns::{run,abort,steer}` |
| `tools.zig` | `zygos::tools::{bash,read_file,write_file}` |
| `policy.zig` | `zygos::policy::check` |
| `approval.zig` | `zygos::approvals::{request,resolve,pending}` |
| `budget.zig` | `zygos::budget::{configure,record,check}` |
| `router.zig` | `zygos::models::resolve` |
| `trim.zig` | `zygos::output::{compress,stats}` |
| `provider_fake.zig` | `zygos::provider::fake::messages` |
| `mcp/client.zig` | `zygos::mcp::<server>::<tool>` |
| `mcp/gateway.zig` | JSON-RPC allowlist of `zygos::tessera::*` |
| `task.zig` | One instruction, the turn loop, a step cap, a trial record |

`tools_ops.zig` is the pure file and bash core behind `tools.zig`: lexical
paths, `cwd` at the workspace root, a scrubbed environment, a deadline that
kills the shell process group. `turn/fsm.zig` is the legal turn table.
`context.zig` selects assemble/absorb from `zygos.zon`; an unknown kind
refuses boot. The three strategies are substrate, recall, and thread.

`filter/dispatch.zig` picks a command-aware compressor from a bash argv.
`filter/guard.zig` keeps a compressed form only when it is smaller and refuses
to hide a failed command. `stream_tap.zig` and `trace.zig` are observability:
a tap must leave the stream alone, and an unwritable `events.jsonl` leaves the
turn and the mission unchanged.

### 5. Mission loop

The durable state machine, brief lint, and the role driver. The mission
specs sit with this layer: `docs/specs/mission.md` and the boot, CLI, and
attach specs.

| File | What it does |
|---|---|
| `mission.zig` | Product-owner, planner, executor, verifier, then a hard human gate. Registers `zygos::missions::{start,status,abort,steer,pause,resume,list}`. Each role is one `zygos::turns::run`. |
| `mission/fsm.zig` | Legal transitions among defining, planning, executing, verifying, gating, and failed. |
| `mission/model.zig` | `Mission`, `Task`, `Role`, `StopReason`. |
| `mission/role_turn.zig` | Builds the turn request and parses `RoleOut`. |
| `mission/start.zig` | Shared bytes of `zygos::missions::start` so the CLI and the orchestrator share field names. |
| `mission/registry.zig` | One control block per live mission, under one mutex. |
| `mission_store.zig` | `.planning/` via tmp file plus rename. Appends `DECISIONS.md`. Refuses path-shaped names. |
| `mission_boot.zig` | Argv and env decisions before any kernel boots: timeouts, search key, run stamp, policy seed, worktree, vault checkpoint. |
| `brief.zig` | GOAL.md-shaped YAML frontmatter, bytes only. A failing lint refuses the mission. |
| `control.zig` | Append-only `control.jsonl` for steer, pause, resume, and approve. |

### 6. Terminal UI (`src/tui/`)

Hand-rolled raw ANSI. `tui.zig` is the barrel and re-exports `Tui` and
`emergencyRestore`. libc terminal control stays in this directory.

`model.zig` copies every byte it keeps and ignores a malformed event line.
`frame.zig` lets chat rows enter scrollback and repaints the bottom band.
`term.zig` writes fd 2 and reads keys from fd 0, leaving stdout for the final
mission JSON. `loop.zig` is one render thread. `scrub.zig` drops terminal
controls from model and tool bytes before they reach the screen.

### 7. Tests and probes (`test/`)

Unit tests live inside the modules. This layer is the exit harness.

- `test/e2e/node-sdk/` runs the unmodified iii Node SDK against the Zig kernel.
- `test/e2e/turn/`, `m2/`, `m3/`, `m8/` drive scripted turns and missions, including real bash and real git output through the filters.
- `test/e2e/m45/` drives the mission CLI against a localhost SSE stub.
- `test/e2e/timeouts/` hangs a silent provider and checks idle abort and invoke-timeout tiering.
- `test/mutation/guards.sh` edits each filter, trim, and turn guard in place and requires the suite to fail.
- `test/probe/filter/run.sh` measures bytes saved and enforces a ratio floor.
- `test/e2e/anthropic/`, `test/e2e/openai/`, and `test/smoke/providers.sh` are env-gated live smokes. They stay out of `zig build test`.

### 8. Evaluation (`eval/`)

Headless task runs and the campaign harness that compares two arms.
`eval/campaign.py` freezes a two-arm experiment that differs in one of build,
config, or trim. `eval/harbor/zygos_agent.py` uploads a Linux binary and a
keyless catalog, then runs `zygos task run` inside the task container.

### 9. Examples (`examples/`)

`examples/quickstart/` is the small hello brief and a route table.
`examples/providers.toml` is a keyless catalog row the build embeds for tests.
`examples/x5-dogfood/` and `examples/research-radar/` are historical missions.
`examples/README.md` says how to point a route table at a real catalog.

### 10. Documentation

Product, protocol, and operator documents. The ones that govern edits:

| Document | Role |
|---|---|
| `GOAL.md` | Success contract. New dependencies, `docs/PROTOCOL.md` edits, and deploys are human gates. |
| `AGENTS.md` | Red-first TDD, Zig 0.16 conventions, commit and version rules. |
| `README.md` | Operator guide: install, brief, catalog, routes, TUI, cron, MCP gateway, headless task. |
| `SECURITY.md` | Trust limits for one local operator. |
| `docs/PROTOCOL.md` | Human-gated iii wire format. |
| `docs/ARCHITECTURE.md` | Condensed sketch. Implemented boundaries live elsewhere. |
| `docs/specs/` | Per-module contracts. Read the spec for the file you are about to touch. |
| `documentation/architecture.md` | Implemented trust boundaries, with the risks tied to code. |
| `documentation/permissions.md` | Scope is the OS user, the bus worker id, and boot-time policy. |
| `documentation/variables.md` | Environment variables, secret files, transcript paths. |
| `documentation/flows.md` | Cross-boundary journeys: boot, mission start, tool dispatch, gate, web, cron, MCP, budget. |

## Key Concepts

- **Extensions are new bus functions.** Providers, tools, policy, approval, budget, trim, routing, and memory register `zygos::*` functions. `docs/PROTOCOL.md` stays the frame format. A new capability is a new function on that format.
- **Four roles, one store, one gate.** Product-owner, planner, executor, and verifier each run as one turn. `mission_store.zig` writes `.planning/` by tmp file plus rename. The mission reaches `done` only after the completion gate approves.
- **Fail closed on authority.** No matching policy rule denies. A failed policy check denies. A failing brief lint refuses the start. A route slug missing from the catalog refuses boot. An unknown context strategy refuses boot. A non-affirmative approval is a denial. Past the end of a model ladder, `zygos::models::resolve` replies `route_exhausted`, which the caller can tell apart from a down router.
- **Observability stays out of the outcome.** `trace.zig` appends `events.jsonl` and fans the line out to observers. An unwritable trace leaves the turn and the mission unchanged. `stream_tap.zig` carries thinking text and tool-call fragments the kernel channel item cannot hold, and a tap must leave the stream alone.
- **Pure tables, effectful drivers.** `turn/fsm.zig` and `mission/fsm.zig` list legal state-event pairs and do no I/O. A pair absent from the table is an illegal transition. `brief.zig`, the Tessera parsers, and `tools_ops.zig` take bytes or paths the caller already has. The orchestrators own the bus calls and the writes.
- **Two transports, one command vocabulary.** `inproc.zig` workers carry a `WorkerId` and post the same commands `ws.zig` posts for a TCP peer.
- **Confinement is lexical and local.** Tool paths reject `..`, `.`, and absolute escapes. Bash runs as the OS user, with `cwd` at the workspace root. The bus admits loopback peers. Fetch screening covers private addresses and is partial. Planning directories and real catalogs are private. `SECURITY.md` is the short version; `documentation/architecture.md` is the one tied to code.
- **The test suite does not touch the network.** Provider HTTP, live search, and the smokes are env-gated binaries. `zig build test` probes handlers and parsers with fixtures.

Working rules from `AGENTS.md`, which the graph treats as the checkout agreement: write the test from the spec first, keep allocators as parameters, use explicit error sets, and run `zig build test` and `zig fmt --check build.zig src/ test/` before a commit. Do not add a `build.zig.zon` dependency, edit `docs/PROTOCOL.md`, or deploy. Those are human gates in `GOAL.md`.

## Guided Tour

Read these in order. Each step is a graph tour stop. The file names are the nodes on that stop.

1. **What the binary does.** `README.md`, then `SECURITY.md`. A brief goes in, four roles work it, and the run is written under `.planning/` so it can resume. The security note is the trust limit that guide assumes: unsandboxed mission bash, lexical file confinement, loopback admission, partial private-address fetch screening, unsanitized traces.

2. **How a process starts.** `src/main.zig` boots the actor and then either the loopback gateway or the stdio MCP gateway. `src/root.zig` re-exports the modules and pulls their tests into `zig build test`. `src/cli/mission.zig` is the mission door. `build.zig` is how the binary is produced.

3. **The wire.** `docs/PROTOCOL.md` is the human-gated frame format: registration, invocation, trigger, ping, and channel, plus correlation, last-wins registration, owner-CAS teardown, trigger replay, and one-time channel endpoints. `src/kernel/protocol.zig` parses and serializes those frames.

4. **The kernel actor.** `actor.zig` drains the inbox and is the only composer of `catalog.zig`, `invocation.zig`, `trigger.zig`, and `channel.zig`. Callers stamp time. The actor delivers work by posting commands and outbound frames.

5. **Two ways onto the bus.** `inproc.zig` is how harness workers call the bus. `ws.zig` is how an external SDK worker connects. Both end as actor commands.

6. **Providers.** `provider_boot.zig` registers one worker per catalog entry and refuses a route whose slug is absent. `anthropic.zig` and `openai.zig` are the HTTP/SSE clients. `src/config/providers.zig` (harness layer) parses `~/.agents/providers.toml` or `AI_PROVIDERS_CONFIG` with a std-only TOML subset.

7. **One turn.** `turn.zig` assembles context, streams a model response, dispatches tools, and repeats until the model stops or the step budget ends. Before each tool call it consults `policy.zig`. `tools.zig`, `router.zig`, `budget.zig`, and `trim.zig` are the other functions that turn calls.

8. **A mission.** `mission.zig` walks the four roles over the store from `mission_store.zig`. `brief.zig` runs before the state machine and refuses a malformed brief. The hard gate is what allows `done`.

9. **The live view.** `tui.zig`, `model.zig`, and `term.zig`. The kernel stays free of terminal state. Stdout stays free for the final mission JSON.

10. **What the process will and will not do.** `documentation/architecture.md` and `documentation/permissions.md`. Bash runs as the operator. Fetch screening is partial. The executor can write the approval control file. There are no accounts and no row policies.

## File Map

Layer sections above are the map for code. Use this index when you know the area and want the file to open first.

| Area | Open first | Then |
|---|---|---|
| Boot | `src/main.zig` | `src/cli/mission.zig`, `src/worker/mission_boot.zig` |
| Wire | `docs/PROTOCOL.md` | `src/kernel/protocol.zig`, `protocol/types.zig` |
| Registries | `src/kernel/actor.zig` | `catalog.zig`, `invocation.zig`, `trigger.zig`, `channel.zig` |
| In-process bus | `src/kernel/inproc.zig` | `src/net/ws.zig` for the socket twin |
| Models | `src/net/provider_boot.zig` | `src/config/providers.zig`, `src/worker/router.zig` |
| One agent step | `src/worker/turn.zig` | `turn/fsm.zig`, `policy.zig`, `tools.zig`, `tools_ops.zig`, `trim.zig` |
| A full objective | `src/worker/mission.zig` | `mission/fsm.zig`, `brief.zig`, `mission_store.zig` |
| Operator view | `src/tui/model.zig` | `frame.zig`, `term.zig`, `loop.zig` |
| Vault | `src/worker/tessera_orient.zig` | `tessera_continuity.zig`, `tessera/vault.zig`, `mcp/gateway.zig` |
| Headless bench | `src/worker/task.zig` | `src/cli/task.zig`, `eval/campaign.py` |
| Proof | `test/e2e/node-sdk/e2e.mjs` | `test/e2e/m3/main.zig`, `test/e2e/m8/main.zig`, `test/mutation/guards.sh` |

`docs/specs/<module>.md` matches the module you are reading. The spec is the contract the tests were written from.

## Complexity Hotspots

The harness is one process with many peers, so a lot of modules are dense.
Approach these with the matching `docs/specs/` page open. They own the bus,
the turn, or the mission.

| File | Why it is sharp |
|---|---|
| `src/worker/turn.zig` | The agent loop. Policy, approval, router, budget, trim, and tools meet here. |
| `src/worker/mission.zig` | The role driver, the gate, and the live-mission control surface. |
| `src/kernel/actor.zig` | Every command lands here. A shared behavior change has the widest blast radius in the kernel. |
| `src/kernel/protocol.zig` | Every wire frame. Behavior changes go through `docs/PROTOCOL.md`, which is human-gated. `protocol/parse.zig` and `protocol/serialize.zig` are the two halves. |
| `src/kernel/catalog.zig` | Last-wins registration and owner-CAS teardown. Other registries assume this map. |
| `src/kernel/inproc.zig` | Threading that lets a handler call the bus without deadlocking its router. |
| `src/net/ws.zig` | The socket boundary. Admission, connection ownership, and outbound writes. |
| `src/net/provider_boot.zig` | Fail-closed catalog boot. A mistake here stops the process on purpose. |
| `src/cli/mission.zig` | Planning-root claim, exit codes, queue, attach, and the TUI lifetime. |
| `src/tui/model.zig` | Shared by the render thread, the trace observer, and log producers, under one mutex. |
| `src/worker/mcp/client.zig` | External MCP tools published onto the bus. Malformed replies fail closed. |
| `src/net/web_tools.zig` | Search and fetch, with screening before the socket. |
| `eval/campaign.py` | The two-arm comparison. A sloppy arm difference invalidates a benchmark. |

Filter files under `src/worker/filter/` are individually complex because a
compressor that hides a failed command or inflates output is a product bug.
`test/mutation/guards.sh` and `test/probe/filter/run.sh` exist to catch that.
`test/e2e/m8/main.zig` runs the same filters on real git output.

## Where to start

1. Read `README.md` once, as an operator, including `SECURITY.md`.
2. Walk the ten stops above. Stop at step 4 until catalog, invocation, trigger, and channel each make sense on their own.
3. Read `GOAL.md` for decision authority and `AGENTS.md` for the edit rules.
4. Pick a module, open its `docs/specs/` page, and write a failing test before changing the implementation.
5. Before a commit: `zig build test`, then `zig fmt --check build.zig src/ test/`. When the change touches `src/worker/filter/`, `src/worker/trim.zig`, or `src/worker/trim/`, also run `./test/probe/filter/run.sh`, `./test/mutation/guards.sh`, and `./test/e2e/m8/run.sh`.
