# Architecture

Zygos is a single-binary agent harness in Zig 0.16. A local operator runs it. Workers register functions and triggers on one message bus. The mission CLI drives role agents (product-owner, planner, executor, verifier) over a durable `.planning/` directory until a brief reaches `done` or `failed`.

Design intent that this map does not replace: `GOAL.md` (milestone contracts and human gates), `docs/ARCHITECTURE.md` (layer sketch, Z-01/Z-02), `docs/PROTOCOL.md` (wire format; human-gated), `docs/specs/` (per-module contracts). This file is the implemented system those audits compare against.

## Stack

- Zig 0.16.0, `std` for kernel and worker logic. One fetched dependency: `karlseguin/websocket.zig` (`build.zig.zon`). Adding another dependency is a human gate.
- Kernel concurrency (Z-02): one kernel thread owns catalog, triggers, and pending invocations. Each WebSocket connection is a reader thread plus a bounded writer queue. No `std.Io` in kernel modules.
- Process entry: `src/main.zig`. Subcommands: bare `zygos` (kernel), `zygos mission`, `zygos mcp-gateway`.
- No database, no email sender, no public HTTP site, no in-process scheduler.

## How a run is trusted

There are no user accounts, sessions, or row-level policies. Identity is the OS user who started the process, plus a random worker id on the bus.

1. **Operator process.** `zygos mission` reads env, `zygos.zon`, and `~/.agents/providers.toml` (or `AI_PROVIDERS_CONFIG`). It boots the kernel in-process and the default workers. The operator's uid is the privilege level of bash, file tools, and vault writes.
2. **Loopback bus.** Bare `zygos` listens on `127.0.0.1` (`src/net/ws.zig` `Config.address`, port `ZYGOS_PORT` or 49134). The handshake rejects unallowlisted browser Origins and can require `ZYGOS_TOKEN` as a query token. Without the token, local script clients can register functions and invoke them. `main.zig` does not expose an address override.
3. **Model tool calls.** The turn driver calls `zygos::policy::check` before a tool runs (`src/worker/turn.zig` `checkPolicy`). Missing worker, malformed verdict, or unknown verdict denies. Without a `.policy` key in `zygos.zon`, the mission CLI seeds bash, `web_fetch`, `web_search`, and configured MCP tools as `allow` (`mission_boot.policySeed`); a present `.policy` replaces the seed. Per-call prompts require an `ask` rule. The completion gate is not independent of the same-user executor shell, which can write the control channel.
4. **Completion gate.** Reaching `done` requires an affirmative approval. Unreachable gate, malformed reply, or no gate function cannot complete the mission. An unanswered deny (`resolved: false`) parks in `gating` instead of returning to rework.
5. **Provider secrets.** Catalog entries resolve `key_env` to the process environment, with an inline `key` fallback (`src/config/providers.zig`). Tests use fixtures. The real catalog is not committed.

## Trust boundaries

| Boundary | What crosses | Enforcement |
|---|---|---|
| Local peer → kernel WebSocket | iii frames, function invokes | Loopback bind, Origin guard, optional shared token. |
| Model → tool | tool name, JSON input | Policy worker, then approval if the verdict is `ask`. Default mission seed is allow; `.policy` replaces it. |
| File tools → filesystem | relative path | Lexical join under the workspace root (`tools_ops.Workspace.resolve`). Symlink targets are not re-checked. |
| Bash → process | shell string | `cwd` is the workspace. The command itself is not jailed. |
| web_fetch / web_search → network | URL or query | `http`/`https` only (`validateUrl`); partial literal-host screen for fetch, with explicit override. DNS/redirect targets remain unchecked. Search key injected at boot. |
| MCP child → bus | JSON-RPC tools | Operator argv from `zygos.zon`. Spawn failure refuses boot. |
| Mission → vault | notes under `ZYGOS_VAULT_ROOT` | Checkpoint before write; checkpoint failure refuses the run. |
| Cron → CLI | a local command | Same binary, stdin from `/dev/null`. Approvals time out and deny. |

## Known risks (each tied to code)

- Loopback bus is unauthenticated unless `ZYGOS_TOKEN` is set. A local process can invoke any registered function, including tools if those workers are running. Bare `zygos` does not boot the tool workers; `zygos mission` does, in-process, and does not open the WebSocket for them.
- File-tool confinement is lexical. `tools_ops.zig` states symlink escapes are deferred. `open` follows links.
- Bash is a shell with workspace `cwd`, not a sandbox. Default policy allows it. The running mission treats `<planning>/control.jsonl` as attach commands, including approve (`src/cli/mission.zig` `controlLoop`). The executor can append that file. `mission attach` uses the same file.
- `web_fetch` rejects recognized literal private addresses and localhost unless explicitly allowed. DNS/private-address aliases and redirect targets remain unscreened. Size caps apply (`max_fetch_bytes`, `max_text_bytes`).
- `events.jsonl` stores tool inputs and clipped outputs (README, "How a mission runs"). A fetched page or a command that prints a secret lands in that file. Emission is fail-open.
- Malformed integer env knobs (`envInt`) fall back to the compiled default. A typo does not refuse boot.
- `docs/ARCHITECTURE.md` still sketches post-M0 work in the future tense. Milestone contracts are `GOAL.md`. Do not treat the sketch as the list of what is unbuilt.

## What this system does not have

- No transactional email. No `emails.md`.
- No public or bot-facing routes. No `seo.md`.
- No database, so no SQL indexes and no migration files.
- Scheduled work is an external cron or launchd line. See `cron.md`.
- Embedded agents and tool loops are the product. See `automation.md`.

## Related documents

- `documentation/flows.md` — journeys where a check or a side effect matters
- `documentation/permissions.md` — who can do what
- `documentation/variables.md` — env, files, secrets
- `documentation/cron.md` — unattended reruns
- `documentation/automation.md` — role agents, tools, gates
- `tests.md` — which of those rules a test pins
- `GOAL.md`, `docs/PROTOCOL.md`, `docs/specs/` — intent the code is supposed to meet
