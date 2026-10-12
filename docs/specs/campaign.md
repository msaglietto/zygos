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
  identical config sha and pipeline (mission definition files included),
  identical build, or a second differing axis refuses
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

## Mission mode

`"mode": "mission"` runs every task through the mission loop instead of
the single headless turn, so a `zygos.zon` is exercised as a mission
configuration: which model (and failover ladder) does each step of the
pipeline (by default product-owner, planner, executor, verifier), and,
with `.steps`, which steps exist. Each arm must carry a
`config`; `variable` is `config` or `build` (`trim` is task-only). The
adapter (`ZYGOS_MODE=mission`) turns the instruction into a brief that
passes the W1 lint (objective last, level-2 headings inside the instruction
demoted), uploads the route table and a keyless catalog with both approved
rows (`deepseek-flash`, `glm-flash`), and runs
`zygos mission start brief.md --planning <agent-dir>/planning --no-tui`
in the task workspace. No console answers the completion gate, so
`ZYGOS_APPROVAL_TIMEOUT_MS=1000` parks the mission after verification and
Harbor's verifier judges the workspace. `ZYGOS_ROLE_MAX_STEPS` is the step
cap and `ZYGOS_MISSION_TIMEOUT_MS` sits 45 s under the exec ceiling.

Preflight additionally requires the key for every catalog slug any arm's
route table names (`DEEPSEEK_API_KEY`, `Z_AI_API_KEY`); an unknown slug
refuses. Evidence per job: `agent/mission-run.json` (config and brief
hashes, pipeline, step cap, exit code), `agent/mission.json` (the CLI's terminal
reply, or `state: lost` with stop `no_terminal_reply` when the process
ended without one), `agent/zygos.zon`, and `agent/planning/events.jsonl`.
Usage is the sum of the trace's usage lines, which carry no cache counts:
every input token is priced at the ordinary rate, the record says
`cache_unreported`, and the report's caveats repeat it. The scorer does not
apply. The report adds mean role turns, mission states, and role failures.
A lost terminal reply is a recorded stop, not a problem; a missing trace or
`mission-run.json` is.

**Pipeline.** A mission arm's `zygos.zon` may carry `.steps`
(`docs/specs/mission.md`, "Pipeline config"), so a mission campaign can
compare which steps exist, in what order, with which definitions and tools,
as well as who does each one. Absent `.steps` is the default pipeline
(`product-owner`, `planner`, `executor`, `verifier`; built-in prompts; tools
on the executor only). `eval/campaign.py` reads the block with a strict
parser of its own and refuses the experiment when it cannot parse it, when a
step names an unknown key or no `.id`, or when a `.definition` is absolute,
holds a `..` component, resolves (after symlinks) outside the `.zon`'s
directory, or is unreadable, empty, or over 64 KiB. It does not repeat the
binary's other boot checks (reserved ids, a missing executor, a verifier
with tools); the mission refuses those at start and the job records the
failure.

- **Arm identity.** The definition files count. Each arm carries
  `pipeline: [{"id","definition_sha256","tools"}]` (`definition_sha256` is
  the SHA-256 of the file's raw bytes, null for a built-in), in
  `report.json` and the report's arm table. Two arms with byte-identical
  `.zon` files and different definition bytes are different arms.
- **Single variable.** A differing pipeline (ids, order, definition hashes,
  tools) is part of the `config` axis, alongside the `.zon`'s own SHA-256:
  `variable: config` accepts it, `variable: build` refuses it as a second
  differing axis, and arms identical in both refuse as "do not differ".
- **Inspection.** The mission's first trace event is `pipeline`
  (`{"ts":N,"event":"pipeline","steps":[{"id","definition_sha256","tools"}]}`).
  Inspection finds it in `planning/events.jsonl` and compares `steps` with
  the arm's pipeline. A missing event or any difference is a recorded
  problem (`pipeline event missing`, `pipeline event differs from the arm`),
  like the config SHA-256 check. `mission-run.json` carries the pipeline the
  adapter uploaded (`id`, `definition`, `definition_sha256`, `tools`); a
  difference from the arm is a problem too.
- **Adapter.** Each `.definition` file is uploaded next to the uploaded
  `zygos.zon` at the same relative path, so the path resolves inside the
  container. A definition may not shadow a file the adapter owns
  (`zygos`, `zygos.zon`, `brief.md`, `providers.toml`, `planning/`).
- **Mission states.** The terminal reply and the metric use the mission's
  states: `running`, `gating`, `done`, `failed`. A parked mission is
  `gating`; the reply also carries `step` (string or null) and `step_index`.
  The report's "Mission states" row counts them verbatim, and the arm table
  adds a `pipeline` row.
- **Step-count budget caveat.** Each step turn increments `role_turns_used`
  against `max_role_turns` (`docs/specs/mission.md`, "Each step turn
  increments `role_turns_used`…"), so a longer pipeline reaches the cap
  sooner. An arm that adds steps spends part of the same budget on them;
  read a lower pass rate or a `role_turns_exhausted` stop in that light, and
  compare mean role turns before crediting or blaming the extra step.

`.context_strategy` and `.mcp_servers` in an arm's `zygos.zon` are honored
by the mission (the mission CLI reads them), so a mission campaign can
compare those too.

Experiments: `eval/experiments/mission-smoke.json` (one task, one repeat,
to prove the path) and `eval/experiments/mission-routing.json` (the
eight-task canary, three repeats; every step on DeepSeek Flash versus the
executor step on GLM Flash) with route tables under
`eval/experiments/configs/`.

## What this does not do

A task-mode campaign (`mode: task`) runs one headless turn and honors only
the route table; a `zygos.zon` carrying `.context_strategy`,
`.mcp_servers` or `.steps` refuses there (the binary refuses it; the
campaign still reads `.steps` into the arm identity). It does not choose a dollar cap or expand the
task set; both remain operator decisions recorded in
`docs/benchmark-policy.md`.
