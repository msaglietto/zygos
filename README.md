# Zygos

A local agent harness in one Zig binary. You give it a brief. Four roles — product owner, planner, executor, verifier — work that brief until it is done or the run stops. Each role can use a different model. The run is written to disk as it goes, so you can leave, come back, and resume.

Workers, models, policy, and tools all sit on one message bus. The same bus speaks the [iii](https://iii.dev) wire protocol, so an existing iii SDK can register functions on a Zygos kernel.

> [!WARNING]
> Zygos is experimental software for a trusted local operator. A mission runs bash as your OS user, with the workspace as its working directory, an environment allowlist, and a two-minute process-group deadline. Default policy allows bash, web search, and web fetch. Text the executor fetches can ask for a shell command, and the process will run it. The executor can also append an approval to the mission control file. Read [SECURITY.md](SECURITY.md) and [permissions](documentation/permissions.md) before you point a run at a real workspace or a real key.

## What you get

- A mission loop with a durable `.planning/` directory. Kill the process and `zygos mission resume` continues from the last saved role.
- A route table that sends each role to its own provider, and fails over to the next attempt when a provider errors.
- An executor with bash, web search, and web fetch, plus any MCP servers you list in `zygos.zon`. Those calls pass through policy, approval, budget, and output compression.
- A live terminal view on a tty: mission state, the current task, the model in use, streamed reasoning, tool calls, and the answer.
- A second terminal on the same run: steer the next step, pause, resume, or answer an approval.
- A loopback kernel. Any iii SDK connects and registers functions. Mission mode itself stays in-process and does not publish its tools on that socket.
- Room for a vault. Set `ZYGOS_VAULT_ROOT` and the run checkpoints the vault before it writes. `zygos mcp-gateway` exposes the vault tools over stdio.

Milestone contracts live in [GOAL.md](GOAL.md). This file is how you use the binary.

## How a mission runs

```
defining → planning → executing → verifying → gating → done
```

| Role | Step id | What it does |
|---|---|---|
| Product owner | `product-owner` | Turns the brief into an objective and acceptance checks. |
| Planner | `planner` | Writes the task list. |
| Executor | `executor` | Runs the tasks. This is the only role that receives tools. |
| Verifier | `verifier` | Checks the success criteria and returns pass or fail. |

A failed verification sends the mission back to planning. So does an explicit denial of the completion gate. Three failed verifications in a row, or three explicit gate denials, stops the run. A timeout on the gate leaves the mission parked in `gating`. A missing gate, an unreachable gate, or a malformed gate reply can never mark the mission done.

By default each role is prompted from the files in `.planning/`. `zygos.zon` can select the `recall` or `thread` strategy; an unknown strategy refuses to boot. See [context](docs/specs/context.md).

When the mission reaches a terminal state it writes `LEDGER.md` (tokens used, bytes trimmed, role turns, final state) next to the other artifacts:

| File | Contents |
|---|---|
| `BRIEF.md` | The brief this run was started with. |
| `MISSION.md` | The objective the product owner accepted. |
| `PLAN.md` | The task list. |
| `VERIFY.md` | The verifier's verdict. |
| `events.jsonl` | Transitions, role boundaries, provider and model, and every tool call with its input and a clipped output. |
| `LEDGER.md` | The rollup you read after the run. |
| `control.jsonl` | Commands from `zygos mission attach`, including approvals. |

## Install

Zig 0.16.0, on macOS or Linux with glibc. CI runs on Ubuntu 24.04 and macOS 14.

```bash
zig build          # zig-out/bin/zygos
zig build test     # offline; no catalog, vault, or network
```

## Run a mission

The checked-in quickstart asks for a POSIX script that prints `Hello from Zygos`. It spends provider tokens and runs commands as your user. The token budget is a cap, not a price.

```bash
zig build
cp examples/providers.toml providers.local.toml
cp examples/quickstart/zygos.zon ./zygos.zon
```

Edit `providers.local.toml`: set `endpoint` and `model`, and export the variable named by `key_env`. Put that same model in `zygos.zon`. `providers.local.toml` is gitignored. Leave keys out of the file.

```bash
export AI_PROVIDERS_CONFIG="$PWD/providers.local.toml"
export ZYGOS_CONFIG="$PWD/zygos.zon"

workspace=$(mktemp -d)
bin="$PWD/zig-out/bin/zygos"
brief="$PWD/examples/quickstart/brief.md"
cd "$workspace"
"$bin" mission start "$brief"
```

On a terminal you get the live view. An approval is one key: `y` approves, and `n` or Enter denies. The approval timeout denies too. With nothing waiting, `s` opens a steer line for the next role boundary, `p` pauses, and `r` resumes. Ctrl-C aborts the mission and restores the terminal. `--no-tui` or `ZYGOS_NO_TUI=1` keeps the plain progress log, where an approval is a line on stderr and only a line starting with `y` approves. A pipe takes that path on its own.

Stdout is one JSON object when the mission finishes. Exit 0 means `done`. Exit 1 means `failed` or `aborted`. Exit 2 means the brief, catalog, route table, or boot refused the run.

> [!TIP]
> To watch the whole loop with no API key, run `./test/e2e/m45/run.sh` from the repository root. It needs Node.js and git, talks only to loopback fixtures, and does not read your provider catalog. More setups are in [examples/README.md](examples/README.md).

### The brief

A brief is Markdown with YAML frontmatter. Zygos lints it before the kernel boots and refuses a brief that fails. This is enough to start:

```markdown
---
mission: hello
budget:
  max_tokens: 20000
gates:
  completion: human
---

# Objective

Write a POSIX shell script `hello.sh` in the current workspace that prints
`Hello from Zygos` followed by a newline.

## Success criteria

| Criterion | Verified by |
|---|---|
| Script prints exactly `Hello from Zygos` plus a newline | `sh hello.sh` exits 0 |

## Non-goals

- Do not install dependencies or change files outside this workspace.
```

The lint requires `budget`, `gates`, a success-criteria table with a `Verified by` column and at least one row, and a non-empty non-goals section. The full quickstart is [examples/quickstart/brief.md](examples/quickstart/brief.md). The contract is [docs/specs/brief.md](docs/specs/brief.md).

### Providers

The catalog is TOML. `AI_PROVIDERS_CONFIG` overrides `~/.agents/providers.toml`. Each `[[providers]]` entry becomes a bus function `zygos::providers::<slug>` (`"Example OpenAI"` → `example-openai`). `[[clis]]` entries are ignored. A malformed catalog is an error, and the process exits before a mission starts.

```toml
[[providers]]
name = "Example OpenAI"
type = "openai_compatible"
endpoint = "https://api.openai.com/v1"
model = "your-model-id"
key_env = "OPENAI_API_KEY"
max_tokens = 4096
temperature = 0.2
```

Supported `type` values are `openai_compatible`, `anthropic_compatible`, `google`, and `ollama`. Parsing and validation are in [docs/specs/providers.md](docs/specs/providers.md).

### Routes

`ZYGOS_CONFIG` overrides `./zygos.zon`. `.default` is the ladder for any step you do not name. Each `.routes` entry is a `step_id` and an `attempts` list: attempt 0 uses the first provider, the next attempt uses the next, and an empty ladder fails the turn. A route that names a provider slug missing from the catalog refuses to boot.

```zon
.{
    .default = .{
        .{ .provider_function = "zygos::providers::example-openai", .model = "your-model-id" },
    },
    .routes = .{
        .{ .step_id = "executor", .attempts = .{
            .{ .provider_function = "zygos::providers::example-openai", .model = "your-model-id" },
        } },
        .{ .step_id = "verifier", .attempts = .{
            .{ .provider_function = "zygos::providers::example-openai", .model = "your-model-id" },
        } },
    },
}
```

Role step ids are `product-owner`, `planner`, `executor`, and `verifier`.

To add MCP tools, list servers in the same file. Zygos spawns each one over stdio, handshakes, and registers its tools as `zygos::mcp::<server>::<tool>`. The model sees `<server>_<tool>`. A server that fails the handshake refuses the run. A server that dies mid-run returns a structured error on the next call.

```zon
.{
    .default = .{
        .{ .provider_function = "zygos::providers::example-openai", .model = "your-model-id" },
    },
    .mcp_servers = .{
        .{ .name = "tavily", .argv = .{ "npx", "-y", "tavily-mcp" } },
    },
}
```

## While it is running

```bash
zygos mission start  <brief.md> [--planning <dir>] [--resume] [--run-stamp] [--no-tui]
zygos mission resume <brief.md> [--planning <dir>]
zygos mission queue  [--planning <base>] [--run-stamp] <brief.md>...
zygos mission trace  <planning-dir|events.jsonl> [--format agui|html]
zygos mission attach <planning-dir>
zygos mission dashboard <dir>
```

`start` uses `./.planning` unless you pass `--planning`. A second start against a directory that already holds a mission exits 2. `resume` continues that directory and does not repeat finished roles. `--run-stamp` gives this invocation its own directory, named `<root>-YYYYMMDD-HHMMSS-P<pid>`.

`queue` runs the briefs one after another in one process. Each brief gets its own planning directory, `<base>-<stem>`. A directory that already holds that mission is resumed. Ctrl-C aborts the mission in flight and does not start the rest.

`dashboard <dir>` prints one status line per mission substrate under that directory.

`trace` renders `events.jsonl`. The file is the record: mission transitions, which provider and model handled each step, and every tool call. If the file cannot be written, the mission still runs.

```bash
zygos mission trace .planning
```

`--format agui` writes the same log as AG-UI 1.0 JSONL. `--format html` writes one self-contained viewer file with those events inlined; it opens offline. Both redact secret-shaped values. A Harbor trial's agent directory works too:

```bash
zygos mission trace <jobs>/<trial>/agent --format html > run.html
```

The projection is specified in `docs/specs/trace.md`, under "AG-UI projection".

`attach` follows that same log from another terminal. Commands you type are appended to `control.jsonl`. A crashed run still shows its history, and the commands wait there until a resume picks them up.

```
steer <text>
pause
resume
approve <id> y|n
```

Ctrl-D detaches.

`ZYGOS_WORKTREE=1` (or `true`) checks out a detached git worktree at `<planning>/worktree` and runs the executor there. If `git worktree add` fails, the mission does not start.

### Search

| `ZYGOS_SEARCH_ENGINE` | What you also set |
|---|---|
| `brave` | The variable named by `ZYGOS_SEARCH_KEY_ENV` (default `BRAVE_API_KEY`). An unset key still boots; each search returns `MissingSearchKey`. |
| `searxng` | `ZYGOS_SEARCH_ENDPOINT`. No key. |

`web_fetch` accepts `http` and `https`. It refuses recognized literal private addresses and localhost unless `ZYGOS_FETCH_ALLOW_PRIVATE=1`.

### Knobs

Integer values that do not parse fall back to the default. A typo does not refuse boot.

| Variable | Default | Effect |
|---|---|---|
| `ZYGOS_BUDGET_MAX_TOKENS` | brief, else 1000000 | Token cap for the mission. When this variable is set it wins over `budget.max_tokens` in the brief. Crossing it stops the turn. |
| `ZYGOS_ROLE_MAX_STEPS` | 24 | Steps inside one role turn. |
| `ZYGOS_MAX_ROLE_TURNS` | 48 | Role turns in the mission. |
| `ZYGOS_MISSION_TIMEOUT_MS` | 24h | Ceiling on the mission call. |
| `ZYGOS_INVOKE_TIMEOUT_MS` | 1h | Ceiling on every other bus call. A provider timeout fails over to the next route. |
| `ZYGOS_STREAM_IDLE_MS` | 120000 | Closes a provider stream that sends nothing this long. `0` disables it. |
| `ZYGOS_APPROVAL_TIMEOUT_MS` | 300000 | Unanswered approval or gate denies. |
| `ZYGOS_LOG` | `warn` | `err`, `warn`, `info`, or `debug`. `info` is the progress feed when the TUI is off. |
| `ZYGOS_VAULT_ROOT` | unset | Checkpoint this vault before the mission writes to it. Checkpoint failure refuses the run. |

Closed stdin does not prompt. The approval timer denies, and an unattended mission cannot approve its own completion gate through the console. The executor's shell can still write `control.jsonl`.

## On a schedule

Nothing inside the binary fires on a clock. cron or launchd runs the CLI. Closed stdin makes console approvals time out and deny. `--run-stamp` keeps each fire in its own planning directory. A lock on `<planning>/claim` refuses a second process on the same directory.

```cron
0 7 * * 1  cd /path/to/workspace && ZYGOS_CONFIG=/path/to/zygos.zon \
  /path/to/zygos mission start /path/to/brief.md --run-stamp < /dev/null
```

Put the provider `key_env` variables, and the search settings if you use them, in that crontab's environment. Details are in [documentation/cron.md](documentation/cron.md).

## The worker bus

With no subcommand, Zygos is the kernel. It listens on `127.0.0.1` and the port in `ZYGOS_PORT` (default `49134`, the iii SDK default). Ctrl-C stops it.

```bash
ZYGOS_PORT=49134 ./zig-out/bin/zygos
```

Browsers send `Origin`. Those connections are refused unless the origin is listed in `ZYGOS_ALLOW_ORIGIN` (comma-separated, exact match). When `ZYGOS_TOKEN` is set, every worker must open `ws://127.0.0.1:<port>?token=<secret>`. A peer that gets in can register and invoke functions. Mission mode does not open this listener; its tools stay in-process.

An iii SDK connects as it would to any iii kernel:

```javascript
import { registerWorker } from 'iii-sdk'
const iii = registerWorker('ws://localhost:49134')
iii.registerFunction('hello::greet', async (input) => ({ hi: input.name }))
```

Extensions are new `zygos::*` functions. The frame format is [docs/PROTOCOL.md](docs/PROTOCOL.md).

### Vault tools over MCP

`zygos mcp-gateway` serves the vault over stdio: project status, open threads, stale projects, reflect, session open, session close, checkpoint, and undo. `ZYGOS_VAULT_ROOT` is required. `tessera_capture` is named in the tool list and is not registered on this process, because capture needs a provider and a taxonomy, so that call returns a JSON-RPC error. An unknown tool does too.

## Headless task (offline)

`zygos task` is the entry a benchmark runner calls. It is a single scripted or live task in a workspace. There is no product-owner gate, and exit 0 means the process finished.

```bash
zygos task run --offline --workspace DIR --out trial.json --events events.jsonl
zygos task score --trial trial.json --prices prices.txt
```

`--offline` uses the scripted provider. A live run names an allowlisted model and a complete invocation; `--config zygos.zon` routes that step through the file's `.default` and `.routes` ladders. The trial records the git sha, target, optimize level, and config hash. Bench policy allows bash, read, and write inside the workspace.

Matched two-arm campaigns (two builds, two route tables, or trim on against trim off) are `eval/campaign.py`. The experiment file freezes the tasks, model, prices, step cap, and repeats, and names the one variable the arms differ in.

```bash
ZYGOS_ZIG=/path/to/zig-0.16 eval/campaign.py build --git-ref <sha>      # Linux arm from a clean worktree
eval/campaign.py run --experiment eval/experiments/trim-ablation.json \
    --jobs-dir /tmp/zygos-trim-ablation --tasks-dir <terminal-bench-2-1>/tasks
eval/campaign.py report --experiment eval/experiments/trim-ablation.json \
    --jobs-dir /tmp/zygos-trim-ablation --out reports/benchmarks/trim-ablation-<date>
```

The report states a verdict or the reason it is inconclusive; durable reports live under `reports/benchmarks/`. An experiment with `"mode": "mission"` runs each task through the mission loop with the arm's `zygos.zon` as the mission configuration (which model does each step), for example `eval/experiments/mission-routing.json`. The contract is [docs/specs/campaign.md](docs/specs/campaign.md). What a run is allowed to spend is [docs/benchmark-policy.md](docs/benchmark-policy.md).

```bash
zygos task run --help
```

## Where to go next

| | |
|---|---|
| [examples/README.md](examples/README.md) | Fixture demo and a real-provider quickstart. |
| [documentation/architecture.md](documentation/architecture.md) | What the binary actually does, and the trust boundaries. |
| [documentation/automation.md](documentation/automation.md) | What a role may do, and what the process enforces. |
| [documentation/variables.md](documentation/variables.md) | Environment, files, and secrets. |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Layer sketch: kernel, harness workers, mission loop. |
| [docs/specs/](docs/specs/) | Per-module contracts. |
| [SECURITY.md](SECURITY.md) | The operator threat model. |
