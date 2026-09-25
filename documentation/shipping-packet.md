## Shipping Packet: zygos

### Documentation Inventory

| Doc | Status (present / stale / missing / n/a) | Notes |
|---|---|---|
| `documentation/architecture.md` | present | Implemented trust boundaries. Points at `GOAL.md` and `docs/ARCHITECTURE.md`. |
| `documentation/flows.md` | present | Eight journeys with the deny case and the side effect. |
| `documentation/permissions.md` | present | No accounts. Process, bus worker, and policy rules. |
| `documentation/variables.md` | present | Env and files. No client bundle. |
| `documentation/cron.md` | present | External cron only. The kernel does not fire on a clock. |
| `documentation/automation.md` | present | Role agents, capture, MCP gateway, web tools. |
| `emails.md` | n/a | The process sends no mail. |
| `seo.md` | n/a | No public routes. |
| `docs/ARCHITECTURE.md` | present | Layer sketch. A pointer to `documentation/` was added. Milestone narrative stays. |
| `docs/PROTOCOL.md` | present | Unchanged. Human-gated. |
| `docs/specs/mission-cli.md` | present | The 2026-07-18 "unfixed brave key" note was false. `searchConfigFromEnv` already sets `key`. |
| `README.md` | present | Same brave note removed. Suite count set to 848. |
| `ROADMAP.md` | present | Y5 is no longer described as blocked by the brave key bug. |
| `tests.md` | present | Coverage map. |
| SQL migrations | n/a | No database. |

### Agent Context

CLAUDE.md / AGENTS.md: updated.

`AGENTS.md` keeps the TDD law, commands, filter probes, and human gates, and now states the trust rules a change must not weaken. `CLAUDE.md` in this checkout carries the same prohibitions. `.gitignore` lists `CLAUDE.md`, so that file stays on this machine and is not in git. The tracked instructions are `AGENTS.md`.

### Test Coverage

Pinned by existing tests: wire, catalog CAS, invocation UUID, triggers, channels, policy fail-closed, approval, budget, mission gate park vs replan, brief lint, resume id, budget precedence, brave key resolution, lexical path escapes, fetch scheme, role parse, run-stamp refusal, unknown provider, tail suffix read, digest read cap, session prefix read, filter guards.

Proposed: a hosted required check that runs `zig build test` and `zig fmt --check src/`. Not added.

Guarded-live: `test/smoke/providers.sh`, `test/e2e/anthropic/run.sh`, `test/e2e/openai/run.sh`.

Unverified: GOAL Y5, the real-vault unattended run.

Detail is `tests.md`. Each fixed finding below names the test that pins it.

### Correctness Summary

Iteration 0 walked ten flows: budget configure, completion gate, invocation id, catalog CAS, policy versus the tool call, tool_result id, resume identity, search key, role parse, workspace resolve versus `open`. No finding survived the five checks.

The probes that were built and then dropped:

- A non-integer `ZYGOS_BUDGET_MAX_TOKENS` keeps 1_000_000 and ignores the brief. `documentation/variables.md` and `mission_boot.envInt` say that. Not a contradiction.
- Tool results cannot attach to the wrong call. Dispatch is one blocking `worker.call` per block, and the result id is that block's id (`src/worker/turn.zig`).
- A symlink inside the workspace is followed by `open`. GOAL T5 and the module comment require lexical rejection. `documentation/permissions.md` records the symlink as unchecked. The correctness pass did not treat that as a broken lexical check.

Kept correctness findings: none. There is no five-check record because nothing was kept.

### Security Summary

Examined by a Grok subagent against `documentation/*.md` and `GOAL.md`. A02, A06, and A09: no evidence. Two findings kept. Both need a human decision, so they were not patched.

1. High. The completion gate is not independent of the executor shell.
   - Risk: an unattended run can reach `done` without an operator.
   - Attack: with the default seed, `bash` may append `{"cmd":"approve","id":"a-1","approved":true}` to `<planning>/control.jsonl`. The mission polls that file and calls `zygos::approvals::resolve`. The first gate id is `a-1` (`src/worker/approval.zig`).
   - Impact: cron's closed stdin never gets to deny. The mission completes.
   - Evidence: `src/worker/mission_boot.zig` `policySeed` allows bash. `src/cli/mission.zig` `controlLoop` turns every line into a bus call. `src/worker/mission.zig` `gate` applies `gate_approved` on `approved: true`.
   - Fix would change a contract: `mission attach` uses the same file to approve, and bash is allowed on purpose (`src/cli/mission.zig` comment on the X3 seed). A same-uid shell can write any path the process can write. Choosing a sandbox, a separate gate channel, or an explicit "the gate is not a boundary while bash is allow" is a human call.

2. High. The mission seed allows `bash`, `web_fetch`, and `web_search` with no `ask`.
   - Risk: text the executor fetched becomes a shell command.
   - Attack: a page or an MCP description asks for `bash`. Policy matches the tool name and does not read the command (`src/worker/policy.zig`).
   - Impact: the operator's uid, workspace, and env (including provider keys if a command prints them into `events.jsonl`).
   - Evidence: `policySeed` in `src/worker/mission_boot.zig`. `documentation/automation.md` already states this.
   - Changing the seed to `ask` or `deny` changes the X3/X5 execution contract. Not patched.

Loopback WebSocket auth, symlink follow on file tools, and provider redirects were examined and dropped. The reasons are in the iteration-0 security notes: mission mode does not open the socket, file tools are not in the model tool list, and provider clients do not forward a bearer on a cross-origin redirect of a POST.

