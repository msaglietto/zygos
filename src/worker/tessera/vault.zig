//! Pure vault parsers (W2 core, M4; docs/specs/tessera-vault.md). Parse and
//! analyze Tessera vault text (SESSIONS.md / PROJECT.md) with no bus and no
//! file I/O — callers read files and pass text in. An allocator is allowed
//! (results are arena-owned), unlike brief.zig.

const std = @import("std");

pub const Session = struct {
    date: []const u8, // "YYYY-MM-DD" slice into input
    leaving_behind: []const u8, // trimmed body text, slice into input ("" if absent)
    open_threads: []const []const u8, // bullet texts, arena-owned slice
};

pub const STALE_DAYS: i64 = 14;

/// Parse SESSIONS.md newest-first (document order == reverse-chron already).
/// Entries with no `## Session — DATE` header are skipped. Arena-owned.
pub fn parseSessions(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]Session {
    var sessions: std.ArrayList(Session) = .empty;
    var pos: usize = 0;
    while (pos < text.len) {
        const line_start = pos;
        const line = nextLine(text, &pos) orelse break;
        if (parseSessionHeader(line)) |date| {
            const body_start = pos;
            // Body runs until the next ## Session header (or EOF).
            const body_end = findNextSessionStart(text, pos);
            pos = body_end;
            const body = text[body_start..body_end];
            const leaving = findLeavingBehind(body);
            const threads = try parseOpenThreadBullets(arena, body);
            try sessions.append(arena, .{
                .date = date,
                .leaving_behind = leaving,
                .open_threads = threads,
            });
            _ = line_start;
        }
        // else: skip non-session lines (entries without a Session header)
    }
    return sessions.toOwnedSlice(arena);
}

/// Open (`- [ ]`) action lines from PROJECT.md `## Actions`. Arena-owned.
pub fn parseOpenActions(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const actions = findActionsSection(text) orelse return out.toOwnedSlice(arena);
    var pos: usize = 0;
    while (nextLine(actions, &pos)) |line| {
        if (parseOpenCheckbox(line)) |item| {
            try out.append(arena, item);
        }
    }
    return out.toOwnedSlice(arena);
}

/// Days between an ISO "YYYY-MM-DD" and `today` (also "YYYY-MM-DD").
/// Returns null on a malformed date. Uses civil-day arithmetic, no libc time.
pub fn daysBetween(iso: []const u8, today: []const u8) ?i64 {
    const a = parseIsoDate(iso) orelse return null;
    const b = parseIsoDate(today) orelse return null;
    return daysFromCivil(b.y, b.m, b.d) - daysFromCivil(a.y, a.m, a.d);
}

/// A "Leaving behind" repeated verbatim (after trim) across >= `run` of the
/// most-recent consecutive sessions signals a stalled loop.
pub fn stalledLoop(sessions: []const Session, run: usize) bool {
    if (run == 0 or sessions.len < run) return false;
    const first = std.mem.trim(u8, sessions[0].leaving_behind, " \t\r\n");
    var i: usize = 1;
    while (i < run) : (i += 1) {
        const lb = std.mem.trim(u8, sessions[i].leaving_behind, " \t\r\n");
        if (!std.mem.eql(u8, first, lb)) return false;
    }
    return true;
}

// ── scanning helpers ────────────────────────────────────────────────────────

fn nextLine(text: []const u8, pos: *usize) ?[]const u8 {
    if (pos.* >= text.len) return null;
    const start = pos.*;
    if (std.mem.indexOfScalarPos(u8, text, start, '\n')) |nl| {
        var end = nl;
        if (end > start and text[end - 1] == '\r') end -= 1;
        pos.* = nl + 1;
        return text[start..end];
    }
    pos.* = text.len;
    return text[start..];
}

fn isBlank(line: []const u8) bool {
    return std.mem.trim(u8, line, " \t").len == 0;
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (hay.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (std.ascii.toLower(ac) != std.ascii.toLower(bc)) return false;
    }
    return true;
}

/// `## Session — YYYY-MM-DD HH:MM` (em dash or hyphen; time optional for matching).
fn parseSessionHeader(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (!std.mem.startsWith(u8, trimmed, "##")) return null;
    // Level-2 only: exactly two hashes, then space.
    if (trimmed.len < 3 or trimmed[2] == '#') return null;
    if (trimmed[2] != ' ' and trimmed[2] != '\t') return null;
    const rest = std.mem.trim(u8, trimmed[3..], " \t");
    if (!containsIgnoreCase(rest, "session")) return null;
    // Extract first YYYY-MM-DD in the line.
    return findIsoDate(rest);
}

