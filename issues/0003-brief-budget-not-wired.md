---
title: Brief frontmatter budget.max_tokens is decorative — wire it into the budget scope
status: open
labels: [ready-for-agent]
created: 2026-07-25
origin: Y5 run .planning-20260725-040525 (zahir-radar vault) — brief declared
  2M tokens, mission died at the CLI's 1M default
---

# Brief frontmatter budget.max_tokens is decorative — wire it into the budget scope

## Problem Statement

W1 requires every mission brief to declare a `budget:` block, and the Y4
zahir-radar brief dutifully carries `budget.max_tokens: 2000000` — but
nothing reads it. The mission CLI configures the budget scope solely from
`ZYGOS_BUDGET_MAX_TOKENS` (default 1,000,000 in `mission_boot.zig`). The
first Y5 attempt declared 2M in the brief and was killed `budget_exhausted`
at 1,004,422 tokens: the operator-facing contract (the brief) and the
enforced value silently disagree. A lint that demands a budget key the
harness then ignores is worse than no lint — it teaches operators the
number matters when it doesn't.

## Solution

The brief's declared budget becomes the enforced budget, with the env var
as an explicit operator override.

- `worker/mission_boot.zig`: a pure parser extracts `max_tokens` from the
  frontmatter `budget:` block (top-level key, indented `max_tokens:` line,
  integer value; malformed or absent ⇒ null, never a boot failure — W1
  already guarantees the block exists).
- Precedence at budget-scope configure time (both the single-mission and
  queue paths in `cli/mission.zig`): `ZYGOS_BUDGET_MAX_TOKENS` if the env
  var is explicitly set → the brief's `budget.max_tokens` if parseable →
  the existing 1,000,000 default. Queue mode resolves per brief.

## Verified by

- pure-parser tests: value extracted; absent/malformed ⇒ null; nested
  under `budget:` only (a stray top-level `max_tokens:` is not a budget).
- precedence tests: env set beats brief; brief beats default; default
  survives both absent (named tests in `mission_boot.zig`).
