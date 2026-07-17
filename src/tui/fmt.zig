//! Pure text helpers for the mission TUI — no model state, no terminal.
//! Everything here allocates into the caller's arena (or a caller buffer)
//! and never retains references to its inputs.

const std = @import("std");
const theme = @import("theme.zig");
const width = @import("width.zig");

/// Cap for tool input previews in the step list.
pub const input_preview_bytes: usize = 72;

/// Last `max` lines of `text` (ignoring a trailing newline), oldest first,
/// into `storage`. Returned slices borrow `text`.
pub fn tailLines(text: []const u8, storage: *[16][]const u8, max: usize) []const []const u8 {
    if (text.len == 0) return storage[0..0];
    var tail = std.mem.splitBackwardsScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    var n: usize = 0;
    while (n < @min(max, storage.len)) : (n += 1) {
        storage[storage.len - 1 - n] = tail.next() orelse break;
    }
    return storage[storage.len - n ..];
}

/// Last `max` non-empty-tail lines of `text` into the band, prefixed and
/// wrapped in `sgr` (empty = terminal default).
pub fn appendTail(
    arena: std.mem.Allocator,
    bottom: *std.ArrayList([]const u8),
    text: []const u8,
    max: usize,
    comptime sgr: []const u8,
) error{OutOfMemory}!void {
    var storage: [16][]const u8 = undefined;
    for (tailLines(text, &storage, max)) |line| {
        if (line.len == 0) continue;
        try bottom.append(arena, try std.fmt.allocPrint(arena, "  " ++ sgr ++ "{s}" ++
            (if (sgr.len > 0) theme.reset else ""), .{line}));
    }
}

pub fn dashes(arena: std.mem.Allocator, n: usize) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < n) : (i += 1) try out.appendSlice(arena, "─");
    return out.items;
}

pub fn spaces(arena: std.mem.Allocator, n: usize) error{OutOfMemory}![]const u8 {
    const buf = try arena.alloc(u8, n);
    @memset(buf, ' ');
    return buf;
}

/// Duration into caller's buffer, grok rules: sub-10s keeps tenths
/// ("0.3s", "5.2s"), then "32s", "1m20s", "1h02m". Negative clamps to 0.
pub fn durFmt(buf: []u8, dur_ms: i64) []const u8 {
    const ms = @max(dur_ms, 0);
    if (ms < 10_000) {
        return std.fmt.bufPrint(buf, "{d}.{d}s", .{
            @divTrunc(ms, 1000), @mod(@divTrunc(ms, 100), 10),
        }) catch unreachable;
    }
    const s = @divTrunc(ms, 1000);
    if (s < 60) return std.fmt.bufPrint(buf, "{d}s", .{s}) catch unreachable;
    if (s < 3600) {
        return std.fmt.bufPrint(buf, "{d}m{d:0>2}s", .{ @divTrunc(s, 60), @mod(s, 60) }) catch unreachable;
    }
    return std.fmt.bufPrint(buf, "{d}h{d:0>2}m", .{
        @divTrunc(s, 3600), @mod(@divTrunc(s, 60), 60),
    }) catch unreachable;
}

/// One row with `left` flush-left and `right` flush-right at `cols` visible
/// cells (SGR-aware). Too narrow: a single space separates them.
pub fn padBetween(
    arena: std.mem.Allocator,
    left: []const u8,
    right: []const u8,
    cols: usize,
) error{OutOfMemory}![]u8 {
    const used = width.visibleWidth(left) + width.visibleWidth(right);
    const gap = if (cols > used) cols - used else 1;
    const out = try arena.alloc(u8, left.len + gap + right.len);
    @memcpy(out[0..left.len], left);
    @memset(out[left.len .. left.len + gap], ' ');
    @memcpy(out[left.len + gap ..], right);
    return out;
}

