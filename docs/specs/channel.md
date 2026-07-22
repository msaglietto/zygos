# Spec: `src/kernel/channel.zig` — keyed byte channels (S5)

Implements GOAL.md criterion **S5** and PROTOCOL.md semantics **8**. The sole
streaming substrate: provider token streams, HTTP request/response bodies, UI
event feeds all ride these pipes.

## Threading model — this module is the exception

Catalog/invocation/trigger are actor-owned and lock-free. Channels are **not**:
producers and consumers are connection threads and bridge threads pushing and
popping bytes directly — routing every token chunk through the actor inbox
would serialize all streams through one thread.

Split accordingly:
- **`Channels` (the registry)** — actor-owned, single-threaded like the other
  registries: create, take-endpoint, sweep, reap. Holds refcounted pointers.
- **`Pipe` (the transport)** — a cross-thread bounded MPSC-of-one ring buffer:
  mutex + two condvars (not-empty / not-full). Refcounted; freed when the
  registry entry AND both endpoints are gone.

Endpoint handoff rule: the registry hands out each endpoint **exactly once**
(PROTOCOL.md §8); after `take`, the endpoint object is owned by the taker's
thread and never touched via the registry again.

## Data model

```zig
pub const Ref = struct {              // wire shape: StreamChannelRef
    channel_id: []const u8,
    access_key: []const u8,           // random 32 bytes, hex — from arc4random_buf
                                      // (Zig 0.16 removed std.crypto.random)
    direction: enum { read, write },
};

pub const Item = union(enum) {        // maps to WS text/binary frames
    text: []u8,                       // owned by the pipe until popped
    binary: []u8,
};
```

`create(buffer_capacity, owner: WorkerId, now_ms)` returns a `(writer: Ref,
reader: Ref)` pair — two distinct access keys, one pipe.

## Semantics

1. **Take-once.** `takeSender(id, key)` / `takeReceiver(id, key)` validate
   id + key + direction and hand out the endpoint; a second take of the same
   endpoint fails `error.AlreadyTaken`. Wrong key → `error.BadKey`; wrong
   direction key (reader key on takeSender) → `error.BadKey` too (don't
   leak which part was wrong).
2. **Bounded, blocking, with try variants.** `Sender.push(item)` blocks on
   not-full; `tryPush` returns `error.Full`. `Receiver.pop()` blocks on
   not-empty; `tryPop` returns `null`. Thread-per-connection makes blocking
   the natural mode (Z-02); no async.
3. **Close semantics.** `Sender.close()` (or sender deinit) → receiver drains
   remaining items then gets `error.EndOfStream`. `Receiver.close()` →
   sender's next push fails `error.ReceiverGone`. Close wakes all blocked
   parties. Exactly the WS-bridge behavior: drain then Close frame.
4. **TTL sweep.** `sweepIdle(now_ms)` reaps channels idle past `ttl_ms`
   (default 300_000). Idle = no push/pop/take since `last_activity_ms`
   (activity updates it; injectable time as everywhere — tests never sleep).
   Reap = registry entry removed + pipe closed both ways; live endpoint
   holders see EndOfStream/ReceiverGone, refcount frees memory safely.
5. **Owner reap.** `reapOwner(worker)` — same as TTL reap for every channel
   created by a disconnecting worker.
6. **Item ownership.** Pushed slices are **duped into the pipe**; popped items
   are owned by the popper (must free). Pipe deinit frees undrained items.

## Public API

```zig
pub const Channels = struct {
    pub fn init(gpa: std.mem.Allocator, ttl_ms: i64) Channels;
    pub fn deinit(self: *Channels) void;
    pub fn create(self: *Channels, capacity: usize, owner: WorkerId, now_ms: i64)
        error{OutOfMemory}!struct { writer: Ref, reader: Ref };
    pub fn takeSender(self: *Channels, id: []const u8, key: []const u8, now_ms: i64)
        error{ NotFound, BadKey, AlreadyTaken }!Sender;
    pub fn takeReceiver(self: *Channels, id: []const u8, key: []const u8, now_ms: i64)
        error{ NotFound, BadKey, AlreadyTaken }!Receiver;
    pub fn sweepIdle(self: *Channels, now_ms: i64) usize;
    pub fn reapOwner(self: *Channels, owner: WorkerId) usize;
    pub fn count(self: *const Channels) usize;
};

pub const Sender = struct {
    pub fn push(self: *Sender, item: Item) error{ ReceiverGone, Closed }!void;
    pub fn tryPush(self: *Sender, item: Item) error{ Full, ReceiverGone, Closed }!void;
    pub fn close(self: *Sender) void;      // idempotent; also called by deinit
    pub fn deinit(self: *Sender) void;
};
pub const Receiver = struct {
    pub fn pop(self: *Receiver) error{EndOfStream}!Item;   // blocks
    pub fn tryPop(self: *Receiver) error{EndOfStream}!?Item;
    pub fn close(self: *Receiver) void;
    pub fn deinit(self: *Receiver) void;
};
```

## Test contract (RED first, named exactly)

1. `create returns distinct keys for writer and reader`
2. `takeSender with reader key fails BadKey; correct key succeeds`
3. `second take of same endpoint fails AlreadyTaken` — the take-once core
4. `take on unknown id fails NotFound`
5. `fifo order preserved across push/pop` (single-thread, try variants)
6. `tryPush on full pipe returns Full; pop frees a slot`
7. `cross-thread stream: producer thread pushes N items, consumer thread pops
   all N in order, then EndOfStream after close` — bounded wait, no sleeps
8. `blocked pop wakes on close with EndOfStream`
9. `push after receiver close fails ReceiverGone`
10. `sweepIdle reaps only channels past ttl; activity resets the clock` —
    injected now
11. `reapOwner reaps that worker's channels only; live endpoint sees clean end`
12. `popped item is caller-owned; undrained items freed on deinit (no leaks)`
13. `no leaks under create/take/close loops` (≥100, std.testing.allocator)

## Out of scope

- The HTTP/WS client bridge (`GET /ws/channels/{id}`) — net layer, dep-gated.
- Telemetry binary frames — observability worker.
- Multi-consumer/broadcast streams — that's the L1 `stream` worker, built on
  these primitives, not in them.
