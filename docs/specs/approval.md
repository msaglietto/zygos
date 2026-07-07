# Spec: `src/worker/approval.zig` — approval/question worker (U2)

An inproc worker owning the human-in-the-loop seam. The turn driver blocks in
`awaiting_approval` on a real `zygos::approvals::request` bus call; a UI (or a
test thread) answers via `zygos::approvals::resolve`.

## Functions

- `zygos::approvals::request` — blocking. Request
  `{"tool":"bash","input":{...},"reason":"policy ask"}`; the worker assigns an
  approval id, parks the invocation, and replies only when resolved:
  `{"approved":true|false,"id":"a-1"}`.
- `zygos::approvals::resolve` — `{"id":"a-1","approved":true}` →
  `{"resolved":true}`; unknown id → `{"resolved":false}`.
- `zygos::approvals::pending` — `{}` →
  `{"pending":[{"id":"a-1","tool":"bash","reason":"..."}]}`.

## Modes

`ApprovalWorker.start(gpa, actor, registry, mode)`:

```zig
pub const Mode = union(enum) {
    manual: struct { timeout_ms: ?u64 = null }, // park until resolve; timeout ⇒ denied
    auto_approve,                                // reply approved immediately
    auto_deny,                                   // reply denied immediately
};
```

Manual mode with `timeout_ms` denies unresolved requests after the deadline
(fail closed — an unanswered question is a "no"). Worker stop denies all
parked requests before joining.

## Ids

Sequential (`a-1`, `a-2`, …) under the worker's mutex — deterministic for
tests and `pending` consumers.

## Test contract (RED first)

1. `auto_approve replies approved`
2. `auto_deny replies denied`
3. `manual: request parks until resolve(approved:true) → approved`
4. `manual: resolve(approved:false) → denied`
5. `manual: pending lists the parked request; empty after resolve`
6. `manual with timeout_ms: unresolved request denies after deadline`
7. `resolve with unknown id → resolved:false`
8. `no leaks under park/resolve loops`

Turn-side integration (ask verdict → awaiting_approval → dispatch/deny) is
tested in `turn.zig`.
