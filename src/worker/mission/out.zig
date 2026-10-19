//! Reply payloads (terminal, parked, status) and the start-of-mission
//! trace event for the mission orchestrator.
//! Role-turn fence unwrapping and excerpts live in role_turn.zig.
//! No bus, no store, no orchestrator state.

const std = @import("std");
const json = std.json;
const jsonx = @import("../jsonx.zig");
const model = @import("model.zig");
const pipeline = @import("pipeline.zig");
const registry = @import("registry.zig");
const TraceEvent = @import("../trace_event.zig").TraceEvent;

const Mission = model.Mission;

/// `state` stays the first key: eval tooling finds the reply by the
/// `{"state"` prefix. `step` is null (and `step_index` the list length) at
/// gating and done; a failed mission keeps the step that failed.
pub fn replyTerminal(arena: std.mem.Allocator, m: *const Mission) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "{{\"state\":\"{t}\",\"step\":{f},\"step_index\":{d},\"stop\":\"{t}\",\"detail\":{f}," ++
            "\"role_turns\":{d},\"tasks_done\":{d}}}",
        .{
            m.state,                 json.fmt(m.stepId(), .{}),
            m.cursor(),              m.stop,
            json.fmt(m.detail, .{}), m.role_turns_used,
            m.tasksDone(),
        },
    );
}

/// Parked, not terminal: state is on disk, resume completes it.
pub fn replyParked(arena: std.mem.Allocator, m: *const Mission) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "{{\"state\":\"{t}\",\"step\":{f},\"step_index\":{d},\"stop\":\"{t}\",\"paused\":true," ++
            "\"role_turns\":{d},\"tasks_done\":{d}}}",
        .{ m.state, json.fmt(m.stepId(), .{}), m.cursor(), m.stop, m.role_turns_used, m.tasksDone() },
    );
}

/// `zygos::missions::status` payload from a live control snapshot.
pub fn replyStatus(arena: std.mem.Allocator, snap: registry.Snapshot) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "{{\"state\":\"{t}\",\"step\":{f},\"step_index\":{d},\"stop\":\"{t}\",\"role_turns\":{d}," ++
            "\"task_index\":{d},\"fail_count\":{d},\"gate_denials\":{d}}}",
        .{
            snap.state,           json.fmt(snap.step, .{}), snap.step_index, snap.stop,
            snap.role_turns_used, snap.task_index,          snap.fail_count, snap.gate_denials,
        },
    );
}

/// The mission-start `pipeline` trace event for a pinned pipeline.
pub fn pipelineEvent(arena: std.mem.Allocator, steps: []const pipeline.Step) error{OutOfMemory}!TraceEvent {
    const out = try arena.alloc(TraceEvent.PipelineStep, steps.len);
    for (steps, out) |st, *o| o.* = .{ .id = st.id, .definition_sha256 = st.definition_sha256, .tools = st.tools };
    return .{ .pipeline = .{ .steps = out } };
}

/// The `policy` trace event for the start request's policy record, written
/// right after `pipeline`. The driver passes the record through verbatim.
pub fn policyEvent(policy: TraceEvent.Policy) TraceEvent {
    return .{ .policy = policy };
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
    var m: Mission = .{
        .mission_id = "m1",
        .state = .done,
        .stop = .completed,
        .detail = "ok",
        .pipeline = &pipeline.default_pipeline,
        .step_index = 4,
    };
    try testing.expectEqualStrings(
        "{\"state\":\"done\",\"step\":null,\"step_index\":4,\"stop\":\"completed\",\"detail\":\"ok\",\"role_turns\":0,\"tasks_done\":0}",
        try replyTerminal(arena, &m),
    );
    m.state = .gating;
    try testing.expectEqualStrings(
        "{\"state\":\"gating\",\"step\":null,\"step_index\":4,\"stop\":\"completed\",\"paused\":true,\"role_turns\":0,\"tasks_done\":0}",
        try replyParked(arena, &m),
    );
    // Parked mid-pipeline: the cursor names the step the resume continues at.
    m.state = .running;
    m.step_index = 2;
    try testing.expectEqualStrings(
        "{\"state\":\"running\",\"step\":\"executor\",\"step_index\":2,\"stop\":\"completed\",\"paused\":true,\"role_turns\":0,\"tasks_done\":0}",
        try replyParked(arena, &m),
    );
}

