//! git output filters (S8.3, docs/specs/filter.md).
//!
//! `git diff` is the single worst offender in an agent transcript: ztk
//! measured one `git diff HEAD~5` at 92k tokens, of which the actual changes
//! were a fifth. The rest is blob hashes, mode lines, and context the model
//! usually cannot act on.
//!
//! What survives here is what an agent reasons about: which file, which
//! hunk, which lines changed. What goes is git's bookkeeping.

const std = @import("std");
const guard = @import("guard.zig");

/// `git diff` / `git show`: keep `diff --git` headers, `@@` hunk headers and
/// `+`/`-` lines; drop `index <sha>..<sha>`, mode lines, `similarity index`,
/// and context lines beyond one either side of a change run.
pub fn diff(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}!?[]const u8 {
    if (guard.shouldSkipOrErrored(text)) return null;
    // Only act on something that actually looks like a diff.
    if (std.mem.indexOf(u8, text, "@@") == null and
        std.mem.indexOf(u8, text, "diff --git") == null) return null;

    // Pass 1: classify each line as kept, droppable-context, or noise.
    var kinds: std.ArrayList(Kind) = .empty;
    var raw: std.ArrayList([]const u8) = .empty;
    var it = guard.lines(text);
    while (it.next()) |line| {
        try raw.append(arena, line);
        try kinds.append(arena, classifyDiffLine(line));
    }

    // Pass 2: a context line survives only when it touches a changed line —
    // one line of either side, enough to anchor a hunk without paying for
    // the full window.
    var out: std.ArrayList(u8) = .empty;
    var dropped_context: usize = 0;
    var dropped_noise: usize = 0;
    for (raw.items, 0..) |line, i| {
        switch (kinds.items[i]) {
            .keep => try appendLine(arena, &out, line),
            .noise => dropped_noise += 1,
            .context => {
                const prev_changed = i > 0 and isChange(raw.items[i - 1]);
                const next_changed = i + 1 < raw.items.len and isChange(raw.items[i + 1]);
                if (prev_changed or next_changed) {
                    try appendLine(arena, &out, line);
                } else {
                    dropped_context += 1;
                }
            },
        }
    }
    if (dropped_context + dropped_noise == 0) return null;
    try out.appendSlice(arena, try guard.marker(
        arena,
        "diff: dropped {d} context lines, {d} metadata lines",
        .{ dropped_context, dropped_noise },
    ));
    try out.append(arena, '\n');
    return guard.keepIfSmaller(text, out.items);
}

fn isChange(line: []const u8) bool {
    if (line.len == 0) return false;
    if (std.mem.startsWith(u8, line, "+++") or std.mem.startsWith(u8, line, "---")) return false;
    return line[0] == '+' or line[0] == '-';
}

const Kind = enum { keep, context, noise };

fn classifyDiffLine(line: []const u8) Kind {
    if (std.mem.startsWith(u8, line, "diff --git")) return .keep;
    if (std.mem.startsWith(u8, line, "@@")) return .keep;
    if (std.mem.startsWith(u8, line, "+++") or std.mem.startsWith(u8, line, "---")) return .noise;
    if (std.mem.startsWith(u8, line, "index ")) return .noise;
    if (std.mem.startsWith(u8, line, "old mode") or std.mem.startsWith(u8, line, "new mode") or
        std.mem.startsWith(u8, line, "deleted file mode") or
        std.mem.startsWith(u8, line, "new file mode")) return .noise;
    if (std.mem.startsWith(u8, line, "similarity index") or
        std.mem.startsWith(u8, line, "rename from") or
        std.mem.startsWith(u8, line, "rename to")) return .noise;
    if (line.len > 0 and (line[0] == '+' or line[0] == '-')) return .keep;
    return .context;
}

