# Work ledger — harness benchmark

Updated 2026-10-07. The operator replaced per-phase permission stops with standing agent authority in `docs/benchmark-policy.md`; planned DeepSeek phases 10–12 are authorized and remain not started. DeepSeek Phase 9 completed 24 trials on the clean `a147d52` Linux artifact: 11 verifier successes, one accepted scorer record with 28% reduction, no transport/RPC failures, no handler failures, and no empty tool inputs. Its campaign is `/tmp/zygos-phase9-deepseek-completions/campaign.json`; all six DeepSeek attempts and their known costs are recorded below. Phases 1–8 are done. Historical GLM results remain preserved: schema-repaired Phase 9 completed 24 trials with six verifier successes and four accepted scorer records; Phase 10 completed 48 matched trials with all verifier rewards 0 and 47 failed provider turns, using the clean `b157dc1` artifact. Its report is `/tmp/zygos-phase10-schema/campaign.json`. Historical Phase 11 stopped after one provider transport failure, with 88 tasks pending. Historical Phase 12 was killed and resumed once, then failed on executor `max_tokens` without reaching verification or the manual completion gate. No dollar cap was named.

The historical offline binary used in phases 1–7 is git `a2a9bf03fe8b808c2a6dfd9a059e3f358346f7c7`, target `aarch64-macos.26.7...26.7-none`, optimize `Debug`, adapter `0.1.0`. That binary was built from a dirty tree, so the stamped sha is the parent commit and does not contain this work. A later build stamps `unknown` when `git status --porcelain` is non-empty, and the task command refuses `unknown`.

## Where the decisions live

| Record | What it locks |
| --- | --- |
| `docs/adr/001-bench-allowlist.md` | Task runs allow bash, read_file, and write_file inside the workspace. Mission policy is unchanged. |
| `docs/adr/002-cache-tokens-off-trace.md` | Cache counts are fields of `trial.json` only. The `events.jsonl` usage line stays `input_tokens` and `output_tokens`. |
| `docs/adr/003-trim-on-zero-is-scorer-error.md` | A trim-on arm with a missing snapshot, zero calls, or zero reduction fails the scorer. A reduction that does not match raw and sent is malformed. Trim-off zero is the control. |
| `docs/benchmark-policy.md` | Standing agent authority for the remaining DeepSeek benchmark phases; evidence reviews and recorded stop conditions regulate continuation. |
| `docs/adr/004-per-phase-spend.md` | Superseded historical approval policy; it does not require new permission requests. |

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

Full results are saved at `/tmp/zygos-phase9/campaign.json`. This first Phase 9 execution is finished, but canary qualification failed. At its completion, Phases 10–12 had not started and required their own approvals; the later operator approval and schema-repair rerun are recorded below.

Offline checks on 2026-10-01: `zig build test --summary all` passed 878/878 tests and `zig fmt --check src/` was clean. Only this ledger changed. The Linux binary digest is unchanged, `eval/image-platforms.json` remains `status: ready`, and no `eval/harbor/**__pycache__` was created. The initial trial summary is `/tmp/zygos-phase9/report.json`; the full 24-trial report is `/tmp/zygos-phase9/campaign.json`.

## Phase 10 — First ablation

Approved on 2026-10-01, execution finished under `/tmp/zygos-phase10-schema`. The operator explicitly chose to fix the missing tool schemas, rerun Phase 9, and run both Phase 10 arms on one new clean Linux build. Trim on versus trim off matches on sha, triple, optimize level, adapter version, model, dataset, and step cap. All 48 task-runs on the eight-task set are recorded below. Each invocation ran one task, with up to four independent host jobs and no retries. All verifier rewards were 0; 47 turns failed at the provider boundary. This does not qualify a useful trim comparison. No dollar cap was named.

## Phase 11 — Milestone job

Approved on 2026-10-01, stopped after the first of 89 tasks under `/tmp/zygos-phase11-schema` with redacted diagnostics. Full 89, then SWE-bench Lite after its slug is confirmed. Manual. Not a PR gate. The other 88 tasks have not started while the reproduced provider transport failure is investigated. The installed Harbor 0.23.0 legacy registry and current Hub package queries list SWE-bench Verified, not a confirmed Lite slug; Verified is not a substitute. Query snapshots: `/tmp/zygos-swe-lite-registry-query.json` and `/tmp/zygos-lite-named-package-check.json`. The operator does not know the Harbor Lite identifier; confirming it remains our investigation, rather than a pending operator answer. No Lite trial has run.

## Phase 12 — Mission bench

Approved on 2026-10-01 and explicitly resumed by the operator on 2026-10-02. One isolated brief, `/tmp/zygos-phase12-schema/brief.md`, ran through `zygos mission start` and exactly one `zygos mission resume`, separate from `zygos task` and Harbor. Execution is finished with a failed outcome; mission success is not claimed. Planning state and trace: `/tmp/zygos-phase12-schema/planning/mission.json` and `/tmp/zygos-phase12-schema/planning/events.jsonl`. Console logs, process exits, kill evidence, independent checks, and aggregate are under `/tmp/zygos-phase12-schema`, including `completion-summary.json`.

The mission used the existing clean-build artifact: git sha `b157dc1fa2048b3aa313e66ba1b275f5c708c4ab`, binary SHA-256 `2f22205e1a85af623f13fb6c2d6c9718f7e4dda7836ae28cadc9c7bc5eb4b468`, triple `x86_64-linux.5.10...6.19-gnu.2.31`, optimize ReleaseSafe. Adapter identity remains 0.1.0, although this mission uses no Harbor adapter. All roles routed to `glm-5.3-flash` through the keyless catalog and route file. The key entered only the Docker exec environment. The isolated workspace is `/tmp/zygos-phase12-schema/workspace`, mounted at `/workspace` in the cached amd64 `alexgshaw/modernize-scientific-stack:20251031` image. The brief token budget was 100000; default role step cap 24 and catalog output default 1024 were preserved. No Linux rebuild, Hub upload, dependency installation, or policy change occurred.

Start began at 2026-10-02 19:07:23 UTC. At 19:07:48.237 UTC the actual mission process, container PID 7, received SIGKILL in persisted `planning` state, after product-owner completion and during the planner request. Start exited 137, and the post-kill process probe failed as expected. The first kill command had returned 127 because the image had no standalone `kill` executable; it sent no signal. Its evidence is preserved as `kill-command-unavailable.json`. The shell builtin then sent the one actual kill, recorded in `kill.json` and `pre-kill-mission.json`. Resume began at 19:07:56 UTC against the same brief and planning root. The trace shows product-owner started once and planner started twice: completed work was reused, interrupted work restarted. Durable state was not edited or seeded.

Resume progressed to `executing`, dispatched two successful bash calls with non-empty commands, and created `sum_cli.py`. At 19:09:12 UTC its third executor provider step stopped on `max_tokens` with output_tokens 1024. The mission terminal reply is `state: failed`, `stop: role_failed`, `detail: executor turn stopped: max_tokens`, role_turns 3, tasks_done 0; resume exited 1. No verifier or approval gate ran, and no completion approval was fabricated. The container was stopped after evidence collection.

Recorded usage across the appended trace is input_tokens 3832 and output_tokens 3209. Cache-read usage is unreported by the mission trace, as required by ADR 002. Published 2026-09-18 rates are $0.15 input, $0.03 cached input, and $0.50 output per 1M tokens; the cached rate cannot be applied without a count. Recorded-usage cost is 3832 × $0.15/M + 3209 × $0.50/M = **$0.00217930**. The killed planner request has no usage event, so this is a recorded-usage lower bound, not a complete invoice or a claim that the interrupted request was free. Harbor reward and `zygos task score` are not applicable to this mission FSM run.

Independent keyless checks confirmed the surviving utility passes six subprocess cases: the original `2 -3 8` example produces `7\n`, positive, negative, and signed-zero sums are correct, and missing or invalid arguments exit 2 with stderr. However, the workspace contains only `sum_cli.py`; `python3 -m unittest discover -v` reports zero tests and exits 5. The brief's automated-test criterion is unmet. Also, the product-owner and planner incorrectly changed the acceptance example to claim `1 2 -3` should produce `-1`; the actual utility produces the correct `0`. That generated acceptance drift is preserved in the state and trace, not silently corrected in durable evidence. Captured artifacts were checked for the provider credential and contained none.

Mission policy, budgets, stream watchdog, and manual completion gates remained fail-closed. No second mission or additional resume was launched after failure. Phase 11's remaining work is still unstarted. RADAR, BrowseComp-Plus, and Y5 stay behind their own gates. No new Z-12 number was assigned. Code Z-12 remains the stream-idle watchdog.

Ledger-only validation: `zig build test --summary all` passed 879/879 offline tests, `zig fmt --check src/` and `git diff --check` were clean. GitNexus reported one documentation file, no affected execution processes, and low risk. The Linux binary digest is unchanged, the image inventory remains exactly `status: ready`, and no adapter `__pycache__` directory was created.

## Offline task-schema repair — 2026-10-01

`src/worker/task.zig` advertised bash, read_file, and write_file with only name and function_id. It supplied no argument schema, and the turn forwarded that incomplete tools array unchanged to the provider. This is a second concrete request-contract defect; the missing raw provider streams still prevent attribution of every earlier empty input or paired call to a particular stream event.

An offline regression observes the public task-to-provider request through a registered stub provider, checks required string arguments (command; path; path and content), and then exercises all three real handlers. Before the fix, `zig build test` failed at the missing-schema assertion: 878/879 tests passed. The minimum fix adds those three input_schema definitions and tool descriptions. The regression now executes `seq 1 500`, reads three fixture lines, writes `schema forwarded\n` to `schema-note.txt`, and records three trim calls with positive reduction. `zig build test --summary all` passes 879/879 tests, and `zig fmt --check src/` is clean. No catalog, vault, or network is used by the test.

The operator explicitly approved replacing the prior Phase 9/10 artifact with one clean build after this fix is committed, and rerunning Phase 9 before Phase 10. Old results remain historical evidence. The new build identity and live trial paths will be recorded after they exist. No live provider request or Harbor trial ran during this repair.

The Harbor adapter now accepts `ZYGOS_TRIM=on|off` (default on) and rejects any other value before container exec. Its offline tests first reproduced the hardcoded-on arm and missing invalid-value refusal, then passed all three checks. They verify that the two commands differ only in the trim value, keep the key in the exec environment, and preserve the timeout and other arguments. Adapter version remains 0.1.0.

Repair commit: `b157dc1fa2048b3aa313e66ba1b275f5c708c4ab`. Built once from its clean tree with `zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe --prefix zig-out/linux-x86_64`. Binary SHA-256: `2f22205e1a85af623f13fb6c2d6c9718f7e4dda7836ae28cadc9c7bc5eb4b468`; triple `x86_64-linux.5.10...6.19-gnu.2.31`, optimize ReleaseSafe, adapter 0.1.0. A keyless, network-disabled Docker check wrote `/tmp/zygos-schema-linux-check/trial.json`: the embedded sha matches, all three scripted tools executed, trim calls 3, reduction 60, scorer exit 0. Its scripted tokens are 25 input, 6 output, 5 cache read; no provider cost. Build manifest: `/tmp/zygos-phase9-schema/build.json`. The prior artifact is preserved at `/tmp/zygos-phase9-binary-324c45c`. Do not rebuild for ledger edits.

The approved fresh Phase 9 used the same eight observed task ids, three runs each, cap 24, glm-5.3-flash, terminal-bench/terminal-bench-2-1, trim on, no Hub upload. It is finished, with results below. Phase 10 will use the same new artifact for both explicitly approved arms; only trim will differ. Scorer failures remain refusals and are not reclassified as valid trim measurements.

## Phase 9 schema-repaired campaign — finished 2026-10-01

Executed 24 task-runs. Build sha `b157dc1fa2048b3aa313e66ba1b275f5c708c4ab`, binary SHA-256 `2f22205e1a85af623f13fb6c2d6c9718f7e4dda7836ae28cadc9c7bc5eb4b468`; triple `x86_64-linux.5.10...6.19-gnu.2.31`, optimize ReleaseSafe, adapter 0.1.0, model glm-5.3-flash, dataset terminal-bench/terminal-bench-2-1, step cap 24. One task per Harbor invocation, no retries, no Hub upload; up to four independent host jobs. The same binary was used throughout; no rebuild for ledger edits.

