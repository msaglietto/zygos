# Work ledger — harness benchmark

Updated 2026-10-01. Phases 1–8 are done. Phase 9 finished all 24 approved task-run attempts after an explicit operator instruction to continue; canary qualification failed because all scorer checks reject missing trim evidence. Results are `/tmp/zygos-phase9/campaign.json`. Phases 10–12 are not started and need their own approvals. No dollar cap was named.

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

Inventory, the Linux binary, and one Harbor task are recorded on 2026-09-30. Spend for that single task was approved the same day for catalog model `glm-5.3-flash`. No dollar cap was named. At that date, phases 9–12 were unstarted.

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

Phases 9–12 were not started when the pilot was recorded on 2026-09-30.

## Offline tool-input repair — 2026-09-30

No Harbor task ran during this repair and no provider spend occurred. This is an offline prerequisite for phase 9, not another phase-8 pilot.

`src/worker/anthropic.zig` discarded `content_block_start.input`. With a populated start object and no later input deltas, `src/net/anthropic.zig` rendered `{}`, and the real tool handlers returned `handler_failed`. A synthetic SSE regression in `src/net/anthropic.zig` reproduced that path through the shipped decoder, assembler, renderer, task turn loop, bench policy, and bash/read/write handlers. Its first `zig build test` was red at the assertion rejecting `handler_failed` (876/877 passed).

The assembler now owns a copy of a populated start object. The first non-empty `input_json_delta` replaces that object; subsequent fragments concatenate. An empty fragment preserves the start input, and the ordinary `{}` placeholder still takes its arguments from deltas. A second red test caught invalid concatenation of a start object and a streamed object (877/878 passed) before replacement was implemented.

Green evidence: `zig build test --summary all` 878/878 passed, leak-checked and offline; `zig fmt --check src/` clean. The SSE-to-task regression runs `seq 1 500`, reads three fixture lines, writes `non-empty start input\n` to `note.txt`, and observes one successful reply per tool, three trim calls, and positive reduction. The assembler regression preserves two distinct tool ids. Existing partial-JSON and duplicate-key tests stay green. The bench allowlist, mission policy, and trim/scorer rules are unchanged; `eval/image-platforms.json` remains exactly `status: ready`.

The phase-8 raw stream was not saved, and its trace has no tool ids. The tests prove the argument-loss mechanism for the synthetic stream shape and that the harness does not double a single block. They cannot establish the pilot's exact stream shape or whether its paired calls were duplicates. No deduplication by tool name was introduced.

The fix is commit `324c45cb6a8a60b07f04d5c069e7522c3ad54d33` (`324c45c`). From that clean tree, the Linux binary was rebuilt once with `zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe --prefix zig-out/linux-x86_64`. Its sha256 is `78e1a163748eff8b500d11797745b0d7ea67c7a227dfdb10daf0061f601b1795`. Use this artifact and sha for every phase-9 and phase-10 trial. This ledger-only note does not rebuild it. The original pilot binary is preserved at `/tmp/zygos-phase8-binary-f3a3bdc`.

A network-disabled, `--pull=never` container using the already-installed `debian:bullseye-slim` amd64 image checked the Linux CLI with the scripted `--offline` fixture. It wrote `/tmp/zygos-tool-input-linux-check/trial.json` and `events.jsonl`; no Harbor or provider ran. The trial confirms sha `324c45c`, triple `x86_64-linux.5.10...6.19-gnu.2.31`, optimize `ReleaseSafe`, and adapter `0.1.0`. Tokens are synthetic: input 25, output 6, cache read 5, cache creation 3. Provider cost is $0; Harbor reward is not applicable. `zygos task score` with a free fixture price exited 0: `cents=0 source_lines_read=3 reduction=60`. Build identity and digest are saved at `/tmp/zygos-tool-input-build.json`.

A proposed eight-task phase-9 set was saved in `/tmp/zygos-phase9-proposal.md`, drawn from the installed task files. It was unapproved and unstarted on 2026-09-30. The approval and first live trial are recorded below; the proposal is not a frozen canary.

## Phase 9 — Freeze the canary

