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

pub const file_name = "events.jsonl";

/// Cap for embedded payload fields (tool inputs/outputs, role content).
/// The full byte size rides alongside — the trace is a view, not an archive.
pub const max_field_bytes: usize = 2048;

/// Append one event line: `{"ts":<ms-epoch>,<body>}`. `body` is the caller's
/// pre-encoded JSON fields, no surrounding braces. `path == null` is a no-op
/// so call sites stay unconditional.
pub fn event(
    arena: std.mem.Allocator,
    path: ?[]const u8,
    comptime fmt: []const u8,
    args: anytype,
) error{OutOfMemory}!void {
    const p = path orelse return;
    const body = try std.fmt.allocPrint(arena, fmt, args);
    const line = try std.fmt.allocPrint(arena, "{{\"ts\":{d},{s}}}\n", .{ nowMs(), body });
    append(p, line);
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
    const v = json.parseFromSliceLeaky(json.Value, arena, line, .{}) catch return error.Unrenderable;
    if (v != .object) return error.Unrenderable;
    const obj = v.object;
    const ev = str(obj, "event") orelse return error.Unrenderable;

    var w: std.ArrayList(u8) = .empty;
    defer w.deinit(gpa);
    const ts = if (obj.get("ts")) |t| (if (t == .integer) t.integer else 0) else 0;
    try appendClock(gpa, &w, ts);

    if (std.mem.eql(u8, ev, "mission")) {
        try appendFmt(gpa, &w, "mission {s} → {s} (role_turns {d}, tasks {d}/{d})", .{
            str(obj, "from") orelse "?", str(obj, "to") orelse "?", int(obj, "role_turns"),
            int(obj, "tasks_done"),      int(obj, "tasks"),
        });
    } else if (std.mem.eql(u8, ev, "role_start")) {
        try appendFmt(gpa, &w, "── role {s} (turn {d}, tools {s})", .{
            str(obj, "role") orelse "?",
            int(obj, "role_turn"),
            if (boolOf(obj, "tools")) "on" else "off",
        });
    } else if (std.mem.eql(u8, ev, "role_end")) {
        try appendFmt(gpa, &w, "── role {s}: {s}", .{ str(obj, "role") orelse "?", str(obj, "outcome") orelse "?" });
        if (str(obj, "reason")) |r| try appendFmt(gpa, &w, " — {s}", .{r});
    } else if (std.mem.eql(u8, ev, "step")) {
        try appendFmt(gpa, &w, "  step {d}: {s} via {s}", .{
            int(obj, "step"), str(obj, "model") orelse "?", str(obj, "provider") orelse "?",
        });
        const attempt = int(obj, "attempt");
        if (attempt > 0) try appendFmt(gpa, &w, " (attempt {d})", .{attempt});
    } else if (std.mem.eql(u8, ev, "tool_call")) {
        try appendFmt(gpa, &w, "    tool {s} {s}", .{ str(obj, "tool") orelse "?", str(obj, "input") orelse "" });
    } else if (std.mem.eql(u8, ev, "tool_result")) {
        try appendFmt(gpa, &w, "      → {d}B{s}: {s}", .{
            int(obj, "bytes"),
            if (boolOf(obj, "is_error")) " ERROR" else "",
            str(obj, "output") orelse "",
        });
    } else if (std.mem.eql(u8, ev, "turn_end")) {
        try appendFmt(gpa, &w, "  turn end: {s} ({d} steps)", .{ str(obj, "stop") orelse "?", int(obj, "steps") });
        if (str(obj, "error")) |e| try appendFmt(gpa, &w, " — {s}", .{e});
    } else return error.Unrenderable;

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
        \\{"ts":1752200000000,"event":"mission","from":"defining","to":"planning","role_turns":1,"tasks_done":0,"tasks":6}
        \\{"ts":1752200001000,"event":"role_start","role":"executor","role_turn":3,"tools":true,"content":"Objective: ship"}
        \\{"ts":1752200002000,"event":"step","turn_id":"","step":1,"provider":"zygos::providers::glm-5-2","model":"glm-5.2","attempt":0}
        \\{"ts":1752200003000,"event":"tool_call","turn_id":"","step":1,"tool":"web_search","input":"{\"query\":\"zig allocators\"}"}
        \\{"ts":1752200004000,"event":"tool_result","step":1,"tool":"web_search","is_error":false,"bytes":5120,"output":"[{\"title\":\"Zig\"}]"}
        \\{"ts":1752200005000,"event":"turn_end","turn_id":"","stop":"max_steps","steps":24}
        \\{"ts":1752200006000,"event":"role_end","role":"executor","outcome":"failed","reason":"executor turn stopped: max_steps"}
        \\not-json garbage line
    ;
    const out = try render(testing.allocator, jsonl);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "mission defining → planning") != null);
    try testing.expect(std.mem.indexOf(u8, out, "role executor") != null);
    try testing.expect(std.mem.indexOf(u8, out, "glm-5.2") != null);
    try testing.expect(std.mem.indexOf(u8, out, "zygos::providers::glm-5-2") != null);
    try testing.expect(std.mem.indexOf(u8, out, "web_search") != null);
    try testing.expect(std.mem.indexOf(u8, out, "zig allocators") != null); // tool input visible
    try testing.expect(std.mem.indexOf(u8, out, "5120B") != null);
    try testing.expect(std.mem.indexOf(u8, out, "title") != null); // tool output visible
    try testing.expect(std.mem.indexOf(u8, out, "max_steps") != null);
    try testing.expect(std.mem.indexOf(u8, out, "failed") != null);
    try testing.expect(std.mem.indexOf(u8, out, "not-json garbage line") != null);
    // Timestamps render as wall clock, one per line.
    try testing.expect(std.mem.indexOf(u8, out, "02:13:20") != null); // 1752200000 UTC
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