/// `git log`: keep the commit subject line (and the short sha), drop author,
/// date and body. `--oneline` output is already minimal and passes through.
pub fn log(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}!?[]const u8 {
    if (guard.shouldSkipOrErrored(text)) return null;
    if (std.mem.indexOf(u8, text, "commit ") == null) return null; // already --oneline

    var out: std.ArrayList(u8) = .empty;
    var dropped: usize = 0;
    var it = guard.lines(text);
    var pending_sha: ?[]const u8 = null;
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "commit ")) {
            const sha = line["commit ".len..];
            pending_sha = sha[0..@min(sha.len, 8)];
            continue;
        }
        if (std.mem.startsWith(u8, line, "Author:") or std.mem.startsWith(u8, line, "Date:") or
            std.mem.startsWith(u8, line, "Merge:") or std.mem.startsWith(u8, line, "commit"))
        {
            dropped += 1;
            continue;
        }
        const body = std.mem.trim(u8, line, " \t");
        if (body.len == 0) continue;
        if (pending_sha) |sha| {
            try out.appendSlice(arena, sha);
            try out.append(arena, ' ');
            try appendLine(arena, &out, body);
            pending_sha = null;
        } else {
            dropped += 1; // continuation of the commit body
        }
    }
    if (dropped == 0) return null;
    try out.appendSlice(arena, try guard.marker(arena, "log: dropped {d} metadata/body lines", .{dropped}));
    try out.append(arena, '\n');
    return guard.keepIfSmaller(text, out.items);
}

/// `git status`: keep the porcelain-ish signal (branch, changed paths), drop
/// git's instructional prose ("use git restore …", "nothing added to commit").
pub fn status(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}!?[]const u8 {
    if (guard.shouldSkipOrErrored(text)) return null;

    var out: std.ArrayList(u8) = .empty;
    var dropped: usize = 0;
    var it = guard.lines(text);
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t");
        if (t.len == 0) {
            dropped += 1;
            continue;
        }
        if (isStatusProse(t)) {
            dropped += 1;
            continue;
        }
        try appendLine(arena, &out, line);
    }
    if (dropped == 0) return null;
    try out.appendSlice(arena, try guard.marker(arena, "status: dropped {d} hint lines", .{dropped}));
    try out.append(arena, '\n');
    return guard.keepIfSmaller(text, out.items);
}

fn isStatusProse(t: []const u8) bool {
    inline for (.{
        "(use \"git",
        "no changes added to commit",
        "nothing added to commit",
        "nothing to commit",
        "Changes not staged for commit:",
        "Changes to be committed:",
        "Untracked files:",
        "Your branch is up to date",
    }) |p| {
        if (std.mem.startsWith(u8, t, p)) return true;
    }
    return false;
}

fn appendLine(arena: std.mem.Allocator, out: *std.ArrayList(u8), line: []const u8) error{OutOfMemory}!void {
    try out.appendSlice(arena, line);
    try out.append(arena, '\n');
}

// ===========================================================================
// Tests (docs/specs/filter.md S8.3 per-filter contract)
// ===========================================================================

const testing = std.testing;

const diff_fixture =
    \\diff --git a/src/main.zig b/src/main.zig
    \\index 1a2b3c4..5d6e7f8 100644
    \\--- a/src/main.zig
    \\+++ b/src/main.zig
    \\@@ -10,7 +10,7 @@ pub fn main() void {
    \\     const a = 1;
    \\     const b = 2;
    \\     const c = 3;
    \\-    const d = 4;
    \\+    const d = 5;
    \\     const e = 6;
    \\     const f = 7;
    \\     const g = 8;
    \\
;

test "S8.3 git.diff: keeps hunks and changes, drops metadata and far context" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const got = (try diff(arena, diff_fixture)).?;
    // The change survives verbatim.
    try testing.expect(std.mem.indexOf(u8, got, "-    const d = 4;") != null);
    try testing.expect(std.mem.indexOf(u8, got, "+    const d = 5;") != null);
    // File + hunk anchors survive.
    try testing.expect(std.mem.indexOf(u8, got, "diff --git a/src/main.zig") != null);
    try testing.expect(std.mem.indexOf(u8, got, "@@ -10,7 +10,7 @@") != null);
    // Bookkeeping is gone.
    try testing.expect(std.mem.indexOf(u8, got, "index 1a2b3c4") == null);
    try testing.expect(std.mem.indexOf(u8, got, "+++ b/src/main.zig") == null);
    // One line of context either side of the change is kept as an anchor.
    try testing.expect(std.mem.indexOf(u8, got, "const c = 3;") != null);
    try testing.expect(std.mem.indexOf(u8, got, "const e = 6;") != null);
    // Far context is not.
    try testing.expect(std.mem.indexOf(u8, got, "const a = 1;") == null);
    try testing.expect(std.mem.indexOf(u8, got, "const g = 8;") == null);
    try testing.expect(got.len < diff_fixture.len);
}

