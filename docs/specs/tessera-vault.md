# Spec: `src/worker/tessera/vault.zig` — pure vault parsers (W2 core, M4)

Pure parsing + analysis over Tessera vault text (SESSIONS.md / PROJECT.md).
NO bus, NO file I/O — callers read files (libc, per Z-02) and pass text in.
An allocator IS permitted here (results are owned slices/lists), unlike brief.zig.

The vault format is Mauricio's Tessera spec:
- `SESSIONS.md`: reverse-chronological entries, each starting with a line
  `## Session — YYYY-MM-DD HH:MM`. Within an entry, subsections start with
  `### <emoji> <Name>` — the ones we parse are `Leaving behind` and
  `Open threads` (match by the subsection heading text containing that phrase,
  case-insensitive; ignore leading emoji). A subsection body runs until the
  next `###` or `##` or EOF. `Open threads` bodies are markdown bullet lists
  (`- ...` lines); each bullet is one thread.
- `PROJECT.md`: a `## Actions` section whose body has `- [ ] ...` (open) and
  `- [x] ...` (done) checkbox lines. We collect the OPEN ones.

## Public API

```zig
pub const Session = struct {
    date: []const u8,          // "YYYY-MM-DD" slice into input
    leaving_behind: []const u8,// trimmed body text, slice into input ("" if absent)
    open_threads: []const []const u8, // bullet texts, arena-owned slice
};

/// Parse SESSIONS.md newest-first (document order == reverse-chron already).
/// Entries with no `## Session — DATE` header are skipped. Arena-owned.
pub fn parseSessions(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]Session;

/// Open (`- [ ]`) action lines from PROJECT.md `## Actions`. Arena-owned.
pub fn parseOpenActions(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}![][]const u8;

/// Days between an ISO "YYYY-MM-DD" and `today` (also "YYYY-MM-DD").
/// Returns null on a malformed date. Uses civil-day arithmetic, no libc time.
pub fn daysBetween(iso: []const u8, today: []const u8) ?i64;

pub const STALE_DAYS = 14;

/// A "Leaving behind" repeated verbatim (after trim) across >= `run` of the
/// most-recent consecutive sessions signals a stalled loop.
pub fn stalledLoop(sessions: []const Session, run: usize) bool;
```

## Test contract (RED first)

1. `parseSessions extracts date + leaving-behind + open threads for a 2-entry file`
2. `an entry missing Leaving behind yields "" for it`
3. `open_threads splits every bullet; a section with no bullets yields empty`
4. `entries without a Session header are skipped`
5. `parseOpenActions returns only unchecked boxes, in order`
6. `parseOpenActions on a file with no ## Actions returns empty`
7. `daysBetween counts civil days; same day = 0; malformed = null; crosses month/year`
8. `stalledLoop true when the newest `run` sessions share identical leaving-behind`
9. `stalledLoop false when they differ, or fewer than `run` sessions exist`
10. `no leaks (arena freed by caller; test uses std.testing.allocator arena)`

## Worker layer (I wire, not delegated): `src/worker/tessera_orient.zig`

Registers `zygos::tessera::{project_status,open_threads,stale_projects,reflect}`.
Config injects the vault root + projects subdir (`Projects/`), the sessions
filename (`SESSIONS.md`), the project filename (`PROJECT.md`) and `today`
(injectable for deterministic tests). Each handler lists project dirs under
`<root>/<projects>`, reads the two files via libc (mission_store's open/read
idiom), runs the pure parsers, and returns JSON. `stale_projects` flags
`daysBetween(newest_session_date, today) > STALE_DAYS`. Tests run against a
temp fixture vault built in a TmpDir, never the real vault.
