//! Mission/turn trace — the harness view. One JSON object per line appended
//! to `events.jsonl` in the planning root: role boundaries, provider steps,
//! tool calls with their inputs, tool results with their outputs.
//!
//! Emission is fail-open by contract: the trace observes the run, it is not
//! part of it — an unwritable trace file never changes a turn or mission
//! outcome. Only OutOfMemory propagates (house rule); all IO errors are
//! swallowed at the seam. libc-backed like mission_store (Zig 0.16 moved
//! std.fs file IO behind std.Io, which stays out of worker modules per Z-02).

const std = @import("std");
const c = std.c;
const json = std.json;
const sync = @import("../kernel/sync.zig");
const trace_event = @import("trace_event.zig");

pub const TraceEvent = trace_event.TraceEvent;

pub const file_name = "events.jsonl";

/// In-process observer of the event stream (e.g. the mission TUI). The line
/// bytes are valid only for the duration of the call — sinks copy what they
/// keep. Callbacks run on whatever worker thread emitted the event and must
/// be fast and infallible (fail-open contract: a sink can't fail a run).
pub const Sink = struct {
    ctx: *anyopaque,
    onEvent: *const fn (ctx: *anyopaque, line_json: []const u8) void,
};

// Registry is process state, not per-run state, because the trace target
// travels across the bus as a path string inside request JSON — there is no
// object to hang a sink on. Registered once by the CLI before the mission,
// unregistered at teardown.
var sink_mutex: sync.Mutex = .{};
var sinks: [4]?Sink = .{ null, null, null, null };
var sink_count = std.atomic.Value(u8).init(0);

/// Returns a token for unregisterSink, or null when all slots are taken.
pub fn registerSink(s: Sink) ?usize {
    sink_mutex.lock();
    defer sink_mutex.unlock();
    for (&sinks, 0..) |*slot, i| {
        if (slot.* == null) {
            slot.* = s;
            _ = sink_count.fetchAdd(1, .release);
            return i;
        }
    }
    return null;
}

/// Idempotent. After return no further onEvent calls are made for this token
/// (delivery holds the same lock, so an in-flight callback finishes first).
pub fn unregisterSink(token: usize) void {
    sink_mutex.lock();
    defer sink_mutex.unlock();
    if (sinks[token] != null) {
        sinks[token] = null;
        _ = sink_count.fetchSub(1, .release);
    }
}

/// Cap for embedded payload fields (tool inputs/outputs, role content).
/// The full byte size rides alongside — the trace is a view, not an archive.
pub const max_field_bytes: usize = 2048;

/// Append one event line: `{"ts":<ms-epoch>,<body>}`. `body` is the caller's
/// pre-encoded JSON fields, no surrounding braces. The line also fans out to
/// registered sinks (without the trailing newline) — so a sink receives
/// events even when `path == null`; with no path and no sinks this is a
/// no-op, keeping call sites unconditional.
pub fn event(
    arena: std.mem.Allocator,
    path: ?[]const u8,
    comptime fmt: []const u8,
    args: anytype,
) error{OutOfMemory}!void {
    if (path == null and sink_count.load(.acquire) == 0) return;
    const body = try std.fmt.allocPrint(arena, fmt, args);
    const line = try std.fmt.allocPrint(arena, "{{\"ts\":{d},{s}}}\n", .{ nowMs(), body });
    if (path) |p| append(p, line);
    if (sink_count.load(.acquire) > 0) {
        sink_mutex.lock();
        defer sink_mutex.unlock();
        for (sinks) |maybe| {
            if (maybe) |s| s.onEvent(s.ctx, line[0 .. line.len - 1]);
        }
    }
}

/// Typed twin of `event` — the only emission path the drivers use. The
/// tagged union keeps emitters and consumers on one schema: adding a
/// variant breaks every exhaustive switch at compile time instead of
/// silently dropping on the floor.
pub fn emit(
    arena: std.mem.Allocator,
    path: ?[]const u8,
    ev: TraceEvent,
) error{OutOfMemory}!void {
    if (path == null and sink_count.load(.acquire) == 0) return;
    try event(arena, path, "{s}", .{try trace_event.body(arena, ev)});
}

