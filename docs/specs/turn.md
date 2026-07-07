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
};
```

## Transition table (everything not listed = `error.IllegalTransition`)

| From | Event | To |
|---|---|---|
| provisioning | provider_started | streaming |
| provisioning | step_budget_exhausted | stopped |
| provisioning | abort | stopped |
| streaming | provider_end_turn | stopped |
| streaming | provider_tool_use | dispatching |
| streaming | provider_error | failed |
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
the table. A `Turn` struct tracks `state`, `steps_used`, `stop: enum { none,
end_turn, aborted, max_steps }`, and the message transcript.

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
4. **stopped**: reply to the original invocation with
   `{"stop":"end_turn|aborted|max_steps","steps":N,"transcript":[...],"deltas":"..."}`.
   **failed**: ErrorBody `turn_failed` with the provider error.

Steering & abort land as bus functions (`zygos::turns::steer/abort`) in M2 —
the FSM transitions are fully tested in M1; the driver doesn't expose them yet.

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
9. `provider error fails the turn with turn_failed`
10. `max_steps exhausts cleanly`
11. `deltas streamed over the kernel channel are captured in order`
12. `no leaks under a multi-step turn` (testing.allocator)

## Out of scope

- Real approval worker, steering surface, budgets, model routing — M2.
- Context compaction, session persistence — M2/M3.
