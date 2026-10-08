# Spec: `zygos task` — headless trial

The Harbor-facing entry. One instruction, the existing turn loop, a step cap, and a `trial.json`. This is not a mission: there is no product-owner and no completion gate. Exit 0 means the process finished and wrote a trial, including when a tool was denied. Exit 2 is a refusal (bad args, unapproved live model, unknown git sha, workspace missing). Exit 1 is out of memory.

The mission FSM is a different number and is not what this command measures.

## Commands

```bash
zygos task run --offline --workspace DIR --out trial.json [--events events.jsonl] [--trim on|off]
zygos task run --model MODEL ... [--config zygos.zon]
zygos task score --trial trial.json --prices prices.txt
```

`--offline` selects the scripted provider. Without it, a complete authorized live invocation as described below is required; incomplete invocations or models outside the allowlist exit 2. The offline path does not read the provider catalog, the vault, or the network. Its script is bash `seq 1 500` (over the trim line cap), a read of `fixture.txt` (three lines, the only `source_lines_read`), a write of `note.txt`, then end of turn.

`--trim off` does not register `TrimWorker`. The trial still carries a zero snapshot. `--trim on` (the default) starts the worker with the mission CLI limits: 65536 bytes, 400 lines, head 120, tail 80.

The live-model allowlist contains `glm-5.3-flash` and `deepseek/deepseek-v4.1-flash`; invocations require the pinned dataset, an instruction file, a task id, and step cap 1–32. Other models remain refused. The current campaign and all reruns use Deepseek Flash under the standing authority in [Benchmark operating policy](../benchmark-policy.md); agents advance between its planned phases without a new permission request. The DeepSeek Harbor catalog uses OpenRouter's OpenAI-compatible endpoint, `DEEPSEEK_API_KEY` only in the exec environment, `max_tokens = 8192`, and `temperature = 0.7`. `ZYGOS_JOBS_DIR` gives `eval/run.sh` a separate jobs directory; every invocation still launches one task with no retries or Hub upload. The model allowlist is an input check; campaign authority is an operator policy, not a per-phase check in the CLI.

The Flash route requires an OpenRouter credential. A key for DeepSeek's direct API does not authenticate at OpenRouter. When the host stores the matching credential as `OPENROUTER_API_KEY`, bind that value to `DEEPSEEK_API_KEY` in the launch process environment. Keep credentials out of the container catalog, command arguments, and diagnostic output.

Adapter setup preserves any existing Linux certificate bundle. A minimal image with none requires `ZYGOS_CA_BUNDLE` to name the operator-selected host PEM bundle; setup copies it to the standard container trust-store path before inference. An absent or malformed source, a failed probe, or a failed directory creation stops setup. TLS verification remains enabled, and this setup is identical in both trim arms. The OpenAI-compatible client allows at most three request-setup attempts for transient `NameServerFailure`, separated by one-second cancellable delays. This happens before sending an HTTP body; other errors and later request stages stop normally. Harbor task retries remain zero.

`prices.txt` is one `<model_id> <cents_per_mtok>` row per line. `#` comments are ignored. A zero price is a free model. A missing row for the trial's model is `MissingPrice`.

## Configuration (`--config`)

A live run may name a `zygos.zon`. The task honors only its route table: the `task` route when present, else `.default`, walked as the escalation ladder for step id `task` through `zygos::models::resolve`. Each attempt is called through its own task bridge (`zygos::provider::task::via::<function>`) so usage and cache counts are still copied onto the trial, and an upstream failure fails over to the next attempt exactly as a mission turn would. Any other top-level setting (`.context_strategy`, `.mcp_servers`, anything unknown) refuses the run with `UnsupportedSetting` instead of being ignored: a configuration arm must change something this path executes. Before any provider boots, every attempt must name an approved model and a `zygos::providers::<slug>` present in the catalog with a resolvable key, and `--model` must equal the first attempt's model (`ModelRefused`, `UnknownProviderSlug`, `MissingKey`, `ModelMismatch` exit 2). The catalog rows the ladder names are the ones booted. `--offline` with `--config` is a usage error: the offline fixture stays byte-stable. The trial records the file's SHA-256 as `config_sha256`. The Harbor adapter uploads the host file named by `ZYGOS_CONFIG` and passes it as `--config`; the DeepSeek catalog row's slug is `deepseek-flash`.

