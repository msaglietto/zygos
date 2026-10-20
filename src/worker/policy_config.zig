//! `.policy` in zygos.zon (docs/specs/policy-config.md): the operator's
//! ordered rule list for the policy worker. Pure and std-only: no I/O, the
//! caller reads the file. The CLI makes exactly two calls and holds no
//! policy logic:
//!
//!   1. `resolve` before the kernel boots: the strict ZON parse and every
//!      structural refusal, plus the dead-step check against the pipeline.
//!   2. `effective` after the MCP handshake: the dead-tool check against the
//!      offered tools, then the rule list for `PolicyWorker.start`.
//!
//! Fail closed throughout: a refusal never degrades to the seed, and only an
//! absent `.policy` ever becomes the seed.

const std = @import("std");
const Zoir = std.zig.Zoir;
const policy = @import("policy.zig");

/// A tool a mission step can be handed, as the policy worker sees it: the
/// model-facing name and the bus function id.
pub const Offered = struct {
    name: []const u8,
    function_id: []const u8,
};

/// The built-in tools every mission step can be offered. Also the head of
/// the absent-config seed, so the two cannot drift.
pub const base_offered = [_]Offered{
    .{ .name = "bash", .function_id = "zygos::tools::bash" },
    .{ .name = "web_fetch", .function_id = "zygos::tools::web_fetch" },
    .{ .name = "web_search", .function_id = "zygos::tools::web_search" },
};

/// Outcome of the pre-boot step. Everything referenced lives in the arena
/// passed to `resolve`; `refused` is a static string or arena-allocated.
pub const Resolved = union(enum) {
    /// No `.policy` key: the seed governs.
    absent,
    /// A valid list in file order, `step` null when the entry has none.
    rules: []policy.Rule,
    /// The reason, without the `mission: invalid .policy in <path>: ` prefix.
    refused: []const u8,
};

/// Outcome of the post-handshake step; slices live in the arena passed to
/// `effective` (or alias the `Resolved` it was given).
pub const Effective = union(enum) {
    rules: []const policy.Rule,
    refused: []const u8,
};

/// The absent-config rule list: `base_offered` names, then each MCP tool's
/// model-facing name, all allow and unscoped. `mcp_tools` strings are
/// aliased, not copied; the slice itself is `gpa`-owned.
pub fn seed(gpa: std.mem.Allocator, mcp_tools: []const []const u8) error{OutOfMemory}![]policy.Rule {
    var rules = try gpa.alloc(policy.Rule, base_offered.len + mcp_tools.len);
    for (base_offered, 0..) |o, i| rules[i] = .{ .tool = o.name, .verdict = .allow };
    for (mcp_tools, 0..) |name, i| rules[base_offered.len + i] = .{ .tool = name, .verdict = .allow };
    return rules;
}

const Parsed = union(enum) { rule: policy.Rule, refused: []const u8 };

/// Strict extraction of `.policy` from the full zygos.zon text; other
/// top-level keys are ignored. `scratch` holds the AST and is released
/// before returning; rules and their strings live in `arena`. A parse
/// failure of any kind is `policy: malformed`.
pub fn resolve(
    scratch: std.mem.Allocator,
    arena: std.mem.Allocator,
    text: [:0]const u8,
    step_ids: []const []const u8,
) error{OutOfMemory}!Resolved {
    var ast = try std.zig.Ast.parse(scratch, text, .zon);
    defer ast.deinit(scratch);
    const zoir = try std.zig.ZonGen.generate(scratch, ast, .{});
    defer zoir.deinit(scratch);
    if (ast.errors.len > 0 or zoir.hasCompileErrors()) return .{ .refused = "policy: malformed" };

    const fields = switch (Zoir.Node.Index.root.get(zoir)) {
        .struct_literal => |s| s,
        else => return .absent,
    };
    const policy_node = for (fields.names, 0..) |name, k| {
        if (std.mem.eql(u8, name.get(zoir), "policy")) break fields.vals.at(@intCast(k));
    } else return .absent;

    const items = switch (policy_node.get(zoir)) {
        .empty_literal => return .{ .refused = "policy: empty" },
        .array_literal => |r| r,
        else => return .{ .refused = "policy: malformed" },
    };
    const rules = try arena.alloc(policy.Rule, items.len);
    for (rules, 0..) |*rule, i| {
        switch (try parseEntry(arena, zoir, items.at(@intCast(i)), i, step_ids)) {
            .rule => |r| rule.* = r,
            .refused => |reason| return .{ .refused = reason },
        }
    }
    return .{ .rules = rules };
}

