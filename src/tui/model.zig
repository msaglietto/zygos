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
const trace_event = @import("../worker/trace_event.zig");
const sync = @import("../kernel/sync.zig");
const theme = @import("theme.zig");
const width = @import("width.zig");
const partialjson = @import("partialjson.zig");
const chatlog = @import("chatlog.zig");
const scrub_mod = @import("scrub.zig");
const band = @import("band.zig");
const steerinput = @import("steerinput.zig");
const entries = @import("entries.zig");
const tasks_mod = @import("tasks.zig");
const previewLen = @import("fmt.zig").previewLen;
const durFmt = @import("fmt.zig").durFmt;

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
    role_started_ms: ?i64 = null,
    step: i64 = 0,
    step_model: ?[]u8 = null,
    attempt: i64 = 0,
    tokens_in: i64 = 0,
    tokens_out: i64 = 0,
    approval: ?[]u8 = null,
    /// M6 intervention: steer input line editor + pause state.
    steer_input: steerinput.SteerInput = .{},
    paused: bool = false,
    /// The executor's live task (task_start .. task_done window).
    current_task: ?tasks_mod.Current = null,

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
    /// Current activity class + when it last changed: the status-line phase
    /// timer resets exactly on class transitions (touchPhase).
    phase_class: band.Activity = .idle,
    phase_started_ms: i64 = 0,
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
        self.steer_input.deinit(self.gpa);
        if (self.current_task) |t| self.gpa.free(t.desc);
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
        // Unknown kinds parse as null and are ignored: the view must survive
        // a newer emitter. Known kinds hit the exhaustive switch below.
        const parsed = trace_event.parse(arena, line_json) orelse return;

        self.mutex.lock();
        defer self.mutex.unlock();
        defer self.dirty.set();
        self.applyEvent(arena, parsed.event) catch {}; // OOM: drop the line, keep the view alive
        self.touchPhase();
    }

    pub fn onDelta(self: *Model, bytes: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        // The answer starting is the end of the thinking phase.
        self.flushThinking() catch {};
        scrub_mod.appendScrubbed(self.gpa, &self.live, bytes) catch {};
        self.stream_bytes += bytes.len;
        self.touchPhase();
        self.dirty.set();
    }

    /// Reasoning stream (worker/stream_tap.zig `.thinking`).
    pub fn onThinking(self: *Model, bytes: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.thinking_started_ms == null) self.thinking_started_ms = self.now_fn();
        scrub_mod.appendScrubbed(self.gpa, &self.thinking, bytes) catch {};
        self.stream_bytes += bytes.len;
        self.touchPhase();
        self.dirty.set();
    }

    /// A tool call opened on the stream (`.tool_name`): start a live box.
    /// Thinking and narration both close here — they precede the call.
    pub fn onToolName(self: *Model, name: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.flushThinking() catch {};
        self.flushLive(.narration) catch {};
        const copy = self.gpa.dupe(u8, name) catch return;
        if (self.live_tool_name) |old| self.gpa.free(old);
        self.live_tool_name = copy;
        self.live_tool_args.clearRetainingCapacity();
        self.live_tool_high = 0;
        self.touchPhase();
        self.dirty.set();
    }

    /// Streaming tool-arguments fragment (`.tool_args`).
    pub fn onToolArgs(self: *Model, fragment: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        scrub_mod.appendScrubbed(self.gpa, &self.live_tool_args, fragment) catch {};
        self.dirty.set();
    }

    /// Captured std.log line — shown as a dim footnote so evidence is never
    /// hidden while the TUI owns the terminal. Stored unwrapped: render()
    /// word-wraps every chat line at the live terminal width.
    pub fn onLog(self: *Model, line: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        // Captured stderr can embed worker-supplied bytes (frame snippets in
        // warn lines): scrub before it becomes a rendered footnote.
        const safe = scrub_mod.scrub(self.gpa, line) catch return;
        defer self.gpa.free(safe);
        self.log.appendLog(safe) catch {};
        self.dirty.set();
    }

    /// The mission objective, echoed once at the top of the transcript —
    /// grok's prompt-echo band, sans background (terminal-native scrollback).
    pub fn setObjective(self: *Model, text: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.log.appendFmt("{s}❯ {s}{s}", .{ theme.bold, text, theme.reset }) catch {};
        self.dirty.set();
    }

    // -- intervention (M6): steer input line + pause state --------------------

    pub fn steerInputOpen(self: *Model) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.steer_input.isOpen();
    }

    pub fn steerOpen(self: *Model) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.steer_input.open();
        self.dirty.set();
    }

    /// One raw key into the open input; 0x7f/0x08 backspace. No-op when
    /// closed or non-printable.
    pub fn steerKey(self: *Model, key: u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.steer_input.key(self.gpa, key)) self.dirty.set();
    }

    pub fn steerCancel(self: *Model) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.steer_input.cancel(self.gpa);
        self.dirty.set();
    }

    /// Close the input and hand the text over (gpa-owned, caller frees);
    /// an empty input yields null — nothing to send.
    pub fn steerTake(self: *Model) ?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.steer_input.isOpen()) self.dirty.set();
        return self.steer_input.take(self.gpa);
    }

    pub fn setPaused(self: *Model, paused: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.paused = paused;
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
        self.touchPhase();
        self.dirty.set();
    }

    fn applyEvent(self: *Model, arena: std.mem.Allocator, ev: trace_event.TraceEvent) error{OutOfMemory}!void {
        switch (ev) {
            .mission => |m| {
                try self.replaceOwned(&self.mission_state, m.to);
                self.tasks_done = m.tasks_done;
                self.tasks = m.tasks;
                var color: [24]u8 = undefined;
                try self.log.appendFmt("{s}◆ mission {s} → {s}{s}", .{
                    theme.fg(&color, theme.Color.accent), m.from, m.to, theme.reset,
                });
            },
            .role_start => |r| {
                try self.replaceOwned(&self.role, r.role);
                self.role_turn = r.role_turn;
                self.role_started_ms = self.now_fn();
                self.step = 0;
                var color: [24]u8 = undefined;
                try self.log.appendFmt("", .{}); // breathing room between roles
                try self.log.appendFmt("{s}▌ {s}{s} — turn {d}", .{
                    theme.fg(&color, theme.Color.accent), r.role, theme.reset, self.role_turn,
                });
            },
            .role_end => |r| {
                try self.flushThinking();
                try self.flushLive(.answer);
                self.clearLiveTool();
                try self.collapseOpenTools();
                const failed = !std.mem.eql(u8, r.outcome, "ok");
                var color: [24]u8 = undefined;
                if (r.reason) |reason| {
                    try self.log.appendFmt("{s}▌ {s}: {s} — {s}{s}", .{
                        theme.fg(&color, if (failed) theme.Color.err else theme.Color.ok),
                        r.role,
                        r.outcome,
                        reason,
                        theme.reset,
                    });
                } else {
                    try self.log.appendFmt("{s}▌ {s}: {s}{s}", .{
                        theme.fg(&color, if (failed) theme.Color.err else theme.Color.ok),
                        r.role,
                        r.outcome,
                        theme.reset,
                    });
                }
                if (self.role_started_ms) |started| {
                    var e_buf: [32]u8 = undefined;
                    try self.log.appendFmt("{s}Worked for {s}.{s}", .{
                        theme.dim, durFmt(&e_buf, self.now_fn() - started), theme.reset,
                    });
                    self.role_started_ms = null;
                }
                if (self.role) |r_owned| {
                    self.gpa.free(r_owned);
                    self.role = null;
                }
            },
            .step => |s| {
                try self.flushThinking();
                try self.flushLive(.narration);
                self.clearLiveTool();
                self.step = s.step;
                self.attempt = s.attempt;
                try self.replaceOwned(&self.step_model, s.model);
            },
            .tool_call => |tc| {
                // Dispatch: the streaming box (if any) hands over to the running
                // tool list fed by this event. Narration streamed before this
                // call commits first — otherwise the "I'll do X" line lands
                // after the tool it introduced (reads backwards in scrollback).
                try self.flushLive(.narration);
                self.clearLiveTool();
                const name = try self.gpa.dupe(u8, tc.tool);
                errdefer self.gpa.free(name);
                const preview = tc.input[0..previewLen(tc.input)];
                const input = try self.gpa.dupe(u8, preview);
                errdefer self.gpa.free(input);
                try self.tools.append(self.gpa, .{ .name = name, .input = input, .started_ms = self.now_fn() });
            },
            .tool_result => |tr| {
                var count: [32]u8 = undefined;
                var e_buf: [32]u8 = undefined;
                // Collapsed line keeps the call readable in scrollback: name,
                // the input it ran with, size, duration, and an output preview.
                const open = self.oldestTool(tr.tool);
                const input: []const u8 = if (open) |t| t.input else "";
                const started: i64 = if (open) |t| t.started_ms else self.now_fn();
                // Prefer the human payload inside the tool's JSON envelope
                // ({"output":...}, {"content":...}) over the envelope itself.
                const unwrapped = (try partialjson.extractStringField(arena, tr.output, "output")) orelse
                    (try partialjson.extractDisplayField(arena, tr.output)) orelse tr.output;
                const shown: []const u8 = if (unwrapped.len > 0) unwrapped else tr.output;
                // Tool output is remote content (fetched pages, cat'd files):
                // ESC/C0 never reach the terminal from a preview.
                const out_preview = try scrub_mod.scrub(arena, shown[0..previewLen(shown)]);
                const input_s = try scrub_mod.scrub(arena, input);
                try self.log.appendFmt("{s}", .{try entries.collapsedTool(
                    arena,
                    tr.tool,
                    input_s,
                    theme.tokens(&count, tr.bytes),
                    durFmt(&e_buf, self.now_fn() - started),
                    tr.is_error,
                )});
                if (out_preview.len > 0) {
                    try self.log.appendFmt("    {s}{s}{s}{s}", .{
                        theme.dim,
                        if (tr.is_error) "✗ " else "→ ",
                        out_preview,
                        theme.reset,
                    });
                }
                self.removeOldestTool(tr.tool);
            },
            .task_start => |t| {
                const desc = try self.gpa.dupe(u8, t.desc);
                if (self.current_task) |ct| self.gpa.free(ct.desc);
                self.current_task = .{
                    .index = t.index,
                    .total = t.total,
                    .desc = desc,
                    .started_ms = self.now_fn(),
                };
            },
            .task_done => {
                // The hand-off: this task collapses into scrollback; the next
                // task_start repopulates the band with a fresh timer.
                if (self.current_task) |t| {
                    var e_buf: [32]u8 = undefined;
                    try self.log.appendFmt("{s}", .{try tasks_mod.doneLine(
                        arena,
                        t,
                        durFmt(&e_buf, self.now_fn() - t.started_ms),
                    )});
                    self.gpa.free(t.desc);
                    self.current_task = null;
                }
            },
            .usage => |u| {
                self.tokens_in += u.input_tokens;
                self.tokens_out += u.output_tokens;
            },
            .steer => |s| {
                var color: [24]u8 = undefined;
                try self.log.appendFmt("{s}⚑ steer: {s}{s}", .{
                    theme.fg(&color, theme.Color.accent), s.text, theme.reset,
                });
            },
            .turn_end => |te| {
                try self.flushThinking();
                try self.flushLive(.answer);
                self.clearLiveTool();
                try self.collapseOpenTools();
                self.step = 0;
                var buf: [64]u8 = undefined;
                const suffix = if (te.err) |e|
                    std.fmt.bufPrint(&buf, " — {s}", .{e[0..@min(e.len, 40)]}) catch ""
                else
                    "";
                try self.log.appendFmt("{s}  turn: {s} ({d} steps){s}{s}", .{
                    theme.dim, te.stop, te.steps, suffix, theme.reset,
                });
            },
        }
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
            .activity = self.phase_class,
            .phase_started_ms = self.phase_started_ms,
            .role_started_ms = self.role_started_ms,
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
            .steer_input = self.steer_input.text(),
            .paused = self.paused,
            .current_task = self.current_task,
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

    /// Re-derive the activity class after a mutation; a class change resets
    /// the status-line phase timer. Priority mirrors band.Activity order.
    fn touchPhase(self: *Model) void {
        const class: band.Activity = if (self.approval != null)
            .approval
        else if (self.tools.items.len > 0 or self.live_tool_name != null)
            .tool
        else if (self.thinking.items.len > 0)
            .thinking
        else if (self.live.items.len > 0)
            .streaming
        else
            .idle;
        if (class != self.phase_class) {
            self.phase_class = class;
            self.phase_started_ms = self.now_fn();
        }
    }

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
    // Collapsed into chat as one dim line with size and duration...
    try testing.expect(std.mem.indexOf(u8, view, "◆ bash") != null);
    try testing.expect(std.mem.indexOf(u8, view, "5.1kB") != null);
    // ...and no longer running in the band.
    const m2 = std.mem.indexOf(u8, view, "---").?;
    try testing.expect(std.mem.indexOf(u8, view[m2..], "bash") == null);
}

