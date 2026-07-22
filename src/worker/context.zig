//! ContextStrategy seam (M5, docs/specs/context.md). The context handed
//! between pipeline steps is a first-class, swappable strategy — explicitly
//! NOT "dump-the-transcript-into-the-model". Zig shape: a vtable
//! (`ctx: *anyopaque` + fn pointers), matching the Outbound/Caller/Sink
//! idiom — strategies are config-selected at boot from `zygos.zon`;
//! comptime dispatch would force every strategy into one compilation unit
//! and bar out-of-repo strategies.
//!
//! The budget is enforced HERE (`ContextStrategy.assemble`), not trusted to
//! implementations: an over-budget assembly is `error.BudgetExceeded`, never
//! a silently oversized prompt.

const std = @import("std");

pub const Error = error{ OutOfMemory, Failed, BudgetExceeded };

/// std-only token estimate: ~4 bytes per token, rounded up. Coarse on
/// purpose — budgets are ceilings, not billing.
pub fn estTokens(bytes: []const u8) usize {
    return (bytes.len + 3) / 4;
}

pub const TokenBudget = struct {
    max_tokens: usize,
};

/// Neutral, read-only view of the mission the driver exposes to strategies —
/// strategies never see driver internals.
pub const TaskView = struct {
    desc: []const u8,
    done: bool = false,
    result: []const u8 = "",
};

pub const MissionView = struct {
    mission_id: []const u8,
    objective: []const u8 = "",
    acceptance: []const u8 = "",
    feedback: []const u8 = "",
    tasks: []const TaskView = &.{},
    task_index: usize = 0,
};

/// Artifact reader over the planning substrate (mission_store behind a
/// vtable so strategies test without disk).
pub const Substrate = struct {
    ctx: *anyopaque,
    readFn: *const fn (ctx: *anyopaque, arena: std.mem.Allocator, name: []const u8) ?[]const u8,

    pub fn read(self: Substrate, arena: std.mem.Allocator, name: []const u8) ?[]const u8 {
        return self.readFn(self.ctx, arena, name);
    }
};

/// The pipeline step whose context is being assembled.
pub const StepRef = struct {
    /// Step id: product-owner | planner | executor | verifier.
    role: []const u8,
    mission: MissionView,
    substrate: Substrate,
};

pub const Assembled = struct {
    content: []const u8,
};

/// A completed step's outcome, offered to the strategy's substrate.
pub const Outcome = struct {
    role: []const u8,
    ok: bool,
    text: []const u8,
};

/// Failure detail for `error.Failed` (providers_catalog Diag idiom): the
/// driver surfaces `message` verbatim in the mission detail.
pub const Diag = struct {
    message: []const u8 = "",
};

pub const ContextStrategy = struct {
    ctx: *anyopaque,
    /// Assemble the next step's content within an explicit token budget.
    assembleFn: *const fn (
        ctx: *anyopaque,
        arena: std.mem.Allocator,
        step: StepRef,
        budget: TokenBudget,
        diag: *Diag,
    ) Error!Assembled,
    /// Absorb a completed step's outcome into the strategy's substrate.
    absorbFn: *const fn (ctx: *anyopaque, step: StepRef, outcome: Outcome) Error!void,

    pub fn assemble(
        self: ContextStrategy,
        arena: std.mem.Allocator,
        step: StepRef,
        budget: TokenBudget,
        diag: *Diag,
    ) Error!Assembled {
        const out = try self.assembleFn(self.ctx, arena, step, budget, diag);
        if (estTokens(out.content) > budget.max_tokens) return error.BudgetExceeded;
        return out;
    }

    pub fn absorb(self: ContextStrategy, step: StepRef, outcome: Outcome) Error!void {
        return self.absorbFn(self.ctx, step, outcome);
    }
};

// ---------------------------------------------------------------------------
// Config (.context_strategy block in zygos.zon)
// ---------------------------------------------------------------------------

pub const Kind = enum { substrate, recall, thread };

pub const default_max_tokens: usize = 32_768;

