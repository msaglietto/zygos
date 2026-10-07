# Open Code Review evaluation — PR #4

Reviewed head: `ecd3444041492e897232f5b77b1dc7c146c75fe3`.
Base: `11bd42f5457238039ed83aab1a33c6a5cc0644f2` (`upstream/master`).
PR: https://github.com/msaglietto/zygos/pull/4.

## Run status and coverage

Executed OpenCodeReview 1.12.11 with the existing configured provider/model,
`z-ai-coding` / `glm-5.3`:

```sh
ocr review --from upstream/master   --to ecd3444041492e897232f5b77b1dc7c146c75fe3   --background-file /tmp/zygos-ocr-background.md   --concurrency 2 --effort high --format json   --output /tmp/zygos-ocr-review.json --color never
```

Initial session: `7d4e9c8d-d690-485f-8e3f-32c9083a63a8`.
The high-effort run was stopped after slow progress. OCR reports review elapsed
**14m39s** and terminal state **failed / cancelled**, with 5 completed files
and five recovered findings.

Retried the remaining files from that saved session:

```sh
ocr review --from upstream/master \
  --to ecd3444041492e897232f5b77b1dc7c146c75fe3 \
  --resume 7d4e9c8d-d690-485f-8e3f-32c9083a63a8 \
  --background-file /tmp/zygos-ocr-background.md \
  --concurrency 8 --effort low --timeout 5 --no-filter \
  --format json --output /tmp/zygos-ocr-resumed.json --color never
```

Retry session: `8c4befa9-7408-468b-b2a5-0eea4c5e3863`.
OCR reports **5m30s**, terminal state **partial**, with 6 newly completed files,
5 reused completed files, and 18 incomplete files (15 timeouts, 3 provider
failures). The provider returned HTTP 429 for the web-tools/filesystem/shell
group. No additional findings were emitted by the six completed runtime
files. Both runs used the same configured provider/model. The retry disabled
OCR's post-filter so its findings could be evaluated directly here.

**Combined coverage: 11 of 29 selected files completed.** The completed files
were the CI workflow, `.gitignore`, LICENSE, example provider catalog, provider
catalog parser, and these six runtime files:

- `src/worker/assembler.zig`
- `src/worker/sse.zig`
- `src/worker/openai.zig`
- `src/worker/anthropic.zig`
- `src/net/anthropic.zig`
- `src/net/openai.zig`

The incomplete files are:

- `src/kernel/sync.zig`
- `src/net/web_tools.zig`
- `test/e2e/ws/admission.mjs`
- `src/cli/mission.zig`
- `src/worker/tools_ops.zig`
- `src/worker/fsx.zig`
- `src/kernel/actor.zig`
- `src/kernel/trigger.zig`
- `src/tui/band.zig`
- `src/tui/scrub.zig`
- `src/net/ws.zig`
- `src/worker/mission_store.zig`
- `src/worker/mission_boot.zig`
- `src/main.zig`
- `src/tui/tui.zig`
- `src/tui/model.zig`
- `src/worker/mcp/transport.zig`
- `src/kernel/inproc.zig`

Default rules also excluded 26 changed files, mostly Markdown and `.zon`
files, plus the M8 fixture. The run is **not a full review or a clean runtime
verdict**. Kernel, mission/CLI, WebSocket, TUI, MCP, shell and filesystem
coverage remains incomplete. No further remote retries were started after
these timeout/rate-limit results.

## Evaluated feedback

| # | OCR severity | Finding | Evaluation and action |
|---|---|---|---|
| 1 | Medium | Shallow checkout invalidates Git probe inputs | Confirmed. Fetch history for this CI workflow (`fetch-depth: 0`); address before relying on the probe as merge evidence. |
| 2 | Low | Same-repo PR pushes run the full matrix twice | Confirmed. Restrict `push` to `master` while keeping `pull_request`, unless branch-only matrix runs are an intentional cost. |
| 3 | Low | Zig toolchain/packages downloaded on every matrix leg | Optional optimization. Cache packages/toolchain with version, OS/architecture, and relevant checksums in the key. Any new action must be pinned. Not a correctness blocker. |
| 4 | Low | Formatting only checks `src/` | Valid coverage improvement. `zig fmt --check build.zig src/ test/` would cover the other compiled sources without traversing fetched dependencies. The expanded check already passes on this head. |
| 5 | Low | Public provider example lacks a permanent parser drift guard | Valid optional regression coverage. The example already passed real CLI bootstrap validation. Reject the suggested relative `@embedFile` patch as written: it escapes the Zig module's package path. Use build wiring or an integration check. |

### 1. Shallow checkout: reproduced

[CI checkout](../.github/workflows/ci.yml) has no `fetch-depth` override.
The [probe](../test/probe/filter/main.zig) runs `git log -20` and
`git diff HEAD~1`, ignores `pclose` status in `capture`, and wraps the captured
output with `exit_code: 0`. With a one-commit checkout, the latter is an error
message rather than real diff data; a successful aggregate ratio does not
prove the intended Git cases ran.

Reproduced in an isolated local `git clone --depth 1` with a temporary HOME:

```text
git rev-list --count HEAD -> exit 0: 1
git log -20 --oneline -> exit 0: one commit
git diff HEAD~1 -> exit 128: ambiguous argument 'HEAD~1'
```

Fetching full history is the direct workflow fix. A future probe improvement
should also preserve/check command exit status so missing history cannot be
misrepresented as successful command output. The ratio floor should remain.

### 2. Duplicate workflow runs: verified

`push` is unfiltered and `pull_request` also runs. The concurrency key uses
`github.ref`, which differs for a branch push and a PR merge ref. The actual
checks on `ecd3444` include two macOS jobs and two Linux jobs, plus the separate
`verify` job. All passed, but the duplicates consume extra runner time.

### 4. Expanded format check: passes

```sh
zig fmt --check build.zig test/
```

Exited 0; the existing source-tree format check was already green.

### 5. Suggested example patch: rejected as written

The module root is under `src/`. An isolated Zig 0.16 reproduction of a
relative embed escaping a module root produced:

```text
error: embed of file outside package path: '../examples/providers.toml'
```

The intent is reasonable; the proposed patch is not compilable under this
package layout. A test should consume the real example through an explicitly
provided build input or the CLI, rather than copying its contents into a
second fixture.

## Recommendation

Fix finding 1 before treating the CI probe as complete merge evidence.
Finding 2 is a useful cost cleanup. Findings 3–5 are optional improvements;
none establish a current runtime defect. The incomplete runtime review still
needs completion before claiming OCR cleared the hardening changes.

This evaluation changed no implementation, workflow, version, or wire-format
files and posted no review comments to GitHub. The report is local review
material; the existing PR implementation and passing checks are unchanged.
