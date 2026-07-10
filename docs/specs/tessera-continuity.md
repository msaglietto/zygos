# Spec: tessera-continuity (W3, M4)

Session continuity as a harness property: `session_open` reads the seam left by
the last session, `session_close` writes the new seam. Mission phase boundaries
auto-log through the mission driver — no model is ever asked to remember.

Two modules:
- `src/worker/tessera/session_writer.zig` — pure text transforms. NO bus, NO
  file I/O (same discipline as `tessera/vault.zig`; arena allowed).
- `src/worker/tessera_continuity.zig` — bus worker. File I/O via the libc
  idiom used by `tessera_orient.zig` / `mission_store.zig` (Z-02).

## Pure layer: `tessera/session_writer.zig`

```zig
pub const Entry = struct {
    date: []const u8,            // "YYYY-MM-DD HH:MM"
    context_reload: []const u8,  // "" allowed
    intention: []const u8,       // "" allowed
    log: []const []const u8,     // pre-formatted "HH:MM — ..." lines
    accomplished: []const u8,
    leaving_behind: []const u8,  // caller guarantees non-empty
    open_threads: []const []const u8,
};

/// Render one session entry in the Tessera format (see vault spec §format):
/// `---`, `## Session — <date>`, then `### 🔁 Context reload`, `### 🎯 Intention`,
/// `### 📝 Log`, `### ✅ Accomplished`, `### 🔮 Leaving behind`,
/// `### 🧵 Open threads`, trailing `---`. Empty sections render with an empty
/// body (heading kept, so the shape is stable for the parsers). Arena-owned.
pub fn renderEntry(arena: std.mem.Allocator, entry: Entry) error{OutOfMemory}![]u8;

/// Prepend `block` to SESSIONS.md text. If `text` starts with file-level
/// frontmatter (`---\n` ... `\n---\n`), insert after it; else insert at the
/// top. Never touches existing entries. Arena-owned result.
pub fn prependEntry(arena: std.mem.Allocator, text: []const u8, block: []const u8) error{OutOfMemory}![]u8;

/// First-creation content: file frontmatter
/// `---\ntitle: Sessions — <project>\ntags: [sessions, project]\n---\n`
/// followed by `block`. (Frontmatter first so the entry's opening `---` is
/// not parsed as frontmatter — W3 "frontmatter-safe on first creation".)
pub fn initialSessionsFile(arena: std.mem.Allocator, project: []const u8, block: []const u8) error{OutOfMemory}![]u8;

/// Append `- [ ] <item>` lines to PROJECT.md's `## Actions` section body
/// (create the section at EOF if absent). Existing checkboxes untouched;
/// duplicates (same trimmed text as an existing open box) are skipped.
pub fn promoteActions(arena: std.mem.Allocator, text: []const u8, items: []const []const u8) error{OutOfMemory}![]u8;
```

### Test contract (RED first)

1. `renderEntry emits every section heading in order; round-trips through vault.parseSessions`
2. `renderEntry with empty log/threads keeps headings with empty bodies`
3. `prependEntry inserts after file frontmatter; existing entries intact and older`
4. `prependEntry on text without frontmatter inserts at top`
5. `initialSessionsFile: frontmatter first, then entry; vault.parseSessions finds exactly one session`
6. `promoteActions appends to existing ## Actions preserving checked/unchecked lines`
7. `promoteActions creates ## Actions when missing`
8. `promoteActions skips duplicates of existing open items`
9. `no leaks under std.testing.allocator arenas`

## Worker layer: `src/worker/tessera_continuity.zig`

Follows the `OrientWorker` shape exactly (Config with injected root/filenames,
`start`/`stop`, handler signature `error{Failed,OutOfMemory}![]const u8`).

```zig
pub const Config = struct {
    root: []const u8,
    projects_subdir: []const u8 = "Projects",
    sessions_file: []const u8 = "SESSIONS.md",
    project_file: []const u8 = "PROJECT.md",
    /// When set, invoke this bus function (`{"label":...}`) BEFORE any write;
    /// a failed/unreachable checkpoint ⇒ error.Failed, nothing written (W5 seam,
    /// fail closed). When null, write without checkpointing.
    checkpoint_function: ?[]const u8 = null,
};
```

### `zygos::tessera::session_open` (read-only)

Request `{"project": "<name>"}`. Missing/blank project ⇒ error.Failed.
Read `<root>/<projects>/<project>/SESSIONS.md`, parse with `vault.parseSessions`.
- File missing or zero sessions ⇒ `{"first_session":true,"context_reload":"First session.","open_threads":[]}`
- Else newest entry ⇒ `{"first_session":false,"context_reload":<leaving_behind>,"open_threads":[...]}`
Never writes (asserted by test: mtime/content unchanged).

### `zygos::tessera::session_close` (write)

Request:
```json
{"project": "...", "date": "YYYY-MM-DD HH:MM", "accomplished": "...",
 "leaving_behind": "...", "open_threads": ["..."], "log": ["..."],
 "intention": "...", "context_reload": "...", "actions": ["..."]}
```
`project`, `date`, `leaving_behind` required; `leaving_behind` must be non-blank
after trim ("never leave Leaving behind empty") — else error.Failed, no write.
Others default empty.

1. If `checkpoint_function` configured: bus-call it first; any error ⇒ error.Failed.
2. Render entry; SESSIONS.md exists ⇒ `prependEntry`, else `initialSessionsFile`
   (create the project dir if needed). Write atomically (tmp+rename, the
   mission_store idiom).
3. If `actions` non-empty: `promoteActions` into PROJECT.md (create the file
   with `# <project>\n\n## Actions\n` if absent), atomic write.
4. Reply `{"ok":true,"first_session":<bool>,"promoted":<count>}`.

### Test contract (RED first) — over a TmpDir fixture vault, never the real one

1. `session_open on missing SESSIONS.md reports first_session`
2. `session_open returns newest leaving-behind + threads; does not write`
3. `session_close first creation: frontmatter-safe file; parseSessions sees 1 entry`
4. `session_close prepends; newest-first order preserved across two closes`
5. `blank leaving_behind refused; vault untouched`
6. `actions promoted to PROJECT.md as - [ ]; duplicates skipped; PROJECT.md created if absent`
7. `configured checkpoint_function is called before the write; its failure blocks the write (fail closed)`
8. `no leaks`

## Mission-boundary auto-log (the driver seam — orchestrator wires, not delegated)

`zygos::missions::start` gains two optional fields: `continuity_function`
(a bus function with session_close's contract) and `continuity_project`.
When both present, the mission driver:
- accumulates a log line per persisted FSM transition (`"<state> → <state>"`),
- on reaching a terminal state calls `continuity_function` once with
  accomplished (tasks done / stop reason), leaving_behind (terminal state +
  next action or stop reason — never blank), open_threads (unfinished tasks),
  and the accumulated log.
Continuity is observability, not a gate: a failed continuity call logs a
warning and does NOT change the mission outcome (unlike gate/budget).
Test: scripted mission with a continuity worker on the bus ⇒ SESSIONS.md gains
one entry whose Log holds the phase transitions; a mission with an unreachable
continuity function still reaches `done`.
