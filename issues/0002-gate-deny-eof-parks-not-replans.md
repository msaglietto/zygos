---
title: Unanswered completion gate parks the mission instead of replanning
status: closed
labels: [ready-for-agent]
created: 2026-07-25
closed: 2026-07-25
resolution: >
  Fixed in d6dfad2 (feat(worker/mission)): approval deny replies carry
  resolved:bool; the gate parks at gating on resolved:false (named tests
  in approval.zig and mission.zig), replans on answered denies.
origin: Y5 run .planning-20260725-040525 (zahir-radar vault) — verified work
  destroyed by a gate-deny → replan → budget-death loop
---

# Unanswered completion gate parks the mission instead of replanning

## Problem Statement

An unattended mission run (stdin closed — the Y5 weekly shape) that reaches
the completion gate with verified work can never terminate cleanly. The
console approver gets EOF, the manual approval times out, and the deny is
indistinguishable from a human saying "no, redo it": the gate routes
`gate_denied → planning`, the planner invents remedial tasks, the executor
re-researches work the verifier already passed, and the mission burns the
remaining budget until it dies `budget_exhausted`. Observed on the first
post-M4.7 Y5 attempt: 3/3 tasks done, `VERIFY.md passed: true`, then a
gate timeout → re-plan to 2 tasks → death at 1,004,422 tokens with the
finished artifact sitting on disk inside a failed mission.

A deny that carries human intent ("redo, here's why") should replan. A deny
that means "nobody was there to answer" should not destroy verified work.

## Solution

Distinguish the two denies at the source and park on the unanswered one.

- `worker/approval.zig`: a deny reply gains `"resolved": bool` — `true`
  when a human (or auto mode) actually resolved the request, `false` when
  the manual timeout expired unanswered. Approve replies are unchanged.
- `worker/mission.zig` `gate()`: a deny with `"resolved": false` parks the
  mission exactly like M6 pause — state stays `gating`, substrate persisted,
  the start call returns the parked (non-terminal) reply with
  `"paused": true`. No FSM change: `mission resume` re-enters `gating`,
  re-asks the gate, and an interactive operator approves to `done`.
- A deny without the field (older approvers, tests) or with
  `"resolved": true` keeps today's behavior: `gate_denied → planning` with
  the reason as feedback, `gate_threshold` still bounding the loop.

Fail-closed is preserved: the external action (completing) never happens
without an affirmative human reply; the mission just stops burning budget
while it waits for one.

## Verified by

- approval worker: timeout-deny replies `resolved:false`; explicit
  resolve-deny replies `resolved:true` (named tests).
- mission driver: gate deny `resolved:false` ⇒ parked reply, state
  `gating` on disk, then resume + approve ⇒ `done` (named test); deny
  without the field still replans (regression test).
