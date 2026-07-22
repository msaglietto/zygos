# Spec: `src/net/ticker.zig` — wall-clock tick pump (Z-11)

The actor's timeout sweeps (`onTick`: invocation deadlines, trigger acks,
idle channels) only run when someone posts `.tick`. The WS gateway's timer
thread does; a headless kernel embedding (`zygos mission start`) must pump
ticks itself or `ZYGOS_INVOKE_TIMEOUT_MS` silently never fires — invocations
park in the pending map forever (the M4.6 hang).

- `Ticker.init(actor, interval_ms)` + `start()`: a thread posting
  clock-stamped ticks; `stop()` joins.
- Lives in `src/net/` because it reads the wall clock — poster-stamped time
  is a net-layer duty; kernel modules never read the clock (observed-clock
  rule, PROTOCOL.md).
- Best-effort: a full inbox drops a tick (the next one sweeps); ticks never
  block.
