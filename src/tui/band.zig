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
const entries = @import("entries.zig");
const scrub = @import("scrub.zig");
const tasks_mod = @import("tasks.zig");
const appendTail = @import("fmt.zig").appendTail;
const tailLines = @import("fmt.zig").tailLines;
const durFmt = @import("fmt.zig").durFmt;
const padBetween = @import("fmt.zig").padBetween;

/// Streamed-text tail lines shown live in the bottom band.
const live_tail_lines: usize = 8;
/// Thinking tail lines shown while the model reasons.
const thinking_tail_lines: usize = 4;
/// Live tool box body rows (high-water padded up to this cap).
const tool_box_max_rows: usize = 5;

/// What the mission is doing right now, in display-priority order. The
/// model derives this on every mutation (touchPhase) so the phase timer
/// resets exactly when the label class changes.
pub const Activity = enum { approval, tool, thinking, streaming, idle };

/// Read-only snapshot of the model state the band renders from. Slices
/// borrow the model's storage — valid only while the model mutex is held.
/// `live_tool_high` points back into the model: the box's high-water body
/// height is the one piece of state that advances during a render.
pub const BandView = struct {
    started_ms: i64,
    activity: Activity,
    phase_started_ms: i64,
    role_started_ms: ?i64,
    mission_state: ?[]const u8,
    /// Pipeline cursor: the step id, its 1-based position, and the pipeline
    /// length (0 = unknown, e.g. attached mid-run). Null at gating/done.
    mission_step: ?[]const u8 = null,
    mission_step_pos: i64 = 0,
    mission_steps_total: i64 = 0,
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
    /// M6 intervention: open steer input text (null = closed) + pause state.
    steer_input: ?[]const u8 = null,
    paused: bool = false,
    current_task: ?tasks_mod.Current,
    tools: []const chatlog.ToolView,
    thinking: []const u8,
    thinking_started_ms: ?i64,
    live: []const u8,
    live_tool_name: ?[]const u8,
    live_tool_args: []const u8,
    live_tool_high: *usize,
    stream_bytes: usize,
};

/// "running · executor (2/4)": the mission state, then the step at the
/// cursor with its 1-based position (and the pipeline length when known).
/// States with no step (gating, done, failed-before-start) render alone.
pub fn missionLabel(arena: std.mem.Allocator, view: BandView) error{OutOfMemory}![]const u8 {
    const state = view.mission_state orelse return "starting";
    const step = view.mission_step orelse return state;
    if (view.mission_steps_total > 0) {
        return std.fmt.allocPrint(arena, "{s} · {s} ({d}/{d})", .{ state, step, view.mission_step_pos, view.mission_steps_total });
    }
    return std.fmt.allocPrint(arena, "{s} · {s} ({d})", .{ state, step, view.mission_step_pos });
}

/// Compose the band rows into `arena`. `cols` shapes the tool box borders;
/// the renderer still truncates every row defensively.
pub fn build(
    view: BandView,
    arena: std.mem.Allocator,
    cols: usize,
    now_ms: i64,
) error{OutOfMemory}![]const []const u8 {
    var bottom: std.ArrayList([]const u8) = .empty;
    var color: [24]u8 = undefined;
    var e_buf: [32]u8 = undefined;

    // Header: identity + mission state + tasks + total elapsed. The spinner
    // lives on the status line, where the activity is.
    try bottom.append(arena, try std.fmt.allocPrint(arena, "{s}zygos{s} · {s} · tasks {d}/{d} · {s}", .{
        theme.fg(&color, theme.Color.accent),
        theme.reset,
        try missionLabel(arena, view),
        view.tasks_done,
        view.tasks,
        theme.elapsed(&e_buf, view.started_ms, now_ms),
    }));

    // The executor's live task — the one bright long-lived band line.
    if (view.current_task) |cur| {
        try bottom.append(arena, try tasks_mod.bandLine(arena, cur, now_ms));
    }

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

    // Dispatched tool calls awaiting results: one heavy-rail line each.
    for (view.tools) |t| {
        try bottom.append(arena, try entries.toolLine(arena, t.name, t.input));
    }

    try renderLiveToolEntry(view, arena, &bottom, cols);

    // Thinking entry: thin-rail header + italic tail while the model reasons.
    if (view.thinking.len > 0) {
        var t_buf: [32]u8 = undefined;
        const started = view.thinking_started_ms orelse now_ms;
        try bottom.append(arena, try entries.thinkingHeader(arena, durFmt(&t_buf, now_ms - started)));
        var storage: [16][]const u8 = undefined;
        for (tailLines(view.thinking, &storage, thinking_tail_lines)) |line| {
            if (line.len == 0) continue;
            const clipped = try width.truncateToWidth(arena, line, cols -| 4);
            try bottom.append(arena, try entries.thinkingBody(arena, clipped));
        }
    }

    // Live answer text: last N lines, full color — this is the payload.
    try appendTail(arena, &bottom, view.live, live_tail_lines, "");

    // Approval ask — keys first, then the whole summary wrapped over as many
    // rows as it needs. Rows clip right, so a single-row summary would lose
    // the end of the command, the clip marker and the reason while the
    // operator can still press y. The summary is model-authored (a bash
    // command): no escape may restyle the gate.
    if (view.approval) |ask| try appendApproval(arena, &bottom, ask, cols);

    // Steer input line (M6 intervention): the operator's message composing
    // live; sent on Enter, discarded on Esc.
    if (view.steer_input) |text| {
        try bottom.append(arena, try std.fmt.allocPrint(arena, "{s}⚑ steer: {s}▏{s} {s}[Enter send · Esc cancel]{s}", .{
            theme.fg(&color, theme.Color.accent), text,        theme.reset,
            theme.dim,                            theme.reset,
        }));
    }

    try bottom.append(arena, try statusLine(view, arena, cols, now_ms));

    return bottom.items;
}

