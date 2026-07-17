//! Markdown-lite for promoted answer text: enough styling that model output
//! reads as prose (headers, bold, inline code, fenced blocks) without a real
//! renderer. Line-oriented so it composes with the model's chat history —
//! one input line becomes at most one output line; fence markers vanish.
//! Unmatched markers pass through literally: never eat user bytes.

const std = @import("std");
const theme = @import("theme.zig");

/// Per-flush state: fenced code spans multiple lines, so the caller keeps
/// one Styler alive for the whole block of lines it is promoting.
pub const Styler = struct {
    in_fence: bool = false,

    /// Style one line for the terminal (arena-owned result), or null when
    /// the line is markup that should not render (``` fence markers).
    pub fn line(self: *Styler, arena: std.mem.Allocator, raw: []const u8) error{OutOfMemory}!?[]const u8 {
        const trimmed = std.mem.trimStart(u8, raw, " ");
        if (std.mem.startsWith(u8, trimmed, "```")) {
            self.in_fence = !self.in_fence;
            return null;
        }
        if (self.in_fence) {
            // Code is payload: gutter it, never reinterpret its bytes.
            return try std.fmt.allocPrint(arena, "{s}│{s} {s}", .{ theme.dim, theme.reset, raw });
        }

        var color: [16]u8 = undefined;
        if (headerText(trimmed)) |title| {
            return try std.fmt.allocPrint(arena, "{s}{s}{s}{s}", .{
                theme.bold, theme.fg(&color, theme.Color.accent), title, theme.reset,
            });
        }

        var out: std.ArrayList(u8) = .empty;
        const indent = raw.len - trimmed.len;
        try out.appendSlice(arena, raw[0..indent]);
        var rest = trimmed;
        if (std.mem.startsWith(u8, rest, "- ") or std.mem.startsWith(u8, rest, "* ")) {
            try out.appendSlice(arena, "• ");
            rest = rest[2..];
        }
        try inlineSpans(arena, &out, rest);
        return out.items;
    }
};

fn headerText(s: []const u8) ?[]const u8 {
    var hashes: usize = 0;
    while (hashes < s.len and s[hashes] == '#') hashes += 1;
    if (hashes == 0 or hashes > 4 or hashes >= s.len or s[hashes] != ' ') return null;
    return std.mem.trimStart(u8, s[hashes..], " ");
}

/// `code` spans → amber, **bold** spans → bold. A marker without its mate
/// is literal text; backtick spans win over asterisks (code may contain **).
fn inlineSpans(arena: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) error{OutOfMemory}!void {
    var color: [16]u8 = undefined;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '`') {
            if (std.mem.indexOfScalarPos(u8, s, i + 1, '`')) |close| {
                try out.appendSlice(arena, theme.fg(&color, theme.Color.tool));
                try out.appendSlice(arena, s[i + 1 .. close]);
                try out.appendSlice(arena, theme.reset);
                i = close + 1;
                continue;
            }
        }
        if (i + 1 < s.len and s[i] == '*' and s[i + 1] == '*' and i + 2 < s.len and s[i + 2] != ' ') {
            if (std.mem.indexOfPos(u8, s, i + 2, "**")) |close| {
                try out.appendSlice(arena, theme.bold);
                try out.appendSlice(arena, s[i + 2 .. close]);
                try out.appendSlice(arena, theme.reset);
                i = close + 2;
                continue;
            }
        }
        try out.append(arena, s[i]);
        i += 1;
    }
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

fn styleOne(styler: *Styler, arena: std.mem.Allocator, raw: []const u8) !?[]const u8 {
    return styler.line(arena, raw);
}

test "plain text passes through unchanged" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var s = Styler{};
    const got = (try styleOne(&s, arena_state.allocator(), "just a sentence.")).?;
    try testing.expectEqualStrings("just a sentence.", got);
}

test "headers drop the hashes and gain the accent color" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var s = Styler{};
    const got = (try styleOne(&s, arena_state.allocator(), "## What I did")).?;
    try testing.expect(std.mem.indexOf(u8, got, "##") == null);
    try testing.expect(std.mem.indexOf(u8, got, "What I did") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\x1b[38;5;75m") != null); // accent
    try testing.expect(std.mem.indexOf(u8, got, theme.bold) != null);
}

test "inline code loses the backticks and gains the tool color" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var s = Styler{};
    const got = (try styleOne(&s, arena_state.allocator(), "so `HEAD` still had it")).?;
    try testing.expect(std.mem.indexOf(u8, got, "`") == null);
    try testing.expect(std.mem.indexOf(u8, got, "\x1b[38;5;179mHEAD\x1b[0m") != null); // amber
}

test "bold spans lose the asterisks and gain bold" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var s = Styler{};
    const got = (try styleOne(&s, arena_state.allocator(), "existed only as **staged** work")).?;
    try testing.expect(std.mem.indexOf(u8, got, "**") == null);
    try testing.expect(std.mem.indexOf(u8, got, theme.bold ++ "staged" ++ theme.reset) != null);
}

test "unmatched markers pass through literally" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var s = Styler{};
    const a = (try styleOne(&s, arena_state.allocator(), "2 ** 3 is eight")).?;
    try testing.expectEqualStrings("2 ** 3 is eight", a);
    const b = (try styleOne(&s, arena_state.allocator(), "a `tick without close")).?;
    try testing.expectEqualStrings("a `tick without close", b);
}

test "fence markers vanish; fenced lines get a gutter and stay literal" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var s = Styler{};
    try testing.expectEqual(@as(?[]const u8, null), try styleOne(&s, arena_state.allocator(), "```zig"));
    const body = (try styleOne(&s, arena_state.allocator(), "const x = **not bold**;")).?;
    try testing.expect(std.mem.indexOf(u8, body, "**not bold**") != null); // no inline styling in code
    try testing.expect(std.mem.indexOf(u8, body, "│") != null); // gutter
    try testing.expectEqual(@as(?[]const u8, null), try styleOne(&s, arena_state.allocator(), "```"));
    const after = (try styleOne(&s, arena_state.allocator(), "back to prose")).?;
    try testing.expectEqualStrings("back to prose", after);
}

test "list markers render as bullets" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var s = Styler{};
    const got = (try styleOne(&s, arena_state.allocator(), "- first thing")).?;
    try testing.expect(std.mem.indexOf(u8, got, "• first thing") != null);
    try testing.expect(std.mem.indexOf(u8, got, "- first") == null);
}
