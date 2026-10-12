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
    /// Step id. Its kind is `pipeline.kindOf(role)`: any other id is custom.
    role: []const u8,
    /// Position in the pinned pipeline, so repeated ids stay distinguishable.
    step_index: usize = 0,
    /// Artifact names appended after the kind's listed input, oldest first;
    /// the driver builds the list (`pipeline.inputArtifacts`).
    artifacts: []const []const u8 = &.{},
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

// ---------------------------------------------------------------------------
// Shared input clipping (docs/specs/mission.md "Steps"): one rule for every
// strategy, applied where the substrate spine is assembled.
// ---------------------------------------------------------------------------

pub const Part = struct {
    /// The block exactly as it appears in the content, header included.
    text: []const u8,
    /// Never clipped or dropped (MISSION.md).
    pinned: bool = false,
};

pub const clip_marker = "\n[clipped to fit the context budget]\n";

/// The smallest clipped remainder worth keeping; below it the block is dropped.
const min_clipped_text = 16;

/// `prefix ++ blocks ++ suffix` within `max_tokens`. The prefix (the current
/// task), the suffix and pinned blocks are never dropped; the other blocks
/// are listed oldest first and are clipped from the oldest. When the
/// never-dropped part alone exceeds the budget the result is
/// `error.BudgetExceeded`, as at the seam.
pub fn fit(
    arena: std.mem.Allocator,
    prefix: []const u8,
    blocks: []const Part,
    suffix: []const u8,
    max_tokens: usize,
) error{ OutOfMemory, BudgetExceeded }![]const u8 {
    const max_bytes = max_tokens *| 4;
    var fixed = prefix.len + suffix.len;
    for (blocks) |b| {
        if (b.pinned) fixed += b.text.len;
    }
    if (fixed > max_bytes) return error.BudgetExceeded;

    var room = max_bytes - fixed;
    const kept = try arena.alloc([]const u8, blocks.len);
    var i = blocks.len;
    while (i > 0) {
        i -= 1;
        const b = blocks[i];
        if (b.pinned) {
            kept[i] = b.text;
        } else if (b.text.len <= room) {
            kept[i] = b.text;
            room -= b.text.len;
        } else if (room >= clip_marker.len + min_clipped_text) {
            var cut = room - clip_marker.len;
            while (cut > 0 and (b.text[cut] & 0xC0) == 0x80) cut -= 1;
            kept[i] = try std.fmt.allocPrint(arena, "{s}{s}", .{ b.text[0..cut], clip_marker });
            room -= kept[i].len;
        } else {
            kept[i] = "";
        }
    }

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, prefix);
    for (kept) |k| try out.appendSlice(arena, k);
    try out.appendSlice(arena, suffix);
    return out.items;
}

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

test "fit: everything under budget passes through in order" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const out = try fit(arena_state.allocator(), "TASK\n", &.{
        .{ .text = "old\n" },
        .{ .text = "new\n" },
    }, "TAIL\n", 100);
    try testing.expectEqualStrings("TASK\nold\nnew\nTAIL\n", out);
}

test "fit: older blocks are clipped first and the newest survives whole" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const old = "o" ** 400;
    const new = "n" ** 100;
    // prefix 10 + new 100 + 150 left for the old block.
    const budget = (10 + 100 + 150) / 4;
    const out = try fit(arena_state.allocator(), "P" ** 10, &.{ .{ .text = old }, .{ .text = new } }, "", budget);
    try testing.expect(estTokens(out) <= budget);
    try testing.expect(std.mem.indexOf(u8, out, new) != null);
    try testing.expect(std.mem.indexOf(u8, out, clip_marker) != null);
    try testing.expect(std.mem.indexOf(u8, out, old) == null);
    try testing.expect(std.mem.indexOf(u8, out, "ooooo") != null);
    try testing.expect(std.mem.startsWith(u8, out, "P" ** 10));
}

test "fit: an older block with no room left is dropped, not stubbed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const new = "n" ** 100;
    const out = try fit(arena_state.allocator(), "T", &.{ .{ .text = "o" ** 50 }, .{ .text = new } }, "", 26);
    try testing.expectEqualStrings("T" ++ new, out);
}

test "fit: pinned blocks are never dropped, even the oldest" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const mission = "MISSION-TEXT " ** 4;
    const out = try fit(arena_state.allocator(), "T", &.{
        .{ .text = mission, .pinned = true },
        .{ .text = "x" ** 400 },
    }, "", (1 + mission.len + 20) / 4 + 1);
    try testing.expect(std.mem.indexOf(u8, out, mission) != null);
    try testing.expect(std.mem.indexOf(u8, out, "x" ** 100) == null);
}

test "fit: the never-dropped part alone over budget is BudgetExceeded" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectError(error.BudgetExceeded, fit(arena, "x" ** 100, &.{}, "", 24));
    try testing.expectError(error.BudgetExceeded, fit(arena, "x" ** 50, &.{}, "y" ** 50, 24));
    try testing.expectError(error.BudgetExceeded, fit(arena, "x", &.{.{ .text = "m" ** 100, .pinned = true }}, "", 24));
    // The boundary itself fits: 25 tokens hold 100 bytes.
    const edge = try fit(arena, "x" ** 100, &.{.{ .text = "dropped" }}, "", 25);
    try testing.expectEqual(@as(usize, 100), edge.len);
}

test "fit: content stays within budget and valid UTF-8 across a budget sweep" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const blocks = [_]Part{
        .{ .text = "héllo wörld → " ** 12 },
        .{ .text = "日本語のテキスト" ** 9, .pinned = false },
        .{ .text = "naïve café " ** 8 },
    };
    var max: usize = 0;
    while (max < 120) : (max += 1) {
        const out = fit(arena, "task ", &blocks, "tail", max) catch |err| switch (err) {
            error.BudgetExceeded => continue,
            error.OutOfMemory => return err,
        };
        try testing.expect(estTokens(out) <= max);
        try testing.expect(std.unicode.utf8ValidateSlice(out));
    }
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
