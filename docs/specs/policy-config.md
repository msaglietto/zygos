# Spec: `zygos.zon` `.policy` — operator config for mission policy rules (issue #12)

> **Status: implemented (issue #12; GOAL.md U1 amendment ratified by
> Mauricio 2026-10-19).** `src/worker/policy_config.zig` parses `.policy`.
> A present, valid list replaces the hard-coded allow list
> (`mission_boot.policySeed`), which still governs when `.policy` is
> absent.

Issue #7 made per-step rules expressible: every policy request carries the
calling turn's `step_id`, and `policy.Rule` has an optional `step` pattern
(`docs/specs/policy.md`). This spec makes them configurable. An operator
writes an ordered rule list in `zygos.zon`; the mission CLI validates it
strictly at boot and hands it to the existing policy worker. The worker,
its matcher, the turn driver's fail-closed handling and the approval path
do not change.

## Where the config lives

The same `zygos.zon` the mission CLI already reads (`ZYGOS_CONFIG`, else
`./zygos.zon`), under a top-level `.policy` key. The value is an ordered
tuple of rules:

```zig
.policy = .{
    .{ .tool = "bash", .verdict = .deny, .step = "architect" },
    .{ .tool = "bash", .verdict = .allow },
    .{ .tool = "web_*", .verdict = .ask, .step = "research*" },
    .{ .tool = "zygos::mcp::tavily::*", .verdict = .allow },
},
```

- **Entry keys:** `.tool` (required string), `.verdict` (required enum
  literal: `.allow`, `.deny` or `.ask`), `.step` (optional string). No other
  key is accepted.
- **`.tool`** is a `policy.Rule.tool` pattern: an exact name, or a prefix
  ending in one trailing `*`. As today, the worker tries it against both the
  request's `tool` (the model-facing name) and its `function_id`. A bare
  `*` matches every tool.
- **`.step`** is a `policy.Rule.step` pattern over pipeline step ids: an
  exact id, or a prefix ending in one trailing `*`. Absent ⇒ the rule
  matches every step (`Rule.step = null`).
- **Order is significant.** Rules keep file order; first match wins; no
  rule matched ⇒ `deny` (`"no rule matched"`), exactly as in `policy.md`.
- **Parsing.** `.policy` has its own strict parser in a pure module
  (`src/worker/policy_config.zig`), built like the `.steps` parser
  (`std.zig.Ast` + `ZonGen`, then a walk of the Zoir tree). It ignores
  every other top-level key. The router's, context's and MCP config's
  lenient parses keep ignoring `.policy`, and the `.steps` parser keeps
  ignoring it too. All parsing and validation logic lives in that module;
  `cli/mission.zig` only reads the file, calls it, prints the refusal and
  wires the result.

## Absent config

No `.policy` key ⇒ the CLI seeds exactly what it
seeds today: `policySeed(mcp_names)`, which is `bash`, `web_fetch`,
`web_search`, then each MCP tool's model-facing name, all `.allow`, none
step-scoped. No new trace event is written, the start request is unchanged,
and every existing test stays green. An absent block changes nothing, byte
for byte.

## Present config: it replaces the seed

A present, valid `.policy` **is** the effective rule list. The seed is not
consulted and nothing is prepended or appended.

Why replace and not prepend: under replace, a rule the operator forgot is a
deny, which is visible as `policy_denied` in the trace. Under prepend, the
seed's allow rules would sit behind every configured rule, so a typo in a
deny rule would silently fall through to an allow. Replace is the
fail-closed reading. It also means the traced list is the whole policy.

**MCP tools.** The seed covered MCP tools by name. A configured list covers
them only if a rule matches. Each MCP tool reaches the policy worker as
`tool = "<server>_<tool>"` and `function_id = "zygos::mcp::<server>::<tool>"`
(`mcp/client.zig`), so any of these work:

- every MCP tool: `.{ .tool = "zygos::mcp::*", .verdict = .allow }`;
- one server: `zygos::mcp::tavily::*`, or `tavily_*`;
- one tool: `tavily_search`, or `zygos::mcp::tavily::search`.

An MCP tool no rule matches is denied.

To rebuild today's seed and add one per-step restriction:

```zig
.policy = .{
    .{ .tool = "bash", .verdict = .deny, .step = "architect" },
    .{ .tool = "bash", .verdict = .allow },
    .{ .tool = "web_fetch", .verdict = .allow },
    .{ .tool = "web_search", .verdict = .allow },
    .{ .tool = "zygos::mcp::*", .verdict = .allow }, // only with .mcp_servers, see below
},
```

## Boot refusals (fail closed, before any turn runs)

