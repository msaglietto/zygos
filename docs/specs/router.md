# Spec: `src/worker/router.zig` — zygos.zon per-step model routing (U3)

An inproc worker registering `zygos::models::resolve`. Routing truth is a
`zygos.zon` file (ZON, parsed with `std.zon.parse` at startup — no JSON here;
the config is operator-authored).

## Config shape

```zon
.{
    .default = .{
        .{ .provider_function = "zygos::provider::anthropic::messages", .model = "claude-sonnet-5" },
    },
    .routes = .{
        .{
            .step_id = "plan",
            .attempts = .{
                .{ .provider_function = "zygos::provider::anthropic::messages", .model = "claude-opus-4-8" },
                .{ .provider_function = "zygos::provider::openai::messages", .model = "gpt-x" },
            },
        },
    },
}
```

`attempts` is the escalation ladder: attempt N uses entry N; N beyond the end
⇒ `route_exhausted` (the caller fails its turn). Unknown `step_id` falls back
to `default` (same exhaustion rule). Empty/absent `default` + unknown step ⇒
`route_exhausted` on attempt 0.

## Function

`zygos::models::resolve` — `{"step_id":"plan","attempt":1}` →
`{"provider_function":"...","model":"..."}`; exhausted ⇒ reply
`{"error":"route_exhausted"}` (a reply, not a bus error — the driver
distinguishes "no more routes" from "router is down", both of which fail the
turn but with different reasons).

## API

- `Config.parse(gpa, zon_text) !Config` / `deinit` — std.zon.parse into
  owned memory. (There is deliberately no `Config.load(path)` — file IO
  stays in the binaries; callers read the file and pass the text.)
- `RouterWorker.start(gpa, actor, registry, config)`.

## Test contract (RED first)

1. `parse: routes + default from ZON text`
2. `resolve: known step attempt 0 and 1 return the ladder entries`
3. `resolve: attempt past the ladder ⇒ route_exhausted`
4. `resolve: unknown step falls back to default`
5. `resolve: unknown step, no default ⇒ route_exhausted`
6. `malformed request ⇒ route_exhausted reply (not handler failure)`
7. `malformed ZON ⇒ parse error, no leaks`
8. `no leaks under resolve loops`

Driver-side failover (provider fails → attempt+1 → different provider) is
tested in `turn.zig`.
