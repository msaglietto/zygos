# Benchmark assessment — 2026-10-08

The benchmark foundation works, but the operator's goal is only partially
complete. This branch can run a fixed headless Zygos task in Harbor and collect
evidence. It cannot yet take different `zygos.zon` files and produce a reliable
comparison, and the completed runs do not demonstrate a harness improvement.

Assessment: `harness-bench` at `69da661`, compared with the locally available
`upstream/master` at `9ff488d`. No paid benchmark was launched for this assessment.
GitNexus was refreshed to the assessed commit and used to trace the task path;
the configuration finding was also checked directly against the source.

## What was built

- [`src/cli/task.zig`](../src/cli/task.zig) and
  [`src/worker/task.zig`](../src/worker/task.zig): a headless instruction-to-turn
  command, step limit, bench tool policy, optional trim worker, and trial output.
- [`src/worker/trial.zig`](../src/worker/trial.zig): build identity, token/cache
  accounting, source-read and compression counters, and a per-trial scorer.
- [`eval/harbor/zygos_agent.py`](../eval/harbor/zygos_agent.py): uploads a Linux
  binary into the task container and executes the command. Harbor's verifier
  determines task success; Zygos exit 0 only means the command completed.
- [`eval/run.sh`](../eval/run.sh): a Terminal-Bench 2.1 runner for one selected
  task, with model checks, a platform inventory, no retries, and a jobs directory.

The branch also repairs issues exposed by live execution: tool argument loss,
missing required tool schemas, Linux entropy, minimal-image certificate stores,
provider selection, DNS setup, SSE reads, malformed tool completions, and mission
brief persistence. Later review added scorer and Anthropic safety fixes.

These repairs made the measurements possible and protected shared runtime paths.
They are not themselves evidence that benchmark performance improved. Some of
the apparent branch size also comes from the repository audit merged from
master. Against the available current upstream base, the branch changes 44 files,
with 5,712 insertions and 64 deletions; comparison with the older local `master`
shows 89 files and includes already integrated audit work.

## Where to see results

Start with the durable, selected-data summary saved in the working tree:
[`deepseek-canary-2026-10-06.json`](benchmarks/deepseek-canary-2026-10-06.json).
It preserves the latest campaign's identities, snapshot rates, aggregate metrics,
task results, and per-trial evidence pointers. It is a summary, not an archive of
the full raw outputs or a reusable report program.

The historical narrative and per-run tables are in
[`docs/WORK-LEDGER.md`](../docs/WORK-LEDGER.md), especially “DeepSeek Phase 9 —
completed 2026-10-06,” “DeepSeek session cost and handoff,” and “Phase 10
schema-repaired campaign.”

On this machine the latest full evidence is:

```text
/tmp/zygos-phase9-deepseek-completions/campaign.json
/tmp/zygos-phase9-deepseek-completions/completion-summary.json
/tmp/zygos-phase9-deepseek-completions/<job>/<trial>/agent/trial.json
/tmp/zygos-phase9-deepseek-completions/<job>/<trial>/agent/events.jsonl
/tmp/zygos-phase9-deepseek-completions/<job>/<trial>/verifier/reward.txt
```

All 24 trial files, event files, verifier rewards, Harbor trial result files, and
uploaded binaries were present during this assessment. Trial contents, rewards,
identity fields, all binary hashes, aggregate usage, and the snapshot cost
formula match the campaign. Temporary paths are not durable storage: the older
GLM Phase 10 directory remains, but its referenced `campaign.json` was absent.

## What the results establish

Latest DeepSeek canary: eight tasks, three repeats, trim on, 24 steps maximum,
`deepseek/deepseek-v4.1-flash`, Terminal-Bench 2.1.

| Metric | Observed |
| --- | --- |
| Verifier passes | 11/24 (45.8%) |
| Recorded-usage cost estimate | $0.558542832 |
| Input / output tokens | 2,451,344 / 229,662 |
| Cache-read tokens, included in input | 2,108,160 |
| Transport/RPC failures | 0 |
| Tool handler failures / empty tool inputs | 0 / 0 |
| Scorer accepted | 1/24 |
| Scorer refused | 21 zero-reduction records; 2 missing-evidence records |
| Accepted compression result | 28% reduction on vulnerability repeat 2 |
| Command-filter / deduplication counters | 0 / 0 across all trials |
| Stops | 12 end-turn, 8 step-limit, 4 output-limit |
| Successful `read_file` source lines | 0 across all trials |

Task passes out of three: build-cython-ext 0, cobol-modernization 0,
filter-js-from-html 0, fix-code-vulnerability 1, fix-git 3,
log-summary-date-ranges 3, modernize-scientific-stack 3, regex-log 1.

Verifier outcomes and scorer validity are separate. Eleven tasks passed their
tests; that does not turn the other 23 trim records into accepted measurements.
The scorer deliberately rejects trim-on zero savings, including small output
that a functioning worker legitimately leaves unchanged. This makes the current
canary poorly suited to demonstrating trim savings. Generic truncation was
observed; command-specific filtering was not. Existing guards were not changed.