The mission CLI refuses to start, exit 2, and prints
`mission: invalid .policy in <path>: <reason>` to stderr. The reason names
the entry with a 0-based index, as `.steps` does. A refusal never falls back
to the seed and never boots with a partial list.

| Condition | Reason | When |
|---|---|---|
| `.policy` is not a tuple, or the file fails to parse as ZON | `policy: malformed` | before kernel boot |
| `.policy = .{}` | `policy: empty` | before kernel boot |
| an entry is not a struct literal | `policy[i]: malformed` | before kernel boot |
| an entry has a key other than `tool`, `verdict`, `step` | `policy[i]: unknown key "<k>"` | before kernel boot |
| no `.tool` | `policy[i]: missing tool` | before kernel boot |
| `.tool = ""` | `policy[i]: empty tool` | before kernel boot |
| `.tool` not a string, or with a `*` anywhere but the last character | `policy[i]: bad tool pattern` | before kernel boot |
| no `.verdict` | `policy[i]: missing verdict` | before kernel boot |
| `.verdict` not one of `.allow`, `.deny`, `.ask` (a string `"allow"` included) | `policy[i]: bad verdict` | before kernel boot |
| `.step` not a string; empty; a `*` anywhere but last; or the part before an optional trailing `*` not matching `[a-z0-9-]{1,32}` (`[a-z0-9-]{0,32}` when a `*` follows) | `policy[i]: bad step pattern` | before kernel boot |
| `.step` matches no step id of the pinned pipeline (`.steps`, or the default four when absent) | `policy[i]: step "<p>" matches no configured step` | before kernel boot |
| `.tool` matches no offered tool's name or function id | `policy[i]: tool "<p>" matches no offered tool` | after the MCP handshake, before the mission starts |

Decisions in that table:

- **A step that names no configured step refuses; it does not warn.** A
  dead step-scoped rule is the issue's main fail-open risk:
  `.{ .tool = "bash", .verdict = .deny, .step = "archtect" }` followed by
  `.{ .tool = "bash", .verdict = .allow }` would give the architect bash.
  The check applies to exact ids and to globs (a glob must prefix-match at
  least one id). `step = "*"` always passes, since every mission step has a
  non-empty id.
- **The tool check is the same rule for tools, and it is the one late row.**
  "Offered" means the tools a mission step can be handed: the base list
  (`bash`, `web_fetch`, `web_search`, with function ids
  `zygos::tools::bash`, `zygos::tools::web_fetch`,
  `zygos::tools::web_search`) plus every MCP tool's name and function id.
  The MCP names exist only after the MCP children have spawned and
  answered `tools/list`, which needs the kernel up. So this row refuses
  after kernel boot and the MCP handshake but before
  `zygos::missions::start` is invoked: exit 2, no turn, and the mission
  store is not written (a resume's existing `mission.json` is left as it
  was). Consequences, accepted:
  - `read_file` and `write_file` are on the bus but never offered to
    mission steps, so a rule naming them refuses.
  - `zygos::mcp::*` refuses when the file has no `.mcp_servers`. The
    policy block is coupled to the MCP block it governs. A rule that can
    never match is a typo or a stale leftover, and either way the operator
    should see it.
  - A bare `*` always passes.
- **Accepted dead case:** a step-scoped rule whose step has `tools = false`
  is accepted. Such a step is offered no tools, so the rule cannot fire;
  refusing it would force a policy edit every time an arm toggles
  `.tools`. Shadowed rules (a rule after one that already matches
  everything it would) are accepted too: first match wins is documented.
- **Duplicate keys** inside one entry fail ZON generation and refuse as
  `policy: malformed`.
- **ZON syntax errors** refuse as `policy: malformed` in the module. In the
  CLI the router's parse reads the file first, so a syntax error still
  exits 2 earlier as `mission: cannot parse route table <path>`; the
  `.policy` parser only ever sees a syntactically valid file there.

## Resume

`.policy` is **not pinned** in `mission.json`, unlike `.steps`. A resume
uses whatever `.policy` the file holds at resume time. The step check runs
against the current pipeline, which resume already requires to equal the
pinned one. Tightening policy mid-mission (say, denying a tool after
watching a run) is a legitimate operator action, and loosening it is
visible because every run of the loop traces its effective list (below).

## The `ask` verdict

`ask` goes down the existing approval path unchanged: the turn driver calls
`zygos::approvals::request`, blocks in `awaiting_approval`, and dispatches
only on `{"approved":true}`. Anything else yields the `approval_denied`
tool result and the turn continues (U1, U2).

- **Console runs.** The mission CLI starts the approval worker `.manual`
  with `ZYGOS_APPROVAL_TIMEOUT_MS` (CLI default 300 s; timeout ⇒
  `approved:false`). The console or TUI prompts;
  stdin EOF stops prompting, and every later ask times out to deny.
