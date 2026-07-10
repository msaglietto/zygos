# Spec: `src/net/provider_boot.zig` — catalog → bus provider boot (X2)

Boots one openai-compat provider worker instance per `providers.toml` catalog
entry (X1, `src/config/providers.zig`), each registered on the bus as
`zygos::providers::<slug>`. Lives in `src/net/` because it constructs
`OpenAiProvider` instances holding `std.Io` (Z-02 boundary). `zig build test`
never opens a socket — registration and config plumbing only.

## CatalogBoot

- `CatalogBoot.start(gpa, actor, registry, io, catalog: *const providers_catalog.Catalog, env: []const providers_catalog.EnvPair) !CatalogBoot`
  — for each `catalog.providers` entry:
  - function name: `zygos::providers::<slug(name)>`; worker name: the slug.
  - `base_url`: the entry's `endpoint`, or for `kind == .google` with no
    endpoint, Gemini's OpenAI-compat base
    `https://generativelanguage.googleapis.com/v1beta/openai` (native
    provider-google is deferred; `openai_compatible`/`ollama` always have an
    endpoint — X1 validation guarantees it).
  - `api_key`: `entry.resolveKey(env)` or `""` (a local endpoint may ignore
    auth; never a boot error).
  - per-instance defaults: `model`, `max_tokens`, `temperature` — request
    values win, defaults fill gaps (see handler change below).
- `CatalogBoot.stop()` — stops every instance.

## checkRoutes (boot refusal, fail closed at startup)

`checkRoutes(catalog, router_config: *const router.Config) error{UnknownProviderSlug}!void`
— every attempt in every ladder (including `.default`) whose
`provider_function` starts with `zygos::providers::` must name a slug present
in the catalog; anything else (e.g. legacy `zygos::provider::anthropic::messages`)
passes untouched. X3's CLI calls this before serving — a bad route table
never boots, and never fails mid-mission.

## Required changes to existing modules (flagged)

- `net/provider_openai.zig`: instance-parameterized start — options carry
  worker/function name plus optional default `model`/`max_tokens`/`temperature`.
  The existing `start()` keeps its signature and behavior (legacy fixed name,
  no defaults) as a thin wrapper. Handler: `model` = request's `model` else
  the default (neither ⇒ `error.Failed`, as today); `max_tokens`/`temperature`
  likewise. Extract the merge as a pure helper so tests never reach the
  network.
- `net/openai.zig`: `StreamOptions.base_url` now *includes* the version
  segment (default `https://api.openai.com/v1`) and the client appends only
  `/chat/completions` — catalog endpoints already carry `/v1`, and Gemini's
  compat base carries `/v1beta/openai`. Extract the join as a pure
  `chatUrl()` helper. `StreamOptions` gains `temperature: ?f64 = null`,
  emitted in the request body only when set.

## Test contract (RED first; no sockets anywhere)

1. `boot: fixture catalog registers zygos::providers::<slug> per entry`
   (invoke each with non-JSON request bytes over the bus ⇒ a structured bus
   error — proves registration + handler wiring without any network)
2. `boot: google entry with no endpoint gets the Gemini compat base_url`
3. `boot: api_key resolution — env var wins, inline key falls back, neither ⇒ ""`
4. `boot: instance defaults carry the entry's model/max_tokens/temperature`
5. `merge helper: request model wins; absent model falls to default; neither ⇒ error; max_tokens/temperature likewise`
6. `checkRoutes: unknown zygos::providers::* slug in any ladder (incl. default) ⇒ UnknownProviderSlug; known slugs and non-catalog functions pass`
7. `chatUrl: version-carrying base joins to <base>/chat/completions`
8. `temperature emitted in the request body only when set`
9. `no leaks across boot/stop loops`