/// Truncate a payload for embedding, cutting on a UTF-8 sequence boundary so
/// the JSON encoder never sees a split code point. Short inputs pass through
/// unchanged (no copy).
pub fn clip(arena: std.mem.Allocator, s: []const u8) error{OutOfMemory}![]const u8 {
    if (s.len <= max_field_bytes) return s;
    var end = max_field_bytes;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return std.fmt.allocPrint(arena, "{s}…[{d} bytes total]", .{ s[0..end], s.len });
}

/// One fwrite through append mode keeps concurrent emitters (turn driver +
/// mission driver threads) from interleaving mid-line.
fn append(path: []const u8, line: []const u8) void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return;
    const f = c.fopen(path_z, "a") orelse return;
    defer _ = c.fclose(f);
    _ = c.fwrite(line.ptr, 1, line.len, f);
}

/// Whole-file read for trace consumers (the CLI formatter, tests). Returns
/// null on any IO failure — the trace is advisory, absence is a valid state.
pub fn readFile(gpa: std.mem.Allocator, path: []const u8) ?[]u8 {
    const path_z = std.fmt.allocPrintSentinel(gpa, "{s}", .{path}, 0) catch return null;
    defer gpa.free(path_z);
    const f = c.fopen(path_z.ptr, "r") orelse return null;
    defer _ = c.fclose(f);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = c.fread(&chunk, 1, chunk.len, f);
        if (n == 0) break;
        buf.appendSlice(gpa, chunk[0..n]) catch return null;
    }
    return buf.toOwnedSlice(gpa) catch null;
}

/// Human view of an events.jsonl text (the `zygos mission trace` output).
/// Unknown or unparseable lines pass through raw — the renderer must never
/// hide evidence.
pub fn render(gpa: std.mem.Allocator, jsonl: []const u8) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, jsonl, "\n"), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        renderLine(arena, &out, gpa, line) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Unrenderable => {
                try out.appendSlice(gpa, line);
                try out.append(gpa, '\n');
            },
        };
        _ = arena_state.reset(.retain_capacity);
    }
    return out.toOwnedSlice(gpa);
}

fn renderLine(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    line: []const u8,
) error{ OutOfMemory, Unrenderable }!void {
    const parsed = trace_event.parse(arena, line) orelse return error.Unrenderable;

    var w: std.ArrayList(u8) = .empty;
    defer w.deinit(gpa);
    try appendClock(gpa, &w, parsed.ts);

    switch (parsed.event) {
        .mission => |m| {
            try appendFmt(gpa, &w, "mission {s} → {s}", .{ m.from, m.to });
            if (m.step_index) |idx| {
                try appendFmt(gpa, &w, " [step {s} #{d}]", .{ m.step orelse "-", idx });
            }
            try appendFmt(gpa, &w, " (role_turns {d}, tasks {d}/{d})", .{ m.role_turns, m.tasks_done, m.tasks });
        },
        .pipeline => |p| {
            try appendFmt(gpa, &w, "pipeline ({d} steps):", .{p.steps.len});
            for (p.steps) |st| {
                try appendFmt(gpa, &w, " {s}{s}", .{ st.id, if (st.tools) "+tools" else "" });
                if (st.definition_sha256) |h| try appendFmt(gpa, &w, "@{s}", .{h[0..@min(h.len, 8)]});
            }
        },
        .role_start => |r| try appendFmt(gpa, &w, "── role {s} (turn {d}, tools {s})", .{
            r.role, r.role_turn, if (r.tools) "on" else "off",
        }),
        .role_end => |r| {
            try appendFmt(gpa, &w, "── role {s}: {s}", .{ r.role, r.outcome });
            if (r.reason) |reason| try appendFmt(gpa, &w, " — {s}", .{reason});
        },
        .task_start => |t| try appendFmt(gpa, &w, "  ▸ task {d}/{d}: {s}", .{ t.index, t.total, t.desc }),
        .task_done => |t| try appendFmt(gpa, &w, "  ✓ task {d}/{d} done", .{ t.index, t.total }),
        .step => |s| {
            try appendFmt(gpa, &w, "  step {d}: {s} via {s}", .{ s.step, s.model, s.provider });
            if (s.attempt > 0) try appendFmt(gpa, &w, " (attempt {d})", .{s.attempt});
        },
        .tool_call => |tc| try appendFmt(gpa, &w, "    tool {s} {s}", .{ tc.tool, tc.input }),
        .tool_result => |tr| try appendFmt(gpa, &w, "      → {d}B{s}: {s}", .{
            tr.bytes, if (tr.is_error) " ERROR" else "", tr.output,
        }),
        .usage => |u| try appendFmt(gpa, &w, "    usage: {d}↑ {d}↓", .{ u.input_tokens, u.output_tokens }),
        .steer => |s| try appendFmt(gpa, &w, "  ⚑ steer: {s}", .{s.text}),
        .turn_end => |te| {
            try appendFmt(gpa, &w, "  turn end: {s} ({d} steps)", .{ te.stop, te.steps });
            if (te.err) |e| try appendFmt(gpa, &w, " — {s}", .{e});
        },
    }

    try w.append(gpa, '\n');
    try out.appendSlice(gpa, w.items);
}

