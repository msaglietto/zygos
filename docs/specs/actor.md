# Spec: `src/kernel/actor.zig` — kernel actor (wires S2–S5)

The composition point. Implements ARCHITECTURE.md's concurrency model (decision
Z-02): **all registry mutation happens on one kernel thread** draining an MPSC
command inbox. This is the only kernel module allowed to import the others
(`protocol`, `catalog`, `invocation`, `trigger`, `channel`, `types`). It still
knows nothing of sockets: the network layer talks to it through `Command`s in
and an `Outbound` interface out.

## Boundary contracts (read first)

```
reader threads ──post(Command)──▶ [inbox] ──▶ kernel thread ──▶ Outbound.send(worker, frame)
timer thread  ──post(.tick)────▶                             ──▶ Waiter handoff (in-process)
```

1. **Inbox.** Bounded MPSC queue (mutex + condvar ring, default capacity 1024).
   `post` is thread-safe and **blocks when full** — backpressure, never drop.
   Only `run()`/`step()` may pop, and only on the kernel thread.
2. **Outbound.** The actor never serializes onto a socket; it hands finished
   frame bytes to a vtable:
   ```zig
   pub const Outbound = struct {
       ctx: *anyopaque,
       sendFn: *const fn (ctx: *anyopaque, to: WorkerId, frame: []const u8) SendError!void,
   };
   pub const SendError = error{ Disconnected, QueueFull };
   ```
   The net layer implements it with per-connection bounded writer queues
   (cap 64, mirrors iii); tests implement a fake that records `(to, frame)`
   pairs. `frame` is only valid during the call — implementations copy.
   On `SendError` the actor logs and drops; connection teardown is the net
   layer's job (it posts `worker_disconnected`).
3. **Time is injected.** The actor never reads a clock. Frame commands carry a
   poster-stamped `now_ms`; `.tick` carries the timer thread's `now_ms`. Tests
   drive time by posting ticks. (Same rule as the S3/S4/S5 modules.)
4. **Frame ownership.** Reader threads parse bytes → `json.Parsed(Message)`
   and move it into the command; the actor `deinit`s it after handling. The
   actor's own outbound frames are built in a per-command arena, freed after
   the `Outbound.send` call returns.

## Commands

```zig
pub const Command = union(enum) {
    worker_connected: WorkerId,
    worker_disconnected: WorkerId,
    frame: struct { from: WorkerId, parsed: std.json.Parsed(protocol.Message), now_ms: i64 },
    tick: i64,                       // now_ms
    shutdown,
};
```

`shutdown` stops the loop after the current command; remaining queued commands
are drained-and-deinitialized without processing (frames own memory — never
leak them on shutdown).

## Routing table (frame from worker W at time `now`)