/// One entry. Check order is fixed: unknown key, tool, verdict, step shape,
/// step existence; the first failure of the first offending entry wins.
fn parseEntry(
    arena: std.mem.Allocator,
    zoir: Zoir,
    node: Zoir.Node.Index,
    i: usize,
    step_ids: []const []const u8,
) error{OutOfMemory}!Parsed {
    const names, const vals = switch (node.get(zoir)) {
        .empty_literal => .{ &[_]Zoir.NullTerminatedString{}, undefined },
        .struct_literal => |s| .{ s.names, s.vals },
        else => return refuse(arena, "policy[{d}]: malformed", .{i}),
    };

    var tool_node: ?Zoir.Node.Index = null;
    var verdict_node: ?Zoir.Node.Index = null;
    var step_node: ?Zoir.Node.Index = null;
    for (names, 0..) |name_nts, k| {
        const name = name_nts.get(zoir);
        const val = vals.at(@intCast(k));
        if (std.mem.eql(u8, name, "tool")) {
            tool_node = val;
        } else if (std.mem.eql(u8, name, "verdict")) {
            verdict_node = val;
        } else if (std.mem.eql(u8, name, "step")) {
            step_node = val;
        } else return refuse(arena, "policy[{d}]: unknown key \"{s}\"", .{ i, name });
    }

    const tool_val = tool_node orelse return refuse(arena, "policy[{d}]: missing tool", .{i});
    const tool = switch (tool_val.get(zoir)) {
        .string_literal => |s| s,
        else => return refuse(arena, "policy[{d}]: bad tool pattern", .{i}),
    };
    if (tool.len == 0) return refuse(arena, "policy[{d}]: empty tool", .{i});
    if (!starOnlyLast(tool)) return refuse(arena, "policy[{d}]: bad tool pattern", .{i});

    const verdict_val = verdict_node orelse return refuse(arena, "policy[{d}]: missing verdict", .{i});
    const verdict: policy.Verdict = switch (verdict_val.get(zoir)) {
        .enum_literal => |lit| std.meta.stringToEnum(policy.Verdict, lit.get(zoir)) orelse
            return refuse(arena, "policy[{d}]: bad verdict", .{i}),
        else => return refuse(arena, "policy[{d}]: bad verdict", .{i}),
    };

    var step: ?[]const u8 = null;
    if (step_node) |sn| {
        const pattern = switch (sn.get(zoir)) {
            .string_literal => |s| s,
            else => return refuse(arena, "policy[{d}]: bad step pattern", .{i}),
        };
        if (!validStepPattern(pattern)) return refuse(arena, "policy[{d}]: bad step pattern", .{i});
        if (!matchesAnyStep(pattern, step_ids))
            return refuse(arena, "policy[{d}]: step \"{s}\" matches no configured step", .{ i, pattern });
        step = try arena.dupe(u8, pattern);
    }

    return .{ .rule = .{ .tool = try arena.dupe(u8, tool), .verdict = verdict, .step = step } };
}

