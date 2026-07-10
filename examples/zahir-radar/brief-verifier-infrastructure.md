---
mission: zahir-radar-verifier-infra
created: 2026-07-10
source: "poe.md/Projects/Zahir/Research Pipelines.md — Brief 2 (Z-10 port)"
budget:
  max_tokens: 2000000
gates:
  external_actions: human
escalation:
  test_fail_threshold: 3
---

# Mission: refresh the verifier-infrastructure living brief

Weekly research refresh of Zahir's Brief 2 — neurosymbolic reasoning /
verifiable AI, the "unified multi-backend verifier layer" wedge. The
executor researches with `zygos::tools::{web_search,web_fetch}` and rewrites
the brief artifact; the verifier checks coverage, not prose taste.

## Objective

Produce an updated `BRIEF-verifier-infrastructure.md` in the workspace
covering, with sources and dates for every claim: (a) state of the art over
the last 6–12 months in neural provers and verifier APIs; (b) what named
players actually shipped vs announced (Harmonic/Aristotle, DeepSeek-Prover,
Goedel-Prover, Seed/BFS-Prover, Kimina, Axiom, Lean/Mathlib ecosystem);
(c) whether the white space still holds — is anyone now selling a unified,
domain-extensible, multi-backend verifier API (Lean, Z3, Python sandbox,
PDDL, custom rule backends)?; (d) tractability verdict without frontier
compute; (e) build/partner/license recommendation delta vs the prior brief;
(f) status of each watch signal below.

## Success criteria

| # | Criterion | Verified by |
|---|-----------|-------------|
| R1 | Every section (a)–(f) present and non-empty | section headings exist in the artifact |
| R2 | ≥ 8 dated, sourced claims (URL + month/year) | count of source-annotated claims |
| R3 | Each of the three watch signals explicitly assessed as fired / not fired / partial, with evidence | signal subsection per signal |
| R4 | Shipped-vs-announced table for the named players | table present with a Shipped? column |
| R5 | An explicit white-space verdict: intact / eroding / gone, with the single strongest counter-evidence link | verdict line in section (c) |

## Open threads (watch signals from the prior brief)

- Harmonic or a hyperscaler launching a *multi-backend* verifier API — the
  direct threat; if fired, the brief must say what and when.
- An open standard/protocol for verifier interfaces (MCP-style) — adopt or
  shape it.
- RLVR frameworks bundling their own verifier hosting — TAM erosion.

## Non-goals

- No changes to the other four area briefs.
- No new market sizing beyond what sources state; no funding-strategy
  rewrites (Task A scope only, this area only).
- No code, no repo changes — the deliverable is the brief artifact.
