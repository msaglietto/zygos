# Doc reconciliation — 2026-07-18

Full-codebase review (64 Zig files, ~30k lines, 579 tests green) against every
doc. One line per doc touched, then the flags. Per GOAL.md gates, `GOAL.md`
and `docs/PROTOCOL.md` were **not** edited (human-gated; PROTOCOL.md's §6
ack-timeout and channel HTTP bridge remain forward-spec by design).

## Docs updated (and why)

| Doc | Why |
|---|---|
| `specs/catalog.md` | `Handler.builtin` was `*const BuiltinFn`; code is `Builtin{ctx, f}` (the inproc-era ctx change never landed here). |
| `specs/invocation.md` | Timeout/fail callbacks take a 4th `function_id` param (`comptime`); the API block contradicted the file's own prose. |
| `specs/channel.md` | Access keys come from `arc4random_buf`, not `std.crypto.random` (removed in Zig 0.16). |
| `specs/net.md` | Same RNG fix; clock source is `clock_gettime`; **flagged never-built**: per-conn writer queue (cap 64 / `QueueFull`) and SIGINT graceful shutdown — code writes directly under the conn mutex and has no signal handler; timer extracted to `net/ticker.zig` (immediate first tick); test contract replaced with the tests that exist. |
| `specs/actor.md` | `Command` has 8 variants (3 channel-bridge ops), `Config` gained `invoke_timeout_overrides` (prefix-matched per-function deadlines), `ack_timeout_ms` marked dead in M0, public API gained `registerBuiltin`/`channel*`, observed-clock stamping documented, 5 post-M0 tests appended, dispatch prose signature fixed. |
| `specs/inproc.md` | `call` returns `CallResult{ok,err}` (no `RemoteError`, no `[]u8`); handlers run on a thread **per invocation**, not inline on the router thread; 11th test added. |
| `specs/turn.md` | `stop` is a string with more live values than the documented enum; **a failed turn replies `.ok` `{"stop":"failed",...}`, not the specced `turn_failed` ErrorBody** (built + header-flagged deviation); Z-09 compress seam located in the loop; post-M2 additions (delta observer, per-step `usage` trace event, default `max_steps`=8). |
| `specs/mission.md` | Executor `max_steps` is retried with feedback via `exec_fail_count` (not instant `role_failed`); `Task` carries `result` outcome excerpts into later executor turns; fence unwrapping; `REJECTED-<role>.md` artifacts; gate request shape as built (`reason`+`summary`=objective); **named ErrorBodies `mission_already_running`/`mission_not_found` were never built** (generic handler failures); post-M3 additions section (task trace events, W1 lint, W3 continuity seam). |
| `specs/router.md` | Phantom `Config.load(path)` removed — only `parse` exists, deliberately. |
| `specs/policy.md` | Patterns are tried against both `tool` and `function_id` unconditionally; no `::`-inspection exists. |
| `specs/openai.md` | Anthropic-spelling usage fallback (GLM drift), duplicate-key canonicalization, stream-tap mirroring, and the `translateMessages`/`translateTools` half documented. |
| `specs/providers.md` | `anthropic_compatible` kind added (type enum, endpoint rule, test names, 9-provider fixture). |
| `specs/provider-boot.md` | Anthropic-dialect instances for `anthropic_compatible` entries; `ZYGOS_STREAM_IDLE_MS` → stream-guard wiring documented. |
| `specs/mission-cli.md` | Synopsis gained `--run-stamp`, `--no-tui`, and the `trace` verb; roster corrected (**bash boots `allow`, not `ask`**; web-tools + MCP clients in roster); `ZYGOS_VAULT_ROOT` pre-mission checkpoint; full env-knob table incl. tiered timeouts; **known defect flagged** (below). |
| `specs/mcp-gateway.md` | `Caller.callFn` gained the `arena` param; pointer to the spec-less inverse client. |
| `README.md` | Test count 385 → **579**; Mission-TUI section reconciled to the current render grammar (`❙ Thinking…`/`◆ Thought for Ns`, rail-guttered `┃` entries not "bordered boxes", `◆`/`✗` collapses, keys-first `[y/N] approve?` band, spinner on the status line, markdown-lite + syntax-highlighted answers, truecolor/256 fallback, `emergencyRestore`, stderr redirect, `ZYGOS_TUI_CAPTURE`); knob list gained `ZYGOS_ROLE_MAX_STEPS`/`ZYGOS_MAX_ROLE_TURNS`/`ZYGOS_SEARCH_*`. |
| `ONBOARDING.md` | 385 → 579 tests; TUI layer 10 → 17 files; `model.zig` 1046 → 986 lines; `mission.zig` 2039 → 2093; stale-graph regeneration note added. |
| `DESIGN.md` | **Flag block added, vision not rewritten**: enumerates the described-but-never-built surface (Layer 1 built-ins, auth-credentials, hook-fanout, session-store, compaction, directory, `agent::spawn`, Z-06 prompt pipeline/fusion, OTel, native google, worktrees, the richer 7-state mission FSM with roadmapper/plan-checker/PO journal/steer/pause/FIFO queue). |

## Docs verified accurate — untouched

`specs/trigger.md`, `specs/brief.md`, `specs/budget.md`, `specs/approval.md`,
`specs/trim.md`, `specs/web-tools.md`, `specs/tessera-vault.md`,
`specs/tessera-continuity.md`, `specs/tessera-undo.md`,
`specs/tessera-capture.md`, `specs/providers-smoke.md`, `PROTOCOL.md`,
`ARCHITECTURE.md` (still-true condensed map). All nine e2e legs match their
README documentation; examples references are correct.

## Flags (not fixed in this pass — docs-only)

1. **Latent defect** — `cli/mission.zig` `searchConfigFromEnv`: the brave
   branch sets `key_env` but nothing resolves it into `key`, and
   `web_tools.zig` reads only `key` ⇒ brave `web_search` through the mission
   CLI always returns `MissingSearchKey` even with the key exported. Blocks
   the Y5 unattended run unless searxng is used. (Now flagged in
   `specs/mission-cli.md`.)
2. **Spec-less modules** — no spec exists for: the entire TUI (17 files, 127
   tests — the largest gap), `worker/mcp/client.zig`, `net/stream_guard.zig`,
   `net/ticker.zig`, `worker/anthropic.zig` (mirrors openai.md), `worker/sse.zig`,
   `worker/trace.zig`, `worker/stream_tap.zig`, `worker/provider_fake.zig`,
   `kernel/sync.zig`, `kernel/types.zig`. Roadmapped rather than written here.
3. **`cli/mission.zig` has 0 tests** — run-stamp refusal, timeout ceilings,
   roster/policy seeding, and the vault-checkpoint protocol are covered only
   by e2e. Roadmapped (mission-boot extraction).
4. `PROJECT.md` (vault-mirrored) is a historical log ending 2026-07-10; the
   TUI/timeout work has no session entry — left to the vault workflow.
