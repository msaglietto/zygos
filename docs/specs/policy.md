# Spec: `src/worker/policy.zig` — fail-closed policy gate (U1)

An inproc worker registering `zygos::policy::check`. The turn driver consults
it before **every** tool dispatch when the turn request names a
`policy_function`. The gate itself is a rule table; the fail-closed property
lives in *both* halves: the worker's default verdict is `deny`, and the driver
treats every failure mode (missing function, bus error, malformed reply) as
`deny`.

## Request / reply

```jsonc
// request
{"tool":"bash", "function_id":"zygos::tools::bash", "input":{...}}
// reply
{"verdict":"allow"|"deny"|"ask", "reason":"matched rule 2"}
```

## Rules

`PolicyWorker.start(gpa, actor, registry, rules)` takes an ordered slice of

```zig
pub const Verdict = enum { allow, deny, ask };
pub const Rule = struct {
    /// Matched against the request's `tool` name; supports a trailing '*'
    /// glob ("zygos::tools::*" matches by function_id prefix too).
    tool: []const u8,
    verdict: Verdict,
};
```

First matching rule wins — match `tool` exactly, or `function_id` when the
pattern contains "::", with a trailing `*` doing prefix match. **No rule
matches ⇒ `deny`** (the fail-closed default), reason "no rule matched".

## Test contract (RED first)

1. `allow rule matches by tool name` → verdict allow
2. `first matching rule wins` (allow before deny for same tool)
3. `trailing-star glob matches function_id prefix`
4. `no rule matched ⇒ deny` — the fail-closed default
5. `ask verdict round-trips`
6. `malformed request (no tool) ⇒ deny reply, handler does not fail`
7. `no leaks under repeated checks`

Driver-side fail-closed tests live in `turn.zig` (see turn spec § policy).
