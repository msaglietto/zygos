# Spec: `src/worker/turn.zig` — turn FSM + driver (T2, T4)

One **turn** = one agentic loop: assemble context → stream a model response →
dispatch tool calls → repeat until the model stops or a limit is hit. Split
hard into a **pure FSM** (table-driven, std-only, exhaustively testable) and a
**driver** (bus glue over an inproc worker).

## States & events (ARCHITECTURE.md M1 line, verbatim states)

```
provisioning → streaming → dispatching → awaiting_approval → steering → stopped|failed
```

```zig
pub const State = enum { provisioning, streaming, dispatching, awaiting_approval, steering, stopped, failed };
pub const Event = enum {
    provider_started,   // request sent, stream attached
    provider_end_turn,  // terminal message, stop_reason end_turn/max_tokens/stop_sequence
    provider_tool_use,  // terminal message with tool_use blocks
    provider_error,     // provider invocation failed
    tools_done,         // all tool_results collected (incl. is_error results)
    needs_approval,     // a dispatched tool requires approval (M2 gate)
    approved,           // approval granted (M1 driver auto-fires this)
    denied,             // approval denied → denial becomes an is_error tool_result
    steer,              // user injected mid-turn input
    steer_applied,      // steering merged into context
    abort,              // external cancel
    step_budget_exhausted, // max_steps reached at provisioning
    provider_retry,     // M2: provider failed, router has a next attempt
    budget_exhausted,   // M2: llm budget scope over limit at provisioning
};
```

## Transition table (everything not listed = `error.IllegalTransition`)

| From | Event | To |
|---|---|---|
| provisioning | provider_started | streaming |
| provisioning | provider_error | failed |
| provisioning | step_budget_exhausted | stopped |
| provisioning | budget_exhausted | stopped |
| provisioning | abort | stopped |
| streaming | provider_end_turn | stopped |
| streaming | provider_tool_use | dispatching |
| streaming | provider_error | failed |
| streaming | provider_retry | provisioning |
| streaming | steer | steering |
| streaming | abort | stopped |
| dispatching | needs_approval | awaiting_approval |
| dispatching | tools_done | provisioning |
| dispatching | steer | steering |
| dispatching | abort | stopped |
| awaiting_approval | approved | dispatching |
| awaiting_approval | denied | dispatching |
| awaiting_approval | abort | stopped |
| steering | steer_applied | provisioning |
| steering | abort | stopped |
| stopped / failed | *anything* | IllegalTransition (terminal) |

`Fsm.apply(state, event) error{IllegalTransition}!State` — pure function over
the table. The driver tracks `state`, `steps_used`, the message transcript,
and `stop` as a **string**, not an enum: live values include `"end_turn"`,
`"aborted"`, `"max_steps"`, `"budget_exhausted"`, `"failed"`,
`"route_exhausted"`, plus any provider stop_reason passed through.

## Driver (inproc worker `turn-orchestrator`)

Registers `zygos::turns::run`. Request:

```jsonc
{"model":"...", "system":"...", "messages":[{"role":"user","content":"..."}],
 "tools":[{"name":"bash","description":"...","input_schema":{...},
           "function_id":"zygos::tools::bash"}],   // name→bus mapping, explicit
 "max_steps":8, "provider_function":"zygos::provider::fake::messages"}
```

Loop per step (each arrow = an FSM event; state asserted after each):
1. **provisioning**: build provider request JSON from transcript + tools.
   Create a kernel channel (`actor.channelCreate`), keep the receiver,
   put the writer `StreamChannelRef` in the request → `provider_started`.
2. **streaming**: `worker.call(provider_function, request)` blocks while the
   provider streams deltas into the channel (driver drains the receiver on a
   helper thread into the turn's delta log). Result JSON = terminal message →
   `provider_end_turn` | `provider_tool_use` (or `provider_error`).
3. **dispatching**: for each tool_use block: resolve `function_id` from the
   request's tools table (unknown tool → is_error tool_result, not a turn
   failure). M1 auto-approval: fire `needs_approval` → `approved` for tools
   marked `"requires_approval": true` (exercises the path), else straight
   dispatch. `worker.call(tool_fn, input_json)` → tool_result (errors become
   `{"is_error":true,...}` results). All collected → `tools_done` → append
   assistant msg + tool_results user msg to transcript, next step.
3b. Every ok tool result passes through the **`zygos::output::compress`
   seam** (Z-09) before entering the transcript — fail-open, savings
   reported to budget when a scope rides the request.
4. **stopped**: reply to the original invocation with
   `{"stop":"end_turn|aborted|max_steps","steps":N,"transcript":[...],"deltas":"..."}`.
   **failed**: replies `.ok` with `{"stop":"failed","steps":N,"error":<code>}`
   — **not** an ErrorBody. (As built and header-flagged in `turn.zig`: a
   structured stop payload keeps mission-driver handling uniform; the
   originally specified `turn_failed` ErrorBody was never implemented.)

## M2 driver extensions (U1–U3, U5; specs: policy.md, approval.md, router.md, budget.md)

