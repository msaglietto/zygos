# Spec: `src/worker/stream_tap.zig` — live stream tap

Observability for delta kinds that never ride the kernel channel: model
thinking/reasoning text and streaming tool-call fragments (`.thinking`,
`.tool_name`, `.tool_args`). The channel's Item union is wire format
(PROTOCOL.md, human-gated) — the tap sidesteps it as a process-global
registry, like trace.zig's sinks.

- Emitters: the SSE assemblers call `emit(kind, bytes)` as fragments arrive.
- Consumers: the mission CLI registers the TUI model; `register` returns a
  token for `unregister`.
- Best-effort and fail-open: no consumer, or a slow consumer, never affects
  the stream; bytes are valid only for the callback's duration.
- Process-global means interleaving across concurrent streams is possible —
  acceptable for the single-mission CLI; a multi-tenant embedding needs
  per-turn scoping first (known limit, on the roadmap with M6).
