# Work ledger — harness benchmark

Updated 2026-09-30. Phases 1–8 are done. Phase 8 below is the current live record: one approved task with `glm-5.3-flash`. Phases 9–12 are not started and need their own approvals. No dollar cap was named.

The historical offline binary used in phases 1–7 is git `a2a9bf03fe8b808c2a6dfd9a059e3f358346f7c7`, target `aarch64-macos.26.7...26.7-none`, optimize `Debug`, adapter `0.1.0`. That binary was built from a dirty tree, so the stamped sha is the parent commit and does not contain this work. A later build stamps `unknown` when `git status --porcelain` is non-empty, and the task command refuses `unknown`.

## Where the decisions live

| Record | What it locks |
| --- | --- |
| `docs/adr/001-bench-allowlist.md` | Task runs allow bash, read_file, and write_file inside the workspace. Mission policy is unchanged. |
| `docs/adr/002-cache-tokens-off-trace.md` | Cache counts are fields of `trial.json` only. The `events.jsonl` usage line stays `input_tokens` and `output_tokens`. |
| `docs/adr/003-trim-on-zero-is-scorer-error.md` | A trim-on arm with a missing snapshot, zero calls, or zero reduction fails the scorer. A reduction that does not match raw and sent is malformed. Trim-off zero is the control. |
| `docs/adr/004-per-phase-spend.md` | Phases 8, 9, and 10 each need their own approval. This record does not pick a dollar amount. |

Operator contract: `docs/specs/task.md` and the "Headless task (offline)" section of `README.md`. `docs/PROTOCOL.md` and `build.zig.zon` were not edited.

## Phase 1 — Trial contract

Done. `src/worker/trial.zig` writes and parses a trial in a fixed key order. The four build-identity fields are required. An empty one is `MissingBuildIdentity`. Cache counts are omitted when the provider sent none.

Evidence: `zig build test` (870 tests, leak-checked, offline).

## Phase 2 — Instruments

Done. `source_lines_read` counts a successful `read_file` only. Bash and grep add nothing. The task path copies cache counts off the provider payload before the turn driver writes the usage line.

Evidence: the same suite, plus the two offline runs below. Each trial has `source_lines_read` 3 after a 500-line bash and one three-line read. Each `events.jsonl` has four usage lines and the word `cache` does not appear.

## Phase 3 — Headless task command

Done. `zygos task run --offline` boots the turn loop, starts `TrimWorker` with the mission limits (65536 bytes, 400 lines, head 120, tail 80), and installs the bench allowlist. Exit 0 means the process finished and wrote a trial. A denied tool is still exit 0. Exit 2 is a refusal, including a run without `--offline`.

Named tests cover an unknown tool, a workspace path escape, a missing policy worker, a routed tool that is not on the allowlist, and bash/read/write inside the workspace. The offline fixture runs `seq 1 500`, which is over the line cap.

Evidence, same binary, two workspaces:

```bash
zig-out/bin/zygos task run --offline --workspace <dir> --out trial.json --events events.jsonl
```

Both exited 0. The two trial files are byte-identical. Trim snapshot: calls 3, raw 1920 bytes, sent 767 bytes, reduction 60. Tokens: input 25, output 6, cache read 5, cache creation 3.

## Phase 4 — Linux binary

Done as a recorded stop, not as a container run. `file zig-out/bin/zygos` is `Mach-O 64-bit executable arm64`. `eval/image-platforms.json` has `chosen_triple` null, so no Linux triple was selected. `docker info` failed: the daemon socket `unix:///Users/msaglietto/.docker/run/docker.sock` is not there (client 29.8.1, exit 1). `harbor` is not on `PATH`. No container was started and no Harbor hello-world was run.

## Phase 5 — Harbor adapter

Done for the dry run. `eval/run.sh` prints the task command and adapter `0.1.0`. `eval/harbor/zygos_agent.py` is the same command as a Python class and does not import Harbor. A live Harbor run is refused. Hello-world waits on phase 4's daemon and on Harbor being installed.

Evidence: `./eval/run.sh --dry-run` twice, both exit 0, both print `dataset: terminal-bench/terminal-bench-2-1` and `command: zygos task run --offline --workspace <workspace> --out trial.json --events events.jsonl`.

## Phase 6 — Price and report

Done. `zygos task score --trial T --prices P` drives `trial.score`. Cents are `(input + output) * cents_per_mtok / 1000000`. A price of zero is a free model.

Evidence from the built binary:

