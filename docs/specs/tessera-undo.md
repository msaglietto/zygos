# Spec: `src/worker/tessera_undo.zig` — shadow-git checkpoint/undo (W5, M4)

Safety net for vault writes: a checkpoint snapshots the vault before a write;
one-call undo restores the last snapshot. Shell-out to the system `git` binary
(no new dependency — the `new_dependency` gate stays closed). Reuses
`tools_ops.bash` (fork/exec with a scrubbed env, workspace cwd, output-capped) for execution.

## Shadow repo layout

A bare-ish shadow repo lives INSIDE the vault root at `.zygos-shadow/`
(a git dir, not a worktree checkout). Every git call is
`GIT_TERMINAL_PROMPT=0 git --no-pager --git-dir=<root>/.zygos-shadow --work-tree=<root> ...`
(the env is scrubbed, so the no-prompt switch rides the command line) so the vault never
gains a visible `.git` and never collides with a user repo above or below it.
On first checkpoint: `init`, then write `.zygos-shadow/info/exclude` containing
`.zygos-shadow/` so the shadow never tracks itself. Commits use
`-c user.name=zygos -c user.email=zygos@local` (no global config dependency).

Handlers serialize on a mutex — two concurrent checkpoints must not interleave
`add`/`commit`.

## Worker

`OrientWorker` shape: `Config { root: []const u8, git_timeout_ms: u32 = 120_000 }`, `start`/`stop`, handlers
`error{Failed,OutOfMemory}![]const u8`.

### `zygos::tessera::checkpoint`

Request `{"label": "..."}` (optional). Label is sanitized to
`[A-Za-z0-9 ._-]`, max 80 chars (it rides a shell command line — nothing else
may pass through); empty/absent ⇒ `"checkpoint"`.

1. Shadow repo missing ⇒ init + exclude file.
2. `add -A` then `commit --allow-empty -m "<label>"`.
3. `rev-parse HEAD` ⇒ reply `{"checkpoint_id":"<sha>"}`.
Any git failure (non-zero exit) ⇒ error.Failed. A call that fails to run or
passes `git_timeout_ms` also fails the handler (error.Failed, fail closed, never
success) and logs a warning naming the command.

### `zygos::tessera::undo`

Request `{}` (restores the most recent checkpoint; no arbitrary time travel in
M4). No shadow repo, or repo with no commits (`rev-parse --verify HEAD` fails)
⇒ error.Failed — a structured ErrorBody on the bus, never a crash.

Restore = make the worktree byte-identical to HEAD:
1. `checkout HEAD -- .` (restores modified/deleted tracked files)
2. `clean -fd` (removes files created since the checkpoint; respects
   info/exclude, so `.zygos-shadow/` survives)
Reply `{"restored":"<sha>"}`.

## Test contract (RED first) — over a TmpDir vault, never the real one

Tests require `git` on PATH (it is, on dev machines and CI; same assumption as
the M3 e2e bash tool).

1. `first checkpoint initializes the shadow repo and returns a sha`
2. `checkpoint → modify a file → undo restores the original bytes`
3. `checkpoint → create a new file → undo removes it`
4. `checkpoint → delete a file → undo brings it back`
5. `undo with no shadow repo is error.Failed (structured, no crash)`
6. `two checkpoints then undo restores the SECOND (most recent) state`
7. `label with shell metacharacters is sanitized (commit succeeds, message stripped)`
8. `.zygos-shadow/ itself is never tracked nor cleaned`
9. `no leaks`
10. `gitCommand: every git call disables terminal prompts and the pager`
11. `a git hook that reads stdin cannot stall checkpoint` (fsmonitor hook, stdin held open)
12. `a git call past its deadline fails the handler (fail closed)`

## Seam (wired elsewhere, not in this module)

tessera-continuity (W3) and tessera-capture (W4) accept a
`checkpoint_function` config; when set they bus-call it before every write and
fail closed if it errors. This module only provides the functions.
