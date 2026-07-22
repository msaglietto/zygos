---
title: Resolve brave search key at mission-CLI boot (Y5 unblock)
status: closed
labels: [ready-for-agent]
created: 2026-07-19
closed: 2026-07-21
resolution: >
  Fixed in 1ebe1aa (feat(worker/mission_boot)): searchConfigFromEnv now
  resolves key_env into SearchConfig.key at boot, with a named regression
  test ("brave resolves key_env into key at boot (Y5 regression)").
origin: docs/RECONCILIATION-2026-07-18.md (latent defect #1); ROADMAP.md M4.7
---

# Resolve brave search key at mission-CLI boot (Y5 unblock)

## Problem Statement

An operator who configures brave as the search engine for an unattended
mission run — exporting the API key exactly as the documentation says
(`ZYGOS_SEARCH_ENGINE=brave` plus `BRAVE_API_KEY`, or a custom name via
`ZYGOS_SEARCH_KEY_ENV`) — finds that every `web_search` call in the mission
fails with `MissingSearchKey`, even though the key is present in the
environment. The error message names the very variable the operator has
already set, which makes the failure look like operator error when it is a
harness defect. This blocks the Y5 exit criterion (the first real unattended
zahir-radar run) for anyone not running a searxng instance.

## Solution

When the mission CLI assembles the search backend configuration from the
environment, the brave branch resolves the configured key variable name
against the process environment and carries the resolved secret into the
worker configuration. If the variable is genuinely unset, behavior is
unchanged: the worker returns the existing structured `MissingSearchKey`
error naming the variable, fail-closed, never a crash. Operators who export
the key get working brave search through the mission CLI with no new flags,
no config changes, and no behavior change for searxng.

## User Stories

1. As a radar operator, I want `ZYGOS_SEARCH_ENGINE=brave` with
   `BRAVE_API_KEY` exported to just work through `zygos mission start`, so
   that my research missions can search the web without me debugging the
   harness.
2. As a radar operator, I want the Y5 unattended weekly run to be runnable
   with brave (the documented default engine), so that the M4.6 milestone can
   close at its human gate.
3. As a radar operator, I want to name a non-default key variable via
   `ZYGOS_SEARCH_KEY_ENV`, so that I can keep multiple keys (or a CI-scoped
   key) without renaming environment variables.
4. As a radar operator running unattended under cron, I want a genuinely
   missing key to surface as the existing structured `MissingSearchKey`
   error naming the exact variable, so that the trace tells me precisely
   what to fix — instead of the run silently degrading or hanging.
5. As a searxng operator, I want my configuration to behave byte-identically
   to today, so that the fix for brave cannot regress my working setup.
6. As a harness maintainer, I want key resolution to happen in configuration
   assembly rather than inside the web-tools worker, so that the worker
   keeps its injected-secret contract and stays testable without ambient
   environment access.
7. As a harness maintainer, I want the resolution logic covered by in-module
   unit tests over a synthetic environment slice, so that this fail-closed
   boot rule is no longer covered only by e2e (the mission CLI currently has
   zero unit tests).
8. As a harness maintainer, I want the regression test to pin both the
   resolved-key path and the missing-key path, so that a future refactor
   (e.g. the planned mission-boot extraction) cannot silently reintroduce
   the defect.
9. As a security-conscious operator, I want the resolved key to never appear
   in traces, logs, error replies, or the TUI, so that exporting a key to
   the harness doesn't leak it into `events.jsonl` or scrollback.
10. As a mission author, I want a mission whose executor uses `web_search`
    with brave to complete its research turns, so that briefs ported from
    zahir-radar (Brief 2) actually execute rather than burning executor
    steps on failing tool calls.
11. As the human at the Y5 gate, I want the staged unattended run to be
    executable as documented in the cron recipe with no undocumented
    workaround (no forced searxng), so that the documented recipe is the
    truth.
12. As a spec reader, I want the known-defect flag in the mission-CLI spec
    replaced by the as-built resolution behavior, so that the docs stay
    reconciled with the code.

## Implementation Decisions

- The defect is fixed in the mission CLI's search-configuration assembly,
  not in the web-tools worker. The worker's `SearchConfig` contract is
  unchanged: `key` is the resolved secret (or null), `key_env` is only the
  variable *name* used in missing-key error replies.
- Resolution is a pure lookup of the configured variable name (default
  `BRAVE_API_KEY`, overridable by `ZYGOS_SEARCH_KEY_ENV`) against the
  environment-pair slice the configuration-assembly function already
  receives. No new environment access paths, no new knobs, no config-schema
  changes.
- The searxng branch is untouched — it requires no key today and continues
  not to.
- A missing key does not fail boot. The existing runtime fail-closed
  behavior (structured `MissingSearchKey` reply per search call) is retained
  deliberately: a mission may legitimately never call `web_search`, and
  boot-refusal for an unused tool would be a behavior change beyond this
  defect's scope.
- The mission-CLI spec's known-defect flag is removed and replaced with the
  resolution rule; the README's knob documentation stays accurate as written
  (it already describes the intended behavior).

## Testing Decisions

- Tests assert external behavior only: given an environment slice, the
  produced `SearchConfig` carries the expected resolved `key` — not how the
  lookup is implemented.
- New in-module unit tests in the mission CLI module (its first), over
  synthetic environment pairs — no process environment, no network,
  consistent with the suite-wide "no network in `zig build test`" rule:
  - brave + default variable set ⇒ `key` equals the exported value,
    `key_env` names the default variable;
  - brave + `ZYGOS_SEARCH_KEY_ENV` naming a custom variable ⇒ `key`
    resolved from the custom variable;
  - brave + variable absent ⇒ `key` null, `key_env` still names the
    variable (so the worker's error reply names it);
  - searxng ⇒ config unchanged from today (no key fields populated);
  - unknown engine / engine unset ⇒ null config, unchanged.
- Prior art: the web-tools worker's existing fixture tests already pin the
  `MissingSearchKey` reply shape for a null key — those remain the contract
  for the runtime half and are not duplicated.
- TDD per repo law: the resolved-key test lands red first against the
  current code, then the fix turns it green.

## Out of Scope

- The full mission-boot extraction from the CLI (run-stamp refusal, timeout
  ceilings, roster/policy seeding under test) — that is the adjacent, larger
  M4.7 roadmap item; this issue only breaks the zero-test streak for the one
  defective rule.
- Executing the Y5 run itself — it remains a human gate; this issue makes it
  executable as documented.
- Any change to search-engine choice, retry semantics (the 429 carve-out),
  endpoint defaults, or adding new engines.
- Boot-time refusal on a missing search key (see Implementation Decisions).
- Reading the key from the provider catalog or `zygos.zon` — engine config
  stays environment-driven as documented.

## Further Notes

- Origin: flagged as the latent defect in the 2026-07-18 doc-reconciliation
  review and in `docs/specs/mission-cli.md`; it is the sole blocker named on
  the Y5 line of the M4.6 criteria table.
- Size S; it is the first item of the proposed M4.7 table. Landing it should
  ride with drafting the M4.7 criteria table for ratification, per the
  repo's milestone process.
- After merge, the Y5 staging note to the human gate should point at the
  cron recipe unchanged — that recipe is the acceptance context for this
  fix.
