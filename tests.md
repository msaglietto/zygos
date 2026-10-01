# Test coverage

Rules below are the ones whose failure crosses a trust, spend, or durability boundary. Status words are only: pinned by existing tests, proposed, guarded-live, unverified.

`zig build test` is the leak-checked, offline merge check. `.github/workflows/verify.yml` reports formatting and tests on pull requests and pushes to `master`; `.github/workflows/ci.yml` additionally checks builds and local integrations on macOS and Linux. Requiring checks is a maintainer repository setting. GitHub Free rejects branch protection on a private repository, so a red check is visible but does not block the merge button. Test counts come from `zig build test --summary all`, not a fixed documentation count.

## Existing coverage

| Use case | Rule | Expected, including the deny | Evidence | Type | Status |
|---|---|---|---|---|---|
| Wire round-trip | S1 frames parse and serialize | Malformed frames rejected | `GOAL.md` S1, `src/kernel/protocol.zig` | unit | pinned by existing tests |
| Catalog owner | Stale disconnect does not evict a newer registration | CAS no-ops the stale owner | `GOAL.md` S2, `src/kernel/catalog.zig` | unit | pinned by existing tests |
| Invocation id | Result joins the pending call by UUID | Unknown or late id is dropped; old generation cannot time out a reused id | `GOAL.md` S3, `src/kernel/invocation.zig` | unit | pinned by existing tests |
| Triggers | Type re-registration replays bindings; connection-owned bindings die with the socket | Durable bindings survive | `GOAL.md` S4, `src/kernel/trigger.zig` | unit | pinned by existing tests |
| Channels | Single take, access key required | Wrong key does not take | `GOAL.md` S5, `src/kernel/channel.zig` | unit | pinned by existing tests |
| Turn policy | Unreachable, malformed, or unknown verdict denies | Tool is not called | `GOAL.md` U1, `src/worker/turn.zig` | unit | pinned by existing tests |
| Approval | Only `approved: true` dispatches | Timeout deny does not dispatch | `GOAL.md` U2, `src/worker/approval.zig` | unit | pinned by existing tests |
| Budget | Over limit or unreachable check stops the turn | `stop: budget_exhausted` | `GOAL.md` U5, `src/worker/budget.zig`, `src/worker/turn.zig` | unit | pinned by existing tests |
| Mission gate | Unanswered deny (`resolved: false`) parks in `gating` | Answered deny replans; approve reaches `done` | `documentation/flows.md` flow 4, `src/worker/mission.zig` | unit | pinned by existing tests |
| Brief lint | Failing W1 lint refuses before the FSM | Structured `refused: true` | `GOAL.md` W1, `src/worker/brief.zig` | unit | pinned by existing tests |
| Resume identity | Loaded `mission_id` must equal the request | Mismatch is `MalformedRequest` | `src/worker/mission.zig` | unit | pinned by existing tests |
| Budget precedence | Env, else brief `budget.max_tokens`, else 1_000_000 | Non-integer env keeps the default | `documentation/variables.md`, `src/worker/mission_boot.zig` | unit | pinned by existing tests |
| Brave key | `searchConfigFromEnv` copies the named env var into `key` | Missing key leaves `key` null | `docs/specs/mission-cli.md`, `src/worker/mission_boot.zig` | unit | pinned by existing tests |
| File confinement | Lexical `..` and absolute paths rejected | Inside-root `..` allowed | `GOAL.md` T5, `src/worker/tools_ops.zig` | unit | pinned by existing tests |
| Fetch URL | Only http(s) with a host | `file:` rejected | `src/net/web_tools.zig` | unit | pinned by existing tests |
| Role output | Malformed objective, plan, or verdict fails the mission | No guessed object | `GOAL.md` V3, `src/worker/mission/role_turn.zig` | unit | pinned by existing tests |
| Run stamp | Existing substrate without resume or `--run-stamp` refuses | Stamp builds a new root | `documentation/cron.md`, `src/worker/mission_boot.zig` | unit | pinned by existing tests |
| Unknown provider | Route slug missing from the catalog refuses boot | No partial boot | `GOAL.md` X2, `src/net/provider_boot.zig` | unit | pinned by existing tests |
| Attach tail | `Tail.poll` returns only new complete lines, and a second poll does not allocate the prefix | A replaced shorter file is read again | `src/worker/control.zig` test `Tail.poll reads only the suffix and notices a replaced file` | unit | pinned by existing tests |
| Git digest | `PopenRunner` stops at the byte cap and still returns those bytes | `false` with no cap returns null | `src/worker/context_thread.zig` test `PopenRunner stops at the read cap and still returns those bytes` | unit | pinned by existing tests |
| Session read | Orient and `session_open` read only through the sessions they use | Bytes after the next header are absent | `src/worker/tessera/vault.zig` test `readThroughSessions stops before the next session header` | unit | pinned by existing tests |
| Mission tool list | The start body offers bash, web_search, and web_fetch | `read_file` and `write_file` are not in the list | `src/worker/mission/start.zig` test `mission start offers bash, web_search, and web_fetch only` | unit | pinned by existing tests |
| Output filters | Real git output is compressed; deleting a guard fails the suite | `raw: true` bypasses the seam | `test/e2e/m8/run.sh`, `test/mutation/guards.sh`, `test/probe/filter/run.sh` | integration | pinned by existing tests |
| PR verify | Each pull request runs `zig fmt --check src/` and `zig build test` | A format or test failure fails the job. The merge button stays available on this GitHub plan | `.github/workflows/verify.yml` | integration | pinned by existing tests |

## Proposed tests

No proposed case is written here. The two security items in the shipping packet are product decisions, not tests to add until a human picks the contract.

## Guarded-live

| Use case | Rule | Expected, including the deny | Evidence | Type | Status |
|---|---|---|---|---|---|
| Provider smoke | Two catalog providers both complete one turn | Skipped when keys are absent | `GOAL.md` X4, `test/smoke/providers.sh` | guarded-live | guarded-live |
| Anthropic / OpenAI smoke | One real streaming call | Exit 2 without the key | `test/e2e/anthropic/run.sh`, `test/e2e/openai/run.sh` | guarded-live | guarded-live |
| Node SDK | Unmodified iii SDK registers and invokes | Non-zero on failure | `GOAL.md` S6, `test/e2e/node-sdk/run.sh` | integration | pinned by existing tests |
| Y5 vault run | Unattended mission against the real Zahir vault | Human runs it; not part of `zig build test` | `GOAL.md` Y5 | manual | unverified |

The Node SDK leg is deterministic once `npm install` has happened. It is not part of `zig build test`.

## Gaps

| Use case | Rule | Expected, including the deny | Evidence | Type | Status |
|---|---|---|---|---|---|
| Y5 exit | Real-vault unattended research mission | Documented run with a diff against the SDK brief | `GOAL.md` Y5 | manual | unverified |

Symlink targets of `read_file` / `write_file` are not re-checked. That is the written contract (`documentation/permissions.md`, the comment in `src/worker/tools_ops.zig`), not a gap against a rule the tests claim to pin. Lexical escapes are pinned.
