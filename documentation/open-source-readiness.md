# Open-source readiness

Reviewed 2026-10-01 against the repository audit of 2026-09-30 (the audit report itself is no longer kept in the tree).
That audit described `a2a9bf0`; this branch already contained thirteen follow-up
commits when this review began. The MIT license and most priority fixes were
present. Five unfinished stream-limit edits were preserved and completed.

The repository is prepared for maintainer review as **experimental software
for a trusted local operator**. It is not a sandbox or a multi-user service.
Publication itself was not performed. The remaining trust limits must travel
with the code; they are stated prominently in [README](../README.md),
[SECURITY](../SECURITY.md), and [permissions](permissions.md).

## Completed preparation

- Checked the existing delivery lifetime barriers, duplicate-invocation reply,
  trigger ownership guard, provider bounds, and environment allowlist against
  the audit's cited paths and regressions.
- Completed bounded SSE event storage, both provider assemblers, OpenAI tool
  indexing, MCP reply lines and read deadline, and live TUI previews.
- Completed terminal scrubbing for invalid/C1 UTF-8, tool names, and decoded
  trace text, with a render-level regression.
- Added a shell process-group deadline and reap on every error path. A
  repeated undo run exposed a macOS race when parent and child both changed
  the child group; only the child establishes it now. Timeout cleanup also
  kills the direct child in case the group has not been established yet.
- Replaced the racy stale-PID claim takeover with a permanent file held by
  `flock`; failures refuse, crash closes the descriptor, substrate checks
  happen under the lock, and stamps return only formatted bytes.
- Added CI for Ubuntu 24.04 and macOS 14, contribution/security/conduct docs,
  issue and PR templates, public provider/brief examples, and ignore rules for
  local planning data/catalogs.
- Confirmed and copied the sole dependency's pinned MIT notice into
  [THIRD_PARTY_NOTICES](../THIRD_PARTY_NOTICES.md).

Build support is Zig 0.16.0, macOS, and Linux with glibc 2.36+. The current
CSPRNG calls do not support musl or older glibc targets. The workflow downloads
the fixed Zig release from ziglang.org and verifies its pinned SHA-256.
Dependencies are fetched before tests; `--system zig-pkg` then disables package
fetching. Runtime unit tests remain fixture-only and do not use the network.

## Maintainer publication tasks

1. Review and accept the documented same-UID shell/control-channel contract,
   or schedule an isolation/policy redesign before promoting a stronger
   authorization claim. A same-user token does not prevent self-approval.
2. Review the actual branch being published. The original audit did not cover
   every side branch; do not publish all refs blindly. No history rewrite was
   performed here.
3. Enable GitHub private vulnerability reporting and require both CI checks
   after their first hosted run. The workflow file does not enable repository
   settings or prove that hosted runners passed.
4. Include LICENSE and THIRD_PARTY_NOTICES alongside any distributed binary.
   No release artifact or deployment was published here.

Y5 remains an unrun real-vault milestone acceptance gate. It is distinct from
the source-publication decision. GOAL.md and docs/PROTOCOL.md remain
unchanged. The build manifest was left unchanged during implementation. PR preparation then incorporated
the newer default-branch versioning/verification changes and records version
4.0.0 in the existing manifest field and CHANGELOG; dependency entries and the
package fingerprint remain unchanged.

## Remaining engineering work

- Shell is allow-by-default, can read credentials on disk, and can write
  completion approvals. Allowed MCP tools can have comparable filesystem
  privileges. The completion gate is an orchestration check, not independent
  human authorization.
- Fetch screening covers the literal host, every resolved address, and every
  redirect hop, and dials the screened address. It is not a complete SSRF
  defense: direct shell and MCP networking bypass it, search endpoints are
  operator config, the system resolver is trusted, and Teredo is not decoded.
- Atomic writers fsync file data, but do not fsync parent directories.
  Power-loss durability and concurrent read/modify/write vault updates are not
  guaranteed by the temp-file uniqueness fix.
- MCP line reads are bounded. Blocking writes and continuous unmatched
  notifications still need a whole-request deadline.
- Transcripts are not secret-redacted. File-tool confinement follows symlinks.
  Remaining Low audit themes are backlog, not implicitly fixed by this work.

## Validation

Local results for the final formatted tree:

| Check | Result |
|---|---|
| `zig build test --system zig-pkg --summary all` | Passed: 889/889 |
| `zig fmt --check src/` and `git diff --check` | Passed |
| Native `zig build --system zig-pkg` | Passed |
| Linux cross-build, `-Dtarget=x86_64-linux-gnu.2.36` | Passed; Linux runtime is for hosted CI |
| Scripted CLI/MCP integration, `test/e2e/m45/run.sh` | Passed: start, resume, gate, config refusal, checkpoint, trace, MCP, 96% real-command reduction |
| Real filter probe and M8 seam | Passed: 82% probe reduction against a 45% floor; M8 real git output reduced 63% |
| Timeout integration | Passed: stream idle, subcall timeout, mission ceiling |
| WebSocket admission and delivery lifecycle | Passed: default/explicit Origin admission, missing/wrong/right token, reply/disconnect churn; added to CI |
| Repeated Tessera undo after process-group fix | Passed: 100/100 focused repetitions |
| Public catalog/route/brief bootstrap | Accepted; deliberately missing fixture vault refused before any provider execution |
| Workflow YAML and embedded shell syntax | Parsed/checked locally; hosted execution pending |
| Secret-shaped content scan, tracked + eligible untracked files | No matches for the scanned key/token/private-key patterns; not a full credential audit |
| GitNexus impact/change scope | Reviewed; HIGH/CRITICAL provider and terminal paths disclosed before edits |

Local CLI integrations use a temporary HOME and a clean environment with no
real provider keys or vault. No provider smokes or npm-based SDK installation
were used. New behavior regressions were observed red before implementation;
existing unfinished guard edits were preserved and pinned with tests.
