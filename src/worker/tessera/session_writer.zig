//! Pure session text transforms (W3 pure layer, M4; docs/specs/tessera-continuity.md).
//! Render and splice SESSIONS.md / PROJECT.md text with no bus and no file I/O —
//! callers own I/O. Results are arena-owned (same discipline as vault.zig).

const std = @import("std");
const textx = @import("../textx.zig");
const nextLine = textx.nextLine;
const containsIgnoreCase = textx.containsIgnoreCase;
const eqlIgnoreCase = textx.eqlIgnoreCase;

const vault = @import("vault.zig");

pub const Entry = struct {
    date: []const u8, // "YYYY-MM-DD HH:MM"
    context_reload: []const u8, // "" allowed
    intention: []const u8, // "" allowed
    log: []const []const u8, // pre-formatted "HH:MM — ..." lines
    accomplished: []const u8,
    leaving_behind: []const u8, // caller guarantees non-empty
    open_threads: []const []const u8,
};

/// Render one session entry in the Tessera format (see vault spec §format):
/// `---`, `## Session — <date>`, then `### 🔁 Context reload`, `### 🎯 Intention`,
/// `### 📝 Log`, `### ✅ Accomplished`, `### 🔮 Leaving behind`,
/// `### 🧵 Open threads`, trailing `---`. Empty sections render with an empty
/// body (heading kept, so the shape is stable for the parsers). Arena-owned.
pub fn renderEntry(arena: std.mem.Allocator, entry: Entry) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;

    try out.appendSlice(arena, "---\n");
    try out.appendSlice(arena, "## Session — ");
    try out.appendSlice(arena, entry.date);
    try out.appendSlice(arena, "\n\n");

    try writeSection(arena, &out, "### 🔁 Context reload", entry.context_reload);
    try writeSection(arena, &out, "### 🎯 Intention", entry.intention);
    try writeLogSection(arena, &out, entry.log);
    try writeSection(arena, &out, "### ✅ Accomplished", entry.accomplished);
    try writeSection(arena, &out, "### 🔮 Leaving behind", entry.leaving_behind);
    try writeThreadsSection(arena, &out, entry.open_threads);

    try out.appendSlice(arena, "---\n");
    return out.toOwnedSlice(arena);
}

/// Prepend `block` to SESSIONS.md text. If `text` starts with file-level
/// frontmatter (`---\n` ... `\n---\n`), insert after it; else insert at the
/// top. Never touches existing entries. Arena-owned result.
pub fn prependEntry(arena: std.mem.Allocator, text: []const u8, block: []const u8) error{OutOfMemory}![]u8 {
    const insert_at = findFileFrontmatterEnd(text) orelse 0;
    const before = text[0..insert_at];
    const after = text[insert_at..];

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, before);
    try out.appendSlice(arena, block);
    // Ensure a newline between block and trailing content when both are non-empty
    // and the join would otherwise glue characters.
    if (block.len > 0 and after.len > 0 and block[block.len - 1] != '\n' and after[0] != '\n') {
        try out.append(arena, '\n');
    }
    try out.appendSlice(arena, after);
    return out.toOwnedSlice(arena);
}

/// First-creation content: file frontmatter
/// `---\ntitle: Sessions — <project>\ntags: [sessions, project]\n---\n`
/// followed by `block`. (Frontmatter first so the entry's opening `---` is
/// not parsed as frontmatter — W3 "frontmatter-safe on first creation".)
pub fn initialSessionsFile(arena: std.mem.Allocator, project: []const u8, block: []const u8) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "---\ntitle: Sessions — ");
    try out.appendSlice(arena, project);
    try out.appendSlice(arena, "\ntags: [sessions, project]\n---\n");
    try out.appendSlice(arena, block);
    return out.toOwnedSlice(arena);
}

/// Append `- [ ] <item>` lines to PROJECT.md's `## Actions` section body
/// (create the section at EOF if absent). Existing checkboxes untouched;
/// duplicates (same trimmed text as an existing open box) are skipped.
pub fn promoteActions(arena: std.mem.Allocator, text: []const u8, items: []const []const u8) error{OutOfMemory}![]u8 {
    if (findActionsSectionBounds(text)) |bounds| {
        return promoteIntoExisting(arena, text, bounds, items);
    }
    return promoteCreateSection(arena, text, items);
}

// ── render helpers ──────────────────────────────────────────────────────────

