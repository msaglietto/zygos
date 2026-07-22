# Spec: `src/net/stream_guard.zig` — stream idle watchdog (Z-12)

`std.Io`'s `net.Stream.Reader` has no per-read deadline, so a provider that
accepts the connection and then goes silent (observed: GLM endpoint
mid-mission) parks the worker thread in `recv` forever. The guard watches
activity pokes from the streaming loop and, once none arrive for `idle_ms`,
fires a callback whose job is `Stream.shutdown(io, .both)` — which errors
the blocked read and lets the turn driver fall back to the next provider
route.

## Shape

- Network-free core: `IdleDeadline` over injected time — all deadline logic
  tests without threads or sockets.
- Thread wrapper: `start()` spawns the watcher; the streaming loop calls
  `poke()` on every read; `stop()` joins.
- Config: `ZYGOS_STREAM_IDLE_MS` (mission CLI wiring); 0/unset semantics
  per the net glue.

## Semantics the guard must honor

- Fire-once: the callback runs at most once per guard, and never after
  `stop()` returns (stop joins the thread) — so the socket the callback
  closes is still valid at fire time.
- A poke resets the deadline; a fired guard stays fired (no rearm).
- The guard observes; it never owns the stream. Cleanup order is the
  caller's: stop the guard before freeing the stream.
