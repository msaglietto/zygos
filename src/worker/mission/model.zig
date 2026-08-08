//! Mission data model: the durable record the orchestrator mutates and
//! mission_store persists, plus the role identity used for provider routing.
//! Pure data — no bus, no store, no provider knowledge.

const std = @import("std");
const fsm = @import("fsm.zig");

pub const State = fsm.State;

pub const StopReason = enum {
    none,
    completed,
    aborted,
    escalated,
    gate_failed,
    role_failed,
    role_turns_exhausted,
};

pub const Task = struct {
    desc: []const u8,
    done: bool = false,
    /// Excerpt of the executor's answer for this task — carried into later
    /// executor turns so they stop re-discovering finished work. In-memory
    /// only (not persisted); a resumed mission sees [done] without it.
    result: []const u8 = "",
};

/// All slices are owned by whoever built the Mission: the driver builds one
/// in a handler arena (no frees); `mission_store.load` builds a gpa-owned one
/// that must be released with `deinit`.
pub const Mission = struct {
    mission_id: []const u8,
    state: State = .defining,
    stop: StopReason = .none,
    detail: []const u8 = "",
    objective: []const u8 = "",
    acceptance: []const u8 = "",
    feedback: []const u8 = "",
    /// M6 operator steer riding the next role turn. In-memory only (a
    /// parked mission does not carry a pending steer across resume).
    steer: []const u8 = "",
    tasks: []Task = &.{},
    task_index: usize = 0,
    fail_count: usize = 0,
    /// Step-budget exhaustions on the current task (executor retries);
    /// separate from fail_count so verify's "consecutive failures"
    /// escalation semantics stay untouched. Reset when a task completes.
    exec_fail_count: usize = 0,
    gate_denials: usize = 0,
    role_turns_used: usize = 0,

    /// Only for gpa-owned missions (mission_store.load).
    pub fn deinit(self: *Mission, gpa: std.mem.Allocator) void {
        gpa.free(self.mission_id);
        gpa.free(self.detail);
        gpa.free(self.objective);
        gpa.free(self.acceptance);
        gpa.free(self.feedback);
        for (self.tasks) |t| gpa.free(t.desc);
        gpa.free(self.tasks);
    }

    pub fn tasksDone(self: *const Mission) usize {
        var n: usize = 0;
        for (self.tasks) |t| {
            if (t.done) n += 1;
        }
        return n;
    }
};

pub const Role = enum {
    product_owner,
    planner,
    executor,
    verifier,

    /// The routing key: `zygos.zon` pins each role to its own provider/model.
    pub fn stepId(self: Role) []const u8 {
        return switch (self) {
            .product_owner => "product-owner",
            .planner => "planner",
            .executor => "executor",
            .verifier => "verifier",
        };
    }
};

/// Snapshot a mission into an arena (status/list read a copy, never the live
/// record). Task results and steer are in-memory-only and are not carried.
pub fn cloneToArena(arena: std.mem.Allocator, m: *const Mission) error{OutOfMemory}!Mission {
    const tasks = try arena.alloc(Task, m.tasks.len);
    for (m.tasks, 0..) |t, i| {
        tasks[i] = .{ .desc = try arena.dupe(u8, t.desc), .done = t.done };
    }
    return .{
        .mission_id = try arena.dupe(u8, m.mission_id),
        .state = m.state,
        .stop = m.stop,
        .detail = try arena.dupe(u8, m.detail),
        .objective = try arena.dupe(u8, m.objective),
        .acceptance = try arena.dupe(u8, m.acceptance),
        .feedback = try arena.dupe(u8, m.feedback),
        .tasks = tasks,
        .task_index = m.task_index,
        .fail_count = m.fail_count,
        .exec_fail_count = m.exec_fail_count,
        .gate_denials = m.gate_denials,
        .role_turns_used = m.role_turns_used,
    };
}

const testing = std.testing;

test "tasksDone counts only completed tasks" {
    var tasks = [_]Task{
        .{ .desc = "a", .done = true },
        .{ .desc = "b" },
        .{ .desc = "c", .done = true },
    };
    const m: Mission = .{ .mission_id = "m-1", .tasks = &tasks };
    try testing.expectEqual(@as(usize, 2), m.tasksDone());
}

test "cloneToArena copies every persisted field and detaches ownership" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tasks = [_]Task{.{ .desc = "t0", .done = true, .result = "in-memory" }};
    const src: Mission = .{
        .mission_id = "m-42",
        .state = .executing,
        .stop = .none,
        .detail = "d",
        .objective = "o",
        .acceptance = "a",
        .feedback = "f",
        .steer = "steer",
        .tasks = &tasks,
        .task_index = 1,
        .fail_count = 2,
        .exec_fail_count = 3,
        .gate_denials = 4,
        .role_turns_used = 5,
    };
    const c = try cloneToArena(arena_state.allocator(), &src);
    try testing.expectEqualStrings("m-42", c.mission_id);
    try testing.expect(c.mission_id.ptr != src.mission_id.ptr);
    try testing.expectEqual(State.executing, c.state);
    try testing.expectEqualStrings("t0", c.tasks[0].desc);
    try testing.expect(c.tasks[0].done);
    // In-memory-only fields do not travel with the snapshot.
    try testing.expectEqualStrings("", c.tasks[0].result);
    try testing.expectEqualStrings("", c.steer);
    try testing.expectEqual(@as(usize, 1), c.task_index);
    try testing.expectEqual(@as(usize, 2), c.fail_count);
    try testing.expectEqual(@as(usize, 3), c.exec_fail_count);
    try testing.expectEqual(@as(usize, 4), c.gate_denials);
    try testing.expectEqual(@as(usize, 5), c.role_turns_used);
}

test "deinit releases a gpa-owned mission (leak-checked)" {
    const gpa = testing.allocator;
    const tasks = try gpa.alloc(Task, 1);
    tasks[0] = .{ .desc = try gpa.dupe(u8, "t") };
    var m: Mission = .{
        .mission_id = try gpa.dupe(u8, "m"),
        .detail = try gpa.dupe(u8, "d"),
        .objective = try gpa.dupe(u8, "o"),
        .acceptance = try gpa.dupe(u8, "a"),
        .feedback = try gpa.dupe(u8, "f"),
        .tasks = tasks,
    };
    m.deinit(gpa);
}

test "every role maps to its routing step id" {
    try testing.expectEqualStrings("product-owner", Role.product_owner.stepId());
    try testing.expectEqualStrings("planner", Role.planner.stepId());
    try testing.expectEqualStrings("executor", Role.executor.stepId());
    try testing.expectEqualStrings("verifier", Role.verifier.stepId());
}
