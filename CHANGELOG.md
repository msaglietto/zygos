# Changelog

Operator-visible changes to Zygos. The number is `.version` in `build.zig.zon`.

Reconstructed from git history on 2026-09-30. A commit that only added a library nothing called yet is recorded on the later commit that exposed it. Test-only commits, and commits that moved code without a behavior change, have no entry. The short hash is that commit.

The agent that next changes operator-visible behavior adds the new heading in that same commit.

## [4.0.1] - 2026-10-07

### Fixed

- `zygos task score` computes the trim reduction percentage in 128-bit arithmetic, so a parseable raw byte count near the integer limit no longer panics or wraps.

## [4.0.0] - 2026-10-01

### Breaking

- Browser WebSocket peers must use an explicitly allowed Origin; local peers must supply the shared token when `ZYGOS_TOKEN` is set.
- Shell children receive an environment allowlist rather than inheriting provider keys and arbitrary operator variables. Commands have a local two-minute deadline and their process group is terminated when the handler exits.
- `web_fetch` refuses recognized literal private hosts and localhost unless the explicit override is enabled. DNS resolution and redirects remain outside this screening.

### Fixed

- Delivery lifetime barriers keep in-process workers and WebSocket connection entries alive until in-flight sends finish.
- Duplicate invocation IDs receive an error without replacing the original request, trigger unregister checks ownership, and provider token limits reject u32 overflow.
- Planning roots retain an OS lock through execution; run stamps contain only formatted timestamp/PID bytes. Atomic writers use unique exclusive temporary files and fsync their data.
- SSE event storage, provider payloads, tool indexes, MCP reply lines/read waits, and TUI previews have limits. Decoded trace text and streamed tool names are scrubbed before terminal rendering.

### Added

- MIT license and dependency notice, public provider/brief examples, contribution and security policies, issue/PR templates, and macOS/Linux CI with fixture integrations.
- Reviewed audit and readiness report distinguish implemented fixes, trusted-local-operator limits, remaining engineering work, and publication tasks.

## [3.5.3] - 2026-09-24

### Fixed

- Orient and session open stop reading SESSIONS.md after the entries they use. Session close still reads the whole file so it can prepend. (81ce552)

## [3.5.2] - 2026-09-24

### Fixed

- A context git digest stops reading git ls-files once it has digest_bytes. (f4cdf43)

## [3.5.1] - 2026-09-24

### Fixed

- Mission attach reads only the new tail of events.jsonl on each poll. (82ab22b)

## [3.5.0] - 2026-08-06

### Added

- web_fetch strips boilerplate from HTML and returns the readable text. (1ba5bbf)

## [3.4.3] - 2026-08-05

### Fixed

- git log output is compressed again. A file location or the word Traceback inside a sentence is not treated as a failed command. (5cfff2e)

## [3.4.2] - 2026-08-05

### Fixed

- An oversized JSON array drops whole entries and reports how many were dropped, so the model still receives parseable JSON. (80771f6)

## [3.4.1] - 2026-08-05

### Fixed

- The error guard matches a diagnostic at the start of a line, and repeated identical lines collapse. Prose that only mentions an error still goes through the filter. (f47d8d4)

## [3.4.0] - 2026-08-05

### Added

- LEDGER.md records the compression ratio for the run. (e2ec487)

## [3.3.2] - 2026-08-05

### Fixed

- Envelopes that store their text under output, text, or content stay valid JSON after trimming. (720ee44)

## [3.3.1] - 2026-08-05

### Fixed

- A tool reply wrapped in an envelope is unwrapped before the filters see it. (5a4c032)

## [3.3.0] - 2026-08-05

### Added

- Those filters, a dedup cache, and trim stats run on the compress seam. (a3eb78c)

## [3.2.0] - 2026-08-05

### Added

- Command-aware filters for git, directory listings, test runs, and build lint choose what tool output to keep. (8394ce1)

## [3.1.0] - 2026-08-05

