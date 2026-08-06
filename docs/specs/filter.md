# Spec: command-aware output filters (M8, decision Z-09 second half)

> **Status: implemented 2026-08-06** (commits 3ddba50..a3eb78c). All of
> S8.1–S8.5 landed; measured 4026 → 538 bytes (86.6%) on the fixture corpus
> against the ≥60% exit floor. Modules: `src/worker/filter/{dispatch,guard,
> git,testrun,listing,buildlint,cache}.zig`, wired in `src/worker/trim.zig`.
>
> Two deviations from the draft below, both deliberate:
> - The error-signal guard is **not** part of the universal `shouldSkip`. It
>   lives in `shouldSkipOrErrored`, used by git/listing only. Folding it in
>   would have made `testrun`/`buildlint` no-ops on failing runs — exactly the
>   runs whose output matters most.
> - `test/e2e/m8/` was not added as a separate binary; the S8.5 ratio floor is
>   asserted in-process in `trim.zig` over the same corpus, which keeps the
>   evidence next to the code it measures.

`src/worker/trim.zig` implements the *generic* half of Z-09: ANSI strip,
blank-run collapse, head/tail elision. That is lossy in the middle and blind —
it drops the same fraction of a `git diff` as of a stack trace, and it cannot
tell a passing test suite from a failing one.

M8 adds the half Z-09 actually promised: **filters that know what produced the
output**. `git diff` keeps the hunks and drops the index/mode metadata;
`cargo test` with everything green becomes one line; `ls -la` becomes names
without permission bits. Errors, exit codes, and structured data are never
touched.

## Why Zygos can do this cleanly

ztk has to intercept via `PreToolUse` hooks and rewrite the command line,
because it sits outside the agent. Zygos owns the tool boundary — the turn
driver already calls `zygos::output::compress` on every ok tool result. The
filters are a worker behind that seam, not a shell wrapper.

---

## S8.1 — Seam context (the enabling change)

The current seam request is `{"content": <str>}`. A filter cannot dispatch on
that. Extend it, additively:

```json
{ "content": "<raw tool output>",
  "tool":    "bash",          // tool name from the turn's tool table
  "input":   { "command": "git diff HEAD~5" } }
```

- `tool` and `input` are **optional**. A request without them still works and
  gets the generic trim — every existing test stays green unchanged.
- The driver already has both at the call site (`turn.zig` `compressSeam`,
  called from the `.ok` arm where `tool_name` and `input` are in scope).
- **Raw escape hatch:** if the model's tool input carries `"raw": true`, the
  driver skips the seam entirely. An agent that needs exact bytes says so.
- Reply shape is unchanged: `{"content": <str>}`.

Not a `docs/PROTOCOL.md` change — `output::compress` is a Zygos function on the
bus, not an iii wire message. No human gate needed.

### Test contract
1. `seam request carries tool and input when the driver knows them`
2. `content-only request still trims (back-compat)`
3. `raw:true in tool input bypasses the seam (byte-identical output)`

---

## S8.2 — Filter dispatcher

`src/worker/filter/dispatch.zig` — a pure lookup, no I/O:

```zig
pub const Filter = *const fn (std.mem.Allocator, []const u8) error{OutOfMemory}!?[]const u8;

/// Null ⇒ no filter applies; caller falls back to the generic trim.
pub fn select(tool: []const u8, input_command: ?[]const u8) ?Filter;
```

Rules, in order:
1. `tool` is not `bash` ⇒ null (file reads etc. keep the generic path for now).
2. Tokenize `command`; take argv[0], **basenamed** so `/usr/bin/git` and
   `/opt/homebrew/bin/git` match `git` (ztk's path-qualified-executable
   lesson — an agent must not dodge compression by spelling a full path).
3. Match argv[0] (+ argv[1] where it disambiguates: `git diff` vs `git log`)
   against the filter table.
