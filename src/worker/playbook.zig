//! Role playbook as data (M7): role system prompts live here, not in the
//! mission driver, and a `role-<step-id>.md` artifact in the planning root
//! overrides the built-in — the factory defines role variants and the radar
//! tunes its researcher without a rebuild. Reply-shape contracts stay with
//! the driver's parsers (fail-closed): an override changes HOW a role is
//! prompted, never what output shape the pipeline accepts.

const std = @import("std");
const context = @import("context.zig");

/// Built-in prompt for a step id; null for unknown roles.
pub fn defaultSystem(role_id: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, role_id, "product-owner"))
        return "You are the product-owner of a mission. Refine the raw objective " ++
            "you are given. Reply with ONLY a JSON object: " ++
            "{\"objective\": <one precise sentence>, \"acceptance\": <how completion is judged>}.";
    if (std.mem.eql(u8, role_id, "planner"))
        return "You are the planner of a mission. Break the objective into ordered, " ++
            "independently executable tasks. Prefer few substantive tasks; each task " ++
            "validates its own work, so never emit separate verify-only or " ++
            "run-the-tests-again tasks. Reply with ONLY a JSON object: " ++
            "{\"tasks\": [<task description>, ...]}.";
    if (std.mem.eql(u8, role_id, "executor"))
        return "You are the executor of a mission. Complete the single task you are " ++
            "given, using the available tools when they help. The bash tool already runs " ++
            "in the mission workspace — work there with relative paths; do not create " ++
            "directories elsewhere or probe $HOME.";
    if (std.mem.eql(u8, role_id, "verifier"))
        return "You are the verifier of a mission. Judge whether the executed plan " ++
            "meets the objective and its acceptance criteria. Reply with ONLY a JSON " ++
            "object: {\"passed\": true|false, \"reason\": <one sentence>}.";
    return null;
}

/// The override artifact's name for a step id: `role-<id>.md`.
pub fn artifactName(arena: std.mem.Allocator, role_id: []const u8) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(arena, "role-{s}.md", .{role_id});
}

/// The effective system prompt: a non-empty override artifact wins, else
/// the built-in; null when the role is unknown and nothing overrides it.
pub fn resolve(
    arena: std.mem.Allocator,
    substrate: context.Substrate,
    role_id: []const u8,
) error{OutOfMemory}!?[]const u8 {
    const name = try artifactName(arena, role_id);
    if (substrate.read(arena, name)) |body| {
        const trimmed = std.mem.trim(u8, body, " \t\r\n");
        if (trimmed.len > 0) return trimmed;
    }
    return defaultSystem(role_id);
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "defaultSystem covers the four pipeline roles; unknown is null" {
    for ([_][]const u8{ "product-owner", "planner", "executor", "verifier" }) |id| {
        try testing.expect(defaultSystem(id) != null);
    }
    // The reply-shape contracts stay in the prompts.
    try testing.expect(std.mem.indexOf(u8, defaultSystem("planner").?, "\"tasks\"") != null);
    try testing.expect(std.mem.indexOf(u8, defaultSystem("verifier").?, "\"passed\"") != null);
    try testing.expect(defaultSystem("reviewer") == null);
}

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

test "resolve: a non-empty role-<id>.md override wins; else the built-in; unknown null" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sub = FakeSub{ .name = "role-executor.md", .body = "You are orchy's integrator.\n" };
    const got = (try resolve(arena, sub.substrate(), "executor")).?;
    try testing.expectEqualStrings("You are orchy's integrator.", got);

    // No override for the planner: the built-in.
    const planner = (try resolve(arena, sub.substrate(), "planner")).?;
    try testing.expectEqualStrings(defaultSystem("planner").?, planner);

    // A whitespace-only override does not blank a role's prompt.
    var blank = FakeSub{ .name = "role-executor.md", .body = "  \n\t\n" };
    const kept = (try resolve(arena, blank.substrate(), "executor")).?;
    try testing.expectEqualStrings(defaultSystem("executor").?, kept);

    try testing.expect((try resolve(arena, sub.substrate(), "reviewer")) == null);
}
