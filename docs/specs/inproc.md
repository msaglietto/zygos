# Spec: `src/kernel/inproc.zig` — in-process workers (T1)

Implements GOAL.md criterion **T1**: Layer 1–2 workers are Zig, in-process,
and use the **same registration API as external workers** (ARCHITECTURE.md).
An inproc worker is a peer on the bus: it has a WorkerId, sends frames as
`Command`s, and receives frames through `Outbound` — the kernel cannot tell
it from a WS connection.

## Design

```
worker thread ──frames as Commands──▶ actor inbox
actor ──Outbound.send──▶ [Mux] ──▶ inproc worker's frame queue ──▶ worker thread
                             └──▶ fallback Outbound (WS gateway)
```

1. **Mux, not kernel change.** `inproc.Registry` implements `Outbound`: send
   looks up the target in its worker table (sync.Mutex-guarded — net-style
   plumbing, not registry state) and copies the frame into that worker's
   bounded queue; unknown ids fall through to a `fallback: ?Outbound`
   (the WS gateway). Composition happens in main.zig; the actor is untouched.
2. **One router thread per inproc worker**, draining its frame queue —
   plus **one thread per invocation** for handler execution: `invokefunction`
   spawns a handler thread (local handler map by function_id → run handler →
   post `invocationresult` frame command, or nothing if fire-and-forget).
   Handlers may therefore make blocking bus calls without deadlocking the
   router thread.
   - `invocationresult` → correlate against the worker's own pending map
     (uuid → `sync.ResetEvent` + result slot) → wake the blocked caller.
   - `workerregistered`, acks → record/log. Unknown → drop.
3. **Blocking call API rides the frame path** — kernel pendings are parked
   with `.connection` reply targets exactly as for WS callers. The kernel's
   `ReplyTarget.waiter` stays for kernel-internal bridges (see below), not
   for inproc workers.

## Public API

```zig
pub const Handler = fn (ctx: ?*anyopaque, arena: Allocator, request_json: []const u8)
    error{ Failed, OutOfMemory }![]const u8;  // response JSON, arena-owned

pub const Worker = struct {
    pub fn spawn(gpa, actor: *Actor, registry: *Registry, name: []const u8) !*Worker;
    /// Registers on the bus (registerfunction frame) + local dispatch table.
    pub fn registerFunction(self, id: []const u8, ctx: ?*anyopaque, handler: *const Handler) !void;
    /// Blocking invoke over the bus. Returns a CallResult union — `.ok` with
    /// owned response JSON, or `.err` with the owned ErrorBody JSON (caller
    /// frees either with gpa). Only OutOfMemory/Shutdown are Zig errors;
    /// remote failures are data, not error codes. The kernel's invoke timeout
    /// bounds the wait.
    pub const CallResult = union(enum) { ok: []u8, err: []u8 };
    pub fn call(self, function_id: []const u8, payload_json: []const u8)
        error{ OutOfMemory, Shutdown }!CallResult;
    /// Fire-and-forget invoke (no invocation_id).
    pub fn cast(self, function_id: []const u8, payload_json: []const u8) !void;
    pub fn stop(self) void;   // deregister via worker_disconnected + join
};

pub const Registry = struct {
    pub fn init(gpa, fallback: ?Outbound) Registry;
    pub fn outbound(self) actor_mod.Outbound;   // hand to Actor.init
    pub fn deinit(self) void;
};
```

## Kernel extensions ridden by T1 (same commit series)

1. **BuiltinFn grows a ctx**: `Handler.builtin` becomes
   `struct { ctx: ?*anyopaque, f: *const BuiltinFn }` so actor-owned builtins
   (channels bridge) can reach state. Was flagged provisional in S2.
2. **Real waiter payloads**: completing `ReplyTarget.waiter` dupes the result
   JSON into gpa; `Outcome` slices are owned-by-recipient (waiter side frees).
3. **Channel sync bridge** — registry ops must run on the kernel thread, but
   endpoint objects are cross-thread by design. New commands:
   `channel_create`, `channel_take_sender`, `channel_take_receiver`, each
   carrying a `*Waiter`-style slot + event; the kernel thread performs the op
   and sets the event. Blocking helpers on Actor:
   `channelCreate(capacity, owner, now_ms)`, `channelTakeSender(id, key, now_ms)`,
   `channelTakeReceiver(id, key, now_ms)`.

## Test contract (RED first)

1. `inproc worker registers a function; a second worker calls it and gets the response`
2. `call to an unknown function surfaces the ErrorBody code` (function_not_found)
3. `fire-and-forget cast dispatches without a pending`
4. `two inproc workers call each other concurrently without deadlock` (bounded, no sleeps)
5. `worker stop posts worker_disconnected; its functions are reaped (CAS holds)`
6. `mux falls back to the fallback outbound for non-inproc ids`
7. `builtin with ctx reads its state` (kernel test)
8. `waiter completion carries a real duped payload; recipient frees` (kernel test)
9. `channel bridge: create/takeSender/takeReceiver round-trip a stream between two threads` (kernel test)
10. `no leaks under register/call loops` (≥100)
11. `a handler result the protocol rejects errors the caller instead of hanging`

## Out of scope

- Reconnect semantics (inproc workers don't reconnect; they stop).
- Trigger registration from inproc workers (arrives with the cron worker, M2).