/// Visible text of the approval keys, and the cells the keys take in front
/// of an inline summary (one separating space included).
const approval_keys = "  [y/N] approve?";
const approval_indent = "    ";
/// An inline first row needs at least this many cells left for the summary;
/// narrower terminals put the keys on a row of their own.
const approval_min_inline_cells: usize = 8;

/// The approval ask: the keys first (red, bold), then the scrubbed summary,
/// word-wrapped on display width (never splitting a UTF-8 sequence; a token
/// wider than the row is hard-split). A newline in the summary starts a new
/// row. A short ask shares the keys' row.
fn appendApproval(
    arena: std.mem.Allocator,
    bottom: *std.ArrayList([]const u8),
    ask: []const u8,
    cols: usize,
) error{OutOfMemory}!void {
    var color: [24]u8 = undefined;
    const keys_sgr = try std.fmt.allocPrint(arena, "{s}{s}{s}{s}", .{
        theme.bold, theme.fg(&color, theme.Color.err), approval_keys, theme.reset,
    });
    const safe_ask = try scrub.scrub(arena, ask);
    const inline_keys = cols >= approval_keys.len + 1 + approval_min_inline_cells;

    var first = true;
    if (!inline_keys) {
        try bottom.append(arena, keys_sgr);
        first = false;
    }
    var segments = std.mem.splitScalar(u8, safe_ask, '\n');
    while (segments.next()) |segment| {
        const logical = if (first)
            try std.fmt.allocPrint(arena, "{s} {s}", .{ approval_keys, segment })
        else
            try std.fmt.allocPrint(arena, "{s}{s}", .{ approval_indent, segment });
        for (try width.wrapToWidth(arena, logical, cols, approval_indent)) |row| {
            // The first row begins with the keys: width >= keys + 1 + 8 means
            // the wrapper cannot have broken inside them.
            if (first and std.mem.startsWith(u8, row, approval_keys)) {
                first = false;
                try bottom.append(arena, try std.fmt.allocPrint(arena, "{s}{s}{s}{s}", .{
                    keys_sgr, theme.dim, row[approval_keys.len..], theme.reset,
                }));
            } else {
                first = false;
                try bottom.append(arena, try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ theme.dim, row, theme.reset }));
            }
        }
    }
}

