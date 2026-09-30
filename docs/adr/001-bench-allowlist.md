# ADR 001: Bench allowlist versus mission fail-closed

## Status

Accepted.

## Context

A Terminal-Bench task needs bash, read, and write inside its workspace. The mission policy seed allows bash, web fetch, web search, and MCP tools, and it does not name read_file or write_file. Defaulting the bench at that seed would either deny the tools the benchmark calls or widen what a mission may do.

Policy failures already deny. An unknown verdict, a missing policy worker, and a rule that does not match are denials. That fail-closed behavior is the mission contract and stays there.

## Decision

The headless task command installs its own rules: bash, read_file, and write_file are allowed, and every other tool name is denied. Path escapes stay inside `Workspace.resolve` and come back as tool results, not as a crashed process. Mission policy is a different function and is not edited by this command.

## Consequences

A bench run cannot reach web_fetch, web_search, or an unlisted MCP tool. A mission run does not gain read_file or write_file from this allowlist. Changing either list is a separate decision.
