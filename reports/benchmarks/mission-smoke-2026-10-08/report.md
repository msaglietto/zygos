# Benchmark report: mission-smoke

Generated 2026-10-08T07:54:21.927684+00:00. Mode: **mission**. Variable: **config**. Verdict: **candidate_worse**.

- pass delta -1 on 1 matched task-runs; cost delta -0.018838686 USD (-86.5%)
- fewer than 24 matched task-runs: treat the direction as a hint, not a measurement
- mission traces carry no cache counts: every input token is priced at the ordinary rate, so costs are an upper bound and comparable only between these arms

## Arms

| | all-deepseek | executor-glm |
|---|---|---|
| git sha | `b8a79db6300617395a9c3894d9e1fcedb44440a6` | `b8a79db6300617395a9c3894d9e1fcedb44440a6` |
| binary sha256 | `54bf161ed54dc520f0f858e3f17669c6b9444e8e71902f1b1179a5c1d2decc2e` | `54bf161ed54dc520f0f858e3f17669c6b9444e8e71902f1b1179a5c1d2decc2e` |
| config sha256 | `5a9104d695653fb041a3f31480a656f55c4a4d8d37514ee984b29c406434f354` | `c16a77a27710f17db4a9bfd6c9ebf524aab6e09ce14006cb8064b71ce2958423` |
| trim | `on` | `on` |

## Results

| Metric | all-deepseek | executor-glm |
|---|---:|---:|
| Task-runs recorded / expected | 1 / 1 | 1 / 1 |
| Verifier passes | 1 | 0 |
| Pass rate | 1.0 | 0.0 |
| Input tokens | 76963 | 601 |
| Cache-read tokens (in input) | 0 | 0 |
| Output tokens | 8981 | 1227 |
| Snapshot cost USD | 0.021785289 | 0.002946603 |
| Cost per resolved task USD | 0.021785 | None |
| Mean provider steps | 20.0 | 3.0 |
| Mean role turns | 5.0 | 3.0 |
| Mission states | {"gating": 1} | {"failed": 1} |
| Role failures | 0 | 1 |
| Mean elapsed seconds | 105.84 | 38.22 |
| Turn stops | {"parked": 1} | {"role_failed": 1} |
| Trim compress calls | 0 | 0 |
| Scorer accepted | 0 | 0 |
| Scorer refused | {} | {} |
| Unscored trials | 1 | 1 |
| Mean accepted reduction % | None | None |
| Transport failures | 0 | 0 |
| Harbor exceptions | 0 | 0 |
| Task-runs with problems | 0 | 0 |

## Matched task-runs

| Task | Repeat | all-deepseek reward | executor-glm reward | Pass delta | Cost delta USD | Problems |
|---|---:|---:|---:|---:|---:|---|
| fix-git | 1 | 1.0 | 0.0 | -1 | -0.018838686 |  |

## Provenance

- Model `deepseek/deepseek-v4.1-flash`, dataset `terminal-bench/terminal-bench-2-1` at `7131e4375048a0e408a8fb404b5f499d726b695b`, step cap 24, repeats 1.
- Prices per million tokens: input 0.003, cached input 0.003, output 2.40 (source https://openrouter.ai/api/v1/models, retrieved 2026-10-06T04:11:09.724231+00:00). Snapshot estimates, not an invoice.
- Jobs directory: `/private/tmp/zygos-mission-smoke` (raw traces stay there; this report carries numbers and identities only).
- Zero rewards, step or output limits, and scorer refusals are recorded outcomes, not reruns.
