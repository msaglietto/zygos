# Spec: `src/kernel/invocation.zig` — invocation router (S3)

Implements GOAL.md criterion **S3** and PROTOCOL.md semantics **1
(correlation)**. Kernel-actor-owned, single-threaded, no locks (see
catalog spec for the threading rationale — same model).

## Design decisions

1. **No clock reads inside the module.** Every time-dependent function takes
   `now_ms: i64` as a parameter. The actor owns a timer (a thread posting tick
   commands); tests inject time and never sleep. A test that sleeps is wrong.
2. **Completion is routing, not futures.** iii parks a oneshot per call; in
   the actor model a pending entry records a `ReplyTarget` and completion
   *routes* the result there:
   ```zig
   pub const ReplyTarget = union(enum) {
       connection: WorkerId,        // forward invocationresult frame to this caller's writer queue
       waiter: *Waiter,             // in-process blocking caller (builtin worker, tests)
       none,                        // fire-and-forget with an id we still track (rare)
   };
   ```
   `Waiter` wraps `sync.ResetEvent` + a result slot; it is the only
   cross-thread object here and its handoff rule is: the actor writes the
   result slot, then sets the event; the waiting thread reads after wake.
   (`kernel/sync.zig` wraps POSIX pthread — Zig 0.16 removed
   `std.Thread.ResetEvent` and its std.Io replacement is barred by Z-02.)
3. **Both disconnect directions matter.** Each pending records the **callee**
   (worker the call was dispatched to) and the **reply target** (who awaits):
   - callee disconnects → complete its pendings with ErrorBody
     `{"code":"worker_disconnected"}`.
   - caller disconnects → drop its pendings silently (nobody to reply to).
4. **Deadline structure:** `std.AutoHashMap(Uuid, Pending)` for O(1)
   correlation + `std.PriorityQueue` min-heap on deadline with **lazy
   deletion** — completed entries may linger in the heap; on sweep, pop
   candidates are validated against the map (and against a generation/
   presence check) before firing a timeout. Never double-complete.
5. **Unknown or duplicate `invocation_id` results are dropped** (logged at
   the call site), never an error, never a crash — PROTOCOL.md §1.

## Public API

```zig
pub const Invocations = struct {
    pub fn init(gpa: std.mem.Allocator) Invocations;
    pub fn deinit(self: *Invocations) void;

    /// Park a pending call. deadline_ms is absolute (caller computes now+timeout).
    /// function_id is duped in: synthesized timeout/disconnect result frames
    /// require it (wire-required field), so callbacks receive it as a fourth
    /// parameter valid for the duration of the callback.
    pub fn add(self: *Invocations, id: Uuid, callee: WorkerId, function_id: []const u8,
               reply: ReplyTarget, deadline_ms: i64) error{OutOfMemory, DuplicateId}!void;

    /// Correlate a result. Returns the ReplyTarget to route to, or null if
    /// unknown/already-completed (caller logs & drops).
    pub fn complete(self: *Invocations, id: Uuid) ?ReplyTarget;

    /// Fire timeouts. For every entry with deadline <= now_ms: remove it and
    /// invoke on_timeout(id, reply_target, function_id) so the actor can
    /// synthesize an invocationresult with ErrorBody{code="timeout"}.
    /// Lazy-deletion safe.
    pub fn sweepExpired(self: *Invocations, now_ms: i64, ctx: anytype,
                        comptime on_timeout: fn (@TypeOf(ctx), Uuid, ReplyTarget, []const u8) void) usize;

    /// Callee died: complete each of its pendings via on_fail (actor sends
    /// worker_disconnected error to the reply target). Returns count.
    pub fn failAllForCallee(self: *Invocations, callee: WorkerId, ctx: anytype,
                            comptime on_fail: fn (@TypeOf(ctx), Uuid, ReplyTarget, []const u8) void) usize;

    /// Caller died: silently drop all pendings whose reply target is that
    /// connection. Returns count.
    pub fn dropAllForCaller(self: *Invocations, caller: WorkerId) usize;

    pub fn count(self: *const Invocations) usize;
};
```

Fire-and-forget (`invokefunction` without `invocation_id`) never enters this
module — dispatch handles it with no pending entry. That's the actor's
concern, not this module's.

## Test contract (RED first, named exactly)

1. `add then complete returns the reply target and removes the entry`
2. `complete unknown id returns null`
3. `duplicate complete returns null the second time`
4. `add with duplicate id returns DuplicateId`
5. `sweepExpired fires only entries at or past the deadline` — three entries,
   deadlines 100/200/300, sweep at now=200 fires exactly two, count()==1
6. `late result after timeout returns null` — add, sweep past deadline,
   then complete → null
7. `completed entry never times out` — add, complete, sweep past its
   deadline → on_timeout not called (lazy-deletion correctness)
8. `failAllForCallee completes only that callee's pendings` — two callees,
   fail one, other's entries intact
9. `dropAllForCaller drops silently and only for that caller`
10. `waiter handoff: result slot visible after event set` — one spawned
    thread blocks on Waiter, actor-side completes, thread reads the slot;
    bounded wait, no sleep-based synchronization
11. `no leaks under add/complete and add/sweep loops` — ≥100 iterations each
    under std.testing.allocator

## Out of scope

- Building the actual `invocationresult` frames (actor + protocol.zig).
- The timer thread (actor owns it; this module only exposes sweepExpired).
- Retries, budgets, tracing — different layers entirely.