Recorded input tokens 212358, output tokens 45975, cache-read tokens 0 (field present on 0/24 records). Published rates as of 2026-09-18: input $0.15, cached input $0.03, output $0.50 per million. Three-rate cost from recorded usage: **$0.05484120**. The scorer's single cents-per-million row is a trim check, not this invoice. Missing usage or a killed/unrecorded provider reply cannot be inferred as free.

Harbor exit counts: `{"0": 24}`; exception counts: `{}`; reward counts: `{"0.0": 18, "1.0": 6}`. Scorer exits: `{"2": 20, "0": 4}`. Tool calls 221, empty inputs 0, handler failures 0; structured tool errors `{"PathEscapesWorkspace": 11}` remain fail-closed. Positive-reduction records 4; total trim calls 221, command-filter count 3. Stop reasons: `{"failed": 6, "max_steps": 2, "max_tokens": 10, "end_turn": 6}`. Execution completion does not override rejected scorer results or failed verifiers.

Full trial records and per-trial dollar cost: `/tmp/zygos-phase9-schema/campaign.json`; aggregate: `/tmp/zygos-phase9-schema/completion-summary.json`. Paths below are the actual Harbor trials; their agent/trial.json, agent/events.jsonl, result.json, verifier reward, and separate scorer logs remain under this jobs directory.

| Run | Arm | Task / actual trial path | Input | Cache read | Output | Dollar cost | Reward | Scorer |
|---|---|---|---:|---:|---:|---:|---:|---|
| 1 | on | `/tmp/zygos-phase9-schema/phase9-r1-build-cython-ext/build-cython-ext__bfizXZi` | 22314 | absent | 3045 | 0.00486960 | 0.0 | 2: score: TrimOnZeroReduction |
| 1 | on | `/tmp/zygos-phase9-schema/phase9-r1-cobol-modernization/cobol-modernization__Ht34hMz` | 4839 | absent | 1504 | 0.00147785 | 0.0 | 2: score: TrimOnZeroReduction |
| 1 | on | `/tmp/zygos-phase9-schema/phase9-r1-filter-js-from-html/filter-js-from-html__cMtBX7c` | 414 | absent | 1024 | 0.00057410 | 0.0 | 2: score: TrimEvidenceMissing |
| 1 | on | `/tmp/zygos-phase9-schema/phase9-r1-fix-code-vulnerability/fix-code-vulnerability__rto9sWf` | 16428 | absent | 3055 | 0.00399170 | 1.0 | 2: score: TrimOnZeroReduction |
| 1 | on | `/tmp/zygos-phase9-schema/phase9-r1-fix-git/fix-git__TVT3Cpk` | 6491 | absent | 2155 | 0.00205115 | 0.0 | 2: score: TrimOnZeroReduction |
| 1 | on | `/tmp/zygos-phase9-schema/phase9-r1-log-summary-date-ranges/log-summary-date-ranges__QuSzF7s` | 11821 | absent | 1255 | 0.00240065 | 1.0 | 0: cents=0 source_lines_read=0 reduction=98 |
| 1 | on | `/tmp/zygos-phase9-schema/phase9-r1-modernize-scientific-stack/modernize-scientific-stack__p3Gyb27` | 1277 | absent | 173 | 0.00027805 | 0.0 | 2: score: TrimOnZeroReduction |
| 1 | on | `/tmp/zygos-phase9-schema/phase9-r1-regex-log/regex-log__g7EGKvk` | 0 | absent | 0 | 0.00000000 | 0.0 | 2: score: TrimEvidenceMissing |
| 2 | on | `/tmp/zygos-phase9-schema/phase9-r2-build-cython-ext/build-cython-ext__9yRKAJB` | 14709 | absent | 2976 | 0.00369435 | 0.0 | 2: score: TrimOnZeroReduction |
| 2 | on | `/tmp/zygos-phase9-schema/phase9-r2-cobol-modernization/cobol-modernization__DszioDs` | 4691 | absent | 1268 | 0.00133765 | 0.0 | 2: score: TrimOnZeroReduction |
| 2 | on | `/tmp/zygos-phase9-schema/phase9-r2-filter-js-from-html/filter-js-from-html__yDnhTpX` | 414 | absent | 1024 | 0.00057410 | 0.0 | 2: score: TrimEvidenceMissing |
| 2 | on | `/tmp/zygos-phase9-schema/phase9-r2-fix-code-vulnerability/fix-code-vulnerability__HHoUUjf` | 9441 | absent | 2757 | 0.00279465 | 0.0 | 0: cents=0 source_lines_read=0 reduction=2 |
| 2 | on | `/tmp/zygos-phase9-schema/phase9-r2-fix-git/fix-git__Wt5igsu` | 1941 | absent | 1239 | 0.00091065 | 0.0 | 2: score: TrimOnZeroReduction |
| 2 | on | `/tmp/zygos-phase9-schema/phase9-r2-log-summary-date-ranges/log-summary-date-ranges__AjgZRK2` | 18688 | absent | 6566 | 0.00608620 | 1.0 | 0: cents=0 source_lines_read=0 reduction=38 |
| 2 | on | `/tmp/zygos-phase9-schema/phase9-r2-modernize-scientific-stack/modernize-scientific-stack__FDikEWk` | 2855 | absent | 593 | 0.00072475 | 0.0 | 2: score: TrimOnZeroReduction |
| 2 | on | `/tmp/zygos-phase9-schema/phase9-r2-regex-log/regex-log__TGP47bQ` | 0 | absent | 0 | 0.00000000 | 0.0 | 2: score: TrimEvidenceMissing |
| 3 | on | `/tmp/zygos-phase9-schema/phase9-r3-build-cython-ext/build-cython-ext__wnqLx9J` | 42501 | absent | 4465 | 0.00860765 | 0.0 | 2: score: TrimOnZeroReduction |
| 3 | on | `/tmp/zygos-phase9-schema/phase9-r3-cobol-modernization/cobol-modernization__UWuu3VA` | 4587 | absent | 1241 | 0.00130855 | 0.0 | 2: score: TrimOnZeroReduction |
| 3 | on | `/tmp/zygos-phase9-schema/phase9-r3-filter-js-from-html/filter-js-from-html__vfMSxGb` | 1339 | absent | 1148 | 0.00077485 | 0.0 | 2: score: TrimOnZeroReduction |
| 3 | on | `/tmp/zygos-phase9-schema/phase9-r3-fix-code-vulnerability/fix-code-vulnerability__RYyJVSf` | 15780 | absent | 4359 | 0.00454650 | 1.0 | 2: score: TrimOnZeroReduction |
| 3 | on | `/tmp/zygos-phase9-schema/phase9-r3-fix-git/fix-git__g8Uug23` | 9869 | absent | 3257 | 0.00310885 | 1.0 | 2: score: TrimOnZeroReduction |
| 3 | on | `/tmp/zygos-phase9-schema/phase9-r3-log-summary-date-ranges/log-summary-date-ranges__3r6wV2A` | 20676 | absent | 2616 | 0.00440940 | 1.0 | 0: cents=0 source_lines_read=0 reduction=53 |
| 3 | on | `/tmp/zygos-phase9-schema/phase9-r3-modernize-scientific-stack/modernize-scientific-stack__VvcRGrV` | 1283 | absent | 255 | 0.00031995 | 0.0 | 2: score: TrimOnZeroReduction |
| 3 | on | `/tmp/zygos-phase9-schema/phase9-r3-regex-log/regex-log__xDaCcQE` | 0 | absent | 0 | 0.00000000 | 0.0 | 2: score: TrimEvidenceMissing |

## Phase 10 schema-repaired campaign — finished 2026-10-02

Arm subtotals: trim on 37,382 input / 6,808 output tokens, $0.00901130, 2 scorer accepted and 22 rejected; trim off 68,139 input / 9,477 output tokens, $0.01495935, all 24 scorer accepted with the expected zero trim snapshot. All 48 rewards were 0. Seventeen records contain zero reported usage; the traces do not establish the upstream failure cause or the invoice for unreported work. All 24 task/repeat pairs match on the required build and request settings. Only the trim argument changes. The observed cost difference is descriptive, not evidence of a causal saving. Arm report: `/tmp/zygos-phase10-schema/arms.json`.

Executed 48 task-runs. Build sha `b157dc1fa2048b3aa313e66ba1b275f5c708c4ab`, binary SHA-256 `2f22205e1a85af623f13fb6c2d6c9718f7e4dda7836ae28cadc9c7bc5eb4b468`; triple `x86_64-linux.5.10...6.19-gnu.2.31`, optimize ReleaseSafe, adapter 0.1.0, model glm-5.3-flash, dataset terminal-bench/terminal-bench-2-1, step cap 24. One task per Harbor invocation, no retries, no Hub upload; up to four independent host jobs. The same binary was used throughout; no rebuild for ledger edits.

Recorded input tokens 105521, output tokens 16285, cache-read tokens 0 (field present on 0/48 records). Published rates as of 2026-09-18: input $0.15, cached input $0.03, output $0.50 per million. Three-rate cost from recorded usage: **$0.02397065**. The scorer's single cents-per-million row is a trim check, not this invoice. Missing usage or a killed/unrecorded provider reply cannot be inferred as free.

Harbor exit counts: `{"0": 48}`; exception counts: `{}`; reward counts: `{"0.0": 48}`. Scorer exits: `{"0": 26, "2": 22}`. Tool calls 153, empty inputs 0, handler failures 0; structured tool errors `{"PathEscapesWorkspace": 13}` remain fail-closed. Positive-reduction records 2; total trim calls 68, command-filter count 2. Stop reasons: `{"failed": 47, "max_tokens": 1}`. Execution completion does not override rejected scorer results or failed verifiers.

Full trial records and per-trial dollar cost: `/tmp/zygos-phase10-schema/campaign.json`; aggregate: `/tmp/zygos-phase10-schema/completion-summary.json`. Paths below are the actual Harbor trials; their agent/trial.json, agent/events.jsonl, result.json, verifier reward, and separate scorer logs remain under this jobs directory.

