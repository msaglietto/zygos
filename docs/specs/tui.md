# Spec: `src/tui/` — live mission TUI

Live-progress terminal UI for `zygos mission start`. Hand-rolled ANSI over
termios/ioctl/poll (Z-02: no `std.Io`); renders the existing mission trace
stream, not a console. The aesthetic bar is the grok CLI capture
(2026-07-17): measured palette, entry-collapse lifecycle, markdown-lite
answers.

## Composition (who owns what)

- `model.zig` — the view model. Fed by trace-event lines (worker/trace.zig
  sink → typed `trace_event.TraceEvent`), streamed deltas (turn observer +
  stream_tap), and captured log lines. Every entry point takes the model
  mutex; byte slices passed in are valid only for the call (the model copies
  what it keeps). Unknown event kinds are ignored — the view must survive a
  newer emitter; known kinds go through an exhaustive switch.
- `loop.zig` — lifecycle: one render thread over model + renderer. `tui/`
  never touches the bus or the trace registry; the CLI composes those
  (registers the model as sink/observer, runs the approval key loop).
  Teardown: callers `stop()` the Tui, which joins the render thread.
- `band.zig` — bottom band (header/spinner, step line, running tools, live
  tool box, thinking block, answer tail, approval ask, status). Pure over a
  read-only model snapshot taken under the mutex.
- `chatlog.zig` — committed history; lines only grow into native terminal
  scrollback. Owns collapse/promote of live buffers into history.
- `entries.zig` — the entry-lifecycle grammar: in-flight work renders under
  a left rail (heavy `┃` tools, thin `❙` thinking) and collapses to one dim
  scrollback line when finished.
- `frame.zig` — scrollback-flow renderer: chat rows scroll out via `\r\n`
  and are never re-addressed; only the changed bottom-row range repaints. A
  change above the viewport forces clear + replay. Frames ride synchronized
  output (`?2026`).
- `term.zig` — terminal seam: named escapes + a vtable renderer (tests
  capture bytes; the real impl is termios-backed). TUI writes fd 2, reads
  keys on fd 0 — stdout stays reserved for the final mission JSON.
- `theme.zig` / `palette.zig` — semantic color roles measured from the grok
  capture; truecolor value + xterm-256 fallback per role; write-once mode.
  Spinner frames derive from the wall clock (any thread renders without
  coordination).
- `width.zig` — ANSI-aware cell width: escapes/combining/ZWJ measure 0,
  East-Asian wide + emoji measure 2; grapheme clusters not composed.
- `markdown.zig` — markdown-lite for promoted answers, line-oriented (one
  input line → at most one output line); unmatched markers pass through —
  never eat user bytes.
- `highlight.zig` — keyword highlighter for fenced code. Invariant:
  stripping SGRs yields the input bytes exactly.
- `partialjson.zig` — tolerant scanner extracting display fields from
  incomplete streamed JSON; never fails on truncation.
- `tasks.zig` — live current-task band line keyed off task_start/task_done.
- `logbridge.zig` — reroutes std.log into the model (dim footnotes) while
  the TUI owns the terminal; mutex-guarded install/clear.

## Semantics the TUI must honor

- Fail-open view: a malformed event line is dropped, never fatal; losing a
  line must not wedge the display.
- Evidence is never hidden: log lines and tool errors surface (footnotes,
  ✗ previews) rather than vanish.
- Ordering: narration streamed before a tool call commits *before* the tool
  entry (the "I'll do X" line must precede the tool it introduces).
- Teardown: unhook sinks/observers, stop rendering (final frame), restore
  the terminal — before anything writes stdout/stderr. Ctrl-C in raw mode
  (byte 0x03) repairs the terminal and re-raises SIGINT.
- Piped/CI runs (`--no-tui`, `ZYGOS_NO_TUI`, or no tty) keep the plain
  console path byte-identical.

Tested terminal-free through the vtable renderer; model tests feed raw
JSONL lines and assert rendered lines.
