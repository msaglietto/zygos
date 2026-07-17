//! Committed chat history for the mission TUI — the lines that flow into
//! native terminal scrollback and only grow. Owns the line storage and the
//! collapse/promote rules that move live buffers into history; knows nothing
//! of the bottom band or the terminal. Callers hold the model mutex.

const std = @import("std");
const theme = @import("theme.zig");
const width = @import("width.zig");
const markdown = @import("markdown.zig");
const entries = @import("entries.zig");
const durFmt = @import("fmt.zig").durFmt;

/// Narration collapses to ONE line; a first line longer than this clips
/// with an ellipsis instead of wrapping into a paragraph of dim text.
const narration_cap: usize = 96;

/// A dispatched tool call awaiting its result. Slices are owned by the
/// caller's gpa (the model frees them; the log only reads).
pub const ToolView = struct {
    name: []u8,
    input: []u8,
    /// Dispatch stamp — the collapsed line shows the run duration.
    started_ms: i64 = 0,
};

pub const FlushMode = enum {
    /// Step boundary: the text was the model talking to itself between
    /// tool calls — activity, not payload. One dim ◆ line.
    narration,
    /// Turn end: this is the answer. Full promote, markdown-lite styled.
    answer,
};

pub const ChatLog = struct {
    gpa: std.mem.Allocator,
    lines: std.ArrayList([]u8) = .empty,

    pub fn init(gpa: std.mem.Allocator) ChatLog {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *ChatLog) void {
        for (self.lines.items) |l| self.gpa.free(l);
        self.lines.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn appendFmt(self: *ChatLog, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
        const line = try std.fmt.allocPrint(self.gpa, fmt, args);
        errdefer self.gpa.free(line);
        try self.lines.append(self.gpa, line);
    }

    /// Collapse the reasoning phase into one history line, claude-code
    /// style: the content was visible live; scrollback keeps the duration.
    /// Clears the caller's thinking buffer and start stamp.
    pub fn flushThinking(
        self: *ChatLog,
        thinking: *std.ArrayList(u8),
        started_ms: *?i64,
        now_ms: i64,
    ) error{OutOfMemory}!void {
        if (thinking.items.len == 0) {
            started_ms.* = null;
            return;
        }
        var e_buf: [32]u8 = undefined;
        const started = started_ms.* orelse now_ms;
        const line = try entries.collapsedThought(self.gpa, durFmt(&e_buf, now_ms - started));
        errdefer self.gpa.free(line);
        try self.lines.append(self.gpa, line);
        thinking.clearRetainingCapacity();
        started_ms.* = null;
    }

    /// Move the streamed text into history and clear the live buffer.
    /// Raw JSON payloads (role protocol output: PO objectives, planner task
    /// lists, verifier verdicts) collapse like narration even at turn end —
    /// the mission/task lines already tell that story in prose.
    pub fn flushLive(self: *ChatLog, live: *std.ArrayList(u8), mode: FlushMode) error{OutOfMemory}!void {
        if (live.items.len == 0) return;
        defer live.clearRetainingCapacity();
        const text = std.mem.trim(u8, live.items, " \t\r\n");
        if (text.len == 0) return;
        const effective: FlushMode = if (mode == .answer and looksLikeJsonPayload(text)) .narration else mode;
        switch (effective) {
            .narration => {
                const nl = std.mem.indexOfScalar(u8, text, '\n');
                var first = std.mem.trimEnd(u8, text[0 .. nl orelse text.len], " \t\r");
                var clipped = nl != null;
                if (first.len > narration_cap) {
                    var end = narration_cap;
                    while (end > 0 and (first[end] & 0xC0) == 0x80) end -= 1;
                    first = first[0..end];
                    clipped = true;
                }
                try self.appendFmt("  {s}◆ {s}{s}{s}", .{
                    theme.dim,   first,
                    if (clipped) "…" else "",
                    theme.reset,
                });
            },
            .answer => {
                var arena_state = std.heap.ArenaAllocator.init(self.gpa);
                defer arena_state.deinit();
                var styler = markdown.Styler{};
                var lines = std.mem.splitScalar(u8, text, '\n');
                while (lines.next()) |line| {
                    if (line.len == 0) continue;
                    const styled = (styler.line(arena_state.allocator(), line) catch line) orelse continue;
                    try self.appendFmt("  {s}", .{styled});
                }
            },
        }
    }

    /// A bare protocol payload: the text (past an optional opening fence line)
    /// starts with a JSON object or array.
    fn looksLikeJsonPayload(text: []const u8) bool {
        var t = text;
        if (std.mem.startsWith(u8, t, "```")) {
            const nl = std.mem.indexOfScalar(u8, t, '\n') orelse return false;
            t = std.mem.trimStart(u8, t[nl + 1 ..], " \t\r\n");
        }
        return t.len > 0 and (t[0] == '{' or t[0] == '[');
    }

    /// A step/turn boundary with tools still open means their results never
    /// arrived (abort, provider error). Log them as interrupted; the caller
    /// still owns (and frees) the entries.
    pub fn collapseOpenTools(self: *ChatLog, tools: []const ToolView) error{OutOfMemory}!void {
        for (tools) |t| {
            try self.appendFmt("  {s}◌ {s} interrupted{s}", .{ theme.dim, t.name, theme.reset });
        }
    }

    /// Captured std.log line — a dim footnote so evidence is never hidden
    /// while the TUI owns the terminal. Stored unwrapped: wrapForRender
    /// word-wraps every line at the live terminal width.
    pub fn appendLog(self: *ChatLog, line: []const u8) error{OutOfMemory}!void {
        try self.appendFmt("{s}{s}{s}", .{ theme.dim, line, theme.reset });
    }

    /// History wrapped at the live width on word boundaries — the renderer
    /// clips rows defensively, so anything wider than `cols` here would
    /// lose its tail (mid-sentence cuts read as noise).
    pub fn wrapForRender(
        self: *const ChatLog,
        arena: std.mem.Allocator,
        cols: usize,
    ) error{OutOfMemory}![]const []const u8 {
        var rows: std.ArrayList([]const u8) = .empty;
        for (self.lines.items) |line| {
            try rows.appendSlice(arena, try width.wrapToWidth(arena, line, cols, "  "));
        }
        return rows.items;
    }
};

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "flushThinking collapses to a duration line and clears the buffer" {
    var log = ChatLog.init(testing.allocator);
    defer log.deinit();
    var thinking: std.ArrayList(u8) = .empty;
    defer thinking.deinit(testing.allocator);
    try thinking.appendSlice(testing.allocator, "weighing options");
    var started: ?i64 = 1000;
    try log.flushThinking(&thinking, &started, 13_000);
    try testing.expectEqual(@as(usize, 1), log.lines.items.len);
    try testing.expect(std.mem.indexOf(u8, log.lines.items[0], "◆ Thought for 12s") != null);
    try testing.expectEqual(@as(usize, 0), thinking.items.len);
    try testing.expectEqual(@as(?i64, null), started);
}

test "flushThinking on an empty buffer resets the stamp without logging" {
    var log = ChatLog.init(testing.allocator);
    defer log.deinit();
    var thinking: std.ArrayList(u8) = .empty;
    var started: ?i64 = 42;
    try log.flushThinking(&thinking, &started, 100);
    try testing.expectEqual(@as(usize, 0), log.lines.items.len);
    try testing.expectEqual(@as(?i64, null), started);
}

test "flushLive narration collapses to one dim first-line entry" {
    var log = ChatLog.init(testing.allocator);
    defer log.deinit();
    var live: std.ArrayList(u8) = .empty;
    defer live.deinit(testing.allocator);
    try live.appendSlice(testing.allocator, "first thought\nsecond line");
    try log.flushLive(&live, .narration);
    try testing.expectEqual(@as(usize, 1), log.lines.items.len);
    try testing.expect(std.mem.indexOf(u8, log.lines.items[0], "◆ first thought…") != null);
    try testing.expectEqual(@as(usize, 0), live.items.len);
}

test "flushLive answer promotes every line through markdown" {
    var log = ChatLog.init(testing.allocator);
    defer log.deinit();
    var live: std.ArrayList(u8) = .empty;
    defer live.deinit(testing.allocator);
    try live.appendSlice(testing.allocator, "## Result\nsecond line survives");
    try log.flushLive(&live, .answer);
    try testing.expectEqual(@as(usize, 2), log.lines.items.len);
    try testing.expect(std.mem.indexOf(u8, log.lines.items[0], "##") == null);
    try testing.expect(std.mem.indexOf(u8, log.lines.items[1], "second line survives") != null);
}

test "flushLive answer collapses raw JSON payloads like narration" {
    var log = ChatLog.init(testing.allocator);
    defer log.deinit();
    var live: std.ArrayList(u8) = .empty;
    defer live.deinit(testing.allocator);
    try live.appendSlice(testing.allocator, "{\"objective\":\"build it\",\"acceptance\":\"it works\"}");
    try log.flushLive(&live, .answer);
    try testing.expectEqual(@as(usize, 1), log.lines.items.len);
    try testing.expect(std.mem.indexOf(u8, log.lines.items[0], "◆ ") != null);
    try testing.expect(std.mem.startsWith(u8, log.lines.items[0], "  " ++ theme.dim));
}

test "flushLive answer collapses fenced JSON payloads too" {
    var log = ChatLog.init(testing.allocator);
    defer log.deinit();
    var live: std.ArrayList(u8) = .empty;
    defer live.deinit(testing.allocator);
    try live.appendSlice(testing.allocator, "```json\n{\"tasks\": [\"one\", \"two\"]}\n```");
    try log.flushLive(&live, .answer);
    try testing.expectEqual(@as(usize, 1), log.lines.items.len);
    try testing.expect(std.mem.indexOf(u8, log.lines.items[0], "◆ ") != null);
    try testing.expect(std.mem.indexOf(u8, log.lines.items[0], "│") == null); // no fence gutter
}

test "flushLive narration clips very long first lines" {
    var log = ChatLog.init(testing.allocator);
    defer log.deinit();
    var live: std.ArrayList(u8) = .empty;
    defer live.deinit(testing.allocator);
    try live.appendSlice(testing.allocator, "word " ** 40); // 200 bytes, one line
    try log.flushLive(&live, .narration);
    try testing.expectEqual(@as(usize, 1), log.lines.items.len);
    try testing.expect(log.lines.items[0].len < 120);
    try testing.expect(std.mem.indexOf(u8, log.lines.items[0], "…") != null);
}

test "collapseOpenTools logs each entry as interrupted" {
    var log = ChatLog.init(testing.allocator);
    defer log.deinit();
    var name = "bash".*;
    var input = "{}".*;
    try log.collapseOpenTools(&.{.{ .name = &name, .input = &input }});
    try testing.expectEqual(@as(usize, 1), log.lines.items.len);
    try testing.expect(std.mem.indexOf(u8, log.lines.items[0], "◌ bash interrupted") != null);
}

test "wrapForRender wraps history at the given width" {
    var log = ChatLog.init(testing.allocator);
    defer log.deinit();
    try log.appendLog("[provider] (warning): endpoint answered 429 and the ladder retried on another host");
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const rows = try log.wrapForRender(arena_state.allocator(), 40);
    try testing.expect(rows.len > 1);
    for (rows) |r| try testing.expect(width.visibleWidth(r) <= 40);
}
