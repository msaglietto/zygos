# Spec: `src/worker/brief.zig` — mission brief validation (W1, M4)

A **pure** linter (no bus, no I/O, no allocation) over a mission brief document —
a `GOAL.md`-shaped markdown file with YAML frontmatter. `zygos::missions::start`
runs it before the FSM starts; a failing lint refuses the mission with a
structured reason (fail closed — a malformed brief never starts a mission).

This module is the Z-08 leftover from M3: M3 drove missions from a raw
`objective` string; M4 lets a mission be driven from a brief document and
guarantees the brief is well-formed first.

## Public API

```zig
pub const LintError = enum {
    no_frontmatter,                 // no leading `---\n ... \n---` block
    missing_budget,                 // frontmatter lacks a top-level `budget:` key
    missing_gates,                  // frontmatter lacks a top-level `gates:` key
    no_success_criteria,            // no heading whose text contains "success criteria"
    success_criteria_not_verifiable,// that section has no verifiable-shaped table
    no_non_goals,                   // no non-empty section whose heading contains "non-goal"
};

pub const Result = union(enum) {
    ok,
    invalid: LintError,
};

/// Lint in document order; the FIRST failing check is returned.
pub fn lint(text: []const u8) Result;

/// Stable machine tag for a LintError (snake_case, matches the enum name),
/// used as the refusal `reason`.
pub fn tag(e: LintError) []const u8;
```

## Rules (checked in this order)

1. **Frontmatter present.** The document must begin (after optional leading
   blank lines) with a line that is exactly `---`, followed by lines, then a
   closing line that is exactly `---`. Absent ⇒ `no_frontmatter`.
2. **budget present.** Within the frontmatter block, a line matching
   `^budget:` (a top-level YAML key, no leading whitespace). Absent ⇒
   `missing_budget`.
3. **gates present.** Likewise `^gates:`. Absent ⇒ `missing_gates`.
4. **Success criteria section.** Somewhere in the body a markdown heading
   (`#`..`######`) whose lowercased text contains the substring
   `success criteria`. Absent ⇒ `no_success_criteria`.
5. **Verifiable-shaped.** The success-criteria section (from its heading up to
   the next heading of the same or higher level, or EOF) must contain a
   markdown table with a header row containing a column whose lowercased text
   contains `verified by`, and at least one data row (a `|`-delimited row after
   the `|---|` separator). Absent ⇒ `success_criteria_not_verifiable`.
6. **Non-goals section.** A heading whose lowercased text contains `non-goal`
   (matches "non-goal" and "non-goals"), whose section body has at least one
   non-blank content line. Absent/empty ⇒ `no_non_goals`.

`lint` returns `.ok` only when all six pass.

## Test contract (RED first)

1. `a well-formed GOAL.md-shaped brief lints ok` — frontmatter with budget+gates,
   a `## Success criteria` table with a `Verified by` column and rows, a
   `## Non-goals` bullet list.
2. `no frontmatter ⇒ no_frontmatter` (body starts with a heading).
3. `frontmatter without budget ⇒ missing_budget`.
4. `frontmatter without gates ⇒ missing_gates`.
5. `no success-criteria heading ⇒ no_success_criteria`.
6. `success-criteria section without a Verified-by table ⇒ success_criteria_not_verifiable`
   (a prose-only or bullet-only section).
7. `success-criteria table header present but zero data rows ⇒ success_criteria_not_verifiable`.
8. `non-goals heading missing ⇒ no_non_goals`.
9. `non-goals heading present but empty (immediately followed by another heading) ⇒ no_non_goals`.
10. `first failing check wins` — a brief missing both budget and a non-goals
    section reports `missing_budget` (document order).
11. `tag() returns the snake_case enum name for every LintError`.

No allocator, no leaks test needed — the module allocates nothing.

## Wiring (driver side, `worker/mission.zig`)

`runMission` reads an optional `brief` string field on the start request. When
present, it is linted before anything is persisted or tracked. On `.invalid`,
the handler returns an `.ok` reply that refuses without starting:

```jsonc
{"refused": true, "reason": "<tag>", "detail": "brief rejected: <tag>"}
```

No mission is persisted, no `MissionControl` is tracked, the FSM never runs.
A brief-less start (raw `objective`, the M3 path) is unaffected. Driver-side
tests live in `worker/mission.zig`.
