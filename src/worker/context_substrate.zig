//! SubstrateStrategy (M5 baseline extraction): artifacts-as-context behind
//! the ContextStrategy seam. For the four known kinds without extra
//! artifacts the bytes match the pre-pipeline assembly (the regression
//! anchor that makes the seam real). Stateless and pure over (StepRef +
//! Substrate): absorb is a no-op (the driver's mission view already carries
//! task outcomes), so one instance serves every mission.

const std = @import("std");
const context = @import("context.zig");
const pipeline = @import("mission/pipeline.zig");

const mission_artifact = "MISSION.md";
const plan_artifact = "PLAN.md";
const exec_artifact = "EXEC.md";

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
        return assembleContent(arena, step, budget, diag);
    }

    fn absorbImpl(ctx: *anyopaque, step: context.StepRef, outcome: context.Outcome) context.Error!void {
        _ = ctx;
        _ = step;
        _ = outcome;
    }
};

/// The artifacts-as-context assembly itself, composable by richer strategies
/// (recall/thread) that append to this base under their own budget math. The
/// shared clip rule (`context.fit`) lives here: the current task, MISSION.md
/// and the operator brief are never dropped; older artifacts clip first; a
/// never-dropped part over the budget is `error.BudgetExceeded`.
pub fn assembleContent(
    arena: std.mem.Allocator,
    step: context.StepRef,
    budget: context.TokenBudget,
    diag: *context.Diag,
) context.Error!context.Assembled {
    const m = step.mission;
    const tail = try operatorBriefTail(arena, step);

    switch (pipeline.kindOf(step.role)) {
        .product_owner => return finish(arena, step, budget, m.objective, &.{}, tail),
        .planner => {
            // The substrate is the context: the planner reads the persisted
            // mission brief, not driver state.
            const brief = step.substrate.read(arena, mission_artifact) orelse {
                diag.message = mission_artifact ++ " missing from the planning root";
                return error.Failed;
            };
            const prefix = if (m.feedback.len == 0) brief else try std.fmt.allocPrint(
                arena,
                "{s}\n\nFeedback on the previous attempt:\n{s}\n",
                .{ brief, m.feedback },
            );
            return finish(arena, step, budget, prefix, &.{}, tail);
        },
        .executor => {
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
                    w.print("{d}. [{s}] {s}\n", .{ i + 1, mark, try pipeline.taskLabel(arena, t.desc) }) catch
                        return error.OutOfMemory;
                    if (t.done and t.result.len > 0)
                        w.print("   outcome: {s}\n", .{t.result}) catch return error.OutOfMemory;
                }
            }
            w.print(
                "\nYour task (do ONLY this, then stop):\n{s}\n",
                .{try currentTaskText(arena, m.tasks[m.task_index].desc)},
            ) catch return error.OutOfMemory;
            if (m.feedback.len > 0)
                w.print("\nFeedback on the previous attempt:\n{s}\n", .{m.feedback}) catch return error.OutOfMemory;
            return finish(arena, step, budget, content.written(), &.{}, tail);
        },
        .verifier => {
            const brief = step.substrate.read(arena, mission_artifact) orelse {
                diag.message = mission_artifact ++ " missing from the planning root";
                return error.Failed;
            };
            const plan = step.substrate.read(arena, plan_artifact) orelse {
                diag.message = plan_artifact ++ " missing from the planning root";
                return error.Failed;
            };
            // EXEC.md is optional: a mission resumed from a pre-pipeline
            // state file reaches its verifier without one.
            var listed: std.ArrayList(context.Part) = .empty;
            try listed.append(arena, .{ .text = try std.fmt.allocPrint(arena, "{s}\n", .{plan}) });
            if (try artifactPart(arena, step, exec_artifact)) |part| try listed.append(arena, part);
            return finish(
                arena,
                step,
                budget,
                try std.fmt.allocPrint(arena, "{s}\n", .{brief}),
                listed.items,
                try std.fmt.allocPrint(arena, "Every task above has been executed. Verify the objective is met.\n{s}", .{tail}),
            );
        },
        .custom => return finish(arena, step, budget, m.objective, &.{}, tail),
    }
}