/// "⠹ Responding… · 4.2s        1m13s · 12.4k↑ 3.1k↓ · ⇣NB" — spinner +
/// activity label + phase timer left; turn timer + token flow right. ⇣N
/// counts observed delta bytes: 0 while tokens climb means the delta path
/// is broken, not the providers. Only the left label truncates.
fn statusLine(
    view: BandView,
    arena: std.mem.Allocator,
    cols: usize,
    now_ms: i64,
) error{OutOfMemory}![]const u8 {
    var color: [24]u8 = undefined;
    var p_buf: [32]u8 = undefined;
    const label: []const u8 = if (view.paused) "Paused (r resumes)" else switch (view.activity) {
        .approval => "Waiting for approval",
        .tool => blk: {
            const name = view.live_tool_name orelse
                (if (view.tools.len > 0) view.tools[view.tools.len - 1].name else "tool");
            break :blk try std.fmt.allocPrint(arena, "Run {s}", .{name});
        },
        .thinking => "Thinking…",
        .streaming => "Responding…",
        .idle => try missionLabel(arena, view),
    };
    const label_sgr: []const u8 = switch (view.activity) {
        .approval => theme.fg(&color, theme.Color.err),
        .tool => theme.fg(&color, theme.Color.ok),
        .thinking, .streaming => theme.fg(&color, theme.Color.accent),
        .idle => theme.fg(&color, theme.Color.muted),
    };
    var left: []const u8 = try std.fmt.allocPrint(arena, "{s} {s}{s}{s} {s}· {s}{s}", .{
        theme.spinnerFrame(now_ms), label_sgr,
        label,                      theme.reset,
        theme.dim,                  durFmt(&p_buf, now_ms - view.phase_started_ms),
        theme.reset,
    });

    var t_buf: [32]u8 = undefined;
    var in_buf: [32]u8 = undefined;
    var out_buf: [32]u8 = undefined;
    var s_buf: [32]u8 = undefined;
    const turn: []const u8 = if (view.role_started_ms) |started|
        try std.fmt.allocPrint(arena, "{s} · ", .{durFmt(&t_buf, now_ms - started)})
    else
        "";
    const right = try std.fmt.allocPrint(arena, "{s}{s}{s}↑ {s}↓ · ⇣{s}B{s}", .{
        theme.dim,
        turn,
        theme.tokens(&in_buf, view.tokens_in),
        theme.tokens(&out_buf, view.tokens_out),
        theme.tokens(&s_buf, @intCast(view.stream_bytes)),
        theme.reset,
    });

    // Only the left label gives way when the row is tight.
    const rw = width.visibleWidth(right);
    if (width.visibleWidth(left) + rw + 1 > cols) {
        left = try width.truncateToWidth(arena, left, cols -| (rw + 1));
    }
    return padBetween(arena, left, right, cols);
}

/// Heavy-rail entry for a tool call still composing its arguments — the
/// headline field (command/path/content…) extracted from the partial JSON
/// streams into the body. Body height is high-water padded so the entry
/// never shrinks mid-stream (zot's liveBodyHigh).
fn renderLiveToolEntry(
    view: BandView,
    arena: std.mem.Allocator,
    bottom: *std.ArrayList([]const u8),
    cols: usize,
) error{OutOfMemory}!void {
    const name = view.live_tool_name orelse return;
    try bottom.append(arena, try entries.toolHeader(arena, name));

    const body = try partialjson.extractDisplayField(arena, view.live_tool_args) orelse
        view.live_tool_args;
    // Model-authored arguments (partial JSON fragments): scrub before split
    // so a poisoned fragment cannot ride a line into the terminal.
    const safe_body = try scrub.scrub(arena, body);
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, safe_body, "\n"), '\n');
    while (it.next()) |line| try lines.append(arena, line);
    const start = lines.items.len -| tool_box_max_rows;
    var shown = lines.items[start..];
    if (shown.len == 1 and shown[0].len == 0) shown = shown[0..0];
    view.live_tool_high.* = @min(@max(view.live_tool_high.*, shown.len), tool_box_max_rows);

    var row: usize = 0;
    while (row < view.live_tool_high.*) : (row += 1) {
        const text = if (row < shown.len) shown[row] else "";
        const clipped = try width.truncateToWidth(arena, text, cols -| 4);
        try bottom.append(arena, try entries.toolBody(arena, clipped));
    }
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