New optional request fields — every one absent ⇒ exact M1 behavior:

```jsonc
{"policy_function":"zygos::policy::check",       // U1 gate, consulted per dispatch
 "approval_function":"zygos::approvals::request",// U2, called on ask/requires_approval
 "router_function":"zygos::models::resolve",     // U3, replaces provider_function
 "step_id":"execute",                            // U3, routing key
 "budget_function":"zygos::budget::check",       // U5 (record goes to ::record)
 "budget_scope":"turn-1",                        // U5 counter scope
 "turn_id":"t-1"}                                 // U2 abort/steer handle
```

- **Policy (fail-closed).** With `policy_function` set, each tool_use block is
  checked before dispatch: `deny` ⇒ is_error tool_result `policy_denied:
  <reason>`, turn continues; `ask` ⇒ approval path; bus error / malformed
  verdict ⇒ treated as deny. Without it, only `requires_approval` gates.
- **Approval.** On `ask` (or `requires_approval:true`): `needs_approval` →
  awaiting_approval; with `approval_function` the driver blocks on the real
  bus call — `{"approved":true}` ⇒ `approved`, anything else (incl. bus
  error: fail closed) ⇒ `denied` ⇒ is_error tool_result `approval_denied`.
  Without `approval_function`, M1 auto-approve is preserved (tested legacy).
- **Routing.** With `router_function`, provisioning resolves
  `{step_id, attempt}` → `{provider_function, model}` (request-level
  `provider_function`/`model` become fallbacks). A provider bus error then
  fires `provider_retry` (→ provisioning) with `attempt+1` instead of
  `provider_error`; `route_exhausted` (or resolver error) at provisioning ⇒
  turn fails `route_exhausted`. Failed attempts do not count as steps.
- **Budget.** With `budget_function`+`budget_scope`: check at each
  provisioning — `ok:false` ⇒ `budget_exhausted` → stopped,
  `stop:"budget_exhausted"`; a bus error on check also stops (fail closed).
  After each provider result carrying `usage`, the driver records
  input/output tokens via `zygos::budget::record` — synchronously, so the
  next provisioning check observes this step's usage (fire-and-forget cast
  is for callers whose accounting is not also their control flow).
- **Abort/steer.** The orchestrator registers `zygos::turns::abort` and
  `zygos::turns::steer` (`{"turn_id":...}`, steer adds `"text"`). Turns with
  a `turn_id` are tracked; abort flips a flag the driver checks at
  provisioning and before each dispatch (→ `abort`, stop `"aborted"`).
  Steer text is drained after tool dispatch: `steer` → steering, the text
  joins the next user message, `steer_applied` → provisioning.

M2 test contract additions (RED first): 13 `policy deny yields is_error
tool_result and turn continues`, 14 `policy ask + approval worker approve
dispatches`, 15 `policy ask + approval deny yields approval_denied result`,
16 `policy function unreachable ⇒ deny (fail closed)`, 17 `malformed policy
verdict ⇒ deny`, 18 `router resolves provider per step`, 19 `provider failure
fails over to attempt 1 and succeeds`, 20 `routes exhausted ⇒ turn fails
route_exhausted`, 21 `budget exhausted stops the turn before the next step`,
22 `budget check unreachable ⇒ stops (fail closed)`, 23 `usage recorded to
the budget scope`, 24 `abort between steps stops with "aborted"`, 25 `steer
text lands in the next step's messages`.

## Test contract (RED first)

FSM (pure, exhaustive):
1. `every legal transition maps to the spec table` — table-driven positive
2. `every (state,event) pair not in the table is IllegalTransition` — full cross product
3. `terminal states reject all events`
4. `step budget: provisioning + step_budget_exhausted stops with max_steps`

Driver (fake provider + fake tool, both inproc):
5. `text-only turn: one step, stops end_turn, transcript has assistant text`
6. `tool-use turn: tool dispatched over the bus, tool_result in next request, ends end_turn on step 2` — the T4 core
7. `unknown tool name yields is_error tool_result and the turn continues`
8. `tool marked requires_approval routes through awaiting_approval (auto-approved) and still dispatches`
9. `provider error fails the turn` (asserts `stop=="failed"` + error code in
   the ok payload — see step 4 note above)
10. `max_steps exhausts cleanly`
11. `deltas streamed over the kernel channel are captured in order`
12. `no leaks under a multi-step turn` (testing.allocator)

## Post-M2 additions (present in code, TUI-era)

- **Delta observer seam**: `DeltaObserver` + `setDeltaObserver` — an in-proc
  callback receiving live assistant deltas alongside the channel drain (the
  TUI's live token feed). Fail-open.
- **Per-step `usage` trace event**: emitted through `worker/trace.zig` even
  when no budget scope rides the request (the TUI token counter's source).
- Default `max_steps` is **8** when the request omits it.

## Out of scope

- Context compaction, session persistence — M5.

Unsupported provider stop reasons fail the turn after usage accounting and before any tool dispatch; only end_turn, max_tokens, and stop_sequence are normal terminal reasons.
