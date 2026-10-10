# Benchmark report: trim-ablation

Generated 2026-10-08T07:11:20.539671+00:00. Variable: **trim**. Verdict: **candidate_better**.

- pass delta -1 on 24 matched task-runs; cost delta -0.111889716 USD (-16.3%)
- pass delta is within repeat noise: 1 task(s) flipped outcome between repeats of one arm; the verdict rests on cost
- trim metric: candidate scorer accepted 24, refused 0; baseline accepted 3, refused 21

## Arms

| | trim-on | trim-off |
|---|---|---|
| git sha | `b8a79db6300617395a9c3894d9e1fcedb44440a6` | `b8a79db6300617395a9c3894d9e1fcedb44440a6` |
| binary sha256 | `54bf161ed54dc520f0f858e3f17669c6b9444e8e71902f1b1179a5c1d2decc2e` | `54bf161ed54dc520f0f858e3f17669c6b9444e8e71902f1b1179a5c1d2decc2e` |
| config sha256 | `none` | `none` |
| trim | `on` | `off` |

## Results

| Metric | trim-on | trim-off |
|---|---:|---:|
| Task-runs recorded / expected | 24 / 24 | 24 / 24 |
| Verifier passes | 14 | 13 |
| Pass rate | 0.5833 | 0.5417 |
| Input tokens | 3998400 | 2828228 |
| Cache-read tokens (in input) | 3532032 | 2494592 |
| Output tokens | 281741 | 236583 |
| Snapshot cost USD | 0.688173600 | 0.576283884 |
| Cost per resolved task USD | 0.049155 | 0.044330 |
| Mean provider steps | 15.96 | 13.46 |
| Mean elapsed seconds | 188.21 | 166.47 |
| Turn stops | {"end_turn": 12, "max_steps": 9, "max_tokens": 3} | {"end_turn": 13, "max_steps": 6, "max_tokens": 5} |
| Trim compress calls | 462 | 0 |
| Scorer accepted | 3 | 24 |
| Scorer refused | {"score: TrimOnZeroReduction": 21} | {} |
| Unscored trials | 0 | 0 |
| Mean accepted reduction % | 28.0 | 0.0 |
| Transport failures | 0 | 0 |
| Harbor exceptions | 0 | 0 |
| Task-runs with problems | 0 | 0 |

## Matched task-runs

| Task | Repeat | trim-on reward | trim-off reward | Pass delta | Cost delta USD | Problems |
|---|---:|---:|---:|---:|---:|---|
| build-cython-ext | 1 | 0.0 | 0.0 | 0 | -0.001438062 |  |
| cobol-modernization | 1 | 0.0 | 1.0 | 1 | -0.057983985 |  |
| filter-js-from-html | 1 | 0.0 | 0.0 | 0 | 0.007387224 |  |
| fix-code-vulnerability | 1 | 1.0 | 1.0 | 0 | 0.000569985 |  |
| fix-git | 1 | 1.0 | 1.0 | 0 | -0.002379540 |  |
| log-summary-date-ranges | 1 | 1.0 | 1.0 | 0 | 0.003364308 |  |
| modernize-scientific-stack | 1 | 1.0 | 1.0 | 0 | -0.001252536 |  |
| regex-log | 1 | 0.0 | 0.0 | 0 | -0.000237576 |  |
| build-cython-ext | 2 | 0.0 | 0.0 | 0 | -0.000788883 |  |
| cobol-modernization | 2 | 0.0 | 0.0 | 0 | 0.002282934 |  |
| filter-js-from-html | 2 | 0.0 | 0.0 | 0 | 0.030562908 |  |
| fix-code-vulnerability | 2 | 1.0 | 1.0 | 0 | 0.004025145 |  |
| fix-git | 2 | 1.0 | 1.0 | 0 | -0.000328791 |  |
| log-summary-date-ranges | 2 | 1.0 | 1.0 | 0 | 0.000253164 |  |
| modernize-scientific-stack | 2 | 1.0 | 1.0 | 0 | 0.001733241 |  |
| regex-log | 2 | 1.0 | 0.0 | -1 | -0.014994759 |  |
| build-cython-ext | 3 | 0.0 | 0.0 | 0 | 0.002722368 |  |
| cobol-modernization | 3 | 0.0 | 0.0 | 0 | -0.008487153 |  |
| filter-js-from-html | 3 | 0.0 | 0.0 | 0 | -0.015410970 |  |
| fix-code-vulnerability | 3 | 1.0 | 1.0 | 0 | -0.004400016 |  |
| fix-git | 3 | 1.0 | 1.0 | 0 | -0.001271544 |  |
| log-summary-date-ranges | 3 | 1.0 | 1.0 | 0 | -0.005642058 |  |
| modernize-scientific-stack | 3 | 1.0 | 1.0 | 0 | -0.001775817 |  |
| regex-log | 3 | 1.0 | 0.0 | -1 | -0.048399303 |  |

## Provenance

- Model `deepseek/deepseek-v4.1-flash`, dataset `terminal-bench/terminal-bench-2-1` at `7131e4375048a0e408a8fb404b5f499d726b695b`, step cap 24, repeats 3.
- Prices per million tokens: input 0.003, cached input 0.003, output 2.40 (source https://openrouter.ai/api/v1/models, retrieved 2026-10-06T04:11:09.724231+00:00). Snapshot estimates, not an invoice.
- Jobs directory: `/private/tmp/zygos-trim-ablation` (raw traces stay there; this report carries numbers and identities only).
- Zero rewards, step or output limits, and scorer refusals are recorded outcomes, not reruns.
