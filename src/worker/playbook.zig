//! Role playbook override (M7): a `role-<step-id>.md` artifact in the planning
//! root replaces a step's built-in behaviour text — the factory defines role
//! variants and the radar tunes its researcher without a rebuild. The
//! built-in prompts and the reply-format contracts live in
//! `mission/pipeline.zig` (`systemPrompt`), which appends the contract after
//! whichever prompt wins: an override changes HOW a step is prompted, never
//! what output shape the pipeline accepts.

const std = @import("std");
const context = @import("context.zig");

/// The override artifact's name for a step id: `role-<id>.md`.
pub fn artifactName(arena: std.mem.Allocator, role_id: []const u8) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(arena, "role-{s}.md", .{role_id});
}

/// The trimmed text of a non-empty `role-<id>.md` override; null when the
/// artifact is absent or blank (a whitespace-only file never blanks a prompt).
pub fn overrideFor(
    arena: std.mem.Allocator,
    substrate: context.Substrate,
    role_id: []const u8,
) error{OutOfMemory}!?[]const u8 {
    const name = try artifactName(arena, role_id);
    const body = substrate.read(arena, name) orelse return null;
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    return if (trimmed.len > 0) trimmed else null;
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

const FakeSub = struct {
    name: []const u8 = "",
    body: []const u8 = "",

    fn read(ctx: *anyopaque, arena: std.mem.Allocator, name: []const u8) ?[]const u8 {
        const self: *FakeSub = @ptrCast(@alignCast(ctx));
        if (!std.mem.eql(u8, name, self.name)) return null;
        return arena.dupe(u8, self.body) catch null;
    }

    fn substrate(self: *FakeSub) context.Substrate {
        return .{ .ctx = @ptrCast(self), .readFn = &read };
    }
};

test "overrideFor: a non-empty role-<id>.md wins; absent or blank is null" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sub = FakeSub{ .name = "role-executor.md", .body = "You are orchy's integrator.\n" };
    const got = (try overrideFor(arena, sub.substrate(), "executor")).?;
    try testing.expectEqualStrings("You are orchy's integrator.", got);

    // No override for the planner.
    try testing.expect((try overrideFor(arena, sub.substrate(), "planner")) == null);

    // A whitespace-only override does not blank a role's prompt.
    var blank = FakeSub{ .name = "role-executor.md", .body = "  \n\t\n" };
    try testing.expect((try overrideFor(arena, blank.substrate(), "executor")) == null);

    // Custom ids resolve by the same name rule.
    var custom = FakeSub{ .name = "role-architect.md", .body = "You design." };
    try testing.expectEqualStrings("You design.", (try overrideFor(arena, custom.substrate(), "architect")).?);
}