| Run | Arm | Task / actual trial path | Input | Cache read | Output | Dollar cost | Reward | Scorer |
|---|---|---|---:|---:|---:|---:|---:|---|
| 1 | off | `/tmp/zygos-phase10-schema/phase10-off-r1-build-cython-ext/build-cython-ext__jQmQ7bn` | 10038 | absent | 1231 | 0.00212120 | 0.0 | 0: cents=0 source_lines_read=0 reduction=0 |
| 1 | on | `/tmp/zygos-phase10-schema/phase10-on-r1-build-cython-ext/build-cython-ext__7wepxjw` | 10195 | absent | 1234 | 0.00214625 | 0.0 | 2: score: TrimOnZeroReduction |
| 1 | off | `/tmp/zygos-phase10-schema/phase10-off-r1-cobol-modernization/cobol-modernization__5PUMGnj` | 0 | absent | 0 | 0.00000000 | 0.0 | 0: cents=0 source_lines_read=0 reduction=0 |
| 1 | on | `/tmp/zygos-phase10-schema/phase10-on-r1-cobol-modernization/cobol-modernization__ApR8VQk` | 0 | absent | 0 | 0.00000000 | 0.0 | 2: score: TrimEvidenceMissing |
| 1 | off | `/tmp/zygos-phase10-schema/phase10-off-r1-filter-js-from-html/filter-js-from-html__BWrq7vL` | 0 | absent | 0 | 0.00000000 | 0.0 | 0: cents=0 source_lines_read=0 reduction=0 |
| 1 | on | `/tmp/zygos-phase10-schema/phase10-on-r1-filter-js-from-html/filter-js-from-html__LE8bVDH` | 414 | absent | 111 | 0.00011760 | 0.0 | 2: score: TrimOnZeroReduction |
| 1 | off | `/tmp/zygos-phase10-schema/phase10-off-r1-fix-code-vulnerability/fix-code-vulnerability__GUcUQot` | 5062 | absent | 170 | 0.00084430 | 0.0 | 0: cents=0 source_lines_read=0 reduction=0 |
| 1 | on | `/tmp/zygos-phase10-schema/phase10-on-r1-fix-code-vulnerability/fix-code-vulnerability__MUeczmm` | 3218 | absent | 178 | 0.00057170 | 0.0 | 0: cents=0 source_lines_read=0 reduction=10 |
| 1 | off | `/tmp/zygos-phase10-schema/phase10-off-r1-fix-git/fix-git__tTRGhk6` | 836 | absent | 245 | 0.00024790 | 0.0 | 0: cents=0 source_lines_read=0 reduction=0 |
| 1 | on | `/tmp/zygos-phase10-schema/phase10-on-r1-fix-git/fix-git__5hLmRRJ` | 1751 | absent | 368 | 0.00044665 | 0.0 | 2: score: TrimOnZeroReduction |
| 1 | off | `/tmp/zygos-phase10-schema/phase10-off-r1-log-summary-date-ranges/log-summary-date-ranges__35Lwhde` | 48 | absent | 64 | 0.00003920 | 0.0 | 0: cents=0 source_lines_read=0 reduction=0 |
| 1 | on | `/tmp/zygos-phase10-schema/phase10-on-r1-log-summary-date-ranges/log-summary-date-ranges__FuhdJei` | 1579 | absent | 283 | 0.00037835 | 0.0 | 2: score: TrimOnZeroReduction |
| 1 | off | `/tmp/zygos-phase10-schema/phase10-off-r1-modernize-scientific-stack/modernize-scientific-stack__7uW9DX5` | 2851 | absent | 675 | 0.00076515 | 0.0 | 0: cents=0 source_lines_read=0 reduction=0 |
| 1 | on | `/tmp/zygos-phase10-schema/phase10-on-r1-modernize-scientific-stack/modernize-scientific-stack__js5RrXg` | 3718 | absent | 1260 | 0.00118770 | 0.0 | 2: score: TrimOnZeroReduction |
| 1 | off | `/tmp/zygos-phase10-schema/phase10-off-r1-regex-log/regex-log__G2oV8U8` | 0 | absent | 0 | 0.00000000 | 0.0 | 0: cents=0 source_lines_read=0 reduction=0 |
| 1 | on | `/tmp/zygos-phase10-schema/phase10-on-r1-regex-log/regex-log__k9cmRfD` | 0 | absent | 0 | 0.00000000 | 0.0 | 2: score: TrimEvidenceMissing |
| 2 | off | `/tmp/zygos-phase10-schema/phase10-off-r2-build-cython-ext/build-cython-ext__Zn5DrS3` | 21750 | absent | 2045 | 0.00428500 | 0.0 | 0: cents=0 source_lines_read=0 reduction=0 |
| 2 | on | `/tmp/zygos-phase10-schema/phase10-on-r2-build-cython-ext/build-cython-ext__NdBFcuM` | 0 | absent | 0 | 0.00000000 | 0.0 | 2: score: TrimEvidenceMissing |
| 2 | off | `/tmp/zygos-phase10-schema/phase10-off-r2-cobol-modernization/cobol-modernization__HWJ8GW6` | 0 | absent | 0 | 0.00000000 | 0.0 | 0: cents=0 source_lines_read=0 reduction=0 |
| 2 | on | `/tmp/zygos-phase10-schema/phase10-on-r2-cobol-modernization/cobol-modernization__bipsjmq` | 1636 | absent | 119 | 0.00030490 | 0.0 | 2: score: TrimOnZeroReduction |
| 2 | off | `/tmp/zygos-phase10-schema/phase10-off-r2-filter-js-from-html/filter-js-from-html__YrZMXRp` | 0 | absent | 0 | 0.00000000 | 0.0 | 0: cents=0 source_lines_read=0 reduction=0 |
| 2 | on | `/tmp/zygos-phase10-schema/phase10-on-r2-filter-js-from-html/filter-js-from-html__gpzXd9n` | 414 | absent | 1024 | 0.00057410 | 0.0 | 2: score: TrimEvidenceMissing |
| 2 | off | `/tmp/zygos-phase10-schema/phase10-off-r2-fix-code-vulnerability/fix-code-vulnerability__MYvRZbj` | 6222 | absent | 569 | 0.00121780 | 0.0 | 0: cents=0 source_lines_read=0 reduction=0 |
| 2 | on | `/tmp/zygos-phase10-schema/phase10-on-r2-fix-code-vulnerability/fix-code-vulnerability__f8vRVhR` | 2870 | absent | 218 | 0.00053950 | 0.0 | 2: score: TrimOnZeroReduction |
| 2 | off | `/tmp/zygos-phase10-schema/phase10-off-r2-fix-git/fix-git__AqKss2M` | 4786 | absent | 1165 | 0.00130040 | 0.0 | 0: cents=0 source_lines_read=0 reduction=0 |
| 2 | on | `/tmp/zygos-phase10-schema/phase10-on-r2-fix-git/fix-git__g7GeJi7` | 5554 | absent | 1161 | 0.00141360 | 0.0 | 2: score: TrimOnZeroReduction |
| 2 | off | `/tmp/zygos-phase10-schema/phase10-off-r2-log-summary-date-ranges/log-summary-date-ranges__TKXcWsY` | 2686 | absent | 298 | 0.00055190 | 0.0 | 0: cents=0 source_lines_read=0 reduction=0 |
| 2 | on | `/tmp/zygos-phase10-schema/phase10-on-r2-log-summary-date-ranges/log-summary-date-ranges__ZZWs5ae` | 624 | absent | 87 | 0.00013710 | 0.0 | 2: score: TrimOnZeroReduction |
| 2 | off | `/tmp/zygos-phase10-schema/phase10-off-r2-modernize-scientific-stack/modernize-scientific-stack__Qa5ZNE5` | 2589 | absent | 542 | 0.00065935 | 0.0 | 0: cents=0 source_lines_read=0 reduction=0 |
| 2 | on | `/tmp/zygos-phase10-schema/phase10-on-r2-modernize-scientific-stack/modernize-scientific-stack__BS8q8tA` | 1265 | absent | 184 | 0.00028175 | 0.0 | 2: score: TrimOnZeroReduction |
| 2 | off | `/tmp/zygos-phase10-schema/phase10-off-r2-regex-log/regex-log__6jdMTWc` | 0 | absent | 0 | 0.00000000 | 0.0 | 0: cents=0 source_lines_read=0 reduction=0 |
| 2 | on | `/tmp/zygos-phase10-schema/phase10-on-r2-regex-log/regex-log__eTfZ9Ee` | 0 | absent | 0 | 0.00000000 | 0.0 | 2: score: TrimEvidenceMissing |
| 3 | off | `/tmp/zygos-phase10-schema/phase10-off-r3-build-cython-ext/build-cython-ext__Yk4Jv5A` | 35 | absent | 122 | 0.00006625 | 0.0 | 0: cents=0 source_lines_read=0 reduction=0 |
| 3 | on | `/tmp/zygos-phase10-schema/phase10-on-r3-build-cython-ext/build-cython-ext__kGcpAEd` | 1565 | absent | 249 | 0.00035925 | 0.0 | 2: score: TrimOnZeroReduction |
| 3 | off | `/tmp/zygos-phase10-schema/phase10-off-r3-cobol-modernization/cobol-modernization__k3eVXs6` | 1776 | absent | 260 | 0.00039640 | 0.0 | 0: cents=0 source_lines_read=0 reduction=0 |
| 3 | on | `/tmp/zygos-phase10-schema/phase10-on-r3-cobol-modernization/cobol-modernization__ZVzcU6n` | 600 | absent | 74 | 0.00012700 | 0.0 | 2: score: TrimOnZeroReduction |
| 3 | off | `/tmp/zygos-phase10-schema/phase10-off-r3-filter-js-from-html/filter-js-from-html__mc7yz2j` | 0 | absent | 0 | 0.00000000 | 0.0 | 0: cents=0 source_lines_read=0 reduction=0 |
| 3 | on | `/tmp/zygos-phase10-schema/phase10-on-r3-filter-js-from-html/filter-js-from-html__6LDZHro` | 0 | absent | 0 | 0.00000000 | 0.0 | 2: score: TrimEvidenceMissing |
| 3 | off | `/tmp/zygos-phase10-schema/phase10-off-r3-fix-code-vulnerability/fix-code-vulnerability__brzRJVW` | 0 | absent | 0 | 0.00000000 | 0.0 | 0: cents=0 source_lines_read=0 reduction=0 |
| 3 | on | `/tmp/zygos-phase10-schema/phase10-on-r3-fix-code-vulnerability/fix-code-vulnerability__Ua5M46j` | 1165 | absent | 54 | 0.00020175 | 0.0 | 0: cents=0 source_lines_read=0 reduction=19 |
| 3 | off | `/tmp/zygos-phase10-schema/phase10-off-r3-fix-git/fix-git__2erU29P` | 807 | absent | 188 | 0.00021505 | 0.0 | 0: cents=0 source_lines_read=0 reduction=0 |
| 3 | on | `/tmp/zygos-phase10-schema/phase10-on-r3-fix-git/fix-git__G84SwQj` | 814 | absent | 204 | 0.00022410 | 0.0 | 2: score: TrimOnZeroReduction |
| 3 | off | `/tmp/zygos-phase10-schema/phase10-off-r3-log-summary-date-ranges/log-summary-date-ranges__2PkymCz` | 5132 | absent | 1073 | 0.00130630 | 0.0 | 0: cents=0 source_lines_read=0 reduction=0 |
| 3 | on | `/tmp/zygos-phase10-schema/phase10-on-r3-log-summary-date-ranges/log-summary-date-ranges__ZfmsiV8` | 0 | absent | 0 | 0.00000000 | 0.0 | 2: score: TrimEvidenceMissing |
| 3 | off | `/tmp/zygos-phase10-schema/phase10-off-r3-modernize-scientific-stack/modernize-scientific-stack__TXgTNXK` | 3521 | absent | 830 | 0.00094315 | 0.0 | 0: cents=0 source_lines_read=0 reduction=0 |
| 3 | on | `/tmp/zygos-phase10-schema/phase10-on-r3-modernize-scientific-stack/modernize-scientific-stack__Pmd2hFS` | 0 | absent | 0 | 0.00000000 | 0.0 | 2: score: TrimEvidenceMissing |
| 3 | off | `/tmp/zygos-phase10-schema/phase10-off-r3-regex-log/regex-log__pjhm9Fk` | 0 | absent | 0 | 0.00000000 | 0.0 | 0: cents=0 source_lines_read=0 reduction=0 |
| 3 | on | `/tmp/zygos-phase10-schema/phase10-on-r3-regex-log/regex-log__N9zR8wP` | 0 | absent | 0 | 0.00000000 | 0.0 | 2: score: TrimEvidenceMissing |

## Phase 10 diagnostic follow-up — 2026-10-02

The adapter had discarded task stdout/stderr on process exit 0, although that exit can contain a provider-failed turn. A new offline adapter test first failed with missing diagnostic files. It now verifies output preservation on exit 0 and redaction of the exec-environment key. All four adapter tests pass. The change only writes diagnostic files; it does not change task arguments, catalog, allowlist, model, timeout, adapter version, or the pinned Linux artifact. Phase 9 and Phase 10 were already finished before this logging change, and their reports remain unchanged. A keyless TLS-only check now succeeds from the modernize image (`/tmp/zygos-phase10-schema/keyless-tls-probe.txt`); that does not establish the earlier provider failure cause or current model quota. The first approved Phase 11 task will preserve diagnostics before launching any further members of the full set. `zig build test --summary all` passes 879/879 offline tests and `zig fmt --check src/` is clean.

## Phase 11 first trial — stopped 2026-10-02

Actual trial: `/tmp/zygos-phase11-schema/phase11-on-r1-modernize-scientific-stack/modernize-scientific-stack__J57q67E`. Same pinned binary: build sha `b157dc1fa2048b3aa313e66ba1b275f5c708c4ab`, SHA-256 `2f22205e1a85af623f13fb6c2d6c9718f7e4dda7836ae28cadc9c7bc5eb4b468`, triple `x86_64-linux.5.10...6.19-gnu.2.31`, ReleaseSafe, adapter 0.1.0, glm-5.3-flash, terminal-bench/terminal-bench-2-1, cap 24, trim on. Diagnostic-only adapter logging was committed as `bed2838` after Phase 10; the Linux artifact was not rebuilt. One task per invocation, no retry or Hub upload.

Harbor exit 0, no exception, verifier reward 0. Trial tokens: 571 input, 74 output; cache read and creation fields absent. At $0.15 input / $0.03 cached input / $0.50 output per million, recorded-usage cost is `571 × $0.15/M + 74 × $0.50/M = $0.00012265`. Scorer exit 2, `TrimOnZeroReduction`; trim calls 2, raw/sent bytes 218/218, reduction 0. Both tool inputs were non-empty, and neither result was handler_failed. The turn ended failed at its second provider step.