/// Cut an input preview on a UTF-8 boundary, first line only.
pub fn previewLen(s: []const u8) usize {
    var end: usize = @min(s.len, input_preview_bytes);
    if (std.mem.indexOfScalar(u8, s[0..end], '\n')) |nl| end = nl;
    while (end > 0 and (s[end -| 1] & 0xC0) == 0x80) end -= 1;
    if (end > 0 and end < s.len and (s[end] & 0xC0) == 0x80) {
        while (end > 0 and (s[end - 1] & 0x80) != 0) end -= 1;
    }
    return end;
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "tool input preview clips on the first line and a UTF-8 boundary" {
    try testing.expectEqual(@as(usize, 5), previewLen("hello"));
    try testing.expectEqual(@as(usize, 3), previewLen("abc\ndef"));
    const long = "x" ** 100;
    try testing.expectEqual(input_preview_bytes, previewLen(long));
    // 72 bytes would split the 3-byte '世' starting at byte 71.
    const cjk = ("y" ** 71) ++ "世界";
    const cut = previewLen(cjk);
    try testing.expect(cut <= 71);
    try testing.expect(std.unicode.utf8ValidateSlice(cjk[0..cut]));
}

test "dashes and spaces emit exactly n cells" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("───", try dashes(arena, 3));
    try testing.expectEqualStrings("", try dashes(arena, 0));
    try testing.expectEqualStrings("   ", try spaces(arena, 3));
    try testing.expectEqualStrings("", try spaces(arena, 0));
}

test "appendTail keeps the last N non-empty lines in order" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var rows: std.ArrayList([]const u8) = .empty;
    try appendTail(arena, &rows, "one\ntwo\nthree\nfour\n", 2, "");
    try testing.expectEqual(@as(usize, 2), rows.items.len);
    try testing.expectEqualStrings("  three", rows.items[0]);
    try testing.expectEqualStrings("  four", rows.items[1]);
}

test "appendTail wraps lines in the sgr prefix and reset" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var rows: std.ArrayList([]const u8) = .empty;
    try appendTail(arena, &rows, "only", 4, theme.dim);
    try testing.expectEqual(@as(usize, 1), rows.items.len);
    try testing.expectEqualStrings("  " ++ theme.dim ++ "only" ++ theme.reset, rows.items[0]);
}

test "durFmt follows the grok duration rules" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("0.3s", durFmt(&buf, 300));
    try testing.expectEqualStrings("5.2s", durFmt(&buf, 5_250));
    try testing.expectEqualStrings("32s", durFmt(&buf, 32_400));
    try testing.expectEqualStrings("1m20s", durFmt(&buf, 80_000));
    try testing.expectEqualStrings("1m05s", durFmt(&buf, 65_000));
    try testing.expectEqualStrings("1h02m", durFmt(&buf, 3_720_000));
    try testing.expectEqualStrings("0.0s", durFmt(&buf, -5));
}

test "padBetween right-aligns by visible width, SGR-aware" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const row = try padBetween(arena, "left", "right", 20);
    try testing.expectEqualStrings("left           right", row);
    try testing.expectEqual(@as(usize, 20), width.visibleWidth(row));
    // SGR bytes cost no cells.
    const styled = try padBetween(arena, theme.dim ++ "ab" ++ theme.reset, "cd", 8);
    try testing.expectEqual(@as(usize, 8), width.visibleWidth(styled));
    // Too narrow: one space, never a panic or truncation.
    const tight = try padBetween(arena, "abcdef", "ghijkl", 4);
    try testing.expectEqualStrings("abcdef ghijkl", tight);
}

test "tailLines returns the last N lines oldest first" {
    var storage: [16][]const u8 = undefined;
    const lines = tailLines("one\ntwo\nthree\n", &storage, 2);
    try testing.expectEqual(@as(usize, 2), lines.len);
    try testing.expectEqualStrings("two", lines[0]);
    try testing.expectEqualStrings("three", lines[1]);
    try testing.expectEqual(@as(usize, 0), tailLines("", &storage, 4).len);
}

test "appendTail on empty text appends nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var rows: std.ArrayList([]const u8) = .empty;
    try appendTail(arena_state.allocator(), &rows, "", 4, "");
    try testing.expectEqual(@as(usize, 0), rows.items.len);
}