/// Assemble `prefix ++ listed ++ step.artifacts ++ suffix` under the budget.
fn finish(
    arena: std.mem.Allocator,
    step: context.StepRef,
    budget: context.TokenBudget,
    prefix: []const u8,
    listed: []const context.Part,
    suffix: []const u8,
) context.Error!context.Assembled {
    var parts: std.ArrayList(context.Part) = .empty;
    try parts.appendSlice(arena, listed);
    for (step.artifacts) |name| {
        if (try artifactPart(arena, step, name)) |part| try parts.append(arena, part);
    }
    const content = context.fit(arena, prefix, parts.items, suffix, budget.max_tokens) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BudgetExceeded => return error.BudgetExceeded,
    };
    return .{ .content = content };
}

/// One artifact as a headed block; null when the file is absent. MISSION.md
/// is pinned: it is never clipped or dropped.
fn artifactPart(arena: std.mem.Allocator, step: context.StepRef, name: []const u8) error{OutOfMemory}!?context.Part {
    const body = step.substrate.read(arena, name) orelse return null;
    const nl: []const u8 = if (std.mem.endsWith(u8, body, "\n")) "" else "\n";
    return .{
        .text = try std.fmt.allocPrint(arena, "\n--- {s} ---\n{s}{s}", .{ name, body, nl }),
        .pinned = std.mem.eql(u8, name, mission_artifact),
    };
}

/// What the executor is asked to do for this task; a fix task states its
/// feedback, or points at the artifacts that follow.
fn currentTaskText(arena: std.mem.Allocator, desc: []const u8) error{OutOfMemory}![]const u8 {
    const fix = (try pipeline.parseFixTask(arena, desc)) orelse return desc;
    switch (fix) {
        .feedback => |fb| return std.fmt.allocPrint(
            arena,
            "Address this feedback on the work done so far:\n{s}",
            .{fb},
        ),
        .artifacts => |names| {
            var out: std.ArrayList(u8) = .empty;
            try out.appendSlice(arena, "Address the findings in these artifacts (contents below):");
            for (names) |n| {
                try out.appendSlice(arena, "\n- ");
                try out.appendSlice(arena, n);
            }
            return out.items;
        },
    }
}

fn operatorBriefTail(arena: std.mem.Allocator, step: context.StepRef) error{OutOfMemory}![]const u8 {
    const original = step.substrate.read(arena, "BRIEF.md") orelse return "";
    return std.fmt.allocPrint(
        arena,
        "\n\nOriginal operator brief (authoritative):\n{s}\n" ++
            "Preserve its success criteria, examples, constraints, and non-goals. " ++
            "If generated acceptance or tasks conflict, follow this original brief.\n",
        .{original},
    );
}

/// Stateless: one shared instance serves every mission.
var shared: SubstrateStrategy = .{};

pub fn strategy() context.ContextStrategy {
    return shared.strategy();
}

// ===========================================================================
// Tests — byte-identical to the pre-seam mission.zig assembly
// ===========================================================================

const testing = std.testing;

const File = struct { name: []const u8, body: []const u8 };