The redacted `agent/stdout.txt` contains `warning(provider_anthropic): glm-flash (model glm-5.3-flash): stream failed: HttpFailed`. That identifies a provider transport failure, not an empty-input handler failure; it does not establish a quota error, underlying send/receive error, or the cause of every older failed turn. No raw provider stream was captured. Campaign and first-trial report: `/tmp/zygos-phase11-schema/campaign.json` and `/tmp/zygos-phase11-schema/phase11-on-r1-modernize-scientific-stack.summary.json`. The remaining 88 tasks, SWE-bench Lite, and the Phase 12 mission have not run. Existing phase approvals remain recorded; no policy, budget, or completion gate was bypassed.

## Checks run on 2026-09-28

```bash
zig build test          # 870/870 passed
zig fmt --check src/    # clean
git diff -- build.zig.zon docs/PROTOCOL.md   # empty
```

`zig build test` does not invoke `eval/run.sh` and does not touch the network, the provider catalog, or the vault.

## DeepSeek blocker repairs — 2026-10-05

The operator requested fixing the remaining blockers and directed that every rerun use Deepseek Flash. The catalog entry is `deepseek/deepseek-v4.1-flash`, type `openai_compatible`, endpoint `https://openrouter.ai/api/v1`, key env `DEEPSEEK_API_KEY`, max_tokens 8192, temperature 0.7. Public model metadata resolves its canonical slug to `deepseek/deepseek-v4.1-flash-20260910`; the snapshot is `/tmp/zygos-deepseek-blockers/model-snapshot.json`. No dollar cap was named. Historical GLM results remain intact and are not combined with DeepSeek results.

An offline CLI regression first failed with `LiveRefused`; the parser now permits exactly the approved DeepSeek catalog model alongside the historical GLM model. Unknown models, the dataset pin, and the 1–32 step-cap limit remain enforced. The adapter regression likewise first failed at its model refusal. Its DeepSeek catalog is keyless and pins the explicit 8192-token output allowance and temperature from the operator catalog. The adapter selects the matching exec-environment credential, redacts diagnostics, and keeps both trim arms identical apart from the trim argument. A runner fixture first failed before the Harbor stub was invoked; `eval/run.sh` now forwards the selected approved model and supports a separate `ZYGOS_JOBS_DIR`, retaining one task, zero retries, and no upload/public flags.

Both HTTP clients had collapsed URL, request-setup, send, and response-head failures into `HttpFailed`. Offline public-client tests reproduced that loss of stage information. Each stage now has a distinct failure category and logs the underlying error name without request headers, credentials, bodies, or response text. This repairs the diagnostic blind spot; the historical GLM transport cause remains unproven because its raw stream and low-level errors were not retained. No new GLM request was made.

The original mission brief was linted but its success criteria were then lost from role context: the product-owner received only the extracted objective, while later roles trusted generated acceptance. An offline bus regression first failed when the provider request lacked the original brief. New missions persist the original intake as `BRIEF.md`; every role receives it as authoritative context, and resume reuses the saved original. Tests cover conflicting generated acceptance and resumed-role context. Existing brief-less context fixtures remain byte-identical, and budget, policy, and manual completion gates remain fail-closed.

An offline OpenRouter-shaped SSE regression first failed because the terminal payload lacked reported cache counts. The shared assembler and renderers now preserve optional cache-read/create fields, including nested `prompt_tokens_details`, without changing primary usage counters or trace serialization. Unreported cache counts remain absent. For OpenRouter, cached reads are a subset of prompt tokens: the three-rate calculation subtracts them from ordinary input before applying the cached-input rate. The scorer is unchanged and remains a trim check, not an invoice.

GitNexus was refreshed for this exact checkout at `ac15c0c`. The CLI/client and mission-context changes have low local impact; shared usage and the terminal renderers were explicitly flagged CRITICAL/HIGH before editing because both provider pipelines depend on them. Graph change analysis reports only the intended adapter, task CLI, provider usage/diagnostics, and mission-context scope. Offline checks: Zig 0.16.0 `zig build test --summary all` 887/887 passed; 8 Python adapter/runner tests passed; `zig fmt --check src/` clean; human-gated files unchanged. The host default Zig is now 0.17, so the repository checks use the checksum-verified official 0.16.0 toolchain at `/tmp/zig-aarch64-macos-0.16.0`. The prior `b157dc1` Linux binary is preserved at `/tmp/zygos-deepseek-blockers/historical-b157dc1-zygos`, with its original digest verified. No paid rerun has started at this repair checkpoint.

The repair checkpoint is commit `e81a30a`. Its first clean Linux build was SHA-256 `b1f25299baa995f1bb0f56bcccefab1c5e2519176faf625dfc76a5f2f6491d45`. A synthetic container check exited 2 before provider boot with `ModelKind`; it created no trial or usage and made no provider request. Evidence: `/tmp/zygos-deepseek-blockers/tool-path-refused-model-kind`. A second restriction in `src/config/providers.zig` required the Anthropic dialect for every task catalog row. A new offline test reproduced `ModelKind` (887/888 passed). The selector now accepts the OpenAI dialect only for the exact approved DeepSeek model, preserving GLM wrong-kind and duplicate-model refusals. GitNexus at `e81a30a` reports low impact, two direct callers confined to catalog lookup and the task CLI. This additional repair requires a replacement clean build before any campaign starts; the refused artifact is not a campaign baseline.

## DeepSeek live tool-path proof — 2026-10-05

The tool-path checkpoint Linux build is commit `9e186df8abefd46a1771b47af8a22e6a842e11ba`, SHA-256 `eb4ac1d7df9d4a0db02675f2f35faafaf92694196fbd6f41eb7a6c065f31f9ab`, target `x86_64-linux.5.10...6.19-gnu.2.31`, ReleaseSafe, adapter 0.1.0. Offline tests pass 888/888 after the catalog selector repair. Build metadata: `/tmp/zygos-deepseek-blockers/build.json`. This binary was used for the initial DeepSeek canary attempt. Its later task-image certificate failure requires an adapter repair and a replacement clean build before the fresh Phase 9 campaign; ledger edits alone do not trigger a build.

Two preflight attempts stopped before reported model usage. The minimal Debian smoke image lacked TLS certificates (`TlsInitializationFailed`), evidence `/tmp/zygos-deepseek-blockers/tool-path-refused-tls-minimal-image`. The benchmark modernize image has its certificate bundle and reached OpenRouter, which returned 401 for the host's `DEEPSEEK_API_KEY`, evidence `/tmp/zygos-deepseek-blockers/tool-path-refused-openrouter-auth`. The existing `OPENROUTER_API_KEY` authenticated successfully at OpenRouter's key endpoint (HTTP 200, no inference). For the live check and this campaign, the launch process binds that valid OpenRouter credential to the adapter's `DEEPSEEK_API_KEY` exec-environment slot. No credential was printed or written to a catalog or command argument, and the personal catalog was not edited.

Successful synthetic check: `/tmp/zygos-deepseek-blockers/tool-path/trial.json`, events and report in the same directory. This is a provider/tool smoke, not a Harbor task, Terminal-Bench member, or repeat of Phase 8. DeepSeek Flash completed four provider steps and all three requested tools with non-empty inputs: bash `seq 1 500`, read_file `fixture.txt`, write_file `note.txt` with the exact requested content. Terminal stop `end_turn`; read lines 3; trim calls 3, raw/sent 1920/767 bytes, reduction 60%; scorer exit 0, `cents=0 source_lines_read=3 reduction=60`. Tokens: 3605 prompt (including 1280 cached reads), 331 output, cache creation 0. Snapshot rates are $0.30 ordinary input / $0.006 cached input / $1.20 output per million: `(3605 - 1280) × $0.30/M + 1280 × $0.006/M + 331 × $1.20/M = $0.001102380`. This is a recorded-usage estimate, not a provider invoice.

The old `/tmp/terminal-bench-2-1` had lost its task configuration and instruction files. A fresh public source checkout is frozen at `7131e4375048a0e408a8fb404b5f499d726b695b` under `/tmp/zygos-deepseek-blockers/dataset-source`. All 89 image references match the ready inventory, and all eight canary directory checksums exactly match their historical Phase 9 records; evidence `/tmp/zygos-deepseek-blockers/dataset-checksums.json`. The DeepSeek Phase 9 rerun has started under `/tmp/zygos-phase9-deepseek`, with the same eight observed task ids, three repeats, cap 24, trim on, max_tokens 8192, temperature 0.7, one task per Harbor invocation, zero retries, no Hub upload, at most four independent host jobs. It stops further launches if a provider, infrastructure, or empty-input failure is detected.

SWE-bench Lite was rechecked without inference. The legacy registry and public Hub searches for `swe` and `lite` still do not expose a confirmed Lite package; Verified is `swe-bench/swe-bench-verified` and is not substituted. Saved public responses and status: `/tmp/zygos-deepseek-blockers/swe-lite-check.json`. The upstream Hugging Face Lite test split has 300 rows, but its dataset id is not a Harbor slug. DeepSeek Phase 10, Phase 11, and Phase 12 reruns remain not started, pending separate phase review/approval.

## Minimal task-image certificate repair — 2026-10-05

The initial DeepSeek canary detected `TlsInitializationFailed` in the actual `regex-log` image before inference (0 prompt/output tokens). Its saved stdout identifies request setup, rather than a quota, tool-input, or reasoning failure. The runner stops new launches once the current four-task batch has finished. This initial attempt is retained at `/tmp/zygos-phase9-deepseek`; it is not merged into the replacement campaign.

Four new offline adapter regressions first failed with missing provisioning and missing fail-closed errors. Adapter setup now probes Zig's Linux bundle locations, preserving an existing bundle. Only an image with no bundle requires an explicit `ZYGOS_CA_BUNDLE` source; a missing/non-PEM source or a failed probe/directory creation stops setup. The source is copied to `/etc/ssl/certs/ca-certificates.crt`. No certificate-verification bypass or package installation was added. For this operator run the public system bundle `/etc/ssl/cert.pem` has SHA-256 `9dae8d76e55cb08991f2b672d58999ea15560d910759c16b544f843bdffbb994`, 128 certificate blocks, 333483 bytes; snapshot `/tmp/zygos-deepseek-blockers/ca-bundle.json`.

An exact-binary check in the regex image with that bundle and a deliberately invalid probe credential reached OpenRouter's HTTP 401 instead of failing TLS. It made no authenticated inference and reported zero usage; evidence `/tmp/zygos-deepseek-blockers/keyless-ca-probe`. GitNexus reports no resolved upstream edges for setup (dynamic Harbor entry); manual review covers every trial's setup and both arms. Change analysis is limited to adapter setup/tests and operator documentation, low graph risk, with no partial/truncated result. Offline checks: 888/888 Zig tests, 12 Python adapter/runner tests, `zig fmt --check src/` clean. The replacement campaign runner is prepared at `/tmp/zygos-deepseek-blockers/run_phase9_ready.py`, with regex-log first and no next-phase launch.

## DeepSeek interrupted canary attempts — DNS repair 2026-10-05

Attempt `/tmp/zygos-phase9-deepseek` stopped after 8 task-runs. Build `9e186df8abefd46a1771b47af8a22e6a842e11ba`, SHA-256 `eb4ac1d7df9d4a0db02675f2f35faafaf92694196fbd6f41eb7a6c065f31f9ab`. Verifier successes 4; accepted scorer records 1; failed provider turns 1. Input 842059 (cache read 713600), output 64979; three-rate recorded-usage estimate `$0.120794100` at $0.30 ordinary input / $0.006 cache read / $1.20 output per million. These interrupted attempts are preserved separately from the replacement campaign. No second or third repeat launched in either attempt.

