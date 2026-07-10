---
mission: x5-dogfood
created: 2026-07-10
budget:
  max_tokens: 500000
gates:
  external_actions: human
escalation:
  test_fail_threshold: 3
---

# Mission: wordfreq — a single-purpose CLI tool

The X5 dogfood objective (GOAL.md M4.5): small, real, verifiable.

## Objective

Build `wordfreq`, a POSIX-shell script in this workspace: reads text on
stdin, prints the top N most frequent words (case-insensitive, punctuation
stripped) as `count word` lines, N from argv defaulting to 10. Include a
`test.sh` that pipes a known sentence through it and asserts the expected
output, exiting 0 on pass.

## Success criteria

| # | Criterion | Verified by |
|---|-----------|-------------|
| D1 | `wordfreq` exists and is executable | `test -x wordfreq` |
| D2 | top-N counting is correct on a known input | `./test.sh` exits 0 |
| D3 | N argument respected (default 10) | `./test.sh` covers both |

## Non-goals

- No language other than POSIX shell; no dependencies beyond coreutils.
- No file input mode, no flags beyond the single N argument.