### Added

- A compress request carries the tool name and the tool input. raw: true on a tool call skips compression and keeps the bytes exact. (3b2b3a7)

## [3.0.1] - 2026-07-25

### Fixed

- The token budget declared in the brief is enforced. An explicit environment cap still wins over the brief, and the brief wins over the default. (63710f7)

## [3.0.0] - 2026-07-25

### Breaking

- An unanswered completion gate parks the mission in gating. Resume asks the gate again. A deny that was actually answered still sends the mission back to planning. (d6dfad2)

## [2.33.0] - 2026-07-22

### Added

- ZYGOS_WORKTREE=1 runs the executor in a detached git worktree under the planning root and leaves the main tree clean. A repo that cannot make a worktree refuses the run. (43ef187)

## [2.32.0] - 2026-07-22

### Added

- The CLI queues more than one mission and shows a dashboard from missions::list. (503533a)

## [2.31.0] - 2026-07-22

### Added

- The TUI takes a steer line, pause, and resume, and shows a band while the mission is paused. (f070b0a)

## [2.30.0] - 2026-07-22

### Added

- Each connection writes through a bounded queue, and SIGINT drains that queue on the way down. (40b2c51)

## [2.29.0] - 2026-07-22

### Added

- A role-<step>.md file in the planning root overrides that role's prompt. A blank file leaves the built-in prompt. The file does not change what output the mission accepts. (4e3c149)

## [2.28.0] - 2026-07-22

### Added

- The mission writes its budget ledger to LEDGER.md. (4c6f98e)

## [2.27.0] - 2026-07-22

### Added

- The product-owner appends its decisions to DECISIONS.md in the planning root. (ca91f41)

## [2.26.0] - 2026-07-22

### Added

- zygos mission attach follows a file control channel for approve, steer, pause, and resume. (f4df8e2)

## [2.25.0] - 2026-07-21

### Added

- A running mission accepts steer, pause, and resume on the bus. (afa3a49)

## [2.24.0] - 2026-07-21

### Added

- The thread strategy keeps a narrow, deep context for long factory runs. (b54a981)

## [2.23.0] - 2026-07-21

### Added

- The recall strategy keeps a wide, shallow context for research runs. (cb6748f)

## [2.22.0] - 2026-07-21

### Added

- Mission context is selected by a strategy. The substrate strategy uses the brief and the planning files. (55eeea7)

## [2.21.1] - 2026-07-21

### Fixed

- The search key named by key_env is resolved at boot, so a Brave search works when that variable is set. (1ebe1aa)

## [2.21.0] - 2026-07-17

### Added

- JSON role payloads collapse, and narration and task-done lines are clipped to a readable length. (b64f1fe)

## [2.20.2] - 2026-07-17

### Fixed

- Narration that introduces a tool call is committed before that tool box. (23a1353)

## [2.20.1] - 2026-07-17

### Fixed

- Token usage is read from Anthropic message_delta events and from OpenAI-style field names. (3a2c287)

## [2.20.0] - 2026-07-17

### Added

- Fenced code highlights a small set of keywords. (35b891c)

## [2.19.0] - 2026-07-17

### Added

- Numbered lists render, and fenced code sits on a panel. (f870518)

## [2.18.0] - 2026-07-17

### Added

- A status line shows the mission phase and the turn timers. (99cfcb1)

## [2.17.0] - 2026-07-17

### Added

- The TUI echoes the objective and shows how long the work has been running. (997cadd)

## [2.16.0] - 2026-07-17

### Added

- The TUI shows the current task and collapses the line when the task is done. (9dee06a)

## [2.15.0] - 2026-07-17

### Added

- The executor emits task_start and task_done on the trace. (944c930)

## [2.14.0] - 2026-07-17

### Added

- A running TUI entry shows a rail and collapses when it finishes. (b0107b6)

## [2.13.0] - 2026-07-17

### Added