- **Headless and campaign runs stay non-interactive.** The Harbor adapter
  provides no console and sets `ZYGOS_APPROVAL_TIMEOUT_MS=1000`, so each
  configured `ask` is denied (`resolved:false`) after one second. It never
  blocks past the timeout and never self-approves. In a campaign an `ask`
  behaves as a slower `deny`.
- **`ask` is not an independent boundary.** A same-user executor shell can
  append an approve line to `<planning>/control.jsonl`
  (`documentation/permissions.md`, "Remaining boundaries"). `deny` is the
  verdict that holds against the executor.

Known limits, out of scope here:

- In console mode, policy asks and the completion gate read the same stdin
  lines. A configured `ask` changes how many answers a run needs; a script
  that pipes a fixed number of `y` lines (as `test/e2e/m45/run.sh` does) must
  account for it. Absent `.policy` is unaffected.
- Each headless `ask` costs `ZYGOS_APPROVAL_TIMEOUT_MS` of wall clock and
  one tool step before the denial. A step that keeps asking spends its
  `role_max_steps` and the mission timeout.
- The prompt reads `approve <tool>: turn tool dispatch? [y/N]`; it does not
  show the step or the matched rule. Forwarding the policy reason is a
  `turn.zig` change to `requestApproval` and is not part of this issue.

## `zygos task --config`

Refused: a `zygos.zon` carrying `.policy` exits 2 with
`task: config refused (UnsupportedSetting)`, as for every non-routing
setting. `task_config.TaskZon` already accepts only `.default` and
`.routes`, so this needs no code, only a named test. The bench policy is
the ADR-001 allowlist (`bash`, `read_file`, `write_file`), and a task-mode
configuration arm changes the route table only. A task-mode campaign whose
arm config carries `.policy` therefore fails at the binary, as it does for
`.steps`.

## Visibility

**Trace.** When `.policy` is present, the mission trace gains a `policy`
event, written immediately after the `pipeline` event and before the first
`mission` event, every time the loop runs (fresh start and non-terminal
resume; a terminal or refused resume writes neither):

```jsonc
{"ts":N,"event":"policy","source":"config",
 "rules":[{"tool":"bash","verdict":"deny","step":"architect"},
          {"tool":"bash","verdict":"allow","step":null}]}
```

- **How it gets there.** The CLI passes the effective list on the
  `zygos::missions::start` request as an optional
  `"policy":{"source":"config","rules":[...]}`, built from the same slice it
  hands `PolicyWorker.start`. The driver checks the field's shape and refuses a
  structurally malformed one with `{"refused":true,"reason":"invalid_policy",...}`
  before any store write; it does not enforce the rules. A well-formed field
  is emitted as the event and nothing else. Absent field ⇒ no event, so hand-rolled
  callers and every existing driver test are unaffected. `source` is
  always `"config"` today; the field leaves room for other sources without
  a shape change.
- **Absent `.policy` writes no `policy` event.** No event means the
  built-in seed governed. Pre-#12 traces mean the same thing, and absent
  runs keep their current trace bytes.
- **Consumers.** `trace_event.zig` gains the `policy` variant, parsed
  tolerantly like `pipeline`. The text render prints one line,
  `policy (config, N rules): bash=deny@architect bash=allow web_*=ask@research*`.
  The AG-UI projector emits `CUSTOM` `zygos.policy` with
  `{"source","rules"}` as its value. The TUI ignores the event.

**Campaign arm identity.** No change is needed. `config_sha256` is the
SHA-256 of the whole `.zon` file, so two arms that differ only in `.policy`
already differ on the `config` axis: `variable: config` accepts them, and
`variable: build` refuses them as a second differing axis.

**`mission-run.json`.** No new field. It already records `config_sha256`,
which pins the exact `.policy` bytes, and the effective list is in
`planning/events.jsonl`, which the job already keeps. A second Python
parser of `.policy` could drift from the binary's.

**Campaign inspection.** One check, to catch a binary that predates this
spec. Such a binary silently ignores `.policy` (every one of its parsers
is lenient about it), so a config arm would run under the seed and look
like a valid result. `eval/campaign.py` detects a depth-1 `.policy` key in
the arm's `.zon` with the existing ZON tokenizer, the same contract as
`read_pipeline`: when the file cannot be tokenized and the text matches
`\bpolicy\b`, the experiment refuses. When the arm has `.policy`,
inspection requires a `policy` event in `planning/events.jsonl`; a missing
one is the recorded problem `policy event missing`. An arm without
`.policy` needs no event. Campaign does not parse or compare the rules.

## Version impact

Minor: `5.0.0` → `5.1.0`, section `Added`. It is a new capability, and a
file without `.policy` behaves exactly as before.