fn writeSection(arena: std.mem.Allocator, out: *std.ArrayList(u8), heading: []const u8, body: []const u8) error{OutOfMemory}!void {
    try out.appendSlice(arena, heading);
    try out.appendSlice(arena, "\n\n");
    if (body.len > 0) {
        try out.appendSlice(arena, body);
        if (body[body.len - 1] != '\n') try out.append(arena, '\n');
        try out.append(arena, '\n');
    }
}

fn writeLogSection(arena: std.mem.Allocator, out: *std.ArrayList(u8), log: []const []const u8) error{OutOfMemory}!void {
    try out.appendSlice(arena, "### 📝 Log\n\n");
    for (log) |line| {
        try out.appendSlice(arena, line);
        if (line.len == 0 or line[line.len - 1] != '\n') try out.append(arena, '\n');
    }
    if (log.len > 0) try out.append(arena, '\n');
}

fn writeThreadsSection(arena: std.mem.Allocator, out: *std.ArrayList(u8), threads: []const []const u8) error{OutOfMemory}!void {
    try out.appendSlice(arena, "### 🧵 Open threads\n\n");
    for (threads) |t| {
        try out.appendSlice(arena, "- ");
        try out.appendSlice(arena, t);
        try out.append(arena, '\n');
    }
    if (threads.len > 0) try out.append(arena, '\n');
}

/// File-level YAML frontmatter end offset, or null if absent / not YAML.
/// Distinguishes entry delimiters (`---\n## Session ...\n---`) from real
/// frontmatter by rejecting an interior that contains a session header.
fn findFileFrontmatterEnd(text: []const u8) ?usize {
    if (!std.mem.startsWith(u8, text, "---\n")) return null;
    const close = std.mem.indexOfPos(u8, text, 4, "\n---\n") orelse return null;
    const interior = text[4..close];
    if (interiorContainsSessionHeader(interior)) return null;
    return close + "\n---\n".len;
}

fn interiorContainsSessionHeader(interior: []const u8) bool {
    var pos: usize = 0;
    while (pos < interior.len) {
        const line = nextLine(interior, &pos) orelse break;
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "## ") and containsIgnoreCase(trimmed, "session")) {
            return true;
        }
    }
    return false;
}

const ActionsBounds = struct {
    /// Index of the start of the `## Actions` heading line.
    heading_start: usize,
    /// Index just after the heading line's newline (start of body).
    body_start: usize,
    /// Index of the end of the section body (start of next `##` or EOF).
    body_end: usize,
};

fn findActionsSectionBounds(text: []const u8) ?ActionsBounds {
    var pos: usize = 0;
    while (pos < text.len) {
        const line_start = pos;
        const line = nextLine(text, &pos) orelse break;
        const trimmed = std.mem.trim(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "##")) continue;
        if (trimmed.len > 2 and trimmed[2] == '#') continue; // ### not ##
        if (trimmed.len > 2 and trimmed[2] != ' ' and trimmed[2] != '\t') continue;
        const heading = if (trimmed.len > 2) std.mem.trim(u8, trimmed[2..], " \t") else "";
        if (!containsIgnoreCase(heading, "actions")) continue;

        const body_start = pos;
        var end_pos = pos;
        while (end_pos < text.len) {
            const ls = end_pos;
            const l = nextLine(text, &end_pos) orelse break;
            const t = std.mem.trim(u8, l, " \t");
            if (std.mem.startsWith(u8, t, "##") and !(t.len > 2 and t[2] == '#')) {
                return .{
                    .heading_start = line_start,
                    .body_start = body_start,
                    .body_end = ls,
                };
            }
        }
        return .{
            .heading_start = line_start,
            .body_start = body_start,
            .body_end = text.len,
        };
    }
    return null;
}