fn refuse(arena: std.mem.Allocator, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!Parsed {
    return .{ .refused = try std.fmt.allocPrint(arena, fmt, args) };
}

/// No `*` except possibly as the last character.
fn starOnlyLast(pattern: []const u8) bool {
    const star = std.mem.indexOfScalar(u8, pattern, '*') orelse return true;
    return star == pattern.len - 1;
}

/// `[a-z0-9-]{1,32}`, or `[a-z0-9-]{0,32}` followed by one trailing `*`.
fn validStepPattern(pattern: []const u8) bool {
    if (pattern.len == 0) return false;
    const glob = pattern[pattern.len - 1] == '*';
    const base = if (glob) pattern[0 .. pattern.len - 1] else pattern;
    if (base.len > 32) return false;
    for (base) |c| switch (c) {
        'a'...'z', '0'...'9', '-' => {},
        else => return false,
    };
    return true;
}

fn matchesAnyStep(pattern: []const u8, step_ids: []const []const u8) bool {
    if (std.mem.eql(u8, pattern, "*")) return true;
    for (step_ids) |id| if (policy.matches(pattern, id)) return true;
    return false;
}

/// The post-handshake step. Only `.absent` becomes the seed (`offered`
/// minus the base tools supplies the MCP names); a refused resolution comes
/// back as the same refusal; a configured list is returned verbatim once
/// every tool pattern matches some offered tool's name or function id.
pub fn effective(
    arena: std.mem.Allocator,
    resolved: Resolved,
    offered: []const Offered,
) error{OutOfMemory}!Effective {
    switch (resolved) {
        .refused => |reason| return .{ .refused = reason },
        .absent => {
            var mcp_names: std.ArrayList([]const u8) = .empty;
            for (offered) |o| {
                if (!isBase(o)) try mcp_names.append(arena, o.name);
            }
            return .{ .rules = try seed(arena, mcp_names.items) };
        },
        .rules => |rules| {
            for (rules, 0..) |r, i| {
                if (!matchesAnyOffered(r.tool, offered)) {
                    return .{ .refused = try std.fmt.allocPrint(
                        arena,
                        "policy[{d}]: tool \"{s}\" matches no offered tool",
                        .{ i, r.tool },
                    ) };
                }
            }
            return .{ .rules = rules };
        },
    }
}

fn isBase(o: Offered) bool {
    for (base_offered) |b| if (std.mem.eql(u8, b.function_id, o.function_id)) return true;
    return false;
}

fn matchesAnyOffered(pattern: []const u8, offered: []const Offered) bool {
    if (std.mem.eql(u8, pattern, "*")) return true;
    for (offered) |o| {
        if (policy.matches(pattern, o.name) or policy.matches(pattern, o.function_id)) return true;
    }
    return false;
}

// ===========================================================================
// Tests (docs/specs/policy-config.md "Test contract", items 1-10)
// ===========================================================================

const testing = std.testing;

const default_ids = [_][]const u8{ "product-owner", "planner", "executor", "verifier" };
const custom_ids = [_][]const u8{ "architect", "research-web", "executor" };
const mcp_offered = [_]Offered{
    .{ .name = "tavily_search", .function_id = "zygos::mcp::tavily::search" },
    .{ .name = "tavily_extract", .function_id = "zygos::mcp::tavily::extract" },
};

fn offeredWith(arena: std.mem.Allocator, extra: []const Offered) ![]Offered {
    return std.mem.concat(arena, Offered, &.{ &base_offered, extra });
}

/// Resolve then effective, with the MCP offered list; returns the refusal
/// reason or null when the list is accepted.
fn refusalOf(arena: std.mem.Allocator, zon: [:0]const u8, ids: []const []const u8, extra: []const Offered) !?[]const u8 {
    const resolved = try resolve(testing.allocator, arena, zon, ids);
    switch (resolved) {
        .refused => |r| return r,
        .absent => return null,
        .rules => {},
    }
    const eff = try effective(arena, resolved, try offeredWith(arena, extra));
    return switch (eff) {
        .refused => |r| r,
        .rules => null,
    };
}

fn expectRefusal(zon: [:0]const u8, ids: []const []const u8, extra: []const Offered, want: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const got = try refusalOf(arena_state.allocator(), zon, ids, extra);
    try testing.expect(got != null);
    try testing.expectEqualStrings(want, got.?);
}

fn expectAccepted(zon: [:0]const u8, ids: []const []const u8, extra: []const Offered) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    if (try refusalOf(arena_state.allocator(), zon, ids, extra)) |r| {
        std.debug.print("unexpected refusal: {s}\n", .{r});
        return error.TestUnexpectedResult;
    }
}