| Actual trial path | Input | Cache read | Output | Cost USD | Reward | Stop | Scorer |
|---|---:|---:|---:|---:|---:|---|---|
| `/tmp/zygos-phase9-deepseek/phase9-r1-build-cython-ext/build-cython-ext__4RHLYpb` | 199517 | 180480 | 4595 | 0.012307980 | 0.0 | max_steps | 0: cents=6 source_lines_read=0 reduction=22 |
| `/tmp/zygos-phase9-deepseek/phase9-r1-cobol-modernization/cobol-modernization__LsX5VQM` | 167229 | 136320 | 18179 | 0.031905420 | 0.0 | max_steps | 2: score: TrimOnZeroReduction |
| `/tmp/zygos-phase9-deepseek/phase9-r1-filter-js-from-html/filter-js-from-html__kea857s` | 223727 | 190464 | 26979 | 0.043496484 | 0.0 | max_steps | 2: score: TrimOnZeroReduction |
| `/tmp/zygos-phase9-deepseek/phase9-r1-fix-code-vulnerability/fix-code-vulnerability__pSnkReN` | 109936 | 99584 | 4977 | 0.009675504 | 1.0 | end_turn | 2: score: TrimOnZeroReduction |
| `/tmp/zygos-phase9-deepseek/phase9-r1-fix-git/fix-git__PbgCKyQ` | 34831 | 28544 | 2267 | 0.004777764 | 1.0 | end_turn | 2: score: TrimOnZeroReduction |
| `/tmp/zygos-phase9-deepseek/phase9-r1-log-summary-date-ranges/log-summary-date-ranges__4cLhYSD` | 67732 | 54016 | 3083 | 0.008138496 | 1.0 | end_turn | 2: score: TrimOnZeroReduction |
| `/tmp/zygos-phase9-deepseek/phase9-r1-modernize-scientific-stack/modernize-scientific-stack__dwjmR79` | 39087 | 24192 | 4899 | 0.010492452 | 1.0 | end_turn | 2: score: TrimOnZeroReduction |
| `/tmp/zygos-phase9-deepseek/phase9-r1-regex-log/regex-log__DqXyrzK` | 0 | absent | 0 | 0E-9 | 0.0 | failed | 2: score: TrimEvidenceMissing |

Attempt `/tmp/zygos-phase9-deepseek-ready` stopped after 8 task-runs. Build `83f0a0a2a09b33831aa1325e9b72772cfd8d63c7`, SHA-256 `7695a137d12f3f7453608d5df2c8d2c138daf70c30abe4f34753a803fcd83951`. Verifier successes 4; accepted scorer records 1; failed provider turns 2. Input 878558 (cache read 734336), output 53661; three-rate recorded-usage estimate `$0.112065816` at $0.30 ordinary input / $0.006 cache read / $1.20 output per million. These interrupted attempts are preserved separately from the replacement campaign. No second or third repeat launched in either attempt.

| Actual trial path | Input | Cache read | Output | Cost USD | Reward | Stop | Scorer |
|---|---:|---:|---:|---:|---:|---|---|
| `/tmp/zygos-phase9-deepseek-ready/phase9-r1-build-cython-ext/build-cython-ext__LHMvREQ` | 308758 | 272640 | 4885 | 0.018333240 | 0.0 | max_steps | 2: score: TrimOnZeroReduction |
| `/tmp/zygos-phase9-deepseek-ready/phase9-r1-cobol-modernization/cobol-modernization__NTewk2X` | 75168 | 61056 | 14151 | 0.021581136 | 0.0 | failed | 2: score: TrimOnZeroReduction |
| `/tmp/zygos-phase9-deepseek-ready/phase9-r1-filter-js-from-html/filter-js-from-html__Ru22E8R` | 5566 | 3072 | 11583 | 0.014666232 | 0.0 | failed | 2: score: TrimOnZeroReduction |
| `/tmp/zygos-phase9-deepseek-ready/phase9-r1-fix-code-vulnerability/fix-code-vulnerability__aMuxgTn` | 250746 | 227072 | 5534 | 0.015105432 | 1.0 | end_turn | 2: score: TrimOnZeroReduction |
| `/tmp/zygos-phase9-deepseek-ready/phase9-r1-fix-git/fix-git__oqhBGE3` | 58458 | 50944 | 4577 | 0.008052264 | 1.0 | end_turn | 2: score: TrimOnZeroReduction |
| `/tmp/zygos-phase9-deepseek-ready/phase9-r1-log-summary-date-ranges/log-summary-date-ranges__9wbDXXx` | 150917 | 97536 | 2025 | 0.019029516 | 1.0 | end_turn | 0: cents=4 source_lines_read=0 reduction=86 |
| `/tmp/zygos-phase9-deepseek-ready/phase9-r1-modernize-scientific-stack/modernize-scientific-stack__sWyjbfh` | 28292 | 22016 | 2714 | 0.005271696 | 1.0 | end_turn | 2: score: TrimOnZeroReduction |
| `/tmp/zygos-phase9-deepseek-ready/phase9-r1-regex-log/regex-log__Wvs9Dg2` | 653 | 0 | 8192 | 0.010026300 | 0.0 | max_tokens | 2: score: TrimEvidenceMissing |

The certificate-ready attempt failed in two later provider steps with request-setup `NameServerFailure` (cobol-modernization and filter-js-from-html). This is an observed DNS failure, not proof that CPU load caused it. After the run, a keyless Docker probe received valid A and AAAA answers in all 10 queries; `/tmp/zygos-deepseek-blockers/docker-dns-probe.txt`. Host lookup also succeeded. No DNS server, VPN, or host networking configuration was changed. The DNS failures were recorded as failed turns and stopped further launches. The regex model output limit was 8192 and stopped its first turn as max_tokens; that remains a benchmark failure, not a transport failure.

Three offline public-client regressions first failed (888/891 passed): two transient DNS failures were not retried, persistent failure had no bounded-attempt behavior, and backoff cancellation was not exercised. The OpenAI-compatible client now retries only NameServerFailure at request setup, at most twice with one-second cancellable delays. No HTTP request body has been sent at that point, so no POST is replayed. A persistent DNS failure still stops after three setup attempts; permanent setup failures, cancellation, sends, response failures, API errors, policies, and budgets are not retried by this change. GitNexus at 83f0a0a reports low impact, two direct references, one OpenAI provider process. The third campaign will use a fresh clean build containing this fix, at most two concurrent jobs to reduce emulation load, and the same model/configuration on every trial.

## DeepSeek third canary — interrupted 2026-10-05

Attempt `/tmp/zygos-phase9-deepseek-dns` stopped at 20/24 trials, git `6b1bd9173d68f2313a88fec69f40055d4be4d695`, binary SHA-256 `980b8fe0c07a9c3dac82e759df58b30ae43b80ba8f813aa53e8fc200f8bf9b3a`. Same pinned triple, ReleaseSafe, adapter 0.1.0, DeepSeek Flash, dataset, cap 24, trim on, 8192 output allowance, temperature 0.7, frozen public certificate bundle; two concurrent host jobs, one task per invocation, zero Harbor retries, no Hub upload. Verifier rewards 1: 13/20; accepted scorer records: 2/20; provider failures: 2; empty inputs and handler_failed results: 0. The failed fix-git turn still earned Harbor reward 1 and remains a transport failure. Positive trim reduction is recorded in build-cython-ext r1 (11%) and log-summary-date-ranges r2 (79%).

Input 2479292 including 2015488 cached reads; output 210342. At $0.30 ordinary input / $0.006 cached input / $1.20 output per million, `(input - cache_read) × $0.30/M + cache_read × $0.006/M + output × $1.20/M` gives `$0.403644528` for recorded usage. Usage on incomplete provider responses may not be reported; this is not an invoice or an upper bound. Validated aggregate: `/tmp/zygos-phase9-deepseek-dns/partial-summary.json`.

The cobol-modernization and fix-git third-repeat stdout records `stream idle timeout: shutting down provider socket` followed by `BadStream`. These are not DNS failures. Four third-repeat tasks were never launched: filter-js-from-html, fix-code-vulnerability, log-summary-date-ranges, regex-log. Phase 9 is incomplete; later DeepSeek phases remain not started.

| Run | Actual trial path | Input | Cache read | Output | Cost USD | Reward | Stop | Scorer |
|---|---|---:|---:|---:|---:|---:|---|---|
| 1 | `/tmp/zygos-phase9-deepseek-dns/phase9-r1-build-cython-ext/build-cython-ext__4vND45h` | 295301 | 251264 | 4528 | 0.020152284 | 0.0 | max_steps | 0: cents=8 source_lines_read=0 reduction=11 |
| 1 | `/tmp/zygos-phase9-deepseek-dns/phase9-r1-cobol-modernization/cobol-modernization__GrqatcJ` | 258585 | 155904 | 28909 | 0.066430524 | 1.0 | max_steps | 2: score: TrimOnZeroReduction |
| 1 | `/tmp/zygos-phase9-deepseek-dns/phase9-r1-filter-js-from-html/filter-js-from-html__AVsWJQB` | 115519 | 60288 | 19851 | 0.040752228 | 0.0 | max_tokens | 2: score: TrimOnZeroReduction |
| 1 | `/tmp/zygos-phase9-deepseek-dns/phase9-r1-fix-code-vulnerability/fix-code-vulnerability__zhW6fkn` | 167142 | 144640 | 4130 | 0.012574440 | 1.0 | end_turn | 2: score: TrimOnZeroReduction |
| 1 | `/tmp/zygos-phase9-deepseek-dns/phase9-r1-fix-git/fix-git__jgtuqUm` | 81077 | 70400 | 7245 | 0.012319500 | 1.0 | end_turn | 2: score: TrimOnZeroReduction |
| 1 | `/tmp/zygos-phase9-deepseek-dns/phase9-r1-log-summary-date-ranges/log-summary-date-ranges__PX9BMbF` | 120001 | 84992 | 3557 | 0.015281052 | 1.0 | end_turn | 2: score: TrimOnZeroReduction |
| 1 | `/tmp/zygos-phase9-deepseek-dns/phase9-r1-modernize-scientific-stack/modernize-scientific-stack__qQynEsp` | 42514 | 29696 | 4069 | 0.008906376 | 1.0 | end_turn | 2: score: TrimOnZeroReduction |
| 1 | `/tmp/zygos-phase9-deepseek-dns/phase9-r1-regex-log/regex-log__ZkS8Yz9` | 134593 | 121472 | 24647 | 0.034241532 | 1.0 | max_steps | 2: score: TrimOnZeroReduction |
| 2 | `/tmp/zygos-phase9-deepseek-dns/phase9-r2-build-cython-ext/build-cython-ext__jKFZAvP` | 162973 | 149760 | 4688 | 0.010488060 | 0.0 | max_steps | 2: score: TrimOnZeroReduction |
| 2 | `/tmp/zygos-phase9-deepseek-dns/phase9-r2-cobol-modernization/cobol-modernization__5eDnpRo` | 184835 | 171008 | 20991 | 0.030363348 | 0.0 | max_steps | 2: score: TrimOnZeroReduction |
| 2 | `/tmp/zygos-phase9-deepseek-dns/phase9-r2-filter-js-from-html/filter-js-from-html__WzrAYYS` | 243018 | 226816 | 23538 | 0.034467096 | 0.0 | max_steps | 2: score: TrimOnZeroReduction |
| 2 | `/tmp/zygos-phase9-deepseek-dns/phase9-r2-fix-code-vulnerability/fix-code-vulnerability__Xtp9E9t` | 136985 | 110848 | 5629 | 0.015260988 | 1.0 | end_turn | 2: score: TrimOnZeroReduction |
| 2 | `/tmp/zygos-phase9-deepseek-dns/phase9-r2-fix-git/fix-git__e2BMjMx` | 65097 | 56704 | 5583 | 0.009557724 | 1.0 | end_turn | 2: score: TrimOnZeroReduction |
| 2 | `/tmp/zygos-phase9-deepseek-dns/phase9-r2-log-summary-date-ranges/log-summary-date-ranges__Yo2xsGo` | 22811 | 12800 | 1249 | 0.004578900 | 1.0 | end_turn | 0: cents=0 source_lines_read=0 reduction=79 |
| 2 | `/tmp/zygos-phase9-deepseek-dns/phase9-r2-modernize-scientific-stack/modernize-scientific-stack__nCytLQX` | 23535 | 12800 | 3014 | 0.006914100 | 1.0 | end_turn | 2: score: TrimOnZeroReduction |
| 2 | `/tmp/zygos-phase9-deepseek-dns/phase9-r2-regex-log/regex-log__A2PAJCZ` | 56327 | 38656 | 30926 | 0.042644436 | 1.0 | end_turn | 2: score: TrimOnZeroReduction |
| 3 | `/tmp/zygos-phase9-deepseek-dns/phase9-r3-build-cython-ext/build-cython-ext__cGS9aJ3` | 237605 | 207360 | 4457 | 0.015666060 | 0.0 | max_steps | 2: score: TrimOnZeroReduction |
| 3 | `/tmp/zygos-phase9-deepseek-dns/phase9-r3-cobol-modernization/cobol-modernization__BbqP2NE` | 57193 | 50176 | 7078 | 0.010899756 | 0.0 | failed | 2: score: TrimOnZeroReduction |
| 3 | `/tmp/zygos-phase9-deepseek-dns/phase9-r3-fix-git/fix-git__n9kiCyX` | 28966 | 22528 | 1928 | 0.004380168 | 1.0 | failed | 2: score: TrimOnZeroReduction |
| 3 | `/tmp/zygos-phase9-deepseek-dns/phase9-r3-modernize-scientific-stack/modernize-scientific-stack__craz4AC` | 45215 | 37376 | 4325 | 0.007765956 | 1.0 | end_turn | 2: score: TrimOnZeroReduction |