The one compatibility edge: a `zygos.zon` that already carried some
unrelated `.policy` key booted before (the key was ignored) and will now
refuse if that key is malformed. Nothing ever read `.policy`, so no operator
contract depended on it. That is a minor bump, not a major one.

## Consumers (updated in the implementation PR)

- `docs/specs/policy.md`: drop the Known limit, point here.
- `docs/specs/mission.md`: the start request gains the optional `policy`
  field and the `policy` trace event; the Known limit and the "Out of
  scope" line are replaced by a pointer here.
- `docs/specs/mission-boot.md` (policy seeding: the seed applies only when
  `.policy` is absent) and `docs/specs/mission-cli.md` (roster line; the
  `.policy` refusal).
- `docs/specs/trace.md`: the `policy` variant, its text render and the
  AG-UI `zygos.policy` mapping.
- `docs/specs/campaign.md`: the inspection check; add `.policy` to the
  task-mode refusal sentence.
- `docs/specs/task.md`: name `.policy` in the `UnsupportedSetting` list.
- `documentation/permissions.md`, `automation.md`, `flows.md`: the policy
  worker's rules come from `.policy` when present, else the seed.
- README (mission config and trace sections), `CHANGELOG.md`, `build.zig.zon`
  `.version`.

## Test contract (RED first)

Config module (`src/worker/policy_config.zig`, pure, `std.testing.allocator`):

1. `absent policy yields today's seed`: no `.policy` key ⇒ resolve returns
   the `policySeed` list (bash, web_fetch, web_search, MCP names; all allow;
   no step), equal to what the CLI seeds on `master`.
2. `present policy replaces the seed in file order`
3. `step pattern round-trips into Rule.step and absent step is null`
4. `other top-level keys are ignored by the policy parser`
5. One named test per boot-refusal row:
   - `policy malformed refuses`
   - `policy empty refuses`
   - `policy non-struct entry refuses`
   - `policy unknown key refuses naming the entry`
   - `policy missing tool refuses`
   - `policy empty tool refuses`
   - `policy bad tool pattern refuses` (interior `*`, non-string)
   - `policy missing verdict refuses`
   - `policy bad verdict refuses` (unknown literal, string `"allow"`)
   - `policy bad step pattern refuses` (empty, interior `*`, uppercase,
     over 32)
   - `policy step matching no configured step refuses` (exact and glob,
     default pipeline and a configured `.steps`)
   - `policy tool matching no offered tool refuses` (`read_file`;
     `zygos::mcp::*` with no MCP tools)
6. `step glob matching a configured step is accepted and star alone always passes`
7. `mcp tools are matched by model name or function id`
8. `step-scoped rule on a step without tools is accepted`
9. `lenient router, context and mcp parses ignore .policy`
10. `no leaks across resolve and refusal paths`

Driver and trace:

11. `policy event follows pipeline when the start request carries policy`
12. `no policy event when the start request carries none`
13. `policy event round-trips through trace_event`
14. `trace text renders the policy line`
15. `agui projects policy as zygos.policy custom event`

Behaviour through the real worker:

16. `configured per-step deny blocks one step's tool call and allows another's`:
    a mission driver test with a scripted provider, two tool-bearing steps,
    rules `bash deny @ step A` then `bash allow`; step A's tool result is
    `policy_denied`, step B's call dispatches.
17. `configured ask with an unanswered approval denies and the turn continues`:
    manual approval with a short timeout; `approval_denied`, no dispatch,
    and the turn reaches its next step.

Task:

18. `task --config refuses .policy as UnsupportedSetting`

Campaign (`eval/test_campaign.py`):

19. `test_policy_arm_without_policy_event_is_a_problem` (records
    `policy event missing`)
20. `test_arm_without_policy_needs_no_policy_event`
21. `test_untokenizable_zon_mentioning_policy_refuses`

End to end (not `zig build test`):

22. `test/e2e/m45/run.sh` gains a leg: a malformed `.policy` exits 2 with
    the `invalid .policy` reason, before the kernel boots and with no
    `events.jsonl` written. The existing legs (absent `.policy`) stay
    unchanged and green.

## Out of scope

- Argument-aware rules (matching the bash command, the URL or a path). The
  matcher stays tool name and function id, plus step.
- Forwarding the step or matched rule to the approval prompt (see the `ask`
  known limits).
- Policy for `zygos task` (the ADR-001 allowlist stays fixed).
- Changing the seed itself. The absent-config default stays today's
  allow list; changing it is the maintainer decision recorded in
  `documentation/permissions.md`.
- Per-occurrence rules for repeated step ids: a `step` pattern matches the
  id, so every occurrence of an id shares its rules, as it shares its
  route ladder.
