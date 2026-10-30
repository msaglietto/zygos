# Spec: `src/worker/approval.zig` — approval/question worker (U2)

An inproc worker owning the human-in-the-loop seam. The turn driver blocks in
`awaiting_approval` on a real `zygos::approvals::request` bus call; a UI (or a
test thread) answers via `zygos::approvals::resolve`.

## Functions

- `zygos::approvals::request` — blocking. Request:

  ```json
  {"tool":"bash","input":{"command":"ls"},"reason":"policy ask: rule: bash",
   "step_id":"executor","trace_path":"/…/.planning/events.jsonl"}
  ```

  `tool`, `input` and `reason` as before; `step_id` (the pipeline step the
  turn runs, omitted or `""` when the turn has none) and `trace_path` (where
  the audit pair lands, see "Audit trail") are optional. The worker assigns
  an approval id, parks the invocation, and replies only when it is decided:

  ```json
  {"approved":false,"id":"a-1","outcome":"rejected","resolved":true}
  ```

  `outcome` is the decision. `approved` and `resolved` keep their meaning:
  `approved` is true only for `allowed_once`; `resolved` is true when a
  resolve call (or an auto mode) actually answered, false when nobody did —
  callers can tell "a human said no" from "nobody answered" (the mission
  gate parks on the latter).
- `zygos::approvals::resolve` — `{"id":"a-1","approved":true}` →
  `{"resolved":true}`; unknown id → `{"resolved":false}`. Unchanged.
- `zygos::approvals::pending` — `{}` →

  ```json
  {"pending":[{"id":"a-1","tool":"bash","step_id":"executor",
               "input":{"command":"ls"},"reason":"policy ask: rule: bash"}]}
  ```

  `input` is the request's `input` value, verbatim (`null` when the request
  had none). `step_id` is present only when the request carried a non-empty
  one. Display code caps the input; this reply does not.
- `zygos::approvals::cancel` — `{}` cancels every parked request,
  `{"id":"a-1"}` cancels that one. Reply `{"cancelled":<n>}` (the number of
  parked requests woken; unknown id or nothing parked → `0`). The mission
  CLI calls it after `missions::abort` on SIGINT, so a run cancelled while a
  tool ask is parked does not wait out the approval timeout.

## Outcomes (closed set)

| Trigger | `outcome` | `approved` | `resolved` |
| --- | --- | --- | --- |
| `resolve` with `approved:true` | `allowed_once` | true | true |
| `resolve` with `approved:false` (or no/non-bool `approved`) | `rejected` | false | true |
| `auto_approve` mode | `allowed_once` | true | true |
| `auto_deny` mode | `rejected` | false | true |
| manual `timeout_ms` expires | `unavailable` | false | false |
| `cancel` while parked | `cancelled` | false | false |
| worker `stop` while parked | `cancelled` | false | false |

A resolve that races the timeout loses: once the deadline passed the reply
is `unavailable` (fail closed — an unanswered question is a "no").

`allowed_once` approves this one call. Nothing is remembered: the next ask
for the same tool and input parks again.

## Turn-side contract (`turn.zig`)

- The request carries the tool's `input`, the turn's `step_id` when it has
  one, its `trace_path` when it has one, and a reason that names the gate:
  `policy ask: <policy reason>` (the policy worker's reason is
  `rule: <pattern>`, so `policy ask: rule: bash`), `policy ask` when the
  verdict carried no reason, and `tool requires approval` for a route's
  `requires_approval` flag with no `ask` verdict.
- The tool dispatches only when the reply's `outcome` is `allowed_once` and
  `approved` is true. A missing, non-string or unknown `outcome`, a
  contradiction (`allowed_once` with `approved:false`), an unparseable
  reply, a handler error and a bus failure all deny. A denied tool gets the
  unchanged `approval_denied` is_error tool_result, and the turn continues.
  An approver that predates `outcome` (`{"approved":true}` alone) is denied.
- No `approval_function` keeps the M1 auto-approve path (tested legacy).

## Audit trail

The worker, not the turn, emits the pair: only the worker knows the id
before it parks. Both lines go through `trace.emit` with the request's
`trace_path` (null when absent: no file line, in-process sinks still see
it), emitted from the handler thread, so `approval_asked` always precedes
its `approval_decided`.

