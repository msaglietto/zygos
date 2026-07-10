# Spec: `test/smoke/providers` — env-gated multi-provider smoke (X4)

Manual, never part of `zig build test` (GOAL.md M4.5 notes). Proves the
X1→X2 chain against real endpoints: the operator's actual
`~/.agents/providers.toml`, real keys from the real environment.

## Binary (`test/smoke/providers/main.zig`, `zig build smoke-providers`)

1. Load the real catalog via `configPath` + `Catalog.parse` (this is the one
   place the real file is read — still never in `zig build test`).
2. Take two provider slugs from argv (`smoke-providers <slug-a> <slug-b>`);
   exit 2 with the available slugs listed when absent or unknown.
3. For each slug, `resolveKey` against the real env; a missing key ⇒ exit 2
   naming the env var (skip-friendly for scripts, like the openai smoke).
4. Boot kernel + `CatalogBoot` + turn orchestrator + a routing config built
   in-memory: `step_id "smoke"` ladder = [slug-a's function, slug-b's
   function] — attempt 0 and 1 hit different providers.
5. Two `zygos::turns::run` calls: one routed to attempt 0, one forced to
   attempt 1 (or two step_ids, one per provider — whichever the turn API
   makes cleaner). Prompt: reply with one short word. No tools, no policy.
6. Print both `{slug, model, stop_reason, usage}` lines; exit 0 only if both
   completed with a terminal message.

## Script (`test/smoke/providers.sh`)

Wraps the binary: picks two slugs whose `key_env` vars are present (else
prints SKIP and exits 0 — same convention as the openai/anthropic smokes),
runs it, echoes the result. Documented in README beside the other smokes.