test "replyTerminal: a failed mission keeps the step that failed; state stays the first key" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const m: Mission = .{
        .mission_id = "m1",
        .state = .failed,
        .stop = .role_failed,
        .detail = "empty reply",
        .pipeline = &pipeline.default_pipeline,
        .step_index = 1,
    };
    const reply = try replyTerminal(arena, &m);
    try testing.expect(std.mem.startsWith(u8, reply, "{\"state\":\"failed\","));
    try testing.expectEqualStrings(
        "{\"state\":\"failed\",\"step\":\"planner\",\"step_index\":1,\"stop\":\"role_failed\",\"detail\":\"empty reply\",\"role_turns\":0,\"tasks_done\":0}",
        reply,
    );
    // A gate failure sits past the last step: no step to keep.
    const gate_failed: Mission = .{
        .mission_id = "m1",
        .state = .failed,
        .stop = .gate_failed,
        .pipeline = &pipeline.default_pipeline,
        .step_index = 4,
    };
    try testing.expect(std.mem.indexOf(u8, try replyTerminal(arena, &gate_failed), "\"step\":null,\"step_index\":4") != null);
}

test "replyStatus: the five-key cursor plus counters" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings(
        "{\"state\":\"running\",\"step\":\"executor\",\"step_index\":2,\"stop\":\"none\",\"role_turns\":3,\"task_index\":1,\"fail_count\":0,\"gate_denials\":0}",
        try replyStatus(arena, .{
            .state = .running,
            .stop = .none,
            .paused = false,
            .step = "executor",
            .step_index = 2,
            .task_index = 1,
            .fail_count = 0,
            .gate_denials = 0,
            .role_turns_used = 3,
        }),
    );
}

test "pipelineEvent lists id, hash and tools for every step" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const steps = [_]pipeline.Step{
        .{ .id = "architect", .kind = .custom, .system = "x", .definition_sha256 = "ab", .tools = true },
        .{ .id = "executor", .kind = .executor, .system = null, .definition_sha256 = null, .tools = true },
    };
    const ev = try pipelineEvent(arena, &steps);
    try testing.expectEqual(@as(usize, 2), ev.pipeline.steps.len);
    try testing.expectEqualStrings("architect", ev.pipeline.steps[0].id);
    try testing.expectEqualStrings("ab", ev.pipeline.steps[0].definition_sha256.?);
    try testing.expect(ev.pipeline.steps[0].tools);
    try testing.expect(ev.pipeline.steps[1].definition_sha256 == null);
}

test "policyEvent carries source and rules through unchanged" {
    const rules = [_]TraceEvent.PolicyRule{
        .{ .tool = "bash", .verdict = "deny", .step = "architect" },
        .{ .tool = "bash", .verdict = "allow" },
    };
    const ev = policyEvent(.{ .source = "config", .rules = &rules });
    try testing.expectEqualStrings("config", ev.policy.source);
    try testing.expectEqual(@as(usize, 2), ev.policy.rules.len);
    try testing.expectEqualStrings("architect", ev.policy.rules[0].step.?);
    try testing.expect(ev.policy.rules[1].step == null);
}

test "nowStamp: fixed shape YYYY-MM-DD HH:MM" {
    const s = nowStamp();
    try testing.expectEqual(@as(usize, 16), s.len);
    try testing.expectEqual(@as(u8, '-'), s[4]);
    try testing.expectEqual(@as(u8, '-'), s[7]);
    try testing.expectEqual(@as(u8, ' '), s[10]);
    try testing.expectEqual(@as(u8, ':'), s[13]);
}
