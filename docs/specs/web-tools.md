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
- Response body → readable text (boilerplate-stripping extraction, tuned for
  token cost — see "HTML compression" below). Non-text content types ⇒ error
  reply.
- Size caps: read at most `max_fetch_bytes` (option, default 512 KiB) of the
  decoded body (see "Content coding"); emit at most `max_text_bytes` (default
  64 KiB) with `truncated:true`.
- Non-2xx ⇒ error reply naming the status.
- Redirects: std.http does not follow them. `web_fetch` follows up to
  `max_redirects` (option, default 3) by hand, and screens every hop (see
  "SSRF screen"). The cap is a structured refusal, not a silent truncation.
- Host refusals and redirect refusals are tool-result errors of the shape
  `{"error":"<Name>"}`: `PrivateHost`, `InvalidRedirect`, `TooManyRedirects`,
  `ResolveFailed`.

### Content coding

The real transport (`httpGet`) advertises `Accept-Encoding: gzip, deflate` and
decodes the body before anything else sees it. `gzip` (and `x-gzip`) and
`deflate` (zlib) are decoded; `identity` and a missing header pass through.
`zstd`, `br` and `compress` are not advertised and not decoded.

- `max_bytes` (`max_fetch_bytes`) caps the decoded output. Reading stops at the
  cap and nothing is allocated past it, so a small compressed body cannot
  expand past the cap. An over-cap body is cut at the cap, as for an identity
  body; it is not an error.
- A body that fails to inflate (bad block, bad data, a stream that ends before
  its end marker or its trailer) is `HttpFailed`. The gzip CRC32 and length, or
  the zlib Adler-32, are checked when the whole body fits under the cap, since
  std's inflater reads those fields without checking them. A body cut at the
  cap is not checked. Raw compressed bytes are never returned as text.
- A response with a `Content-Encoding` the transport did not advertise or does
  not know (`zstd`, `br`, `compress`, anything else, or a stacked coding such
  as `gzip, br`) is `HttpFailed`, whatever `Accept-Encoding` a caller put in
  `TransportRequest.headers`. Neither `web_fetch` nor `web_search` sets one.
- The pure part is `readCapped(gpa, reader, max_bytes)`: it reads a decoded
  reader to its end or the cap and reports whether it reached the end.

### SSRF screen

The screen judges every address `web_fetch` is about to dial. It is a
defense in depth, not a sandbox (see "Remaining limits").

1. **Literal screen.** The original URL passes `validateUrl` (http/https
   with a host of at most 255 bytes, `HostName.max_len`, counted on the
   encoded text), then the host screen. A literal IPv4 or IPv6 host is
   classified as parsed. `localhost` and `*.localhost` are refused. An IPv6
   literal that does not parse fails closed. The host is screened again
   after percent-decoding, since that is the host std.http would connect to
   (`%31%32%37.0.0.1` is `127.0.0.1`).
2. **Hop loop.** On a 3xx the transport returns `HttpBody.redirect` with the
   `Location` value. `web_fetch` resolves it against the current URL
   (relative allowed), then runs the same `validateUrl` and host screen on
   the result before the next request. It repeats up to `max_redirects`
   times.
3. **Resolve, screen, dial.** A host name is resolved before any connection.
   If any resolved address is in a blocked class, the fetch refuses
   `PrivateHost`. Otherwise the transport dials a screened address itself
   (`connectTcpOptions` with the IP as the dial host). The real name stays
   the TLS SNI and certificate name and the `Host` header. A second DNS
   answer cannot steer the socket, so the rebinding window between screen
   and connect is closed for `web_fetch`. Literal hosts are dialed as parsed.
4. **Blocked classes.**
   - IPv4: `0/8`, `10/8`, `127/8`, `169.254/16` (includes the cloud metadata
     address `169.254.169.254`), `172.16/12`, `192.168/16`, `192.0.0.0/24`
     (IETF protocol assignments), `198.18/15` (benchmarking), `100.64/10`
     (RFC 6598), and `224/4` and above (multicast, reserved).
   - IPv6: `0000::/8` (any literal whose first byte is zero: unspecified,
     loopback, v4-compatible, SIIT `::ffff:0:0:0/96`, and the rest of the
     block), local-use NAT64 `64:ff9b:1::/48`, discard `100::/64`,
     `fe80::/10`, `fec0::/10`, `fc00::/7`, `ff00::/8`.
   - IPv6 forms that embed an IPv4 address are screened by the embedded
     address: v4-mapped `::ffff:0:0/96`, NAT64 `64:ff9b::/96`, 6to4
     `2002::/16`. These are classified before `0000::/8`, and NAT64 and
     6to4 are not refused wholesale, so DNS64 networks keep working.
   - Names: `localhost` and `*.localhost`.
