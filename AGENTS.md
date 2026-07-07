# Working in this repo (all agents)

Read `GOAL.md` first — it is the mission brief and defines success criteria,
non-goals, gates, and your decision authority. Architecture: `docs/ARCHITECTURE.md`.
Wire format: `docs/PROTOCOL.md` (source of truth; human-gated).

## TDD is the law here

1. **Red first.** Write the test from the spec (PROTOCOL.md / ARCHITECTURE.md /
   the task prompt), run `zig build test`, watch it fail for the right reason.
2. **Green.** Implement the minimum that passes.
3. **Refactor** with tests green.
4. Never delete, skip, or weaken a test to get green — that's an escalation,
   not a fix (see GOAL.md decision authority).

Tests live in `test` blocks inside each module file. Every kernel module has a
matching exhaustive test section. Edge cases from PROTOCOL.md ("Semantics the
kernel must honor") each get a named test.

## Commands

```bash
zig build            # compile
zig build test       # the check that matters — must be green before any commit
zig fmt src/         # format before committing
```

## Conventions

- Zig 0.16.0. `std` only for kernel modules (deps are human-gated, see GOAL.md).
- Allocators are always passed in, never global. Tests use
  `std.testing.allocator` (leak-checking) — a leaking test is a failing test.
- Errors: explicit error sets per module; no `anyerror` in public signatures.
- Naming: types `PascalCase`, functions/fields `snake_case` per Zig std style.
- Comments state constraints the code can't (wire invariants, ownership rules) —
  not narration.

## Commits

- Conventional commits, scoped by module: `feat(kernel/protocol): ...`,
  `test(kernel/catalog): ...`, `chore(build): ...`.
- Test-first history is welcome: a `test(...)` commit followed by `feat(...)`.
- **No Co-Authored-By trailers. No AI attribution in commit messages.**
- Commit only with `zig build test` green and `zig fmt --check src/` clean.

## Module map (M0)

```
src/
  root.zig               public module root; imports kernel/*
  main.zig               binary entry (thin; kernel wiring only)
  kernel/
    protocol.zig         wire types + parse/serialize   (S1)
    catalog.zig          function registry, owner CAS   (S2)
    invocation.zig       pending map, timeouts          (S3)
    trigger.zig          trigger types + bindings       (S4)
    channel.zig          keyed byte channels            (S5)
    actor.zig            kernel inbox, command loop     (wires S2–S5)
  net/
    ws.zig               WebSocket server loop          (dep-gated)
```

Keep modules independent: `protocol.zig` knows nothing of the catalog;
`catalog.zig`/`invocation.zig`/`trigger.zig`/`channel.zig` know nothing of
sockets. Only `actor.zig` and `net/` compose them.
