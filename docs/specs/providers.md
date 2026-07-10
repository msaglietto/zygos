# Spec: `src/config/providers.zig` — shared provider catalog parsing (X1)

Parses the operator's shared AI provider catalog (`~/.agents/providers.toml`,
schema mirrored from `~/.agents/providers.schema.json`) into a validated
`Catalog`. Pure module: `Catalog.parse` takes TOML text, never a path — the
binary reads the file (same Z-02-shaped split as `router.Config`). No new
dependency: a minimal in-repo TOML-subset parser, `std` only.

## TOML subset (exactly what the catalog shape needs)

- `# comments` (full-line and trailing) and blank lines.
- `[[providers]]` / `[[clis]]` array-of-table headers. Unknown array-of-table
  sections are skipped whole (forward compat); any other header form
  (`[table]`, malformed brackets) is an error.
- `key = value` pairs where value is: basic string `"..."` (escapes: `\"`,
  `\\`, `\n`, `\t` only — anything else is an error), integer, float, or an
  inline array of basic strings (`["a", "b"]`, trailing comma tolerated).
- Unknown keys inside a known section are skipped (schema has no
  `additionalProperties: false`); wrong value *type* for a known key is an
  error. Anything outside this subset ⇒ `error.ParseToml` + diagnostic.

## Validation (fail closed — an invalid file yields no catalog)

Per the JSON schema's semantics:

- provider: `name`, `type`, `model` required; `type` ∈
  `{openai_compatible, google, ollama}`; `endpoint` required when `type`
  is `openai_compatible` or `ollama`; `max_tokens >= 1`;
  `0 <= temperature <= 2`.
- cli: `name`, `command` required; `args` optional string array.
- Duplicate provider `name`s are an error, and so are duplicate derived
  slugs (bus registration would silently last-win otherwise).

Diagnostics: `parse(gpa, toml_text, *?Diag)` — on error, `Diag` carries
`line` (1-based) and a static message. Errors never leak partial allocations
(testing allocator is the leak check).

## Key resolution & slugs

- `Provider.resolveKey(env)` → `key_env` var's value if set *and* present in
  `env`, else inline `key`, else null (a local endpoint may need none; X2
  decides what null means per transport). `env` is an injected
  `*const std.process.Env.Map`-shaped lookup so tests never touch the real
  environment.
- `slug(name)`: lowercase; every run of non-alphanumerics → one `-`; trimmed
  (`"NVidia DeepseekV4 Pro"` → `"nvidia-deepseekv4-pro"`). X2 registers
  `zygos::providers::<slug>`.
- `configPath(gpa, env)`: `AI_PROVIDERS_CONFIG` if set, else
  `<HOME>/.agents/providers.toml` — pure over the injected env.

## API

- `Catalog.parse(gpa, toml_text, diag: ?*Diag) error{OutOfMemory,ParseToml,InvalidCatalog}!Catalog` / `deinit`
- `Catalog.providers: []const Provider`, `Catalog.clis: []const Cli`
- `Provider.resolveKey(env) ?[]const u8`, `slug(gpa, name) ![]u8`,
  `configPath(gpa, env) ![]u8`

## Test contract (RED first)

1. `parse: real-shaped fixture (8 providers incl. google + local, 2 clis) round-trips every field`
2. `parse: comments, trailing comments, blank lines ignored`
3. `parse: unknown keys and unknown array-of-table sections skipped`
4. `parse: string escapes decoded; unsupported escape ⇒ ParseToml with line`
5. `parse: malformed input (unclosed string, [table] header, bare junk) ⇒ ParseToml, no leaks`
6. `validate: missing name/type/model ⇒ InvalidCatalog, diag names the field`
7. `validate: openai_compatible or ollama without endpoint ⇒ InvalidCatalog`
8. `validate: unknown type enum ⇒ InvalidCatalog`
9. `validate: temperature out of [0,2] or max_tokens < 1 ⇒ InvalidCatalog`
10. `validate: duplicate provider name (and distinct names colliding to one slug) ⇒ InvalidCatalog`
11. `validate: cli missing command ⇒ InvalidCatalog`
12. `resolveKey: key_env present in env wins; absent ⇒ inline key; neither ⇒ null`
13. `slug: mixed case, spaces, punctuation, leading/trailing junk`
14. `configPath: AI_PROVIDERS_CONFIG override, else HOME fallback`
15. `no leaks across parse/deinit loops incl. error paths`

The real `~/.agents/providers.toml` is never read by any test — fixtures
only (it may carry inline key fallbacks).
