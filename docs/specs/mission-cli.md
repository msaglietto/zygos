# Spec: `zygos mission start|resume` — the mission CLI (X3)

Binary glue in `src/main.zig` (plus a small `src/cli/mission.zig` if the
wiring outgrows main): boot the kernel + the default worker roster + the
provider catalog, validate the brief, drive one mission to a terminal state.
This is the door X5's dogfood run walks through. The wiring template is
`test/e2e/m3/main.zig` — same roster, with the fake provider replaced by the
X2 `CatalogBoot` and auto-approve replaced by a console approval path.

## Invocation

```
zygos mission start <brief.md> [--planning <dir>] [--resume] [--run-stamp] [--no-tui]
zygos mission resume <brief.md> [--planning <dir>]   # sugar for --resume
zygos mission trace <planning-dir>                   # render events.jsonl
```

- `--run-stamp` (Y3, unattended reruns): the planning root becomes
  `<root>-YYYYMMDD-HHMMSS` so every scheduled invocation gets its own
  substrate. Without it, a non-resume start over an existing substrate
  **refuses** (exit 2) instead of clobbering — no double-start races.
- `--no-tui` (or `ZYGOS_NO_TUI=1`): keep the plain stderr banner even on a
  tty. Piped/CI runs fall back automatically.
- `trace` renders the structured `events.jsonl` the mission writes (see
  README "Mission trace").

- Brief: the file's text rides the `missions::start` request as `brief`
  (the W1 lint refuses malformed briefs server-side); the CLI also runs
  `brief.lint` up front so a failing lint prints the structured reason to
  stderr and exits 2 before any kernel boots (fail closed). `objective` =
  the brief's `## Objective` section body if present, else the whole body.
- Provider catalog: `configPath` (`AI_PROVIDERS_CONFIG` else
  `~/.agents/providers.toml`), X1 `Catalog.parse`; a parse/validation error
  prints the Diag (line + message) and exits 2.
- Route table: `ZYGOS_CONFIG` else `./zygos.zon` (`router.Config`); after
  parse, X2 `checkRoutes(catalog, config)` — an unknown
  `zygos::providers::<slug>` refuses to boot, exit 2.
- Planning root: `--planning` else `./.planning`. Workspace root for
  `agent-tools`: the cwd.
- Budget scope + limits, gates, escalation: from the brief frontmatter (the
  existing W1/V5 machinery — no new knobs).

## Worker roster (the "default" slider position, per e2e/m3 + catalog)

turn orchestrator, `CatalogBoot` provider instances, agent-tools, web-tools,
policy (fail-closed; as built **bash boots as `allow`**, not `ask` — the
per-tool ask deferral is noted in `cli/mission.zig`; web_fetch/web_search
and configured MCP tools also boot `allow`), approval worker in `.manual`
mode, router, budget, trim, mission orchestrator, MCP clients for any
`.mcp_servers` entries in `zygos.zon` (a broken server refuses the run at
boot). Missing pieces at boot are exit-2 errors, never silent omissions.

When `ZYGOS_VAULT_ROOT` is set, the CLI takes a **tessera-undo checkpoint of
the vault before the mission runs** (Y5): checkpoint failure refuses the run
(fail closed) — artifacts never land in an un-undoable vault.

## Console approvals (fail closed)

The approval worker runs `.manual` (deny on timeout). The binary runs a
console loop: poll `zygos::approvals::pending`, print each pending
`{id, tool, reason}` to stderr, read `y`/`n` from stdin (libc fd 0 — Z-02:
no std.Io in main), resolve over `zygos::approvals::resolve`. stdin EOF or
not-a-tty ⇒ stop prompting entirely and let the manual timeout deny
(fail closed — an unattended mission can never self-approve a gate).

## Progress

The mission/turn workers' existing `std.log` lines are the progress feed
(stderr, default log level info for the binary); on a tty the live TUI
replaces the banner (see README "Mission TUI"). The terminal reply JSON
(state/stop/role_turns/tasks_done) goes to stdout. Exit 0 on `state=done`,
1 on `failed`/`aborted`, 2 on config/boot errors.

## Environment knobs (as built)

Tiered timeouts (one flat deadline cannot serve a mission and its calls):

- `ZYGOS_MISSION_TIMEOUT_MS` (default 24h) — per-function override on
  `zygos::missions::` via the actor's `invoke_timeout_overrides`; the only
  bound on total mission duration.
- `ZYGOS_INVOKE_TIMEOUT_MS` (default 1h) — every other bus invocation.
- `ZYGOS_STREAM_IDLE_MS` (default 120s, `0` disables) — provider-stream idle
  watchdog (see `net/stream_guard.zig`), wired through `provider_boot`.
- `ZYGOS_APPROVAL_TIMEOUT_MS` (default 300s) — manual-approval deny timer.

Others: `ZYGOS_BUDGET_MAX_TOKENS` (default 1M), `ZYGOS_ROLE_MAX_STEPS`
(default 24), `ZYGOS_MAX_ROLE_TURNS` (default 48),
`ZYGOS_SEARCH_ENGINE`/`ZYGOS_SEARCH_ENDPOINT`/`ZYGOS_SEARCH_KEY_ENV`
(web-search backend config), `ZYGOS_VAULT_ROOT` (pre-mission checkpoint,
above), `ZYGOS_NO_TUI`, `ZYGOS_TUI_CAPTURE` (raw-frame debug tee),
`ZYGOS_LOG` (log filter), `COLORTERM` (truecolor detection).

> ⚠️ **Known defect (flagged 2026-07-18, unfixed):** the brave search branch
> of `searchConfigFromEnv` sets `key_env` but nothing ever resolves it into
> `key`, and `web_tools` reads only `key`. Net effect: brave `web_search`
> through the mission CLI always returns `MissingSearchKey` even with
> `BRAVE_API_KEY` set. searxng (keyless) works.

## Resume

`--resume` (or the `resume` verb) sends `resume:true` with the same
`mission_id`/`planning_root` — the V4 path: earlier roles are not re-run.
`mission_id` derives from the brief filename stem unless the frontmatter
names one.

## Verified by (X3 criterion)

`test/e2e/m45/run.sh` — no real network:
1. Start a localhost SSE stub (an HTTP server scripted with the M3 role
   messages as chat-completions SSE streams, `[DONE]`-terminated; any small
   runtime already used under `test/e2e/` is fine).
2. Write a fixture providers.toml whose entries point at the stub, a
   zygos.zon routing each role's `step_id` to `zygos::providers::<slug>`,
   and a passing brief.
3. `zygos mission start brief.md` with stdin closed (approvals must fall to
   fail-closed paths the script tolerates — script the policy/gate config so
   the mission completes without a console) runs to `state=done`, exit 0.
4. Seed a mid-flight `.planning/` substrate (the e2e/m3 leg-2 pattern —
   deterministic, unlike killing a live process), then `zygos mission
   resume` finishes it through the real CLI (V4 semantics; earlier roles
   not re-run). The live kill+resume happens in X5's manual dogfood run.
5. A zygos.zon naming an unknown slug exits 2 before any kernel boot.

`zig build test` stays network-free; the stub binds 127.0.0.1 only.
