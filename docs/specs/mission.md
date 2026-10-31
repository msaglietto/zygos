# Spec: `src/worker/mission.zig` + `src/worker/mission/pipeline.zig` + `src/worker/mission_store.zig` — mission loop (M3, V1–V5; issue #7)

> **Status: target contract for issue #7; the 2026-10-11 GOAL.md amendment
> was ratified by Mauricio on 2026-10-11.** The code on `master` still implements the
> fixed M3 chain (`defining → planning → executing → verifying → gating`).
> The implementation PR follows this spec test-first. Everything below
> describes the configurable pipeline.

One **mission** = one objective driven to completion by an ordered
**pipeline of steps** over a durable artifact substrate. Each step is an
agent with its own prompt, routed to its own model, and it reads what the
earlier steps wrote. The work splits hard, like the turn worker:

- a **pure FSM** (table-driven, std-only, exhaustively testable);
- a **pure pipeline module** (config validation, cursor movement,
  missing-phase fill, rework targets, artifact naming);
- a **store** (durable `.planning/` persistence, libc-backed);
- a **driver** (bus glue over an inproc worker that runs each step as a
  `zygos::turns::run` turn).

The GSD substrate is the context: step prompts are assembled from the
persisted artifacts, never from conversation memory. Every FSM transition is
persisted before the loop proceeds, so a killed orchestrator resumes from
disk.

## Pipeline config (`zygos.zon` `.steps`)

```zig
.steps = .{
    .{ .id = "architect", .definition = "agents/architect.md", .tools = true },
    .{ .id = "executor" },
    .{ .id = "verifier" },
},
```

- **Absent `.steps`** ⇒ the default pipeline: `product-owner`, `planner`,
  `executor`, `verifier`, with built-in definitions and tools on the
  executor only. A file with no `.steps` behaves exactly as today.
- **Entry keys:** `.id` (required), `.definition` (optional path), `.tools`
  (optional bool). `.steps` has its own strict parser, so an unknown key
  refuses boot. The router's lenient parse of the same file keeps ignoring
  `.steps`.
- **`.routes` stays model ladders only.** A step routes by its id
  (`zygos::models::resolve(id, attempt)`), falling back to `.default`. Every
  occurrence of an id shares that id's ladder; to give a repeat a different
  model, use a different id.
- **Order is free and ids may repeat.** Each entry is its own occurrence,
  with its own `.definition` and `.tools`.
- **Kinds.** The id decides the step kind: `product-owner`, `planner`,
  `executor` and `verifier` are the known kinds; any other id is `custom`.
- **`zygos task --config`** refuses a file carrying `.steps`
  (`UnsupportedSetting`, as for every non-routing setting).

### Boot refusals (fail closed, before any turn runs)

The mission CLI validates the list and refuses to start, with a reason
naming the entry, when:

| Condition | Reason |
|---|---|
| `.steps` present but empty | `steps: empty` |
| entry without `.id`, or with an unknown key | `steps[i]: unknown key "<k>"` / `missing id` |
| id not matching `[a-z0-9-]{1,32}` | `steps[i]: bad id` |
| id is reserved (`task`, `tessera-capture`) | `steps[i]: reserved id` |
| no `executor` occurrence | `steps: no executor` |
| `.tools = true` on a `verifier` | `steps[i]: verifier cannot have tools` |
| custom id without `.definition` | `steps[i]: no definition` |
| `.definition` absolute, containing a `..` component, or resolving (after `realpath`) outside the `.zon` file's directory | `steps[i]: definition path` |
| `.definition` file missing, empty after trim, or over 64 KiB | `steps[i]: definition unreadable` |

### Definitions (agent prompts)

- **Built-ins** live as `src/worker/mission/agents/<id>.md` for the four
  known ids, embedded with `@embedFile` (which cannot reach outside the
  module root). An arm that wants to rewrite a built-in copies the file
  next to its `zygos.zon` and names it in `.definition`.
- **A `.definition` path** resolves relative to the `.zon` file's directory.
  The CLI reads it **once at boot** and pins its bytes and sha256. The
  worker never reads definition files; the resolved text rides the start
  request.