```json
{"ts":…,"event":"approval_asked","id":"a-1","tool":"bash","step":"executor","input":"{\"command\":\"ls\"}"}
{"ts":…,"event":"approval_decided","id":"a-1","outcome":"rejected"}
```

- `step` is the step id string (null when the request had none), the same
  meaning as a `policy` rule's `step` — not the `tool_call` step counter.
- `input` is the input's JSON text clipped by `trace.clip`, the same path a
  `tool_call` input takes. AG-UI redacts it like `tool_call` input.
- Every reply the worker sends has its `approval_decided`, auto modes
  included. A request parked when the worker stops records `cancelled`.
- Policy `deny` verdicts are already in the trace as a
  `policy_denied: <reason>` is_error `tool_result`; there is no separate
  event for them.

## Modes

`ApprovalWorker.start(gpa, actor, registry, mode)`:

```zig
pub const Mode = union(enum) {
    manual: struct { timeout_ms: ?u64 = null }, // park until resolve; timeout ⇒ unavailable
    auto_approve,                                // reply allowed_once immediately
    auto_deny,                                   // reply rejected immediately
};
```

## Ids

Sequential (`a-1`, `a-2`, …) under the worker's mutex, auto modes included
(before 5.2.0 they replied `"auto"`) — deterministic for tests and
`pending` consumers, and unique within a worker's life so the audit pair
correlates.

## Display (console and TUI)

The mission CLI shows each pending ask as the tool, the step (when
present), the input and the reason. The input's JSON text is capped at
`approval_prompt.max_input_bytes` on a UTF-8 boundary with a
`…[<n> bytes total]` marker — never silently. Every displayed field passes
the TUI's terminal scrubber first: the input is model-controlled and must
not carry escape sequences to the operator's terminal.

## Test contract (RED first)

1. `auto_approve replies approved`
2. `auto_deny replies denied`
3. `manual: request parks until resolve(approved:true) → approved`
4. `manual: resolve(approved:false) → denied`
5. `manual: pending lists the parked request; empty after resolve`
6. `manual with timeout_ms: unresolved request denies after deadline`
7. `resolve with unknown id → resolved:false`
8. `no leaks under park/resolve loops`
9. `timeout deny replies resolved:false (unanswered, not refused)`
10. `explicit resolve deny replies resolved:true`
11. `auto modes reply resolved:true (a configured decision, not silence)`
12. `resolve(approved:true) replies outcome allowed_once`
13. `resolve(approved:false) replies outcome rejected`
14. `timeout replies outcome unavailable with resolved:false`
15. `cancel wakes a parked request as outcome cancelled; cancel with nothing parked reports 0`
16. `stop while parked replies outcome cancelled`
17. `auto modes reply allowed_once / rejected with sequential ids`
18. `pending carries the request's input (the command text) and step_id`
19. `pending omits step_id when the request has none and shows input null when absent`
20. `trace: approve, reject and timeout each write approval_asked then approval_decided with the same id and the matching outcome`
21. `trace: stop while parked records approval_decided cancelled`
22. `trace: approval_asked input is clipped like tool_call input`

Turn side (`turn.zig`):

23. `approval request carries input, step_id, trace_path and the policy reason`
24. `requires_approval without an ask verdict asks with reason "tool requires approval"`
25. `only outcome allowed_once dispatches (approved:true with outcome rejected does not)`
26. `missing, unknown, non-string or contradictory outcome denies`
27. `unparseable approval reply denies`

Trace, AG-UI and CLI (`trace_event.zig`, `trace.zig`, `agui.zig`, `src/cli`):

28. `approval_asked and approval_decided round-trip body() and parse()`
29. `render shows both approval lines`
30. `agui golden: zygos.approval_asked and zygos.approval_decided custom events`
31. `agui redacts a secret in approval_asked input`
32. `console prompt renders tool, step and input`
33. `console prompt caps a long input with a marker`
34. `console prompt strips escape sequences from the input`

e2e (`test/e2e/m45/run.sh`): a mission with `.policy` `{bash ask}` on the
scripted path, one ask approved and one rejected over piped stdin, shows
both trace pairs (`allowed_once`, `rejected`) and the matching tool
results (the command's output, then `approval_denied`).

Turn-side FSM integration (ask verdict → awaiting_approval → dispatch/deny)
is tested in `turn.zig`.