const FakeSubstrate = struct {
    mission_md: ?[]const u8 = null,
    plan_md: ?[]const u8 = null,
    extra: []const File = &.{},

    fn read(ctx: *anyopaque, arena: std.mem.Allocator, name: []const u8) ?[]const u8 {
        const self: *FakeSubstrate = @ptrCast(@alignCast(ctx));
        const src: ?[]const u8 = if (std.mem.eql(u8, name, "MISSION.md"))
            self.mission_md
        else if (std.mem.eql(u8, name, "PLAN.md"))
            self.plan_md
        else for (self.extra) |f| {
            if (std.mem.eql(u8, f.name, name)) break f.body;
        } else null;
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

test "SubstrateStrategy passes the strategy conformance harness" {
    const conformance = @import("context_conformance.zig");
    var sub = FakeSubstrate{ .mission_md = "# Mission m\n\ngizmo\n", .plan_md = "# Plan\n\n- [ ] t\n" };
    const tasks = [_]context.TaskView{
        .{ .desc = "build", .done = true, .result = "built" },
        .{ .desc = "ship" },
    };
    for ([_][]const u8{ "product-owner", "planner", "executor", "verifier", "architect" }) |role| {
        try conformance.conform(testing.allocator, .{ .strategy = strategy() }, .{
            .role = role,
            .mission = .{
                .mission_id = "m",
                .objective = "ship it",
                .tasks = &tasks,
                .task_index = 1,
            },
            .substrate = sub.substrate(),
        });
    }
}

fn stepWith(
    role: []const u8,
    mission: context.MissionView,
    sub: *FakeSubstrate,
    artifacts: []const []const u8,
) context.StepRef {
    return .{ .role = role, .artifacts = artifacts, .mission = mission, .substrate = sub.substrate() };
}

test "verifier content appends EXEC.md and each step artifact after PLAN.md, before the closing line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var sub = FakeSubstrate{
        .mission_md = "BRIEF\n",
        .plan_md = "PLAN\n",
        .extra = &.{
            .{ .name = "EXEC.md", .body = "## Task 1: t\n\ndone\n\n" },
            .{ .name = "step-architect-1.md", .body = "use a ring buffer" },
        },
    };
    var diag: context.Diag = .{};
    const out = try strategy().assemble(arena_state.allocator(), stepWith(
        "verifier",
        .{ .mission_id = "m" },
        &sub,
        &.{ "step-architect-1.md", "step-missing-9.md" },
    ), wide_budget, &diag);
    try testing.expectEqualStrings(
        "BRIEF\n\nPLAN\n\n\n--- EXEC.md ---\n## Task 1: t\n\ndone\n\n" ++
            "\n--- step-architect-1.md ---\nuse a ring buffer\n" ++
            "Every task above has been executed. Verify the objective is met.\n",
        out.content,
    );
}

test "a custom id assembles by kind: objective first, then every artifact in the order given" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var sub = FakeSubstrate{
        .mission_md = "# Mission\n",
        .plan_md = "# Plan\n",
        .extra = &.{.{ .name = "EXEC.md", .body = "ran" }},
    };
    var diag: context.Diag = .{};
    const out = try strategy().assemble(arena_state.allocator(), stepWith(
        "reviewer",
        .{ .mission_id = "m", .objective = "ship it" },
        &sub,
        &.{ "MISSION.md", "PLAN.md", "EXEC.md" },
    ), wide_budget, &diag);
    try testing.expectEqualStrings(
        "ship it\n--- MISSION.md ---\n# Mission\n\n--- PLAN.md ---\n# Plan\n\n--- EXEC.md ---\nran\n",
        out.content,
    );
}

test "the operator brief closes every kind's content, after the artifacts" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var sub = FakeSubstrate{
        .mission_md = "M\n",
        .extra = &.{
            .{ .name = "BRIEF.md", .body = "THE BRIEF" },
            .{ .name = "step-x-1.md", .body = "xs" },
        },
    };
    var diag: context.Diag = .{};
    const out = try strategy().assemble(arena_state.allocator(), stepWith(
        "planner",
        .{ .mission_id = "m" },
        &sub,
        &.{"step-x-1.md"},
    ), wide_budget, &diag);
    const art = std.mem.indexOf(u8, out.content, "--- step-x-1.md ---") orelse return error.Missing;
    const brief = std.mem.indexOf(u8, out.content, "THE BRIEF") orelse return error.Missing;
    try testing.expect(art < brief);
}

