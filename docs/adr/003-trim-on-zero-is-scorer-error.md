# ADR 003: Trim-on zero reduction is a scorer error

## Status

Accepted.

## Context

The compress seam passes tool output through when `zygos::output::compress` is not registered. A suite can stay green while the trim worker never runs. That is the failure mode where filters shipped and were not wired. `LEDGER.md` is written only at mission end, so a headless task has no ledger to consult.

The trim-off arm is the control. Zero reduction there is a real result.

## Decision

The task command starts `TrimWorker` with the same limits as the mission CLI when the arm is trim-on, reads `zygos::output::stats`, and stores calls, filtered, deduped, raw bytes, sent bytes, and the reduction percent on the trial. The trim-off arm does not register the worker and stores an explicit zero snapshot.

The scorer rejects a trim-on trial whose snapshot is missing, whose call count is zero, or whose recorded reduction is zero. It accepts zero reduction on trim-off. A trim-on snapshot whose sent bytes exceed raw bytes, or whose recorded reduction is not the percent computed from those two fields, is a malformed trial rather than a zero-reduction result. Token addition or the price multiplication that overflows is the same malformed-trial error. A missing price for the pinned model, and a missing build-identity field, are also scorer errors. A present price of zero is a free model, not a missing price.

## Consequences

A report over a trim-on arm cannot hide an inert seam behind a flat pass rate. The offline fixture includes `seq 1 500`, which is over the line cap, so a wired arm records a reduction above zero. A canary that never produces filterable output would fail this guard even when the worker is wired.
