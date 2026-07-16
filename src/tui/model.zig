//! View model for the mission progress TUI. Fed by trace-event JSON lines
//! (worker/trace.zig sink), streamed text deltas (worker/turn.zig observer),
//! and captured log lines — all arriving on foreign worker threads, so every
//! entry point takes the model mutex. Ownership rule: the byte slices passed
//! to onEvent/onDelta/onLog are valid only for the call — the model copies
//! everything it keeps with its gpa. render() copies the frame into the
//! caller's arena under the lock, so returned lines never dangle.
//!
//! Malformed event lines are ignored, never fatal: the model is a view,
//! losing one line must not wedge the display (fail-open, like the trace).

const std = @import("std");
const json = std.json;
const sync = @import("../kernel/sync.zig");
const theme = @import("theme.zig");
const width = @import("width.zig");
const partialjson = @import("partialjson.zig");

/// Streamed-text tail lines shown live in the bottom band.
const live_tail_lines: usize = 8;
/// Thinking tail lines shown while the model reasons.
const thinking_tail_lines: usize = 4;
/// Live tool box body rows (high-water padded up to this cap).
const tool_box_max_rows: usize = 5;
/// Cap for tool input previews in the step list.
const input_preview_bytes: usize = 72;

const italic = "\x1b[3m";

fn defaultNow() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

pub const Frame = struct {
    chat: []const []const u8,
    bottom: []const []const u8,
};

const ToolView = struct {
    name: []u8,
    input: []u8,
};

