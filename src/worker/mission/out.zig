//! Pure output shaping for the mission orchestrator: provider text
//! extraction, fence unwrapping, task-outcome excerpts, and the terminal /
//! parked reply payloads. No bus, no store, no orchestrator state — every
//! function is arena-in, slice-out (or fully pure).

const std = @import("std");
const json = std.json;
const jsonx = @import("../jsonx.zig");
const model = @import("model.zig");

const Mission = model.Mission;

pub const assistantText = jsonx.assistantText;

/// Real providers wrap role JSON in one whole-output markdown fence.
/// Unwrapping exactly that shape is deterministic — anything else is
/// returned untouched and must still parse as strict JSON (fail closed).
pub fn unwrapFence(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "```")) return trimmed;
    if (!std.mem.endsWith(u8, trimmed, "```")) return trimmed;
    const open_end = std.mem.indexOfScalar(u8, trimmed, '\n') orelse return trimmed;
    if (trimmed.len < open_end + 1 + 3) return trimmed;
    return std.mem.trim(u8, trimmed[open_end + 1 .. trimmed.len - 3], " \t\r\n");
}

/// Excerpt of a task outcome carried into later executor turns. Cuts on a
/// UTF-8 boundary, prefers a word break past max/2, appends an ellipsis.
pub fn outcomeExcerpt(arena: std.mem.Allocator, text: []const u8, max: usize) error{OutOfMemory}![]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len <= max) return arena.dupe(u8, trimmed);
    var end = max;
    while (end > 0 and (trimmed[end] & 0xC0) == 0x80) end -= 1;
    if (std.mem.lastIndexOfScalar(u8, trimmed[0..end], ' ')) |sp| {
        if (sp > max / 2) end = sp;
    }
    return std.fmt.allocPrint(arena, "{s}…", .{std.mem.trimEnd(u8, trimmed[0..end], " \t\r\n")});
}

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
    try testing.expectEqualStrings("ab", try assistantText(arena, msg));
}

test "assistantText: string content passes through; missing content is empty" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("hi", try assistantText(arena, try parseObj(arena,
        \\{"content":"hi"}
    )));
    try testing.expectEqualStrings("", try assistantText(arena, try parseObj(arena,
        \\{"role":"assistant"}
    )));
}

test "unwrapFence: whole-output fence with and without a language tag" {
    try testing.expectEqualStrings("{\"a\":1}", unwrapFence("```json\n{\"a\":1}\n```"));
    try testing.expectEqualStrings("{\"a\":1}", unwrapFence("```\n{\"a\":1}\n```"));
    try testing.expectEqualStrings("{\"a\":1}", unwrapFence("  ```json\n{\"a\":1}\n```  \n"));
}

test "unwrapFence: anything but exactly one whole-output fence is untouched" {
    try testing.expectEqualStrings("{\"a\":1}", unwrapFence(" {\"a\":1} "));
    try testing.expectEqualStrings("```{\"a\":1}```", unwrapFence("```{\"a\":1}```"));
    try testing.expectEqualStrings("pre ```json\n{}\n```", unwrapFence("pre ```json\n{}\n```"));
}

test "outcomeExcerpt: short text is duped verbatim, long text cuts on a word" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("done", try outcomeExcerpt(arena, "  done \n", 10));
    const cut = try outcomeExcerpt(arena, "alpha beta gamma delta", 12);
    try testing.expectEqualStrings("alpha beta…", cut);
}

test "outcomeExcerpt: never cuts inside a UTF-8 sequence" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // "ééééé" is 10 bytes; max 9 lands mid-codepoint and must back up.
    const cut = try outcomeExcerpt(arena, "ééééé", 9);
    try testing.expect(std.unicode.utf8ValidateSlice(cut));
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
