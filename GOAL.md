---
# ── enforced by the orchestrating agent; implementation agents cannot override ──
mission: zygos
created: 2026-07-06
status: active
milestone: M2
budget:
  delegate_max_time_s: 900
  max_parallel_coding_agents: 2
gates:                              # require Mauricio's explicit ok
  new_dependency: human             # any entry in build.zig.zon
  protocol_change: human            # any edit to docs/PROTOCOL.md
  external_actions: human           # publishing, network services, deploys
escalation:
  test_fail_threshold: 3            # same test red after 3 delegated attempts → stop, redesign
---

# Mission: Zygos

This file is the **goal prompt**. Any agent working in this repo reads this first,
then `AGENTS.md` (how to work), then `docs/ARCHITECTURE.md` and `docs/PROTOCOL.md`
(what to build). The full design rationale lives in the Obsidian vault at
`poe.md/Projects/Zygos/DESIGN.md`; this repo is self-contained without it.

## Objective

Build **Zygos**: a single-binary agent harness in Zig. It reimplements the iii
engine kernel — workers connect over WebSocket and register *functions* and
*triggers* on one message bus — and ships harness capabilities (turn loop,
provider routing, policy, approvals, budget, memory) as replaceable workers.
Its end state runs a continuous **mission loop**: role agents (product-owner,
planner, executor, verifier) iterating on the GSD artifact substrate until an
objective completes, each step routable to a different model/provider.

## Success criteria — milestone M0 (the kernel)