pub const Model = struct {
    gpa: std.mem.Allocator,
    mutex: sync.Mutex = .{},
    /// Set on every mutation; the render loop waits on it.
    dirty: sync.ResetEvent = .{},

    started_ms: i64,
    mission_state: ?[]u8 = null,
    tasks_done: i64 = 0,
    tasks: i64 = 0,
    role: ?[]u8 = null,
    role_turn: i64 = 0,
    step: i64 = 0,
    step_model: ?[]u8 = null,
    attempt: i64 = 0,
    tokens_in: i64 = 0,
    tokens_out: i64 = 0,
    approval: ?[]u8 = null,

    /// Completed history — flows into terminal scrollback, only grows.
    chat: std.ArrayList([]u8) = .empty,
    /// Open tool calls of the current step, oldest first.
    tools: std.ArrayList(ToolView) = .empty,
    /// Current step's streamed assistant text.
    live: std.ArrayList(u8) = .empty,
    /// Live reasoning stream (thinking_delta / reasoning_content) — shown
    /// while it runs, collapsed to a "thought for Ns" line at the next
    /// text/tool/step boundary.
    thinking: std.ArrayList(u8) = .empty,
    thinking_started_ms: ?i64 = null,
    /// Tool call still streaming its arguments (pre-dispatch): live box.
    live_tool_name: ?[]u8 = null,
    live_tool_args: std.ArrayList(u8) = .empty,
    live_tool_high: usize = 0,
    /// Injectable clock (tests); render timestamps still come from callers.
    now_fn: *const fn () i64 = &defaultNow,

    pub fn init(gpa: std.mem.Allocator, started_ms: i64) Model {
        return .{ .gpa = gpa, .started_ms = started_ms };
    }

    pub fn deinit(self: *Model) void {
        for (self.chat.items) |l| self.gpa.free(l);
        self.chat.deinit(self.gpa);
        self.clearTools();
        self.tools.deinit(self.gpa);
        self.live.deinit(self.gpa);
        self.thinking.deinit(self.gpa);
        self.live_tool_args.deinit(self.gpa);
        if (self.live_tool_name) |n| self.gpa.free(n);
        if (self.mission_state) |s| self.gpa.free(s);
        if (self.role) |r| self.gpa.free(r);
        if (self.step_model) |m| self.gpa.free(m);
        if (self.approval) |a| self.gpa.free(a);
        self.dirty.deinit();
        self.mutex.deinit();
        self.* = undefined;
    }

    // -- ingestion (worker threads) ------------------------------------------

    /// trace.Sink adapter.
    pub fn sinkOnEvent(ctx: *anyopaque, line_json: []const u8) void {
        const self: *Model = @ptrCast(@alignCast(ctx));
        self.onEvent(line_json);
    }

    /// turn.DeltaObserver adapter.
    pub fn observerOnDelta(ctx: *anyopaque, turn_id: []const u8, bytes: []const u8) void {
        _ = turn_id;
        const self: *Model = @ptrCast(@alignCast(ctx));
        self.onDelta(bytes);
    }

    /// logbridge.Hook adapter.
    pub fn hookOnLine(ctx: *anyopaque, line: []const u8) void {
        const self: *Model = @ptrCast(@alignCast(ctx));
        self.onLog(line);
    }

    pub fn onEvent(self: *Model, line_json: []const u8) void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const v = json.parseFromSliceLeaky(json.Value, arena, line_json, .{}) catch return;
        if (v != .object) return;
        const obj = v.object;
        const ev = str(obj, "event") orelse return;

        self.mutex.lock();
        defer self.mutex.unlock();
        defer self.dirty.set();
        self.applyEvent(arena, ev, obj) catch {}; // OOM: drop the line, keep the view alive

    }

    pub fn onDelta(self: *Model, bytes: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        // The answer starting is the end of the thinking phase.
        self.flushThinking() catch {};
        self.live.appendSlice(self.gpa, bytes) catch {};
        self.dirty.set();
    }

    /// Reasoning stream (worker/stream_tap.zig `.thinking`).
    pub fn onThinking(self: *Model, bytes: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.thinking_started_ms == null) self.thinking_started_ms = self.now_fn();
        self.thinking.appendSlice(self.gpa, bytes) catch {};
        self.dirty.set();
    }

    /// A tool call opened on the stream (`.tool_name`): start a live box.
    pub fn onToolName(self: *Model, name: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.flushThinking() catch {};
        const copy = self.gpa.dupe(u8, name) catch return;
        if (self.live_tool_name) |old| self.gpa.free(old);
        self.live_tool_name = copy;
        self.live_tool_args.clearRetainingCapacity();
        self.live_tool_high = 0;
        self.dirty.set();
    }

    /// Streaming tool-arguments fragment (`.tool_args`).
    pub fn onToolArgs(self: *Model, fragment: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.live_tool_args.appendSlice(self.gpa, fragment) catch {};
        self.dirty.set();
    }

    /// Captured std.log line — shown as a dim footnote so evidence is never
    /// hidden while the TUI owns the terminal.
    pub fn onLog(self: *Model, line: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.appendChatFmt("{s}{s}{s}", .{ theme.dim, line, theme.reset }) catch {};
        self.dirty.set();
    }

    /// Approval ask currently awaiting a keypress (null clears the band).
    pub fn setPendingApproval(self: *Model, summary: ?[]const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.approval) |a| {
            self.gpa.free(a);
            self.approval = null;
        }
        if (summary) |s| self.approval = self.gpa.dupe(u8, s) catch null;
        self.dirty.set();
    }

    fn applyEvent(self: *Model, arena: std.mem.Allocator, ev: []const u8, obj: json.ObjectMap) error{OutOfMemory}!void {
        _ = arena;
        if (std.mem.eql(u8, ev, "mission")) {
            const to = str(obj, "to") orelse "?";
            try self.replaceOwned(&self.mission_state, to);
            self.tasks_done = int(obj, "tasks_done");
            self.tasks = int(obj, "tasks");
            var color: [16]u8 = undefined;
            try self.appendChatFmt("{s}◆ mission {s} → {s}{s}", .{
                theme.fg(&color, theme.Color.accent), str(obj, "from") orelse "?", to, theme.reset,
            });
        } else if (std.mem.eql(u8, ev, "role_start")) {
            const role = str(obj, "role") orelse "?";
            try self.replaceOwned(&self.role, role);
            self.role_turn = int(obj, "role_turn");
            self.step = 0;
            var color: [16]u8 = undefined;
            try self.appendChatFmt("{s}▌ {s}{s} — turn {d}", .{
                theme.fg(&color, theme.Color.accent), role, theme.reset, self.role_turn,
            });
        } else if (std.mem.eql(u8, ev, "role_end")) {
            try self.flushThinking();
            try self.flushLive();
            self.clearLiveTool();
            try self.collapseOpenTools();
            const outcome = str(obj, "outcome") orelse "?";
            const failed = !std.mem.eql(u8, outcome, "ok");
            var color: [16]u8 = undefined;
            if (str(obj, "reason")) |reason| {
                try self.appendChatFmt("{s}▌ {s}: {s} — {s}{s}", .{
                    theme.fg(&color, if (failed) theme.Color.err else theme.Color.ok),
                    str(obj, "role") orelse "?",
                    outcome,
                    reason,
                    theme.reset,
                });
            } else {
                try self.appendChatFmt("{s}▌ {s}: {s}{s}", .{
                    theme.fg(&color, if (failed) theme.Color.err else theme.Color.ok),
                    str(obj, "role") orelse "?",
                    outcome,
                    theme.reset,
                });
            }
            if (self.role) |r| {
                self.gpa.free(r);
                self.role = null;
            }
        } else if (std.mem.eql(u8, ev, "step")) {
            try self.flushThinking();
            try self.flushLive();
            self.clearLiveTool();
            self.step = int(obj, "step");
            self.attempt = int(obj, "attempt");
            try self.replaceOwned(&self.step_model, str(obj, "model") orelse "?");
        } else if (std.mem.eql(u8, ev, "tool_call")) {
            // Dispatch: the streaming box (if any) hands over to the running
            // tool list fed by this event.
            self.clearLiveTool();
            const name = try self.gpa.dupe(u8, str(obj, "tool") orelse "?");
            errdefer self.gpa.free(name);
            const raw_input = str(obj, "input") orelse "";
            const preview = raw_input[0..previewLen(raw_input)];
            const input = try self.gpa.dupe(u8, preview);
            errdefer self.gpa.free(input);
            try self.tools.append(self.gpa, .{ .name = name, .input = input });
        } else if (std.mem.eql(u8, ev, "tool_result")) {
            const name = str(obj, "tool") orelse "?";
            const is_err = boolOf(obj, "is_error");
            var color: [16]u8 = undefined;
            var count: [32]u8 = undefined;
            try self.appendChatFmt("  {s}{s} {s}{s} · {s}B", .{
                theme.fg(&color, if (is_err) theme.Color.err else theme.Color.ok),
                if (is_err) "✗" else "✓",
                name,
                theme.reset,
                theme.tokens(&count, int(obj, "bytes")),
            });
            self.removeOldestTool(name);
        } else if (std.mem.eql(u8, ev, "usage")) {
            self.tokens_in += int(obj, "input_tokens");
            self.tokens_out += int(obj, "output_tokens");
        } else if (std.mem.eql(u8, ev, "turn_end")) {
            try self.flushThinking();
            try self.flushLive();
            self.clearLiveTool();
            try self.collapseOpenTools();
            self.step = 0;
            var buf: [64]u8 = undefined;
            const stop = str(obj, "stop") orelse "?";
            const suffix = if (str(obj, "error")) |e|
                std.fmt.bufPrint(&buf, " — {s}", .{e[0..@min(e.len, 40)]}) catch ""
            else
                "";
            try self.appendChatFmt("{s}  turn: {s} ({d} steps){s}{s}", .{
                theme.dim, stop, int(obj, "steps"), suffix, theme.reset,
            });
        }
        // Unknown kinds are ignored: the view must survive a newer emitter.
    }

    // -- rendering (render thread) -------------------------------------------

    /// Snapshot the frame into `arena`. Chat lines accumulate; bottom is the
    /// repainting band: header spinner line, step line, dispatched tools,
    /// live streaming tool box, thinking block, live answer text, approval
    /// ask, status line. `cols` shapes the tool box borders; the renderer
    /// still truncates every row defensively.
    pub fn render(self: *Model, arena: std.mem.Allocator, cols: usize, now_ms: i64) error{OutOfMemory}!Frame {
        self.mutex.lock();
        defer self.mutex.unlock();

        var chat = try arena.alloc([]const u8, self.chat.items.len);
        for (self.chat.items, 0..) |line, i| chat[i] = try arena.dupe(u8, line);

        var bottom: std.ArrayList([]const u8) = .empty;
        var color: [16]u8 = undefined;
        var e_buf: [32]u8 = undefined;

        // Header: spinner + mission state + tasks + elapsed.
        try bottom.append(arena, try std.fmt.allocPrint(arena, "{s}{s} zygos{s} · {s} · tasks {d}/{d} · {s}", .{
            theme.fg(&color, theme.Color.accent),
            theme.spinnerFrame(now_ms),
            theme.reset,
            if (self.mission_state) |s| s else "starting",
            self.tasks_done,
            self.tasks,
            theme.elapsed(&e_buf, self.started_ms, now_ms),
        }));

        // Current role/step.
        if (self.role) |role| {
            if (self.step > 0) {
                if (self.attempt > 0) {
                    try bottom.append(arena, try std.fmt.allocPrint(arena, "  {s} · step {d} · {s} (attempt {d})", .{
                        role, self.step, self.step_model orelse "?", self.attempt,
                    }));
                } else {
                    try bottom.append(arena, try std.fmt.allocPrint(arena, "  {s} · step {d} · {s}", .{
                        role, self.step, self.step_model orelse "?",
                    }));
                }
            } else {
                try bottom.append(arena, try std.fmt.allocPrint(arena, "  {s} · turn {d}", .{ role, self.role_turn }));
            }
        }

        // Dispatched tool calls awaiting results.
        for (self.tools.items) |t| {
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

        try self.renderLiveToolBox(arena, &bottom, cols);

        // Thinking block: label + italic tail while the model reasons.
        if (self.thinking.items.len > 0) {
            var t_buf: [32]u8 = undefined;
            const started = self.thinking_started_ms orelse now_ms;
            try bottom.append(arena, try std.fmt.allocPrint(arena, "  {s}✳ thinking… {s}{s}", .{
                theme.fg(&color, theme.Color.accent),
                theme.elapsed(&t_buf, started, now_ms),
                theme.reset,
            }));
            try appendTail(arena, &bottom, self.thinking.items, thinking_tail_lines, theme.dim ++ italic);
        }

        // Live answer text: last N lines, full color — this is the payload.
        try appendTail(arena, &bottom, self.live.items, live_tail_lines, "");

        // Approval ask.
        if (self.approval) |ask| {
            try bottom.append(arena, try std.fmt.allocPrint(arena, "{s}{s}  approve {s}? [y/N]{s}", .{
                theme.bold, theme.fg(&color, theme.Color.err), ask, theme.reset,
            }));
        }

        // Status line.
        var in_buf: [32]u8 = undefined;
        var out_buf: [32]u8 = undefined;
        try bottom.append(arena, try std.fmt.allocPrint(arena, "  {s}{s}↑ {s}↓{s}", .{
            theme.dim,
            theme.tokens(&in_buf, self.tokens_in),
            theme.tokens(&out_buf, self.tokens_out),
            theme.reset,
        }));

        return .{ .chat = chat, .bottom = bottom.items };
    }

    /// Bordered live box for a tool call still composing its arguments —
    /// the headline field (command/path/content…) extracted from the
    /// partial JSON streams into the body. Body height is high-water padded
    /// so the box never shrinks mid-stream (zot's liveBodyHigh).
    fn renderLiveToolBox(
        self: *Model,
        arena: std.mem.Allocator,
        bottom: *std.ArrayList([]const u8),
        cols: usize,
    ) error{OutOfMemory}!void {
        const name = self.live_tool_name orelse return;
        const inner = @min(cols -| 6, 74); // box body cells between the │ rails
        if (inner < 8) return;

        var tcolor: [16]u8 = undefined;
        const rail = try dashes(arena, inner -| (width.visibleWidth(name) + 3));
        try bottom.append(arena, try std.fmt.allocPrint(arena, "  ╭─ {s}{s}{s} {s}╮", .{
            theme.fg(&tcolor, theme.Color.tool), name, theme.reset, rail,
        }));

        const body = try partialjson.extractDisplayField(arena, self.live_tool_args.items) orelse
            self.live_tool_args.items;
        var lines: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, body, "\n"), '\n');
        while (it.next()) |line| try lines.append(arena, line);
        const start = lines.items.len -| tool_box_max_rows;
        var shown = lines.items[start..];
        if (shown.len == 1 and shown[0].len == 0) shown = shown[0..0];
        self.live_tool_high = @min(@max(self.live_tool_high, shown.len), tool_box_max_rows);

        var row: usize = 0;
        while (row < self.live_tool_high) : (row += 1) {
            const text = if (row < shown.len) shown[row] else "";
            const clipped = try width.truncateToWidth(arena, text, inner);
            const pad = try spaces(arena, inner -| width.visibleWidth(clipped));
            try bottom.append(arena, try std.fmt.allocPrint(arena, "  │{s}{s}{s}{s}│", .{
                theme.dim, clipped, theme.reset, pad,
            }));
        }
        try bottom.append(arena, try std.fmt.allocPrint(arena, "  ╰{s}╯", .{try dashes(arena, inner)}));
    }

    // -- internals (mutex held) ----------------------------------------------

    fn appendChatFmt(self: *Model, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
        const line = try std.fmt.allocPrint(self.gpa, fmt, args);
        errdefer self.gpa.free(line);
        try self.chat.append(self.gpa, line);
    }

    /// Collapse the reasoning phase into one history line, claude-code
    /// style: the content was visible live; scrollback keeps the duration.
    fn flushThinking(self: *Model) error{OutOfMemory}!void {
        if (self.thinking.items.len == 0) {
            self.thinking_started_ms = null;
            return;
        }
        var e_buf: [32]u8 = undefined;
        const started = self.thinking_started_ms orelse self.now_fn();
        try self.appendChatFmt("  {s}{s}✳ thought for {s}{s}", .{
            theme.dim, italic, theme.elapsed(&e_buf, started, self.now_fn()), theme.reset,
        });
        self.thinking.clearRetainingCapacity();
        self.thinking_started_ms = null;
    }

    fn clearLiveTool(self: *Model) void {
        if (self.live_tool_name) |n| {
            self.gpa.free(n);
            self.live_tool_name = null;
        }
        self.live_tool_args.clearRetainingCapacity();
        self.live_tool_high = 0;
    }

    /// Move the streamed text into chat history, one dim line per text line.
    fn flushLive(self: *Model) error{OutOfMemory}!void {
        if (self.live.items.len == 0) return;
        var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, self.live.items, "\n"), '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            try self.appendChatFmt("  {s}", .{line});
        }
        self.live.clearRetainingCapacity();
    }

    /// A step/turn boundary with tools still open means their results never
    /// arrived (abort, provider error). Collapse them as interrupted.
    fn collapseOpenTools(self: *Model) error{OutOfMemory}!void {
        for (self.tools.items) |t| {
            try self.appendChatFmt("  {s}◌ {s} interrupted{s}", .{ theme.dim, t.name, theme.reset });
        }
        self.clearTools();
    }

    fn clearTools(self: *Model) void {
        for (self.tools.items) |t| {
            self.gpa.free(t.name);
            self.gpa.free(t.input);
        }
        self.tools.clearRetainingCapacity();
    }

    fn removeOldestTool(self: *Model, name: []const u8) void {
        for (self.tools.items, 0..) |t, i| {
            if (std.mem.eql(u8, t.name, name)) {
                self.gpa.free(t.name);
                self.gpa.free(t.input);
                _ = self.tools.orderedRemove(i);
                return;
            }
        }
    }

    fn replaceOwned(self: *Model, slot: *?[]u8, value: []const u8) error{OutOfMemory}!void {
        const copy = try self.gpa.dupe(u8, value);
        if (slot.*) |old| self.gpa.free(old);
        slot.* = copy;
    }
};

