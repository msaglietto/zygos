# Spec: `src/worker/mission_boot.zig` — mission-boot decision layer

The pure argv→config rules `zygos mission` applies before any kernel boots.
`cli/mission.zig` stays binary glue (libc IO, worker wiring); every
fail-closed decision lives here, tested:

- **Arg parsing** — `parseArgs(argv)`: `start|resume|trace`, `--planning`,
  `--resume`, `--run-stamp`, `--no-tui`. `resume` normalizes to start +
  resume_flag; a missing brief/target or stray positional is `error.Usage`.
- **Timeout ceilings** — `timeouts(env)`: invoke (1h), mission (24h,
  `zygos::missions::` override), approval (5m), budget tokens, role
  steps/turns. Env overrides parse; malformed values keep defaults (boot
  must not die on a typo).
- **Brief budget** — `briefBudgetMaxTokens(text)` + `budgetMaxTokens(env,
  text)`: the frontmatter `budget.max_tokens` W1 already requires is the
  enforced budget; an explicitly set `ZYGOS_BUDGET_MAX_TOKENS` overrides
  it, the Timeouts default (1M) backstops both. Queue mode resolves per
  brief. Before this, the declared budget was decorative and the CLI
  default silently governed (issues/0003).
- **Search backend** — `searchConfigFromEnv(env)`: brave|searxng from
  `ZYGOS_SEARCH_*`. The brave branch resolves the `key_env` variable into
  `SearchConfig.key` HERE — web_tools never reads the environment (the Y5
  defect: an exported key still failed as MissingSearchKey). Unset key
  keeps the structured per-call error.
- **Run-stamp refusal** — `refuseStart` + `planningRoot`: a fresh start
  over an existing `mission.json` refuses instead of clobbering;
  `--run-stamp` suffixes the planning root per scheduled invocation (Y3).
- **Policy seeding** — `policySeed`: bash/web_fetch/web_search + configured
  MCP tools, all `.allow` (the console gate is the human boundary).
- **Vault checkpoint** — `checkpointRequest`/`checkpointVerdict`: with
  `ZYGOS_VAULT_ROOT` set, a failed `zygos::tessera::checkpoint` refuses the
  run (fail closed) — never write into an unprotected vault.

No IO in this module: the CLI supplies env pairs, argv, and filesystem
facts, and wires the results.
