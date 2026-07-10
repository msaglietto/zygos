# Spec: `zygos mission start|resume` — the mission CLI (X3)

Binary glue in `src/main.zig` (plus a small `src/cli/mission.zig` if the
wiring outgrows main): boot the kernel + the default worker roster + the
provider catalog, validate the brief, drive one mission to a terminal state.
This is the door X5's dogfood run walks through. The wiring template is
`test/e2e/m3/main.zig` — same roster, with the fake provider replaced by the
X2 `CatalogBoot` and auto-approve replaced by a console approval path.

## Invocation

```
zygos mission start <brief.md> [--planning <dir>] [--resume]
zygos mission resume <brief.md> [--planning <dir>]   # sugar for --resume
```

- Brief: W1 lint (`brief.lint`) runs first; a failing lint prints the
  structured reason to stderr and exits 2 — no kernel boots (fail closed).
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

turn orchestrator, `CatalogBoot` provider instances, agent-tools, policy
(fail-closed; `ask` on bash), approval worker in `.manual` mode, router,
budget, trim, mission orchestrator. Missing pieces at boot are exit-2
errors, never silent omissions.

## Console approvals (fail closed)

The approval worker runs `.manual` (deny on timeout). The binary runs a
console loop: poll `zygos::approvals::pending`, print each pending
`{id, tool, reason}` to stderr, read `y`/`n` from stdin (libc fd 0 — Z-02:
no std.Io in main), resolve over `zygos::approvals::resolve`. stdin EOF or
not-a-tty ⇒ stop prompting entirely and let the manual timeout deny
(fail closed — an unattended mission can never self-approve a gate).

## Progress

Stream to stderr: one line per mission state transition and per role turn
(`state=executing role=executor turn=5 ...`), plus the terminal reply JSON
(state/stop/role_turns/tasks_done) to stdout. Exit 0 on `state=done`,
1 on `failed`/`aborted`, 2 on config/boot errors.

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
4. Kill the process mid-mission on a second run, then `zygos mission resume`
   finishes it from `.planning/` (V4 semantics through the real CLI).
5. A zygos.zon naming an unknown slug exits 2 before any kernel boot.

`zig build test` stays network-free; the stub binds 127.0.0.1 only.