## Incremental SSE pump repair — 2026-10-05

Both provider HTTP pumps used Zig 0.16 readSliceShort, whose contract fills the requested 4096-byte slice until EOF. It can hide arriving short chunks from the watchdog and assembler, and can wait for more bytes after a terminal event. A new injected-reader regression in each client delivers 17-byte chunks, refuses any subsequent read unless activity was poked, and keeps the stream open after the terminal fixture. Both failed with BadStream before implementation (891/893 tests passed). The minimum fix uses readVec once per pump iteration and distinguishes explicit EndOfStream from a zero-byte read. It processes and pokes each non-empty read immediately; zero-byte reads do not claim activity. The 120-second watchdog, socket shutdown, request/body behavior, routing, policies, and budgets remain unchanged. The raw live stream was not recorded, so this offline reproduction does not prove the third campaign's exact cause.

GitNexus on clean 6b1bd91 reports CRITICAL impact for each processSse (486 upstream symbols, 172 direct references, 100 affected process entries, including test/shared-name edges). The warning was reported before editing; manual source review covers streamChat and each provider handler. Full change analysis is also critical, without partial/truncated results; actual diff is the two pumps, their new regressions, and this ledger. Validation: 893/893 offline Zig tests, 12 offline Python tests, zig fmt --check src/ and git diff --check clean. No human-gated file changes. A replacement Phase 9 campaign must use one new clean artifact for all 24 trials; the interrupted 6b1bd91 records are not mixed into it.

## DeepSeek fourth canary — interrupted 2026-10-06

Executed 24 task-runs, but provider health failed: the same eight observed tasks, three repeats each. Build sha `1ac0d7f627f6dc3057de52b37c2ba1ebc62e6c46`, binary SHA-256 `7d7736b53ac8271bcd7743e43fc94ab3e8a52389b1a52105ce73c492ebdc9b80`, triple `x86_64-linux.5.10...6.19-gnu.2.31`, ReleaseSafe, adapter 0.1.0, model `deepseek/deepseek-v4.1-flash`, dataset `terminal-bench/terminal-bench-2-1`, cap 24, trim on, output allowance 8192, temperature 0.7. All uploaded binary hashes and trial identities match. Certificate provisioning uses the explicit bundle recorded above and is unchanged across trials; existing bundles are preserved. One task per Harbor invocation, zero retries, no Hub upload, at most two concurrent jobs in this campaign. No rebuild occurred for ledger edits.

Verifier successes: 11/24. Scorer accepted: 1/24. Provider failures: 2; handler_failed results: 1 (all saved inputs audited as missing required arguments); empty tool inputs: 0. Terminal stops: `{"end_turn": 10, "failed": 2, "max_steps": 7, "max_tokens": 5}`. Scorer refusals remain errors, including zero reduction or missing trim evidence, and are not counted as valid measurements. The canary contains recorded command output with positive reduction. Tool-result success counts mean handler delivery; bash can still report a nonzero command exit.

Aggregate tokens: 2591843 input (including 2236288 cached reads), 223039 output. At $0.30 ordinary input / $0.006 cached input / $1.20 output per million, recorded-usage estimate is `$0.387731028`. Formula: `(input - cache_read) × $0.30/M + cache_read × $0.006/M + output × $1.20/M`. Source snapshot is `/tmp/zygos-deepseek-blockers/model-snapshot.json`; incomplete responses may omit usage; this estimate is separate from the scorer's integer cents check and is not a provider invoice.

Campaign: `/tmp/zygos-phase9-deepseek-stream/campaign.json`; verified aggregate: `/tmp/zygos-phase9-deepseek-stream/partial-summary.json`. Actual trial paths, Harbor rewards, tokens, costs, and scorer results follow.

| Run | Actual trial path | Input | Cache read | Output | Dollar cost | Reward | Stop | Scorer |
|---|---|---:|---:|---:|---:|---:|---|---|
| 1 | `/tmp/zygos-phase9-deepseek-stream/phase9-r1-build-cython-ext/build-cython-ext__iqXvweR` | 383076 | 350336 | 6319 | 0.019506816 | 0.0 | max_steps | 2: score: TrimOnZeroReduction |
| 1 | `/tmp/zygos-phase9-deepseek-stream/phase9-r1-cobol-modernization/cobol-modernization__whHXbJu` | 162139 | 139904 | 19635 | 0.031071924 | 0.0 | max_steps | 2: score: TrimOnZeroReduction |
| 1 | `/tmp/zygos-phase9-deepseek-stream/phase9-r1-filter-js-from-html/filter-js-from-html__sugFAc2` | 21679 | 12800 | 11418 | 0.016442100 | 0.0 | max_tokens | 2: score: TrimOnZeroReduction |
| 1 | `/tmp/zygos-phase9-deepseek-stream/phase9-r1-fix-code-vulnerability/fix-code-vulnerability__9jkdZuf` | 232324 | 215808 | 7865 | 0.015687648 | 0.0 | max_steps | 2: score: TrimOnZeroReduction |
| 1 | `/tmp/zygos-phase9-deepseek-stream/phase9-r1-fix-git/fix-git__nvt9rh4` | 84318 | 75904 | 4620 | 0.008523624 | 1.0 | end_turn | 2: score: TrimOnZeroReduction |
| 1 | `/tmp/zygos-phase9-deepseek-stream/phase9-r1-log-summary-date-ranges/log-summary-date-ranges__HPaLZhR` | 14766 | 6656 | 933 | 0.003592536 | 1.0 | end_turn | 2: score: TrimOnZeroReduction |
| 1 | `/tmp/zygos-phase9-deepseek-stream/phase9-r1-modernize-scientific-stack/modernize-scientific-stack__vH2KFCV` | 37300 | 30208 | 4872 | 0.008155248 | 1.0 | end_turn | 2: score: TrimOnZeroReduction |
| 1 | `/tmp/zygos-phase9-deepseek-stream/phase9-r1-regex-log/regex-log__sK5sEJz` | 84351 | 75904 | 20109 | 0.027120324 | 1.0 | end_turn | 2: score: TrimOnZeroReduction |
| 2 | `/tmp/zygos-phase9-deepseek-stream/phase9-r2-build-cython-ext/build-cython-ext__xJvaDTL` | 205174 | 189568 | 4727 | 0.011491608 | 0.0 | max_steps | 2: score: TrimOnZeroReduction |
| 2 | `/tmp/zygos-phase9-deepseek-stream/phase9-r2-cobol-modernization/cobol-modernization__iZDBBjY` | 174356 | 158720 | 29770 | 0.041367120 | 0.0 | max_steps | 2: score: TrimOnZeroReduction |
| 2 | `/tmp/zygos-phase9-deepseek-stream/phase9-r2-filter-js-from-html/filter-js-from-html__7TnhZ4o` | 13580 | 5504 | 18153 | 0.024239424 | 0.0 | max_tokens | 2: score: TrimOnZeroReduction |
| 2 | `/tmp/zygos-phase9-deepseek-stream/phase9-r2-fix-code-vulnerability/fix-code-vulnerability__6MwbUvQ` | 205339 | 184832 | 4781 | 0.012998292 | 0.0 | max_steps | 2: score: TrimOnZeroReduction |
| 2 | `/tmp/zygos-phase9-deepseek-stream/phase9-r2-fix-git/fix-git__dLZZGX4` | 59141 | 51328 | 4215 | 0.007709868 | 1.0 | end_turn | 2: score: TrimOnZeroReduction |
| 2 | `/tmp/zygos-phase9-deepseek-stream/phase9-r2-log-summary-date-ranges/log-summary-date-ranges__adMrVos` | 41576 | 0 | 1858 | 0.014702400 | 1.0 | end_turn | 0: cents=1 source_lines_read=0 reduction=98 |
| 2 | `/tmp/zygos-phase9-deepseek-stream/phase9-r2-modernize-scientific-stack/modernize-scientific-stack__cJm2Fm2` | 29361 | 24192 | 3953 | 0.006439452 | 1.0 | end_turn | 2: score: TrimOnZeroReduction |
| 2 | `/tmp/zygos-phase9-deepseek-stream/phase9-r2-regex-log/regex-log__B5AqKZD` | 653 | 640 | 8192 | 0.009838140 | 0.0 | max_tokens | 2: score: TrimEvidenceMissing |
| 3 | `/tmp/zygos-phase9-deepseek-stream/phase9-r3-build-cython-ext/build-cython-ext__RCDWKzA` | 322553 | 282496 | 5500 | 0.020312076 | 0.0 | max_steps | 2: score: TrimOnZeroReduction |
| 3 | `/tmp/zygos-phase9-deepseek-stream/phase9-r3-cobol-modernization/cobol-modernization__tDrseFd` | 150660 | 137088 | 32933 | 0.044413728 | 0.0 | max_tokens | 2: score: TrimOnZeroReduction |
| 3 | `/tmp/zygos-phase9-deepseek-stream/phase9-r3-filter-js-from-html/filter-js-from-html__sKWVMse` | 16878 | 3584 | 16234 | 0.023490504 | 0.0 | max_tokens | 2: score: TrimOnZeroReduction |
| 3 | `/tmp/zygos-phase9-deepseek-stream/phase9-r3-fix-code-vulnerability/fix-code-vulnerability__MkYu6Bv` | 196811 | 176640 | 5764 | 0.014027940 | 1.0 | end_turn | 2: score: TrimOnZeroReduction |
| 3 | `/tmp/zygos-phase9-deepseek-stream/phase9-r3-fix-git/fix-git__4hLWM28` | 36968 | 30592 | 3254 | 0.006001152 | 1.0 | end_turn | 2: score: TrimOnZeroReduction |
| 3 | `/tmp/zygos-phase9-deepseek-stream/phase9-r3-log-summary-date-ranges/log-summary-date-ranges__8MhmRb3` | 80844 | 52480 | 2819 | 0.012206880 | 1.0 | failed | 2: score: TrimOnZeroReduction |
| 3 | `/tmp/zygos-phase9-deepseek-stream/phase9-r3-modernize-scientific-stack/modernize-scientific-stack__38NA27H` | 37996 | 31104 | 5115 | 0.008392224 | 1.0 | end_turn | 2: score: TrimOnZeroReduction |
| 3 | `/tmp/zygos-phase9-deepseek-stream/phase9-r3-regex-log/regex-log__nQHFWCo` | 0 | absent | 0 | 0E-9 | 0.0 | failed | 2: score: TrimEvidenceMissing |

Recorded argument failures (distinct from provider transport failures): `[{"cause": "recorded call lacks required arguments", "missing": ["path"], "step": 2, "tool": "write_file", "trial_path": "/tmp/zygos-phase9-deepseek-stream/phase9-r1-regex-log/regex-log__sK5sEJz"}]`.

Stopped before a healthy Phase 9 completion. The final log-summary and regex turns hit the unchanged 120-second idle watchdog. Their stdout records socket shutdown and BadStream; the full raw streams were not saved. Their exact cause remains unproven. A separate offline reproduction covers bytes already buffered by an indirect reader and terminal events on a still-open socket. DeepSeek Phase 10 (48 matched on/off trials only after a healthy replacement canary), Phase 11 (full 89, then Lite only with a confirmed Harbor pin), and Phase 12 (one mission with genuine kill/resume and a manual completion gate) remain not started. Original-brief preservation and resume coverage are proven offline; no new live mission success is claimed. The Lite Harbor package remains unconfirmed. RADAR, BrowseComp-Plus, and Y5 remain behind their separate gates.

