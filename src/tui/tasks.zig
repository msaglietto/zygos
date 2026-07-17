//! Live current-task display, fed by the executor's task_start/task_done
//! trace events. The running task is the one bright long-lived band line;
//! on task_done it collapses to a dim ✓ line in scrollback and the next
//! task_start repopulates the band with a fresh timer — that hand-off is
//! the visible "move to the next task" moment.

const std = @import("std");
const theme = @import("theme.zig");
const palette = @import("palette.zig");
const entries = @import("entries.zig");
const previewLen = @import("fmt.zig").previewLen;

/// The task the executor is on right now. `desc` is owned by the model's
/// gpa; the band borrows it under the model mutex.
pub const Current = struct {
    index: i64,
    total: i64,
    desc: []u8,
    started_ms: i64,
};

/// "┃ ⠹ task 2/6 — implement the lexer" — the highlighted band line.
pub fn bandLine(
    arena: std.mem.Allocator,
    cur: Current,
    now_ms: i64,
) error{OutOfMemory}![]u8 {
    var r_buf: [24]u8 = undefined;
    var b_buf: [24]u8 = undefined;
    return std.fmt.allocPrint(arena, "{s}{s}{s} {s} {s}task {d}/{d}{s} — {s}{s}{s}", .{
        theme.fg(&r_buf, palette.border), entries.heavy_rail, theme.reset,
        theme.spinnerFrame(now_ms),       theme.bold,         cur.index,
        cur.total,                        theme.reset,        theme.fg(&b_buf, palette.bright),
        cur.desc,                         theme.reset,
    });
}

/// "  ✓ task 2/6 implement the lexer · 1m20s" — scrollback collapse.
/// Planner descs run long; the line clips at the tool-preview cap so the
/// hand-off stays one row, not a wrapped dim paragraph.
pub fn doneLine(
    arena: std.mem.Allocator,
    cur: Current,
    elapsed_txt: []const u8,
) error{OutOfMemory}![]u8 {
    var color: [24]u8 = undefined;
    const cut = previewLen(cur.desc);
    return std.fmt.allocPrint(arena, "  {s}✓{s} {s}task {d}/{d} {s}{s} · {s}{s}", .{
        theme.fg(&color, theme.Color.ok), theme.reset,
        theme.dim,                        cur.index,
        cur.total,                        cur.desc[0..cut],
        if (cut < cur.desc.len) "…" else "",
        elapsed_txt,                      theme.reset,
    });
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "band line carries rail, spinner, index and desc" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var desc = "implement the lexer".*;
    const line = try bandLine(arena_state.allocator(), .{
        .index = 2,
        .total = 6,
        .desc = &desc,
        .started_ms = 0,
    }, 0);
    try testing.expect(std.mem.indexOf(u8, line, entries.heavy_rail) != null);
    try testing.expect(std.mem.indexOf(u8, line, "task 2/6") != null);
    try testing.expect(std.mem.indexOf(u8, line, "implement the lexer") != null);
    try testing.expect(std.mem.indexOf(u8, line, theme.spinnerFrame(0)) != null);
}

test "done line clips a long task desc to the preview cap" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var desc = ("Create `wordfreq` as a POSIX-compliant shell script that reads stdin, " ++
        "lowercases via `tr A-Z a-z`, strips punctuation and counts frequencies").*;
    const line = try doneLine(arena_state.allocator(), .{
        .index = 1,
        .total = 2,
        .desc = &desc,
        .started_ms = 0,
    }, "23s");
    try testing.expect(std.mem.indexOf(u8, line, "…") != null);
    try testing.expect(std.mem.indexOf(u8, line, "counts frequencies") == null);
    try testing.expect(std.mem.indexOf(u8, line, "· 23s") != null);
}

test "done line collapses dim with the ok marker and duration" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var desc = "implement the lexer".*;
    const line = try doneLine(arena_state.allocator(), .{
        .index = 2,
        .total = 6,
        .desc = &desc,
        .started_ms = 0,
    }, "1m20s");
    try testing.expect(std.mem.indexOf(u8, line, "✓") != null);
    try testing.expect(std.mem.indexOf(u8, line, "task 2/6 implement the lexer · 1m20s") != null);
    try testing.expect(std.mem.indexOf(u8, line, entries.heavy_rail) == null);
}