Approved on 2026-10-01 for three runs of eight tasks (24 task-runs), with the proposal's initial stop condition: inspect each trial and stop on a broken tool path or failed scorer evidence before spending on the next task. The first trial failed and spend stopped. The operator then explicitly instructed continuation of all 23 remaining Phase 9 runs before the model allocation reset. That instruction supersedes the campaign stop condition; tool policy, task budgets, model allowlist, and scorer rejection stay unchanged. The remaining runs finished sequentially with the same pinned binary and settings. Actual task ids, trials, and failed qualification are recorded below.

The first task was `fix-code-vulnerability`, selected from the installed Terminal-Bench 2.1 task files. Its instruction offers `pytest -rA`, which can produce filterable command output. The agent never executed a successful command, so this trial provides no live filter evidence for ADR 003. The verifier's own pytest output is not agent tool output.

Harbor 0.23.0 ran one task, n=1, concurrency 1, max retries 0, model `glm-5.3-flash`, dataset `terminal-bench/terminal-bench-2-1`, step cap 24, trim on, and platform `linux/amd64`. `PYTHONPATH` was the repository and `PYTHONDONTWRITEBYTECODE=1` prevented an untracked adapter cache. The existing adapter passed the key only in the task exec environment; its providers.toml was keyless. No Hub upload or public publication occurred. Job: `/tmp/zygos-phase9/phase9-r1-fix-code-vulnerability`. Trial: `fix-code-vulnerability__WxoQzbD`, at `/tmp/zygos-phase9/phase9-r1-fix-code-vulnerability/fix-code-vulnerability__WxoQzbD`. Harbor exited 0 with 0 exceptions, reward 0.0, and wall time about 1m 22s.

`agent/trial.json` records git sha `324c45cb6a8a60b07f04d5c069e7522c3ad54d33`, triple `x86_64-linux.5.10...6.19-gnu.2.31`, optimize `ReleaseSafe`, and adapter `0.1.0`. The uploaded `agent/zygos` matches the pinned Linux binary: sha256 `78e1a163748eff8b500d11797745b0d7ea67c7a227dfdb10daf0061f601b1795`. No rebuild was performed for this trial or this ledger edit.

`agent/events.jsonl` has five provider steps. Step 1 dispatched two bash calls, step 2 one bash call, step 3 one read_file call, and step 4 a bash call and a read_file call. All six inputs are `{}` and all six results are `handler_failed`; there are no successful tool results or write_file calls. Step 5 stopped on `max_tokens` at output_tokens 1024, the request default because the catalog row sets no max_tokens. The trace has no tool ids and the raw provider stream was not saved. The offline regressions establish the repaired synthetic contract, but this live failure leaves the provider stream shape and paired calls unresolved.

The first trial's token totals are input 2288 and output 1141. `cache_read_tokens` is absent. Using the same published 2026-09-18 rates ($0.15 input, $0.03 cached input, $0.50 output per 1M tokens), the cached rate is unused: 2288 × $0.15/M + 1141 × $0.50/M = $0.00091370. No dollar cap is assumed.

The trim snapshot has calls 0, filtered 0, raw_bytes 0, sent_bytes 0, and reduction 0; source_lines_read is 0. The pinned Linux scorer ran offline in a network-disabled container and exited 2 with `TrimEvidenceMissing`. Its price fixture `/tmp/zygos-phase9/prices.txt` contains `glm-5.3-flash 15`; that single cents_per_mtok value is the scorer check, not the three-rate invoice above. Scorer output and exit status are `/tmp/zygos-phase9/phase9-r1-fix-code-vulnerability.score.txt` and `/tmp/zygos-phase9/phase9-r1-fix-code-vulnerability.score-exit.txt`.

The verifier found no `/app/report.jsonl` and the Bottle header validation remained unfixed: its output checks had 4 failures and 2 passes. Harbor reward is 0. Spend initially stopped under the proposal's condition; the operator's subsequent instruction resumed the remaining runs with failures preserved. Phases 10–12 remain not started and separately gated.

