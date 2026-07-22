# Spec: `src/worker/mission.zig` + `src/worker/mission_store.zig` — mission loop (M3, V1–V5)

One **mission** = one objective driven to completion by role turns over a
durable artifact substrate. Split hard, like the turn worker: a **pure FSM**
(table-driven, std-only, exhaustively testable), a **store** (durable
`.planning/` persistence, libc-backed), and a **driver** (bus glue over an
inproc worker that runs each role as a `zygos::turns::run` turn).

The GSD substrate is the context: role prompts are assembled from the
persisted artifacts, never from conversation memory. Every FSM transition is
persisted before the loop proceeds — a killed orchestrator resumes from disk.

## States & events (V1)

```
defining → planning → executing → verifying → gating → done|failed
```

```zig
pub const State = enum { defining, planning, executing, verifying, gating, done, failed };
pub const Event = enum {
    objective_ready,      // product-owner turn produced MISSION.md
    plan_ready,           // planner turn produced PLAN.md (fresh task list)
    task_done,            // executor finished a task, more remain
    tasks_done,           // executor finished the last task
    verify_passed,        // verifier verdict passed:true
    verify_failed,        // verdict passed:false, threshold not reached → replan
    escalate,             // verify failures hit the threshold (GOAL.md escalation)
    gate_approved,        // hard gate: human approval granted
    gate_denied,          // gate denied with feedback, threshold not reached → replan
    gate_failed,          // gate missing/unreachable/malformed, or denials exhausted
    role_failed,          // a role turn failed (turn error, bad stop, malformed output)
    role_turns_exhausted, // max_role_turns reached at a role boundary
    abort,                // zygos::missions::abort
};
```

## Transition table (everything not listed = `error.IllegalTransition`)

| From | Event | To |
|---|---|---|
| defining | objective_ready | planning |
| defining | role_failed | failed |
| defining | role_turns_exhausted | failed |
| defining | abort | failed |
| planning | plan_ready | executing |
| planning | role_failed | failed |
| planning | role_turns_exhausted | failed |
| planning | abort | failed |
| executing | task_done | executing |
| executing | tasks_done | verifying |
| executing | role_failed | failed |
| executing | role_turns_exhausted | failed |
| executing | abort | failed |
| verifying | verify_passed | gating |
| verifying | verify_failed | planning |
| verifying | escalate | failed |
| verifying | role_failed | failed |
| verifying | role_turns_exhausted | failed |
| verifying | abort | failed |
| gating | gate_approved | done |
| gating | gate_denied | planning |
| gating | gate_failed | failed |
| gating | abort | failed |
| done / failed | *anything* | IllegalTransition (terminal) |

`Fsm.apply(state, event) error{IllegalTransition}!State` — pure function over
the table, exactly like `turn.Fsm`.

A `Mission` struct tracks `mission_id`, `state`, `objective`, `acceptance`,
`tasks: []Task` (`desc`, `done`, `result` — a clipped outcome excerpt carried
into later executor turns), `task_index`, `fail_count` (consecutive
verify failures), `exec_fail_count` (consecutive executor `max_steps`
exhaustions — persisted, defaulting to 0 on legacy state files),
`gate_denials`, `role_turns_used`,
`stop: enum { none, completed, aborted, escalated, gate_failed, role_failed,
role_turns_exhausted }`, `detail` (human-readable stop/feedback text), and
`feedback` (the text fed to the next planner turn after a verify failure or
gate denial).

## Store (V2) — `src/worker/mission_store.zig`

libc-backed (std.Io stays out of worker modules per Z-02), no bus code.

- `Store.init(planning_root)` — absolute path; `save` creates it (mkdir -p).
- `save(gpa, store, mission)` — serialize the full `Mission` to JSON, write
  `<root>/mission.json.tmp`, then `rename(2)` onto `<root>/mission.json`.
  Rename is the atomicity boundary: a crash mid-write leaves the previous
  state file intact.
- `load(gpa, store)` — parse `<root>/mission.json` back into an owned
  `Mission`; missing file ⇒ `error.NotFound`; malformed ⇒ `error.Corrupt`.
  Save→load round-trips byte-equivalent semantics (every field).
