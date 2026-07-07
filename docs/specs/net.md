# Spec: `src/net/ws.zig` — WebSocket server layer (S6 path)

The only kernel-side module that touches sockets. Composes `protocol.zig` and
`actor.zig`: reader callbacks post `Command`s; an `Outbound` implementation
drains to per-connection writer queues. Dependency: `karlseguin/websocket.zig`
(+ `http.zig` for the M0-optional channel bridge) — **gate resolved: both
approved by Mauricio 2026-07-06**.

## Interop targets (measured, not guessed)

- iii Node SDK connects to `ws://localhost:49134` by default (`III_URL` env
  override) — Zygos listens on **49134** by default, `--port` to override.
- Wire behavior verified against `~/Projects/iii/engine/src/protocol.rs`
  (v0.21.x): iii omits `None` fields on serialize and accepts explicit nulls;
  our emit-null style is compatible both ways.

## Connection lifecycle

1. **Accept** → generate `WorkerId` (`std.crypto.random` UUID v4), register the
   connection in the conn table, `actor.post(.{ .worker_connected = id })`.
   The actor answers `workerregistered{worker_id}` through `Outbound`.
2. **Read loop** (websocket.zig handler thread, one per connection):
   - Text frame → `protocol.parseMessage` → post
     `.{ .frame = .{ .from = id, .parsed = parsed, .now_ms = std.time.milliTimestamp() } }`.
     This is the **only** place wall-clock time is read besides the timer.
   - Parse failure → log (worker id + error + first 256 bytes), drop the frame,
     keep the connection (mirrors iii's tolerance; a hostile peer is bounded by
     the read-frame size limit below).
   - Binary frame → match 4-byte magic `OTLP`/`MTRC`/`LOGS` → M0: accept + drop
     (telemetry stub). No magic → attempt JSON decode as above (PROTOCOL.md).
3. **Close/error** → remove from conn table, `post(.worker_disconnected)`.
   Exactly once — guard against double-close callbacks.

## Conn table + Outbound

```zig
const ConnTable = struct { mutex: Mutex, map: AutoHashMap(WorkerId, *Conn) };
```

- Mutated by accept/close (ws threads), read by `Outbound.send` (kernel
  thread). This mutex is legitimate: the table is net-layer plumbing, not
  registry state (Z-02 forbids locks in *registries*, not in the socket layer).
- `Outbound.send(to, frame)`: look up conn; missing → `error.Disconnected`.
  Enqueue on the connection's **bounded writer queue (cap 64, mirrors iii)**;
  full → `error.QueueFull` (actor logs + drops — a stalled consumer must not
  block the kernel thread). A writer drain (websocket.zig's write path or a
  dedicated per-conn writer thread — implementation's choice, flag it) copies
  the frame bytes before `send` returns.

## Timer

One thread: every 250 ms `actor.post(.{ .tick = std.time.milliTimestamp() })`.
Started/stopped with the server. Tests never use it (they post ticks).

## Limits (fail-closed, mirror iii's posture)

- Max frame size 16 MiB; oversized → close the connection (code 1009).
- Handshake timeout 10 s; no auth in M0 (localhost bus, same as iii dev mode).

## main.zig wiring

`zygos [--port 49134]`: init GPA → `Actor.init` → spawn kernel thread
(`actor.run`) → start timer → start WS server (blocks) → on SIGINT: stop
server, post `.shutdown`, join kernel thread, deinit. Exit 0.

## Test contract

Unit tests here are thin (the kernel logic is actor-tested); the real
verification is **S6**:

1. `conn table: register, lookup, remove, double-close guarded`
2. `writer queue: cap 64 enforced, full → QueueFull, drain preserves order`
3. `binary magic dispatch: OTLP/MTRC/LOGS dropped, unknown falls through to JSON`
4. **e2e (S6)**: `test/e2e/node-sdk/` — script that (a) builds + starts the
   zygos binary on a free port, (b) runs a Node script importing the
   **unmodified** iii SDK from `~/Projects/iii/sdk/packages/node/iii` (env
   `III_URL=ws://localhost:<port>`), registering `echo::reverse` from worker A,
   invoking it from worker B, asserting the result, (c) kills the server;
   exits nonzero on any failure. Documented run in README.

## Out of scope

- The `GET /ws/channels/{id}` client bridge — M0-optional, own task, http.zig.
- TLS, auth, worker registry service — non-goals / later milestones.
