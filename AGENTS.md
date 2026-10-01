# Working in this repo (all agents)

Read `GOAL.md` first — it is the mission brief and defines success criteria,
non-goals, gates, and your decision authority. Architecture sketch:
`docs/ARCHITECTURE.md`. Implemented trust boundaries and operator contracts:
`documentation/`. Wire format: `docs/PROTOCOL.md` (source of truth; human-gated).
Operating prohibitions (what not to weaken): `CLAUDE.md`.

The rules below stay in force. Do not delete them to shorten this file.
`CLAUDE.md` repeats the prohibitions for this checkout; `.gitignore` keeps
it untracked. The tracked copy is here.

## Do not weaken

- No new `build.zig.zon` entry, no `docs/PROTOCOL.md` edit, no deploys. Those are human gates in `GOAL.md`.
- Do not edit `GOAL.md` success criteria so code looks compliant.
- Policy, gate, and budget failures deny or stop. Do not default them to allow, approve, or continue.
- File tools stay inside `Workspace.resolve`. Bash is a shell with workspace cwd, not a jail.
- `web_fetch` stays http(s) with a host. Brave keys resolve in `searchConfigFromEnv`, not inside `web_tools`.
- `zig build test` stays offline: no real catalog, vault, or network.

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
zig fmt build.zig src/ test/   # format before committing
```

When touching `src/worker/filter/*`, `src/worker/trim.zig` or
`src/worker/trim/*`, also run:

```bash
./test/probe/filter/run.sh   # real commands through the real filters, with a ratio floor
./test/mutation/guards.sh    # each guard must fail the suite when deleted
./test/e2e/m8/run.sh         # the seam over real git output
```

Why these exist: M8 shipped three defects behind a fully green suite (filters
inert in production, tool output corrupted into invalid JSON, and prose read as
a failed command — twice). Unit tests prove the algorithm; only real command
output proves the wiring and the ratio.

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
- Commit only with `zig build test` green and `zig fmt --check build.zig src/ test/` clean.

## Version

The semver is `.version` in `build.zig.zon`. The history is `CHANGELOG.md`. The agent that changes operator-visible behavior edits both files in that same commit. The Zygos binary does not write them.

- A fix of existing behavior increments patch (`1.4.2` → `1.4.3`). Section: `Fixed`.
- A compatible new capability increments minor and resets patch (`1.4.3` → `1.5.0`). Section: `Added` or `Changed`.
- A break in a contract an operator or a connected worker already had increments major and resets the rest (`0.9.1` → `1.0.0`, `1.4.2` → `2.0.0`). Section: `Breaking`.
- The highest bump in the commit wins. One such commit, one new heading, dated with the commit date, inserted above the previous heading.
- `test`, `refactor`, `docs`, `chore`, a behavior-preserving move, and a test-only commit leave the number and the changelog alone.

Changing `.version` is the existing version field. It is not a new dependency entry. Leave `.fingerprint` and `.dependencies` alone.

Apply the number in the same session, including a major bump. Do not stop to ask which component to increment.

## Module map (M0)

```
src/
  root.zig               public module root; imports kernel/*
  main.zig               binary entry (thin; kernel wiring only)
  kernel/
    protocol.zig         wire types + parse/serialize   (S1)
    types.zig            shared WorkerId/Uuid identity types
    sync.zig             pthread mutex/condvar/event (Zig 0.16 has no
                         std.Thread primitives; std.Io ones barred by Z-02)
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

<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **zygos** (552 symbols, 546 relationships, 0 execution flows). Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

> Index stale? Run `node .gitnexus/run.cjs analyze` from the project root — it auto-selects an available runner. No `.gitnexus/run.cjs` yet? `npx gitnexus analyze` (npm 11 crash → `npm i -g gitnexus`; #1939).

## Always Do

- **MUST run impact analysis before editing any symbol.** Before modifying a function, class, or method, run `impact({target: "symbolName", direction: "upstream"})` and report the blast radius (direct callers, affected processes, risk level) to the user.
- **MUST run `detect_changes()` before committing** to verify your changes only affect expected symbols and execution flows. For regression review, compare against the default branch: `detect_changes({scope: "compare", base_ref: "main"})`.
- **MUST warn the user** if impact analysis returns HIGH or CRITICAL risk before proceeding with edits.
- When exploring unfamiliar code, use `query({search_query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol — callers, callees, which execution flows it participates in — use `context({name: "symbolName"})`.
- For security review, `explain({target: "fileOrSymbol"})` lists taint findings (source→sink flows; needs `analyze --pdg`).

## Never Do

- NEVER edit a function, class, or method without first running `impact` on it.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis.
- NEVER rename symbols with find-and-replace — use `rename` which understands the call graph.
- NEVER commit changes without running `detect_changes()` to check affected scope.

## Resources

| Resource | Use for |
|----------|---------|
| `gitnexus://repo/zygos/context` | Codebase overview, check index freshness |
| `gitnexus://repo/zygos/clusters` | All functional areas |
| `gitnexus://repo/zygos/processes` | All execution flows |
| `gitnexus://repo/zygos/process/{name}` | Step-by-step execution trace |

## CLI

| Task | Read this skill file |
|------|---------------------|
| Understand architecture / "How does X work?" | `.claude/skills/gitnexus/gitnexus-exploring/SKILL.md` |
| Blast radius / "What breaks if I change X?" | `.claude/skills/gitnexus/gitnexus-impact-analysis/SKILL.md` |
| Trace bugs / "Why is X failing?" | `.claude/skills/gitnexus/gitnexus-debugging/SKILL.md` |
| Rename / extract / split / refactor | `.claude/skills/gitnexus/gitnexus-refactoring/SKILL.md` |
| Tools, resources, schema reference | `.claude/skills/gitnexus/gitnexus-guide/SKILL.md` |
| Index, status, clean, wiki CLI commands | `.claude/skills/gitnexus/gitnexus-cli/SKILL.md` |

<!-- gitnexus:end -->
