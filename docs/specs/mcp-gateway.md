# Spec: mcp-gateway — MCP stdio bridge to `zygos::tessera::*` (W6, M4)

An external MCP client (Claude Code, any MCP host) speaks JSON-RPC 2.0 over
stdio to a Zygos process and reaches the tessera workers on the bus. `std`
only — no MCP lib, no new dependency. Exposes EXACTLY the `zygos::tessera::*`
functions as MCP tools, nothing else; unknown tool or bus error is a JSON-RPC
error, never a guess (fail closed).

Two layers:
- `src/worker/mcp/gateway.zig` — pure message handling: bytes in → optional
  bytes out, bus calls through an injected caller vtable. NO stdio here; fully
  unit-testable.
- binary glue (main.zig subcommand `zygos mcp-gateway`, wired by the
  orchestrator, not delegated): libc stdin/stdout line loop feeding the pure
  layer, plus kernel + tessera worker startup from config.

## Tool table (static — the bridge IS the allowlist)

| MCP tool name | Bus function |
|---|---|
| `tessera_project_status` | `zygos::tessera::project_status` |
| `tessera_open_threads` | `zygos::tessera::open_threads` |
| `tessera_stale_projects` | `zygos::tessera::stale_projects` |
| `tessera_reflect` | `zygos::tessera::reflect` |
| `tessera_session_open` | `zygos::tessera::session_open` |
| `tessera_session_close` | `zygos::tessera::session_close` |
| `tessera_capture` | `zygos::tessera::capture` |
| `tessera_checkpoint` | `zygos::tessera::checkpoint` |
| `tessera_undo` | `zygos::tessera::undo` |

Each tool's `inputSchema` is a permissive `{"type":"object"}` in W6 — the
workers validate their own requests fail-closed; duplicating their schemas
here would drift.

> Note: the **inverse direction** — consuming *external* MCP servers' tools
> onto the bus as `zygos::mcp::<server>::<tool>` — lives in
> `src/worker/mcp/client.zig` and currently has **no spec doc** (README
> "MCP servers as tool providers" is its only prose). Flagged 2026-07-18.

## Pure layer API

```zig
pub const Caller = struct {
    ctx: *anyopaque,
    /// Mirrors inproc.Worker.call's result shape: ok payload or error code.
    /// The arena owns the reply bytes for the duration of `handle`.
    callFn: *const fn (ctx: *anyopaque, function: []const u8, request_json: []const u8, arena: std.mem.Allocator) CallError!Result,
};

/// One JSON-RPC message in (a single line, LSP-style framing NOT used — MCP
/// stdio transport is newline-delimited JSON), reply out. Null = no reply
/// (notifications). Arena-owned.
pub fn handle(arena: std.mem.Allocator, caller: Caller, line: []const u8) error{OutOfMemory}!?[]const u8;
```

Framing: newline-delimited JSON per MCP stdio transport. Behavior:

- `initialize` → result `{protocolVersion:"2025-06-18", capabilities:{tools:{}},
  serverInfo:{name:"zygos-mcp-gateway", version:...}}`. Echo the client's
  requested protocolVersion if it is one we know, else ours.
- `notifications/initialized` (and any notification) → null, no reply.
- `tools/list` → the 9 tools above, name + description + inputSchema.
- `tools/call` → look up `params.name` in the table; miss ⇒ JSON-RPC error
  -32602. Hit ⇒ bus-call with `params.arguments` serialized as the request
  JSON (absent arguments ⇒ `{}`). Bus ok ⇒ result
  `{content:[{type:"text",text:<payload>}],isError:false}`. Bus error ⇒
  JSON-RPC error -32000 carrying the bus error code (fail closed — never a
  fabricated tool result).
- Malformed JSON ⇒ error -32700; not an object / missing method ⇒ -32600;
  unknown method ⇒ -32601. All error replies carry the request id when one
  parsed, else null id.
- Requests must never crash the loop: any handler failure other than OOM
  becomes a JSON-RPC error reply.

## Test contract (RED first) — pure layer, fake Caller, no stdio, no network

1. `initialize replies with tools capability and echoes a known protocolVersion`
2. `notifications produce no reply`
3. `tools/list returns exactly the 9 tessera tools`
4. `tools/call routes to the mapped bus function with arguments as request JSON`
5. `tools/call with no arguments sends {}`
6. `unknown tool name is -32602; nothing bus-called`
7. `bus error surfaces as -32000 with the code; never a result`
8. `parse error -32700, bad request -32600, unknown method -32601, ids preserved`
9. `no leaks`

## e2e (`test/e2e/m4/run.sh`, orchestrator-wired)

One process runs kernel + tessera workers + a scripted-provider mission with
the W3 continuity seam pointed at a temp vault; the mission reaching `done`
auto-logs a SESSIONS.md entry. Then a separate MCP client process (the script,
speaking newline-JSON over the gateway subcommand's stdio) does
initialize → tools/list → tools/call `tessera_project_status` and asserts the
reply contains that same session entry. Documented in README like m2/m3.