fn appendFmt(gpa: std.mem.Allocator, w: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
    const s = try std.fmt.allocPrint(gpa, fmt, args);
    defer gpa.free(s);
    try w.appendSlice(gpa, s);
}

fn appendClock(gpa: std.mem.Allocator, w: *std.ArrayList(u8), ts_ms: i64) error{OutOfMemory}!void {
    const secs: u64 = @intCast(@max(0, @divTrunc(ts_ms, 1000)));
    const ep: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const ds = ep.getDaySeconds();
    try appendFmt(gpa, w, "{d:0>2}:{d:0>2}:{d:0>2} ", .{
        ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    });
}

fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

extern "c" fn realpath(path: [*:0]const u8, resolved: [*]u8) ?[*:0]u8;

test "event appends one parseable JSON line per call, with ts and caller fields" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    var rel_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rel = try std.fmt.bufPrintZ(&rel_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const dir = std.mem.span(realpath(rel, &dir_buf) orelse return error.RealpathFailed);
    const path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, file_name });

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try event(arena, path, "\"event\":\"step\",\"step\":{d}", .{1});
    try event(arena, path, "\"event\":\"tool_call\",\"tool\":{f}", .{json.fmt("bash", .{})});

    const text = readFile(arena, path) orelse return error.ReadFailed;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    var n: usize = 0;
    while (lines.next()) |line| : (n += 1) {
        const v = try json.parseFromSliceLeaky(json.Value, arena, line, .{});
        try testing.expect(v == .object);
        try testing.expect(v.object.get("ts").? == .integer);
        try testing.expect(v.object.get("event").? == .string);
    }
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expect(std.mem.indexOf(u8, text, "\"tool\":\"bash\"") != null);
}

test "event with a null path is a no-op; an unwritable path is swallowed (fail open)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try event(arena, null, "\"event\":\"step\"", .{});
    try event(arena, "/nonexistent-zygos-dir/events.jsonl", "\"event\":\"step\"", .{});
}