/// Last `max` non-empty-tail lines of `text` into the band, prefixed and
/// wrapped in `sgr` (empty = terminal default).
fn appendTail(
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

fn dashes(arena: std.mem.Allocator, n: usize) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < n) : (i += 1) try out.appendSlice(arena, "─");
    return out.items;
}

fn spaces(arena: std.mem.Allocator, n: usize) error{OutOfMemory}![]const u8 {
    const buf = try arena.alloc(u8, n);
    @memset(buf, ' ');
    return buf;
}

/// Cut an input preview on a UTF-8 boundary, first line only.
fn previewLen(s: []const u8) usize {
    var end: usize = @min(s.len, input_preview_bytes);
    if (std.mem.indexOfScalar(u8, s[0..end], '\n')) |nl| end = nl;
    while (end > 0 and (s[end -| 1] & 0xC0) == 0x80) end -= 1;
    if (end > 0 and end < s.len and (s[end] & 0xC0) == 0x80) {
        while (end > 0 and (s[end - 1] & 0x80) != 0) end -= 1;
    }
    return end;
}

fn str(obj: json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn int(obj: json.ObjectMap, key: []const u8) i64 {
    const v = obj.get(key) orelse return 0;
    return if (v == .integer) v.integer else 0;
}

fn boolOf(obj: json.ObjectMap, key: []const u8) bool {
    const v = obj.get(key) orelse return false;
    return v == .bool and v.bool;
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

fn renderJoined(m: *Model, arena: std.mem.Allocator) ![]const u8 {
    const f = try m.render(arena, 80, 0);
    var out: std.ArrayList(u8) = .empty;
    for (f.chat) |l| {
        try out.appendSlice(arena, l);
        try out.append(arena, '\n');
    }
    try out.appendSlice(arena, "---\n");
    for (f.bottom) |l| {
        try out.appendSlice(arena, l);
        try out.append(arena, '\n');
    }
    return out.items;
}

test "mission event updates the header state and logs the transition" {
    var m = Model.init(testing.allocator, 0);
    defer m.deinit();
    m.onEvent(
        \\{"ts":1,"event":"mission","from":"planning","to":"executing","role_turns":2,"tasks_done":1,"tasks":6}
    );
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const view = try renderJoined(&m, arena_state.allocator());
    try testing.expect(std.mem.indexOf(u8, view, "mission planning → executing") != null);
    try testing.expect(std.mem.indexOf(u8, view, "executing · tasks 1/6") != null);
}

test "role_start opens a role and role_end collapses it with the outcome" {
    var m = Model.init(testing.allocator, 0);
    defer m.deinit();
    m.onEvent(
        \\{"ts":1,"event":"role_start","role":"architect","role_turn":2,"tools":true}
    );
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var view = try renderJoined(&m, arena_state.allocator());
    // Chat header ("architect" is color-wrapped, so match around the reset).
    try testing.expect(std.mem.indexOf(u8, view, "— turn 2") != null);
    try testing.expect(std.mem.indexOf(u8, view, "architect · turn 2") != null); // bottom band

    m.onEvent(
        \\{"ts":2,"event":"role_end","role":"architect","outcome":"failed","reason":"max_steps"}
    );
    view = try renderJoined(&m, arena_state.allocator());
    try testing.expect(std.mem.indexOf(u8, view, "architect: failed — max_steps") != null);
    // Role gone from the bottom band.
    try testing.expect(std.mem.indexOf(u8, view, "architect · turn 2") == null);
}

test "step event flushes streamed text into chat" {
    var m = Model.init(testing.allocator, 0);
    defer m.deinit();
    m.onEvent(
        \\{"ts":0,"event":"role_start","role":"executor","role_turn":1,"tools":true}
    );
    m.onDelta("thinking about ");
    m.onDelta("allocators\nsecond line");
    m.onEvent(
        \\{"ts":1,"event":"step","turn_id":"t","step":2,"provider":"p","model":"glm-5.2","attempt":0}
    );
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const f = try m.render(arena_state.allocator(), 80, 0);
    // Flushed into chat...
    var found = false;
    for (f.chat) |l| {
        if (std.mem.indexOf(u8, l, "thinking about allocators") != null) found = true;
    }
    try testing.expect(found);
    // ...and no longer in the live tail.
    for (f.bottom) |l| {
        try testing.expect(std.mem.indexOf(u8, l, "thinking about") == null);
    }
    // Step line shows the model.
    var step_line = false;
    for (f.bottom) |l| {
        if (std.mem.indexOf(u8, l, "step 2 · glm-5.2") != null) step_line = true;
    }
    try testing.expect(step_line);
}

test "deltas accumulate and render as the live tail" {
    var m = Model.init(testing.allocator, 0);
    defer m.deinit();
    m.onEvent(
        \\{"ts":1,"event":"role_start","role":"executor","role_turn":1,"tools":true}
    );
    m.onDelta("streaming now");
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const view = try renderJoined(&m, arena_state.allocator());
    const marker = std.mem.indexOf(u8, view, "---").?;
    try testing.expect(std.mem.indexOf(u8, view[marker..], "streaming now") != null);
}

test "tool_call opens a running box and tool_result collapses it" {
    var m = Model.init(testing.allocator, 0);
    defer m.deinit();
    m.onEvent(
        \\{"ts":1,"event":"tool_call","turn_id":"t","step":1,"tool":"bash","input":"{\"cmd\":\"ls\"}"}
    );
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var view = try renderJoined(&m, arena_state.allocator());
    const marker = std.mem.indexOf(u8, view, "---").?;
    try testing.expect(std.mem.indexOf(u8, view[marker..], "bash") != null);

    m.onEvent(
        \\{"ts":2,"event":"tool_result","step":1,"tool":"bash","is_error":false,"bytes":5120,"output":"ok"}
    );
    view = try renderJoined(&m, arena_state.allocator());
    // Collapsed into chat with the ok marker and size...
    try testing.expect(std.mem.indexOf(u8, view, "✓ bash") != null);
    try testing.expect(std.mem.indexOf(u8, view, "5.1k") != null);
    // ...and no longer running in the band.
    const m2 = std.mem.indexOf(u8, view, "---").?;
    try testing.expect(std.mem.indexOf(u8, view[m2..], "bash") == null);
}

test "tool_result with is_error renders the error marker" {
    var m = Model.init(testing.allocator, 0);
    defer m.deinit();
    m.onEvent(
        \\{"ts":1,"event":"tool_call","turn_id":"t","step":1,"tool":"web_search","input":"{}"}
    );
    m.onEvent(
        \\{"ts":2,"event":"tool_result","step":1,"tool":"web_search","is_error":true,"bytes":12,"output":"denied"}
    );
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const view = try renderJoined(&m, arena_state.allocator());
    try testing.expect(std.mem.indexOf(u8, view, "✗ web_search") != null);
}

test "usage events accumulate token totals" {
    var m = Model.init(testing.allocator, 0);
    defer m.deinit();
    m.onEvent(
        \\{"ts":1,"event":"usage","turn_id":"t","step":1,"input_tokens":10000,"output_tokens":2000}
    );
    m.onEvent(
        \\{"ts":2,"event":"usage","turn_id":"t","step":2,"input_tokens":2400,"output_tokens":1100}
    );
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const view = try renderJoined(&m, arena_state.allocator());
    try testing.expect(std.mem.indexOf(u8, view, "12.4k↑ 3.1k↓") != null);
}

test "turn_end flushes live text and collapses interrupted tools" {
    var m = Model.init(testing.allocator, 0);
    defer m.deinit();
    m.onDelta("tail text");
    m.onEvent(
        \\{"ts":1,"event":"tool_call","turn_id":"t","step":1,"tool":"bash","input":"{}"}
    );
    m.onEvent(
        \\{"ts":2,"event":"turn_end","turn_id":"t","stop":"aborted","steps":3}
    );
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const view = try renderJoined(&m, arena_state.allocator());
    try testing.expect(std.mem.indexOf(u8, view, "tail text") != null);
    try testing.expect(std.mem.indexOf(u8, view, "bash interrupted") != null);
    try testing.expect(std.mem.indexOf(u8, view, "turn: aborted (3 steps)") != null);
}

test "malformed event JSON is ignored and never wedges the model" {
    var m = Model.init(testing.allocator, 0);
    defer m.deinit();
    m.onEvent("not json at all");
    m.onEvent("{\"event\":42}");
    m.onEvent("[1,2,3]");
    m.onEvent("{}");
    m.onEvent(
        \\{"ts":1,"event":"usage","input_tokens":5,"output_tokens":5}
    );
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const view = try renderJoined(&m, arena_state.allocator());
    try testing.expect(std.mem.indexOf(u8, view, "5↑ 5↓") != null);
}

test "pending approval renders the y/N band and clears" {
    var m = Model.init(testing.allocator, 0);
    defer m.deinit();
    m.setPendingApproval("bash: rm -rf ./build");
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var view = try renderJoined(&m, arena_state.allocator());
    try testing.expect(std.mem.indexOf(u8, view, "approve bash: rm -rf ./build? [y/N]") != null);
    m.setPendingApproval(null);
    view = try renderJoined(&m, arena_state.allocator());
    try testing.expect(std.mem.indexOf(u8, view, "[y/N]") == null);
}

test "log lines land in chat as dim footnotes" {
    var m = Model.init(testing.allocator, 0);
    defer m.deinit();
    m.onLog("[mission] (warn): something odd");
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const f = try m.render(arena_state.allocator(), 80, 0);
    var found = false;
    for (f.chat) |l| {
        if (std.mem.indexOf(u8, l, "something odd") != null) found = true;
    }
    try testing.expect(found);
}

test "every mutation sets the dirty event" {
    var m = Model.init(testing.allocator, 0);
    defer m.deinit();

    try testing.expect(!m.dirty.isSet());
    m.onDelta("x");
    try testing.expect(m.dirty.isSet());
    m.dirty.reset();

    m.onEvent(
        \\{"ts":1,"event":"usage","input_tokens":1,"output_tokens":1}
    );
    try testing.expect(m.dirty.isSet());
    m.dirty.reset();

    m.setPendingApproval("x");
    try testing.expect(m.dirty.isSet());
    m.dirty.reset();

    m.onLog("y");
    try testing.expect(m.dirty.isSet());
}

var fake_now: i64 = 0;
fn fakeNow() i64 {
    return fake_now;
}

test "thinking streams live, then collapses to a thought-for line when text starts" {
    var m = Model.init(testing.allocator, 0);
    defer m.deinit();
    m.now_fn = &fakeNow;
    fake_now = 1000;

    m.onThinking("weighing allocator ");
    m.onThinking("strategies");
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var view = try renderJoined(&m, arena_state.allocator());
    const marker = std.mem.indexOf(u8, view, "---").?;
    try testing.expect(std.mem.indexOf(u8, view[marker..], "✳ thinking…") != null);
    try testing.expect(std.mem.indexOf(u8, view[marker..], "weighing allocator strategies") != null);

    fake_now = 13_000; // 12s of thinking
    m.onDelta("The answer is arenas.");
    view = try renderJoined(&m, arena_state.allocator());
    // Collapsed into history with the duration...
    try testing.expect(std.mem.indexOf(u8, view, "✳ thought for 12s") != null);
    // ...content gone from the band, answer text present at full color.
    const m2 = std.mem.indexOf(u8, view, "---").?;
    try testing.expect(std.mem.indexOf(u8, view[m2..], "weighing allocator") == null);
    try testing.expect(std.mem.indexOf(u8, view[m2..], "The answer is arenas.") != null);
    try testing.expect(std.mem.indexOf(u8, view[m2..], theme.dim ++ "The answer") == null);
}

test "a streaming tool call renders a live box with the extracted field" {
    var m = Model.init(testing.allocator, 0);
    defer m.deinit();
    m.onToolName("bash");
    m.onToolArgs("{\"command\":\"cat src/ker");
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var view = try renderJoined(&m, arena_state.allocator());
    const marker = std.mem.indexOf(u8, view, "---").?;
    try testing.expect(std.mem.indexOf(u8, view[marker..], "╭─ ") != null);
    try testing.expect(std.mem.indexOf(u8, view[marker..], "bash") != null);
    try testing.expect(std.mem.indexOf(u8, view[marker..], "cat src/ker") != null);
    try testing.expect(std.mem.indexOf(u8, view[marker..], "╰") != null);

    // Dispatch (the tool_call trace event) hands over to the running list.
    m.onEvent(
        \\{"ts":1,"event":"tool_call","turn_id":"t","step":1,"tool":"bash","input":"{\"command\":\"cat src/kernel/actor.zig\"}"}
    );
    view = try renderJoined(&m, arena_state.allocator());
    const m2 = std.mem.indexOf(u8, view, "---").?;
    try testing.expect(std.mem.indexOf(u8, view[m2..], "╭─ ") == null);
    try testing.expect(std.mem.indexOf(u8, view[m2..], "bash") != null); // running entry
}

test "thinking flushes when a tool call opens on the stream" {
    var m = Model.init(testing.allocator, 0);
    defer m.deinit();
    m.now_fn = &fakeNow;
    fake_now = 0;
    m.onThinking("should I list files?");
    fake_now = 3000;
    m.onToolName("bash");
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const view = try renderJoined(&m, arena_state.allocator());
    try testing.expect(std.mem.indexOf(u8, view, "✳ thought for 3s") != null);
    const marker = std.mem.indexOf(u8, view, "---").?;
    try testing.expect(std.mem.indexOf(u8, view[marker..], "should I list files") == null);
}

test "tool box body falls back to raw args and pads its rails" {
    var m = Model.init(testing.allocator, 0);
    defer m.deinit();
    m.onToolName("mcp_thing");
    m.onToolArgs("{\"weird\":\"sha");
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const f = try m.render(arena_state.allocator(), 80, 0);
    // Every box row ends at the right rail (aligned padding).
    var box_rows: usize = 0;
    for (f.bottom) |line| {
        if (std.mem.indexOf(u8, line, "│") != null) {
            box_rows += 1;
            try testing.expect(std.mem.endsWith(u8, line, "│"));
        }
    }
    try testing.expect(box_rows >= 1);
}

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
