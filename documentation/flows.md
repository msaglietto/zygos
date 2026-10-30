# Flows

Journeys that cross a trust boundary or cause a side effect. Feature tours are in `README.md` and `docs/specs/`.

Actors: **operator** (the OS user), **kernel** (bus), **model** (a provider worker), **policy**, **approver** (console, TUI, or timeout), **cron** (external).

## 1. Bare kernel

- **Precondition.** Operator runs `zygos` with no subcommand.
- **Sequence.** `main.zig` binds `127.0.0.1:ZYGOS_PORT` (default 49134). A local peer completes the iii handshake and receives a random worker id. It registers functions and triggers. Invocations are correlated by invocation id (`kernel/invocation.zig`). Catalog teardown is owner-CAS: a stale disconnect does not evict a newer registration (`kernel/catalog.zig`).
- **Authz.** None inside the protocol. The deny case is "cannot open the port" (not loopback, or port taken). A peer that can connect can invoke anything registered on that process.
- **Side effects.** In-memory registries only, until a worker performs them.

## 2. Mission start

- **Precondition.** Operator runs `zygos mission start <brief.md>` with a catalog and `zygos.zon` route table.
- **Sequence.**
  1. Parse argv (`mission_boot.parseArgs`). Usage errors exit 2.
  2. Load provider catalog. Unknown route slug refuses boot before the kernel runs (X2).
  3. W1 brief lint (`worker/brief.zig`). A failing lint returns a structured refusal and does not start the FSM.
  4. Boot workers: tools, policy (rules from `.policy` in `zygos.zon` when present, else `policySeed`: bash / web_fetch / web_search / MCP names = allow), web tools, approvals, router, budget, trim, orchestrator. Optional MCP children; spawn or handshake failure exits 2. A malformed `.policy` exits 2 before the kernel boots; a rule naming a tool no step is offered exits 2 after the MCP handshake.
  5. `budget::configure` with `budgetMaxTokens`: `ZYGOS_BUDGET_MAX_TOKENS` if set, else the brief's `budget.max_tokens`, else 1_000_000.
  6. If `ZYGOS_VAULT_ROOT` is set, `tessera::checkpoint`. Failure exits 2.
  7. `missions::start` runs the pipeline: state `running` while a cursor walks the steps (by default product-owner, planner, executor, verifier), then `gating`, then `done` or `failed`. The first trace line is a `pipeline` event, followed by a `policy` event when `.policy` is present. Each step run is one turn with its own `step_id`.
- **Authz.** Boot refusal is the deny case for bad config (including a malformed `.policy`), bad brief, unknown provider, or a vault that cannot be checkpointed. Tool calls during the mission use flow 3. Completion uses flow 4.
- **Side effects.** `.planning/` writes (atomic tmp+rename). Workspace file writes and bash. Optional vault notes. `events.jsonl`. Provider HTTP calls. Search/fetch HTTP calls.

`mission resume` sets `resume:true` and does not re-run earlier roles. A fresh start over an existing substrate refuses unless `--run-stamp` or resume (`refuseStart`).

## 3. Tool dispatch

- **Precondition.** A role turn is in `dispatching` and the model emitted a tool call. Executor is the role that receives tools.
- **Sequence.** Driver resolves the tool function on the bus. If the turn has a `policy_function`, `checkPolicy` runs first with tool name, function id, and the raw input (the URL is inside that JSON for web tools). `allow` dispatches. `ask` calls `approvals::request` with the input, the step id and the policy reason, and blocks in `awaiting_approval`; only the outcome `allowed_once` dispatches (`rejected`, `unavailable` on timeout, `cancelled` on SIGINT or worker stop, and a reply without a known outcome all become the `approval_denied` error result). The approval worker traces the ask as `approval_asked` and the answer as `approval_decided`. `deny`, bus error, malformed verdict, or unknown verdict becomes an `is_error` tool result and the turn continues. Tool output passes `zygos::output::compress` when the seam is wired. Usage is recorded on the budget scope.
- **Authz.** The policy worker's own default is deny when no rule matches (`policy.zig`). Without `.policy`, the mission seed overrides that for the named tools by installing allow rules. With `.policy`, the operator's ordered list is the only rule set and a tool it does not name is denied. A turn with no `policy_function` is the M1 path and does not consult policy.
- **Deny case.** Denied tool does not run. Unreachable budget check stops the turn with `stop:"budget_exhausted"`.
- **Side effects.** Whatever the tool does (shell, files, HTTP, MCP). Trim stats and budget counters update.

## 4. Completion gate

- **Precondition.** Verifier passed and the mission is in `gating`.
- **Sequence.** Orchestrator calls the gate through `approvals::request`. Only an explicit approval moves to `done`. Missing gate function, unreachable gate, or malformed reply cannot complete. A deny with `resolved:true` (or no `resolved` field) feeds back into rework (the mission returns to `running` at the last executor step), bounded by `gate_threshold`. A deny with `resolved:false` (manual timeout, including closed stdin) parks in `gating` with `paused:true`. `mission resume` re-asks.
- **Authz.** The approver is the operator at the TUI/console, the timeout, or any writer of `<planning>/control.jsonl` (the attach channel, including the executor's shell). EOF does not approve. A line in that file can.
- **Side effects.** State file updated. Parked missions do not return to rework and do not mark `done`.

## 5. Web fetch and search

- **Precondition.** Policy allowed the call. Search requires `ZYGOS_SEARCH_ENGINE`.
- **Sequence.** `validateUrl` rejects non-http(s) and URLs with no host. Fetch reads up to `max_fetch_bytes`, strips tags, caps text. Non-2xx, oversize, or non-text is a structured error. Search: brave resolves `key` at boot from `ZYGOS_SEARCH_KEY_ENV` or `BRAVE_API_KEY` (`searchConfigFromEnv`). A null key returns `MissingSearchKey` naming the variable. One retry on HTTP 429 only. searxng needs `ZYGOS_SEARCH_ENDPOINT` and no key.
- **Authz.** Policy on the way in. No host allow-list on the way out.
- **Side effects.** Outbound HTTP. Bytes may be trimmed and copied into the next model prompt and into `events.jsonl`.

## 6. Unattended rerun

- **Precondition.** Cron or launchd runs `zygos mission start <brief> --run-stamp` with stdin closed.
- **Sequence.** `--run-stamp` builds a new planning root (`<base>-<stamp>`). Closed stdin makes approval timeouts deny. An unanswered completion gate parks (flow 4) rather than returning to rework. Refuse-if-existing still applies when the flag is absent.
- **Authz.** The OS user of the crontab. No separate internal credential.
- **Side effects.** A new `.planning-*` tree per invocation. Network and tool effects as in flows 2–5.

## 7. MCP gateway

- **Precondition.** `ZYGOS_VAULT_ROOT` is set. Client speaks JSON-RPC on stdio.
- **Sequence.** Gateway exposes `zygos::tessera::*` that are registered (orient, continuity, undo). `capture` is not registered on this path. `tools/call` becomes a bus invocation. Unknown tool or bus error is a JSON-RPC error.
- **Authz.** Whoever can write the process stdin. No token.
- **Side effects.** Vault reads and continuity/undo writes under the configured root.

## 8. Budget stop

- **Precondition.** A scope was configured.
- **Sequence.** Each provider step records usage. `check` over limit, or a check that cannot be answered, stops the turn `budget_exhausted`. The mission fails closed rather than continuing unpaid.
- **Authz.** Not an authorization check. It is a spend ceiling.
- **Side effects.** Turn and then mission stop. No further provider calls for that turn.
