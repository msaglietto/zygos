# Automation

The product is the automation. This file is the line between what a model proposes and what the process enforces.

## Mission role agents

| | |
|---|---|
| Trigger | `zygos mission start` or `resume`, or `missions::start` on the bus. |
| Owner | The operator who launched the process. |
| Runs automatically? | Yes, through every pipeline step (`running`: by default product-owner, planner, executor, and verifier). `done` waits for the completion gate. |
| May read | Brief, `.planning/` artifacts, tool results, vault notes when tessera workers are booted. |
| May call | The mission tool list is `bash`, `web_search`, `web_fetch`, plus `zygos::mcp::<server>::<tool>` for servers in `zygos.zon` (`src/worker/mission/start.zig`). Other roles are not handed tools. `read_file` and `write_file` are registered on the bus and are not in that list. Bash can still read and write files, and it can append to `<planning>/control.jsonl`, which the running CLI treats as an attach command, including approve. |
| Steering | Role prompts assembled from the persisted artifacts (`GOAL.md` M3 notes). Playbook text is data (`worker/playbook.zig`). `missions::steer` merges operator input into the next step. |
| Hard guardrails (not the prompt) | W1 brief lint before the FSM. Fail-closed parse of role JSON (malformed objective, plan, or verdict fails the mission). Policy check when `policy_function` is set. Approval worker for `ask`. Budget check. Workspace lexical path check on file tools. URL scheme check on fetch. Escalation after `test_fail_threshold` consecutive verify failures or gate denials. Route ladder exhaustion fails the turn. Unknown provider slug refuses boot. |
| Output contract | Structured role payloads. Parse failure writes `REJECTED-<role>.md` and fails the mission. It does not guess. |
| App-owned side effects | FSM transition, atomic state save, artifact files, budget ledger, trace events, vault checkpoint. |
| Agent-owned suggestions | Plan tasks, tool-call arguments, verifier verdict text. The driver decides whether they execute. |
| Controls | Completion gate. `missions::abort`. Approval timeout deny. `ZYGOS_BUDGET_MAX_TOKENS` / brief budget. `ZYGOS_MAX_ROLE_TURNS`, `ZYGOS_ROLE_MAX_STEPS`. Stream idle and invoke timeouts. |

Default mission policy allows bash and both web tools. A prompt-injected page can ask the executor to run a shell command, and the process will, unless the operator changed the rule to `ask` or `deny`. That is the current contract, not a hidden path.

## Tessera capture

| | |
|---|---|
| Trigger | `zygos::tessera::capture` on the bus. Not registered on the mcp-gateway path. |
| Owner | Whoever invokes the function. Mission CLI does not have to boot it. |
| Runs automatically? | Only when called. Classification is one `turns::run` with `step_id:"tessera-capture"`. |
| May read | The raw capture string and the taxonomy from `zygos.zon` (not hardcoded). |
| May call | The routed provider. Destination write is the worker, not the model. |
| Steering | Taxonomy in config. |
| Hard guardrails | Malformed classifier output falls back to the ideas destination with `#needs-review`. Shadow-git checkpoint before the write. Undo restores the checkpoint. Undo with no checkpoint is an error. |
| Output contract | A written note, or the fallback note. Capture is not dropped. |

## MCP gateway (outward)

| | |
|---|---|
| Trigger | A client speaking JSON-RPC on stdio to `zygos mcp-gateway`. |
| Owner | The parent process. |
| Runs automatically? | Serves until stdin closes. |
| Tools | Registered tessera functions only. `capture` is absent and returns a bus error, which the gateway turns into a JSON-RPC error. |
| Hard guardrails | `ZYGOS_VAULT_ROOT` required or the process exits 2. Unknown tool is an error. |

## Web tools as a model-driven effect

Fetch and search are tools, not background jobs. The model chooses the URL and the query. Caps, scheme checks, and the policy gate are the hard limits. Host allow-lists are not. Fetched text is tool output: it re-enters the next prompt after trim, which is a prompt-injection path the policy gate does not inspect.

## Kill switch

`missions::abort`, SIGINT on the CLI (gateway stops, kernel joins), or refusing boot. There is no remote kill switch.
