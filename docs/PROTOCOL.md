# Zygos wire protocol (iii-compatible)

**This document is the single source of truth for frames.** Code conforms to it.
Changing it requires the `protocol_change` human gate (see GOAL.md). It transcribes
the iii engine's protocol (`engine/src/protocol.rs` in `~/Projects/iii`, v0.21.x) —
compatibility with the unmodified iii SDKs is milestone M0's exit test.

## Transport

- WebSocket. **Messages are JSON text frames** — one JSON object per frame.
- Binary frames are **reserved for telemetry**, dispatched by a 4-byte magic prefix:
  `OTLP` (traces), `MTRC` (metrics), `LOGS` (logs). A binary frame without a known
  magic falls back to JSON decode. M0 may stub telemetry (accept + drop).
- On connect, the engine assigns the worker a UUID and sends `workerregistered`.

## Envelope

Every message is a tagged union: field `"type"` holds the **lowercased variant
name, no separators** (`registerfunction`, not `register_function`). All other
fields are top-level siblings of `type`, snake_case.

## Message types

### Engine ← Worker (registration)

```jsonc
{"type":"registerservice","id":"svc-1","name":"my-svc","description":"...","parent_service_id":null}

{"type":"registerfunction","id":"content::classify","description":"...",
 "request_format":{/* JSON schema, optional */},"response_format":{/* optional */},
 "metadata":{/* optional */},
 "invocation":null}
// "invocation" may instead be an external-HTTP ref (function served by HTTP, not WS):
// {"url":"https://...","method":"POST","timeout_ms":30000,"headers":{},"auth":null}

{"type":"unregisterfunction","id":"content::classify"}

{"type":"registertriggertype","id":"cron","description":"...",
 "trigger_request_format":null,"call_request_format":null}

{"type":"registertrigger","id":"t-1","trigger_type":"cron",
 "function_id":"jobs::nightly","config":{"schedule":"0 3 * * *"},"metadata":null}

{"type":"unregistertrigger","id":"t-1","trigger_type":"cron"}   // trigger_type optional
```

### Engine → Worker (registration acks)

```jsonc
{"type":"workerregistered","worker_id":"<uuid>"}

{"type":"triggerregistrationresult","id":"t-1","trigger_type":"cron",
 "function_id":"jobs::nightly","error":null}
// error, when present: {"code":"...","message":"...","stacktrace":null}
```

### Invocation (both directions)

```jsonc
{"type":"invokefunction",
 "invocation_id":"<uuid, optional — absent = fire-and-forget>",
 "function_id":"orders::validate",
 "data":{/* arbitrary JSON */},
 "traceparent":"00-<32hex>-<16hex>-01",   // optional
 "baggage":"zygos.session.id=...,...",     // optional
 "action":null,                             // optional TriggerAction, see below
 "metadata":null}

{"type":"invocationresult",
 "invocation_id":"<uuid>",
 "function_id":"orders::validate",
 "result":{/* present on success */},
 "error":null,                              // or ErrorBody — result and error are mutually exclusive
 "traceparent":"...","baggage":"..."}
```

`TriggerAction` (the `action` field) redirects call semantics:

```jsonc
{"type":"enqueue","queue":"orders"}   // enqueue onto a function queue instead of direct dispatch
{"type":"void"}                        // fire-and-forget
```

### Keepalive

```jsonc
{"type":"ping"}
{"type":"pong"}
```

### Sub-types

```jsonc
// ErrorBody
{"code":"function_not_found","message":"...","stacktrace":null}

// StreamChannelRef — capability handle for byte channels (rides inside payloads)
{"channel_id":"<id>","access_key":"<secret>","direction":"read"}   // or "write"
```

## Semantics the kernel must honor

1. **Correlation.** `invocation_id` pairs an `invokefunction` with its
   `invocationresult`. The engine parks a pending entry on dispatch and completes
   it when the result arrives. Unknown/duplicate `invocation_id` results are
   logged and dropped, never crash.
2. **Last registration wins.** Registering an already-registered function id
   overwrites the handler (warn, don't error).
3. **CAS-gated teardown.** The engine tracks `function_id → owner worker UUID`.
   On worker disconnect, a registration is removed **only if** the departing
   worker is still the recorded owner. A faster reconnect that re-registered
   first must not be evicted by the stale connection's cleanup.
4. **Trigger-type replay.** Re-registering a trigger type replays all existing
   bindings of that type to the new registrator (provider-reconnect support).
5. **Trigger ownership.** Triggers registered with a `worker_id` owner
   (connection-owned) are GC'd when that connection drops; ownerless (durable)
   bindings survive disconnects.
6. **Registration acks.** Function-path trigger registrations wait for
   `triggerregistrationresult` with a 10s timeout; connection-owned lifecycle
   bindings are fire-and-forget (awaiting inline would deadlock the read loop).
7. **Trace context.** `traceparent`/`baggage` pass through opaquely and must be
   preserved end-to-end across dispatch, enqueue, and result paths.
8. **Channels.** `channel_id` + `access_key` gate access; each endpoint
   (sender/receiver) may be taken **exactly once**; direction is enforced;
   idle channels are TTL-swept (default 5 min); owner disconnect reaps.

## Client channel bridge (HTTP surface, M0-optional)

`GET /ws/channels/{channel_id}?key=<access_key>&dir=read|write` upgrades to a WS
that drains (read) or feeds (write) the channel, one frame per item, Close when
the other side drops.