### Performance Summary

No database, so no N+1 SQL, no over-fetch of rows, and no index. Ranked by impact per effort. All three code items are fixed and pinned.

| Rank | Where | Finding | Effort | Priority | Expected effect | Status |
|---|---|---|---|---|---|---|
| 1 | `zygos mission attach` and the in-process control poll | `Tail.poll` read the whole file every 300 ms, then sliced at `offset` | Low | Medium | Poll cost follows new bytes | Fixed in `82ab22b`. Test: `Tail.poll reads only the suffix and notices a replaced file`. |
| 2 | Thread context strategy, executor assemble | `git ls-files` was read to EOF and then cut to `digest_bytes` (2048) | Low | Medium | Large repos stop the listing at the cap | Fixed in `f4cdf43`. Test: `PopenRunner stops at the read cap and still returns those bytes`. |
| 3 | `project_status`, `stale_projects`, `reflect`, `open_threads`, `session_open` | Each call parsed all of `SESSIONS.md` to use the newest one or three entries | Medium | Medium | Reads stop at 3 headers (orient) or 1 (`session_open`) | Fixed in `81ce552`. Test: `readThroughSessions stops before the next session header`. |

Tool dispatch stays sequential because policy, approval, and abort are per call (`src/worker/turn.zig`). That is the turn spec, not a waterfall to parallelize. Filter dedup already caches command output with an invalidation rule (`src/worker/filter/cache.zig`). `session_close` still reads the whole sessions file because it prepends.

Iteration 1 re-read those three diffs. No new performance finding.

### Independent Review

not run

Codex (`gpt-5.6-sol`) was started twice as a fresh session, with no checklist and no prior findings. The subject was `git tag` (empty), `git log --oneline` (212 commits, HEAD `b839ff0` at the start), and `git status`. Both sessions exited 0 without reading the tree: "timed out negotiating with the code-mode host", then the same failure under the workspace-write sandbox. Session ids: `01a0d5de-7201-7d01-ae88-aa7c7542b872` and the retry recorded in the scratch log. There are no findings to hand-verify. This is not a clean review.

### Audit Provenance

- Iteration 0 was the full sequence: docs, agent context, correctness over the ten flows above, security, performance, the Codex attempt, `tests.md`.
- Iteration 1 re-audited only the areas changed by the three fixes (`Tail.poll`, `PopenRunner.run` / `digestBlock`, `readThroughSessions` and its two callers). Zero new AUTO findings. The loop stopped there. Cap is 5. Count used: 1.
- Correctness, security, and performance subagents ran as Grok, the same family as this session. They were not routed to another model. No Fable classifier reroute applies on this runner.
- The independent model was Codex `gpt-5.6-sol`. It did not complete a read of the tree. Section above: not run.
- `docs/PROTOCOL.md` and `build.zig.zon` were not edited.

### Launch Blockers

- Y5 is still the human gate in `GOAL.md`: an unattended run against the real Zahir vault, with artifacts behind a tessera checkpoint and a diff against the SDK-run brief. `zig build test` does not cover it.
- The completion-gate file is writable by the executor while bash stays allow. Do not treat a cron run as "parked unless a person approves" until that choice is made.
- Independent review did not run. A second model never saw the tree.

### Recommended Next Actions

1. Decide the gate. Either sandbox bash so it cannot write `control.jsonl`, or stop describing that file as an operator-only approval path while bash is allow.
2. Decide whether the mission seed stays `allow` for bash and web tools. The code and `documentation/automation.md` match each other today.
3. Run the Y5 vault mission when you want that milestone closed.
4. Re-run an unsteered Codex (or other) review when its workspace shell can read the tree.
5. If you want a hosted merge gate, require `zig build test` and `zig fmt --check src/` on `main`. Not added here.

## Closing table

| Finding | Bucket | Status (fixed+verified / deferred) |
|---|---|---|
| `Tail.poll` re-read the whole log every poll | AUTO | fixed+verified. Commit `82ab22b`. Test `Tail.poll reads only the suffix and notices a replaced file`. `zig build test` 848 passed. |
| `git ls-files` read to EOF inside the digest cap | AUTO | fixed+verified. Commit `f4cdf43`. Test `PopenRunner stops at the read cap and still returns those bytes`. |
| Orient and `session_open` parsed every session to use the newest ones | AUTO | fixed+verified. Commit `81ce552`. Test `readThroughSessions stops before the next session header`. |
| Spec, README, and roadmap still said the brave key was unresolved | AUTO | fixed+verified. Commit `ba52b7f`. Code already matched `searchConfigFromEnv`; the regression test is `brave resolves key_env into key at boot` in `src/worker/mission_boot.zig`. |
| Executor bash can approve the completion gate through `control.jsonl` | HUMAN | deferred. Needs a decision: sandbox bash, split the attach channel from the gate, or accept the gate is not a boundary while bash is allow. A same-uid shell can write any path this process can write, so a token in the planning root does not close it. |
| Default mission policy allows bash and web tools, so fetched text can run a shell | HUMAN | deferred. `policySeed` matches the X3 comment and `documentation/automation.md`. Changing it to `ask` changes the execution contract. |
| Y5 real-vault unattended run | HUMAN | deferred. `GOAL.md` leaves that run as a human gate. No secret, vault, or production access was used. |

GOAL MET: 3 findings remain, all requiring human intervention
