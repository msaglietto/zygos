# Spec: `src/worker/trim.zig` — output-trim filter (U6, decision Z-09)

An inproc worker registering `zygos::output::compress` — the seam the turn
driver already calls on every tool result (M1 pass-through). rtk/ztk-style
lossy-but-honest trimming: keep the head and tail, say what was dropped.

## Behavior (pure function `trim(arena, text, limits) ![]const u8`)

Applied in order:
1. Strip ANSI CSI/OSC escape sequences (`ESC [ ... final`, `ESC ] ... BEL/ST`).
2. Collapse runs of 3+ blank lines to one blank line.
3. If the result exceeds `max_bytes` **or** `max_lines`: keep the first
   `head_lines` and last `tail_lines` lines with a marker line between:
   `[... zygos trimmed K lines (B bytes) ...]`.

Under the limits ⇒ byte-identical pass-through (after 1–2, which only fire
when escapes/blank-runs exist). Trimming never splits a UTF-8 sequence
(line-based).

## Limits

```zig
pub const Limits = struct {
    max_bytes: usize = 16 * 1024,
    max_lines: usize = 256,
    head_lines: usize = 96,
    tail_lines: usize = 96,
};
```

## Worker

`TrimWorker.start(gpa, actor, registry, limits, budget_scope)`. The mission CLI and the headless task command (`zygos task`, trim-on) both start this worker; the task writes `zygos::output::stats` onto `trial.json`. A trim-on trial with a missing snapshot or a zero reduction is a scorer error. Trim-off does not register the worker. Handler:
request `{"content":"..."}` → reply `{"content":"..."}` (the driver's seam
contract). When bytes were saved and `budget_scope` is non-null, `cast`
`zygos::budget::record {"scope":scope,"kind":"saved_bytes","amount":saved}` —
fire-and-forget; accounting must never slow the tool path.

Malformed request (no `content` string) ⇒ echo the request back unchanged?
No — reply `{"content":""}` is lossy and wrong; reply the original request
text is wrong too. The seam's driver side already falls back to the untrimmed
output on any error, so: malformed ⇒ `error.Failed` (driver passes through).

## Test contract (RED first)

1. `short clean text passes through byte-identical`
2. `ANSI escapes stripped (CSI colors + OSC title)`
3. `blank-line runs collapse`
4. `over max_lines: head+tail kept, marker counts dropped lines`
5. `over max_bytes with few lines still trims`
6. `trimmed output is under the limits`
7. `worker: saved bytes recorded to the budget scope (observed via budget::check)`
8. `worker: malformed request ⇒ bus handler_failed (driver falls back)`
9. `no leaks under trim loops`
