//! Strategy conformance harness (M5): one suite every ContextStrategy must
//! pass, mirroring the FSM table-test discipline. A strategy module calls
//! `conform` from its own tests with a representative StepRef; the harness
//! checks the seam invariants no implementation may bend:
//!
//!   1. budget never exceeded — across a budget sweep, assemble either
//!      returns content within the budget or refuses with BudgetExceeded;
//!   2. determinism — the same step assembles the same bytes twice;
//!   3. absorb tolerance — after absorbing outcomes, assemble still succeeds
//!      and still respects the budget (round-trip: absorbed state must never
//!      corrupt assembly);
//!   4. resume-from-disk parity — a reopened instance over the same persisted
//!      state assembles identical bytes (stateless strategies pass trivially
//!      by returning the same instance).

const std = @import("std");
const context = @import("context.zig");

pub const Fixture = struct {
    strategy: context.ContextStrategy,
    /// Rebuild the strategy from its persisted state (resume parity).
    /// Null = stateless (parity holds by definition).
    reopenFn: ?*const fn (ctx: *anyopaque) context.Error!context.ContextStrategy = null,
    reopen_ctx: ?*anyopaque = null,
};

pub const ConformError = error{
    OutOfMemory,
    BudgetViolated,
    NonDeterministic,
    AbsorbCorrupted,
    ResumeParityBroken,
    AssembleFailed,
};

/// `step` must be assemblable by the strategy (the harness is about seam
/// invariants, not role coverage — modules cover their roles separately).
pub fn conform(gpa: std.mem.Allocator, fixture: Fixture, step: context.StepRef) ConformError!void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: context.Diag = .{};

    // 1. Budget sweep: generous, exact-ish, and starvation budgets.
    const wide: context.TokenBudget = .{ .max_tokens = 1 << 20 };
    const base = fixture.strategy.assemble(arena, step, wide, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.AssembleFailed,
    };
    for ([_]usize{ 1, 8, 64, 1024, 1 << 20 }) |max| {
        const budget: context.TokenBudget = .{ .max_tokens = max };
        const out = fixture.strategy.assemble(arena, step, budget, &diag) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BudgetExceeded => continue, // refusing is a valid answer
            error.Failed => return error.AssembleFailed,
        };
        if (context.estTokens(out.content) > max) return error.BudgetViolated;
    }
    // 2. Determinism: same step, same bytes.
    const again = fixture.strategy.assemble(arena, step, wide, &diag) catch return error.AssembleFailed;
    if (!std.mem.eql(u8, base.content, again.content)) return error.NonDeterministic;

    // 3. Absorb tolerance: absorbed outcomes never corrupt assembly.
    fixture.strategy.absorb(step, .{
        .role = step.role,
        .ok = true,
        .text = "conformance probe outcome",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.AbsorbCorrupted,
    };
    const after = fixture.strategy.assemble(arena, step, wide, &diag) catch return error.AbsorbCorrupted;
    if (context.estTokens(after.content) > wide.max_tokens) return error.BudgetViolated;

    // 4. Resume parity: a reopened instance assembles the same bytes.
    if (fixture.reopenFn) |reopen| {
        const reopened = reopen(fixture.reopen_ctx.?) catch return error.ResumeParityBroken;
        const twin = reopened.assemble(arena, step, wide, &diag) catch return error.ResumeParityBroken;
        if (!std.mem.eql(u8, after.content, twin.content)) return error.ResumeParityBroken;
    }
}

// ===========================================================================
// Tests — the harness itself must catch violators
// ===========================================================================

const testing = std.testing;

fn nullRead(ctx: *anyopaque, arena: std.mem.Allocator, name: []const u8) ?[]const u8 {
    _ = ctx;
    _ = arena;
    _ = name;
    return null;
}

fn probeStep() context.StepRef {
    return .{
        .role = "executor",
        .mission = .{ .mission_id = "m", .objective = "obj" },
        .substrate = .{ .ctx = @ptrCast(@constCast(&{})), .readFn = &nullRead },
    };
}

const Honest = struct {
    fn assembleImpl(
        ctx: *anyopaque,
        arena: std.mem.Allocator,
        step: context.StepRef,
        budget: context.TokenBudget,
        diag: *context.Diag,
    ) context.Error!context.Assembled {
        _ = ctx;
        _ = step;
        _ = diag;
        // Honest: shrink to fit the budget.
        const want = @min(budget.max_tokens * 4, 40);
        const buf = try arena.alloc(u8, want);
        @memset(buf, 'a');
        return .{ .content = buf };
    }
    fn absorbImpl(ctx: *anyopaque, step: context.StepRef, outcome: context.Outcome) context.Error!void {
        _ = ctx;
        _ = step;
        _ = outcome;
    }
};

const Flaky = struct {
    calls: usize = 0,
    fn assembleImpl(
        ctx: *anyopaque,
        arena: std.mem.Allocator,
        step: context.StepRef,
        budget: context.TokenBudget,
        diag: *context.Diag,
    ) context.Error!context.Assembled {
        _ = step;
        _ = budget;
        _ = diag;
        const self: *Flaky = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        return .{ .content = try std.fmt.allocPrint(arena, "call {d}", .{self.calls}) };
    }
    fn absorbImpl(ctx: *anyopaque, step: context.StepRef, outcome: context.Outcome) context.Error!void {
        _ = ctx;
        _ = step;
        _ = outcome;
    }
};

test "an honest strategy conforms" {
    var h = Honest{};
    try conform(testing.allocator, .{ .strategy = .{
        .ctx = @ptrCast(&h),
        .assembleFn = &Honest.assembleImpl,
        .absorbFn = &Honest.absorbImpl,
    } }, probeStep());
}

test "a non-deterministic strategy is caught" {
    var f = Flaky{};
    try testing.expectError(error.NonDeterministic, conform(testing.allocator, .{ .strategy = .{
        .ctx = @ptrCast(&f),
        .assembleFn = &Flaky.assembleImpl,
        .absorbFn = &Flaky.absorbImpl,
    } }, probeStep()));
}
