# Spec: `src/kernel/trigger.zig` — trigger registry (S4)

Implements GOAL.md criterion **S4** and PROTOCOL.md semantics **4 (type
replay)**, **5 (trigger ownership)**, **6 (registration acks)**.
Kernel-actor-owned, single-threaded, no locks. No clock reads —
time-dependent functions take `now_ms` (same rules as invocation spec).

## How triggers work (context)

A **trigger type** (cron, http, state, …) is owned by the worker that
registered it — that worker does the actual wiring (schedules the cron, binds
the route) and fires `invokefunction` when events occur. The kernel's job is
bookkeeping: route each **binding** (a trigger: `{id, type, function_id,
config}`) to the type's owner worker, track ownership, replay bindings when a
type's owner reconnects, and manage registration acks.

This module **returns effects; it never sends frames**. The actor executes
the effects (forward a binding to worker X, complete/fail an ack, …).

## Data model

```zig
pub const TriggerType = struct {
    owner: WorkerId,                 // the registrator worker
    description: []const u8,         // owned
    trigger_request_format: ?[]const u8,  // raw JSON, owned
    call_request_format: ?[]const u8,     // raw JSON, owned
};

pub const Binding = struct {
    trigger_type: []const u8,        // owned
    function_id: []const u8,         // owned
    config: []const u8,              // raw JSON, owned
    owner: ?WorkerId,                // null = durable (survives disconnects)
    metadata: ?[]const u8,           // raw JSON, owned
};
```

Two maps: `types: StringHashMap(TriggerType)`, `bindings:
StringHashMap(Binding)` (keyed by trigger id). Plus a pending-ack map for
rule 6: `acks: StringHashMap(PendingAck)` with a deadline heap, lazy
deletion — identical pattern to the invocation spec, 10_000 ms default
deadline computed by the caller.

## Semantics

1. **Type registration is last-wins and returns the replay set.**
   Re-registering an existing type id replaces the owner/formats and returns
   the list of existing binding ids of that type — the actor forwards each to
   the new owner (PROTOCOL.md §4, provider-reconnect support).
2. **Binding registration** with a known type → effect `forward(type_owner,
   binding_id)`. Unknown type → `error.UnknownTriggerType` (the actor decides
   how to report; a built-in-name hint is actor policy, not this module's).
3. **Acks:** a binding with `owner == null` (function-path, durable) parks a
   `PendingAck`; the actor completes it when `triggerregistrationresult`
   arrives, or `sweepExpiredAcks(now_ms)` fails it at deadline → effect: drop
   the binding + report error. Connection-owned bindings (`owner != null`)
   are fire-and-forget: no ack entry (awaiting inline would deadlock the
   owner's read loop — iii's exact reasoning, kept).
4. **Disconnect GC** (`unregisterWorker(departing)`): remove bindings whose
   `owner == departing`; durable bindings survive. Types owned by the
   departing worker **stay registered** (bindings must survive to be
   replayed on reconnect); their forwards will fail at dispatch until the
   owner returns — that's dispatch's problem, not registry state.
5. **Unregister trigger** by id, `trigger_type` optional as a consistency
   check (mismatch → no-op false, matching PROTOCOL.md's optional field).

## Public API

```zig
pub const Triggers = struct {
    pub fn init(gpa: std.mem.Allocator) Triggers;
    pub fn deinit(self: *Triggers) void;

    /// Last-wins. Appends ids of existing bindings of this type to `replay`
    /// so the actor can re-forward them to the new owner.
    pub fn registerType(self: *Triggers, id: []const u8, t: TypeInit,
                        replay: *std.ArrayList([]const u8)) error{OutOfMemory}!enum { new, replaced };

    pub fn registerBinding(self: *Triggers, id: []const u8, b: BindingInit,
                           ack_deadline_ms: ?i64)
        error{ OutOfMemory, UnknownTriggerType, DuplicateId }!ForwardTo; // = type owner WorkerId

    pub fn completeAck(self: *Triggers, binding_id: []const u8, failed: bool) AckOutcome;
        // .completed | .failed_binding_removed | .unknown (late/dup ack: drop, log)

    pub fn sweepExpiredAcks(self: *Triggers, now_ms: i64,
                            ctx: anytype, on_expired: fn (@TypeOf(ctx), binding_id: []const u8) void) usize;
        // expired ⇒ binding removed before callback fires

    pub fn unregisterBinding(self: *Triggers, id: []const u8, trigger_type: ?[]const u8) bool;
    pub fn unregisterWorker(self: *Triggers, departing: WorkerId) usize; // removed bindings count
    pub fn typeOwner(self: *const Triggers, type_id: []const u8) ?WorkerId;
    pub fn binding(self: *const Triggers, id: []const u8) ?*const Binding;
    pub fn countBindings(self: *const Triggers) usize;
};
```

All strings owned-copy on insert, freed on remove/overwrite/deinit;
`std.testing.allocator` leak discipline as everywhere.

## Test contract (RED first, named exactly)

1. `registerType new; typeOwner resolves`
2. `registerType replace returns replay set of existing bindings` — 2 bindings
   of type cron + 1 of type http; re-register cron → replay has exactly the 2
3. `registerBinding known type returns the type owner to forward to`
4. `registerBinding unknown type errors; nothing stored`
5. `duplicate binding id errors`
6. `durable binding parks an ack; completeAck(ok) keeps the binding`
7. `completeAck(failed) removes the binding`
8. `ack timeout removes binding then fires callback` — sweep with injected now
9. `late ack after timeout returns .unknown`
10. `connection-owned binding creates no ack entry`
11. `unregisterWorker removes only that worker's connection-owned bindings;
    durable and other workers' bindings survive` — the S4 core
12. `type survives its owner's disconnect; bindings of it remain replayable`
13. `unregisterBinding with mismatched trigger_type is a no-op returning false`
14. `no leaks under register/replace/unregister loops` (≥100 iterations)

## Out of scope

- Firing triggers (`engine.call(function_id, event)`) — the type-owner worker
  does that via normal invocation; nothing here.
- Built-in trigger-type table & "worker add" hints — actor policy.
- State-change trigger matching/conditions — that's the state *worker* (L1).