pub const Config = struct {
    kind: Kind,
    max_tokens: usize,

    /// ZON text, not a path (Z-02: binaries read the file). Absent block ⇒
    /// substrate strategy with the default budget; an unknown kind string
    /// refuses the boot (fail closed).
    pub fn parse(
        gpa: std.mem.Allocator,
        zon_text: [:0]const u8,
    ) error{ OutOfMemory, ParseZon, UnknownStrategy }!Config {
        const Block = struct { kind: []const u8 = "substrate", max_tokens: usize = default_max_tokens };
        const Data = struct { context_strategy: Block = .{} };
        // Arena, not zon.parse.free: freeing a struct whose absent fields
        // defaulted to comptime literals would free non-heap slices.
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const data = std.zon.parse.fromSliceAlloc(Data, arena_state.allocator(), zon_text, null, .{
            .ignore_unknown_fields = true,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ParseZon,
        };
        const kind = std.meta.stringToEnum(Kind, data.context_strategy.kind) orelse
            return error.UnknownStrategy;
        return .{ .kind = kind, .max_tokens = data.context_strategy.max_tokens };
    }
};

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "estTokens: ~4 bytes per token, rounded up; empty is 0" {
    try testing.expectEqual(@as(usize, 0), estTokens(""));
    try testing.expectEqual(@as(usize, 1), estTokens("abc"));
    try testing.expectEqual(@as(usize, 1), estTokens("abcd"));
    try testing.expectEqual(@as(usize, 2), estTokens("abcde"));
    try testing.expectEqual(@as(usize, 25), estTokens("x" ** 100));
}

const FixedStrategy = struct {
    content: []const u8,
    absorbed: usize = 0,

    fn assembleImpl(
        ctx: *anyopaque,
        arena: std.mem.Allocator,
        step: StepRef,
        budget: TokenBudget,
        diag: *Diag,
    ) Error!Assembled {
        _ = step;
        _ = budget;
        _ = diag;
        const self: *FixedStrategy = @ptrCast(@alignCast(ctx));
        return .{ .content = try arena.dupe(u8, self.content) };
    }

    fn absorbImpl(ctx: *anyopaque, step: StepRef, outcome: Outcome) Error!void {
        _ = step;
        _ = outcome;
        const self: *FixedStrategy = @ptrCast(@alignCast(ctx));
        self.absorbed += 1;
    }

    fn strategy(self: *FixedStrategy) ContextStrategy {
        return .{ .ctx = @ptrCast(self), .assembleFn = &assembleImpl, .absorbFn = &absorbImpl };
    }
};

fn emptySubstrateRead(ctx: *anyopaque, arena: std.mem.Allocator, name: []const u8) ?[]const u8 {
    _ = ctx;
    _ = arena;
    _ = name;
    return null;
}

fn testStep() StepRef {
    return .{
        .role = "executor",
        .mission = .{ .mission_id = "m" },
        .substrate = .{ .ctx = @ptrCast(@constCast(&{})), .readFn = &emptySubstrateRead },
    };
}

test "assemble enforces the budget: over-budget content is BudgetExceeded, never returned" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var fixed = FixedStrategy{ .content = "x" ** 100 }; // 25 tokens
    var diag: Diag = .{};
    try testing.expectError(error.BudgetExceeded, fixed.strategy().assemble(
        arena_state.allocator(),
        testStep(),
        .{ .max_tokens = 24 },
        &diag,
    ));
}

test "assemble under budget passes through; absorb dispatches to the impl" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var fixed = FixedStrategy{ .content = "hello" };
    var diag: Diag = .{};
    const out = try fixed.strategy().assemble(
        arena_state.allocator(),
        testStep(),
        .{ .max_tokens = 100 },
        &diag,
    );
    try testing.expectEqualStrings("hello", out.content);
    try fixed.strategy().absorb(testStep(), .{ .role = "executor", .ok = true, .text = "done" });
    try testing.expectEqual(@as(usize, 1), fixed.absorbed);
}

test "Config.parse: absent block defaults to substrate with the default budget" {
    const cfg = try Config.parse(testing.allocator, ".{ .default = .{} }");
    try testing.expectEqual(Kind.substrate, cfg.kind);
    try testing.expectEqual(default_max_tokens, cfg.max_tokens);
}

test "Config.parse: explicit block selects kind and budget" {
    const cfg = try Config.parse(testing.allocator,
        \\.{ .context_strategy = .{ .kind = "recall", .max_tokens = 9000 } }
    );
    try testing.expectEqual(Kind.recall, cfg.kind);
    try testing.expectEqual(@as(usize, 9000), cfg.max_tokens);
    const thread_cfg = try Config.parse(testing.allocator,
        \\.{ .context_strategy = .{ .kind = "thread" } }
    );
    try testing.expectEqual(Kind.thread, thread_cfg.kind);
    try testing.expectEqual(default_max_tokens, thread_cfg.max_tokens);
}

test "Config.parse: unknown kind refuses the boot (fail closed); garbage is ParseZon" {
    try testing.expectError(error.UnknownStrategy, Config.parse(testing.allocator,
        \\.{ .context_strategy = .{ .kind = "transcript-dump" } }
    ));
    try testing.expectError(error.ParseZon, Config.parse(testing.allocator, "not zon at all"));
}
