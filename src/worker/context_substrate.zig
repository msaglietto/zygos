//! SubstrateStrategy (M5 baseline extraction): today's artifacts-as-context
//! behavior behind the ContextStrategy seam, unchanged — the byte-identical
//! regression anchor that makes the seam real. Stateless and pure over
//! (StepRef + Substrate): absorb is a no-op (the driver's mission view
//! already carries task outcomes), so one instance serves every mission.

const std = @import("std");
const context = @import("context.zig");

const mission_artifact = "MISSION.md";
const plan_artifact = "PLAN.md";

pub const SubstrateStrategy = struct {
    pub fn strategy(self: *SubstrateStrategy) context.ContextStrategy {
        return .{ .ctx = @ptrCast(self), .assembleFn = &assembleImpl, .absorbFn = &absorbImpl };
    }

    fn assembleImpl(
        ctx: *anyopaque,
        arena: std.mem.Allocator,
        step: context.StepRef,
        budget: context.TokenBudget,
        diag: *context.Diag,
    ) context.Error!context.Assembled {
        _ = ctx;
        _ = budget; // enforced by the seam wrapper
        const m = step.mission;

        if (std.mem.eql(u8, step.role, "product-owner")) {
            return .{ .content = m.objective };
        }
        if (std.mem.eql(u8, step.role, "planner")) {
            // The substrate is the context: the planner reads the persisted
            // mission brief, not driver state.
            const brief = step.substrate.read(arena, mission_artifact) orelse {
                diag.message = mission_artifact ++ " missing from the planning root";
                return error.Failed;
            };
            if (m.feedback.len == 0) return .{ .content = brief };
            return .{ .content = try std.fmt.allocPrint(
                arena,
                "{s}\n\nFeedback on the previous attempt:\n{s}\n",
                .{ brief, m.feedback },
            ) };
        }
        if (std.mem.eql(u8, step.role, "executor")) {
            // The executor is stateless across turns; the prompt is its only
            // memory. Without the progress block every turn re-discovers the
            // workspace from scratch.
            std.debug.assert(m.task_index < m.tasks.len);
            var content: std.Io.Writer.Allocating = .init(arena);
            const w = &content.writer;
            w.print("Objective:\n{s}\n", .{m.objective}) catch return error.OutOfMemory;
            if (m.tasks.len > 1) {
                w.writeAll(if (m.task_index > 0)
                    "\nPlan progress — earlier tasks are already complete and verified; " ++
                        "do NOT redo, re-check, or re-test them:\n"
                else
                    "\nPlan:\n") catch return error.OutOfMemory;
                for (m.tasks, 0..) |t, i| {
                    const mark = if (t.done) "done" else if (i == m.task_index) "current" else "pending";
                    w.print("{d}. [{s}] {s}\n", .{ i + 1, mark, t.desc }) catch return error.OutOfMemory;
                    if (t.done and t.result.len > 0)
                        w.print("   outcome: {s}\n", .{t.result}) catch return error.OutOfMemory;
                }
            }
            w.print(
                "\nYour task (do ONLY this, then stop):\n{s}\n",
                .{m.tasks[m.task_index].desc},
            ) catch return error.OutOfMemory;
            if (m.feedback.len > 0)
                w.print("\nFeedback on the previous attempt:\n{s}\n", .{m.feedback}) catch return error.OutOfMemory;
            return .{ .content = content.written() };
        }
        if (std.mem.eql(u8, step.role, "verifier")) {
            const brief = step.substrate.read(arena, mission_artifact) orelse {
                diag.message = mission_artifact ++ " missing from the planning root";
                return error.Failed;
            };
            const plan = step.substrate.read(arena, plan_artifact) orelse {
                diag.message = plan_artifact ++ " missing from the planning root";
                return error.Failed;
            };
            return .{ .content = try std.fmt.allocPrint(
                arena,
                "{s}\n{s}\nEvery task above has been executed. Verify the objective is met.\n",
                .{ brief, plan },
            ) };
        }
        diag.message = "unknown role";
        return error.Failed;
    }

    fn absorbImpl(ctx: *anyopaque, step: context.StepRef, outcome: context.Outcome) context.Error!void {
        _ = ctx;
        _ = step;
        _ = outcome;
    }
};

/// Stateless: one shared instance serves every mission.
var shared: SubstrateStrategy = .{};

pub fn strategy() context.ContextStrategy {
    return shared.strategy();
}

// ===========================================================================
// Tests — byte-identical to the pre-seam mission.zig assembly
// ===========================================================================

const testing = std.testing;

const FakeSubstrate = struct {
    mission_md: ?[]const u8 = null,
    plan_md: ?[]const u8 = null,

    fn read(ctx: *anyopaque, arena: std.mem.Allocator, name: []const u8) ?[]const u8 {
        const self: *FakeSubstrate = @ptrCast(@alignCast(ctx));
        const src = if (std.mem.eql(u8, name, "MISSION.md"))
            self.mission_md
        else if (std.mem.eql(u8, name, "PLAN.md"))
            self.plan_md
        else
            null;
        const bytes = src orelse return null;
        return arena.dupe(u8, bytes) catch null;
    }

    fn substrate(self: *FakeSubstrate) context.Substrate {
        return .{ .ctx = @ptrCast(self), .readFn = &read };
    }
};