test "narration commits before the tool call it introduced" {
    var m = Model.init(testing.allocator, 0);
    defer m.deinit();
    m.onDelta("I'll create the script now.");
    m.onEvent(
        \\{"ts":1,"event":"tool_call","turn_id":"t","step":1,"tool":"bash","input":"{}"}
    );
    m.onEvent(
        \\{"ts":2,"event":"tool_result","step":1,"tool":"bash","is_error":false,"bytes":5,"output":"ok"}
    );
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const view = try renderJoined(&m, arena_state.allocator());
    const say = std.mem.indexOf(u8, view, "I'll create the script now.") orelse return error.NoNarration;
    const did = std.mem.indexOf(u8, view, "◆ bash") orelse return error.NoTool;
    try testing.expect(say < did);
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

test "steer input: open, type, backspace, render, take — the intervention line" {
    var m = Model.init(testing.allocator, 0);
    defer m.deinit();
    try testing.expect(!m.steerInputOpen());
    m.steerOpen();
    try testing.expect(m.steerInputOpen());
    for ("focx") |ch| m.steerKey(ch);
    m.steerKey(0x7f); // backspace
    for ("us on docs") |ch| m.steerKey(ch);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const view = try renderJoined(&m, arena_state.allocator());
    try testing.expect(std.mem.indexOf(u8, view, "steer: focus on docs") != null);
    try testing.expect(std.mem.indexOf(u8, view, "Enter send") != null);

    const text = m.steerTake() orelse return error.NoText;
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("focus on docs", text);
    try testing.expect(!m.steerInputOpen());
}

test "steer input: cancel discards; taking an empty input yields null" {
    var m = Model.init(testing.allocator, 0);
    defer m.deinit();
    m.steerOpen();
    m.steerKey('x');
    m.steerCancel();
    try testing.expect(!m.steerInputOpen());
    m.steerOpen();
    try testing.expect(m.steerTake() == null); // empty input: nothing to send
    try testing.expect(!m.steerInputOpen());
}

test "paused missions say so in the status line until resumed" {
    var m = Model.init(testing.allocator, 0);
    defer m.deinit();
    m.setPaused(true);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var view = try renderJoined(&m, arena_state.allocator());
    try testing.expect(std.mem.indexOf(u8, view, "Paused") != null);
    m.setPaused(false);
    view = try renderJoined(&m, arena_state.allocator());
    try testing.expect(std.mem.indexOf(u8, view, "Paused") == null);
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

test "setObjective echoes the prompt once at the top of the transcript" {
    var m = Model.init(testing.allocator, 0);
    defer m.deinit();
    m.setObjective("ship the gizmo");
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const view = try renderJoined(&m, arena_state.allocator());
    try testing.expect(std.mem.indexOf(u8, view, "❯ ship the gizmo") != null);
}

test "role_end appends a dim worked-for duration line" {
    var m = Model.init(testing.allocator, 0);
    defer m.deinit();
    m.now_fn = &fakeNow;
    fake_now = 0;
    m.onEvent(
        \\{"ts":1,"event":"role_start","role":"executor","role_turn":1,"tools":true}
    );
    fake_now = 73_000;
    m.onEvent(
        \\{"ts":2,"event":"role_end","role":"executor","outcome":"ok"}
    );
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const view = try renderJoined(&m, arena_state.allocator());
    try testing.expect(std.mem.indexOf(u8, view, "Worked for 1m13s.") != null);
}

test "task_start highlights the band and task_done hands off to the next" {
    var m = Model.init(testing.allocator, 0);
    defer m.deinit();
    m.now_fn = &fakeNow;
    fake_now = 0;
    m.onEvent(
        \\{"ts":1,"event":"task_start","index":1,"total":2,"desc":"build the gizmo"}
    );
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var view = try renderJoined(&m, arena_state.allocator());
    var marker = std.mem.indexOf(u8, view, "---").?;
    try testing.expect(std.mem.indexOf(u8, view[marker..], "task 1/2") != null);
    try testing.expect(std.mem.indexOf(u8, view[marker..], "build the gizmo") != null);

    fake_now = 80_000; // 1m20s on the first task
    m.onEvent(
        \\{"ts":2,"event":"task_done","index":1,"total":2,"desc":"build the gizmo"}
    );
    m.onEvent(
        \\{"ts":3,"event":"task_start","index":2,"total":2,"desc":"test the gizmo"}
    );
    view = try renderJoined(&m, arena_state.allocator());
    marker = std.mem.indexOf(u8, view, "---").?;
    // The finished task collapsed into scrollback with its duration...
    try testing.expect(std.mem.indexOf(u8, view[0..marker], "task 1/2 build the gizmo · 1m20s") != null);
    // ...and the band now highlights the next task, not the old one.
    try testing.expect(std.mem.indexOf(u8, view[marker..], "task 2/2") != null);
    try testing.expect(std.mem.indexOf(u8, view[marker..], "build the gizmo") == null);
}

test "phase timer resets when the activity class changes" {
    var m = Model.init(testing.allocator, 0);
    defer m.deinit();
    m.now_fn = &fakeNow;
    fake_now = 1_000;
    m.onThinking("hmm");
    try testing.expectEqual(band.Activity.thinking, m.phase_class);
    try testing.expectEqual(@as(i64, 1_000), m.phase_started_ms);

    fake_now = 5_000;
    m.onThinking("more"); // same class: timer unchanged
    try testing.expectEqual(@as(i64, 1_000), m.phase_started_ms);

    m.onDelta("answer"); // thinking flushed → streaming: timer resets
    try testing.expectEqual(band.Activity.streaming, m.phase_class);
    try testing.expectEqual(@as(i64, 5_000), m.phase_started_ms);

    // Approval outranks everything.
    m.setPendingApproval("bash: rm -rf ./build");
    try testing.expectEqual(band.Activity.approval, m.phase_class);
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
    try testing.expect(std.mem.indexOf(u8, view[marker..], "Thinking…") != null);
    try testing.expect(std.mem.indexOf(u8, view[marker..], entries.thin_rail) != null);
    try testing.expect(std.mem.indexOf(u8, view[marker..], "weighing allocator strategies") != null);

    fake_now = 13_000; // 12s of thinking
    m.onDelta("The answer is arenas.");
    view = try renderJoined(&m, arena_state.allocator());
    // Collapsed into history with the duration...
    try testing.expect(std.mem.indexOf(u8, view, "◆ Thought for 12s") != null);
    // ...content gone from the band, answer text present at full color.
    const m2 = std.mem.indexOf(u8, view, "---").?;
    try testing.expect(std.mem.indexOf(u8, view[m2..], "weighing allocator") == null);
    try testing.expect(std.mem.indexOf(u8, view[m2..], "The answer is arenas.") != null);
    try testing.expect(std.mem.indexOf(u8, view[m2..], theme.dim ++ "The answer") == null);
}

test "a streaming tool call renders a rail entry with the extracted field" {
    var m = Model.init(testing.allocator, 0);
    defer m.deinit();
    m.onToolName("bash");
    m.onToolArgs("{\"command\":\"cat src/ker");
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var view = try renderJoined(&m, arena_state.allocator());
    var marker = std.mem.indexOf(u8, view, "---").?;
    // Heavy-rail header + rail-guttered body carrying the streamed field.
    try testing.expect(std.mem.count(u8, view[marker..], entries.heavy_rail) >= 2);
    try testing.expect(std.mem.indexOf(u8, view[marker..], "bash") != null);
    try testing.expect(std.mem.indexOf(u8, view[marker..], "cat src/ker") != null);

    // Dispatch (the tool_call trace event) hands over to the running list:
    // the streaming body collapses into one rail line.
    m.onEvent(
        \\{"ts":1,"event":"tool_call","turn_id":"t","step":1,"tool":"bash","input":"{\"command\":\"cat src/kernel/actor.zig\"}"}
    );
    view = try renderJoined(&m, arena_state.allocator());
    marker = std.mem.indexOf(u8, view, "---").?;
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, view[marker..], entries.heavy_rail));
    try testing.expect(std.mem.indexOf(u8, view[marker..], "bash") != null); // running entry
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
    try testing.expect(std.mem.indexOf(u8, view, "◆ Thought for 3.0s") != null);
    const marker = std.mem.indexOf(u8, view, "---").?;
    try testing.expect(std.mem.indexOf(u8, view[marker..], "should I list files") == null);
}

test "tool entry body falls back to raw args under the rail" {
    var m = Model.init(testing.allocator, 0);
    defer m.deinit();
    m.onToolName("mcp_thing");
    m.onToolArgs("{\"weird\":\"sha");
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const f = try m.render(arena_state.allocator(), 80, 0);
    // No extractable display field: the raw args stream shows anyway.
    var raw_row = false;
    for (f.bottom) |line| {
        if (std.mem.indexOf(u8, line, "{\"weird\":\"sha") != null) {
            raw_row = true;
            try testing.expect(std.mem.indexOf(u8, line, entries.heavy_rail) != null);
        }
    }
    try testing.expect(raw_row);
}
