# Spec: `zygos task` — headless trial

The Harbor-facing entry. One instruction, the existing turn loop, a step cap, and a `trial.json`. This is not a mission: there is no product-owner and no completion gate. Exit 0 means the process finished and wrote a trial, including when a tool was denied. Exit 2 is a refusal (bad args, missing `--offline`, unknown git sha, workspace missing). Exit 1 is out of memory.

The mission FSM is a different number and is not what this command measures.

## Commands

```bash
zygos task run --offline --workspace DIR --out trial.json [--events events.jsonl] [--trim on|off]
zygos task score --trial trial.json --prices prices.txt
```

`--offline` is required. Without it the process prints a refusal and exits 2. The offline path uses the scripted provider. It does not read the provider catalog, the vault, or the network. The script is bash `seq 1 500` (over the trim line cap), a read of `fixture.txt` (three lines, the only `source_lines_read`), a write of `note.txt`, then end of turn.

`--trim off` does not register `TrimWorker`. The trial still carries a zero snapshot. `--trim on` (the default) starts the worker with the mission CLI limits: 65536 bytes, 400 lines, head 120, tail 80.

`prices.txt` is one `<model_id> <cents_per_mtok>` row per line. `#` comments are ignored. A zero price is a free model. A missing row for the trial's model is `MissingPrice`.

## Trial fields

Fixed key order so two offline runs match byte for byte. Cache keys are omitted when the provider sent none.

- `task_id`, `dataset`, `model_id`, `variable` (`trim-on` or `trim-off`), `step_cap`
- `git_sha`, `target_triple`, `optimize`, `adapter_version` (currently `0.1.0`)
- `source_lines_read` from successful `read_file` only
- `input_tokens`, `output_tokens`
- `cache_read_tokens`, `cache_creation_tokens` when present
- `trim`: `calls`, `filtered`, `deduped`, `raw_bytes`, `sent_bytes`, `reduction`

`reduction` is `(raw - sent) * 100 / raw` when `raw > 0` and `sent < raw`, else 0. The git sha is the Zygos build, not the task workspace. A dirty worktree, a missing git checkout, or a hash that is not 40 or 64 hex characters embeds `unknown`, and the task command then refuses to write a trial. `optimize` is the build mode name (`Debug`, `ReleaseSafe`, `ReleaseFast`, `ReleaseSmall`).

The trace file given to `--events` stays the usage line from `trace_event.zig`: `input_tokens` and `output_tokens`. Cache counts are not added there.

## Bench policy

Deny by default. Allowed tool names: `bash`, `read_file`, `write_file`, inside the workspace. An unknown tool name, a path that escapes the workspace, and a policy worker that is missing or returns a failure all deny. The turn result carries `unknown tool`, `PathEscapesWorkspace`, or `policy_denied`. The process still exits 0. Mission policy is unchanged. See `docs/adr/001-bench-allowlist.md`.

## Scorer

`zygos task score` exits 0 and prints `cents`, `source_lines_read`, and `reduction`, or exits 2 and prints the error name.

Refused: trim-on with no snapshot, trim-on with `calls == 0`, trim-on with `reduction == 0`, empty build identity, missing price, any variable other than `trim-on` or `trim-off`. Accepted: trim-off with reduction 0.

A trim-on snapshot whose `sent_bytes` exceeds `raw_bytes`, or whose recorded `reduction` is not the value computed from those two fields, is `MalformedTrial`. Token addition or the price multiplication that does not fit in a `u64` is the same error. A consistent zero on trim-on stays `TrimOnZeroReduction`.

Cents are integer: `(input_tokens + output_tokens) * cents_per_mtok / 1000000`.

## What this command does not do

It does not start Harbor, pick a model id, or choose a dollar cap. `eval/run.sh` is the dataset pin (`terminal-bench/terminal-bench-2-1`) and is not a `zig build test` step. Image platforms live in `eval/image-platforms.json`. While that file says `blocked` and `chosen_triple` is null, no pilot starts.