5. **Refusals** (all `{"error":"<Name>"}`):
   - `InvalidUrl`: the URL is not http(s), has no host, or its host text
     (raw or percent-encoded) is longer than 255 bytes. `std.Uri.getHost`
     aborts the process on a longer encoded host, so `validateUrl` refuses
     it first, on every hop and with the escape hatch on.
   - `PrivateHost`: the original host or any hop host is blocked, by
     literal or by resolution.
   - `InvalidRedirect`: `Location` missing, unparseable or unresolvable,
     longer than 8 KiB, not http(s), without a host, or with a host longer
     than 255 bytes.
   - `TooManyRedirects`: one more redirect than the cap (the fourth by
     default).
   - `ResolveFailed`: the name does not resolve, or resolves to no address.
     It never falls through to a fetch.
6. **Escape hatch.** `ZYGOS_FETCH_ALLOW_PRIVATE=1` (or `true`) sets
   `allow_private_hosts` and bypasses the whole screen: literal, every hop,
   and DNS. The resolver is not consulted and std.http resolves the host.
   The redirect cap still applies. It is for intentional local endpoints.

**Remaining limits.**
- Search endpoints are operator config and are not screened.
- The bash tool and MCP servers can reach the network directly and bypass
  this screen.
- The hosts file and the system resolver are trusted to answer. The screen
  judges the answer, not the resolver.
- Teredo (`2001::/32`) and other IPv6 transition forms are not decoded.

### HTML compression

`htmlToText` is an extractor, not a tag stripper: the goal is the fewest
tokens that still carry the page's content.

1. **Drop non-content elements whole** (open tag through matching close, or to
   EOF if unclosed): `script`, `style`, `noscript`, `svg`, `head`, `nav`,
   `header`, `footer`, `aside`, `form`, `iframe`, `template`, `select`,
   `button`. Case-insensitive. HTML comments (`<!-- ... -->`, incl. doctype-ish
   `<!...>`) are dropped too.
2. **Structure survives as text.** Block-level tags (`p`, `div`, `br`, `li`,
   `tr`, `section`, `article`, `ul`, `ol`, `table`, `blockquote`, `pre`,
   `h1`–`h6`) emit a newline; every other tag emits a single space so inline
   text never glues. `h1`–`h6` are prefixed with the matching number of `#`
   and `li` with `- `, so headings and lists stay machine-readable at zero
   extra token cost.
3. **Entities**: the five basic ones plus `&nbsp;` and numeric decimal/hex
   (`&#160;`, `&#x27;`). Unknown entities pass through verbatim.
4. **Whitespace**: runs of spaces/tabs collapse to one space, runs of blank
   lines collapse to at most one blank line, trailing spaces per line are
   dropped, and the whole output is trimmed.
5. Caps unchanged: at most `max_text_bytes`, `truncated:true` when clipped.

