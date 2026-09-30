# Spec: `src/worker/trace.zig` + `src/worker/trace_event.zig` — mission trace

One JSON object per line appended to `events.jsonl` in the planning root:
role boundaries, provider steps, tool calls/results, usage, task edges.

## Typed schema (`trace_event.zig`)

`TraceEvent` is a tagged union shared by emitters (mission/turn drivers via
`trace.emit`) and consumers (JSONL renderer, TUI model): adding a variant
breaks every exhaustive switch at compile time instead of silently dropping.
Variants: `mission`, `role_start`, `role_end`, `task_start`, `task_done`,
`step`, `tool_call`, `tool_result`, `usage`, `turn_end`.

- `body()` serializes byte-identical to the historical fmt-string emitters —
  events.jsonl is a wire format; consumers in the wild parse it. The usage
  arm stays `input_tokens` and `output_tokens`. Cache counts, when a provider
  sends them, are copied onto the task trial and are not fields of this line.
- `parse()` is tolerant: missing fields read as defaults, unknown event
  names/non-objects as null — consumers keep raw-passthrough semantics for
  foreign lines.

## Semantics the trace must honor

- Fail-open by contract: the trace observes the run, it is not part of it.
  An unwritable path never changes an outcome; only OutOfMemory propagates.
- One `fwrite` in append mode per line keeps concurrent emitters from
  interleaving mid-line.
- Embedded payloads clip at `max_field_bytes` (2048) on a UTF-8 boundary,
  with the full byte size alongside — a view, not an archive.
- In-process `Sink`s (the TUI) receive every line (sans newline) even with
  no file path; sink callbacks run on the emitting thread and must be fast
  and infallible. Registry is process-global (the path travels as a string
  in request JSON — there is no object to hang a sink on).
- `render()` (the `zygos mission trace` view) passes unknown or unparseable
  lines through raw — the renderer must never hide evidence.
