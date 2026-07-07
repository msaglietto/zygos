# Spec: `src/worker/openai.zig` — openai-compat stream assembler (U4)

Mirror of `worker/anthropic.zig` for the chat-completions SSE dialect.
Consumes decoded SSE events (sse.zig's job), produces text deltas + a
terminal message **in the provider-neutral shape the turn driver consumes**
— the same JSON the anthropic path and the fakes emit:

```jsonc
{"stop_reason":"end_turn"|"tool_use"|"max_tokens",
 "content":[{"type":"text","text":"..."},
            {"type":"tool_use","id":"call_1","name":"bash","input":{...}}],
 "usage":{"input_tokens":N,"output_tokens":N}}
```

## Dialect facts the assembler must honor

- Chunks arrive as `data: {json}` SSE events with **no event name**; the
  stream ends with `data: [DONE]`.
- Text rides `choices[0].delta.content` (string fragments).
- Tool calls ride `choices[0].delta.tool_calls[]`, each with an `index`;
  the first fragment for an index carries `id` and `function.name`, later
  fragments append `function.arguments` string fragments (JSON text built
  incrementally — same accumulate-don't-parse rule as anthropic's
  `partial_json`).
- `choices[0].finish_reason`: `"stop"→end_turn`, `"tool_calls"→tool_use`,
  `"length"→max_tokens`, anything else → `unknown`.
- `usage` rides a final chunk (when `stream_options.include_usage`):
  `prompt_tokens`→input, `completion_tokens`→output.
- Robustness contract identical to anthropic.zig: unknown fields ignored;
  malformed JSON on a chunk ⇒ `MalformedEvent`, assembler stays usable;
  an `{"error":{...}}` body ⇒ `ApiError`; never crash on input bytes.

## API (mirrors anthropic.Assembler)

`Assembler.init/deinit`, `onEvent(data_json) !?[]const u8` (no event name —
the dialect has none; `[DONE]` marks done), `isDone()`, `message()` →
`error.Incomplete` before `[DONE]`.

## Test contract (RED first)

1. `text-only stream: ordered deltas, joined final text, stop end_turn`
2. `tool_calls stream: arguments fragments accumulate into input JSON`
3. `two parallel tool_calls by index stay separate and ordered`
4. `finish_reason mapping incl. length→max_tokens and unknown`
5. `usage captured from the final chunk`
6. `[DONE] flips isDone; message() before it is Incomplete`
7. `error body ⇒ ApiError; malformed chunk ⇒ MalformedEvent, still usable`
8. `no leaks assembling 100 streams`

## Net glue (env-gated, never in `zig build test`)

`src/net/openai.zig` + `src/net/provider_openai.zig` mirror the anthropic
pair: HTTP/SSE client with a network-free pump, bus function
`zygos::provider::openai::messages`, base_url + `OPENAI_API_KEY` bearer auth,
smoke at `test/e2e/openai/` (exit 2 when the key is absent).
