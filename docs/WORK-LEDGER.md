# Work ledger — harness benchmark, phases that spend nothing

Recorded 2026-09-28. This is the human follow-up for the revised Harbor / Terminal-Bench plan. Phases 1–7 are done. Phases 8–12 are not started. No dated model id was named, and no dollar cap was chosen, so nothing here spends.

The offline binary that produced the trial below is git `a2a9bf03fe8b808c2a6dfd9a059e3f358346f7c7`, target `aarch64-macos.26.7...26.7-none`, optimize `Debug`, adapter `0.1.0`.

## Where the decisions live

| Record | What it locks |
| --- | --- |
| `docs/adr/001-bench-allowlist.md` | Task runs allow bash, read_file, and write_file inside the workspace. Mission policy is unchanged. |
| `docs/adr/002-cache-tokens-off-trace.md` | Cache counts are fields of `trial.json` only. The `events.jsonl` usage line stays `input_tokens` and `output_tokens`. |
| `docs/adr/003-trim-on-zero-is-scorer-error.md` | A trim-on arm with a missing snapshot, zero calls, or zero reduction fails the scorer. Trim-off zero is the control. |
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

Not started. One short task, n=1, after its own spend approval and a dated catalog model id. The image would have to match a phase 7 triple. There is no triple and no approval.

## Phase 9 — Freeze the canary

Not started. Task ids come from the pilot. The shape, if approved separately, is 3 runs of 8–12 tasks (24–36 task-runs). At least one task must produce filterable output or the phase 6 guard fails a wired trim-on arm. No ids were invented here.

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