test "absent policy yields today's seed" {
    const mission_boot = @import("mission_boot.zig");
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const resolved = try resolve(testing.allocator, arena,
        \\.{ .default = .{}, .routes = .{}, .mcp_servers = .{} }
    , &default_ids);
    try testing.expect(resolved == .absent);

    const offered = try offeredWith(arena, &mcp_offered);
    const eff = try effective(arena, resolved, offered);
    const got = eff.rules;

    const names = [_][]const u8{ "tavily_search", "tavily_extract" };
    const want = try mission_boot.policySeed(testing.allocator, &names);
    defer testing.allocator.free(want);
    try testing.expectEqual(@as(usize, 5), want.len);
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| {
        try testing.expectEqualStrings(w.tool, g.tool);
        try testing.expectEqual(w.verdict, g.verdict);
        try testing.expectEqual(policy.Verdict.allow, g.verdict);
        try testing.expect(g.step == null);
    }

    // No MCP tools: the bare base seed.
    const bare = try effective(arena, resolved, &base_offered);
    try testing.expectEqual(@as(usize, 3), bare.rules.len);
    try testing.expectEqualStrings("bash", bare.rules[0].tool);
    try testing.expectEqualStrings("web_fetch", bare.rules[1].tool);
    try testing.expectEqualStrings("web_search", bare.rules[2].tool);
}

test "present policy replaces the seed in file order" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const resolved = try resolve(testing.allocator, arena,
        \\.{ .policy = .{
        \\    .{ .tool = "web_*", .verdict = .ask },
        \\    .{ .tool = "bash", .verdict = .deny },
        \\    .{ .tool = "bash", .verdict = .allow },
        \\} }
    , &default_ids);
    const rules = resolved.rules;
    try testing.expectEqual(@as(usize, 3), rules.len);
    try testing.expectEqualStrings("web_*", rules[0].tool);
    try testing.expectEqual(policy.Verdict.ask, rules[0].verdict);
    try testing.expectEqualStrings("bash", rules[1].tool);
    try testing.expectEqual(policy.Verdict.deny, rules[1].verdict);
    try testing.expectEqualStrings("bash", rules[2].tool);
    try testing.expectEqual(policy.Verdict.allow, rules[2].verdict);

    // Nothing from the seed is prepended or appended, MCP names included.
    const eff = try effective(arena, resolved, try offeredWith(arena, &mcp_offered));
    try testing.expectEqual(@as(usize, 3), eff.rules.len);
    for (rules, eff.rules) |a, b| {
        try testing.expectEqualStrings(a.tool, b.tool);
        try testing.expectEqual(a.verdict, b.verdict);
    }
}

test "step pattern round-trips into Rule.step and absent step is null" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const resolved = try resolve(testing.allocator, arena,
        \\.{ .policy = .{
        \\    .{ .tool = "bash", .verdict = .deny, .step = "architect" },
        \\    .{ .tool = "bash", .verdict = .allow },
        \\    .{ .tool = "web_*", .verdict = .ask, .step = "research*" },
        \\} }
    , &custom_ids);
    const rules = resolved.rules;
    try testing.expectEqual(@as(usize, 3), rules.len);
    try testing.expectEqualStrings("architect", rules[0].step.?);
    try testing.expect(rules[1].step == null);
    try testing.expectEqualStrings("research*", rules[2].step.?);
}

test "other top-level keys are ignored by the policy parser" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const resolved = try resolve(testing.allocator, arena,
        \\.{
        \\    .default = .{ .{ .provider_function = "zygos::providers::x", .model = "m" } },
        \\    .routes = .{},
        \\    .mcp_servers = .{ .{ .name = "tavily", .argv = .{ "npx" } } },
        \\    .steps = .{ .{ .id = "executor" } },
        \\    .context_strategy = .{ .kind = "recall" },
        \\    .policy = .{ .{ .tool = "bash", .verdict = .allow } },
        \\    .whatever = 7,
        \\}
    , &default_ids);
    try testing.expectEqual(@as(usize, 1), resolved.rules.len);
    try testing.expectEqualStrings("bash", resolved.rules[0].tool);

    // A file with no `.policy` at all is absent.
    try testing.expect((try resolve(testing.allocator, arena, ".{ .routes = .{} }", &default_ids)) == .absent);
    try testing.expect((try resolve(testing.allocator, arena, ".{}", &default_ids)) == .absent);
}

