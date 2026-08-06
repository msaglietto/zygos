//! Directory-listing filter (S8.3, docs/specs/filter.md).
//!
//! `ls -la` spends most of its bytes on permission bits, owner, group, size
//! and timestamp — none of which the agent asked for. It asked *what is in
//! this directory*. ztk's lesson here is the one worth repeating: compress
//! the metadata, never the names. A listing filter that hides paths has
//! destroyed the reason the command was run.

const std = @import("std");
const guard = @import("guard.zig");

/// Cap on names kept before eliding the tail; a 4000-entry `find` is not
/// something the model can act on in one go, but the first slice plus an
/// honest count is.
const max_names: usize = 200;

pub fn run(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}!?[]const u8 {
    if (guard.shouldSkipOrErrored(text)) return null;

    var out: std.ArrayList(u8) = .empty;
    var kept: usize = 0;
    var elided: usize = 0;
    var stripped: usize = 0;
    var it = guard.lines(text);
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0) continue;
        // `ls -l` header.
        if (std.mem.startsWith(u8, t, "total ")) {
            stripped += 1;
            continue;
        }
        if (kept >= max_names) {
            elided += 1;
            continue;
        }
        const name = if (longFormName(t)) |n| blk: {
            stripped += 1;
            break :blk n;
        } else t;
        try out.appendSlice(arena, name);
        try out.append(arena, '\n');
        kept += 1;
    }
    if (stripped == 0 and elided == 0) return null;

    if (elided > 0) {
        try out.appendSlice(arena, try guard.marker(
            arena,
            "listing: {d} more entries not shown ({d} total)",
            .{ elided, kept + elided },
        ));
    } else {
        try out.appendSlice(arena, try guard.marker(
            arena,
            "listing: {d} entries, metadata columns dropped",
            .{kept},
        ));
    }
    try out.append(arena, '\n');
    return guard.keepIfSmaller(text, out.items);
}

/// Recognize an `ls -l` row and return just the name column. Conservative:
/// anything that does not match the shape is returned as-is, unmodified.
///
///   -rw-r--r--  1 user  staff   1234 Aug  5 12:00 name.zig
///   drwxr-xr-x  4 user  staff    128 Aug  5 12:00 subdir
fn longFormName(t: []const u8) ?[]const u8 {
    if (t.len < 11) return null;
    switch (t[0]) {
        '-', 'd', 'l', 'c', 'b', 'p', 's' => {},
        else => return null,
    }
    for (t[1..10]) |c| switch (c) {
        'r', 'w', 'x', 's', 'S', 't', 'T', '-' => {},
        else => return null,
    };
    // Columns: perms, links, owner, group, size, month, day, time, name.
    var it = std.mem.tokenizeAny(u8, t, " \t");
    var cols: usize = 0;
    while (it.next()) |_| {
        cols += 1;
        if (cols == 8) break;
    }
    if (cols < 8) return null;
    const rest = std.mem.trim(u8, it.rest(), " \t");
    return if (rest.len == 0) null else rest;
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

const ls_fixture =
    \\total 96
    \\drwxr-xr-x  12 msaglietto  staff    384 Aug  5 12:00 .
    \\drwxr-xr-x   8 msaglietto  staff    256 Aug  1 09:10 ..
    \\-rw-r--r--   1 msaglietto  staff   1024 Aug  5 12:00 actor.zig
    \\-rw-r--r--   1 msaglietto  staff   2048 Aug  5 12:00 catalog.zig
    \\-rw-r--r--   1 msaglietto  staff   4096 Aug  5 12:00 protocol.zig
    \\drwxr-xr-x   3 msaglietto  staff     96 Aug  5 12:00 subdir
    \\
;

test "S8.3 listing: names survive, metadata columns do not" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const got = (try run(arena, ls_fixture)).?;
    // Every name is still there — the whole point of the command.
    try testing.expect(std.mem.indexOf(u8, got, "actor.zig") != null);
    try testing.expect(std.mem.indexOf(u8, got, "catalog.zig") != null);
    try testing.expect(std.mem.indexOf(u8, got, "protocol.zig") != null);
    try testing.expect(std.mem.indexOf(u8, got, "subdir") != null);
    // Metadata is gone.
    try testing.expect(std.mem.indexOf(u8, got, "drwxr-xr-x") == null);
    try testing.expect(std.mem.indexOf(u8, got, "msaglietto") == null);
    try testing.expect(std.mem.indexOf(u8, got, "total 96") == null);
    try testing.expect(std.mem.indexOf(u8, got, "Aug  5") == null);
    try testing.expect(got.len < ls_fixture.len / 2);
}

test "S8.3 listing: plain find output has nothing to strip" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const find_out = "src/kernel/actor.zig\nsrc/kernel/catalog.zig\nsrc/worker/turn.zig\n" ++
        "src/worker/trim.zig\nsrc/net/ws.zig\n";
    try testing.expect(try run(arena, find_out) == null);
}

test "S8.3 listing: huge listing keeps a bounded head and counts the rest" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var buf: std.ArrayList(u8) = .empty;
    for (0..500) |i| {
        const line = try std.fmt.allocPrint(arena, "src/generated/file_{d}.zig\n", .{i});
        try buf.appendSlice(arena, line);
    }
    const got = (try run(arena, buf.items)).?;
    try testing.expect(std.mem.indexOf(u8, got, "file_0.zig") != null);
    try testing.expect(std.mem.indexOf(u8, got, "file_199.zig") != null);
    try testing.expect(std.mem.indexOf(u8, got, "file_400.zig") == null);
    try testing.expect(std.mem.indexOf(u8, got, "300 more entries not shown (500 total)") != null);
}

test "S8.3 listing: error output passes through untouched" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const errored = "ls: error: cannot access 'nope'\n" ++
        "total 8\n-rw-r--r--  1 u  g  1 Aug  5 12:00 a\n" ++ ("pad-line-here\n" ** 8);
    try testing.expect(try run(arena, errored) == null);
}

test "S8.3 listing: no leaks over repeated filtering" {
    for (0..50) |_| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        _ = try run(arena, ls_fixture);
    }
}