- **Precedence** for a step's system prompt:
  1. the pinned `.definition`;
  2. else a non-empty `role-<id>.md` artifact in the planning root (the M7
     playbook override);
  3. else the built-in.
- **Reply contract.** For `product-owner`, `planner` and `verifier`, the
  driver appends that kind's reply format (for example the
  `{"tasks":[...]}` instruction) after whichever prompt won. A definition
  holds behaviour only. The built-in file plus the appended contract
  reproduces today's `playbook.defaultSystem` text byte-for-byte, so the
  default pipeline's prompts do not change. `executor` and custom kinds get
  no appended contract.

## States & events (V1)

```
running → gating → done|failed
```

`running` carries a cursor: `step_index` into the pinned pipeline, and
`step`, that entry's id.

```zig
pub const State = enum { running, gating, done, failed };
pub const Event = enum {
    task_done,            // an executor task finished; more remain on this step
    step_done,            // the step at the cursor finished; cursor advances, steps remain
    steps_done,           // the cursor passed the last step
    verify_failed,        // a verifier said passed:false, threshold not reached → rework
    escalate,             // verify failures or executor exhaustions hit the threshold
    gate_approved,        // hard gate: human approval granted
    gate_denied,          // gate denied with feedback, threshold not reached → rework
    gate_failed,          // gate missing/unreachable/malformed, or denials exhausted
    role_failed,          // a step turn failed (turn error, bad stop, malformed or empty output)
    role_turns_exhausted, // max_role_turns reached at a step boundary
    abort,                // zygos::missions::abort
};
```

### Transition table (everything not listed = `error.IllegalTransition`)

| From | Event | To |
|---|---|---|
| running | task_done | running |
| running | step_done | running |
| running | steps_done | gating |
| running | verify_failed | running |
| running | escalate | failed |
| running | role_failed | failed |
| running | role_turns_exhausted | failed |
| running | abort | failed |
| gating | gate_approved | done |
| gating | gate_denied | running |
| gating | gate_failed | failed |
| gating | abort | failed |
| done / failed | *anything* | IllegalTransition (terminal) |

`Fsm.apply(state, event) error{IllegalTransition}!State` stays a pure
function over the table. Where the cursor moves is not the FSM's job: the
pipeline module computes the new cursor for `step_done`, `verify_failed`
and `gate_denied`, and the driver persists both together.

A pause (M6) or an unanswered gate still parks the mission with no
transition, as today.

## Pipeline module (`src/worker/mission/pipeline.zig`)

Pure, std-only, no bus and no I/O. It owns every rule that depends on the
step list, so `mission.zig` does not grow `if step == ...` branches.

- **`Pipeline`**: `[]Step`, where `Step` is `{ id, kind, system, definition_sha256: ?[]const u8, tools: bool }`.
  `tools` defaults to `true` for `executor` and `false` for every other kind.
  `definition_sha256` is null for a built-in.
- **`validate(entries) → Pipeline | Refusal`**: the boot-refusal table above,
  except the file checks, which the CLI performs before calling it.
- **MISSION seed.** At mission start, if `steps[0]` is not `product-owner`,
  the driver writes `MISSION.md` with the request's objective and the
  acceptance line "per the operator brief". This costs no turn. A later
  `product-owner` occurrence rewrites it.
- **Executor rule.** When the cursor reaches an `executor` occurrence:
  1. **No tasks yet**: seed `PLAN.md` with one task equal to the objective
     (no turn), then go on to step 2. This covers both a pipeline with no
     planner and a planner placed after the first executor.
  2. **Unfinished tasks**: run them in order, one turn each (`task_done`),
     then `step_done`.
  3. **All tasks done**: append one **fix task** and run it. Its input is
     every artifact written since the previous executor run; if nothing
     was written since, its input is every artifact written so far. So
     `executor → reviewer → executor` is a review-and-fix loop.
- **Planner repeat.** A `planner` occurrence's tasks replace the unfinished
  tasks. Done tasks stay done, and `task_index` moves to the first new task.
- **Rework target.**
  - **`verify_failed`**: the cursor returns to the last `executor`
    occurrence before the failing verifier. If there is none, it returns to
    the first `executor` in the list.
  - **`gate_denied`**: the cursor returns to the last `executor` in the
    list.

  In both cases a fix task whose description carries the feedback is
  appended. Earlier tasks stay done, and every step after the target runs
  again.
