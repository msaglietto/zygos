//! Entry lifecycle grammar for the mission TUI (grok-informed): work in
//! flight renders in the bottom band under a left rail — heavy `┃` for
//! tools, thin `❙` for thinking — and collapses to one dim scrollback line
//! when it finishes. This module owns the line formats; band.zig places
//! running entries, chatlog.zig/model.zig commit collapsed ones.

const std = @import("std");
const theme = @import("theme.zig");
const palette = @import("palette.zig");

pub const heavy_rail = "┃";
pub const thin_rail = "❙";

fn rail(buf: []u8, comptime glyph: []const u8) []const u8 {
    var color: [24]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}{s}{s}", .{
        theme.fg(&color, palette.border), glyph, theme.reset,
    }) catch unreachable;
}

/// "┃ ◆ name" — header of a tool entry still composing its arguments.
pub fn toolHeader(arena: std.mem.Allocator, name: []const u8) error{OutOfMemory}![]u8 {
    var r_buf: [32]u8 = undefined;
    var color: [24]u8 = undefined;
    return std.fmt.allocPrint(arena, "{s} ◆ {s}{s}{s}", .{
        rail(&r_buf, heavy_rail), theme.fg(&color, theme.Color.tool), name, theme.reset,
    });
}

/// "┃ ◆ name input" — a dispatched tool call awaiting its result.
pub fn toolLine(arena: std.mem.Allocator, name: []const u8, input: []const u8) error{OutOfMemory}![]u8 {
    var r_buf: [32]u8 = undefined;
    var color: [24]u8 = undefined;
    return std.fmt.allocPrint(arena, "{s} ◆ {s}{s}{s} {s}{s}{s}", .{
        rail(&r_buf, heavy_rail), theme.fg(&color, theme.Color.tool), name,        theme.reset,
        theme.dim,                input,                              theme.reset,
    });
}

/// "┃   text" — dim body row under a running tool (streaming arguments).
/// Empty text renders the bare rail: high-water padding rows.
pub fn toolBody(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]u8 {
    var r_buf: [32]u8 = undefined;
    if (text.len == 0) return std.fmt.allocPrint(arena, "{s}", .{rail(&r_buf, heavy_rail)});
    return std.fmt.allocPrint(arena, "{s}   {s}{s}{s}", .{
        rail(&r_buf, heavy_rail), theme.dim, text, theme.reset,
    });
}

/// "❙ Thinking… 12s" — live reasoning header.
pub fn thinkingHeader(arena: std.mem.Allocator, elapsed_txt: []const u8) error{OutOfMemory}![]u8 {
    var r_buf: [32]u8 = undefined;
    return std.fmt.allocPrint(arena, "{s} {s}Thinking…{s} {s}{s}{s}", .{
        rail(&r_buf, thin_rail), theme.bold,  theme.reset,
        theme.dim,               elapsed_txt, theme.reset,
    });
}

/// "❙   text" — dim italic body row under the thinking header.
pub fn thinkingBody(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]u8 {
    var r_buf: [32]u8 = undefined;
    return std.fmt.allocPrint(arena, "{s}   {s}{s}{s}{s}", .{
        rail(&r_buf, thin_rail), theme.dim, theme.italic, text, theme.reset,
    });
}

/// One-line scrollback collapse of a finished tool call:
/// "  ◆ name input · 5.1kB · 0.3s" dim, "✗" err-styled on error.
pub fn collapsedTool(
    arena: std.mem.Allocator,
    name: []const u8,
    input: []const u8,
    bytes_txt: []const u8,
    elapsed_txt: []const u8,
    is_err: bool,
) error{OutOfMemory}![]u8 {
    var color: [24]u8 = undefined;
    if (is_err) {
        return std.fmt.allocPrint(arena, "  {s}✗ {s}{s} {s}{s} · {s}B · {s}{s}", .{
            theme.fg(&color, theme.Color.err), name,      theme.reset, theme.dim,
            input,                             bytes_txt, elapsed_txt, theme.reset,
        });
    }
    return std.fmt.allocPrint(arena, "  {s}◆ {s} {s} · {s}B · {s}{s}", .{
        theme.dim, name, input, bytes_txt, elapsed_txt, theme.reset,
    });
}

/// "  ◆ Thought for 12s" — scrollback collapse of a reasoning phase.
pub fn collapsedThought(arena: std.mem.Allocator, elapsed_txt: []const u8) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(arena, "  {s}◆ Thought for {s}{s}", .{
        theme.dim, elapsed_txt, theme.reset,
    });
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "tool header and body carry the heavy rail" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const header = try toolHeader(arena, "bash");
    try testing.expect(std.mem.indexOf(u8, header, heavy_rail) != null);
    try testing.expect(std.mem.indexOf(u8, header, "◆ ") != null);
    try testing.expect(std.mem.indexOf(u8, header, "bash") != null);
    const body = try toolBody(arena, "cat src/ker");
    try testing.expect(std.mem.indexOf(u8, body, heavy_rail) != null);
    try testing.expect(std.mem.indexOf(u8, body, "cat src/ker") != null);
}

test "empty tool body row is the bare rail (high-water padding)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const row = try toolBody(arena_state.allocator(), "");
    try testing.expect(std.mem.indexOf(u8, row, heavy_rail) != null);
    try testing.expect(std.mem.indexOf(u8, row, theme.dim) == null);
}

test "thinking rows carry the thin rail and italic body" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const header = try thinkingHeader(arena, "12s");
    try testing.expect(std.mem.indexOf(u8, header, thin_rail) != null);
    try testing.expect(std.mem.indexOf(u8, header, "Thinking…") != null);
    try testing.expect(std.mem.indexOf(u8, header, "12s") != null);
    const body = try thinkingBody(arena, "weighing options");
    try testing.expect(std.mem.indexOf(u8, body, thin_rail) != null);
    try testing.expect(std.mem.indexOf(u8, body, theme.italic) != null);
}

test "collapsed tool line is one dim row with size and duration" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const line = try collapsedTool(arena_state.allocator(), "bash", "ls", "5.1k", "0s", false);
    try testing.expect(std.mem.indexOf(u8, line, "◆ bash ls · 5.1kB · 0s") != null);
    try testing.expect(std.mem.startsWith(u8, line, "  " ++ theme.dim));
    try testing.expect(std.mem.indexOf(u8, line, heavy_rail) == null); // rail gone on commit
}

test "collapsed tool line styles errors with the err marker" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const line = try collapsedTool(arena_state.allocator(), "web_search", "{}", "12", "1s", true);
    try testing.expect(std.mem.indexOf(u8, line, "✗ web_search") != null);
    try testing.expect(std.mem.indexOf(u8, line, "◆") == null);
}

test "collapsed thought line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const line = try collapsedThought(arena_state.allocator(), "12s");
    try testing.expect(std.mem.indexOf(u8, line, "◆ Thought for 12s") != null);
}
