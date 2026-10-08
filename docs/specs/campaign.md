# Spec: `eval/campaign.py` — matched benchmark campaigns

The operator-facing benchmark workflow. One tracked experiment file freezes
everything two arms share and names the single thing they differ in. One
command runs every matched task-run through Harbor; one command turns the raw
job directories into a durable report that shows the measured change or says
why it is inconclusive. It answers two questions:

- Did a **release** change benchmark behavior? (`variable: build` — two git shas.)
- Did a **configuration** change it? (`variable: config` — two `zygos.zon` files.)

The third variable, `trim`, is the output-compression ablation the earlier
phases measured by hand. `zygos task run` remains the per-task entry
(`docs/specs/task.md`); the campaign never bypasses its allowlists.

## Commands

```bash
# 1. Build a Linux arm from a clean, detached worktree at a commit.
ZYGOS_ZIG=/path/to/zig-0.16 eval/campaign.py build --git-ref <sha|branch|HEAD>
#    -> zig-out/bench/<git_sha>/{zygos,build.json}; prints git_sha + binary_sha256

# 2. Write eval/experiments/<name>.json (schema below) naming both arms.

# 3. Run. One Harbor invocation per task-run, arms interleaved, resumable.
eval/campaign.py run --experiment eval/experiments/<name>.json \
    --jobs-dir /tmp/zygos-<name> --tasks-dir <dataset checkout>/tasks [--dry-run]

# 4. Report. Re-reads the raw job directories; needs no Docker or network.
eval/campaign.py report --experiment eval/experiments/<name>.json \
    --jobs-dir /tmp/zygos-<name> --out reports/benchmarks/<name>-<date>
```

Toolchain on the reference machine: plain `zig` may be 0.17; `build`
refuses anything but 0.16.x, so pass `--zig` or `ZYGOS_ZIG`. `run` needs
`harbor` on `PATH` (or `--harbor`), a reachable Docker daemon, and the
dataset checkout. The runner and report are plain Python 3.11+; the adapter
tests use Harbor's interpreter. All of `eval/test_campaign.py`,
`eval/test_run.py`, and `eval/harbor/test_zygos_agent.py` run offline.

## Experiment file

```json
{
  "name": "trim-ablation",
  "variable": "trim",
  "dataset": {
    "id": "terminal-bench/terminal-bench-2-1",
    "source": "https://github.com/harbor-framework/terminal-bench-2-1",
    "source_sha": "<git sha of the tasks checkout>",
    "tasks": [{"id": "fix-git", "checksum": "<Harbor task_checksum>"}]
  },
  "model": {"id": "deepseek/deepseek-v4.1-flash", "key_env": "DEEPSEEK_API_KEY",
            "key_from_env": "OPENROUTER_API_KEY", "max_tokens": 8192, "temperature": 0.7},
  "prices": {"source": "https://openrouter.ai/api/v1/models", "retrieved_utc": "...",
             "usd_per_million_tokens": {"input": "0.003", "cached_input": "0.003", "output": "2.40"},
             "scorer_cents_per_mtok": 30},
  "step_cap": 24, "repeats": 3, "workspace": "/app", "host_concurrency": 2,
  "ca_bundle_sha256": "<sha256 of the host PEM bundle, or omit>",
  "arms": [
    {"name": "trim-on",  "trim": "on",  "build": {"git_sha": "...", "binary_sha256": "..."}},
    {"name": "trim-off", "trim": "off", "build": {"git_sha": "...", "binary_sha256": "..."}}
  ]
}
```

- Exactly two arms: baseline first, candidate second. An arm has `trim`
  (`on` default), `build` (identity only; the artifact is found under
  `--builds-dir/<git_sha>/`), and optional `config` (a `zygos.zon` path
  relative to the experiment file).
- The arms must differ in `variable` and in nothing else. Identical trim,
  identical config sha, identical build, or a second differing axis refuses
  the experiment. This is the "single variable" rule of the benchmark policy
  made executable.
- `model.id` must be on the live allowlist. `key_env` is the variable the
  adapter binds into the container exec environment; `key_from_env`, when
  present, names the host variable whose value is always copied over it
  (an override, because a host may hold a different vendor's key under
  `key_env`; a direct DeepSeek key does not authenticate at OpenRouter).
  Values are never written anywhere.
- `tasks[].checksum` is the `task_checksum` Harbor records in `result.json`;
  a trial whose checksum differs is a problem, not a result. `source_sha` is
  checked against the tasks checkout's `HEAD` when non-empty.
