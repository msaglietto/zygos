# ADR 004: Phases 8, 9, and 10 are separate spend approvals

## Status

Accepted.

## Context

There is no campaign dollar envelope. Naming one here would invent a cap. A dated model id is also still unset, so no paid run has a price row that names the model that will actually be called.

The shape of the later work, if it is approved, is fixed even though the dollar number is not. Phase 8 is one pilot task. Phase 9 is 3 runs of 8–12 tasks (24–36 task-runs). Phase 10 repeats that on both trim arms (48–72 more task-runs).

## Decision

Phase 8 approval covers the pilot only. Phases 9 and 10 each stall until their own approval, unless a dollar cap is named before phase 8. This record does not choose that number. The task command refuses a live provider run until both a dated model id and a spend approval exist. The eval runner refuses a live Harbor run on the same condition.

## Consequences

Finishing the offline phases does not authorize the pilot. A later approval of phase 8 does not authorize phase 9 or phase 10. Arms in phase 10 are comparable only when git sha, target triple, optimize level, and adapter version match and the single harness variable differs.
