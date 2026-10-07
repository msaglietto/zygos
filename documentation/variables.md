# Variables and secrets

Nothing in the client bundle path applies: there is no browser bundle. Secrets live in the operator environment or in `~/.agents/providers.toml`, which tests never read and which is not part of this repo.

Integer knobs go through `mission_boot.envInt`. A missing variable uses the default. A non-integer value also uses the default (no boot error).

| Name | Used by | Scope | Source | Rotation | Risk |
|---|---|---|---|---|---|
| `AI_PROVIDERS_CONFIG` | catalog path | server | env, else `$HOME/.agents/providers.toml` | replace the file | Path may point at a file with inline keys. |
| Provider `key_env` (per entry; examples in fixtures: `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GOOGLE_API_KEY`, `NVIDIA_API_KEY`) | `provider_boot` | server | process env | rotate at the provider | Bearer token on provider HTTP. Inline `key` in the toml is the fallback and is worse (secret at rest on disk). |
| `ZYGOS_CONFIG` | route table path | server | env, else `./zygos.zon` | n/a | Config, not a secret. Names provider slugs. |
| `ZYGOS_PORT` | bare kernel | server | env, else 49134 | n/a | Binds loopback only. Bad parse keeps 49134. |
| `ZYGOS_LOG` | `std.log` filter | server | env | n/a | `info` logs progress. Do not rely on it to redact tool output. |
| `ZYGOS_VAULT_ROOT` | tessera workers, pre-mission checkpoint | server | env | n/a | Notes and shadow git live here. Unset skips vault writes. |
| `ZYGOS_BUDGET_MAX_TOKENS` | budget configure | server | env, else brief, else 1_000_000 | n/a | Spend ceiling. Explicit set beats the brief. |
| `ZYGOS_MISSION_TIMEOUT_MS` | mission invocation ceiling | server | env, else 86_400_000 | n/a | Bounds total mission length. |
| `ZYGOS_INVOKE_TIMEOUT_MS` | other bus calls | server | env, else 3_600_000 | n/a | Provider failover uses this as the outer net. |
| `ZYGOS_STREAM_IDLE_MS` | provider stream guard | server | env, else 120_000; `0` disables | n/a | Hang protection. Non-integer is ignored at boot (provider_boot tests). |
| `ZYGOS_APPROVAL_TIMEOUT_MS` | manual approval deny | server | env, else 300_000 | n/a | Unanswered ask denies. |
| `ZYGOS_ROLE_MAX_STEPS` | executor steps | server | env, else 24 | n/a | Turn stops `max_steps`. |
| `ZYGOS_MAX_ROLE_TURNS` | mission role cap | server | env, else 48 | n/a | Loop bound. |
| `ZYGOS_SEARCH_ENGINE` | web_search | server | env `brave` or `searxng` | n/a | Unset or unknown → search unconfigured. |
| `ZYGOS_SEARCH_ENDPOINT` | web_search | server | env; brave defaults to `https://api.search.brave.com`; searxng required | n/a | Operator-chosen host. |
| `ZYGOS_SEARCH_KEY_ENV` | brave key variable name | server | env, else `BRAVE_API_KEY` | n/a | Names the secret. Not the secret. |
| `BRAVE_API_KEY` (or the name in `ZYGOS_SEARCH_KEY_ENV`) | brave `SearchConfig.key` | server | env, resolved in `searchConfigFromEnv` | rotate at Brave | Sent as the search credential. Missing → `MissingSearchKey` per call, boot still proceeds. |
| `ZYGOS_WORKTREE` | executor git worktree | server | `1` or `true` | n/a | Detached worktree under the planning root. |
| `ZYGOS_NO_TUI` | CLI presentation | server | env | n/a | Forces the plain stderr path. |
| `ZYGOS_TUI_CAPTURE` | TUI debug tee | server | env path | n/a | Raw frames on disk. Treat as sensitive as the transcript. |
| `COLORTERM` | TUI color | server | env | n/a | Display only. |
| `OPENAI_API_KEY`, `OPENAI_BASE_URL`, `ANTHROPIC_API_KEY`, `ZYGOS_SMOKE_MODEL` | `test/e2e/*/`, `test/smoke/` | smoke process | env | rotate at the provider | Not read by `zig build test`. |
| `ZYGOS_TOKEN` | bare kernel handshake | server | optional env secret | rotate locally | Requires `?token=` on worker URLs. Treat connection URLs as secret-bearing. |
| `ZYGOS_ALLOW_ORIGIN` | bare kernel browser admission | server | comma-separated exact Origin values; empty denies browsers | n/a | Does not authenticate local script clients. |
| `ZYGOS_FETCH_ALLOW_PRIVATE` | mission web fetch | server | `1` or `true`; default screen enabled | n/a | Allows literal private hosts. Screening does not cover DNS or redirect targets. |
| `HOME` | default catalog path | server | env | n/a | Absence with no `AI_PROVIDERS_CONFIG` refuses mission boot. |

## Files that hold secrets or transcripts

| Path | Contents | Risk |
|---|---|---|
| `$HOME/.agents/providers.toml` | endpoints, models, `key_env`, optional inline `key` | Inline keys are secrets at rest. Never commit. |
| `<planning>/events.jsonl` | tool name, input, clipped output, provider/model | Can contain page text and command output. Not a place for API keys by design; nothing strips them if a tool prints one. |
| `<planning>/` artifacts | MISSION, PLAN, VERIFY, state | Mission content. |
| `ZYGOS_VAULT_ROOT` | notes, `.zygos-shadow` git | Operator knowledge base. |
| `ZYGOS_TUI_CAPTURE` file | raw TUI frames | Same sensitivity as the live transcript. |

## Pre-go-live checklist

- Catalog uses `key_env`, not inline `key`.
- `ZYGOS_BUDGET_MAX_TOKENS` or the brief `budget.max_tokens` is the ceiling you mean. Confirm the env var is an integer; a typo silently keeps the default.
- Search, if used: `ZYGOS_SEARCH_ENGINE=brave` and the named key exported, or searxng with an endpoint.
- Cron line uses `--run-stamp` and stdin from `/dev/null` (`cron.md`).
- Bare `zygos` is not published off localhost. Set `ZYGOS_TOKEN` to restrict local peers; it does not make the bus safe to expose publicly.
- `ZYGOS_VAULT_ROOT` is set only when the vault should receive writes, and the checkpoint succeeds.
- `events.jsonl` and any `ZYGOS_TUI_CAPTURE` path are not world-readable if transcripts are sensitive.

No secret is compiled into the binary. `zig build test` does not read the real catalog or the network.

Shell children receive only PATH, HOME, TZ, LANG, TERM, and LC_* variables.
Provider and search keys are not inherited. HOME and PATH are preserved, so
credentials on disk and executable lookup remain within the operator trust
boundary. MCP children are operator-configured processes and inherit the
parent environment. SSE decode storage is capped at 4 MiB per incomplete
event, provider assemblers at 16 MiB of stream payload, MCP reply lines at
1 MiB with a two-minute read deadline, and each live TUI preview at 256 KiB.
Tool previews can omit later bytes; the provider and tool results are separate
from presentation. Trace files still have no secret redaction.
