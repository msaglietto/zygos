# Scheduled work

The kernel has trigger *types* on the wire (`cron` is a legal trigger type id in the protocol). Nothing inside the binary fires on a clock. M4.6/Y3 puts the schedule outside: cron or launchd execs the CLI.

## Inventory

| Job | Schedule | What runs | Secrets | Limits | Retry |
|---|---|---|---|---|---|
| Weekly mission (operator recipe) | Operator's crontab. README example: `0 7 * * 1` | `zygos mission start <brief.md> --run-stamp` with stdin closed | Same env as an interactive run: catalog keys, `ZYGOS_SEARCH_*`, `ZYGOS_*` ceilings | Budget, role steps, mission timeout, stream idle | Cron does not retry a failed process. A second invocation with `--run-stamp` is a new planning root, not a replay of the first. |

There is no job queue, no internal HTTP trigger, and no `?source=cron` endpoint.

## Idempotency

- `refuseStart`: a start against an existing substrate, without `resume` and without `--run-stamp`, exits 2 and does not clobber.
- `--run-stamp` appends the stamp to the planning root, so each cron fire gets its own directory.
- An unanswered completion gate parks (`resolved:false`). It does not replan and does not mark `done`. The next weekly fire does not resume that park unless the operator points `mission resume` at it.

## Authentication of the internal call

The crontab is the authentication. The process is the operator's uid. Closed stdin makes approval timeouts deny. There is no second credential for "this invocation is cron".

## Seeing the last run

- Process exit code: 0 `done`, 1 `failed` or `aborted`, 2 boot or usage.
- `<planning-root>/events.jsonl` and the state file.
- `zygos mission trace <planning-root>`.

## Recipe (from README, as built)

```cron
0 7 * * 1  cd /path/to/workspace && ZYGOS_CONFIG=/path/to/zygos.zon \
  /path/to/zygos mission start /path/to/brief.md --run-stamp < /dev/null
```

Export provider `key_env` variables and, for brave search, `ZYGOS_SEARCH_ENGINE` plus the key variable in that crontab environment. A missing brave key does not fail boot; each `web_search` returns `MissingSearchKey`.
