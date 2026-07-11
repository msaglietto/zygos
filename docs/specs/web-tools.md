# Spec: `src/net/web_tools.zig` — web-tools worker (Y1/Y2)

Registers `zygos::tools::{web_search,web_fetch}` on the bus. Lives in
`src/net/` (holds `std.Io` for HTTP — Z-02). Because these are ordinary bus
tool functions dispatched by the turn driver, policy (U1), trim (Z-09), and
budget ride the existing seams for free — Y2 is proven by tests, not new
machinery. `zig build test` never opens a socket: the HTTP leg is factored
behind a pure response-processing layer tested over recorded fixtures.

## `zygos::tools::web_fetch`

Request `{"url":"https://..."}`; reply `{"url":..., "text":..., "truncated":bool}`.
- https/http only; anything else ⇒ structured is_error reply (tool-result
  shape, like tools_ops errors), never a crash.
- Response body → readable text: strip `<script>/<style>` blocks whole, strip
  tags, decode the five basic entities (`&amp; &lt; &gt; &quot; &#39;`),
  collapse blank runs. Non-text content types ⇒ error reply.
- Size caps: read at most `max_fetch_bytes` (option, default 512 KiB) off the
  wire; emit at most `max_text_bytes` (default 64 KiB) with `truncated:true`.
- Non-2xx ⇒ error reply naming the status. Redirects: follow ≤ 3.

## `zygos::tools::web_search`

Request `{"query":"...","count":5?}`; reply `{"results":[{"title","url","snippet"}]}`.
- Backend is operator config (`SearchConfig{ endpoint, key_env or key,
  engine: enum{brave, searxng} }`) injected at start — engine choice is
  config, adding an SDK would trip the `new_dependency` gate. Brave:
  GET `{endpoint}/res/v1/web/search?q=...` with `X-Subscription-Token`;
  searxng: GET `{endpoint}/search?q=...&format=json`, no key.
- Upstream JSON normalized to the neutral results shape; malformed upstream
  ⇒ error reply (fail closed, never a crash). Missing key at start ⇒ the
  worker registers anyway and every call replies a structured error naming
  the env var (a mission fails a step, not the boot).
- HTTP 429 (rate limit — Brave free tier is ~1 rps) gets up to
  `search_retry_max` (default 1) polite retries after
  `search_retry_delay_ms` (default 1100). Every other status still fails
  closed immediately; exhausted retries reply the status as usual. Failed
  attempts log at warn with the query, status, and attempt number.

## API

`WebToolsWorker.start(gpa, actor, registry, io, opts: Options)` / `stop` —
mirrors ToolsWorker. `Options{ search: ?SearchConfig, max_fetch_bytes,
max_text_bytes, search_retry_max, search_retry_delay_ms }`. The HTTP leg is
a `Transport` fn-pointer seam on the worker (default `httpGet`); tests swap
in a socket-free scripted fake. Pure layer (pub, fixture-tested): `htmlToText(arena,
bytes, max_out) {text, truncated}`, `parseBraveResults(arena, json_text)`,
`parseSearxngResults(arena, json_text)`, `validateUrl(url)`.

## Test contract (RED first; no sockets)

1. `htmlToText: tags/script/style stripped, entities decoded, blank runs collapsed`
2. `htmlToText: max_text_bytes cap sets truncated`
3. `validateUrl: https/http pass; file:, ftp:, garbage ⇒ error`
4. `parseBraveResults + parseSearxngResults: recorded fixtures → neutral shape`
5. `malformed upstream search JSON ⇒ error, no crash, no leak`
6. `bus: both functions registered; malformed request bytes ⇒ structured error reply`
7. `search with no key configured ⇒ structured error naming the env var`
8. `no leaks across handler loops`
9. `search retries once on 429 and succeeds on the second attempt`
10. `persistent 429 exhausts the retry budget and fails closed with the status`
11. `non-429 status is never retried`

Y2 (in `worker/turn.zig`-level tests or here): a scripted turn dispatching
`web_fetch` consults policy with the URL riding the policy request's
`input` (already the U1 shape — assert it), and an oversized fetched text
goes through `zygos::output::compress` (existing trim tests pattern).
