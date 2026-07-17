//! Bottom-band composition for the mission TUI — the repainting rows under
//! the scrollback: header spinner line, step line, dispatched tools, live
//! streaming tool box, thinking block, live answer tail, approval ask,
//! status line. Pure over a read-only snapshot of the model; the model holds
//! its mutex across build(), so the borrowed slices cannot move.

const std = @import("std");
const theme = @import("theme.zig");
const width = @import("width.zig");
const partialjson = @import("partialjson.zig");
const chatlog = @import("chatlog.zig");
const appendTail = @import("fmt.zig").appendTail;
const dashes = @import("fmt.zig").dashes;
const spaces = @import("fmt.zig").spaces;

/// Streamed-text tail lines shown live in the bottom band.
const live_tail_lines: usize = 8;
/// Thinking tail lines shown while the model reasons.
const thinking_tail_lines: usize = 4;
/// Live tool box body rows (high-water padded up to this cap).
const tool_box_max_rows: usize = 5;

/// Read-only snapshot of the model state the band renders from. Slices
/// borrow the model's storage — valid only while the model mutex is held.
/// `live_tool_high` points back into the model: the box's high-water body
/// height is the one piece of state that advances during a render.
pub const BandView = struct {
    started_ms: i64,
    mission_state: ?[]const u8,
    tasks_done: i64,
    tasks: i64,
    role: ?[]const u8,
    role_turn: i64,
    step: i64,
    step_model: ?[]const u8,
    attempt: i64,
    tokens_in: i64,
    tokens_out: i64,
    approval: ?[]const u8,
    tools: []const chatlog.ToolView,
    thinking: []const u8,
    thinking_started_ms: ?i64,
    live: []const u8,
    live_tool_name: ?[]const u8,
    live_tool_args: []const u8,
    live_tool_high: *usize,
    stream_bytes: usize,
};

/// Compose the band rows into `arena`. `cols` shapes the tool box borders;
/// the renderer still truncates every row defensively.
pub fn build(
    view: BandView,
    arena: std.mem.Allocator,
    cols: usize,
    now_ms: i64,
) error{OutOfMemory}![]const []const u8 {
    var bottom: std.ArrayList([]const u8) = .empty;
    var color: [16]u8 = undefined;
    var e_buf: [32]u8 = undefined;

    // Header: spinner + mission state + tasks + elapsed.
    try bottom.append(arena, try std.fmt.allocPrint(arena, "{s}{s} zygos{s} · {s} · tasks {d}/{d} · {s}", .{
        theme.fg(&color, theme.Color.accent),
        theme.spinnerFrame(now_ms),
        theme.reset,
        if (view.mission_state) |s| s else "starting",
        view.tasks_done,
        view.tasks,
        theme.elapsed(&e_buf, view.started_ms, now_ms),
    }));

    // Current role/step.
    if (view.role) |role| {
        if (view.step > 0) {
            if (view.attempt > 0) {
                try bottom.append(arena, try std.fmt.allocPrint(arena, "  {s} · step {d} · {s} (attempt {d})", .{
                    role, view.step, view.step_model orelse "?", view.attempt,
                }));
            } else {
                try bottom.append(arena, try std.fmt.allocPrint(arena, "  {s} · step {d} · {s}", .{
                    role, view.step, view.step_model orelse "?",
                }));
            }
        } else {
            try bottom.append(arena, try std.fmt.allocPrint(arena, "  {s} · turn {d}", .{ role, view.role_turn }));
        }
    }

    // Dispatched tool calls awaiting results.
    for (view.tools) |t| {
        var tcolor: [16]u8 = undefined;
        try bottom.append(arena, try std.fmt.allocPrint(arena, "  {s} {s}{s}{s} {s}{s}{s}", .{
            theme.spinnerFrame(now_ms),
            theme.fg(&tcolor, theme.Color.tool),
            t.name,
            theme.reset,
            theme.dim,
            t.input,
            theme.reset,
        }));
    }

    try renderLiveToolBox(view, arena, &bottom, cols);

    // Thinking block: label + italic tail while the model reasons.
    if (view.thinking.len > 0) {
        var t_buf: [32]u8 = undefined;
        const started = view.thinking_started_ms orelse now_ms;
        try bottom.append(arena, try std.fmt.allocPrint(arena, "  {s}✳ thinking… {s}{s}", .{
            theme.fg(&color, theme.Color.accent),
            theme.elapsed(&t_buf, started, now_ms),
            theme.reset,
        }));
        try appendTail(arena, &bottom, view.thinking, thinking_tail_lines, theme.dim ++ theme.italic);
    }

    // Live answer text: last N lines, full color — this is the payload.
    try appendTail(arena, &bottom, view.live, live_tail_lines, "");

    // Approval ask — keys first: the summary can exceed the terminal
    // width and rows clip right, so a trailing hint would be the part
    // that vanishes (a gated mission then looks hung).
    if (view.approval) |ask| {
        try bottom.append(arena, try std.fmt.allocPrint(arena, "{s}{s}  [y/N] approve?{s} {s}{s}{s}", .{
            theme.bold, theme.fg(&color, theme.Color.err), theme.reset,
            theme.dim,  ask,                               theme.reset,
        }));
    }

    // Status line. `stream` counts observed delta bytes — 0B while
    // tokens climb means the delta path is broken, not the providers.
    var in_buf: [32]u8 = undefined;
    var out_buf: [32]u8 = undefined;
    var s_buf: [32]u8 = undefined;
    try bottom.append(arena, try std.fmt.allocPrint(arena, "  {s}{s}↑ {s}↓ · stream {s}B{s}", .{
        theme.dim,
        theme.tokens(&in_buf, view.tokens_in),
        theme.tokens(&out_buf, view.tokens_out),
        theme.tokens(&s_buf, @intCast(view.stream_bytes)),
        theme.reset,
    }));

    return bottom.items;
}