- The TUI uses truecolor where the terminal has it, and 256 colors otherwise. (64c2a38)

## [2.12.0] - 2026-07-16

### Added

- Interim narration collapses, and answers render a small markdown subset. (d57d454)

## [2.11.0] - 2026-07-16

### Added

- Later executor turns see the outcome of tasks that already finished. (9b4be8d)

## [2.10.6] - 2026-07-16

### Fixed

- Streamed tool arguments that repeat a key keep the last value, so the result frame stays legal JSON. (3475a6f)

## [2.10.5] - 2026-07-16

### Fixed

- An in-process result the wire cannot parse is returned to the caller as an error, instead of parking the call until timeout. (3cc939b)

## [2.10.4] - 2026-07-16

### Fixed

- The executor is told its workspace path and told to stay there with relative paths. (45162f2)

## [2.10.3] - 2026-07-16

### Fixed

- The approval band leads with the y/N keys, and chat text wraps at the terminal width. (e13bbfa)

## [2.10.2] - 2026-07-16

### Fixed

- In-process channels are stamped with the kernel clock, so a live stream is not reaped as idle on the first tick. (92b6c2f)

## [2.10.1] - 2026-07-16

### Fixed

- The first timer tick is posted at startup, so kernel time is real before the first interval elapses. (47f9e52)

## [2.10.0] - 2026-07-16

### Added

- Finished tool boxes collapse, roles are spaced, footnotes wrap, and stream diagnostics stay on screen. (1afc27b)

## [2.9.1] - 2026-07-16

### Fixed

- While the TUI owns the screen, raw stderr goes to tui-stderr.log. A panic still prints on the terminal. (5ab43f5)

## [2.9.0] - 2026-07-16

### Added

- Mission runs feed that stream tap into the TUI. (edebd87)

## [2.8.0] - 2026-07-16

### Added

- The TUI shows a live thinking block, streaming tool boxes, and the answer as it arrives. (bcef61f)

## [2.7.0] - 2026-07-16

### Added

- Thinking text and in-progress tool arguments are tapped off the provider stream. (c4b237e)

## [2.6.0] - 2026-07-15

### Added

- zygos mission opens a live TUI: raw mode, width-aware cells, line-diff repaint, and the mission, role, and tool. --no-tui or ZYGOS_NO_TUI keeps the plain log. (4b6c859)

## [2.5.0] - 2026-07-15

### Added

- A panic while the TUI owns the terminal restores the terminal before the crash text is printed. (0922a8f)

## [2.4.0] - 2026-07-15

### Added

- A turn publishes streaming deltas and a usage event on that trace. (aaa25c7)

## [2.3.0] - 2026-07-15

### Added

- Trace events fan out to in-process listeners as well as events.jsonl. (da71507)

## [2.2.0] - 2026-07-15

### Added

- A function can override the default invocation timeout. (b6f8465)

## [2.1.0] - 2026-07-15

### Added

- A provider stream that stays silent past the idle watchdog is aborted. (3557517)

## [2.0.2] - 2026-07-15

### Fixed

- The mission CLI pumps invocation timeouts, so a hung provider call is swept instead of stalling the mission. (49b3923)

## [2.0.1] - 2026-07-15

### Fixed

- Bash, web search, web fetch, and MCP tools send their description and input schema to the provider. (8eb6bb3)

## [2.0.0] - 2026-07-14

### Breaking

- An executor that stops because it hit max_steps is run again with feedback, instead of failing the mission on that attempt. Past the failure threshold the mission escalates. Other roles still fail on the first bad turn. (e5c0679)

## [1.8.0] - 2026-07-14

### Added

- MCP servers named in zygos.zon are spawned on stdio and their tools register as zygos::mcp/<server>/<tool>, through policy, trim, and budget. A server that fails at boot refuses the run. (7f5007a)

## [1.7.0] - 2026-07-11

### Added

- Every run appends events.jsonl under the planning root, and zygos mission trace prints it. A trace that cannot be written does not change the mission. (0d08a03)

