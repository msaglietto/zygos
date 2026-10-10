---
mission: research-radar-wasm-components
created: 2026-07-10
budget:
  max_tokens: 2000000
gates:
  external_actions: human
escalation:
  test_fail_threshold: 3
---

# Mission: refresh a living research brief

A weekly, unattended research refresh. The executor researches with
`zygos::tools::{web_search,web_fetch}` and rewrites one brief artifact in the
workspace; the verifier checks coverage, not prose taste. The topic below is
an example. Swap in your own area, named players, and watch signals; keep the
shape, because the shape is what the brief lint and the verifier check.

## Objective

Produce an updated `BRIEF-wasm-components.md` in the workspace covering, with
sources and dates for every claim: (a) state of the art over the last 6–12
months in the WebAssembly component model and WASI tooling; (b) what named
projects actually shipped vs announced (wasmtime, wasmCloud, Spin, jco,
wasm-tools, WASI 0.3 and later, wit-bindgen); (c) whether the open question
still holds — is there now a stable, language-neutral way to compose
components across runtimes without a vendor-specific host?; (d) a
tractability verdict for a small team; (e) an adopt/wait/avoid recommendation
delta vs the prior brief; (f) status of each watch signal below.

## Success criteria

| # | Criterion | Verified by |
|---|-----------|-------------|
| R1 | Every section (a)–(f) present and non-empty | section headings exist in the artifact |
| R2 | ≥ 8 dated, sourced claims (URL + month/year) | count of source-annotated claims |
| R3 | Each of the three watch signals explicitly assessed as fired / not fired / partial, with evidence | signal subsection per signal |
| R4 | Shipped-vs-announced table for the named projects | table present with a Shipped? column |
| R5 | An explicit verdict on the open question: resolved / converging / open, with the single strongest counter-evidence link | verdict line in section (c) |

## Open threads (watch signals from the prior brief)

- A major runtime or cloud vendor shipping a component registry with
  cross-runtime composition as a supported product; if fired, the brief must
  say what and when.
- A ratified WASI release that changes the async or networking interfaces the
  prior brief assumed; adopt or re-plan.
- A mainstream language toolchain making component output a default target,
  not a plugin.

## Non-goals

- No changes to any other brief in the workspace.
- No benchmarks or new measurements; report only what sources state.
- No code, no repo changes — the deliverable is the brief artifact.