fn promoteIntoExisting(
    arena: std.mem.Allocator,
    text: []const u8,
    bounds: ActionsBounds,
    items: []const []const u8,
) error{OutOfMemory}![]u8 {
    const body = text[bounds.body_start..bounds.body_end];
    var existing: std.ArrayList([]const u8) = .empty;
    var pos: usize = 0;
    while (nextLine(body, &pos)) |line| {
        if (parseOpenCheckbox(line)) |item| {
            try existing.append(arena, item);
        }
    }

    var additions: std.ArrayList(u8) = .empty;
    for (items) |item| {
        const trimmed = std.mem.trim(u8, item, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (hasOpenDuplicate(existing.items, trimmed)) continue;
        try additions.appendSlice(arena, "- [ ] ");
        try additions.appendSlice(arena, trimmed);
        try additions.append(arena, '\n');
        try existing.append(arena, trimmed);
    }

    if (additions.items.len == 0) {
        return arena.dupe(u8, text);
    }

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, text[0..bounds.body_end]);
    // If body is non-empty and doesn't end with newline, add one before new items.
    if (bounds.body_end > bounds.body_start and text[bounds.body_end - 1] != '\n') {
        try out.append(arena, '\n');
    }
    try out.appendSlice(arena, additions.items);
    try out.appendSlice(arena, text[bounds.body_end..]);
    return out.toOwnedSlice(arena);
}

fn promoteCreateSection(arena: std.mem.Allocator, text: []const u8, items: []const []const u8) error{OutOfMemory}![]u8 {
    var additions: std.ArrayList(u8) = .empty;
    var seen: std.ArrayList([]const u8) = .empty;
    for (items) |item| {
        const trimmed = std.mem.trim(u8, item, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (hasOpenDuplicate(seen.items, trimmed)) continue;
        try additions.appendSlice(arena, "- [ ] ");
        try additions.appendSlice(arena, trimmed);
        try additions.append(arena, '\n');
        try seen.append(arena, trimmed);
    }

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, text);
    if (text.len > 0 and text[text.len - 1] != '\n') {
        try out.append(arena, '\n');
    }
    if (text.len > 0) {
        try out.append(arena, '\n');
    }
    try out.appendSlice(arena, "## Actions\n\n");
    try out.appendSlice(arena, additions.items);
    return out.toOwnedSlice(arena);
}

fn hasOpenDuplicate(existing: []const []const u8, item: []const u8) bool {
    for (existing) |e| {
        if (std.mem.eql(u8, std.mem.trim(u8, e, " \t\r\n"), item)) return true;
    }
    return false;
}

fn parseOpenCheckbox(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (!std.mem.startsWith(u8, trimmed, "- [ ]")) return null;
    return std.mem.trim(u8, trimmed[5..], " \t");
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

fn sampleEntry() Entry {
    return .{
        .date = "2024-06-01 14:30",
        .context_reload = "Reloaded prior seam.",
        .intention = "Ship session_writer.",
        .log = &.{
            "14:00 — started pure layer",
            "14:30 — tests green",
        },
        .accomplished = "Wrote renderEntry.",
        .leaving_behind = "Wire the continuity worker next.",
        .open_threads = &.{
            "tessera_continuity.zig",
            "mission auto-log",
        },
    };
}

test "renderEntry emits every section heading in order; round-trips through vault.parseSessions" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const rendered = try renderEntry(arena, sampleEntry());

    // Headings in order (emoji + name as specified).
    const h1 = "### 🔁 Context reload";
    const h2 = "### 🎯 Intention";
    const h3 = "### 📝 Log";
    const h4 = "### ✅ Accomplished";
    const h5 = "### 🔮 Leaving behind";
    const h6 = "### 🧵 Open threads";
    const p1 = std.mem.indexOf(u8, rendered, h1) orelse return error.TestExpectedEqual;
    const p2 = std.mem.indexOf(u8, rendered, h2) orelse return error.TestExpectedEqual;
    const p3 = std.mem.indexOf(u8, rendered, h3) orelse return error.TestExpectedEqual;
    const p4 = std.mem.indexOf(u8, rendered, h4) orelse return error.TestExpectedEqual;
    const p5 = std.mem.indexOf(u8, rendered, h5) orelse return error.TestExpectedEqual;
    const p6 = std.mem.indexOf(u8, rendered, h6) orelse return error.TestExpectedEqual;
    try testing.expect(p1 < p2 and p2 < p3 and p3 < p4 and p4 < p5 and p5 < p6);

    try testing.expect(std.mem.startsWith(u8, rendered, "---\n"));
    try testing.expect(std.mem.indexOf(u8, rendered, "## Session — 2024-06-01 14:30") != null);
    try testing.expect(std.mem.endsWith(u8, rendered, "---\n"));

    const sessions = try vault.parseSessions(arena, rendered);
    try testing.expectEqual(@as(usize, 1), sessions.len);
    try testing.expectEqualStrings("2024-06-01", sessions[0].date);
    try testing.expectEqualStrings("Wire the continuity worker next.", sessions[0].leaving_behind);
    try testing.expectEqual(@as(usize, 2), sessions[0].open_threads.len);
    try testing.expectEqualStrings("tessera_continuity.zig", sessions[0].open_threads[0]);
    try testing.expectEqualStrings("mission auto-log", sessions[0].open_threads[1]);
}