Campaign execution finished on 2026-10-01: 24 task-runs, three attempts for each of eight task ids observed in the actual trials. The executed set is `build-cython-ext`, `cobol-modernization`, `filter-js-from-html`, `fix-code-vulnerability`, `fix-git`, `log-summary-date-ranges`, `modernize-scientific-stack`, `regex-log`. `modernize-scientific-stack` is one member. This is an observed task set, not a qualified frozen canary: all 24 trim-on trials fail ADR 003 and no task emitted successful agent command output.

All 24 uploaded binaries and trial identities match the pinned sha, triple, ReleaseSafe build, adapter 0.1.0, model, dataset, step cap 24, and trim-on settings recorded above. No Linux rebuild or Hub upload occurred. Each Harbor invocation remained n=1, concurrency 1, and max retries 0.

Totals: input_tokens 49949, output_tokens 26650. Cache read and cache creation fields are absent in all 24 trials. The published 2026-09-18 rates remain $0.15 input, $0.03 cached input, and $0.50 output per 1M tokens; cached input is unreported and that rate is unused. The recorded-usage cost is 49949 × $0.15/M + 26650 × $0.50/M = $0.02081735. No dollar cap was invented.

There were 162 tool dispatches, all with input `{}`, and 162 `handler_failed` results; successful tools and source_lines_read are zero throughout. Every trim snapshot has zero calls and zero reduction. Turn stops: 18 max_tokens, 3 failed, 2 end_turn, and 1 max_steps. All 24 final scorer checks exited 2 with `TrimEvidenceMissing`; the single `glm-5.3-flash 15` cents_per_mtok fixture remains a trim check, not this three-rate cost calculation. The provider raw streams were not saved, so the live argument-loss cause and paired calls are unresolved.

Harbor reward is 0.0 in 23 trials. The first `regex-log` attempt has no reward and one `RewardFileNotFoundError`: Docker stopped during the run and verification produced no reward file. Docker Desktop was restarted. The next Harbor invocation was refused before a trial launched; its log is `/tmp/zygos-phase9/phase9-r2-modernize-scientific-stack.daemon-down.harbor.log`. The 16 unstarted task-runs then resumed, and existing trials were not repeated. The interrupted regex trial reports no token usage; its initial scorer invocation failed with Docker unavailable (exit 1), preserved in `/tmp/zygos-phase9/phase9-r1-regex-log.docker-unavailable.score.txt`. Its final offline scorer after recovery exited 2 with `TrimEvidenceMissing`. The other two regex turns also failed before reporting usage, without a Harbor exception.

Trial directories below are absolute. Scorer output for each row is `/tmp/zygos-phase9/<job-name>.score.txt`; each final scorer result is exit 2, `TrimEvidenceMissing`. Harbor exit is 0 for every actual trial. The table preserves the missing reward rather than treating it as zero.