| # | Criterion | Verified by |
|---|-----------|-------------|
| S1 | All iii protocol messages round-trip (parse → serialize → parse, byte-equivalent semantics) | `zig build test` — `kernel/protocol.zig` tests, incl. every message type and malformed-input rejection |
| S2 | Function catalog: last-registration-wins; CAS-gated teardown (a stale worker's disconnect never evicts a fresher registration) | `zig build test` — catalog tests incl. reconnect-churn scenario |
| S3 | Invocation router: UUID-correlated request/response; deferred completion; timeout produces an ErrorBody, not a hang | `zig build test` — invocation tests incl. timeout + late-result-after-timeout |
| S4 | Trigger registry: type re-registration replays existing bindings; connection-owned triggers GC'd on disconnect, durable bindings survive | `zig build test` — trigger tests |
| S5 | Keyed byte channels: single-consumer take semantics, access-key gating, TTL sweep | `zig build test` — channel tests |
| S6 | End-to-end: the unmodified **iii Node SDK** connects to a running Zygos kernel, registers a function, and invokes another worker's function successfully | `test/e2e/node-sdk/` script; documented run in README |

## Success criteria — milestone M1 (the turn loop)

M0 closed 2026-07-07 (all S1–S6 green; see README). M1 criteria approved by
Mauricio 2026-07-07.

| # | Criterion | Verified by |
|---|-----------|-------------|
| T1 | In-process workers ride the same bus semantics as WS workers: frame-path registration/invocation, no kernel special-casing beyond delivery; kernel Waiter completions carry real payloads | `zig build test` — inproc worker register/invoke round-trip through the actor |
| T2 | Turn FSM: `provisioning → streaming → dispatching → awaiting_approval → steering → stopped\|failed`; every legal transition tested, illegal transitions rejected as errors | `zig build test` — table-driven FSM tests |
| T3 | provider-anthropic: incremental SSE decoding → channel deltas + assembled terminal message (stop_reason, usage, tool_use with accumulated input JSON); malformed SSE never crashes | `zig build test` — decoder/assembler tests over recorded fixtures, no network |
| T4 | Tool dispatch: model `tool_use` → bus invocation of the named tool function → `tool_result` fed into the next step's messages | `zig build test` — turn tests with fake provider + fake tool |
| T5 | agent-tools worker: `zygos::tools::{bash,read_file,write_file}` registered on the bus, workspace-root confined (path escapes rejected) | `zig build test` — tools tests |
| T6 | e2e: a scripted 2-step tool-use turn (fake provider streaming deltas over a kernel channel) completes and stops cleanly | `test/e2e/turn/` script; documented run in README |

M1 notes: the approval worker is M2 — `awaiting_approval` exists in the FSM and
is tested, the M1 driver auto-approves through it. The real Anthropic HTTP/SSE
client lands in `src/net/` (Z-02 amendment covers it) but is exercised only by
an env-gated manual smoke (`ANTHROPIC_API_KEY`), never by `zig build test`.

## Success criteria — milestone M2 (policy + routing)

M1 closed 2026-07-07 (all T1–T6 green; see README). M2 criteria drafted
2026-07-07 from the ARCHITECTURE.md M2 line, under Mauricio's `/goal` directive
to implement M2 — **pending Mauricio's ratification** (GOAL.md edits are
human-gated; flag stands until he ok's this table).

| # | Criterion | Verified by |
|---|-----------|-------------|
| U1 | Fail-closed policy gate: when a `policy_function` rides the turn request, every tool dispatch consults it first; `deny` ⇒ is_error tool_result (turn continues); `ask` ⇒ approval path; missing worker, malformed verdict, or handler error ⇒ deny — never dispatch | `zig build test` — policy worker tests + turn-driver fail-closed tests |
| U2 | Approval worker: `zygos::approvals::{request,resolve,pending}`; an `ask` verdict blocks the turn in `awaiting_approval` on a real bus call until resolved (unresolved timeout ⇒ deny); `zygos::turns::abort` stops a running turn at the next boundary | `zig build test` — approval worker + turn integration tests |
| U3 | Per-step routing: `zygos.zon` config parsed at startup; `zygos::models::resolve(step_id, attempt)` returns `{provider_function, model}`; the driver resolves each step and retries a failed provider with `attempt+1` until routes exhaust (then the turn fails) | `zig build test` — router tests incl. failover turn |
| U4 | provider-openai: incremental chat-completions SSE decoding → channel deltas + assembled terminal message in the provider-neutral shape (finish_reason mapping, tool_calls with accumulated arguments JSON, usage); malformed SSE never crashes | `zig build test` — assembler tests over recorded fixtures, no network |
| U5 | Budget enforcement: `zygos::budget::{configure,record,check}` per-scope counters; the driver records provider usage each step and stops with `stop:"budget_exhausted"` when the scope is over limit; a configured-but-unreachable budget worker also stops the turn (fail closed) | `zig build test` — budget worker + turn tests |
| U6 | output-trim (Z-09): `zygos::output::compress` worker head/tail-trims oversized tool output and reports bytes saved via `zygos::budget::record`; e2e: a scripted turn through policy→approval→routing→budget→trim completes and stops cleanly | `zig build test` + `test/e2e/m2/` script; documented run in README |

M2 notes: `zygos::turns::steer` merges mid-turn input into the next step's
messages (the FSM's steering path, driver-exposed). The real openai-compat
HTTP client lands in `src/net/` under the Z-02 amendment, exercised only by an
env-gated manual smoke (`OPENAI_API_KEY`), never by `zig build test`.

Later milestones (M3 mission loop, M4 Tessera) get their own criteria tables
when M2 closes; do not start them early.

## Non-goals

- No iii console/UI clone. Observability lands as OTel + logs first.
- No worker registry service (`workers.iii.dev` equivalent). Local `worker add` only.
- No Windows support in v1. macOS + Linux.
- No protocol divergence from iii's wire format — extensions are new `zygos::*` functions, never changed frames.
- No microVM sandbox in M0–M2.
- No use of Zig async/`std.Io` concurrency — kernel actor + threads (decision Z-02).

## Constraints

- **Zig 0.16.0** (the installed toolchain). Code must build warning-clean with it.
- **TDD, strictly.** Tests are written first from the spec, fail red, then implementation
  turns them green. A commit that adds behavior without a test that demanded it is wrong.
- **Dependencies:** M0 kernel modules use `std` only, except the WebSocket/HTTP layer,
  which may use `karlseguin/websocket.zig` + `karlseguin/http.zig` — but adding them
  triggers the `new_dependency` gate.
- **Wire truth:** `docs/PROTOCOL.md` is the single source of truth for frames. Code
  conforms to it, never the other way (changes gated).
- **Memory discipline:** arena per invocation/turn; GPA with leak detection in tests;
  no hidden global allocators.

## Decision authority (for coding agents in this repo)

| Tier | Meaning | Examples |
|------|---------|----------|
| Decide & log (commit message) | Implementation agent decides | internal data structures, test organization, helper naming, error-set granularity |
| Decide & flag (in final report) | Decide, but surface it | deviations from ARCHITECTURE.md module layout, new public API on a kernel module, skipping an edge case with rationale |
| Escalate (stop, report, don't do) | Orchestrator/human decides | anything in `gates:` above, changing PROTOCOL.md or this file, disabling/deleting a test to get green, cross-module refactors |

## Amendments

Append-only. Human-written.
- 2026-07-07 (Mauricio, via session decision): Z-02 scoped exception — `std.Io.Threaded`
  (the blocking OS-thread Io implementation, not async) is permitted in `src/net/` only,
  because karlseguin/websocket.zig migrated to the std.Io interface. Kernel modules
  (`src/kernel/*`) remain std.Io-free; the actor boundary insulates them. Rationale
  discussed and accepted: churn exposure confined to one file + the pinned dep.