test "policy malformed refuses" {
    // not a tuple: a struct, a string, a number, a bool
    try expectRefusal(".{ .policy = .{ .tool = \"bash\", .verdict = .allow } }", &default_ids, &.{}, "policy: malformed");
    try expectRefusal(".{ .policy = \"bash\" }", &default_ids, &.{}, "policy: malformed");
    try expectRefusal(".{ .policy = 3 }", &default_ids, &.{}, "policy: malformed");
    try expectRefusal(".{ .policy = true }", &default_ids, &.{}, "policy: malformed");
    // the file does not parse as ZON
    try expectRefusal(".{ .policy = .{ ", &default_ids, &.{}, "policy: malformed");
    try expectRefusal(".{ .policy = .{ .{ .tool = \"bash\" .verdict = .allow } } }", &default_ids, &.{}, "policy: malformed");
    // duplicate keys inside one entry fail ZON generation
    try expectRefusal(".{ .policy = .{ .{ .tool = \"a\", .tool = \"b\", .verdict = .allow } } }", &default_ids, &.{}, "policy: malformed");
    // a duplicated top-level .policy key as well
    try expectRefusal(".{ .policy = .{ .{ .tool = \"bash\", .verdict = .allow } }, .policy = .{} }", &default_ids, &.{}, "policy: malformed");
}

test "policy empty refuses" {
    try expectRefusal(".{ .policy = .{} }", &default_ids, &.{}, "policy: empty");
}

test "policy non-struct entry refuses" {
    try expectRefusal(".{ .policy = .{ \"bash\" } }", &default_ids, &.{}, "policy[0]: malformed");
    try expectRefusal(
        \\.{ .policy = .{ .{ .tool = "bash", .verdict = .allow }, 7 } }
    , &default_ids, &.{}, "policy[1]: malformed");
    try expectRefusal(".{ .policy = .{ .{ \"bash\", .allow } } }", &default_ids, &.{}, "policy[0]: malformed");
}

test "policy unknown key refuses naming the entry" {
    try expectRefusal(
        \\.{ .policy = .{
        \\    .{ .tool = "bash", .verdict = .allow },
        \\    .{ .tool = "bash", .verdict = .deny, .reason = "x" },
        \\} }
    , &default_ids, &.{}, "policy[1]: unknown key \"reason\"");
    // unknown key wins over a missing tool in the same entry
    try expectRefusal(".{ .policy = .{ .{ .verdict = .allow, .toool = \"b\" } } }", &default_ids, &.{}, "policy[0]: unknown key \"toool\"");
}

test "policy missing tool refuses" {
    try expectRefusal(".{ .policy = .{ .{ .verdict = .allow } } }", &default_ids, &.{}, "policy[0]: missing tool");
    try expectRefusal(".{ .policy = .{ .{} } }", &default_ids, &.{}, "policy[0]: missing tool");
}

test "policy empty tool refuses" {
    try expectRefusal(".{ .policy = .{ .{ .tool = \"\", .verdict = .allow } } }", &default_ids, &.{}, "policy[0]: empty tool");
}

test "policy bad tool pattern refuses" {
    try expectRefusal(".{ .policy = .{ .{ .tool = \"ba*sh\", .verdict = .allow } } }", &default_ids, &.{}, "policy[0]: bad tool pattern");
    try expectRefusal(".{ .policy = .{ .{ .tool = \"*bash\", .verdict = .allow } } }", &default_ids, &.{}, "policy[0]: bad tool pattern");
    try expectRefusal(".{ .policy = .{ .{ .tool = \"**\", .verdict = .allow } } }", &default_ids, &.{}, "policy[0]: bad tool pattern");
    try expectRefusal(".{ .policy = .{ .{ .tool = 7, .verdict = .allow } } }", &default_ids, &.{}, "policy[0]: bad tool pattern");
    try expectRefusal(".{ .policy = .{ .{ .tool = .bash, .verdict = .allow } } }", &default_ids, &.{}, "policy[0]: bad tool pattern");
}

test "policy missing verdict refuses" {
    try expectRefusal(".{ .policy = .{ .{ .tool = \"bash\" } } }", &default_ids, &.{}, "policy[0]: missing verdict");
}