4. Shell metacharacters (`|`, `&&`, `;`, `` ` ``, `$(`) in the command ⇒ null.
   A pipeline's output is not the named command's output. Fail open.

**Composition:** filter output is then run through the existing generic
`trim()` as a backstop, so a filter that under-compresses still can't blow the
budget. A filter returning null ⇒ generic trim alone. Behavior is a superset of
today's; nothing regresses.

### Test contract
1. `select maps git/cargo/ls to their filters`
2. `path-qualified argv[0] still matches (/usr/bin/git)`
3. `unknown command ⇒ null ⇒ generic trim`
4. `piped command ⇒ null (fail open)`
5. `non-bash tool ⇒ null`

---

## S8.3 — The filters

One file per family, each with its own `test` block. Every filter is a **pure
function** `(arena, text) !?[]const u8` — null means "I looked and decided not
to touch this". No filter ever sees an errored tool result: the driver only
calls the seam on the `.ok` arm.

### Universal invariants (tested per filter)
- **Never touch error text.** If the output matches an error signal for that
  family (`error:`, `FAILED`, `panic`, `fatal:`, a nonzero-exit marker), the
  filter returns null and the raw text survives to the generic trim.
- **Small outputs pass through.** Under 80 bytes ⇒ null (ztk's threshold; not
  worth the risk).
- **Structured formats are sacred.** Output that parses as JSON ⇒ null.
- **Honest markers.** Anything dropped is announced in the same
  `[... zygos ... ]` style the generic trim uses, with counts.

| File | Covers | Keeps | Drops |
|---|---|---|---|
| `filter/git.zig` | `git diff`, `git log`, `git status` | hunk headers + `+`/`-` lines, commit subjects, changed paths | `index abc..def`, `old/new mode`, `similarity index`, context lines beyond 1, log bodies/authors |
| `filter/testrun.zig` | `zig build test`, `cargo test`, `pytest`, `go test`, `npm/pnpm/yarn test`, `jest`, `vitest` | every failure + its assertion/trace, the final tally line | per-test PASS lines, progress spinners, timing noise |
| `filter/listing.zig` | `ls`, `find`, `tree`, `wc`, `du` | file/dir **names** (bounded head), the total count | permission bits, owner/group, sizes, timestamps |
| `filter/buildlint.zig` | `zig build`, `cargo build/check`, `go build`, `tsc`, `eslint`, `ruff`, `clippy` | diagnostics (file:line:col + message), the summary line | progress/`Compiling …` lines, repeated notes, duplicate diagnostics with counts |

`filter/git.zig` is the highest-value one (ztk's own numbers: 92k → 18k on one
`git diff`) and lands first.

### Per-filter test contract (each file)
1. `<family> golden fixture compresses` — a recorded real output in
   `test/fixtures/filter/`, asserted against an expected compressed form
2. `error output passes through untouched (null)`
3. `output under 80 bytes ⇒ null`
4. `JSON output ⇒ null`
5. `dropped counts in the marker are accurate`
6. `no leaks (testing.allocator)`

---

## S8.4 — Session dedup cache

Z-09's third promise. Running `git status` three times unchanged should cost
one full output and two one-liners.

`src/worker/filter/cache.zig`, owned by `TrimWorker` (no new bus function):

- Key: `hash(tool ++ command)`. Value: `hash(raw output)` + timestamp.
- Repeat call, same key, same output hash, within TTL ⇒ reply
  `[... zygos: unchanged since <N>s ago; see the earlier result ...]`.
- Output differs ⇒ full filtered output, cache updated.
- TTL by command class: volatile (`git status`, `ls`) 30s; medium (test
  runners) 120s; slow (`git log`) 300s.
- **Mutating commands invalidate.** `git add`/`commit`/`checkout`, `write_file`
  ⇒ clear the whole cache. Correctness over hit rate.
- Bounded: 64 entries, LRU eviction. Cleared on `TrimWorker.stop`.

Reuses `context_recall.zig`'s TTL discipline rather than adding a `state`
worker (which does not exist).

### Test contract
1. `identical repeat within TTL ⇒ unchanged marker`
2. `changed output ⇒ full result, cache updated`
3. `expired TTL ⇒ full result`
4. `mutating command invalidates`
5. `cache bounded at 64 entries (LRU)`
6. `no leaks across many turns`

---

## S8.5 — Savings evidence

Z-09 said "savings report to `budget::record` (`rtk gain` for free)". The trim
worker already casts `saved_bytes`. M8 adds:

- `zygos::output::stats` → `{"calls":N,"raw_bytes":B,"sent_bytes":b,"by_filter":{...}}`
  so a mission's compression ratio is inspectable, and the mission-level budget
  ledger (M7) can print it at terminal state.
- A `test/e2e/m8/` script running a scripted turn whose tool outputs are the
  golden fixtures, asserting the end-to-end ratio clears a floor (**≥60%** on
  the fixture corpus — deliberately below ztk's 90% headline, which is measured
  over a command mix we do not control).

---

## Port vs depend

ztk is MIT, Zig 0.16, zero-dep — the same toolchain. But taking it as a
`build.zig.zon` entry is a **human-gated `new_dependency`** (GOAL.md), and its
filter set is coupled to its own hook/CLI shell.

**Decision: port the ideas, not the code.** Each filter here is a small pure
function against a golden fixture, written test-first in Zygos' own style,
attributed to ztk/rtk in the module docstring. No gate needed, no upstream
coupling, and the filters stay shaped by *our* seam (which has structured tool
input ztk never gets to see).
