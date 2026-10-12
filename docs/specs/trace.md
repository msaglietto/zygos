# Spec: `src/worker/trace.zig` + `src/worker/trace_event.zig` — mission trace

One JSON object per line appended to `events.jsonl` in the planning root:
role boundaries, provider steps, tool calls/results, usage, task edges.

## Typed schema (`trace_event.zig`)

`TraceEvent` is a tagged union shared by emitters (mission/turn drivers via
`trace.emit`) and consumers (JSONL renderer, TUI model): adding a variant
breaks every exhaustive switch at compile time instead of silently dropping.
Variants: `mission`, `pipeline`, `role_start`, `role_end`, `task_start`,
`task_done`, `step`, `tool_call`, `tool_result`, `usage`, `turn_end`, `steer`.

### Mission events

- `pipeline`, emitted once at mission start before the first `mission`
  event: `{"ts":<ms>,"event":"pipeline","steps":[{"id":"architect","definition_sha256":"<hex>"|null,"tools":true},...]}`.
  `definition_sha256` is null for a step with a built-in prompt. Ids are
  arbitrary strings from the config.
- `mission` carries the state names `running`, `gating`, `done`, `failed`
  in `from` and `to`, plus the cursor after the transition: `step` (the
  step id; null at `gating` and `done`) and `step_index`. The driver emits
  it whenever `(state, step_index)` changes, so a step advance is
  `running → running` with a different `step`. Lines written before the
  pipeline existed carry neither field and the old state names; parse
  reads them as "cursor not recorded".
- `role_start` and `role_end` carry `role` = the step id.

- `body()` serializes byte-identical to the historical fmt-string emitters —
  events.jsonl is a wire format; consumers in the wild parse it. The usage
  arm stays `input_tokens` and `output_tokens`. Cache counts, when a provider
  sends them, are copied onto the task trial and are not fields of this line.
- `parse()` is tolerant: missing fields read as defaults, unknown event
  names/non-objects as null — consumers keep raw-passthrough semantics for
  foreign lines.

## Semantics the trace must honor

- Fail-open by contract: the trace observes the run, it is not part of it.
  An unwritable path never changes an outcome; only OutOfMemory propagates.
- One `fwrite` in append mode per line keeps concurrent emitters from
  interleaving mid-line.
- Embedded payloads clip at `max_field_bytes` (2048) on a UTF-8 boundary,
  with the full byte size alongside — a view, not an archive.
- In-process `Sink`s (the TUI) receive every line (sans newline) even with
  no file path; sink callbacks run on the emitting thread and must be fast
  and infallible. Registry is process-global (the path travels as a string
  in request JSON — there is no object to hang a sink on).
- `render()` (the `zygos mission trace` view) passes unknown or unparseable
  lines through raw — the renderer must never hide evidence. A `mission`
  line renders as `mission running → running [step executor #2] (...)`
  (`[step - #4]` at gating), and the `pipeline` line lists
  `id[+tools][@hash8]` per step.

## AG-UI projection (`agui.zig`)

`zygos mission trace <target> --format agui|html` maps a finished or partial
`events.jsonl` onto AG-UI 1.0 events, offline. The mapping table is the one
exhaustive `switch` over `TraceEvent` in `Projector.apply`.

- Pure. `project(arena, jsonl, thread_id)` and `html(arena, agui_jsonl)` do
  no IO and open no socket. The CLI reads the files and writes stdout.
- Deterministic. The same log gives byte-identical output. Ids are derived
  from the log, never from a clock or a random source: `runId` is
  `<thread_id>:1`, tool calls are `call-<n>` by `tool_call` ordinal, unmatched
  results are `result-<m>`, steers are `steer-<n>`, and a role turn is the
  subagent run `<role>:<role_turn>`. Key order in each line is fixed.
- Steps follow the cursor. A `mission` event opens an AG-UI step named by
  the step id while the state is `running`, and by the state name at
  `gating`, `done` and `failed`. The step changes when that name or
  `step_index` changes; a repeated event for the same cursor only
  refreshes the `zygos.mission` activity snapshot (`state`, `from`, `step`,
  `step_index`, counters). A `planner` step starting clears the shown plan.
  The `pipeline` event becomes `CUSTOM` `zygos.pipeline` with
  `value.steps` (`id`, `definition_sha256`, `tools`). Logs that predate the
  cursor fall back to one step per state name.
- Lines `parse()` rejects are skipped. A mission log ends in `RUN_FINISHED`
  only at `done` and `RUN_ERROR` only at `failed`. A task log ends on its
  `turn_end`. A live or truncated log ends without either, because AG-UI
  forbids inventing a finish.
- A tool result attaches to the first open call in the same role with the
  same tool name, else the first open call in that role. `policy_denied: `
  and `approval_denied` error results carry `metadata.zygos.denied`.
- Redaction. `redact()` scrubs every free-text field copied out of the log
  (role content, tool input and output, task text, steer text, failure
  reasons). A name rule replaces the value of a `*KEY*`, `*SECRET*`,
  `*TOKEN*`, `*PASSWORD*`, `*PASSWD*` or `*CREDENTIAL*` assignment when the
  value is at least 8 bytes and not all digits, so `max_tokens=4096`
  survives. A shape rule replaces `Bearer` tokens, `sk-`, `ghp_`, `gho_`,
  `github_pat_`, `xoxb-`, `xoxp-` keys and `AKIA` key ids. It is a
  best-effort scrub of a log that already holds the text, not a guarantee.
- Clip flag. `metadata.zygos.clipped` is true when the field ends with the
  `…[<n> bytes total]` suffix `clip()` appends, or a result's `bytes`
  exceeds `max_field_bytes`. The viewer shows that the payload is partial.
- HTML. The viewer template `agui_viewer.html` is embedded at compile time
  and must hold the `@@ZYGOS_EVENTS@@` placeholder exactly once (a compile
  error otherwise). Every `<` in the inlined JSONL becomes `\u003c`, so the
  data block cannot close its `<script>` tag.
- Bench trials. Harbor keeps `agent/events.jsonl` next to `agent/trial.json`,
  so `zygos mission trace <jobs>/<trial>/agent --format html > run.html`
  views one trial. The thread id is `mission_id` from `mission.json`, else
  `task_id` from `trial.json`, else the directory name.