test "renderEntry with empty log/threads keeps headings with empty bodies" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const entry = Entry{
        .date = "2024-06-02 09:00",
        .context_reload = "",
        .intention = "",
        .log = &.{},
        .accomplished = "",
        .leaving_behind = "Empty sections ok.",
        .open_threads = &.{},
    };
    const rendered = try renderEntry(arena, entry);

    try testing.expect(std.mem.indexOf(u8, rendered, "### 🔁 Context reload") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "### 🎯 Intention") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "### 📝 Log") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "### ✅ Accomplished") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "### 🔮 Leaving behind") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "### 🧵 Open threads") != null);
    // No bullet lines under open threads when empty.
    try testing.expect(std.mem.indexOf(u8, rendered, "\n- ") == null);

    const sessions = try vault.parseSessions(arena, rendered);
    try testing.expectEqual(@as(usize, 1), sessions.len);
    try testing.expectEqualStrings("Empty sections ok.", sessions[0].leaving_behind);
    try testing.expectEqual(@as(usize, 0), sessions[0].open_threads.len);
}

test "prependEntry inserts after file frontmatter; existing entries intact and older" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const existing =
        \\---
        \\title: Sessions — zygos
        \\tags: [sessions, project]
        \\---
        \\---
        \\## Session — 2024-05-01 10:00
        \\
        \\### 🔮 Leaving behind
        \\
        \\Older seam.
        \\
        \\### 🧵 Open threads
        \\
        \\- old thread
        \\
        \\---
        \\
    ;
    const newer = try renderEntry(arena, .{
        .date = "2024-06-01 12:00",
        .context_reload = "",
        .intention = "",
        .log = &.{},
        .accomplished = "",
        .leaving_behind = "Newer seam.",
        .open_threads = &.{"new thread"},
    });
    const out = try prependEntry(arena, existing, newer);

    // Frontmatter still first.
    try testing.expect(std.mem.startsWith(u8, out, "---\ntitle: Sessions — zygos\n"));
    // New session appears before old date in the document.
    const inew = std.mem.indexOf(u8, out, "2024-06-01") orelse return error.TestExpectedEqual;
    const iold = std.mem.indexOf(u8, out, "2024-05-01") orelse return error.TestExpectedEqual;
    try testing.expect(inew < iold);

    const sessions = try vault.parseSessions(arena, out);
    try testing.expectEqual(@as(usize, 2), sessions.len);
    try testing.expectEqualStrings("2024-06-01", sessions[0].date);
    try testing.expectEqualStrings("Newer seam.", sessions[0].leaving_behind);
    try testing.expectEqualStrings("2024-05-01", sessions[1].date);
    try testing.expectEqualStrings("Older seam.", sessions[1].leaving_behind);
}

test "prependEntry on text without frontmatter inserts at top" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const existing =
        \\## Session — 2024-05-01 10:00
        \\
        \\### 🔮 Leaving behind
        \\
        \\Only entry.
        \\
        \\### 🧵 Open threads
        \\
        \\- t
        \\
    ;
    const block = try renderEntry(arena, .{
        .date = "2024-06-01 08:00",
        .context_reload = "",
        .intention = "",
        .log = &.{},
        .accomplished = "",
        .leaving_behind = "Prepended.",
        .open_threads = &.{},
    });
    const out = try prependEntry(arena, existing, block);

    try testing.expect(std.mem.startsWith(u8, out, "---\n## Session — 2024-06-01"));
    const sessions = try vault.parseSessions(arena, out);
    try testing.expectEqual(@as(usize, 2), sessions.len);
    try testing.expectEqualStrings("2024-06-01", sessions[0].date);
    try testing.expectEqualStrings("2024-05-01", sessions[1].date);
}

