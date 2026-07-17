//! Pure text helpers for the mission TUI — no model state, no terminal.
//! Everything here allocates into the caller's arena (or a caller buffer)
//! and never retains references to its inputs.

const std = @import("std");
const theme = @import("theme.zig");

/// Cap for tool input previews in the step list.
pub const input_preview_bytes: usize = 72;

/// Last `max` non-empty-tail lines of `text` into the band, prefixed and
/// wrapped in `sgr` (empty = terminal default).
pub fn appendTail(
    arena: std.mem.Allocator,
    bottom: *std.ArrayList([]const u8),
    text: []const u8,
    max: usize,
    comptime sgr: []const u8,
) error{OutOfMemory}!void {
    if (text.len == 0) return;
    var tail = std.mem.splitBackwardsScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    var collected: [16][]const u8 = undefined;
    var n: usize = 0;
    while (n < @min(max, collected.len)) : (n += 1) {
        collected[n] = tail.next() orelse break;
    }
    while (n > 0) {
        n -= 1;
        if (collected[n].len == 0) continue;
        try bottom.append(arena, try std.fmt.allocPrint(arena, "  " ++ sgr ++ "{s}" ++
            (if (sgr.len > 0) theme.reset else ""), .{collected[n]}));
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

test "appendTail on empty text appends nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var rows: std.ArrayList([]const u8) = .empty;
    try appendTail(arena_state.allocator(), &rows, "", 4, "");
    try testing.expectEqual(@as(usize, 0), rows.items.len);
}