| Fixture | Result |
| --- | --- |
| trim-on, reduction 0, calls 2 | exit 2, `TrimOnZeroReduction` |
| trim-on, snapshot omitted | exit 2, `TrimEvidenceMissing` |
| empty `git_sha` | exit 2, `MissingBuildIdentity` |
| model with no price row | exit 2, `MissingPrice` |
| trim-off, reduction 0 | exit 0, `cents=0 source_lines_read=0 reduction=0` |

## Phase 7 — Dataset pin and image platforms

Done. The only accepted pin is `terminal-bench/terminal-bench-2-1`. `./eval/run.sh --dataset latest` exits 2. `./eval/run.sh --dataset terminal-bench/terminal-bench@4.0.0` exits 2. The runner is not referenced from `build.zig` and is not a `zig build test` step.

`eval/image-platforms.json` records `status: blocked`, `chosen_triple: null`, and an empty image list. Harbor is not installed and the Terminal-Bench 2.1 image set is not on disk, so no platform was invented and no triple was chosen. Phase 8 cannot start on this inventory.

## Phase 8 — Pilot

Inventory, the Linux binary, and one Harbor task are recorded on 2026-09-30. Spend for that single task was approved the same day for catalog model `glm-5.3-flash`. No dollar cap was named. Phases 9–12 stay unstarted.

`eval/image-platforms.json` is `status: ready`. The source is the public task set at `https://github.com/harbor-framework/terminal-bench-2-1` (89 `task.toml` files under `tasks/`, each with `docker_image`). Registry manifests, read on 2026-09-30:

| Manifest | Tasks |
| --- | --- |
| single-arch `linux/amd64` | 85 |
| index `linux/amd64` + `linux/arm64` | 4 (`hf-model-inference`, `mteb-leaderboard`, `mteb-retrieve`, `pytorch-model-recovery`, tag `20260430`) |

No image is arm64-only. The chosen platform is `linux/amd64`. The chosen triple is `x86_64-linux.5.10...6.19-gnu.2.31`, which is what `std.Target.zigTriple` stamps for `-Dtarget=x86_64-linux-gnu`. The glibc floor is 2.31. The Docker daemon on this machine is `linux/arm64` (client and server 29.8.1), so an amd64 container runs under emulation. Harbor 0.23.0 is on `PATH`.

`std.c.arc4random_buf` does not exist on the Linux target in Zig 0.16, and glibc 2.36 is newer than this floor, so channel keys and worker ids take macOS `arc4random_buf` or the Linux `getrandom` syscall. The call signatures are unchanged.

The Linux binary is a ReleaseSafe build (`zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe --prefix zig-out/linux-x86_64`). `zig-out/` is gitignored. A dirty tree stamps git sha `unknown`, and `zygos task` refuses to write a trial for that sha. The binary that ran the pilot was rebuilt from a clean tree at `f3a3bdca454d5d77bcd26487955e2ecc80f38585` (`f3a3bdc`). This note does not rebuild it.

One Harbor task ran. Command: `./eval/run.sh --task modernize-scientific-stack --model glm-5.3-flash --task-dir /tmp/terminal-bench-2-1/tasks/modernize-scientific-stack`. n=1, step cap 24, trim on, no Hub upload. Harbor 0.23.0 wrote `/tmp/zygos-phase8/2026-09-30__03-54-51`. Trial name `modernize-scientific-stack__sq67hcP`. Harbor finished with exit 0, 0 exceptions, and reward 0.0. Wall time was 1m 22s. Any other live model, including `glm-5.3`, is still refused with exit 2.

`agent/trial.json` records `model_id` `glm-5.3-flash`, dataset `terminal-bench/terminal-bench-2-1`, variable `trim-on`, `step_cap` 24, that git sha, triple `x86_64-linux.5.10...6.19-gnu.2.31`, optimize `ReleaseSafe`, and adapter `0.1.0`. Totals are `input_tokens` 1927 and `output_tokens` 1221. `cache_read_tokens` is absent. The binary Harbor uploaded matches `zig-out/linux-x86_64/bin/zygos` (sha256 `d550f399333fdaecdc24722001e6d7b458b16c3a4420f8285408e9705c18c674`). The verifier installed an `x86_64` uv and amd64 Debian packages, so the task container was `linux/amd64`. Harbor skipped its image OS check because `docker inspect` returned 1. The ELF binary executed and wrote the trial.