test "initialSessionsFile: frontmatter first, then entry; vault.parseSessions finds exactly one session" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const block = try renderEntry(arena, sampleEntry());
    const file = try initialSessionsFile(arena, "zygos", block);

    try testing.expect(std.mem.startsWith(u8, file, "---\ntitle: Sessions — zygos\ntags: [sessions, project]\n---\n"));
    // Entry delimiter comes after frontmatter (frontmatter-safe).
    const after_fm = std.mem.indexOf(u8, file, "tags: [sessions, project]\n---\n") orelse return error.TestExpectedEqual;
    const rest = file[after_fm + "tags: [sessions, project]\n---\n".len ..];
    try testing.expect(std.mem.startsWith(u8, rest, "---\n## Session — "));

    const sessions = try vault.parseSessions(arena, file);
    try testing.expectEqual(@as(usize, 1), sessions.len);
    try testing.expectEqualStrings("2024-06-01", sessions[0].date);
    try testing.expectEqualStrings("Wire the continuity worker next.", sessions[0].leaving_behind);
}

test "promoteActions appends to existing ## Actions preserving checked/unchecked lines" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const text =
        \\# Project
        \\
        \\## Actions
        \\
        \\- [ ] keep open
        \\- [x] already done
        \\
        \\## Notes
        \\
        \\leave me alone
        \\
    ;
    const out = try promoteActions(arena, text, &.{"brand new"});
    try testing.expect(std.mem.indexOf(u8, out, "- [ ] keep open") != null);
    try testing.expect(std.mem.indexOf(u8, out, "- [x] already done") != null);
    try testing.expect(std.mem.indexOf(u8, out, "- [ ] brand new") != null);
    try testing.expect(std.mem.indexOf(u8, out, "## Notes") != null);
    try testing.expect(std.mem.indexOf(u8, out, "leave me alone") != null);

    // New item sits inside Actions (before Notes).
    const inew = std.mem.indexOf(u8, out, "- [ ] brand new") orelse return error.TestExpectedEqual;
    const inotes = std.mem.indexOf(u8, out, "## Notes") orelse return error.TestExpectedEqual;
    try testing.expect(inew < inotes);
}

test "promoteActions creates ## Actions when missing" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const text =
        \\# Project
        \\
        \\Some body.
        \\
    ;
    const out = try promoteActions(arena, text, &.{ "one", "two" });
    try testing.expect(std.mem.indexOf(u8, out, "## Actions") != null);
    try testing.expect(std.mem.indexOf(u8, out, "- [ ] one") != null);
    try testing.expect(std.mem.indexOf(u8, out, "- [ ] two") != null);
    try testing.expect(std.mem.indexOf(u8, out, "# Project") != null);
}

test "promoteActions skips duplicates of existing open items" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const text =
        \\## Actions
        \\
        \\- [ ] already open
        \\- [x] done twin
        \\
    ;
    const out = try promoteActions(arena, text, &.{ "already open", "  already open  ", "fresh", "done twin" });

    // Open duplicate skipped; checked "done twin" is not an open-box duplicate so is added.
    var count_already: usize = 0;
    var count_fresh: usize = 0;
    var count_done_open: usize = 0;
    var pos: usize = 0;
    while (nextLine(out, &pos)) |line| {
        const t = std.mem.trim(u8, line, " \t");
        if (std.mem.eql(u8, t, "- [ ] already open")) count_already += 1;
        if (std.mem.eql(u8, t, "- [ ] fresh")) count_fresh += 1;
        if (std.mem.eql(u8, t, "- [ ] done twin")) count_done_open += 1;
    }
    try testing.expectEqual(@as(usize, 1), count_already);
    try testing.expectEqual(@as(usize, 1), count_fresh);
    try testing.expectEqual(@as(usize, 1), count_done_open);
    try testing.expect(std.mem.indexOf(u8, out, "- [x] done twin") != null);
}

test "no leaks under std.testing.allocator arenas" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const block = try renderEntry(arena, sampleEntry());
    const emptyish = try renderEntry(arena, .{
        .date = "2024-01-01 00:00",
        .context_reload = "",
        .intention = "",
        .log = &.{},
        .accomplished = "",
        .leaving_behind = "x",
        .open_threads = &.{},
    });
    const file = try initialSessionsFile(arena, "leakcheck", block);
    const prepended = try prependEntry(arena, file, emptyish);
    _ = try vault.parseSessions(arena, prepended);

    const proj =
        \\# P
        \\
        \\## Actions
        \\
        \\- [ ] a
        \\
    ;
    _ = try promoteActions(arena, proj, &.{ "a", "b" });
    _ = try promoteActions(arena, "# only\n", &.{"c"});
    // Arena deinit on exit; testing.allocator reports any non-arena leak.
}