fn emptyView(high: *usize) BandView {
    return .{
        .started_ms = 0,
        .activity = .idle,
        .phase_started_ms = 0,
        .role_started_ms = null,
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
        .current_task = null,
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
    try testing.expect(std.mem.indexOf(u8, rows[rows.len - 1], "⇣") != null);
}

test "status line labels follow the activity class with its color" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var high: usize = 0;
    var view = emptyView(&high);

    view.activity = .streaming;
    var row = try statusLine(view, arena, 80, 0);
    try testing.expect(std.mem.indexOf(u8, row, "Responding…") != null);

    view.activity = .approval;
    row = try statusLine(view, arena, 80, 0);
    try testing.expect(std.mem.indexOf(u8, row, "Waiting for approval") != null);

    var name = "bash".*;
    var input = "{}".*;
    view.activity = .tool;
    view.tools = &.{.{ .name = &name, .input = &input }};
    row = try statusLine(view, arena, 80, 0);
    try testing.expect(std.mem.indexOf(u8, row, "Run bash") != null);

    view.activity = .idle;
    view.mission_state = "running";
    view.mission_step = "verifier";
    view.mission_step_pos = 3;
    view.mission_steps_total = 4;
    row = try statusLine(view, arena, 80, 0);
    try testing.expect(std.mem.indexOf(u8, row, "running · verifier (3/4)") != null);
}

test "mission label: state, then step with position, total when known" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var high: usize = 0;
    var view = emptyView(&high);
    try testing.expectEqualStrings("starting", try missionLabel(arena, view));
    view.mission_state = "gating";
    try testing.expectEqualStrings("gating", try missionLabel(arena, view));
    view.mission_state = "running";
    view.mission_step = "executor";
    view.mission_step_pos = 2;
    try testing.expectEqualStrings("running · executor (2)", try missionLabel(arena, view));
    view.mission_steps_total = 4;
    try testing.expectEqualStrings("running · executor (2/4)", try missionLabel(arena, view));
}

test "status line pads to the full width with the turn timer right" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var high: usize = 0;
    var view = emptyView(&high);
    view.activity = .streaming;
    view.phase_started_ms = 0;
    view.role_started_ms = 0;
    const row = try statusLine(view, arena_state.allocator(), 60, 73_000);
    try testing.expectEqual(@as(usize, 60), width.visibleWidth(row));
    try testing.expect(std.mem.indexOf(u8, row, "1m13s") != null);
}

test "only the left label truncates when the row is tight" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var high: usize = 0;
    var view = emptyView(&high);
    var name = "a_very_long_mcp_tool_name_that_never_ends".*;
    var input = "{}".*;
    view.activity = .tool;
    view.tools = &.{.{ .name = &name, .input = &input }};
    const row = try statusLine(view, arena_state.allocator(), 40, 0);
    try testing.expect(width.visibleWidth(row) <= 40);
    // The right side survives intact.
    try testing.expect(std.mem.indexOf(u8, row, "⇣") != null);
}

test "live tool entry high-water mark never shrinks mid-stream" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var high: usize = 0;
    var view = emptyView(&high);
    view.live_tool_name = "bash";
    view.live_tool_args = "{\"command\":\"one\\ntwo\\nthree\"}";
    _ = try build(view, arena_state.allocator(), 80, 0);
    try testing.expectEqual(@as(usize, 3), high);
    // A shorter body keeps the padded height: header + 3 rail rows.
    view.live_tool_args = "{\"command\":\"one\"}";
    const rows = try build(view, arena_state.allocator(), 80, 0);
    try testing.expectEqual(@as(usize, 3), high);
    var rail_rows: usize = 0;
    for (rows) |r| {
        if (std.mem.indexOf(u8, r, entries.heavy_rail) != null) rail_rows += 1;
    }
    try testing.expectEqual(@as(usize, 4), rail_rows);
}

// -- Approval ask: the whole summary stays visible (wrapped, never clipped) ----

/// The band rows strictly between the header and the status line, with SGR
/// and CSI sequences removed.
fn plainAskRows(arena: std.mem.Allocator, rows: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (rows[1 .. rows.len - 1]) |row| {
        var buf: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < row.len) {
            if (row[i] == 0x1b) {
                i += 1;
                if (i < row.len and row[i] == '[') i += 1;
                while (i < row.len and !(row[i] >= 0x40 and row[i] <= 0x7e)) i += 1;
                i += 1;
                continue;
            }
            try buf.append(arena, row[i]);
            i += 1;
        }
        try out.append(arena, buf.items);
    }
    return out.items;
}

/// Every non-space byte of `rows`, in order: what an operator can read.
fn visibleLetters(arena: std.mem.Allocator, rows: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (rows) |row| {
        for (row) |b| if (b != ' ') try out.append(arena, b);
    }
    return out.items;
}