test "policy bad verdict refuses" {
    try expectRefusal(".{ .policy = .{ .{ .tool = \"bash\", .verdict = .maybe } } }", &default_ids, &.{}, "policy[0]: bad verdict");
    try expectRefusal(".{ .policy = .{ .{ .tool = \"bash\", .verdict = \"allow\" } } }", &default_ids, &.{}, "policy[0]: bad verdict");
    try expectRefusal(".{ .policy = .{ .{ .tool = \"bash\", .verdict = true } } }", &default_ids, &.{}, "policy[0]: bad verdict");
    try expectRefusal(".{ .policy = .{ .{ .tool = \"bash\", .verdict = .Allow } } }", &default_ids, &.{}, "policy[0]: bad verdict");
}

test "policy bad step pattern refuses" {
    const long33 = "a" ** 33;
    try expectRefusal(".{ .policy = .{ .{ .tool = \"bash\", .verdict = .deny, .step = \"\" } } }", &default_ids, &.{}, "policy[0]: bad step pattern");
    try expectRefusal(".{ .policy = .{ .{ .tool = \"bash\", .verdict = .deny, .step = \"pla*ner\" } } }", &default_ids, &.{}, "policy[0]: bad step pattern");
    try expectRefusal(".{ .policy = .{ .{ .tool = \"bash\", .verdict = .deny, .step = \"*planner\" } } }", &default_ids, &.{}, "policy[0]: bad step pattern");
    try expectRefusal(".{ .policy = .{ .{ .tool = \"bash\", .verdict = .deny, .step = \"**\" } } }", &default_ids, &.{}, "policy[0]: bad step pattern");
    try expectRefusal(".{ .policy = .{ .{ .tool = \"bash\", .verdict = .deny, .step = \"Planner\" } } }", &default_ids, &.{}, "policy[0]: bad step pattern");
    try expectRefusal(".{ .policy = .{ .{ .tool = \"bash\", .verdict = .deny, .step = \"plan ner\" } } }", &default_ids, &.{}, "policy[0]: bad step pattern");
    try expectRefusal(".{ .policy = .{ .{ .tool = \"bash\", .verdict = .deny, .step = \"" ++ long33 ++ "\" } } }", &default_ids, &.{}, "policy[0]: bad step pattern");
    try expectRefusal(".{ .policy = .{ .{ .tool = \"bash\", .verdict = .deny, .step = \"" ++ long33 ++ "*\" } } }", &default_ids, &.{}, "policy[0]: bad step pattern");
    try expectRefusal(".{ .policy = .{ .{ .tool = \"bash\", .verdict = .deny, .step = 3 } } }", &default_ids, &.{}, "policy[0]: bad step pattern");
    try expectRefusal(".{ .policy = .{ .{ .tool = \"bash\", .verdict = .deny, .step = .planner } } }", &default_ids, &.{}, "policy[0]: bad step pattern");
    // 32 characters is the longest accepted exact id (here it then matches no step).
    const long32 = "a" ** 32;
    try expectRefusal(".{ .policy = .{ .{ .tool = \"bash\", .verdict = .deny, .step = \"" ++ long32 ++ "\" } } }", &default_ids, &.{}, "policy[0]: step \"" ++ long32 ++ "\" matches no configured step");
}