const wide_budget: context.TokenBudget = .{ .max_tokens = 100_000 };

fn assembleFor(
    arena: std.mem.Allocator,
    role: []const u8,
    mission: context.MissionView,
    sub: *FakeSubstrate,
    diag: *context.Diag,
) context.Error!context.Assembled {
    return strategy().assemble(arena, .{
        .role = role,
        .mission = mission,
        .substrate = sub.substrate(),
    }, wide_budget, diag);
}

test "product-owner content is the raw objective" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var sub = FakeSubstrate{};
    var diag: context.Diag = .{};
    const out = try assembleFor(arena_state.allocator(), "product-owner", .{
        .mission_id = "m",
        .objective = "ship the gizmo",
    }, &sub, &diag);
    try testing.expectEqualStrings("ship the gizmo", out.content);
}

test "planner content is MISSION.md, with feedback appended on a redo" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sub = FakeSubstrate{ .mission_md = "# Mission m\n\n## Objective\n\ngizmo\n" };
    var diag: context.Diag = .{};

    const fresh = try assembleFor(arena, "planner", .{ .mission_id = "m" }, &sub, &diag);
    try testing.expectEqualStrings("# Mission m\n\n## Objective\n\ngizmo\n", fresh.content);

    const redo = try assembleFor(arena, "planner", .{
        .mission_id = "m",
        .feedback = "too many tasks",
    }, &sub, &diag);
    try testing.expectEqualStrings(
        "# Mission m\n\n## Objective\n\ngizmo\n\n\nFeedback on the previous attempt:\ntoo many tasks\n",
        redo.content,
    );
}

test "planner without MISSION.md fails with the exact legacy message" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var sub = FakeSubstrate{};
    var diag: context.Diag = .{};
    try testing.expectError(error.Failed, assembleFor(
        arena_state.allocator(),
        "planner",
        .{ .mission_id = "m" },
        &sub,
        &diag,
    ));
    try testing.expectEqualStrings("MISSION.md missing from the planning root", diag.message);
}

test "executor content: objective, progress block with outcomes, current task, feedback" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var sub = FakeSubstrate{};
    var diag: context.Diag = .{};
    const tasks = [_]context.TaskView{
        .{ .desc = "build the gizmo", .done = true, .result = "gizmo built" },
        .{ .desc = "test the gizmo" },
        .{ .desc = "ship the gizmo" },
    };
    const out = try assembleFor(arena_state.allocator(), "executor", .{
        .mission_id = "m",
        .objective = "ship it",
        .tasks = &tasks,
        .task_index = 1,
        .feedback = "be quicker",
    }, &sub, &diag);
    try testing.expectEqualStrings(
        "Objective:\nship it\n" ++
            "\nPlan progress — earlier tasks are already complete and verified; " ++
            "do NOT redo, re-check, or re-test them:\n" ++
            "1. [done] build the gizmo\n" ++
            "   outcome: gizmo built\n" ++
            "2. [current] test the gizmo\n" ++
            "3. [pending] ship the gizmo\n" ++
            "\nYour task (do ONLY this, then stop):\ntest the gizmo\n" ++
            "\nFeedback on the previous attempt:\nbe quicker\n",
        out.content,
    );
}

test "executor with a single task skips the plan block entirely" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var sub = FakeSubstrate{};
    var diag: context.Diag = .{};
    const tasks = [_]context.TaskView{.{ .desc = "just do it" }};
    const out = try assembleFor(arena_state.allocator(), "executor", .{
        .mission_id = "m",
        .objective = "one thing",
        .tasks = &tasks,
    }, &sub, &diag);
    try testing.expectEqualStrings(
        "Objective:\none thing\n\nYour task (do ONLY this, then stop):\njust do it\n",
        out.content,
    );
}

test "verifier content joins MISSION.md and PLAN.md; missing PLAN.md names it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sub = FakeSubstrate{ .mission_md = "BRIEF\n", .plan_md = "PLAN\n" };
    var diag: context.Diag = .{};
    const out = try assembleFor(arena, "verifier", .{ .mission_id = "m" }, &sub, &diag);
    try testing.expectEqualStrings(
        "BRIEF\n\nPLAN\n\nEvery task above has been executed. Verify the objective is met.\n",
        out.content,
    );

    var noplan = FakeSubstrate{ .mission_md = "BRIEF\n" };
    try testing.expectError(error.Failed, assembleFor(arena, "verifier", .{ .mission_id = "m" }, &noplan, &diag));
    try testing.expectEqualStrings("PLAN.md missing from the planning root", diag.message);
}

test "over-budget executor assembly is refused by the seam" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var sub = FakeSubstrate{};
    var diag: context.Diag = .{};
    const tasks = [_]context.TaskView{.{ .desc = "x" ** 400 }};
    try testing.expectError(error.BudgetExceeded, strategy().assemble(arena_state.allocator(), .{
        .role = "executor",
        .mission = .{ .mission_id = "m", .objective = "o", .tasks = &tasks },
        .substrate = sub.substrate(),
    }, .{ .max_tokens = 50 }, &diag));
}

test "absorb is a no-op that never fails" {
    var sub = FakeSubstrate{};
    try strategy().absorb(.{
        .role = "executor",
        .mission = .{ .mission_id = "m" },
        .substrate = sub.substrate(),
    }, .{ .role = "executor", .ok = true, .text = "done" });
}
