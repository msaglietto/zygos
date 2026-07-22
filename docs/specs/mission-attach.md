# Spec: `src/worker/control.zig` + `zygos mission attach` (M6)

Attach an operator view to a RUNNING (or crashed) mission from another
process. The channel is an append-only `control.jsonl` in the planning root
rather than a socket: libc file IO works in workers (Z-02), commands
survive a crashed mission (they park until a resume picks them up), and no
listener is required.

## Protocol (`control.zig`)

- Commands (JSONL, one per line): `steer {text}`, `pause`, `resume`,
  `approve {id, approved}`. `commandLine`/`parseCommandLine` round-trip;
  malformed or unknown lines are skipped, never fatal.
- `requestFor` maps each command onto its bus call
  (`zygos::missions::steer|pause|resume`, `zygos::approvals::resolve`) —
  pure, so the mapping is tested without a bus.
- `Tail` is an offset-based incremental reader: `poll` returns only the
  complete lines appended since the previous call; a partial trailing line
  (mid-append) is not consumed until its newline arrives; a missing file
  is an empty poll.

## The two ends

- **Running mission** (`zygos mission start`): a detached poller tails
  `<planning>/control.jsonl` every 300ms and dispatches each command onto
  its own bus. A dead bus ends the loop (the process is exiting).
- **`zygos mission attach <planning-dir>`**: tails `events.jsonl` and
  prints each new event through the trace renderer (typed-event schema,
  raw passthrough for foreign lines), while stdin lines drive the channel:
  `steer <text>` | `pause` | `resume` | `approve <id> y|n`. Ctrl-D
  detaches. Unattended runs become inspectable without being interactive.

## Semantics

- Steer consumed at the next role boundary, rides exactly one role turn
  (see missions::steer). Pause parks durably; resume over the channel
  un-pauses a boundary-waiting run — a parked (exited) run resumes via
  `zygos mission start --resume`.
- Approvals resolved over the channel ride the same
  `zygos::approvals::resolve` path as the console/TUI keys — deny-on-
  timeout still applies if nobody answers (fail closed).
