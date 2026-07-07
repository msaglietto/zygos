# Spec: `src/worker/budget.zig` — budget enforcement (U5)

An inproc worker registering `zygos::budget::{configure,record,check}`.
Scopes are arbitrary strings (a turn id, a mission id, "global"). Counters
are u64 saturating adds under one mutex.

## Functions

- `zygos::budget::configure` — `{"scope":"turn-1","max_tokens":1000}` →
  `{"ok":true}`. Re-configure resets counters for the scope.
- `zygos::budget::record` — `{"scope":"turn-1","kind":"input_tokens"|"output_tokens"|"saved_bytes","amount":N}`
  → `{"ok":true}`. Unknown scope auto-creates (unlimited unless configured);
  unknown kind is ignored (`{"ok":false}`). Designed to be `cast` — callers
  never block on accounting.
- `zygos::budget::check` — `{"scope":"turn-1"}` →
  `{"ok":bool,"used_tokens":N,"max_tokens":N|null,"saved_bytes":N}`.
  `ok` = used_tokens (input+output) < max_tokens; unconfigured scope is
  always ok (no limit), `max_tokens: null`.

## Test contract (RED first)

1. `configure + record + check round-trip; ok flips false at the limit`
2. `unconfigured scope: record accumulates, check ok with null max`
3. `re-configure resets counters`
4. `saved_bytes accumulates separately and never counts against tokens`
5. `unknown kind ⇒ ok:false, nothing recorded`
6. `malformed request ⇒ ok:false reply, not handler failure`
7. `concurrent records from two callers sum exactly`
8. `no leaks under record loops`

Driver-side enforcement (`stop:"budget_exhausted"`, fail-closed on
unreachable worker) is tested in `turn.zig`.
