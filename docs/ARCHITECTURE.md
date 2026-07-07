# Zygos architecture (condensed)

Full rationale lives in the vault (`poe.md/Projects/Zygos/DESIGN.md`). This is
the working summary for agents in this repo.

## Layers

```
Layer 3  ADAPTERS      gsd mission loop · tessera-mnemis · mcp-gateway
Layer 2  HARNESS       turn-orchestrator · provider-* · model-router · policy ·
                       approval-gate · llm-budget · hook-fanout · session-store ·
                       context-compaction · agent-tools · mission-orchestrator
Layer 1  BUILT-IN      state · queue · cron · http · pubsub · observability
Layer 0  KERNEL (M0)   WS server · function catalog · invocation router ·
                       trigger registry · byte channels
```

Everything above Layer 0 is a *worker*: it registers functions/triggers on the
bus and is replaceable by any process speaking the wire protocol. Layer 1–2
workers are Zig, in-process, but use the same registration API as external
workers.

## Kernel concurrency model (decision Z-02)

- **Kernel actor:** ALL registry mutation (catalog, owners, triggers, pending
  invocations) happens on one kernel thread draining an MPSC command inbox.
  No shared-state locking across registries; no Zig async.
- **Thread per connection:** each worker WS connection = a reader thread
  (parse frame → post command to kernel inbox) + a writer drained from a
  bounded queue (cap 64, mirrors iii).
- **Channels:** mutex + condvar ring buffers; endpoints taken exactly once.
- **Memory:** arena per invocation; `std.testing.allocator` in tests makes
  leaks failures.

Kernel modules stay socket-free and composable; see module map in `AGENTS.md`.
The five kernel invariants that must never regress are S1–S5 in `GOAL.md`,
specified in detail in `docs/PROTOCOL.md` § "Semantics the kernel must honor".

## Why wire-compatible with iii (decision Z-01)

The existing iii SDKs (Node/Python/Rust/Go) then work as Zygos worker SDKs
unmodified — M0's exit test (S6) proves it with the Node SDK. Extensions are
new `zygos::*` bus functions, never frame changes.

## What comes after M0 (do not start early)

- **M1**: turn FSM (`provisioning → streaming → dispatching → awaiting_approval
  → steering → stopped|failed`), provider-anthropic (SSE→channel), agent-tools.
- **M2**: fail-closed policy gate, approval/question worker, `zygos.zon`
  per-step routing (`models::resolve(step_id, attempt)`), openai-compat
  provider, budget enforcement.
- **M3**: mission loop — durable mission FSM over the GSD `.planning/`
  substrate; product-owner/planner/executor/verifier role turns; hard gates.
- **M4**: Tessera workers (continuity/capture/orient/undo) + MCP gateway.
