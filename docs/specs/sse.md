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
- Decoder storage is capped at 4 MiB across raw input and the accumulated
  event fields, including complete data lines in an unterminated event.
  Exceeding the cap returns `TooLarge`; provider pumps map it to `BadStream`.
- Assemblers cap total payload input at 16 MiB per response. Oversized
  responses fail rather than returning a truncated terminal message.

Consumers: `net/anthropic.zig` and `net/openai.zig` feed decoded events to
the `worker/{anthropic,openai}.zig` assemblers (shared core:
`worker/assembler.zig`).

Both assemblers validate terminal tool input before materialization, because
the net renderers embed it raw in the terminal payload. A `max_tokens` reply
omits its tool blocks and keeps that reason and its usage. Any other non-empty
tool input that is not a JSON object (truncated, whitespace-only, or a
different JSON type) stops as `unknown` with no tool blocks; the turn driver
then fails the turn after usage accounting and without dispatch. In the
anthropic dialect, a start-event input survives empty deltas, and a non-empty
delta sequence replaces it as a whole.