- `prices` is a dated snapshot; the report labels every dollar figure an
  estimate, not an invoice. `scorer_cents_per_mtok` is the one-rate price
  row `zygos task score` consumes.
- `host_concurrency` is 1 or 2; the step cap is 1..32. Harbor retries and
  Hub upload are never enabled.

## run

Preflight, before any paid launch: image inventory `ready`; every task has
`task.toml`; the tasks checkout `HEAD` equals `source_sha`; each arm's
`build.json` and binary sha256 match the experiment; the credential resolves;
`ZYGOS_CA_BUNDLE` matches `ca_bundle_sha256` when pinned; `harbor` and the
Docker daemon answer. `--dry-run` prints the checks and the job plan and
exits without launching.

Jobs are named `<arm>-r<repeat>-<task>` and ordered so both arms of a
`(repeat, task)` pair are adjacent. Each job is one `harbor run` with
`-k 1 --n-concurrent 1 --max-retries 0 --yes`, the adapter
`eval.harbor.zygos_agent:ZygosAgent`, and the arm's binary, trim, and
config in the environment (`ZYGOS_LINUX_BIN`, `ZYGOS_TRIM`, `ZYGOS_CONFIG`).
Harbor output goes to `<job>.harbor.log`, the exit code to
`<job>.harbor-exit.txt`.

After each job the runner inspects it (below), scores the trial with
`zygos task score` (`--scorer docker` runs the Linux artifact in a
network-less `debian:bullseye-slim`; `--scorer native --native-bin` uses a
host binary) into `<job>.score.txt` / `<job>.score-exit.txt`, and appends
the record to `campaign.json`. A job directory that already exists is
inspected, not rerun, so an interrupted campaign resumes with the same
command; `--arm` runs one arm.

Stop condition: a job with any problem (transport failure, missing trial,
Harbor exception, identity or checksum mismatch, every tool input empty)
stops new launches while in-flight jobs drain; the status becomes
`stopped: <job>: <reasons>` and the exit code is 4. Zero rewards, step or
output limits, and scorer refusals are recorded outcomes and do not stop
the campaign.

## Inspection

Per job, from raw files only: `result.json` (reward, exception, task
checksum, elapsed), `agent/zygos` sha256 against the arm, `agent/providers.toml`
free of inline keys, `agent/trial.json` identity (task, dataset, model,
`trim-<arm>`, step cap, git sha, `config_sha256` equal to the arm's config
sha or absent), `agent/events.jsonl` (usage sums equal the trial, no cache
field on the usage line, steps, tool calls, empty inputs, handler failures,
terminal stop and error), and the scorer files. Every deviation lands in the
record's `problems` list. A failed turn whose error is not
`unknown_provider_stop` is a transport failure; a trace with no `turn_end`
is a lost turn (the harness overran an outer ceiling) and also a problem.
`end_turn`, `max_steps`, `max_tokens`, and `timeout` are recorded stops.

## report

Per arm: expected and recorded task-runs, verifier passes and pass rate,
input/output/cache-read tokens, snapshot USD and USD per resolved task, mean
provider steps and elapsed seconds, turn stops, trim compress calls, scorer
accepted/refused/unscored and the mean accepted reduction, transport
failures, Harbor exceptions, and the count of task-runs with problems.
Matched table: one row per `(task, repeat)` with both rewards, the pass
delta, the cost delta, and any problems.

Verdict, in order:

1. `inconclusive` when either arm is missing task-runs or has any task-run
   with problems. The reasons are listed.
2. `candidate_better` / `candidate_worse` on the verifier pass delta; on a
   zero pass delta, on a cost delta beyond ±5%; otherwise
   `no_observed_difference`. The caveats always state the pass and cost
   deltas, warn below 24 matched task-runs, and for `trim` state both arms'
   scorer acceptance.

Outputs under `--out`: `report.json`, `report.md`, `experiment.json`, and
each arm's config as `<arm>.zon`. The report carries numbers, identities, and
paths; instructions, model output, and credentials stay in the jobs
directory. The report must run from fixture job directories with no Harbor,
Docker, or network — that is what `eval/test_campaign.py` checks.

## What this does not do

It does not run missions. `zygos task run --config` honors only the route
table (`.default`/`.routes`); a `zygos.zon` carrying `.context_strategy` or
`.mcp_servers` refuses, so a mission-only setting cannot be "measured" by a
task campaign that never executes it. Measuring those settings needs the
mission FSM inside the task container, which is a separate workload.
It also does not choose a dollar cap or expand the task set; both remain
operator decisions recorded in `docs/benchmark-policy.md`.