fn findIsoDate(s: []const u8) ?[]const u8 {
    // Scan for ####-##-##
    if (s.len < 10) return null;
    var i: usize = 0;
    while (i + 10 <= s.len) : (i += 1) {
        if (isIsoDateAt(s, i)) return s[i .. i + 10];
    }
    return null;
}

fn isIsoDateAt(s: []const u8, i: usize) bool {
    if (i + 10 > s.len) return false;
    inline for (0..4) |k| {
        if (!std.ascii.isDigit(s[i + k])) return false;
    }
    if (s[i + 4] != '-') return false;
    inline for (5..7) |k| {
        if (!std.ascii.isDigit(s[i + k])) return false;
    }
    if (s[i + 7] != '-') return false;
    inline for (8..10) |k| {
        if (!std.ascii.isDigit(s[i + k])) return false;
    }
    return true;
}

fn findNextSessionStart(text: []const u8, from: usize) usize {
    var pos = from;
    while (pos < text.len) {
        const line_start = pos;
        const line = nextLine(text, &pos) orelse return text.len;
        if (parseSessionHeader(line) != null) return line_start;
    }
    return text.len;
}

const SubHeading = struct {
    body_start: usize,
    // end of body is computed by walking
};

fn findLeavingBehind(body: []const u8) []const u8 {
    const sec = findSubsection(body, "leaving behind") orelse return "";
    return std.mem.trim(u8, sec, " \t\r\n");
}

fn parseOpenThreadBullets(arena: std.mem.Allocator, body: []const u8) error{OutOfMemory}![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const sec = findSubsection(body, "open threads") orelse return out.toOwnedSlice(arena);
    var pos: usize = 0;
    while (nextLine(sec, &pos)) |line| {
        if (parseBullet(line)) |text| {
            try out.append(arena, text);
        }
    }
    return out.toOwnedSlice(arena);
}

/// Subsection body from after `### ...needle...` until next `###` or `##` or EOF.
fn findSubsection(body: []const u8, needle: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < body.len) {
        const line = nextLine(body, &pos) orelse break;
        if (isH3Containing(line, needle)) {
            const start = pos;
            const end = subsectionEnd(body, pos);
            return body[start..end];
        }
    }
    return null;
}

fn isH3Containing(line: []const u8, needle: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (!std.mem.startsWith(u8, trimmed, "###")) return false;
    if (trimmed.len > 3 and trimmed[3] == '#') return false; // #### or more
    // Require space or end after ###
    if (trimmed.len > 3 and trimmed[3] != ' ' and trimmed[3] != '\t') return false;
    const text = if (trimmed.len > 3) std.mem.trim(u8, trimmed[3..], " \t") else "";
    return containsIgnoreCase(text, needle);
}

fn subsectionEnd(body: []const u8, from: usize) usize {
    var pos = from;
    while (pos < body.len) {
        const line_start = pos;
        const line = nextLine(body, &pos) orelse return body.len;
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "##")) {
            // ### or ## both end the subsection
            return line_start;
        }
    }
    return body.len;
}

fn parseBullet(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (!std.mem.startsWith(u8, trimmed, "- ")) return null;
    // Skip checkbox-style bullets for open-threads? Spec says markdown bullet lists
    // (`- ...` lines); checkboxes are for Actions. Accept plain `- text`.
    const rest = std.mem.trim(u8, trimmed[2..], " \t");
    if (rest.len == 0) return null;
    return rest;
}

fn findActionsSection(text: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < text.len) {
        const line = nextLine(text, &pos) orelse break;
        const trimmed = std.mem.trim(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "##")) continue;
        if (trimmed.len > 2 and trimmed[2] == '#') continue; // ### not ##
        if (trimmed.len > 2 and trimmed[2] != ' ' and trimmed[2] != '\t') continue;
        const heading = if (trimmed.len > 2) std.mem.trim(u8, trimmed[2..], " \t") else "";
        if (!containsIgnoreCase(heading, "actions")) continue;
        const start = pos;
        // Section ends at next ## (level <= 2) or EOF
        var end_pos = pos;
        while (end_pos < text.len) {
            const ls = end_pos;
            const l = nextLine(text, &end_pos) orelse break;
            const t = std.mem.trim(u8, l, " \t");
            if (std.mem.startsWith(u8, t, "##") and !(t.len > 2 and t[2] == '#')) {
                return text[start..ls];
            }
        }
        return text[start..text.len];
    }
    return null;
}

/// `- [ ] text` → trimmed text after the checkbox.
fn parseOpenCheckbox(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t");
    // Accept optional leading indent already trimmed; form: - [ ] ...
    if (!std.mem.startsWith(u8, trimmed, "- [ ]")) return null;
    const rest = trimmed[5..];
    return std.mem.trim(u8, rest, " \t");
}

const CivilDate = struct { y: i32, m: u32, d: u32 };