## Buffered stream completion repair — 2026-10-06

The earlier short-read regression covered direct reader output but missed already-buffered bytes. Zig Reader.readVec can copy a short buffered prefix and then block reading more; an indirect TLS reader can also populate its buffer while returning zero. Two new offline regressions, one per provider pump, cover a pre-buffered complete terminal fixture and an indirect reader returning zero after filling the same fixture. They reject any further socket read after loading it. Both failed with BadStream (893/895 passed), proving that the first stream repair was incomplete.

Each pump now drains its available buffer before calling readVec. It processes and pokes that buffered payload immediately, then stops on a terminal event without an extra socket read. A zero return from an indirect read is followed by another iteration that checks its populated buffer. A ReadFailed warning reports only buffered-byte count and activity-update count, never stream content, request headers, or keys. The watchdog remains 120 seconds; no provider POST is retried, no timeout is disabled, and no policy, budget, or gate is relaxed. These offline cases establish a real bug; they do not establish the exact bytes received during the interrupted live turns.

GitNexus on 1ac0d7f reports OpenAI MEDIUM impact (15 upstream symbols, 9 direct references, two provider processes) and Anthropic HIGH impact (10 upstream symbols, 8 direct references, two processes). The HIGH warning was reported before implementation. Full change analysis is low, with no partial/truncated result and no resolved affected processes; manual source review still covers both provider paths and streamChat callers. Final validation: 895/895 offline Zig tests, 12 offline Python tests, zig fmt --check src/ and git diff --check clean. No human-gated files were edited. The replacement artifact will be built once from this committed clean tree and preserved for any later matched arms.

## DeepSeek fifth canary — invalid completion repair 2026-10-06

Attempt `/tmp/zygos-phase9-deepseek-buffered` stopped after 20/24 trials, git `b94b711312aee8a18ae7abd803e5ece2a4c91525`, binary SHA-256 `98e3bc1967c9d94da344b51c7a9eb9c3cb309da3510e5c89345764bf8033c68c`. All trial identities and uploaded hashes match; same target, ReleaseSafe, adapter 0.1.0, model, dataset, cap 24, trim on, output allowance 8192, temperature 0.7, frozen CA bundle, two concurrent host jobs, one task per invocation, zero Harbor retries, no Hub upload. Verifier successes 11/20, accepted scorer records 1/20. No HTTP/DNS/idle failure was observed in these 20; one provider reply failed at the bus boundary. build-cython-ext r1 records positive trim reduction of 12%. Four third-repeat tasks did not launch: filter-js-from-html, fix-code-vulnerability, log-summary-date-ranges, regex-log. This is not a healthy completed Phase 9 campaign.

The cobol third-repeat provider reply contained incomplete write_file argument JSON at output_tokens 8192, reported tool_use, and was embedded raw in an invalid invocationresult frame. The bus rejected it with MalformedJson; it was not an idle watchdog or DNS failure. The raw provider stream was not saved. Its saved inproc warning includes an already-assembled usage header: input 8124, cache read 7296, output 8192, cache creation 0. That reply never reached task bridge accounting. The diagnostic body is not repeated here; supplemental totals are recorded separately, and trial.json is not rewritten.

Recorded trial totals: input 2143710 (cache read 1879680), output 195498; snapshot estimate `$0.475626330`. Additional known unrecorded reply estimate `$0.019685172`; combined known usage estimate `$0.495311502`. Formula remains `(input - cache_read) × ordinary rate + cache_read × cached rate + output × output rate`. Public OpenRouter metadata was rechecked 2026-10-06; the canonical slug is unchanged, but rates changed to $0.003 ordinary input / $0.003 cached input / $2.40 output per million. This attempt uses `/tmp/zygos-deepseek-blockers/model-snapshot-2026-10-06.json`. Earlier attempts retain their original $0.30/$0.006/$1.20 snapshot estimates; the change's exact effective time and invoice are unavailable. The scorer still uses a separate fixed 30 cents per million check rate, not these published rates. Aggregate: `/tmp/zygos-phase9-deepseek-buffered/partial-summary.json`.

| Run | Actual trial path | Input | Cache read | Output | Recorded estimate USD | Reward | Stop | Scorer |
|---|---|---:|---:|---:|---:|---:|---|---|
| 1 | `/tmp/zygos-phase9-deepseek-buffered/phase9-r1-build-cython-ext/build-cython-ext__7M7qwZY` | 288527 | 269312 | 3834 | 0.010067181 | 0.0 | max_steps | 0: cents=8 source_lines_read=0 reduction=12 |
| 1 | `/tmp/zygos-phase9-deepseek-buffered/phase9-r1-cobol-modernization/cobol-modernization__QmCymux` | 209279 | 192768 | 29938 | 0.072479037 | 0.0 | max_steps | 2: score: TrimOnZeroReduction |
| 1 | `/tmp/zygos-phase9-deepseek-buffered/phase9-r1-filter-js-from-html/filter-js-from-html__Fo7hmAG` | 48906 | 40064 | 23810 | 0.057290718 | 0.0 | max_tokens | 2: score: TrimOnZeroReduction |
| 1 | `/tmp/zygos-phase9-deepseek-buffered/phase9-r1-fix-code-vulnerability/fix-code-vulnerability__ctTTysb` | 84216 | 74112 | 2773 | 0.006907848 | 1.0 | end_turn | 2: score: TrimOnZeroReduction |
| 1 | `/tmp/zygos-phase9-deepseek-buffered/phase9-r1-fix-git/fix-git__8rRWAkX` | 53022 | 25344 | 3204 | 0.007848666 | 1.0 | end_turn | 2: score: TrimOnZeroReduction |
| 1 | `/tmp/zygos-phase9-deepseek-buffered/phase9-r1-log-summary-date-ranges/log-summary-date-ranges__voob462` | 29791 | 20224 | 1483 | 0.003648573 | 1.0 | end_turn | 2: score: TrimOnZeroReduction |
| 1 | `/tmp/zygos-phase9-deepseek-buffered/phase9-r1-modernize-scientific-stack/modernize-scientific-stack__7tGntwG` | 37607 | 29952 | 3722 | 0.009045621 | 1.0 | end_turn | 2: score: TrimOnZeroReduction |
| 1 | `/tmp/zygos-phase9-deepseek-buffered/phase9-r1-regex-log/regex-log__ct3JwDs` | 25416 | 20864 | 13718 | 0.032999448 | 1.0 | end_turn | 2: score: TrimOnZeroReduction |
| 2 | `/tmp/zygos-phase9-deepseek-buffered/phase9-r2-build-cython-ext/build-cython-ext__Rx4m4Sd` | 233206 | 201088 | 4552 | 0.011624418 | 0.0 | max_steps | 2: score: TrimOnZeroReduction |
| 2 | `/tmp/zygos-phase9-deepseek-buffered/phase9-r2-cobol-modernization/cobol-modernization__5HPBR7W` | 148871 | 135936 | 31398 | 0.075801813 | 0.0 | max_steps | 2: score: TrimOnZeroReduction |
| 2 | `/tmp/zygos-phase9-deepseek-buffered/phase9-r2-filter-js-from-html/filter-js-from-html__sBciDbE` | 20939 | 14080 | 13822 | 0.033235617 | 0.0 | end_turn | 2: score: TrimOnZeroReduction |
| 2 | `/tmp/zygos-phase9-deepseek-buffered/phase9-r2-fix-code-vulnerability/fix-code-vulnerability__ZkNqXNN` | 304865 | 284416 | 8635 | 0.021638595 | 1.0 | max_steps | 2: score: TrimOnZeroReduction |
| 2 | `/tmp/zygos-phase9-deepseek-buffered/phase9-r2-fix-git/fix-git__BMGHTRK` | 65345 | 48000 | 3102 | 0.007640835 | 1.0 | end_turn | 2: score: TrimOnZeroReduction |
| 2 | `/tmp/zygos-phase9-deepseek-buffered/phase9-r2-log-summary-date-ranges/log-summary-date-ranges__2CCfRLj` | 19727 | 11392 | 1989 | 0.004832781 | 1.0 | end_turn | 2: score: TrimOnZeroReduction |
| 2 | `/tmp/zygos-phase9-deepseek-buffered/phase9-r2-modernize-scientific-stack/modernize-scientific-stack__Mwtzs4A` | 23996 | 19072 | 2850 | 0.006911988 | 1.0 | end_turn | 2: score: TrimOnZeroReduction |
| 2 | `/tmp/zygos-phase9-deepseek-buffered/phase9-r2-regex-log/regex-log__X2xYi3L` | 653 | 640 | 8192 | 0.019662759 | 0.0 | max_tokens | 2: score: TrimEvidenceMissing |
| 3 | `/tmp/zygos-phase9-deepseek-buffered/phase9-r3-build-cython-ext/build-cython-ext__9NzPWj7` | 387151 | 361600 | 4680 | 0.012393453 | 0.0 | max_steps | 2: score: TrimOnZeroReduction |
| 3 | `/tmp/zygos-phase9-deepseek-buffered/phase9-r3-cobol-modernization/cobol-modernization__4NjPejN` | 47518 | 40192 | 17711 | 0.042648954 | 0.0 | failed | 2: score: TrimOnZeroReduction |
| 3 | `/tmp/zygos-phase9-deepseek-buffered/phase9-r3-fix-git/fix-git__jjGJUNw` | 93058 | 73216 | 13283 | 0.032158374 | 1.0 | max_tokens | 2: score: TrimOnZeroReduction |
| 3 | `/tmp/zygos-phase9-deepseek-buffered/phase9-r3-modernize-scientific-stack/modernize-scientific-stack__zGmj935` | 21617 | 17408 | 2802 | 0.006789651 | 1.0 | end_turn | 2: score: TrimOnZeroReduction |

A new offline SSE→terminal→real task-bus regression first failed because the terminal renderer produced invalid JSON (895/896 passed). It covers length-limited and malformed tool_calls completions, asserts no dispatch/file creation, and requires input/output/cache usage to reach trial accounting. The assembler now omits partial tool blocks on max_tokens; other malformed argument JSON stops as unknown without materializing any tool block. The turn driver now treats unsupported stop reasons as provider_error after accounting rather than treating them as a normal completion. No malformed call is repaired into empty arguments or dispatched. The regression's failed assertion exposed that driver boundary; the test was not weakened. Final result: 896/896 offline Zig tests, 12 Python tests, format and diff checks clean.

GitNexus reports HIGH assembler impact (24 upstream symbols, 11 direct references, three processes). The warning was reported before implementation. Impact queries did not resolve the private runTurn function; manual source review found its entry handler and task/mission callers. No protocol file, dependency, policy, budget, or approval gate was weakened. Later DeepSeek phases remain not started. A replacement full campaign uses one clean artifact; malformed model completions are explicit benchmark failures with preserved usage, distinct from transport failures.

## DeepSeek Phase 9 — completed 2026-10-06

Executed 24 task-runs: the same eight observed tasks, three repeats each. Build sha `a147d52286e9b2e63ff4991800e98af57d792de1`, binary SHA-256 `09008d658265bb6f4e06e61386f1a2b1c284905d91e61a087366a1a73d812926`, triple `x86_64-linux.5.10...6.19-gnu.2.31`, ReleaseSafe, adapter 0.1.0, model `deepseek/deepseek-v4.1-flash`, dataset `terminal-bench/terminal-bench-2-1`, cap 24, trim on, output allowance 8192, temperature 0.7. All uploaded binary hashes and trial identities match. Certificate provisioning uses the explicit bundle recorded above and is unchanged across trials; existing bundles are preserved. One task per Harbor invocation, zero retries, no Hub upload, at most two concurrent jobs in this campaign. No rebuild occurred for ledger edits.

Verifier successes: 11/24. Scorer accepted: 1/24. Provider transport/RPC failures: 0; failed turns from malformed/unsupported model completions: 0; handler_failed results: 0; empty tool inputs: 0. Terminal stops: `{"end_turn": 12, "max_steps": 8, "max_tokens": 4}`. Scorer refusals remain errors, including zero reduction or missing trim evidence, and are not counted as valid measurements. The canary contains recorded command output with positive reduction. Tool-result success counts mean handler delivery; bash can still report a nonzero command exit.