| Frame | Action |
|---|---|
| `registerfunction` | `catalog.register(id, W, entry)`; `.overwrote` → warn log. `invocation` ref present → `Handler.external_http`, else `Handler.worker(W)`. Schema/metadata values are re-serialized to raw JSON text for the catalog. |
| `unregisterfunction` | `catalog.unregister(id, W)`; false → warn log. |
| `registerservice` | `services.register(id, W, …)`. |
| `registertriggertype` | `triggers.registerType` → for each replayed binding id, re-forward a `registertrigger` frame to W (PROTOCOL.md §4). |
| `registertrigger` | Wire-path bindings are **connection-owned**: `owner = W`, no ack entry (PROTOCOL.md §6; durable/function-path bindings arrive via bus functions in M1). `registerBinding` → forward the frame to the type owner. `UnknownTriggerType` → send `triggerregistrationresult` with ErrorBody `unknown_trigger_type` back to W. |
| `unregistertrigger` | `triggers.unregisterBinding(id, trigger_type)`; false → warn log. |
| `triggerregistrationresult` | From the type owner. `triggers.completeAck(id, failed)` for durable acks; then forward the frame to the binding's registrant (`binding.owner`) if connection-owned and still connected. `.unknown` + no binding → log-drop. |
| `invokefunction` | See dispatch below. |
| `invocationresult` | Parse `invocation_id` text → Uuid; `invocations.complete(uuid)` → route: `.connection c` → re-serialize the result frame, `Outbound.send(c, …)`; `.waiter w` → write slot, set event; `.none` → drop. `null` (unknown/dup/late) → log-drop, never crash (PROTOCOL.md §1). |
| `ping` | Send `pong` to W. |
| `pong` | Ignore (liveness is the net layer's concern in M0). |
| engine→worker types (`workerregistered`, …) received from a worker | Log-drop. |

### Dispatch (`invokefunction` from W)

1. Resolve `catalog.get(function_id)`:
   - **miss** → if `invocation_id` present: send `invocationresult` to W with
     ErrorBody `function_not_found`; else log-drop.
   - **`.worker(callee)`** → if `invocation_id` present: parse to Uuid (invalid
     UUID text → log-drop the frame, mirroring iii's deserialization rejection),
     `invocations.add(uuid, callee, .{ .connection = W }, now + invoke_timeout_ms)`,
     then forward the frame to `callee`. `DuplicateId` → log-drop. If absent:
     fire-and-forget — forward only, no pending (S3 spec boundary).
   - **`.builtin(f)`** → call in-process on the kernel thread (M0 built-ins are
     tiny); success/error → `invocationresult` back to W if `invocation_id` present.
   - **`.external_http`** → M0: not dispatchable; treat as miss with ErrorBody
     `external_http_unsupported`.
2. `traceparent`/`baggage` are copied through opaquely on every path (§7).
3. `action` (`enqueue`/`void`) — M0 has no queue worker: `enqueue` degrades to
   direct dispatch with a warn log; `void` forces fire-and-forget semantics.

### Tick (`now_ms`)

1. `invocations.sweepExpired(now)` → per expiry, synthesize `invocationresult`
   with ErrorBody `timeout` to the reply target (§ S3).
2. `triggers.sweepExpiredAcks(now)` → per expiry, log; binding already removed.
3. `channels.sweepIdle(now)`.

### Disconnect (`worker_disconnected` for W) — order matters

1. `invocations.failAllForCallee(W)` → each reply target gets ErrorBody
   `worker_disconnected`. Run **before** catalog cleanup so the error carries
   the still-known function context if needed.
2. `invocations.dropAllForCaller(W)` — silent.
3. `catalog.removeAllOwnedBy(W)` + `services.removeAllOwnedBy(W)` — CAS-gated
   inside the catalog (S2); a fresher re-registration survives.
4. `triggers.unregisterWorker(W)` — connection-owned bindings GC'd, durable
   survive, types stay (S4).
5. `channels.reapOwner(W)`.

`worker_connected` for W: send `workerregistered{worker_id: uuid-text}` to W.

## UUID text ↔ bytes

Wire ids are UUID text; S3 keys on `[16]u8`. `types.zig` grows
`parseUuid([]const u8) error{InvalidUuid}!Uuid` and
`formatUuid(Uuid, *[36]u8) []const u8` (lowercase hyphenated), with tests.
No RFC-variant validation beyond shape (8-4-4-4-12 hex) — iii accepts any UUID.

## Public API

```zig
pub const Config = struct {
    invoke_timeout_ms: i64 = 30_000,
    ack_timeout_ms: i64 = 10_000,
    channel_ttl_ms: i64 = 300_000,
    inbox_capacity: usize = 1024,
};

pub const Actor = struct {
    pub fn init(gpa: std.mem.Allocator, config: Config, outbound: Outbound) error{OutOfMemory}!Actor;
    pub fn deinit(self: *Actor) void;

    /// Thread-safe. Blocks when the inbox is full (backpressure).
    pub fn post(self: *Actor, cmd: Command) void;

    /// Kernel-thread loop: drain until `shutdown`.
    pub fn run(self: *Actor) void;

    /// Test seam: process exactly one queued command (kernel thread only).
    /// Returns false when it processed `shutdown` or the inbox was empty.
    pub fn step(self: *Actor) bool;
};
```

Tests drive `post` + `step` deterministically on one thread — `run` gets one
thin smoke test (spawn, post, shutdown, join). Multi-thread stress lives with
the net layer, not here.

## Test contract (RED first, named exactly)

1. `worker_connected sends workerregistered with the uuid text`
2. `register then invoke routes the frame to the callee and the result back to the caller` — the M0 happy path, trace context preserved end-to-end
3. `invoke unknown function returns function_not_found error result`
4. `invoke unknown function without invocation_id is dropped silently`
5. `fire-and-forget invoke forwards without parking a pending`
6. `timeout tick synthesizes timeout error; late result then dropped` — S3 through the actor
7. `callee disconnect fails its pendings with worker_disconnected`
8. `caller disconnect drops its pendings silently`
9. `stale disconnect after re-registration leaves the fresh owner intact` — S2 through the actor: A registers f, A′ re-registers, A disconnects → invoke still routes to A′
10. `trigger type re-registration replays bindings to the new owner` — S4 through the actor
11. `registertrigger forwards to type owner; triggerregistrationresult forwarded to registrant`
12. `registertrigger with unknown type answers unknown_trigger_type`
13. `ping answers pong`
14. `builtin dispatch runs in-process and answers on the same tick`
15. `unknown invocation_id result is dropped without crash`
16. `disconnect GC reaps catalog, triggers, channels for that worker`
17. `enqueue action degrades to direct dispatch (warn) in M0`
18. `shutdown drains and frees queued frames (no leaks)`
19. `run loop smoke: spawn thread, post, shutdown, join` — bounded, no sleeps
20. `no leaks under register/invoke/complete loops` (≥100, std.testing.allocator)

## Out of scope

- WebSocket accept/read/write loops, connection registry, writer queues — `net/ws.zig` (dep-gated).
- The timer thread itself — net/main wiring owns it; tests post ticks.
- Session-prefixed id namespacing, `engine::*` built-in functions, queues,
  policy, budgets — M1+.