fn parseIsoDate(s: []const u8) ?CivilDate {
    if (s.len != 10) return null;
    if (!isIsoDateAt(s, 0)) return null;
    const y = std.fmt.parseInt(i32, s[0..4], 10) catch return null;
    const m = std.fmt.parseInt(u32, s[5..7], 10) catch return null;
    const d = std.fmt.parseInt(u32, s[8..10], 10) catch return null;
    if (m < 1 or m > 12) return null;
    if (d < 1 or d > 31) return null;
    return .{ .y = y, .m = m, .d = d };
}

/// Days since civil 1970-01-01 (Howard Hinnant algorithm). Difference only matters.
fn daysFromCivil(y_in: i32, m: u32, d: u32) i64 {
    var y: i32 = y_in;
    const m_i: i32 = @intCast(m);
    const d_i: i32 = @intCast(d);
    y -= @intFromBool(m_i <= 2);
    const era: i32 = if (y >= 0) @divFloor(y, 400) else @divFloor(y - 399, 400);
    const yoe: u32 = @intCast(y - era * 400);
    const mp: i32 = if (m_i > 2) m_i - 3 else m_i + 9;
    const doy: u32 = @intCast(@divTrunc(153 * mp + 2, 5) + d_i - 1);
    const doe: u32 = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return @as(i64, era) * 146097 + @as(i64, @intCast(doe)) - 719468;
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "parseSessions extracts date + leaving-behind + open threads for a 2-entry file" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const text =
        \\## Session — 2024-03-15 14:30
        \\
        \\### 📌 Leaving behind
        \\
        \\Finished the vault parsers.
        \\
        \\### 🧵 Open threads
        \\
        \\- wire orient worker
        \\- add fixture vault
        \\
        \\## Session — 2024-03-10 09:00
        \\
        \\### 📌 Leaving behind
        \\
        \\Started M4.
        \\
        \\### 🧵 Open threads
        \\
        \\- write the pure module
        \\
    ;
    const sessions = try parseSessions(arena, text);
    try testing.expectEqual(@as(usize, 2), sessions.len);

    try testing.expectEqualStrings("2024-03-15", sessions[0].date);
    try testing.expectEqualStrings("Finished the vault parsers.", sessions[0].leaving_behind);
    try testing.expectEqual(@as(usize, 2), sessions[0].open_threads.len);
    try testing.expectEqualStrings("wire orient worker", sessions[0].open_threads[0]);
    try testing.expectEqualStrings("add fixture vault", sessions[0].open_threads[1]);

    try testing.expectEqualStrings("2024-03-10", sessions[1].date);
    try testing.expectEqualStrings("Started M4.", sessions[1].leaving_behind);
    try testing.expectEqual(@as(usize, 1), sessions[1].open_threads.len);
    try testing.expectEqualStrings("write the pure module", sessions[1].open_threads[0]);
}

test "an entry missing Leaving behind yields \"\" for it" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const text =
        \\## Session — 2024-01-01 10:00
        \\
        \\### 🧵 Open threads
        \\
        \\- only a thread
        \\
    ;
    const sessions = try parseSessions(arena, text);
    try testing.expectEqual(@as(usize, 1), sessions.len);
    try testing.expectEqualStrings("", sessions[0].leaving_behind);
    try testing.expectEqual(@as(usize, 1), sessions[0].open_threads.len);
}

test "open_threads splits every bullet; a section with no bullets yields empty" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const with_bullets =
        \\## Session — 2024-02-01 12:00
        \\
        \\### Open threads
        \\
        \\- first
        \\- second
        \\- third
        \\
    ;
    const s1 = try parseSessions(arena, with_bullets);
    try testing.expectEqual(@as(usize, 3), s1[0].open_threads.len);
    try testing.expectEqualStrings("first", s1[0].open_threads[0]);
    try testing.expectEqualStrings("second", s1[0].open_threads[1]);
    try testing.expectEqualStrings("third", s1[0].open_threads[2]);

    const no_bullets =
        \\## Session — 2024-02-02 12:00
        \\
        \\### Open threads
        \\
        \\nothing here, just prose
        \\
    ;
    const s2 = try parseSessions(arena, no_bullets);
    try testing.expectEqual(@as(usize, 1), s2.len);
    try testing.expectEqual(@as(usize, 0), s2[0].open_threads.len);
}

test "entries without a Session header are skipped" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const text =
        \\# Vault index
        \\
        \\Some preamble.
        \\
        \\## Not a session
        \\
        \\### Leaving behind
        \\
        \\Should be ignored.
        \\
        \\## Session — 2024-05-01 08:00
        \\
        \\### Leaving behind
        \\
        \\Real entry.
        \\
    ;
    const sessions = try parseSessions(arena, text);
    try testing.expectEqual(@as(usize, 1), sessions.len);
    try testing.expectEqualStrings("2024-05-01", sessions[0].date);
    try testing.expectEqualStrings("Real entry.", sessions[0].leaving_behind);
}