## [1.6.0] - 2026-07-11

### Added

- Search retries a 429 once, after a short delay. Any other HTTP status still fails immediately, and the status is logged. (6872957)

## [1.5.1] - 2026-07-10

### Fixed

- A role reply that is one markdown fence around JSON is accepted. The inside still has to be strict JSON. (d1d31b9)

## [1.5.0] - 2026-07-10

### Added

- Role output that fails to parse is saved as REJECTED-<role>.md in the planning root before the mission fails. (e93d50e)

## [1.4.0] - 2026-07-10

### Added

- When ZYGOS_VAULT_ROOT is set, the run takes a tessera-undo checkpoint before the mission starts, and refuses to start if that checkpoint cannot be taken. (9245c18)

## [1.3.0] - 2026-07-10

### Added

- ZYGOS_LOG filters runtime logs, and mission progress is emitted at info. (8becb37)

## [1.2.0] - 2026-07-10

### Added

- Mission runs boot the web tools and send them through the policy gate. The search engine and key come from the environment. With no engine set, search fails on that call and fetch still works. (3adf13d)

## [1.1.0] - 2026-07-10

### Added

- web_search and web_fetch are bus tools. Fetch returns size-capped text. A non-2xx response, an oversize body, a non-text body, or a malformed payload fails closed. (471d82d)

## [1.0.0] - 2026-07-10

### Breaking

- zygos mission start exits 2 when the planning root already holds a mission, and no longer replaces it. --run-stamp gives a scheduled run its own planning root. (44c8ca7)

## [0.33.0] - 2026-07-10

### Added

- A catalog entry may set type = anthropic_compatible and boot the Anthropic Messages backend. Other entries stay on chat completions. (8c64224)

## [0.32.2] - 2026-07-10

### Fixed

- The mission CLI allows 24 steps per role turn and 48 role turns, enough for a real executor. ZYGOS_ROLE_MAX_STEPS and ZYGOS_MAX_ROLE_TURNS override them. (4489626)

## [0.32.1] - 2026-07-10

### Fixed

- A stream warning names the provider that failed. (a488484)

## [0.32.0] - 2026-07-10

### Added

- zygos mission start <brief> and zygos mission resume run a mission from the terminal. Approvals are read from stdin. End of file denies. (d013d9e)

## [0.31.0] - 2026-07-09

### Added

- The provider catalog TOML boots one zygos::providers/<slug> worker per entry. A route that names an unknown slug refuses to boot. (fb7d8e9)

## [0.30.0] - 2026-07-09

### Added

- zygos mcp-gateway serves the tessera functions as MCP tools over stdio. (b43d979)

## [0.29.0] - 2026-07-09

### Added

- Tessera capture files a note using the taxonomy in zygos.zon. A bad classification still lands, in the ideas note, tagged needs-review. (a1717f5)

## [0.28.0] - 2026-07-09

### Added

- Session open returns the last session's leaving-behind notes and open threads. Session close prepends an entry and promotes action items onto PROJECT.md. (f454093)

## [0.27.0] - 2026-07-09

### Added

- A mission writes a session entry when a phase ends, without asking the model to remember the phase. (ad608a1)

## [0.26.0] - 2026-07-09

### Added

- Tessera undo takes a shadow-git checkpoint before a vault write, and one call restores it. Undo with no checkpoint is an error. (81e5dd7)

## [0.25.0] - 2026-07-09

### Added

- Tessera orient reads a vault's SESSIONS.md and PROJECT.md: project status, open threads, projects stale for more than 14 days, and stalled loops. (f292ab8)

## [0.24.0] - 2026-07-09

### Added

- Mission start rejects a brief with no verifiable success criteria, no non-goals, or no budgets and gates. (bb3516b)

## [0.23.0] - 2026-07-07

### Added

