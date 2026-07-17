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
const chatlog = @import("chatlog.zig");
const band = @import("band.zig");
const previewLen = @import("fmt.zig").previewLen;

fn defaultNow() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

pub const Frame = struct {
    chat: []const []const u8,
    bottom: []const []const u8,
};

const ToolView = chatlog.ToolView;

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
    log: chatlog.ChatLog,
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
    /// Total streamed bytes seen (text + thinking) — surfaced in the status
    /// line as a live health check of the delta path.
    stream_bytes: usize = 0,
    /// Injectable clock (tests); render timestamps still come from callers.
    now_fn: *const fn () i64 = &defaultNow,

    pub fn init(gpa: std.mem.Allocator, started_ms: i64) Model {
        return .{ .gpa = gpa, .started_ms = started_ms, .log = chatlog.ChatLog.init(gpa) };
    }

    pub fn deinit(self: *Model) void {
        self.log.deinit();
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
        self.stream_bytes += bytes.len;
        self.dirty.set();
    }

    /// Reasoning stream (worker/stream_tap.zig `.thinking`).
    pub fn onThinking(self: *Model, bytes: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.thinking_started_ms == null) self.thinking_started_ms = self.now_fn();
        self.thinking.appendSlice(self.gpa, bytes) catch {};
        self.stream_bytes += bytes.len;
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
    /// hidden while the TUI owns the terminal. Stored unwrapped: render()
    /// word-wraps every chat line at the live terminal width.
    pub fn onLog(self: *Model, line: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.log.appendLog(line) catch {};
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
        if (std.mem.eql(u8, ev, "mission")) {
            const to = str(obj, "to") orelse "?";
            try self.replaceOwned(&self.mission_state, to);
            self.tasks_done = int(obj, "tasks_done");
            self.tasks = int(obj, "tasks");
            var color: [24]u8 = undefined;
            try self.log.appendFmt("{s}◆ mission {s} → {s}{s}", .{
                theme.fg(&color, theme.Color.accent), str(obj, "from") orelse "?", to, theme.reset,
            });
        } else if (std.mem.eql(u8, ev, "role_start")) {
            const role = str(obj, "role") orelse "?";
            try self.replaceOwned(&self.role, role);
            self.role_turn = int(obj, "role_turn");
            self.step = 0;
            var color: [24]u8 = undefined;
            try self.log.appendFmt("", .{}); // breathing room between roles
            try self.log.appendFmt("{s}▌ {s}{s} — turn {d}", .{
                theme.fg(&color, theme.Color.accent), role, theme.reset, self.role_turn,
            });
        } else if (std.mem.eql(u8, ev, "role_end")) {
            try self.flushThinking();
            try self.flushLive(.answer);
            self.clearLiveTool();
            try self.collapseOpenTools();
            const outcome = str(obj, "outcome") orelse "?";
            const failed = !std.mem.eql(u8, outcome, "ok");
            var color: [24]u8 = undefined;
            if (str(obj, "reason")) |reason| {
                try self.log.appendFmt("{s}▌ {s}: {s} — {s}{s}", .{
                    theme.fg(&color, if (failed) theme.Color.err else theme.Color.ok),
                    str(obj, "role") orelse "?",
                    outcome,
                    reason,
                    theme.reset,
                });
            } else {
                try self.log.appendFmt("{s}▌ {s}: {s}{s}", .{
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
            try self.flushLive(.narration);
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
            var color: [24]u8 = undefined;
            var count: [32]u8 = undefined;
            // Collapsed line keeps the call readable in scrollback: name,
            // the input it ran with, size, and a one-line output preview.
            const input: []const u8 = if (self.oldestTool(name)) |t| t.input else "";
            // Prefer the human payload inside the tool's JSON envelope
            // ({"output":...}, {"content":...}) over the envelope itself.
            const raw_out = str(obj, "output") orelse "";
            const unwrapped = (try partialjson.extractStringField(arena, raw_out, "output")) orelse
                (try partialjson.extractDisplayField(arena, raw_out)) orelse raw_out;
            const shown: []const u8 = if (unwrapped.len > 0) unwrapped else raw_out;
            const out_preview = shown[0..previewLen(shown)];
            try self.log.appendFmt("  {s}{s} {s}{s} {s}{s}{s} · {s}B", .{
                theme.fg(&color, if (is_err) theme.Color.err else theme.Color.ok),
                if (is_err) "✗" else "✓",
                name,
                theme.reset,
                theme.dim,
                input,
                theme.reset,
                theme.tokens(&count, int(obj, "bytes")),
            });
            if (out_preview.len > 0) {
                try self.log.appendFmt("    {s}{s}{s}{s}", .{
                    theme.dim,
                    if (is_err) "✗ " else "→ ",
                    out_preview,
                    theme.reset,
                });
            }
            self.removeOldestTool(name);
        } else if (std.mem.eql(u8, ev, "usage")) {
            self.tokens_in += int(obj, "input_tokens");
            self.tokens_out += int(obj, "output_tokens");
        } else if (std.mem.eql(u8, ev, "turn_end")) {
            try self.flushThinking();
            try self.flushLive(.answer);
            self.clearLiveTool();
            try self.collapseOpenTools();
            self.step = 0;
            var buf: [64]u8 = undefined;
            const stop = str(obj, "stop") orelse "?";
            const suffix = if (str(obj, "error")) |e|
                std.fmt.bufPrint(&buf, " — {s}", .{e[0..@min(e.len, 40)]}) catch ""
            else
                "";
            try self.log.appendFmt("{s}  turn: {s} ({d} steps){s}{s}", .{
                theme.dim, stop, int(obj, "steps"), suffix, theme.reset,
            });
        }
        // Unknown kinds are ignored: the view must survive a newer emitter.
    }

    // -- rendering (render thread) -------------------------------------------

    /// Snapshot the frame into `arena`: wrapped chat history + the band
    /// composed by band.build() over a locked view of this model.
    pub fn render(self: *Model, arena: std.mem.Allocator, cols: usize, now_ms: i64) error{OutOfMemory}!Frame {
        self.mutex.lock();
        defer self.mutex.unlock();

        const chat = try self.log.wrapForRender(arena, cols);
        const bottom = try band.build(.{
            .started_ms = self.started_ms,
            .mission_state = self.mission_state,
            .tasks_done = self.tasks_done,
            .tasks = self.tasks,
            .role = self.role,
            .role_turn = self.role_turn,
            .step = self.step,
            .step_model = self.step_model,
            .attempt = self.attempt,
            .tokens_in = self.tokens_in,
            .tokens_out = self.tokens_out,
            .approval = self.approval,
            .tools = self.tools.items,
            .thinking = self.thinking.items,
            .thinking_started_ms = self.thinking_started_ms,
            .live = self.live.items,
            .live_tool_name = self.live_tool_name,
            .live_tool_args = self.live_tool_args.items,
            .live_tool_high = &self.live_tool_high,
            .stream_bytes = self.stream_bytes,
        }, arena, cols, now_ms);

        return .{ .chat = chat, .bottom = bottom };
    }

    // -- internals (mutex held) ----------------------------------------------

    fn flushThinking(self: *Model) error{OutOfMemory}!void {
        try self.log.flushThinking(&self.thinking, &self.thinking_started_ms, self.now_fn());
    }

    fn clearLiveTool(self: *Model) void {
        if (self.live_tool_name) |n| {
            self.gpa.free(n);
            self.live_tool_name = null;
        }
        self.live_tool_args.clearRetainingCapacity();
        self.live_tool_high = 0;
    }

    fn flushLive(self: *Model, mode: chatlog.FlushMode) error{OutOfMemory}!void {
        try self.log.flushLive(&self.live, mode);
    }

    /// A step/turn boundary with tools still open means their results never
    /// arrived (abort, provider error). Collapse them as interrupted.
    fn collapseOpenTools(self: *Model) error{OutOfMemory}!void {
        try self.log.collapseOpenTools(self.tools.items);
        self.clearTools();
    }

    fn clearTools(self: *Model) void {
        for (self.tools.items) |t| {
            self.gpa.free(t.name);
            self.gpa.free(t.input);
        }
        self.tools.clearRetainingCapacity();
    }

    fn oldestTool(self: *Model, name: []const u8) ?*const ToolView {
        for (self.tools.items) |*t| {
            if (std.mem.eql(u8, t.name, name)) return t;
        }
        return null;
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
    // Interim narration collapses to ONE dim ◆ line (the model talking to
    // itself between tool calls is activity, not the answer).
    var found = false;
    var second = false;
    for (f.chat) |l| {
        if (std.mem.indexOf(u8, l, "◆ thinking about allocators…") != null) found = true;
        if (std.mem.indexOf(u8, l, "second line") != null) second = true;
    }
    try testing.expect(found);
    try testing.expect(!second);
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

test "turn_end promotes the answer in full with markdown styling" {
    var m = Model.init(testing.allocator, 0);
    defer m.deinit();
    m.onDelta("## Result\nkept `HEAD` intact\nsecond line survives");
    m.onEvent(
        \\{"ts":1,"event":"turn_end","turn_id":"t","stop":"end_turn","steps":1}
    );
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const view = try renderJoined(&m, arena_state.allocator());
    // Full promote — nothing collapsed away.
    try testing.expect(std.mem.indexOf(u8, view, "second line survives") != null);
    // Header styled, hashes gone; inline code amber, backticks gone.
    try testing.expect(std.mem.indexOf(u8, view, "##") == null);
    try testing.expect(std.mem.indexOf(u8, view, "\x1b[38;5;75mResult") != null);
    try testing.expect(std.mem.indexOf(u8, view, "\x1b[38;5;179mHEAD\x1b[0m") != null);
    try testing.expect(std.mem.indexOf(u8, view, "`HEAD`") == null);
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
    // Keys FIRST: the ask summary can exceed the terminal width and the
    // renderer clips rows right — a trailing hint would be the part lost.
    const keys_at = std.mem.indexOf(u8, view, "[y/N] approve?") orelse return error.NoKeyHint;
    const ask_at = std.mem.indexOf(u8, view, "bash: rm -rf ./build") orelse return error.NoAsk;
    try testing.expect(keys_at < ask_at);
    m.setPendingApproval(null);
    view = try renderJoined(&m, arena_state.allocator());
    try testing.expect(std.mem.indexOf(u8, view, "[y/N]") == null);
}

test "chat lines wrap at the render width on word boundaries" {
    var m = Model.init(testing.allocator, 0);
    defer m.deinit();
    m.onLog("[provider] (warning): endpoint answered 429 and the ladder retried on another host");
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const f = try m.render(arena_state.allocator(), 40, 0);
    try testing.expect(f.chat.len > 1); // wrapped, not one clipped row
    var joined: std.ArrayList(u8) = .empty;
    for (f.chat) |l| {
        try testing.expect(width.visibleWidth(l) <= 40); // nothing for the renderer to clip
        try joined.appendSlice(arena_state.allocator(), l);
        try joined.append(arena_state.allocator(), '\n');
    }
    // Word boundary, and no tail lost (the closing words survive the wrap).
    try testing.expect(std.mem.indexOf(u8, joined.items, "endpoint") != null);
    try testing.expect(std.mem.indexOf(u8, joined.items, "host") != null);
    try testing.expect(std.mem.indexOf(u8, joined.items, "endpoin\n") == null);
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
