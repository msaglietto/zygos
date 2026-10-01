# Spec: `src/worker/mcp/client.zig` — MCP client

Plugs an external MCP server's tools onto the bus as
`zygos::mcp::<server>::<tool>` functions — the inverse of `gateway.zig`
(which exposes zygos tools outward). Configured via `.mcp_servers` in
`zygos.zon`; tools appear in the turn's tool list as `<server>_<tool>` and
ride the same policy/trim/budget gates as native tools.

## Protocol

- stdio framing, JSON-RPC 2.0, over an injected `Transport` vtable — the
  protocol layer never touches a pipe directly (tests run in-process; the
  child-process transport lives below the seam).
- Handshake: `initialize` → `notifications/initialized` → `tools/list`.
  A configured-but-broken server refuses the whole run (fail closed) —
  spawn failure, handshake failure, or malformed tool list all exit 2
  before the mission starts.
- Requests are serialized per client (one stdio pipe = one conversation);
  replies are matched by id. Non-matching lines (server notifications) are
  skipped, never treated as errors.

## Semantics the client must honor

- Fail closed: a malformed reply, a JSON-RPC error object, or a dead
  transport is a structured tool failure (`is_error` tool-result shape) —
  never a guess, never a crash.
- Tool calls translate `tools/call` results into the neutral tool-result
  content the turn driver consumes; text content concatenates, non-text
  content is preserved as JSON.
- The worker owns its clients: teardown closes transports; a server dying
  mid-mission fails the *calls*, not the process.
- The child transport caps a reply line at 1 MiB, rejects NUL, and times out
  each line read after two minutes. Buffered later lines are preserved.
  Teardown escalates TERM to KILL after 250 ms if the child does not exit.
  A blocked write or endless unmatched notifications still need a whole-RPC
  deadline; the read deadline does not provide that stronger guarantee.

E2E leg 2 of `test/e2e/m4/run.sh` drives a real client against
`zygos mcp-gateway` over stdio (zygos talking to zygos).
