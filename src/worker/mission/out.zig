//! Terminal and parked reply payloads for the mission orchestrator.
//! Role-turn fence unwrapping and excerpts live in role_turn.zig.
//! No bus, no store, no orchestrator state.

const std = @import("std");
const json = std.json;
const jsonx = @import("../jsonx.zig");
const model = @import("model.zig");

const Mission = model.Mission;

pub fn replyTerminal(arena: std.mem.Allocator, m: *const Mission) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "{{\"state\":\"{t}\",\"stop\":\"{t}\",\"detail\":{f},\"role_turns\":{d},\"tasks_done\":{d}}}",
        .{ m.state, m.stop, json.fmt(m.detail, .{}), m.role_turns_used, m.tasksDone() },
    );
}

/// Parked, not terminal: state is on disk, resume completes it.
pub fn replyParked(arena: std.mem.Allocator, m: *const Mission) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "{{\"state\":\"{t}\",\"stop\":\"{t}\",\"paused\":true,\"role_turns\":{d},\"tasks_done\":{d}}}",
        .{ m.state, m.stop, m.role_turns_used, m.tasksDone() },
    );
}

/// Wall-clock "YYYY-MM-DD HH:MM" (UTC). Continuity stamps are advisory
/// prose, not ordering keys, so UTC without a zone suffix is acceptable.
pub fn nowStamp() [16]u8 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    const secs: u64 = @intCast(@max(0, ts.sec));
    const ep: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const yd = ep.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = ep.getDaySeconds();
    var out: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(),
    }) catch unreachable;
    return out;
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

fn parseObj(arena: std.mem.Allocator, s: []const u8) !json.ObjectMap {
    const v = try json.parseFromSliceLeaky(json.Value, arena, s, .{});
    return v.object;
}

test "assistantText: concatenates text blocks, skips non-text" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const msg = try parseObj(arena,
        \\{"content":[{"type":"text","text":"a"},{"type":"tool_use","id":"x"},{"type":"text","text":"b"}]}
    );
    try testing.expectEqualStrings("ab", try jsonx.assistantText(arena, msg));
}

test "assistantText: string content passes through; missing content is empty" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("hi", try jsonx.assistantText(arena, try parseObj(arena,
        \\{"content":"hi"}
    )));
    try testing.expectEqualStrings("", try jsonx.assistantText(arena, try parseObj(arena,
        \\{"role":"assistant"}
    )));
}

test "replyTerminal and replyParked shape" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var m: Mission = .{ .mission_id = "m1", .state = .done, .stop = .completed, .detail = "ok" };
    try testing.expectEqualStrings(
        "{\"state\":\"done\",\"stop\":\"completed\",\"detail\":\"ok\",\"role_turns\":0,\"tasks_done\":0}",
        try replyTerminal(arena, &m),
    );
    m.state = .gating;
    try testing.expectEqualStrings(
        "{\"state\":\"gating\",\"stop\":\"completed\",\"paused\":true,\"role_turns\":0,\"tasks_done\":0}",
        try replyParked(arena, &m),
    );
}

test "nowStamp: fixed shape YYYY-MM-DD HH:MM" {
    const s = nowStamp();
    try testing.expectEqual(@as(usize, 16), s.len);
    try testing.expectEqual(@as(u8, '-'), s[4]);
    try testing.expectEqual(@as(u8, '-'), s[7]);
    try testing.expectEqual(@as(u8, ' '), s[10]);
    try testing.expectEqual(@as(u8, ':'), s[13]);
}