test "S8.3 git.diff: marker counts what was dropped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const got = (try diff(arena, diff_fixture)).?;
    // 4 far-context lines (a, b, f, g) and 4 metadata lines (index, ---, +++).
    try testing.expect(std.mem.indexOf(u8, got, "dropped 4 context lines") != null);
    try testing.expect(std.mem.indexOf(u8, got, "3 metadata lines") != null);
}

test "S8.3 git.diff: error output passes through untouched" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const errored = "fatal: not a git repository (or any of the parent directories): .git\n" ++
        "@@ this looks like a diff but the command failed @@\n" ++ ("pad line\n" ** 10);
    try testing.expect(try diff(arena, errored) == null);
}

test "S8.3 git.diff: small and structured output pass through" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expect(try diff(arena, "@@ -1 +1 @@\n-a\n+b\n") == null); // < 80 bytes
    const as_json = "{\"diff\":\"@@ -1 +1 @@\",\"pad\":\"" ++ "x" ** 80 ++ "\"}";
    try testing.expect(try diff(arena, as_json) == null);
}

test "S8.3 git.diff: non-diff output selects nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expect(try diff(arena, "just some prose\n" ** 12) == null);
}

const log_fixture =
    \\commit 3ddba50c1f2e3a4b5c6d7e8f9a0b1c2d3e4f5a6b
    \\Author: Someone <someone@example.com>
    \\Date:   Wed Aug 5 12:00:00 2026 +0000
    \\
    \\    docs(roadmap): draft M8
    \\
    \\    A longer body paragraph that the model rarely needs.
    \\
    \\commit 3b2b3a7d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b
    \\Author: Someone <someone@example.com>
    \\Date:   Wed Aug 5 11:00:00 2026 +0000
    \\
    \\    feat(worker/turn): seam context
    \\
;

test "S8.3 git.log: keeps sha + subject, drops author/date/body" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const got = (try log(arena, log_fixture)).?;
    try testing.expect(std.mem.indexOf(u8, got, "3ddba50c docs(roadmap): draft M8") != null);
    try testing.expect(std.mem.indexOf(u8, got, "3b2b3a7d feat(worker/turn): seam context") != null);
    try testing.expect(std.mem.indexOf(u8, got, "Author:") == null);
    try testing.expect(std.mem.indexOf(u8, got, "Date:") == null);
    try testing.expect(std.mem.indexOf(u8, got, "longer body paragraph") == null);
    try testing.expect(got.len < log_fixture.len);
}

test "S8.3 git.log: --oneline output is already minimal, passes through" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const oneline = "3ddba50 docs(roadmap): draft M8\n" ** 6;
    try testing.expect(try log(arena, oneline) == null);
}

const status_fixture =
    \\On branch master
    \\Your branch is up to date with 'origin/master'.
    \\
    \\Changes not staged for commit:
    \\  (use "git add <file>..." to update what will be committed)
    \\  (use "git restore <file>..." to discard changes in working directory)
    \\  modified:   src/worker/trim.zig
    \\  modified:   ROADMAP.md
    \\
    \\no changes added to commit (use "git add" and/or "git commit -a")
    \\
;

test "S8.3 git.status: keeps branch and paths, drops hint prose" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const got = (try status(arena, status_fixture)).?;
    try testing.expect(std.mem.indexOf(u8, got, "On branch master") != null);
    try testing.expect(std.mem.indexOf(u8, got, "src/worker/trim.zig") != null);
    try testing.expect(std.mem.indexOf(u8, got, "ROADMAP.md") != null);
    try testing.expect(std.mem.indexOf(u8, got, "(use \"git add") == null);
    try testing.expect(std.mem.indexOf(u8, got, "no changes added") == null);
    try testing.expect(got.len < status_fixture.len);
}

test "S8.3 git: no leaks over repeated filtering" {
    for (0..50) |_| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        _ = try diff(arena, diff_fixture);
        _ = try log(arena, log_fixture);
        _ = try status(arena, status_fixture);
    }
}
