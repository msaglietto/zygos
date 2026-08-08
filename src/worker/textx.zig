//! Canonical line/ASCII text helpers shared across worker/ (the text twin
//! of jsonx.zig and fsx.zig). One definition each for line iteration and
//! case-insensitive matching — previously copied into brief.zig and the
//! tessera markdown modules.

const std = @import("std");

/// Next line of `text` starting at `pos`, CR/LF tolerant; advances `pos`
/// past the terminator. Null at end of input.
pub fn nextLine(text: []const u8, pos: *usize) ?[]const u8 {
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

pub fn isBlank(line: []const u8) bool {
    return std.mem.trim(u8, line, " \t").len == 0;
}

pub fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (hay.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

pub fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (std.ascii.toLower(ac) != std.ascii.toLower(bc)) return false;
    }
    return true;
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "nextLine: LF and CRLF lines, trailing line without newline, then null" {
    const text = "one\r\ntwo\nlast";
    var pos: usize = 0;
    try testing.expectEqualStrings("one", nextLine(text, &pos).?);
    try testing.expectEqualStrings("two", nextLine(text, &pos).?);
    try testing.expectEqualStrings("last", nextLine(text, &pos).?);
    try testing.expectEqual(@as(?[]const u8, null), nextLine(text, &pos));
}

test "isBlank: spaces and tabs only" {
    try testing.expect(isBlank(""));
    try testing.expect(isBlank(" \t "));
    try testing.expect(!isBlank(" x "));
}

test "containsIgnoreCase and eqlIgnoreCase: ASCII case folded, empty needle matches" {
    try testing.expect(eqlIgnoreCase("Leaving Behind", "leaving behind"));
    try testing.expect(!eqlIgnoreCase("abc", "abd"));
    try testing.expect(containsIgnoreCase("### 🔮 Leaving behind", "leaving behind"));
    try testing.expect(containsIgnoreCase("x", ""));
    try testing.expect(!containsIgnoreCase("short", "longer needle"));
}
