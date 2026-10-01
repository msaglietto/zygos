# Security

Zygos is experimental software for one trusted local operator. The development
branch receives fixes; there are no supported release lines yet.

Report vulnerabilities through GitHub's **Report a vulnerability** action in
the repository's Security tab when private vulnerability reporting is enabled.
If unavailable, open an issue asking for a private contact without disclosing
the exploit. Do not include credentials, private transcripts, or vault data.
The maintainer must enable private reporting when creating the public repo.

Include the affected commit, platform, a minimal fixture-based reproduction,
expected behavior, and impact. No response-time commitment is offered yet.

## Trust limits

- Mission mode allows shell and web tools by default. Bash runs as your user
  with workspace cwd; it is not sandboxed. Fetched text can influence commands.
- A same-user shell can read credentials from disk and write
  `<planning>/control.jsonl`, including completion approvals. Environment
  filtering reduces accidental disclosure; it does not isolate credentials or
  make the completion gate independent of the executor.
- Bare kernel mode binds loopback. Browser Origins are denied unless
  explicitly allowlisted. Set `ZYGOS_TOKEN` to require a shared secret for
  local peers; admitted peers can register and invoke functions on the bus.
- File-tool confinement is lexical; symlinks can target files outside the
  workspace. Mission models are not offered those file tools by default.
- Private-address web screening is a defense in depth measure. See
  [permissions](documentation/permissions.md) for its exact coverage.
- Trace files contain tool inputs and outputs without secret redaction. Keep
  planning directories and TUI captures private. Do not publish real catalogs.

Use a disposable workspace and a dedicated OS account/container when running
untrusted tasks. Do not expose the bus to the internet. Implemented boundaries
are documented in [architecture](documentation/architecture.md).
