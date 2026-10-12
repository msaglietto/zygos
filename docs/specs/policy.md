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
{"tool":"bash", "function_id":"zygos::tools::bash", "step_id":"architect", "input":{...}}
// reply
{"verdict":"allow"|"deny"|"ask", "reason":"matched rule 2"}
```

`step_id` is the calling turn's step id; the driver always sends it (empty
string when the turn request has none).

## Rules

`PolicyWorker.start(gpa, actor, registry, rules)` takes an ordered slice of

```zig
pub const Verdict = enum { allow, deny, ask };
pub const Rule = struct {
    /// Matched against the request's `tool` name; supports a trailing '*'
    /// glob ("zygos::tools::*" matches by function_id prefix too).
    tool: []const u8,
    verdict: Verdict,
    /// Matched against the request's `step_id` with the same matcher as
    /// `tool` (exact, or trailing '*' prefix). Null matches every step.
    step: ?[]const u8 = null,
};
```

First matching rule wins. As built, each pattern is tried against **both**
the `tool` name and the `function_id` unconditionally (exact match, or
trailing-`*` prefix match) — the worker never inspects the pattern for `::`.
A rule without `step` matches every step. A rule with `step` matches only
when the request's `step_id` matches it; a request lacking `step_id` (absent
or empty) never matches a step-scoped rule, so it falls through to later
rules and finally to the default deny.
**No rule matches ⇒ `deny`** (the fail-closed default), reason "no rule
matched".

## Test contract (RED first)

1. `allow rule matches by tool name` → verdict allow
2. `first matching rule wins` (allow before deny for same tool)
3. `trailing-star glob matches function_id prefix`
4. `no rule matched ⇒ deny` — the fail-closed default
5. `ask verdict round-trips`
6. `malformed request (no tool) ⇒ deny reply, handler does not fail`
7. `no leaks under repeated checks`
8. `rule with step matches only that step`
9. `rule without step matches every step`
10. `step-scoped rule does not match a request without step_id`

Driver-side fail-closed tests live in `turn.zig` (see turn spec § policy),
including `the policy request carries step_id`.

**Known limit:** the mission CLI's policy seed (`mission_boot.policySeed`) is
still hard-coded allow with no operator config surface (see mission.md
"Known limit"). Per-step rules are expressible in the worker but not yet
configurable by an operator.