- **Advance.** After `step_done` the cursor moves to `step_index + 1`; past
  the end, the driver fires `steps_done`. Steps after a verifier run on a
  pass, before the gate.
- **Run counters.** `step_runs[id]` counts the runs of each id (rework
  re-runs included) and names the artifacts below.

## Steps (V3)

Each step run is **one** `zygos::turns::run` invocation with
`step_id = <id>`. The executor is the exception: one turn per task. The turn
request passes through the mission request's `provider_function`,
`router_function`, `policy_function`, `approval_function` and
`budget_scope` untouched; `max_steps` = `role_max_steps` (default 8). A step
gets the mission's `tools` only when its pinned `tools` is true.

| Kind | Input (user message, assembled from the substrate) | Output contract | Artifact |
|---|---|---|---|
| product-owner | the seed `objective` | JSON `{"objective":"...","acceptance":"..."}` | `MISSION.md` (the previous version is kept as `MISSION-<n>.md`) |
| planner | `MISSION.md` | `{"tasks":["...", ...]}`, 1–32 non-empty strings | `PLAN.md` (the previous version is kept as `PLAN-<n>.md`) |
| executor | objective + current task + a progress block of completed-task outcomes; a fix task also carries its feedback or source artifacts | free text ending `end_turn`; a `max_steps` stop is **retried** with feedback | one section appended to `EXEC.md` per completed task |
| verifier | `MISSION.md` + `PLAN.md` + `EXEC.md` | `{"passed":true|false,"reason":"..."}` | `VERIFY.md` |
| custom | the brief, then every artifact written so far in step order | non-empty free text ending `end_turn` | `step-<id>-<n>.md`, where `n` = `step_runs[id]` |

**Every known kind also receives each `step-*.md` written so far**,
appended after its listed input, so a custom step's output reaches every
later step. Inputs are clipped to the context strategy's `max_tokens`
budget: older artifacts are clipped first, while `MISSION.md` and the
current task are never dropped. This one assembly rule is shared by the
`substrate`, `recall` and `thread` strategies; it is not re-implemented per
strategy.

Output parsing is **fail-closed**:

- **Structured kinds** (product-owner, planner, verifier): the final
  assistant text must parse to the exact shape above. Anything else fires
  `role_failed` and saves the raw output to `REJECTED-<id>.md`. A fence
  wrapping the whole output (```json … ```) is unwrapped first.
- **Custom kinds:** an empty reply fires `role_failed`.
- **Every kind:** a stop other than `end_turn`, or a bus error, fires
  `role_failed`. The one exception is the executor's `max_steps` stop.

**Executor retry (post-M3):** an executor turn that stops at `max_steps`
increments `exec_fail_count` and is retried with feedback. It escalates
(`escalate`) only when `exec_fail_count` reaches `fail_threshold`. The
driver never retries the other kinds; provider failover is the router's job
(U3).

Each step turn increments `role_turns_used`, a single total per mission. At
every step boundary the driver checks the abort flag first (→ `abort`), then
`role_turns_used >= max_role_turns` (→ `role_turns_exhausted`). A longer
pipeline reaches the cap sooner, and the campaign spec records that as a
caveat.

### Tools and policy

- A step receives tools only when its pinned `tools` is true. The
  defaults are executor-only. `.tools = true` is allowed on
  `product-owner`, `planner` and custom steps, and refused on `verifier`.
- Every policy request carries the calling turn's `step_id`:
  `{"tool":"bash","function_id":"zygos::tools::bash","step_id":"architect","input":{...}}`.
  `policy.Rule` gains an optional `step` pattern; a rule without one
  matches every step.
- **Operator config.** The mission CLI reads the rule list from
  `zygos.zon` `.policy` and hands it to the policy worker; a present, valid
  list replaces the hard-coded allow seed (`mission_boot.policySeed`),
  which governs only when `.policy` is absent. The start request carries
  the effective list as `policy`, so the trace records it. See
  `docs/specs/policy-config.md`.

## Store (V2) — `src/worker/mission_store.zig`

libc-backed (std.Io stays out of worker modules per Z-02), no bus code.