test "render pretty-prints every event kind and passes unknown lines through raw" {
    const jsonl =
        \\{"ts":1752199999000,"event":"pipeline","steps":[{"id":"architect","definition_sha256":"0123456789abcdef","tools":true},{"id":"executor","definition_sha256":null,"tools":false}]}
        \\{"ts":1752200000000,"event":"mission","from":"running","to":"running","step":"executor","step_index":1,"role_turns":1,"tasks_done":0,"tasks":6}
        \\{"ts":1752200000500,"event":"mission","from":"running","to":"gating","step":null,"step_index":2,"role_turns":1,"tasks_done":0,"tasks":6}
        \\{"ts":1752200001000,"event":"role_start","role":"executor","role_turn":3,"tools":true,"content":"Objective: ship"}
        \\{"ts":1752200001500,"event":"task_start","index":2,"total":6,"desc":"implement the lexer"}
        \\{"ts":1752200001700,"event":"task_done","index":2,"total":6,"desc":"implement the lexer"}
        \\{"ts":1752200002000,"event":"step","turn_id":"","step":1,"provider":"zygos::providers::glm-5-2","model":"glm-5.2","attempt":0}
        \\{"ts":1752200003000,"event":"tool_call","turn_id":"","step":1,"tool":"web_search","input":"{\"query\":\"zig allocators\"}"}
        \\{"ts":1752200004000,"event":"tool_result","step":1,"tool":"web_search","is_error":false,"bytes":5120,"output":"[{\"title\":\"Zig\"}]"}
        \\{"ts":1752200004500,"event":"usage","turn_id":"","step":1,"input_tokens":12400,"output_tokens":3100}
        \\{"ts":1752200005000,"event":"turn_end","turn_id":"","stop":"max_steps","steps":24}
        \\{"ts":1752200006000,"event":"role_end","role":"executor","outcome":"failed","reason":"executor turn stopped: max_steps"}
        \\not-json garbage line
    ;
    const out = try render(testing.allocator, jsonl);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "pipeline (2 steps): architect+tools@01234567 executor") != null);
    try testing.expect(std.mem.indexOf(u8, out, "mission running → running [step executor #1]") != null);
    try testing.expect(std.mem.indexOf(u8, out, "mission running → gating [step - #2]") != null);
    try testing.expect(std.mem.indexOf(u8, out, "role executor") != null);
    try testing.expect(std.mem.indexOf(u8, out, "glm-5.2") != null);
    try testing.expect(std.mem.indexOf(u8, out, "zygos::providers::glm-5-2") != null);
    try testing.expect(std.mem.indexOf(u8, out, "web_search") != null);
    try testing.expect(std.mem.indexOf(u8, out, "zig allocators") != null); // tool input visible
    try testing.expect(std.mem.indexOf(u8, out, "5120B") != null);
    try testing.expect(std.mem.indexOf(u8, out, "12400↑ 3100↓") != null);
    try testing.expect(std.mem.indexOf(u8, out, "title") != null); // tool output visible
    try testing.expect(std.mem.indexOf(u8, out, "max_steps") != null);
    try testing.expect(std.mem.indexOf(u8, out, "failed") != null);
    try testing.expect(std.mem.indexOf(u8, out, "not-json garbage line") != null);
    try testing.expect(std.mem.indexOf(u8, out, "▸ task 2/6: implement the lexer") != null);
    try testing.expect(std.mem.indexOf(u8, out, "✓ task 2/6 done") != null);
    // Timestamps render as wall clock, one per line.
    try testing.expect(std.mem.indexOf(u8, out, "02:13:20") != null); // 1752200000 UTC
}

const SinkCapture = struct {
    mutex: sync.Mutex = .{},
    lines: std.ArrayList([]u8) = .empty,
    gpa: std.mem.Allocator,

    fn onEvent(ctx: *anyopaque, line_json: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        const copy = self.gpa.dupe(u8, line_json) catch return;
        self.lines.append(self.gpa, copy) catch self.gpa.free(copy);
    }

    fn sink(self: *@This()) Sink {
        return .{ .ctx = @ptrCast(self), .onEvent = &onEvent };
    }

    fn deinit(self: *@This()) void {
        for (self.lines.items) |l| self.gpa.free(l);
        self.lines.deinit(self.gpa);
    }
};

test "a registered sink receives every event line even with a null path" {
    var cap = SinkCapture{ .gpa = testing.allocator };
    defer cap.deinit();
    const token = registerSink(cap.sink()) orelse return error.NoSlot;
    defer unregisterSink(token);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try event(arena, null, "\"event\":\"step\",\"step\":{d}", .{7});
    try event(arena, null, "\"event\":\"turn_end\",\"steps\":{d}", .{3});

    try testing.expectEqual(@as(usize, 2), cap.lines.items.len);
    // Delivered without the trailing newline, parseable, ts present.
    for (cap.lines.items) |line| {
        try testing.expect(!std.mem.endsWith(u8, line, "\n"));
        const v = try json.parseFromSliceLeaky(json.Value, arena, line, .{});
        try testing.expect(v.object.get("ts").? == .integer);
    }
    try testing.expect(std.mem.indexOf(u8, cap.lines.items[0], "\"step\":7") != null);
}

test "sink and file both receive when a path is set" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    var rel_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rel = try std.fmt.bufPrintZ(&rel_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const dir = std.mem.span(realpath(rel, &dir_buf) orelse return error.RealpathFailed);
    const path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, file_name });

    var cap = SinkCapture{ .gpa = testing.allocator };
    defer cap.deinit();
    const token = registerSink(cap.sink()) orelse return error.NoSlot;
    defer unregisterSink(token);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try event(arena, path, "\"event\":\"step\",\"step\":{d}", .{1});
    try testing.expectEqual(@as(usize, 1), cap.lines.items.len);
    const text = readFile(arena, path) orelse return error.ReadFailed;
    try testing.expect(std.mem.indexOf(u8, text, "\"step\":1") != null);
}