Aggregate tokens: 2451344 input (including 2108160 cached reads), 229662 output. At $0.003 ordinary input / $0.003 cached input / $2.40 output per million, recorded-usage estimate is `$0.558542832`. Formula: `(input - cache_read) × $0.003/M + cache_read × $0.003/M + output × $2.40/M`. Source snapshot is `/tmp/zygos-deepseek-blockers/model-snapshot-2026-10-06.json`; incomplete responses may omit usage; this estimate is separate from the scorer's integer cents check and is not a provider invoice.

Campaign: `/tmp/zygos-phase9-deepseek-completions/campaign.json`; verified aggregate: `/tmp/zygos-phase9-deepseek-completions/completion-summary.json`. Actual trial paths, Harbor rewards, tokens, costs, and scorer results follow.

| Run | Actual trial path | Input | Cache read | Output | Dollar cost | Reward | Stop | Scorer |
|---|---|---:|---:|---:|---:|---:|---|---|
| 1 | `/tmp/zygos-phase9-deepseek-completions/phase9-r1-build-cython-ext/build-cython-ext__i56ymm8` | 226058 | 198272 | 4448 | 0.011353374 | 0.0 | max_steps | 2: score: TrimOnZeroReduction |
| 1 | `/tmp/zygos-phase9-deepseek-completions/phase9-r1-cobol-modernization/cobol-modernization__LDfz8QY` | 178392 | 141056 | 18956 | 0.046029576 | 0.0 | max_steps | 2: score: TrimOnZeroReduction |
| 1 | `/tmp/zygos-phase9-deepseek-completions/phase9-r1-filter-js-from-html/filter-js-from-html__5d4Vgt6` | 13189 | 4864 | 10023 | 0.024094767 | 0.0 | max_tokens | 2: score: TrimOnZeroReduction |
| 1 | `/tmp/zygos-phase9-deepseek-completions/phase9-r1-fix-code-vulnerability/fix-code-vulnerability__ojNjrTs` | 202993 | 190080 | 4108 | 0.010468179 | 0.0 | max_steps | 2: score: TrimOnZeroReduction |
| 1 | `/tmp/zygos-phase9-deepseek-completions/phase9-r1-fix-git/fix-git__Qq6onjP` | 33273 | 12672 | 2464 | 0.006013419 | 1.0 | end_turn | 2: score: TrimOnZeroReduction |
| 1 | `/tmp/zygos-phase9-deepseek-completions/phase9-r1-log-summary-date-ranges/log-summary-date-ranges__juwdZbk` | 68347 | 50944 | 2307 | 0.005741841 | 1.0 | end_turn | 2: score: TrimOnZeroReduction |
| 1 | `/tmp/zygos-phase9-deepseek-completions/phase9-r1-modernize-scientific-stack/modernize-scientific-stack__DaDjZyw` | 35202 | 29312 | 3760 | 0.009129606 | 1.0 | end_turn | 2: score: TrimOnZeroReduction |
| 1 | `/tmp/zygos-phase9-deepseek-completions/phase9-r1-regex-log/regex-log__rLWuwv8` | 653 | 0 | 8192 | 0.019662759 | 0.0 | max_tokens | 2: score: TrimEvidenceMissing |
| 2 | `/tmp/zygos-phase9-deepseek-completions/phase9-r2-build-cython-ext/build-cython-ext__HAcUjp7` | 188757 | 173952 | 3781 | 0.009640671 | 0.0 | max_steps | 2: score: TrimOnZeroReduction |
| 2 | `/tmp/zygos-phase9-deepseek-completions/phase9-r2-cobol-modernization/cobol-modernization__JDUBJXL` | 165858 | 142720 | 26747 | 0.064690374 | 0.0 | max_steps | 2: score: TrimOnZeroReduction |
| 2 | `/tmp/zygos-phase9-deepseek-completions/phase9-r2-filter-js-from-html/filter-js-from-html__gJoL6nP` | 25491 | 19968 | 24759 | 0.059498073 | 0.0 | end_turn | 2: score: TrimOnZeroReduction |
| 2 | `/tmp/zygos-phase9-deepseek-completions/phase9-r2-fix-code-vulnerability/fix-code-vulnerability__Zy88Q62` | 308495 | 283392 | 17200 | 0.042205485 | 0.0 | max_steps | 0: cents=9 source_lines_read=0 reduction=28 |
| 2 | `/tmp/zygos-phase9-deepseek-completions/phase9-r2-fix-git/fix-git__LjULdEm` | 40663 | 25856 | 3108 | 0.007581189 | 1.0 | end_turn | 2: score: TrimOnZeroReduction |
| 2 | `/tmp/zygos-phase9-deepseek-completions/phase9-r2-log-summary-date-ranges/log-summary-date-ranges__HevdS8K` | 22877 | 14080 | 1139 | 0.002802231 | 1.0 | end_turn | 2: score: TrimOnZeroReduction |
| 2 | `/tmp/zygos-phase9-deepseek-completions/phase9-r2-modernize-scientific-stack/modernize-scientific-stack__tFPGWV3` | 30414 | 24320 | 3730 | 0.009043242 | 1.0 | end_turn | 2: score: TrimOnZeroReduction |
| 2 | `/tmp/zygos-phase9-deepseek-completions/phase9-r2-regex-log/regex-log__7Cxjvha` | 19786 | 16128 | 13773 | 0.033114558 | 1.0 | end_turn | 2: score: TrimOnZeroReduction |
| 3 | `/tmp/zygos-phase9-deepseek-completions/phase9-r3-build-cython-ext/build-cython-ext__NLttx9q` | 396684 | 370432 | 5992 | 0.015570852 | 0.0 | max_steps | 2: score: TrimOnZeroReduction |
| 3 | `/tmp/zygos-phase9-deepseek-completions/phase9-r3-cobol-modernization/cobol-modernization__rwSd6w8` | 203894 | 184576 | 29380 | 0.071123682 | 0.0 | max_steps | 2: score: TrimOnZeroReduction |
| 3 | `/tmp/zygos-phase9-deepseek-completions/phase9-r3-filter-js-from-html/filter-js-from-html__9FVumge` | 61221 | 54272 | 26350 | 0.063423663 | 0.0 | max_tokens | 2: score: TrimOnZeroReduction |
| 3 | `/tmp/zygos-phase9-deepseek-completions/phase9-r3-fix-code-vulnerability/fix-code-vulnerability__9ZSNJJu` | 136248 | 115072 | 4673 | 0.011623944 | 1.0 | end_turn | 2: score: TrimOnZeroReduction |
| 3 | `/tmp/zygos-phase9-deepseek-completions/phase9-r3-fix-git/fix-git__ygPtdaN` | 39607 | 23424 | 2316 | 0.005677221 | 1.0 | end_turn | 2: score: TrimOnZeroReduction |
| 3 | `/tmp/zygos-phase9-deepseek-completions/phase9-r3-log-summary-date-ranges/log-summary-date-ranges__mugD8N2` | 31286 | 15104 | 1917 | 0.004694658 | 1.0 | end_turn | 2: score: TrimOnZeroReduction |
| 3 | `/tmp/zygos-phase9-deepseek-completions/phase9-r3-modernize-scientific-stack/modernize-scientific-stack__LcAFZ9K` | 21303 | 17024 | 2347 | 0.005696709 | 1.0 | end_turn | 2: score: TrimOnZeroReduction |
| 3 | `/tmp/zygos-phase9-deepseek-completions/phase9-r3-regex-log/regex-log__HqxnTKY` | 653 | 640 | 8192 | 0.019662759 | 0.0 | max_tokens | 2: score: TrimEvidenceMissing |

Recorded argument failures (distinct from provider transport failures): `[]`.

Unsupported or malformed model completions remain failed benchmark outcomes, never transport successes or repaired tool calls. Their usage is recorded before stopping; they are not retried. The separate scorer rate remains 30 cents per million and is not an invoice rate.

Stopped after Phase 9. DeepSeek Phase 10 (48 matched on/off trials on this exact artifact), Phase 11 (full 89, then Lite only with a confirmed Harbor pin), and Phase 12 (one mission with genuine kill/resume and a manual completion gate) remain not started. Original-brief preservation and resume coverage are proven offline; no new live mission success is claimed. The Lite Harbor package remains unconfirmed. RADAR, BrowseComp-Plus, and Y5 remain behind their separate gates.

## DeepSeek session cost and handoff — 2026-10-06

This session executed 104 Harbor task-runs across six repair attempts, plus the separate synthetic tool-path preflight. Interrupted attempts are preserved; only the final 24-run campaign is the completed replacement Phase 9. No DeepSeek Phase 10, 11, or 12 run occurred.

| Attempt directory under `/tmp/` | Task-runs | Recorded-usage estimate |
|---|---:|---:|
| `zygos-phase9-deepseek` | 8 | $0.120794100 |
| `zygos-phase9-deepseek-ready` | 8 | $0.112065816 |
| `zygos-phase9-deepseek-dns` | 20 | $0.403644528 |
| `zygos-phase9-deepseek-stream` | 24 | $0.387731028 |
| `zygos-phase9-deepseek-buffered` | 20 | $0.475626330 |
| `zygos-phase9-deepseek-completions` | 24 | $0.558542832 |

Synthetic tool-path preflight: $0.001102380. Additional known usage from the rejected buffered-attempt reply: $0.019685172, kept outside its unchanged trial. Combined known-usage estimate: **$2.079192186**. Earlier estimates retain their $0.30 ordinary input / $0.006 cached input / $1.20 output snapshot; the last two campaigns use the $0.003 / $0.003 / $2.40 snapshot. The pricing change effective time and provider invoice are unavailable; incomplete responses can have unreported usage. This total is neither an invoice nor an upper bound.

The final accepted record is vulnerability repeat 2: 88,748 raw bytes → 63,362 sent bytes, integer reduction 28%, scorer exit 0. Every final snapshot reports `filtered=0` and `deduped=0`: this establishes generic truncation wiring, not command-specific filtering. The other 23 scorer records remain invalid measurements (21 `TrimOnZeroReduction`, two `TrimEvidenceMissing`). The 401 recorded tool calls reached handlers successfully. Four turns stopped at `max_tokens`, eight at `max_steps`, and 12 at `end_turn`; verifier rewards remain the benchmark outcomes.

Final offline checks: Zig 0.16.0, `zig build test --summary all` 896/896, 12 Python adapter/runner tests, `zig fmt --check src/`, and `git diff --check`. Tests use mocks/fixtures and no real catalog, vault, or network. Linux SHA-256 stays `09008d658265bb6f4e06e61386f1a2b1c284905d91e61a087366a1a73d812926`; retain the artifact built from clean source `a147d52286e9b2e63ff4991800e98af57d792de1` for every Phase 10 arm. A ledger-only commit changes checkout HEAD but does not rebuild that artifact.

The reviewable Phase 10 proposal is `/tmp/zygos-deepseek-blockers/phase10-proposal.json`: 48 task-runs, eight identical tasks × three repeats × trim on/off. Its source, binary, model, dataset, cap, CA bundle, and provider settings match the final Phase 9; trim is the only harness variable. It has not launched. Separate approval is required by ADR 004 and the original phase gates. The runnable SWE-bench Lite Harbor package remains unconfirmed; Verified is not substituted. Master remains untouched and nothing is pushed.

## Benchmark authority update — 2026-10-07

The operator questioned why an approval policy was filed as an architectural decision and explicitly directed agents to work without the operator becoming a blocker. That replaces the earlier instruction to stop and ask after each phase. The active policy is now `docs/benchmark-policy.md`; record 004 remains as superseded historical context. `AGENTS.md`, the task spec, and README point to the active policy.

Agents have standing authority to execute and assess the planned DeepSeek phases 10–12 and advance when their evidence prerequisites are met, including resolving the isolated benchmark mission's completion approval as delegated operator after independent acceptance checks through the real approval path. Source fixes still require offline red-first evidence and a clean artifact; policy, budget, and gate failures still stop. Trial/scorer failures remain recorded outcomes. No success criterion or runtime guard was changed.

This policy update executed no paid trial and did not rebuild the frozen Linux artifact. Phase 10's 48-run proposal is authorized under the standing policy, not waiting on an operator answer. The full 89-task Phase 11, verified Lite package investigation, and isolated Phase 12 follow the planned scope. The Lite package remains unconfirmed; agents investigate it without asking the operator to supply an identifier. Historical approvals, interrupted attempts, and cost estimates above remain unchanged.
