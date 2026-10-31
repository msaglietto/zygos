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
  `{"resolved":true}`; unknown id → `{"resolved":false}`. The first decision
  wins: a resolve for a request already resolved or cancelled (but not yet
  woken) also replies `{"resolved":false}` and changes nothing, and a
  `cancel` for a request already resolved wakes nothing (`{"cancelled":0}`).
  The one exception is worker `stop`: it cancels every parked request,
  including one that was resolved but has not woken yet, so such a request
  replies `cancelled`. Stopping is the fail-closed direction, and the code
  keeps it that way.
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
  included. A request parked when the worker stops, or cancelled by
  `zygos::approvals::cancel`, records `cancelled`.
- The trace stays advisory, like every other event (README: "If the file
  cannot be written, the mission still runs"). `trace.emit` swallows an
  unwritable file, so the lines are lost and the decision is unchanged: the
  reply, `approved` and `outcome` do not depend on the trace being written.
  The `input` is clipped (and the clip allocated) before the request is
  parked, so an out-of-memory error there cannot leave an entry in
  `pending`.
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

The console prints the summary on one line. The TUI band cannot: it clips
every row at the terminal width, which would hide the end of a long command,
the cap marker and the reason while the operator can still press `y`. So the
band renders the `  [y/N] approve?` keys first (red, bold), then the whole
summary, word-wrapped on display width (`tui/width.zig` `wrapToWidth`: wide
runes count 2, no UTF-8 sequence is split, a token wider than a row is
hard-split) over as many rows as it needs, continuation rows indented four
cells and dim. A summary that fits shares the keys' row. In a terminal too
narrow for an inline summary (under 25 cells) the keys take a row of their
own. A newline in the summary (the scrubber keeps `\n`) starts a new row. The
summary is bounded (400 input bytes plus marker and reason), so the rows are
too; nothing in `frame.zig` drops bottom rows.

## Test contract (RED first)

Worker (`approval.zig`):

1. `auto_approve replies approved`
2. `auto_deny replies denied`
3. `manual: request parks until resolve approves it`
4. `manual: resolve(approved:false) denies`
5. `manual: pending is empty after resolution`
6. `manual with timeout_ms denies unresolved requests`
7. `resolve with unknown id reports resolved:false`
8. `no leaks under park/resolve loops`
9. `timeout deny replies resolved:false (unanswered, not refused)`
10. `explicit resolve deny replies resolved:true (a human said no)`
11. `auto modes reply resolved:true (a configured decision, not silence)`
12. `resolve(approved:true) replies outcome allowed_once`
13. `resolve(approved:false) replies outcome rejected`
14. `timeout replies outcome unavailable with resolved:false`
15. `cancel wakes a parked request as outcome cancelled; cancel with nothing parked reports 0`
16. `cancel by id wakes only that request`
17. `stop while parked replies outcome cancelled`
18. `auto modes reply allowed_once / rejected with sequential ids`
19. `pending carries the request's input (the command text) and step_id`
20. `pending omits step_id when the request has none and shows input null when absent`
21. `trace: approve, reject and timeout each write approval_asked then approval_decided with the same id and the matching outcome`
22. `trace: stop while parked records approval_decided cancelled`
23. `trace: approval_asked input is clipped like tool_call input`
24. `request: an allocation failure never leaves a parked entry behind` (drives the handler with a failing allocator at every allocation point)
25. `resolve: the first decision wins and a later resolve or cancel cannot flip it` (handlers driven directly on a hand-parked entry: the window between the decision and the wake)
26. `resolve after cancel replies resolved:false and cannot revive the request`
27. `trace: cancel while parked records approval_decided cancelled`
28. `a request that arrives while the worker is stopping replies cancelled and parks nothing`

Turn side (`turn.zig`):

29. `approval request carries input, step_id, trace_path and the policy reason`
30. `requires_approval without an ask verdict asks with reason "tool requires approval"`
31. `only outcome allowed_once dispatches (approved:true with outcome rejected does not)`
32. `missing, unknown, non-string or contradictory outcome denies`
33. `unparseable approval reply denies` (wrong-shape replies `[]`, `"x"`, `null`, `42`, `true` and a handler error: the bus rejects a non-JSON result frame before the turn sees it)
34. `an unregistered approval function denies (function_not_found on the bus)`

Mission gate (`mission.zig`):

35. `gate: approved:true contradicted by a non-allowed_once outcome is a malformed reply`
36. `gate: approved:true with a non-string outcome is a malformed reply`
37. `gate: approved:true with outcome allowed_once completes; a reply with no outcome still does`

Trace, AG-UI and CLI (`trace_event.zig`, `trace.zig`, `agui.zig`, `src/cli`):

38. `approval events round-trip through trace_event` (and `parse: malformed approval events read tolerant defaults`)
39. `render shows both approval lines`
40. `agui projects approval events as zygos.approval custom events` (golden)
41. `agui redacts a secret in approval_asked input`
42. `console prompt renders tool, step and input`
43. `console prompt caps a long input with a marker`
44. `console prompt strips escape sequences from the input`

TUI band (`tui/band.zig`):

45. `approval ask wraps across rows at 80 columns: tail, marker and reason stay visible`
46. `approval ask wraps across rows at a narrow width`
47. `approval ask keeps the keys visible when the terminal is tiny`
48. `approval ask hard-splits an unbroken token and never splits a UTF-8 sequence`
49. `a short approval ask stays on one row after the keys`
50. `an approval ask cannot restyle the band or break rows with escapes and newlines`

e2e (`test/e2e/m45/run.sh`): a mission with `.policy` `{bash ask}` on the
scripted path, one ask approved and one rejected over piped stdin, shows
both trace pairs (`allowed_once`, `rejected`) and the matching tool
results (the command's output, then `approval_denied`).

Turn-side FSM integration (ask verdict → awaiting_approval → dispatch/deny)
is tested in `turn.zig`.
