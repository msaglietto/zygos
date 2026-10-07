# Benchmark operating policy

Effective 2026-10-07, under the operator's instruction that agents should work
without the operator becoming a blocker. This replaces the per-phase approval
rule recorded in `docs/adr/004-per-phase-spend.md` and prior ledger handoffs.
It governs execution authority; architecture decisions remain in `docs/adr/`.

## Standing authority

Agents may prepare, run, inspect, repair, and record the remaining benchmark
phases without requesting permission at phase boundaries. Every rerun uses
Deepseek Flash (`deepseek/deepseek-v4.1-flash`). A phase ends with an evidence
review and ledger entry; the agent then advances when the prerequisites for
the next phase are met. A new conversation or an elapsed phase boundary does
not revoke this authority.

The campaign scope is:

- Phase 10: 48 matched task-runs, the existing eight-task canary, three repeats
  each with trim on and off. Use the final Phase 9 artifact built from clean
  source `a147d52286e9b2e63ff4991800e98af57d792de1` unless a demonstrated blocker
  requires a source fix and a new matched baseline. Only trim differs between
  arms. Preserve all old results.
- Phase 11: the full 89-task Terminal-Bench 2.1 set, then SWE-bench Lite after
  its runnable Harbor package and pin have been verified. Agents investigate
  that identifier themselves. Verified is not a substitute. Benchmark results
  do not become a PR gate.
- Phase 12: one isolated mission through the mission FSM, genuinely killed
  and resumed once, followed by independent acceptance checks and the real
  completion-approval path. The agent may act as the delegated operator to
  resolve that approval after every brief criterion is demonstrated. A model's
  completion claim alone is insufficient; a failed or unreachable gate stops.

RADAR, BrowseComp-Plus, Y5 real-vault work, deployment, publication, protocol
changes, and new dependencies are outside this benchmark authorization.
This policy does not change the project's success criteria.

## Automatic continuation and stop conditions

Before paid execution, verify the model, runnable task pin, ready platform
inventory, binary identity, credentials through the exec environment, and
current published price metadata. Keep the catalog keyless and credentials
out of arguments, logs, and reports. Use one task per Harbor invocation, no
Harbor retries, no Hub upload, and at most two concurrent host jobs.

Keep the step cap at 24 and the bench tool allowlist at bash, read_file, and
write_file. Matched arms use identical source sha, target triple, optimization,
adapter, model, dataset, provider settings, and step cap. Do not rebuild the
Linux artifact for documentation edits.

Task rewards of zero, output/step-limit stops, and scorer refusals are recorded
outcomes. They do not automatically trigger reruns. Scorer errors remain
invalid measurements under ADR 003. A comparison with insufficient evidence
is reported as inconclusive; it is not turned into a pass.

Transport/RPC failures, corrupt or missing trial records, changed identities,
or a broken tool path stop new paid launches while in-flight work is drained.
Agents investigate locally and prove any source repair with offline red-first
tests before committing and rebuilding. Resume only when there is new evidence
that addresses the blocker. Do not repeat an unchanged failing campaign.
An unresolved external blocker is recorded explicitly; continue independent
work where possible rather than asking the operator to diagnose it.

Policy, approval, and budget failures still deny or stop. An agent supplying an
evidence-backed approval through the real interface does not bypass that
interface. Tests remain offline, fail-closed behavior stays intact, and no test
is removed or weakened to permit continuation.

No dollar cap has been supplied. Authority is bounded by the campaign above,
existing task/mission limits, and evidence-driven repair. Record every paid
attempt, including interrupted attempts, token totals, cached-token treatment,
the three-rate cost estimate, rewards, scorer results, and artifact paths in
`docs/WORK-LEDGER.md`. A snapshot estimate is not a provider invoice. Expanding
the task set or buying unrelated services is not implied by this policy.