- `Store.init(planning_root)` takes an absolute path; `save` creates it
  (mkdir -p).
- `save(gpa, store, mission)` serializes the full `Mission` to JSON, writes
  `<root>/mission.json.tmp`, then calls `rename(2)` onto
  `<root>/mission.json`. The rename is the atomicity boundary.
- `load(gpa, store)`: a missing file is `error.NotFound`, a malformed one
  `error.Corrupt`. Save→load round-trips every field.
- `writeArtifact` / `readArtifact` use the same atomic pattern. Artifact
  names are bare filenames with no path separators: `MISSION.md`,
  `MISSION-<n>.md`, `PLAN.md`, `PLAN-<n>.md`, `EXEC.md`, `VERIFY.md`,
  `step-<id>-<n>.md`, `REJECTED-<id>.md`. Lowercase ids cannot collide with
  the uppercase names.

`Mission` gains these persisted fields:

- `pipeline`: the pinned list `[{"id","definition_sha256","tools"}]`;
- `step_index`;
- `step_runs`, an id → count map;
- `mission_versions` and `plan_versions`, the counters behind
  `MISSION-<n>`/`PLAN-<n>`.

It keeps `objective`, `acceptance`, `tasks` (`desc`, `done`, and the
in-memory `result`), `task_index`, `fail_count`, `exec_fail_count`,
`gate_denials`, `role_turns_used`, `stop`, `detail` and `feedback`.

**Legacy state files** (no `pipeline`) load as the default pipeline, with
the old state mapped onto the cursor:

| Old state | New state and cursor |
|---|---|
| `defining` | `running`, step 0 |
| `planning` | `running`, step 1 |
| `executing` | `running`, step 2 |
| `verifying` | `running`, step 3 |
| `gating`, `done`, `failed` | unchanged |

The new counters default to 0, as `exec_fail_count` does.

## Hard gate (V5)

**Every pipeline ends at the gate**, with or without a verifier. At
`gating` the driver calls the request's `gate_function` (normally
`zygos::approvals::request`) with
`{"turn_id":"<mission_id>","tool":"mission::complete","reason":"<objective>","summary":"<objective>"}`
and blocks on the reply:

- `{"approved":true}` ⇒ `gate_approved` → done, stop `completed`. A reply
  with no `outcome` field is accepted as-is. If `outcome` is present it must
  be the string `allowed_once`: `{"approved":true,"outcome":"rejected"}`
  (any other string) and `{"approved":true,"outcome":42}` (a non-string)
  contradict themselves and count as a malformed reply (below). Completion
  needs an affirmative gate, never a contradictory one.
- `{"approved":false,"resolved":false, ...}` ⇒ **unanswered** (approval
  timeout or EOF, not a human refusal). The mission parks at `gating` with
  no transition and a non-terminal `"paused":true` reply. `resume` asks the
  gate again. Campaign runs always end here.
- `{"approved":false, ...}` (no `resolved` field, or `resolved:true`) ⇒
  denial: `gate_denials += 1`. If `gate_denials >= gate_threshold` it fires
  `gate_failed`; otherwise `gate_denied` → running, at the rework target
  with the denial reason as a fix task.
- **No `gate_function` in the request, a bus error, or a malformed reply
  (unparseable, not an object, `approved` missing or not a boolean, or
  `approved:true` with an `outcome` other than `allowed_once`) ⇒
  `gate_failed`** with detail `malformed gate reply`. A mission can never reach `done` without a real,
  reachable gate saying yes.

Since 5.2.0 the approval worker's reply also carries `outcome`
(`docs/specs/approval.md`). The gate reads `approved` and `resolved`, and
`outcome` only to reject a contradiction on an approval: `allowed_once`
arrives as `approved:true`, `rejected` as a denial,
and `unavailable` and `cancelled` as `resolved:false` (park). The gate
request carries no `trace_path`, so gate asks are not in the trace's
approval pair; the `mission` events record the gate.

The gate call is not a step turn and does not count against
`max_role_turns`.

## Driver (inproc worker `mission-orchestrator`, V4)

Registers `zygos::missions::{start,status,abort}`.

`zygos::missions::start` request (new: `steps`):