- `writeArtifact(gpa, store, name, bytes)` / `readArtifact(gpa, store, name)`
  — same atomic write pattern; artifact names are bare filenames
  (`MISSION.md`, `PLAN.md`, `VERIFY.md`), no path separators accepted.

## Role turns (V3)

Each role runs as **one** `zygos::turns::run` invocation with a fixed
per-role `step_id`, so `zygos.zon` routing (`zygos::models::resolve`) can pin
each role to its own provider/model. The turn request passes through the
mission request's `provider_function`, `router_function`, `policy_function`,
`approval_function`, and `budget_scope` untouched; `max_steps` =
`role_max_steps` (default 8). Only the executor receives `tools`.

| Role | step_id | Input (user message, assembled from the substrate) | Output contract | Artifact |
|---|---|---|---|---|
| product-owner | `product-owner` | the request's seed `objective` | final assistant text = JSON `{"objective":"...","acceptance":"..."}` | `MISSION.md` |
| planner | `planner` | `MISSION.md` content + `feedback` when replanning | `{"tasks":["...", ...]}`, 1–32 non-empty strings | `PLAN.md` (rewritten per replan; task list and `task_index` reset) |
| executor | `executor` | objective + the current task description + a progress block of completed-task outcomes (`Task.result` excerpts, so later turns don't redo done work) | free text ending `end_turn`; a `max_steps` stop is **retried** with feedback (see below), not an instant failure | — |
| verifier | `verifier` | `MISSION.md` + `PLAN.md` contents | `{"passed":true|false,"reason":"..."}` | `VERIFY.md` |

Role output parsing is **fail-closed**: the final assistant text of a
structured role (product-owner, planner, verifier) must parse to the exact
shape above — anything else fires `role_failed` (stop `role_failed`, detail
says which role and why), and the rejected raw output is persisted to
`REJECTED-<role>.md` under the planning root for post-mortems. Whole-output
markdown fences (```json … ```) are **unwrapped** before parsing — models
that fence their JSON don't fail the mission. A structured role's turn that
ends with any stop other than `end_turn`, or errors on the bus, also fires
`role_failed`.

**Executor exception (post-M3, dogfood-driven):** an executor turn stopping
`max_steps` increments `exec_fail_count` and is **retried with feedback**
(the re-prompt tells it steps ran out and to work incrementally); it only
escalates to `role_failed` when `exec_fail_count` reaches `fail_threshold`.
The driver never retries the other roles — provider-level failover is the
router's job (U3).

Each role turn increments `role_turns_used`; at every role boundary the
driver first checks the abort flag (→ `abort`) and then
`role_turns_used >= max_role_turns` (→ `role_turns_exhausted`).

## Hard gate (V5)

At `gating` the driver calls the request's `gate_function` (normally
`zygos::approvals::request`) with
`{"turn_id":"<mission_id>","tool":"mission::complete","reason":"<objective>","summary":"<objective>"}`
(as built: `summary` carries the objective, not the verifier reason; a
`reason` field is included for the approval worker's prompt) and blocks on
the reply:

- `{"approved":true}` ⇒ `gate_approved` → done, stop `completed`.
- `{"approved":false, ...}` ⇒ denial: `gate_denials += 1`; if
  `gate_denials >= gate_threshold` ⇒ `gate_failed`, else `gate_denied` →
  planning with the denial reason as `feedback`.
- **No `gate_function` in the request, bus error, or malformed reply ⇒
  `gate_failed`** — a mission can never reach `done` without a real,
  reachable gate saying yes. Fail closed, no exceptions.

The gate call is not a role turn (does not count against `max_role_turns`).

## Driver (inproc worker `mission-orchestrator`, V4)

Registers `zygos::missions::{start,status,abort}`.

`zygos::missions::start` request:

```jsonc
{"mission_id":"m-1", "planning_root":"/abs/dir",   // both required
 "objective":"build X",                            // required unless resume
 "resume":false,                                   // load mission.json, continue
 "router_function":"zygos::models::resolve",       // or provider_function fallback
 "provider_function":"zygos::provider::fake::messages",
 "gate_function":"zygos::approvals::request",      // absent ⇒ done is unreachable
 "policy_function":"...", "approval_function":"...", "budget_scope":"...",  // passthrough
 "tools":[{"name":"bash","function_id":"zygos::tools::bash"}],              // executor only
 "max_role_turns":16, "fail_threshold":3, "gate_threshold":3, "role_max_steps":8}
```

Defaults: `max_role_turns` 16, `fail_threshold`/`gate_threshold` 3 (GOAL.md
`escalation.test_fail_threshold`), `role_max_steps` 8.

Loop: run the role (or gate) for the current state, fire the event, persist
the mission (`store.save`) after **every** transition, repeat until terminal.
Verify pass resets `fail_count`. The reply is
`{"state":"done|failed","stop":"...","detail":"...","role_turns":N,"tasks_done":K}`.
Start of a `mission_id` that is already running fails the handler
(generic bus error — the named `mission_already_running` ErrorBody was never
built; `mission.zig`'s header flags this).

- **Resume.** `resume:true` ignores the seed objective and loads
  `<planning_root>/mission.json`: missing ⇒ handler failure (generic — the
  named `mission_not_found` ErrorBody was never built);
  terminal state ⇒ reply immediately with the persisted terminal result (no
  role turns — idempotent); otherwise the loop continues from the persisted
  state and counters, so already-completed roles are never re-run.
- **Abort.** `zygos::missions::abort {"mission_id"}` flips a flag on the
  tracked mission; the driver observes it at the next role boundary, fires
  `abort`, persists (stop `aborted`), and replies to the original start.
  Unknown mission ⇒ `{"ok":false}`, else `{"ok":true}`.
- **Status.** `zygos::missions::status {"mission_id"}` reads the live
  tracked mission: `{"state":"...","stop":"...","role_turns":N,
  "task_index":K,"fail_count":F,"gate_denials":G}`. Unknown ⇒ handler
  failure (generic — no named ErrorBody, as above).

## Test contract (RED first)

FSM (pure, exhaustive):
1. `every legal transition maps to the spec table` — table-driven positive
2. `every (state,event) pair not in the table is IllegalTransition` — full cross product
3. `terminal states reject all events`

Store:
4. `save→load round-trips every Mission field`
5. `save is atomic: no .tmp residue, overwrite replaces cleanly`
6. `artifacts land under the planning root; root auto-created; separators rejected`
7. `load without a state file is NotFound; garbage is Corrupt`

Driver (scripted fake provider; a request-recording provider where prompts
must be asserted):
8. `happy path: define → plan(2 tasks) → execute×2 → verify pass → gate approve → done; artifacts + terminal state file on disk` — per-role step_ids proven via a router config that only routes the four role step_ids
9. `verify fail → replan with the verdict as feedback → pass → done; fail_count resets`
10. `fail_threshold consecutive verify failures → failed, stop escalated`
11. `gate denial → replan with denial feedback → approve on second gate → done`
12. `gate_threshold denials → failed, stop gate_failed`
13. `no gate_function ⇒ failed at gating, never done (fail closed)`
14. `unreachable gate function ⇒ failed, stop gate_failed`
15. `malformed planner output ⇒ failed, stop role_failed`
16. `provider error mid-role ⇒ failed, stop role_failed`
17. `abort mid-mission ⇒ failed, stop aborted, persisted as such`
18. `max_role_turns exhausted ⇒ failed, stop role_turns_exhausted`
19. `status reflects a live mission; unknown mission_id errors`
20. `resume mid-flight (state file seeded at executing, task 2 of 2) runs only executor→verifier→gate and finishes`
21. `resume of a terminal mission replies without running any role turn`
22. `no leaks across a full mission` (testing.allocator)

## Post-M3 additions (present in code)

- **Trace events**: the driver emits `task_start`/`task_done` per executor
  task and role/mission boundary events through `worker/trace.zig` (the
  TUI's task rail and `zygos mission trace` feed).
- **W1 brief lint**: `missions::start` lints the brief before the FSM runs
  (see brief.md) — fail closed.
- **W3 continuity seam**: `continuity_function`/`continuity_project` on the
  start request session-close over the bus at terminal states; a continuity
  failure never changes the mission outcome.
- **Fence unwrapping, rejected-role artifacts, executor retry, context
  carry** — see the Role turns section above.

## Out of scope (M3)

- Multi-mission concurrency beyond independent mission_ids; mission queues.
- Context compaction, session-store, transcript persistence between roles.
- New budget machinery (`budget_scope` rides through).