The reply is unchanged in shape; the worker logs input bytes, output bytes,
and the compression ratio so the saving is observable in production.

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
max_text_bytes, search_retry_max, search_retry_delay_ms,
allow_private_hosts, max_redirects }`. `allow_private_hosts` defaults to
false (the env override sets it). `max_redirects` defaults to 3.

The HTTP leg is a `Transport` fn-pointer seam on the worker (default
`httpGet`). It takes a `TransportRequest{ url, headers, max_bytes, dial,
follow_redirects }` and may return `HttpBody.redirect` instead of a body.
`dial` lists the screened addresses to connect to, tried in order (an empty
slice lets std.http resolve the host: search, and `web_fetch` under the
escape hatch). `follow_redirects` is false for `web_fetch` and true for
`web_search`, whose redirect handling is unchanged.

DNS is a `Resolver` fn-pointer seam on the worker. The default wraps
`std.Io.net.HostName.lookup`, run with `io.concurrent` so the loop that
drains the answers always runs beside it; an `Io` that cannot run it
concurrently, or an answer longer than 32 addresses, is `ResolveFailed`. Tests swap in a scripted fake, so
`zig build test` never resolves or opens a socket.

Pure layer (pub, fixture-tested): `htmlToText(arena, bytes, max_out)
{text, truncated}`, `parseBraveResults(arena, json_text)`,
`parseSearxngResults(arena, json_text)`, `validateUrl(url)`,
`hostBlocked(host_text)` (literal and name screen), `fetchHostBlocked(url)`
(the literal screen applied to the original URL and each hop), `addressBlocked(addr)`
(class check on a resolved address, including embedded IPv4).

## Test contract (RED first; no external network)

1. `htmlToText: tags/script/style stripped, entities decoded, blank runs collapsed`
2. `htmlToText: max_text_bytes cap sets truncated`
2a. `htmlToText: boilerplate elements dropped whole`
2b. `htmlToText: comments and doctype dropped`
2c. `htmlToText: block tags become newlines, headings get #, list items get -`
2d. `htmlToText: nbsp and numeric entities decoded; unknown entity passes through`
2e. `htmlToText: blank-line runs collapse to at most one`
2f. `htmlToText: realistic page compresses to a small fraction of input`
3. `validateUrl: https/http pass; file:, ftp:, garbage ⇒ error`
4. `parseBraveResults + parseSearxngResults: recorded fixtures → neutral shape`
5. `malformed upstream search JSON ⇒ error, no crash, no leak`
6. `bus: both functions registered; malformed request bytes ⇒ structured error reply`
7. `search with no key configured ⇒ structured error naming the env var`
8. `no leaks across handler loops`
9. `search retries once on 429 and succeeds on the second attempt`
10. `persistent 429 exhausts the retry budget and fails closed with the status`
11. `non-429 status is never retried`
12. `SSRF screen: loopback/private/link-local hosts blocked; public pass`
13. `web_fetch: private host refuses with PrivateHost before the transport; the allow flag overrides`
14. `web_fetch: public → 302 → 169.254.169.254 refuses PrivateHost at the hop`
15. `web_fetch: public → 302 → name resolving private refuses PrivateHost at the hop`
16. `web_fetch: public → 302 → public is followed and every hop is dialed at its screened address`
17. `web_fetch: exactly max_redirects hops succeed; one more refuses TooManyRedirects`
18. `web_fetch: missing, non-http(s), or unresolvable Location refuses InvalidRedirect`
19. `web_fetch: name resolving to a blocked class refuses PrivateHost before the transport`
20. `web_fetch: a name with one public and one private address refuses PrivateHost`
21. `web_fetch: resolver error or empty answer refuses ResolveFailed and never fetches`
22. `web_fetch: ZYGOS_FETCH_ALLOW_PRIVATE bypasses hop and DNS screens`
23. `web_fetch: public literal hosts dial themselves and skip the resolver`
24. `web_fetch: percent-encoded private host refuses PrivateHost before the transport`
25. `addressBlocked: v4, v6, v4-mapped, NAT64 and 6to4 embedded private classes; public pass`
26. `SSRF screen literals: NAT64, 6to4 and expanded loopback forms are blocked`
27. `validateUrl: a host longer than HostName.max_len is refused; a 255-byte host passes`
28. `web_fetch: over-long host refuses InvalidUrl without crashing, screen on and off`
29. `web_fetch: a redirect to an over-long host refuses InvalidRedirect, screen on and off`
30. `addressBlocked: 0000::/8, local-use NAT64, discard and benchmark ranges blocked`
31. `defaultResolver: an Io without concurrency refuses ResolveFailed instead of looking up inline`
32. `defaultResolver: an address literal resolves through the concurrent lookup`

33. `httpGet` over a loopback listener (the only tests that cross the real
    transport; 127.0.0.1, one connection, no external network):
    `httpGet decodes a gzip body to the caller's text (#23)`,
    `httpGet decodes an x-gzip body`, `httpGet decodes a deflate body`,
    `httpGet decodes a chunked gzip body`,
    `httpGet decodes a gzip body that ends with the connection`,
    `httpGet leaves an identity body unchanged`,
    `httpGet caps the decoded gzip output at max_bytes`,
    `httpGet returns the whole decoded body when it fits under max_bytes`,
    `httpGet errors on a corrupt gzip body instead of returning raw bytes`,
    `httpGet errors on a gzip body whose checksum does not match`,
    `httpGet errors on a gzip body whose length field does not match`,
    `httpGet errors on a deflate body whose Adler-32 does not match`,
    `httpGet errors on a body labelled gzip that is not gzip`,
    `httpGet errors on a truncated gzip stream`,
    `httpGet errors on a gzip stream missing its trailer`,
    `httpGet errors on an encoding it cannot decode`,
    `httpGet advertises only the encodings it decodes`,
    `httpGet with a caller Accept-Encoding never returns a compressed body as text`
34. `readCapped stops reading and allocating at the cap of a highly compressible body`,
    `readCapped marks a body read to its end complete`,
    `readCapped fails on a truncated gzip stream`

Y2 (in `worker/turn.zig`-level tests or here): a scripted turn dispatching
`web_fetch` consults policy with the URL riding the policy request's
`input` (already the U1 shape — assert it), and an oversized fetched text
goes through `zygos::output::compress` (existing trim tests pattern).