## Trial fields

Fixed key order so two offline runs match byte for byte. Cache keys are omitted when the provider sent none; `config_sha256` is omitted when there was no config.

- `task_id`, `dataset`, `model_id`, `variable` (`trim-on` or `trim-off`), `step_cap`
- `git_sha`, `target_triple`, `optimize`, `adapter_version` (currently `0.2.0`; `0.1.0` records have no `config_sha256`)
- `config_sha256` when present: 64 lowercase hex characters, else `MalformedTrial`
- `source_lines_read` from successful `read_file` only
- `input_tokens`, `output_tokens`
- `cache_read_tokens`, `cache_creation_tokens` when present
- `trim`: `calls`, `filtered`, `deduped`, `raw_bytes`, `sent_bytes`, `reduction`

`reduction` is `(raw - sent) * 100 / raw` when `raw > 0` and `sent < raw`, else 0. The git sha is the Zygos build, not the task workspace. A dirty worktree, a missing git checkout, or a hash that is not 40 or 64 hex characters embeds `unknown`, and the task command then refuses to write a trial. `optimize` is the build mode name (`Debug`, `ReleaseSafe`, `ReleaseFast`, `ReleaseSmall`).

The trace file given to `--events` stays the usage line from `trace_event.zig`: `input_tokens` and `output_tokens`. Cache counts are not added there.

The SSE clients preserve reported cache counts in their terminal usage payload for copying to the trial, including OpenRouter's `prompt_tokens_details.cached_tokens` and `cache_write_tokens`. Unreported counts remain absent. OpenAI-compatible `input_tokens` retains the provider's total prompt count, including cached input; its three-rate cost calculation charges `(input_tokens - cache_read_tokens)` at the ordinary input rate and cache reads at their separate rate. The scorer formula below is unchanged and is not a provider invoice.

## Bench policy

Deny by default. Allowed tool names: `bash`, `read_file`, `write_file`, inside the workspace. An unknown tool name, a path that escapes the workspace, and a policy worker that is missing or returns a failure all deny. The turn result carries `unknown tool`, `PathEscapesWorkspace`, or `policy_denied`. The process still exits 0. Mission policy is unchanged. See `docs/adr/001-bench-allowlist.md`.

## Scorer

`zygos task score` exits 0 and prints `cents`, `source_lines_read`, and `reduction`, or exits 2 and prints the error name.

Refused: trim-on with no snapshot, trim-on with `calls == 0`, trim-on with `reduction == 0`, empty build identity, missing price, any variable other than `trim-on` or `trim-off`. Accepted: trim-off with no snapshot or the all-zero snapshot the command writes; it scores reduction 0. A present trim-off snapshot with any nonzero counter is `MalformedTrial`, because trim ran or the record was altered.

A trim-on snapshot whose `sent_bytes` exceeds `raw_bytes`, or whose recorded `reduction` is not the value computed from those two fields, is `MalformedTrial`. Token addition or the price multiplication that does not fit in a `u64` is the same error. A consistent zero on trim-on stays `TrimOnZeroReduction`.

Cents are integer: `(input_tokens + output_tokens) * cents_per_mtok / 1000000`.

## What this command does not do

It does not start Harbor, pick a model id, or choose a dollar cap. `eval/run.sh` is the dataset pin (`terminal-bench/terminal-bench-2-1`) and is not a `zig build test` step. Image platforms live in `eval/image-platforms.json`. While that file says `blocked` and `chosen_triple` is null, no pilot starts. Matched two-arm campaigns and their reports are `eval/campaign.py` ([campaign spec](campaign.md)).