| Repeat | Trial directory | Input | Output | USD | Harbor reward | Exceptions |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 1 | `/tmp/zygos-phase9/phase9-r1-build-cython-ext/build-cython-ext__rHAxgqh` | 1960 | 1369 | 0.00097850 | 0.0 | 0 |
| 1 | `/tmp/zygos-phase9/phase9-r1-cobol-modernization/cobol-modernization__Poh4LoZ` | 4833 | 2108 | 0.00177895 | 0.0 | 0 |
| 1 | `/tmp/zygos-phase9/phase9-r1-filter-js-from-html/filter-js-from-html__7a8thu5` | 291 | 1024 | 0.00055565 | 0.0 | 0 |
| 1 | `/tmp/zygos-phase9/phase9-r1-fix-code-vulnerability/fix-code-vulnerability__WxoQzbD` | 2288 | 1141 | 0.00091370 | 0.0 | 0 |
| 1 | `/tmp/zygos-phase9/phase9-r1-fix-git/fix-git__sJGjVBN` | 708 | 1199 | 0.00070570 | 0.0 | 0 |
| 1 | `/tmp/zygos-phase9/phase9-r1-log-summary-date-ranges/log-summary-date-ranges__w4g467u` | 2652 | 1133 | 0.00096430 | 0.0 | 0 |
| 1 | `/tmp/zygos-phase9/phase9-r1-modernize-scientific-stack/modernize-scientific-stack__eYHjD8h` | 2438 | 1280 | 0.00100570 | 0.0 | 0 |
| 1 | `/tmp/zygos-phase9/phase9-r1-regex-log/regex-log__FSFyAum` | 0 | 0 | 0.00000000 | missing | 1 (RewardFileNotFoundError) |
| 2 | `/tmp/zygos-phase9/phase9-r2-build-cython-ext/build-cython-ext__RBAxixL` | 3915 | 1321 | 0.00124775 | 0.0 | 0 |
| 2 | `/tmp/zygos-phase9/phase9-r2-cobol-modernization/cobol-modernization__J76iuUw` | 6865 | 1575 | 0.00181725 | 0.0 | 0 |
| 2 | `/tmp/zygos-phase9/phase9-r2-filter-js-from-html/filter-js-from-html__MQr9FwH` | 291 | 1024 | 0.00055565 | 0.0 | 0 |
| 2 | `/tmp/zygos-phase9/phase9-r2-fix-code-vulnerability/fix-code-vulnerability__UQLwRTV` | 4514 | 492 | 0.00092310 | 0.0 | 0 |
| 2 | `/tmp/zygos-phase9/phase9-r2-fix-git/fix-git__EvTJNv3` | 983 | 1384 | 0.00083945 | 0.0 | 0 |
| 2 | `/tmp/zygos-phase9/phase9-r2-log-summary-date-ranges/log-summary-date-ranges__2BH4zN9` | 5098 | 1651 | 0.00159020 | 0.0 | 0 |
| 2 | `/tmp/zygos-phase9/phase9-r2-modernize-scientific-stack/modernize-scientific-stack__gC3DFQa` | 1478 | 1152 | 0.00079770 | 0.0 | 0 |
| 2 | `/tmp/zygos-phase9/phase9-r2-regex-log/regex-log__cY79UtB` | 0 | 0 | 0.00000000 | 0.0 | 0 |
| 3 | `/tmp/zygos-phase9/phase9-r3-build-cython-ext/build-cython-ext__VcXhBsp` | 1801 | 1224 | 0.00088215 | 0.0 | 0 |
| 3 | `/tmp/zygos-phase9/phase9-r3-cobol-modernization/cobol-modernization__wrozoN8` | 2110 | 1188 | 0.00091050 | 0.0 | 0 |
| 3 | `/tmp/zygos-phase9/phase9-r3-filter-js-from-html/filter-js-from-html__kA38REx` | 291 | 1024 | 0.00055565 | 0.0 | 0 |
| 3 | `/tmp/zygos-phase9/phase9-r3-fix-code-vulnerability/fix-code-vulnerability__j4J7Top` | 2897 | 1285 | 0.00107705 | 0.0 | 0 |
| 3 | `/tmp/zygos-phase9/phase9-r3-fix-git/fix-git__J4qH8BC` | 1013 | 1488 | 0.00089595 | 0.0 | 0 |
| 3 | `/tmp/zygos-phase9/phase9-r3-log-summary-date-ranges/log-summary-date-ranges__ZJHi5nH` | 1587 | 1188 | 0.00083205 | 0.0 | 0 |
| 3 | `/tmp/zygos-phase9/phase9-r3-modernize-scientific-stack/modernize-scientific-stack__PGpGFwF` | 1936 | 1400 | 0.00099040 | 0.0 | 0 |
| 3 | `/tmp/zygos-phase9/phase9-r3-regex-log/regex-log__YvLwCqD` | 0 | 0 | 0.00000000 | 0.0 | 0 |

Full results are saved at `/tmp/zygos-phase9/campaign.json`. Phase 9 execution is finished, but canary qualification failed. Phases 10–12 remain not started and require their own approvals; the Phase 9 continuation did not authorize them.

Offline checks on 2026-10-01: `zig build test --summary all` passed 878/878 tests and `zig fmt --check src/` was clean. Only this ledger changed. The Linux binary digest is unchanged, `eval/image-platforms.json` remains `status: ready`, and no `eval/harbor/**__pycache__` was created. The initial trial summary is `/tmp/zygos-phase9/report.json`; the full 24-trial report is `/tmp/zygos-phase9/campaign.json`.

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