This is a baseline observation, not an A/B result. There is no completed DeepSeek
trim-off arm. The historical GLM comparison ran 48 matched trials, but all rewards
were zero and 47 turns failed; its cost difference is inconclusive. Changing model
and binary between GLM and DeepSeek also prevents attributing their difference to
one harness feature.

The live baseline used source `a147d52`, not current HEAD `69da661`. The currently
retained Linux binary still matches that baseline's SHA-256. Later review fixes
have offline coverage, but no live benchmark of those fixes is claimed.

Across the six recorded DeepSeek repair campaigns and a preflight, the ledger's
known-usage estimate is $2.079192186. This includes interrupted work and different
historical price snapshots; it is neither a provider invoice nor an upper bound.

## Assessment against the intended workflow

| Intended capability | State |
| --- | --- |
| Run real Zygos tasks in benchmark containers | Implemented and exercised |
| Record task outcomes, tokens, compression, build identity | Implemented; evidence split across Zygos and Harbor files |
| Change `zygos.zon` and compare results | Missing |
| Reusable campaign report with pass rate and cost per resolved task | Missing from tracked tooling |
| Freeze and run a named canary with repeats | Used by temporary scripts; no tracked `eval/canary.txt` or campaign command |
| Demonstrate an improvement with matched arms | Not established |
| Re-run consistently for a release | Individual tasks supported; repeatable baseline/candidate workflow incomplete |
| Measure mission roles, routing, context strategies, kill/resume | Separate mission benchmark incomplete |
| Full 89-task benchmark and SWE-bench Lite | Incomplete; Lite's runnable Harbor pin unconfirmed |

The decisive configuration gap is in `src/cli/task.zig:runLive` and
`src/worker/task.zig:Session.start/buildRequest`. The CLI reads a providers TOML
catalog and passes an explicit model. The task boots tools, a fixed policy, trim,
provider bridge, and the turn worker; its request names a fixed provider function.
It does not load `zygos.zon`, boot its model router, or pass context strategies.
The Harbor adapter supplies a fixed keyless provider catalog and exposes trim
through `ZYGOS_TRIM`; it does not upload a ZON configuration.

Consequently, editing `zygos.zon` does not change this benchmark. A feature that
affects these task/provider paths can be measured after rebuilding, but a mission
feature needs a workload that actually executes its mission behavior.

The original plan's Phase 6 required an aggregate report, including resolved
rate, dollars per resolved task, tokens, steps, and a fixture job-directory test.
The ledger labels Phase 6 done, but the shipped command scores one trial and
prints integer cents, lines, and reduction. The separate campaign JSONs and
manual tables do not fulfill that reusable reporting requirement. Phase 9's
tracked canary file is also absent. Historical Phase 12 was genuinely killed and
resumed, then failed before verification and the completion gate. Replacement
DeepSeek phases 10–12 remain unstarted despite standing authority.

## What should complete the work

1. Make a tracked experiment definition: frozen task IDs/checksums, model and
   provider settings, step cap, baseline/candidate source and binary identities,
   configuration snapshots/hashes, and the single variable being compared.
2. Add explicit task configuration support for applicable `zygos.zon` settings,
   with routing/context wiring and adapter upload. Reject unsupported settings
   instead of silently ignoring them. Keep mission-specific evaluation separate.
3. Ship one campaign runner and report command. Report matched task/repeat deltas,
   verifier pass rate, input/output/cache tokens, snapshot-priced USD and cost per
   resolved task, steps/time, and the feature metric. Keep transport failures,
   scorer refusals, and task failures visible; insufficient evidence is inconclusive.
4. Store a sanitized report, configuration, canary, and provenance under a stable
   results directory. Keep sensitive raw traces separately, with an explicit
   retention location. The report must work from fixture jobs without inference.
5. Finish a healthy matched comparison under the existing benchmark policy, then
   use that exact workflow for baseline-versus-release comparisons. A new source
   repair requires its own matched baseline rather than mixing old and new arms.

Definition of done: two supported configuration files, or two release binaries,
can run the same frozen tasks and repeats through one documented command and
produce a durable comparison that either shows the measured change or explains
why the evidence is inconclusive. That is the remaining operator-facing goal.

## Assessment checks

Current source passes 952/952 offline Zig tests with the required Zig 0.16.0,
12 mocked Python runner/adapter tests with Harbor's installed Python environment,
and `zig fmt --check build.zig src/ test/`. The dry run reports the pinned dataset
and ready Linux platform inventory. These checks establish code health, not
benchmark improvement; the filter probe and integration suites were not rerun
for this documentation-only assessment.

There is additional setup friction on this machine: plain `zig` currently selects
0.17.0, which fails to compile this 0.16.0 project, and the system Python cannot
import Harbor. The passing commands used the existing installations:

```bash
/tmp/zig-aarch64-macos-0.16.0/zig build test --summary all
PYTHONDONTWRITEBYTECODE=1 /Users/msaglietto/.local/share/uv/tools/harbor/bin/python \
  -m unittest eval.test_run eval.harbor.test_zygos_agent
```

Pinning/documenting that toolchain is part of making the experiment workflow
repeatable. No runtime code, policies, scorer rules, dependency entries, or
protocol files were changed. This session added only this assessment and its
selected-data JSON summary; neither was committed or pushed.