test "executor fix tasks state their feedback, or carry their source artifacts" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sub = FakeSubstrate{ .extra = &.{.{ .name = "step-reviewer-1.md", .body = "rename foo to bar" }} };
    var diag: context.Diag = .{};

    const fb = try pipeline.feedbackTask(arena, "missing tests");
    const fb_tasks = [_]context.TaskView{ .{ .desc = "build", .done = true, .result = "built" }, .{ .desc = fb.desc } };
    const out_fb = try strategy().assemble(arena, stepWith("executor", .{
        .mission_id = "m",
        .objective = "ship it",
        .tasks = &fb_tasks,
        .task_index = 1,
    }, &sub, &.{}), wide_budget, &diag);
    try testing.expect(std.mem.indexOf(u8, out_fb.content, "Address this feedback on the work done so far:\nmissing tests") != null);
    try testing.expect(std.mem.indexOf(u8, out_fb.content, "2. [current] fix: missing tests") != null);
    try testing.expect(std.mem.indexOf(u8, out_fb.content, "zygos fix-task") == null);

    const art = try pipeline.artifactsTask(arena, &.{"step-reviewer-1.md"});
    const art_tasks = [_]context.TaskView{ .{ .desc = "build", .done = true }, .{ .desc = art.desc } };
    const out_art = try strategy().assemble(arena, stepWith("executor", .{
        .mission_id = "m",
        .objective = "ship it",
        .tasks = &art_tasks,
        .task_index = 1,
    }, &sub, &.{"step-reviewer-1.md"}), wide_budget, &diag);
    try testing.expect(std.mem.indexOf(u8, out_art.content, "Address the findings in these artifacts") != null);
    try testing.expect(std.mem.indexOf(u8, out_art.content, "- step-reviewer-1.md") != null);
    try testing.expect(std.mem.indexOf(u8, out_art.content, "rename foo to bar") != null);
    try testing.expect(std.mem.indexOf(u8, out_art.content, "zygos fix-task") == null);
}

test "clipping: older artifacts shrink first; MISSION.md, the task and the closing line survive" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const old_notes = "OLD-NOTES " ** 200;
    var sub = FakeSubstrate{
        .mission_md = "THE-MISSION\n",
        .plan_md = "PLAN\n",
        .extra = &.{
            .{ .name = "EXEC.md", .body = "exec evidence line\n" ** 80 },
            .{ .name = "step-notes-1.md", .body = old_notes },
        },
    };
    var diag: context.Diag = .{};
    // Room for the spine and the newest artifact, not for everything.
    const out = try strategy().assemble(arena, stepWith("verifier", .{ .mission_id = "m" }, &sub, &.{"step-notes-1.md"}), .{ .max_tokens = 600 }, &diag);
    try testing.expect(context.estTokens(out.content) <= 600);
    try testing.expect(std.mem.indexOf(u8, out.content, "THE-MISSION") != null);
    try testing.expect(std.mem.indexOf(u8, out.content, "Every task above has been executed") != null);
    try testing.expect(std.mem.indexOf(u8, out.content, old_notes) != null);
    try testing.expect(std.mem.indexOf(u8, out.content, context.clip_marker) != null);
    try testing.expect(std.mem.indexOf(u8, out.content, "exec evidence line\n" ** 80) == null);

    // A MISSION.md that alone exceeds the budget is still refused.
    var huge = FakeSubstrate{ .mission_md = "M" ** 4000, .plan_md = "P\n" };
    try testing.expectError(error.BudgetExceeded, strategy().assemble(arena, stepWith("verifier", .{ .mission_id = "m" }, &huge, &.{}), .{ .max_tokens = 100 }, &diag));
    // So is a current task that alone exceeds it.
    const big_task = [_]context.TaskView{.{ .desc = "t" ** 4000 }};
    try testing.expectError(error.BudgetExceeded, strategy().assemble(arena, stepWith("executor", .{
        .mission_id = "m",
        .objective = "o",
        .tasks = &big_task,
    }, &sub, &.{"step-notes-1.md"}), .{ .max_tokens = 100 }, &diag));
}

test "absorb is a no-op that never fails" {
    var sub = FakeSubstrate{};
    try strategy().absorb(.{
        .role = "executor",
        .mission = .{ .mission_id = "m" },
        .substrate = sub.substrate(),
    }, .{ .role = "executor", .ok = true, .text = "done" });
}