- Product-owner, planner, executor, and verifier each run as their own routed turn. Malformed role JSON fails the mission. Done requires an approval gate. Too many failed verifies, or too many denied gates, fails the mission. Resume continues from the saved state. (1d05862)

## [0.22.0] - 2026-07-07

### Added

- A mission moves through defining, planning, executing, verifying, and gating, and saves that state atomically under .planning/. (06ff5c0)

## [0.21.0] - 2026-07-07

### Added

- OpenAI-compatible streams assemble into the same terminal message as Anthropic: finish reason, tool-call arguments, and usage. (e6ea446)

## [0.20.0] - 2026-07-07

### Added

- Oversized tool output is trimmed from the head and the tail, and the bytes saved are recorded on the budget. (9e17a9d)

## [0.19.0] - 2026-07-07

### Added

- Budgets are counted per scope. Crossing the limit stops the turn. A configured budget worker that cannot be reached also stops the turn. (e8f41f1)

## [0.18.0] - 2026-07-07

### Added

- zygos.zon picks the provider and model for each step. A failed provider advances to the next route, and an exhausted ladder fails the turn. (4dee3ce)

## [0.17.0] - 2026-07-07

### Added

- The turn consults policy before dispatch, waits on a real approval when the verdict is ask, and accepts abort and steer. (2f84074)

## [0.16.0] - 2026-07-07

### Added

- Approvals can be requested, listed, and resolved. An approval that times out unanswered denies the tool. (04bb773)

## [0.15.0] - 2026-07-07

### Added

- A policy worker can deny or ask before a tool runs. A missing worker, a malformed verdict, or a handler error denies the call. (2f7c522)

## [0.14.0] - 2026-07-07

### Added

- Every successful tool result is offered to output::compress before it reenters the transcript. With no compressor registered, the text passes through. (ed4567d)

## [0.13.0] - 2026-07-07

### Added

- Bash, read_file, and write_file stay inside the workspace. A two-step tool-use turn runs to a clean stop. (28c6e32)

## [0.12.0] - 2026-07-07

### Added

- The Anthropic provider is a bus worker. Incremental SSE becomes deltas and a terminal message with stop reason, usage, and tool-use JSON. A malformed event does not crash the decoder. (9f196ea)

## [0.11.0] - 2026-07-07

### Added

- A turn runs from provisioning through streaming, tool dispatch, approval, and steering, and ends stopped or failed. The tool result is fed back into the next step. (509dc56)

## [0.10.0] - 2026-07-07

### Added

- In-process workers register and invoke through the same frames as WebSocket workers. (38c618c)

## [0.9.0] - 2026-07-07

### Added

- Kernel completions return the real payload, and in-process channel traffic shares the actor's clock. (8180328)

## [0.8.0] - 2026-07-07

### Added

- A WebSocket worker can connect with the unmodified iii Node SDK, register a function, and call another worker. (35cc754)

## [0.7.0] - 2026-07-06

### Added

- The catalog, calls, triggers, and channels run on one kernel thread. (dfee1b2)

## [0.6.0] - 2026-07-06

### Added

- A keyed channel delivers its bytes to one consumer, rejects the wrong access key, and expires on its TTL. (85fdc46)

## [0.5.0] - 2026-07-06

### Added

- A call is matched by its id, may finish later, and times out with an error instead of hanging. Disconnect on either side settles it. (dd67cf4)

## [0.4.0] - 2026-07-06

### Added

- Triggers keep durable bindings across reconnects, replay them when a type is registered again, and drop connection-owned triggers when the worker leaves. (f8ddd73)

## [0.3.0] - 2026-07-06

### Added

- Registration frames round-trip, including the looser JSON the iii Node SDK sends. (9207403)

## [0.2.0] - 2026-07-06

### Added

- Functions register on a catalog. The newest registration wins, and a stale worker's disconnect cannot remove it. (c84f407)

## [0.1.0] - 2026-07-06

### Added

- Invocation, keepalive, and worker-registered frames parse and serialize on the iii wire. (0e153ea)