test "policy step matching no configured step refuses" {
    // exact, configured pipeline: the typo from the spec
    try expectRefusal(
        \\.{ .policy = .{
        \\    .{ .tool = "bash", .verdict = .deny, .step = "archtect" },
        \\    .{ .tool = "bash", .verdict = .allow },
        \\} }
    , &custom_ids, &.{}, "policy[0]: step \"archtect\" matches no configured step");
    try expectRefusal(
        \\.{ .policy = .{ .{ .tool = "bash", .verdict = .allow }, .{ .tool = "bash", .verdict = .deny, .step = "architect" } } }
    , &default_ids, &.{}, "policy[1]: step \"architect\" matches no configured step");
    // glob that prefix-matches nothing
    try expectRefusal(
        \\.{ .policy = .{ .{ .tool = "bash", .verdict = .deny, .step = "research*" } } }
    , &default_ids, &.{}, "policy[0]: step \"research*\" matches no configured step");
    // a configured .steps: ids of the default four no longer exist
    try expectRefusal(
        \\.{ .policy = .{ .{ .tool = "bash", .verdict = .deny, .step = "planner" } } }
    , &custom_ids, &.{}, "policy[0]: step \"planner\" matches no configured step");
    try expectRefusal(
        \\.{ .policy = .{ .{ .tool = "bash", .verdict = .deny, .step = "plan*" } } }
    , &custom_ids, &.{}, "policy[0]: step \"plan*\" matches no configured step");
    // the first offending entry in list order wins over a later structural error
    try expectRefusal(
        \\.{ .policy = .{
        \\    .{ .tool = "bash", .verdict = .deny, .step = "nope" },
        \\    .{ .verdict = .deny },
        \\} }
    , &default_ids, &.{}, "policy[0]: step \"nope\" matches no configured step");
    // ... and an earlier structural error wins over a later dead step
    try expectRefusal(
        \\.{ .policy = .{
        \\    .{ .verdict = .deny },
        \\    .{ .tool = "bash", .verdict = .deny, .step = "nope" },
        \\} }
    , &default_ids, &.{}, "policy[0]: missing tool");
}

test "policy tool matching no offered tool refuses" {
    try expectRefusal(".{ .policy = .{ .{ .tool = \"bash\", .verdict = .allow }, .{ .tool = \"read_file\", .verdict = .allow } } }", &default_ids, &.{}, "policy[1]: tool \"read_file\" matches no offered tool");
    try expectRefusal(".{ .policy = .{ .{ .tool = \"zygos::mcp::*\", .verdict = .allow } } }", &default_ids, &.{}, "policy[0]: tool \"zygos::mcp::*\" matches no offered tool");
    try expectRefusal(".{ .policy = .{ .{ .tool = \"write_*\", .verdict = .deny } } }", &default_ids, &.{}, "policy[0]: tool \"write_*\" matches no offered tool");
    // a refused list is never an allow: no rules come back
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const resolved = try resolve(testing.allocator, arena, ".{ .policy = .{ .{ .tool = \"nope\", .verdict = .allow } } }", &default_ids);
    const eff = try effective(arena, resolved, &base_offered);
    try testing.expect(eff == .refused);
}

test "effective never turns a refused resolution into the seed or an allow" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const eff = try effective(arena, .{ .refused = "policy: malformed" }, &base_offered);
    try testing.expect(eff == .refused);
    try testing.expectEqualStrings("policy: malformed", eff.refused);
}

test "step glob matching a configured step is accepted and star alone always passes" {
    try expectAccepted(
        \\.{ .policy = .{
        \\    .{ .tool = "bash", .verdict = .deny, .step = "research*" },
        \\    .{ .tool = "bash", .verdict = .deny, .step = "arch*" },
        \\    .{ .tool = "bash", .verdict = .deny, .step = "executor" },
        \\    .{ .tool = "bash", .verdict = .allow, .step = "*" },
        \\} }
    , &custom_ids, &.{});
    // `*` passes even against an empty step list
    try expectAccepted(".{ .policy = .{ .{ .tool = \"bash\", .verdict = .ask, .step = \"*\" } } }", &.{}, &.{});
    // `*` for the tool passes against the base list too
    try expectAccepted(".{ .policy = .{ .{ .tool = \"*\", .verdict = .deny } } }", &default_ids, &.{});
}