/// Bordered live box for a tool call still composing its arguments —
/// the headline field (command/path/content…) extracted from the
/// partial JSON streams into the body. Body height is high-water padded
/// so the box never shrinks mid-stream (zot's liveBodyHigh).
fn renderLiveToolBox(
    view: BandView,
    arena: std.mem.Allocator,
    bottom: *std.ArrayList([]const u8),
    cols: usize,
) error{OutOfMemory}!void {
    const name = view.live_tool_name orelse return;
    const inner = @min(cols -| 6, 74); // box body cells between the │ rails
    if (inner < 8) return;

    var tcolor: [16]u8 = undefined;
    const rail = try dashes(arena, inner -| (width.visibleWidth(name) + 3));
    try bottom.append(arena, try std.fmt.allocPrint(arena, "  ╭─ {s}{s}{s} {s}╮", .{
        theme.fg(&tcolor, theme.Color.tool), name, theme.reset, rail,
    }));

    const body = try partialjson.extractDisplayField(arena, view.live_tool_args) orelse
        view.live_tool_args;
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, body, "\n"), '\n');
    while (it.next()) |line| try lines.append(arena, line);
    const start = lines.items.len -| tool_box_max_rows;
    var shown = lines.items[start..];
    if (shown.len == 1 and shown[0].len == 0) shown = shown[0..0];
    view.live_tool_high.* = @min(@max(view.live_tool_high.*, shown.len), tool_box_max_rows);

    var row: usize = 0;
    while (row < view.live_tool_high.*) : (row += 1) {
        const text = if (row < shown.len) shown[row] else "";
        const clipped = try width.truncateToWidth(arena, text, inner);
        const pad = try spaces(arena, inner -| width.visibleWidth(clipped));
        try bottom.append(arena, try std.fmt.allocPrint(arena, "  │{s}{s}{s}{s}│", .{
            theme.dim, clipped, theme.reset, pad,
        }));
    }
    try bottom.append(arena, try std.fmt.allocPrint(arena, "  ╰{s}╯", .{try dashes(arena, inner)}));
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

fn emptyView(high: *usize) BandView {
    return .{
        .started_ms = 0,
        .mission_state = null,
        .tasks_done = 0,
        .tasks = 0,
        .role = null,
        .role_turn = 0,
        .step = 0,
        .step_model = null,
        .attempt = 0,
        .tokens_in = 0,
        .tokens_out = 0,
        .approval = null,
        .tools = &.{},
        .thinking = "",
        .thinking_started_ms = null,
        .live = "",
        .live_tool_name = null,
        .live_tool_args = "",
        .live_tool_high = high,
        .stream_bytes = 0,
    };
}

test "band always carries the header and status rows" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var high: usize = 0;
    const rows = try build(emptyView(&high), arena_state.allocator(), 80, 0);
    try testing.expect(rows.len >= 2);
    try testing.expect(std.mem.indexOf(u8, rows[0], "zygos") != null);
    try testing.expect(std.mem.indexOf(u8, rows[rows.len - 1], "stream") != null);
}

test "live tool box high-water mark never shrinks mid-stream" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var high: usize = 0;
    var view = emptyView(&high);
    view.live_tool_name = "bash";
    view.live_tool_args = "{\"command\":\"one\\ntwo\\nthree\"}";
    _ = try build(view, arena_state.allocator(), 80, 0);
    try testing.expectEqual(@as(usize, 3), high);
    // A shorter body keeps the padded height.
    view.live_tool_args = "{\"command\":\"one\"}";
    const rows = try build(view, arena_state.allocator(), 80, 0);
    try testing.expectEqual(@as(usize, 3), high);
    var box_rows: usize = 0;
    for (rows) |r| {
        if (std.mem.indexOf(u8, r, "│") != null) box_rows += 1;
    }
    try testing.expectEqual(@as(usize, 3), box_rows);
}