`agent/events.jsonl` has four provider steps. Steps 1–3 dispatched two tool calls each (`bash`, then `read_file`, then `write_file`). Every recorded input is `{}` and every result is `handler_failed`. Step 4 stopped on `max_tokens` with `output_tokens` 1024, the request default when the catalog row sets no `max_tokens`. The trim snapshot is `calls` 0 and `reduction` 0. `zygos task score` against that trial, with a price row present, exits 2 and prints `TrimEvidenceMissing`. ADR 003 treats that as a failed score. The scorer's one `cents_per_mtok` figure is a separate check from the dollar total below.

The published GLM-5.3-Flash rates (https://docs.z.ai/guides/overview/pricing, 2026-09-18) are $0.15 input, $0.03 cached input, and $0.50 output per 1M tokens. The trial has no cache field, so the cached rate is unused. 1927 × $0.15/M + 1221 × $0.50/M = $0.00089955.

The verifier reward is 0 because `/app/analyze_climate_modern.py` was not created and neither `/app/requirements.txt` nor `/app/pyproject.toml` was created.

Phases 9–12 are not started.

## Offline tool-input repair — 2026-09-30

No Harbor task ran during this repair and no provider spend occurred. This is an offline prerequisite for phase 9, not another phase-8 pilot.

`src/worker/anthropic.zig` discarded `content_block_start.input`. With a populated start object and no later input deltas, `src/net/anthropic.zig` rendered `{}`, and the real tool handlers returned `handler_failed`. A synthetic SSE regression in `src/net/anthropic.zig` reproduced that path through the shipped decoder, assembler, renderer, task turn loop, bench policy, and bash/read/write handlers. Its first `zig build test` was red at the assertion rejecting `handler_failed` (876/877 passed).

The assembler now owns a copy of a populated start object. The first non-empty `input_json_delta` replaces that object; subsequent fragments concatenate. An empty fragment preserves the start input, and the ordinary `{}` placeholder still takes its arguments from deltas. A second red test caught invalid concatenation of a start object and a streamed object (877/878 passed) before replacement was implemented.

Green evidence: `zig build test --summary all` 878/878 passed, leak-checked and offline; `zig fmt --check src/` clean. The SSE-to-task regression runs `seq 1 500`, reads three fixture lines, writes `non-empty start input\n` to `note.txt`, and observes one successful reply per tool, three trim calls, and positive reduction. The assembler regression preserves two distinct tool ids. Existing partial-JSON and duplicate-key tests stay green. The bench allowlist, mission policy, and trim/scorer rules are unchanged; `eval/image-platforms.json` remains exactly `status: ready`.

The phase-8 raw stream was not saved, and its trace has no tool ids. The tests prove the argument-loss mechanism for the synthetic stream shape and that the harness does not double a single block. They cannot establish the pilot's exact stream shape or whether its paired calls were duplicates. No deduplication by tool name was introduced.

The Linux binary for phases 9 and 10 must be built once from the clean committed fix, with target `x86_64-linux.5.10...6.19-gnu.2.31`, optimize `ReleaseSafe`, and adapter `0.1.0`. A later ledger-only commit does not rebuild that artifact. Phase 9 remains unapproved and unstarted.

## Phase 9 — Freeze the canary

Not started. Task ids will be frozen from actual task runs, with `modernize-scientific-stack` as one member. The shape, if approved separately, is 3 runs of 8–12 tasks (24–36 task-runs). At least one task must produce filterable output or the phase 6 guard fails a wired trim-on arm. No completed canary ids were invented here.

## Phase 10 — First ablation

Not started. Trim on versus trim off, same sha, triple, optimize level, adapter version, model, dataset, and step cap. The shape is another 48–72 task-runs and needs its own approval. No campaign cap was set before phase 8, so an earlier yes would not cover this.

## Phase 11 — Milestone job

Not started. Full 89, then SWE-bench Lite after its slug is confirmed. Manual. Not a PR gate.

## Phase 12 — Mission bench

Not started. One brief, kill and resume once. That number stays on the mission FSM, separate from `zygos task`. RADAR, BrowseComp-Plus, and Y5 stay behind their own gates. No new Z-12 number was assigned. Code Z-12 remains the stream-idle watchdog.

## Checks run on 2026-09-28

```bash
zig build test          # 870/870 passed
zig fmt --check src/    # clean
git diff -- build.zig.zon docs/PROTOCOL.md   # empty
```

`zig build test` does not invoke `eval/run.sh` and does not touch the network, the provider catalog, or the vault.