test "mcp tools are matched by model name or function id" {
    try expectAccepted(".{ .policy = .{ .{ .tool = \"tavily_search\", .verdict = .allow } } }", &default_ids, &mcp_offered);
    try expectAccepted(".{ .policy = .{ .{ .tool = \"zygos::mcp::tavily::search\", .verdict = .allow } } }", &default_ids, &mcp_offered);
    try expectAccepted(".{ .policy = .{ .{ .tool = \"tavily_*\", .verdict = .allow } } }", &default_ids, &mcp_offered);
    try expectAccepted(".{ .policy = .{ .{ .tool = \"zygos::mcp::tavily::*\", .verdict = .allow } } }", &default_ids, &mcp_offered);
    try expectAccepted(".{ .policy = .{ .{ .tool = \"zygos::mcp::*\", .verdict = .allow } } }", &default_ids, &mcp_offered);
    // base tools by function id too
    try expectAccepted(".{ .policy = .{ .{ .tool = \"zygos::tools::bash\", .verdict = .allow } } }", &default_ids, &.{});
    try expectAccepted(".{ .policy = .{ .{ .tool = \"zygos::tools::*\", .verdict = .allow } } }", &default_ids, &.{});
    // wrong server or tool stays refused
    try expectRefusal(".{ .policy = .{ .{ .tool = \"brave_*\", .verdict = .allow } } }", &default_ids, &mcp_offered, "policy[0]: tool \"brave_*\" matches no offered tool");
    try expectRefusal(".{ .policy = .{ .{ .tool = \"tavily_crawl\", .verdict = .allow } } }", &default_ids, &mcp_offered, "policy[0]: tool \"tavily_crawl\" matches no offered tool");
    try expectRefusal(".{ .policy = .{ .{ .tool = \"zygos::mcp::brave::*\", .verdict = .allow } } }", &default_ids, &mcp_offered, "policy[0]: tool \"zygos::mcp::brave::*\" matches no offered tool");
}

test "step-scoped rule on a step without tools is accepted" {
    // The step check sees ids only; `.tools = false` on the verifier does not
    // make a rule scoped to it a dead rule.
    try expectAccepted(".{ .policy = .{ .{ .tool = \"bash\", .verdict = .deny, .step = \"verifier\" } } }", &default_ids, &.{});
}

test "lenient router, context and mcp parses ignore .policy" {
    const router = @import("router.zig");
    const context = @import("context.zig");
    const mcp_config = @import("mcp/config.zig");
    const zon: [:0]const u8 =
        \\.{
        \\    .default = .{ .{ .provider_function = "zygos::providers::x", .model = "m" } },
        \\    .routes = .{},
        \\    .context_strategy = .{ .kind = "recall", .max_tokens = 9000 },
        \\    .mcp_servers = .{ .{ .name = "tavily", .argv = .{ "npx", "-y", "tavily-mcp" } } },
        \\    .policy = .{
        \\        .{ .tool = "bash", .verdict = .deny, .step = "architect" },
        \\        .{ .tool = "zygos::mcp::*", .verdict = .allow },
        \\        .{ .verdict = "not even valid", .bogus = 1 },
        \\    },
        \\}
    ;
    var rc = try router.Config.parse(testing.allocator, zon);
    defer rc.deinit();
    const attempt = rc.resolve("executor", 0) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("zygos::providers::x", attempt.provider_function);

    const cc = try context.Config.parse(testing.allocator, zon);
    try testing.expectEqual(context.Kind.recall, cc.kind);
    try testing.expectEqual(@as(usize, 9000), cc.max_tokens);

    var mc = try mcp_config.McpConfig.parse(testing.allocator, zon);
    defer mc.deinit();
    try testing.expectEqual(@as(usize, 1), mc.servers().len);
    try testing.expectEqualStrings("tavily", mc.servers()[0].name);
}

test "no leaks across resolve and refusal paths" {
    // Scratch and arena backing are both the leak-checking allocator.
    const texts = [_][:0]const u8{
        ".{ .routes = .{} }",
        ".{ .policy = .{ .{ .tool = \"bash\", .verdict = .deny, .step = \"executor\" }, .{ .tool = \"tavily_*\", .verdict = .ask } } }",
        ".{ .policy = .{} }",
        ".{ .policy = .{ \"x\" } }",
        ".{ .policy = .{ .{ .tool = \"bash\", .verdict = .allow, .extra = 1 } } }",
        ".{ .policy = .{ .{ .tool = \"bash\", .verdict = .deny, .step = \"nope\" } } }",
        ".{ .policy = .{ .{ .tool = \"read_file\", .verdict = .allow } } }",
        ".{ .policy = .{ .{ .tool = \"bash\"",
        ".{ .policy = 5 }",
    };
    for (texts) |text| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const resolved = try resolve(testing.allocator, arena, text, &default_ids);
        const eff = try effective(arena, resolved, try offeredWith(arena, &mcp_offered));
        switch (eff) {
            .rules, .refused => {},
        }
    }
}