```jsonc
{"mission_id":"m-1", "planning_root":"/abs/dir",   // both required
 "objective":"build X",                            // required unless resume
 "resume":false,
 "steps":[                                         // absent ⇒ default pipeline
   {"id":"architect","system":"<pinned definition text>",
    "definition_sha256":"<hex>","tools":true},
   {"id":"executor"}, {"id":"verifier"}],
 "policy":{"source":"config",                      // optional; absent ⇒ no policy event
   "rules":[{"tool":"bash","verdict":"deny","step":"architect"},
            {"tool":"bash","verdict":"allow","step":null}]},
 "router_function":"zygos::models::resolve",
 "provider_function":"zygos::provider::fake::messages",
 "gate_function":"zygos::approvals::request",      // absent ⇒ done is unreachable
 "policy_function":"...", "approval_function":"...", "budget_scope":"...",
 "tools":[{"name":"bash","function_id":"zygos::tools::bash"}],  // offered to steps with tools:true
 "max_role_turns":16, "fail_threshold":3, "gate_threshold":3, "role_max_steps":8}
```

The worker re-validates `steps` with `pipeline.validate` (except the file
checks, which belong to the CLI) and refuses the start on any violation.
`policy` is optional and informational: the driver does not interpret it,
and a structurally malformed one refuses the start with reason
`invalid_policy` (like `invalid_steps`).

**Loop.** Run the step at the cursor, or the gate. Fire the event, apply
the pipeline's cursor update, and persist the mission (`store.save`) after
**every** transition. Repeat until terminal.

- A verifier pass resets `fail_count`.
- `verify_failed` increments it. Once it reaches `fail_threshold`, the
  driver fires `escalate`; the count spans all verifier occurrences.

The terminal reply is
`{"state":"done|failed","step":"<id>"|null,"step_index":N,"stop":"...","detail":"...","role_turns":N,"tasks_done":K}`.

**Mission-start trace.** The driver first emits a `pipeline` trace event
with `[{"id","definition_sha256","tools"}]`; then, only when the request
carries `policy`, a `policy` event with `{"source","rules"}`; then the usual
mission state events with the new state names plus `step` and `step_index`.
Both events are written on every run of the loop (fresh start and
non-terminal resume).