const long_ask = "bash [step executor] {\"command\":\"cd build && make clean && " ++
    "make -j8 all && ./run-the-whole-suite --verbose --retries 3 && " ++
    "tar czf /tmp/out.tgz ./dist ./build ./docs ./src ./test ./eval && " ++
    "rm -rf ~/x\"}…[612 bytes total] (policy ask: rule: bash)";

fn expectAskFullyVisible(cols: usize) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var high: usize = 0;
    var view = emptyView(&high);
    view.approval = long_ask;
    const rows = try build(view, arena, cols, 0);
    const ask_rows = try plainAskRows(arena, rows);

    // The keys lead; the summary follows on the same row or the rows below.
    try testing.expect(ask_rows.len >= 2);
    try testing.expect(std.mem.indexOf(u8, ask_rows[0], "[y/N] approve?") != null);
    // The keys alone are 16 cells; a terminal narrower than that clips them
    // (the frame does), every other row still fits.
    for (ask_rows, 0..) |r, i| {
        if (i == 0 and cols < approval_keys.len) continue;
        try testing.expect(width.visibleWidth(r) <= cols);
    }
    // Nothing is lost: the tail of the command, the clip marker and the
    // reason are all on screen, and so is every other byte, in order.
    const letters = try visibleLetters(arena, ask_rows);
    const want = try visibleLetters(arena, &.{ "[y/N]approve?", long_ask });
    try testing.expectEqualStrings(want, letters);
    for ([_][]const u8{ "rm -rf ~/x", "…[612 bytes total]", "(policy ask: rule: bash)" }) |needle| {
        const squashed = try visibleLetters(arena, &.{needle});
        try testing.expect(std.mem.indexOf(u8, letters, squashed) != null);
    }
}

test "approval ask wraps across rows at 80 columns: tail, marker and reason stay visible" {
    try expectAskFullyVisible(80);
}

test "approval ask wraps across rows at a narrow width" {
    try expectAskFullyVisible(40);
    try expectAskFullyVisible(24);
}

test "approval ask keeps the keys visible when the terminal is tiny" {
    try expectAskFullyVisible(12);
}

test "approval ask hard-splits an unbroken token and never splits a UTF-8 sequence" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var high: usize = 0;
    var view = emptyView(&high);
    // No spaces at all, wide runes included: 2 cells each.
    view.approval = "bash:" ++ "日本語のコマンド" ** 6 ++ "{\"command\":\"" ++ "x" ** 90 ++ "\"}";
    const rows = try build(view, arena, 30, 0);
    const ask_rows = try plainAskRows(arena, rows);
    for (ask_rows) |r| {
        try testing.expect(width.visibleWidth(r) <= 30);
        try testing.expect(std.unicode.utf8ValidateSlice(r));
    }
    const letters = try visibleLetters(arena, ask_rows);
    try testing.expect(std.mem.endsWith(u8, letters, "\"}"));
    try testing.expect(std.mem.indexOf(u8, letters, "日本語のコマンド") != null);
}

test "a short approval ask stays on one row after the keys" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var high: usize = 0;
    var view = emptyView(&high);
    view.approval = "bash: rm -rf ./build";
    const rows = try build(view, arena, 80, 0);
    const ask_rows = try plainAskRows(arena, rows);
    try testing.expectEqual(@as(usize, 1), ask_rows.len);
    const keys_at = std.mem.indexOf(u8, ask_rows[0], "[y/N] approve?").?;
    const ask_at = std.mem.indexOf(u8, ask_rows[0], "bash: rm -rf ./build").?;
    try testing.expect(keys_at < ask_at);
}

test "an approval ask cannot restyle the band or break rows with escapes and newlines" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var high: usize = 0;
    var view = emptyView(&high);
    view.approval = "bash \x1b[2J\x1b]52;c;ZXZpbA==\x07 line one\nline two";
    const rows = try build(view, arena, 80, 0);
    for (rows) |r| {
        try testing.expect(std.mem.indexOf(u8, r, "\x1b[2J") == null);
        try testing.expect(std.mem.indexOf(u8, r, "\x1b]52") == null);
        try testing.expect(std.mem.indexOfScalar(u8, r, '\n') == null);
    }
    const ask_rows = try plainAskRows(arena, rows);
    try testing.expect(ask_rows.len >= 2); // the newline starts a new row
    const letters = try visibleLetters(arena, ask_rows);
    try testing.expect(std.mem.indexOf(u8, letters, "lineone") != null);
    try testing.expect(std.mem.indexOf(u8, letters, "linetwo") != null);
}
