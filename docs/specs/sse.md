# Spec: `src/worker/sse.zig` — SSE decoder

Incremental Server-Sent Events (`text/event-stream`) decoder. Pure std-only:
no sockets, no clocks. Bytes arrive in arbitrary chunks via `feed`; complete
events pop via `next`.

- An event is emitted only once its terminating blank line has arrived;
  incomplete lines buffer internally across feeds.
- Multi-`data:` lines join with `\n` per the SSE spec; `event:` names the
  event (anthropic dialect), nameless data lines are the chat dialect.
- Comment lines (`:`) and unknown fields are skipped.
- Input bytes never crash the decoder; garbage between events is discarded
  at line granularity.

Consumers: `net/anthropic.zig` and `net/openai.zig` feed decoded events to
the `worker/{anthropic,openai}.zig` assemblers (shared core:
`worker/assembler.zig`).