test "parseOpenActions returns only unchecked boxes, in order" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const text =
        \\# Project
        \\
        \\## Actions
        \\
        \\- [ ] first open
        \\- [x] done already
        \\- [ ] second open
        \\- [X] also done
        \\- [ ] third open
        \\
        \\## Other
        \\
        \\- [ ] not in actions
        \\
    ;
    const actions = try parseOpenActions(arena, text);
    try testing.expectEqual(@as(usize, 3), actions.len);
    try testing.expectEqualStrings("first open", actions[0]);
    try testing.expectEqualStrings("second open", actions[1]);
    try testing.expectEqualStrings("third open", actions[2]);
}

test "parseOpenActions on a file with no ## Actions returns empty" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const text =
        \\# Project
        \\
        \\## Notes
        \\
        \\- [ ] orphan checkbox
        \\
    ;
    const actions = try parseOpenActions(arena, text);
    try testing.expectEqual(@as(usize, 0), actions.len);
}

test "daysBetween counts civil days; same day = 0; malformed = null; crosses month/year" {
    try testing.expectEqual(@as(?i64, 0), daysBetween("2024-03-15", "2024-03-15"));
    try testing.expectEqual(@as(?i64, 1), daysBetween("2024-03-14", "2024-03-15"));
    try testing.expectEqual(@as(?i64, 5), daysBetween("2024-03-10", "2024-03-15"));
    // Cross month
    try testing.expectEqual(@as(?i64, 2), daysBetween("2024-02-28", "2024-03-01")); // 2024 leap
    // Cross year
    try testing.expectEqual(@as(?i64, 2), daysBetween("2023-12-30", "2024-01-01"));
    // Past → future is positive; future → past is negative
    try testing.expectEqual(@as(?i64, -3), daysBetween("2024-01-04", "2024-01-01"));
    // Malformed
    try testing.expect(daysBetween("not-a-date", "2024-01-01") == null);
    try testing.expect(daysBetween("2024-01-01", "bad") == null);
    try testing.expect(daysBetween("2024-1-1", "2024-01-01") == null);
}

test "stalledLoop true when the newest `run` sessions share identical leaving-behind" {
    const sessions = [_]Session{
        .{ .date = "2024-03-15", .leaving_behind = "  same text  ", .open_threads = &.{} },
        .{ .date = "2024-03-14", .leaving_behind = "same text", .open_threads = &.{} },
        .{ .date = "2024-03-13", .leaving_behind = "same text\n", .open_threads = &.{} },
        .{ .date = "2024-03-12", .leaving_behind = "different", .open_threads = &.{} },
    };
    try testing.expect(stalledLoop(&sessions, 3));
    try testing.expect(stalledLoop(&sessions, 2));
}

test "stalledLoop false when they differ, or fewer than `run` sessions exist" {
    const differ = [_]Session{
        .{ .date = "2024-03-15", .leaving_behind = "A", .open_threads = &.{} },
        .{ .date = "2024-03-14", .leaving_behind = "B", .open_threads = &.{} },
        .{ .date = "2024-03-13", .leaving_behind = "A", .open_threads = &.{} },
    };
    try testing.expect(!stalledLoop(&differ, 2));
    try testing.expect(!stalledLoop(&differ, 3));

    const few = [_]Session{
        .{ .date = "2024-03-15", .leaving_behind = "same", .open_threads = &.{} },
    };
    try testing.expect(!stalledLoop(&few, 2));
    try testing.expect(!stalledLoop(&few, 3));
    try testing.expect(!stalledLoop(&.{}, 1));
}

test "no leaks (arena freed by caller; test uses std.testing.allocator arena)" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const sessions_text =
        \\## Session — 2024-06-01 10:00
        \\
        \\### Leaving behind
        \\
        \\leak check
        \\
        \\### Open threads
        \\
        \\- thread one
        \\- thread two
        \\
        \\## Session — 2024-05-01 10:00
        \\
        \\### Leaving behind
        \\
        \\older
        \\
    ;
    const sessions = try parseSessions(arena, sessions_text);
    try testing.expectEqual(@as(usize, 2), sessions.len);

    const actions_text =
        \\## Actions
        \\
        \\- [ ] do a thing
        \\- [x] done
        \\
    ;
    const actions = try parseOpenActions(arena, actions_text);
    try testing.expectEqual(@as(usize, 1), actions.len);

    // Arena deinit on exit; testing.allocator reports any non-arena leak.
    _ = daysBetween(sessions[0].date, "2024-06-15");
    _ = stalledLoop(sessions, 2);
}
