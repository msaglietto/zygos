# Contributing to Zygos

Zygos is an experimental local agent harness for macOS and Linux. Read
[GOAL.md](GOAL.md), [AGENTS.md](AGENTS.md), and
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) before changing behavior.
The repository is self-contained; a private vault is not required.

Use Zig **0.16.0**, libc, and git (Linux requires glibc 2.36+; musl is not
currently supported). Build dependencies are pinned in
`build.zig.zon`; the first fetch needs network access. Tests use local fixtures
and must never read a real provider catalog, real vault, or remote service.

```sh
zig build --fetch
zig build test --system zig-pkg
zig build --system zig-pkg
zig fmt --check build.zig src/ test/
```

Write a named regression test in the affected module, run `zig build test`
and observe the expected failure, then implement the fix. Use
`std.testing.allocator`. Keep policy, approval, and budget failures closed.
Never remove, skip, or weaken a test to make a change pass. Use GitNexus impact
analysis before editing symbols, as described in `AGENTS.md`.

For changes to filters or trimming, also run the real-command probes,
mutation guards, and M8 integration listed in `AGENTS.md`. For CLI, transport,
or shell changes, run `test/e2e/m45/run.sh` and the relevant local e2e scripts.
Node.js is needed for the scripted CLI fixtures. Real provider smokes are
optional, credential-gated, and excluded from CI.

Open a focused pull request describing the problem, resulting behavior,
regression coverage, and remaining limitations. Dependency additions,
wire-protocol changes, and deployments need maintainer approval. Do not edit
the mission's success criteria to justify a change. Use conventional commits
scoped by module, without attribution trailers.

The CI workflow checks macOS and Linux. Requiring its checks in branch
protection is a repository setting the maintainer enables after publication.
Report suspected vulnerabilities privately using [SECURITY.md](SECURITY.md).
Participation follows [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
