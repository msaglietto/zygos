//! Mission data model: the durable record the orchestrator mutates and
//! mission_store persists. Pure data — no bus, no store, no provider
//! knowledge. A step's routing key is its pipeline id (`pipeline.Step.id`).

const std = @import("std");
const fsm = @import("fsm.zig");
const pipeline = @import("pipeline.zig");

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
    state: State = .running,
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

    /// The pinned pipeline. The driver sets it from the start request (a
    /// stored mission does not carry it yet); `step_index` indexes into it.
    pipeline: []const pipeline.Step = &.{},
    /// Cursor into `pipeline` while `running`; the list length at `gating`
    /// and `done`.
    step_index: usize = 0,
    step_runs: pipeline.StepRuns = .{},
    /// Counters behind the `MISSION-<n>.md` / `PLAN-<n>.md` archives.
    mission_versions: usize = 0,
    plan_versions: usize = 0,

    /// Only for gpa-owned missions (mission_store.load), whose `pipeline`
    /// is a deep copy: ids and hashes are freed with the list.
    pub fn deinit(self: *Mission, gpa: std.mem.Allocator) void {
        for (self.pipeline) |st| {
            gpa.free(st.id);
            if (st.definition_sha256) |h| gpa.free(h);
        }
        gpa.free(self.pipeline);
        for (self.step_runs.items) |r| gpa.free(r.id);
        gpa.free(self.step_runs.items);
        gpa.free(self.mission_id);
        gpa.free(self.detail);
        gpa.free(self.objective);
        gpa.free(self.acceptance);
        gpa.free(self.feedback);
        for (self.tasks) |t| gpa.free(t.desc);
        gpa.free(self.tasks);
    }

    /// The step id the cursor points at; null at gating and done and for an
    /// index past the list. A failed mission keeps the step that failed.
    pub fn stepId(self: *const Mission) ?[]const u8 {
        return stepIdAt(self.pipeline, self.state, self.step_index);
    }

    /// The reported cursor: the list length at gating and done.
    pub fn cursor(self: *const Mission) usize {
        return cursorAt(self.pipeline.len, self.state, self.step_index);
    }

    pub fn tasksDone(self: *const Mission) usize {
        var n: usize = 0;
        for (self.tasks) |t| {
            if (t.done) n += 1;
        }
        return n;
    }
};

pub fn stepIdAt(steps: []const pipeline.Step, state: State, step_index: usize) ?[]const u8 {
    if (state != .running and state != .failed) return null;
    if (step_index >= steps.len) return null;
    return steps[step_index].id;
}

pub fn cursorAt(pipeline_len: usize, state: State, step_index: usize) usize {
    return switch (state) {
        .gating, .done => pipeline_len,
        .running, .failed => step_index,
    };
}

/// Snapshot a mission into an arena (status/list read a copy, never the live
/// record). Task results and steer are in-memory-only and are not carried;
/// the pinned pipeline is shared, not copied (immutable for a mission).
pub fn cloneToArena(arena: std.mem.Allocator, m: *const Mission) error{OutOfMemory}!Mission {
    const tasks = try arena.alloc(Task, m.tasks.len);
    for (m.tasks, 0..) |t, i| {
        tasks[i] = .{ .desc = try arena.dupe(u8, t.desc), .done = t.done };
    }
    const runs = try arena.alloc(pipeline.RunCount, m.step_runs.items.len);
    for (m.step_runs.items, 0..) |r, i| runs[i] = .{ .id = try arena.dupe(u8, r.id), .count = r.count };
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
        .pipeline = m.pipeline,
        .step_index = m.step_index,
        .step_runs = .{ .items = runs },
        .mission_versions = m.mission_versions,
        .plan_versions = m.plan_versions,
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
    var runs_src = [_]pipeline.RunCount{.{ .id = "executor", .count = 3 }};
    const src: Mission = .{
        .mission_id = "m-42",
        .state = .running,
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
        .pipeline = &pipeline.default_pipeline,
        .step_index = 2,
        .step_runs = .{ .items = &runs_src },
        .mission_versions = 6,
        .plan_versions = 7,
    };
    const c = try cloneToArena(arena_state.allocator(), &src);
    try testing.expectEqualStrings("m-42", c.mission_id);
    try testing.expect(c.mission_id.ptr != src.mission_id.ptr);
    try testing.expectEqual(State.running, c.state);
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
    try testing.expectEqual(@as(usize, 2), c.step_index);
    try testing.expectEqual(@as(usize, 4), c.pipeline.len);
    try testing.expectEqual(@as(usize, 3), c.step_runs.get("executor"));
    try testing.expect(c.step_runs.items[0].id.ptr != runs_src[0].id.ptr);
    try testing.expectEqual(@as(usize, 6), c.mission_versions);
    try testing.expectEqual(@as(usize, 7), c.plan_versions);
}

test "deinit releases a gpa-owned mission (leak-checked)" {
    const gpa = testing.allocator;
    const tasks = try gpa.alloc(Task, 1);
    tasks[0] = .{ .desc = try gpa.dupe(u8, "t") };
    const runs = try gpa.alloc(pipeline.RunCount, 1);
    runs[0] = .{ .id = try gpa.dupe(u8, "executor"), .count = 1 };
    const steps = try gpa.alloc(pipeline.Step, 2);
    steps[0] = .{ .id = try gpa.dupe(u8, "architect"), .kind = .custom, .system = null, .definition_sha256 = try gpa.dupe(u8, "ab"), .tools = false };
    steps[1] = .{ .id = try gpa.dupe(u8, "executor"), .kind = .executor, .system = null, .definition_sha256 = null, .tools = true };
    var m: Mission = .{
        .pipeline = steps,
        .step_runs = .{ .items = runs },
        .mission_id = try gpa.dupe(u8, "m"),
        .detail = try gpa.dupe(u8, "d"),
        .objective = try gpa.dupe(u8, "o"),
        .acceptance = try gpa.dupe(u8, "a"),
        .feedback = try gpa.dupe(u8, "f"),
        .tasks = tasks,
    };
    m.deinit(gpa);
}