- **Resume.** `resume:true` loads `<planning_root>/mission.json` and
  compares its pinned `pipeline` (ids, definition hashes, tools) with the
  request's `steps`. On a mismatch it refuses: `pipeline changed since
  start`, fail closed. A legacy file counts as the default pipeline. A
  terminal state replies immediately with the persisted result.
  Otherwise the loop continues from the persisted cursor and counters, so
  already-completed steps are not re-run.
- **Abort.** `zygos::missions::abort {"mission_id"}` works as today: the
  driver observes the flag at the next step boundary, fires `abort` and
  persists stop `aborted`.
- **Status.** `zygos::missions::status {"mission_id"}` returns:
  ```jsonc
  {"state":"running|gating|done|failed","step":"executor","step_index":2,
   "stop":"...","role_turns":N,"task_index":K,"fail_count":F,"gate_denials":G}
  ```
  `step` is null and `step_index` is the list length at `gating` and
  `done`. A failed mission keeps the step that failed.

## Consumers (updated in the implementation PR)

The state names change, so these are updated in the same change, with a
**major** version bump:

- **Readers of mission state:**
  - the TUI (`src/tui/model.zig`, `band.zig`, `loop.zig`);
  - `src/cli/mission/view.zig`;
  - the AG-UI projector and viewer (`src/worker/agui.zig`,
    `agui_viewer.html`);
  - the trace (`src/worker/trace.zig`, `trace_event.zig`);
  - the eval tests that assert `"gating"`.
- **Other specs:** `docs/specs/trace.md` gets the `pipeline` event and the
  new state names. `docs/specs/policy.md` gets `step_id` and `Rule.step`.
- **Campaign:**
  - `docs/specs/campaign.md` and `eval/campaign.py`: definition hashes
    count toward an arm's identity, inspection checks the `pipeline` event
    against the arm, the mission-states metric uses the new states, and
    the issue-#7 known-limit paragraph is replaced by the step-count
    budget caveat.
  - The Harbor adapter uploads definition files next to `zygos.zon` and
    records the pipeline in `mission-run.json`.

## Test contract (RED first)

FSM (pure, exhaustive):

1. `every legal transition maps to the spec table`
2. `every (state,event) pair not in the table is IllegalTransition`, over the full cross product
3. `terminal states reject all events`

Pipeline (pure):

4. `absent steps is the default four with executor-only tools`
5. One named test per boot-refusal row: empty list, unknown key, missing id, bad id, reserved id, no executor, verifier with tools, custom without definition, definition path (absolute, `..`)
6. `duplicate ids are accepted and each occurrence keeps its own definition and tools`
7. `MISSION seed iff step 0 is not product-owner`
8. `executor rule: no tasks seeds one objective task; unfinished tasks run; all done appends one fix task from artifacts since the previous executor, else everything`
9. `planner repeat replaces only unfinished tasks`
10. `rework target: last executor before the failing verifier, else the first executor; gate denial targets the last executor`
11. `run counters name step-<id>-<n> and MISSION-<n>/PLAN-<n> without overwriting`
12. `prompt precedence: pinned definition > role-<id>.md > built-in; the contract is appended for structured kinds`
13. `built-in file + appended contract equals the legacy defaultSystem text byte-for-byte`

Store:

14. `save→load round-trips every Mission field including pipeline, step_index, step_runs and version counters`
15. `save is atomic: no .tmp residue, overwrite replaces cleanly`
16. `artifacts land under the planning root; new artifact names accepted; separators rejected`
17. `load without a state file is NotFound; garbage is Corrupt`
18. `a legacy mission.json loads as the default pipeline with its state mapped onto the cursor`

Driver (scripted fake provider, or a request-recording provider where prompts must be asserted):

19. `default pipeline: same turn order and step_ids as M3; states read running → gating → done`
20. `executor → verifier: MISSION and PLAN seeded, no product-owner or planner turn`
21. `architect → executor → verifier: the architect's text lands in step-architect-1.md and in the executor and verifier prompts`
22. `a pipeline with no verifier goes from its last step to the gate`
23. `verify fail ⇒ fix task on the last executor before the verifier; later steps re-run; fail_count resets on pass`
24. `gate denial ⇒ fix task on the last executor in the list`
25. `executor → reviewer → executor: the second executor runs one fix task built from the reviewer output`
26. `fail_threshold verify failures across two verifier occurrences ⇒ failed, stop escalated`
27. `a custom step's empty reply ⇒ role_failed; a custom step's max_steps stop ⇒ role_failed`
28. `only steps with tools:true receive tools; the verifier never does`
29. `the policy request carries step_id`, a turn-level test in `turn.zig`
30. `resume with a changed pipeline refuses; a legacy state file resumes under the default pipeline`
31. `status reports state, step and step_index`
32. The M3 driver tests carried over: no gate function ⇒ failed, never done; unreachable gate ⇒ gate_failed; gate_threshold denials ⇒ gate_failed; malformed planner output ⇒ role_failed; provider error mid-step ⇒ role_failed; abort ⇒ aborted; max_role_turns ⇒ role_turns_exhausted; unknown mission_id errors; terminal resume runs no turn; no leaks across a full mission (testing.allocator)

## Post-M3 additions (present in code, carried forward)

- **Trace events:** the driver emits `task_start`/`task_done` for each
  executor task, plus step and mission boundary events, through
  `worker/trace.zig`.
- **W1 brief lint:** `missions::start` lints the brief before the FSM runs
  (see brief.md), and fails closed.
- **W3 continuity seam:** at terminal states, the start request's
  `continuity_function`/`continuity_project` run session-close over the
  bus. A continuity failure never changes the mission outcome.
- **Unchanged behaviour:** fence unwrapping, rejected-output artifacts,
  executor retry and context carry are kept as described above.

## Out of scope

- Argument-aware policy rules and forwarding the step to the approval
  prompt (`docs/specs/policy-config.md`, "Out of scope").
- Per-occurrence model routes (routing stays one ladder per id).
- Per-step turn budgets (`max_role_turns` stays one total per mission).
- Multi-mission concurrency beyond independent mission_ids; mission queues.
- Context compaction, session-store, transcript persistence between steps.