test "emit delivers the typed event through the same line path" {
    var cap = SinkCapture{ .gpa = testing.allocator };
    defer cap.deinit();
    const token = registerSink(cap.sink()) orelse return error.NoSlot;
    defer unregisterSink(token);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try emit(arena_state.allocator(), null, .{ .step = .{
        .turn_id = "t",
        .step = 1,
        .provider = "p",
        .model = "m",
    } });

    try testing.expectEqual(@as(usize, 1), cap.lines.items.len);
    try testing.expect(std.mem.indexOf(u8, cap.lines.items[0], "\"event\":\"step\"") != null);
    try testing.expect(std.mem.indexOf(u8, cap.lines.items[0], "\"model\":\"m\"") != null);
}

test "unregister stops delivery and slots are reusable" {
    var cap = SinkCapture{ .gpa = testing.allocator };
    defer cap.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const token = registerSink(cap.sink()) orelse return error.NoSlot;
    unregisterSink(token);
    unregisterSink(token); // idempotent
    try event(arena, null, "\"event\":\"step\"", .{});
    try testing.expectEqual(@as(usize, 0), cap.lines.items.len);

    const token2 = registerSink(cap.sink()) orelse return error.NoSlot;
    defer unregisterSink(token2);
    try event(arena, null, "\"event\":\"step\"", .{});
    try testing.expectEqual(@as(usize, 1), cap.lines.items.len);
}

test "two sinks both receive each event" {
    var a = SinkCapture{ .gpa = testing.allocator };
    defer a.deinit();
    var b = SinkCapture{ .gpa = testing.allocator };
    defer b.deinit();
    const ta = registerSink(a.sink()) orelse return error.NoSlot;
    defer unregisterSink(ta);
    const tb = registerSink(b.sink()) orelse return error.NoSlot;
    defer unregisterSink(tb);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try event(arena_state.allocator(), null, "\"event\":\"step\"", .{});
    try testing.expectEqual(@as(usize, 1), a.lines.items.len);
    try testing.expectEqual(@as(usize, 1), b.lines.items.len);
}

test "concurrent event emission delivers whole parseable lines to the sink" {
    var cap = SinkCapture{ .gpa = testing.allocator };
    defer cap.deinit();
    const token = registerSink(cap.sink()) orelse return error.NoSlot;
    defer unregisterSink(token);

    const emitter = struct {
        fn run(id: usize) void {
            var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena_state.deinit();
            var i: usize = 0;
            while (i < 50) : (i += 1) {
                event(arena_state.allocator(), null, "\"event\":\"step\",\"step\":{d},\"emitter\":{d}", .{ i, id }) catch return;
            }
        }
    };
    const t1 = try std.Thread.spawn(.{}, emitter.run, .{1});
    const t2 = try std.Thread.spawn(.{}, emitter.run, .{2});
    t1.join();
    t2.join();

    try testing.expectEqual(@as(usize, 100), cap.lines.items.len);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    for (cap.lines.items) |line| {
        const v = try json.parseFromSliceLeaky(json.Value, arena_state.allocator(), line, .{});
        try testing.expect(v == .object);
    }
}

test "clip passes short strings through untouched" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s = "short output";
    try testing.expectEqualStrings(s, try clip(arena, s));
}

test "clip caps oversized payloads on a UTF-8 boundary and records the full size" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A 3-byte code point straddles the cap: the cut must back up past it.
    var big: std.ArrayList(u8) = .empty;
    try big.appendNTimes(arena, 'a', max_field_bytes - 1);
    try big.appendSlice(arena, "→→→"); // 9 bytes, first '→' spans the boundary
    const clipped = try clip(arena, big.items);

    try testing.expect(std.unicode.utf8ValidateSlice(clipped));
    const suffix = try std.fmt.allocPrint(arena, "[{d} bytes total]", .{big.items.len});
    try testing.expect(std.mem.endsWith(u8, clipped, suffix));
    // Nothing of the split code point survives before the marker.
    try testing.expectEqual(@as(usize, max_field_bytes - 1), std.mem.indexOf(u8, clipped, "…").?);
}
