//! Pure pipeline rules (docs/specs/mission.md "Pipeline module"): step kinds,
//! the default four, and config validation shared by the CLI (zygos.zon
//! `.steps`) and the worker (the start request's `steps`). std-only, no I/O.
//!
//! Every refusal is a reason string naming the entry (`steps[i]: ...`); an
//! invalid list never degrades to the default pipeline.

const std = @import("std");
const Zoir = std.zig.Zoir;

pub const Kind = enum { product_owner, planner, executor, verifier, custom };

pub fn kindOf(id: []const u8) Kind {
    const known = [_]struct { id: []const u8, kind: Kind }{
        .{ .id = "product-owner", .kind = .product_owner },
        .{ .id = "planner", .kind = .planner },
        .{ .id = "executor", .kind = .executor },
        .{ .id = "verifier", .kind = .verifier },
    };
    for (known) |k| if (std.mem.eql(u8, id, k.id)) return k.kind;
    return .custom;
}

pub const Step = struct {
    id: []const u8,
    kind: Kind,
    /// Pinned definition text; null for a built-in (the driver resolves the
    /// `role-<id>.md` override or the embedded prompt later).
    system: ?[]const u8,
    /// Lowercase hex sha256 of `system`; null for a built-in.
    definition_sha256: ?[]const u8,
    tools: bool,
};

/// One configured entry before validation. The CLI fills `definition_path`
/// (the file is loaded after validation); the worker fills `system` and
/// optionally `definition_sha256` (the CLI-pinned text and its hash).
pub const Entry = struct {
    id: ?[]const u8 = null,
    definition_path: ?[]const u8 = null,
    system: ?[]const u8 = null,
    definition_sha256: ?[]const u8 = null,
    tools: ?bool = null,
    unknown_key: ?[]const u8 = null,
};

pub const Outcome = union(enum) {
    /// Allocated from the caller's arena; `id`/`system` borrow from the entries.
    ok: []Step,
    refused: []const u8,
};

/// Ids the runtime owns: `task` is the headless task step, `tessera-capture`
/// the capture worker's turn id. A pipeline step must not share their routes.
const reserved_ids = [_][]const u8{ "task", "tessera-capture" };

const max_id_len = 32;

fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > max_id_len) return false;
    for (id) |c| {
        if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-')) return false;
    }
    return true;
}

fn refuse(arena: std.mem.Allocator, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!Outcome {
    return .{ .refused = try std.fmt.allocPrint(arena, fmt, args) };
}

/// The boot-refusal table, minus the file checks (the CLI loads definitions
/// after this). A step's `system` is set only when the entry carries one;
/// `definition_path` entries stay unpinned until the loader fills them.
pub fn validate(arena: std.mem.Allocator, entries: []const Entry) error{OutOfMemory}!Outcome {
    if (entries.len == 0) return refuse(arena, "steps: empty", .{});
    const steps = try arena.alloc(Step, entries.len);
    var has_executor = false;
    for (entries, steps, 0..) |e, *out, i| {
        if (e.unknown_key) |k| return refuse(arena, "steps[{d}]: unknown key \"{s}\"", .{ i, k });
        const id = e.id orelse return refuse(arena, "steps[{d}]: missing id", .{i});
        if (!validId(id)) return refuse(arena, "steps[{d}]: bad id", .{i});
        for (reserved_ids) |r| {
            if (std.mem.eql(u8, id, r)) return refuse(arena, "steps[{d}]: reserved id", .{i});
        }
        const kind = kindOf(id);
        const tools = e.tools orelse (kind == .executor);
        if (kind == .verifier and tools) {
            return refuse(arena, "steps[{d}]: verifier cannot have tools", .{i});
        }
        const pinned_blank = if (e.system) |t| std.mem.trim(u8, t, &std.ascii.whitespace).len == 0 else false;
        const defined = (e.definition_path != null or e.system != null) and !pinned_blank;
        // A blank pinned text would silence the step's prompt, built-in or not.
        if (pinned_blank or (kind == .custom and !defined)) {
            return refuse(arena, "steps[{d}]: no definition", .{i});
        }

        var sha: ?[]const u8 = null;
        if (e.system) |text| {
            const computed = sha256Hex(text);
            if (e.definition_sha256) |declared| {
                if (!std.mem.eql(u8, declared, &computed)) {
                    return refuse(arena, "steps[{d}]: definition hash mismatch", .{i});
                }
            }
            sha = try arena.dupe(u8, &computed);
        } else if (e.definition_sha256 != null) {
            return refuse(arena, "steps[{d}]: definition hash mismatch", .{i});
        }

        if (kind == .executor) has_executor = true;
        out.* = .{ .id = id, .kind = kind, .system = e.system, .definition_sha256 = sha, .tools = tools };
    }
    if (!has_executor) return refuse(arena, "steps: no executor", .{});
    return .{ .ok = steps };
}

pub const default_pipeline = [_]Step{
    .{ .id = "product-owner", .kind = .product_owner, .system = null, .definition_sha256 = null, .tools = false },
    .{ .id = "planner", .kind = .planner, .system = null, .definition_sha256 = null, .tools = false },
    .{ .id = "executor", .kind = .executor, .system = null, .definition_sha256 = null, .tools = true },
    .{ .id = "verifier", .kind = .verifier, .system = null, .definition_sha256 = null, .tools = false },
};

pub fn defaultSteps(arena: std.mem.Allocator) error{OutOfMemory}![]Step {
    return arena.dupe(Step, &default_pipeline);
}

pub const DefinitionPathError = error{DefinitionPath};

/// Shape check only: no absolute path, no `..` component. The CLI adds the
/// realpath containment check.
pub fn checkDefinitionPath(path: []const u8) DefinitionPathError!void {
    if (path.len == 0 or path[0] == '/') return error.DefinitionPath;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return error.DefinitionPath;
    }
}

pub fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

pub const ZonSteps = union(enum) {
    /// No `.steps` key: the default pipeline.
    absent,
    entries: []Entry,
    refused: []const u8,
};

/// Strict extraction of `.steps` from the full zygos.zon text. Other
/// top-level keys are ignored. `scratch` holds the AST and is released
/// before returning; entries and their strings live in `arena`.
pub fn parseZon(scratch: std.mem.Allocator, arena: std.mem.Allocator, text: [:0]const u8) error{ OutOfMemory, ParseZon }!ZonSteps {
    var ast = try std.zig.Ast.parse(scratch, text, .zon);
    defer ast.deinit(scratch);
    const zoir = try std.zig.ZonGen.generate(scratch, ast, .{});
    defer zoir.deinit(scratch);
    if (ast.errors.len > 0 or zoir.hasCompileErrors()) return error.ParseZon;

    const root = Zoir.Node.Index.root.get(zoir);
    const fields = switch (root) {
        .struct_literal => |s| s,
        else => return .absent,
    };
    const steps_node = for (fields.names, 0..) |name, k| {
        if (std.mem.eql(u8, name.get(zoir), "steps")) break fields.vals.at(@intCast(k));
    } else return .absent;

    const items: ?Zoir.Node.Index.Range = switch (steps_node.get(zoir)) {
        .empty_literal => null,
        .array_literal => |r| r,
        else => return .{ .refused = "steps: malformed" },
    };
    const count: usize = if (items) |r| r.len else 0;
    const entries = try arena.alloc(Entry, count);
    for (entries, 0..) |*entry, i| {
        entry.* = .{};
        const node = items.?.at(@intCast(i)).get(zoir);
        const names, const vals = switch (node) {
            .empty_literal => continue,
            .struct_literal => |s| .{ s.names, s.vals },
            else => return .{ .refused = try std.fmt.allocPrint(arena, "steps[{d}]: malformed", .{i}) },
        };
        for (names, 0..) |name_nts, k| {
            const name = name_nts.get(zoir);
            const val = vals.at(@intCast(k)).get(zoir);
            if (std.mem.eql(u8, name, "id")) {
                entry.id = switch (val) {
                    .string_literal => |str| try arena.dupe(u8, str),
                    else => return .{ .refused = try std.fmt.allocPrint(arena, "steps[{d}]: bad id", .{i}) },
                };
            } else if (std.mem.eql(u8, name, "definition")) {
                entry.definition_path = switch (val) {
                    .string_literal => |str| try arena.dupe(u8, str),
                    else => return .{ .refused = try std.fmt.allocPrint(arena, "steps[{d}]: definition path", .{i}) },
                };
            } else if (std.mem.eql(u8, name, "tools")) {
                entry.tools = switch (val) {
                    .true => true,
                    .false => false,
                    else => return .{ .refused = try std.fmt.allocPrint(arena, "steps[{d}]: bad tools", .{i}) },
                };
            } else if (entry.unknown_key == null) {
                entry.unknown_key = try arena.dupe(u8, name);
            }
        }
    }
    return .{ .entries = entries };
}

// ===========================================================================
// Tests (docs/specs/mission.md test contract 4-6, RED first)
// ===========================================================================

const testing = std.testing;

fn expectRefusal(entries: []const Entry, want: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    switch (try validate(arena_state.allocator(), entries)) {
        .ok => return error.TestExpectedRefusal,
        .refused => |reason| try testing.expectEqualStrings(want, reason),
    }
}

fn expectOk(arena: std.mem.Allocator, entries: []const Entry) ![]Step {
    switch (try validate(arena, entries)) {
        .ok => |steps| return steps,
        .refused => |reason| {
            std.debug.print("unexpected refusal: {s}\n", .{reason});
            return error.TestUnexpectedRefusal;
        },
    }
}

test "kindOf: the four known ids, everything else custom" {
    try testing.expectEqual(Kind.product_owner, kindOf("product-owner"));
    try testing.expectEqual(Kind.planner, kindOf("planner"));
    try testing.expectEqual(Kind.executor, kindOf("executor"));
    try testing.expectEqual(Kind.verifier, kindOf("verifier"));
    try testing.expectEqual(Kind.custom, kindOf("architect"));
    try testing.expectEqual(Kind.custom, kindOf("Executor"));
    try testing.expectEqual(Kind.custom, kindOf(""));
}

test "absent steps is the default four with executor-only tools" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try parseZon(testing.allocator, arena,
        \\.{ .default = .{}, .routes = .{}, .context_strategy = .{ .kind = "recall" } }
    );
    try testing.expect(parsed == .absent);

    const steps = try defaultSteps(arena);
    const want_ids = [_][]const u8{ "product-owner", "planner", "executor", "verifier" };
    const want_kinds = [_]Kind{ .product_owner, .planner, .executor, .verifier };
    const want_tools = [_]bool{ false, false, true, false };
    try testing.expectEqual(@as(usize, 4), steps.len);
    for (steps, 0..) |s, i| {
        try testing.expectEqualStrings(want_ids[i], s.id);
        try testing.expectEqual(want_kinds[i], s.kind);
        try testing.expectEqual(want_tools[i], s.tools);
        try testing.expect(s.system == null);
        try testing.expect(s.definition_sha256 == null);
    }
}

test "the default four validates as an explicit list" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const steps = try expectOk(arena, &.{
        .{ .id = "product-owner" }, .{ .id = "planner" }, .{ .id = "executor" }, .{ .id = "verifier" },
    });
    for (steps, &default_pipeline) |got, want| {
        try testing.expectEqualStrings(want.id, got.id);
        try testing.expectEqual(want.kind, got.kind);
        try testing.expectEqual(want.tools, got.tools);
    }
}

test "boot refusal: empty list" {
    try expectRefusal(&.{}, "steps: empty");
}

test "boot refusal: unknown key" {
    try expectRefusal(&.{
        .{ .id = "executor" },
        .{ .id = "verifier", .unknown_key = "model" },
    }, "steps[1]: unknown key \"model\"");
}

test "boot refusal: missing id" {
    try expectRefusal(&.{ .{ .id = "executor" }, .{} }, "steps[1]: missing id");
}

test "boot refusal: bad id" {
    const bad = [_][]const u8{
        "",        "Executor", "my_step", "has space", "dot.id",
        "ünï",
        "a" ** 33,
    };
    for (bad) |id| {
        try expectRefusal(&.{ .{ .id = "executor" }, .{ .id = id } }, "steps[1]: bad id");
    }
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    _ = try expectOk(arena_state.allocator(), &.{
        .{ .id = "executor" },
        .{ .id = "a", .system = "x" },
        .{ .id = "a-1-" ++ "z" ** 28, .system = "x" },
    });
}

test "boot refusal: reserved id" {
    try expectRefusal(&.{ .{ .id = "executor" }, .{ .id = "task", .system = "x" } }, "steps[1]: reserved id");
    try expectRefusal(&.{ .{ .id = "tessera-capture", .system = "x" }, .{ .id = "executor" } }, "steps[0]: reserved id");
}

test "boot refusal: no executor" {
    try expectRefusal(&.{ .{ .id = "planner" }, .{ .id = "verifier" } }, "steps: no executor");
}

test "boot refusal: verifier with tools" {
    try expectRefusal(&.{
        .{ .id = "executor" },
        .{ .id = "verifier", .tools = true },
    }, "steps[1]: verifier cannot have tools");
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const steps = try expectOk(arena_state.allocator(), &.{
        .{ .id = "executor" },
        .{ .id = "verifier", .tools = false },
    });
    try testing.expect(!steps[1].tools);
}

test "boot refusal: custom without definition" {
    try expectRefusal(&.{ .{ .id = "architect" }, .{ .id = "executor" } }, "steps[0]: no definition");
    // A whitespace-only pinned text is no definition either.
    try expectRefusal(&.{ .{ .id = "architect", .system = " \n\t" }, .{ .id = "executor" } }, "steps[0]: no definition");
    try expectRefusal(&.{.{ .id = "executor", .system = "" }}, "steps[0]: no definition");
}

test "boot refusal: definition path absolute" {
    try testing.expectError(error.DefinitionPath, checkDefinitionPath("/etc/passwd"));
    try testing.expectError(error.DefinitionPath, checkDefinitionPath("/"));
    try checkDefinitionPath("agents/architect.md");
    try checkDefinitionPath("architect.md");
}

test "boot refusal: definition path with .." {
    try testing.expectError(error.DefinitionPath, checkDefinitionPath(".."));
    try testing.expectError(error.DefinitionPath, checkDefinitionPath("../a.md"));
    try testing.expectError(error.DefinitionPath, checkDefinitionPath("a/../b.md"));
    try testing.expectError(error.DefinitionPath, checkDefinitionPath("a/.."));
    try testing.expectError(error.DefinitionPath, checkDefinitionPath(""));
    // `..` inside a component name is not a parent reference.
    try checkDefinitionPath("a..b/c..md");
    try checkDefinitionPath("..hidden.md");
}

test "tools=true is allowed on product-owner, planner and custom steps" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const steps = try expectOk(arena_state.allocator(), &.{
        .{ .id = "product-owner", .tools = true },
        .{ .id = "planner", .tools = true },
        .{ .id = "architect", .system = "design it", .tools = true },
        .{ .id = "executor", .tools = false },
    });
    try testing.expect(steps[0].tools);
    try testing.expect(steps[1].tools);
    try testing.expect(steps[2].tools);
    try testing.expect(!steps[3].tools);
    try testing.expectEqual(Kind.custom, steps[2].kind);
}

test "duplicate ids are accepted and each occurrence keeps its own definition and tools" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const steps = try expectOk(arena_state.allocator(), &.{
        .{ .id = "executor", .system = "first", .tools = true },
        .{ .id = "reviewer", .system = "review" },
        .{ .id = "executor", .system = "second", .tools = false },
        .{ .id = "verifier" },
    });
    try testing.expectEqual(@as(usize, 4), steps.len);
    try testing.expectEqualStrings("first", steps[0].system.?);
    try testing.expect(steps[0].tools);
    try testing.expectEqualStrings("second", steps[2].system.?);
    try testing.expect(!steps[2].tools);
    try testing.expect(!std.mem.eql(u8, steps[0].definition_sha256.?, steps[2].definition_sha256.?));
}

test "a pinned definition without a hash gets one; a matching hash passes; a wrong or orphan hash refuses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const want = sha256Hex("design it");

    const computed = try expectOk(arena, &.{
        .{ .id = "architect", .system = "design it" },
        .{ .id = "executor" },
    });
    try testing.expectEqualStrings(&want, computed[0].definition_sha256.?);
    try testing.expect(computed[1].definition_sha256 == null);

    const declared = try expectOk(arena, &.{
        .{ .id = "architect", .system = "design it", .definition_sha256 = &want },
        .{ .id = "executor" },
    });
    try testing.expectEqualStrings(&want, declared[0].definition_sha256.?);

    try expectRefusal(&.{
        .{ .id = "architect", .system = "design it changed", .definition_sha256 = &want },
        .{ .id = "executor" },
    }, "steps[0]: definition hash mismatch");
    try expectRefusal(&.{
        .{ .id = "executor", .definition_sha256 = &want },
    }, "steps[0]: definition hash mismatch");
}

test "a definition path counts as a definition before the file is loaded" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const steps = try expectOk(arena_state.allocator(), &.{
        .{ .id = "architect", .definition_path = "agents/architect.md" },
        .{ .id = "executor" },
    });
    try testing.expect(steps[0].system == null);
}

test "refusals report the first offending entry in list order" {
    try expectRefusal(&.{
        .{ .id = "architect", .system = "x" },
        .{ .id = "BAD" },
        .{ .unknown_key = "k" },
    }, "steps[1]: bad id");
}

// -- .steps zon parser --------------------------------------------------------

test "zon steps: entries carry id, definition and tools; other top-level keys are ignored" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const out = try parseZon(testing.allocator, arena,
        \\.{
        \\    .default = .{ .{ .provider_function = "zygos::providers::x", .model = "m" } },
        \\    .routes = .{},
        \\    .mcp_servers = .{},
        \\    .steps = .{
        \\        .{ .id = "architect", .definition = "agents/architect.md", .tools = true },
        \\        .{ .id = "executor" },
        \\        .{ .id = "verifier", .tools = false },
        \\    },
        \\}
    );
    const entries = out.entries;
    try testing.expectEqual(@as(usize, 3), entries.len);
    try testing.expectEqualStrings("architect", entries[0].id.?);
    try testing.expectEqualStrings("agents/architect.md", entries[0].definition_path.?);
    try testing.expectEqual(@as(?bool, true), entries[0].tools);
    try testing.expectEqualStrings("executor", entries[1].id.?);
    try testing.expect(entries[1].definition_path == null);
    try testing.expect(entries[1].tools == null);
    try testing.expectEqual(@as(?bool, false), entries[2].tools);
    for (entries) |e| try testing.expect(e.unknown_key == null);
}

test "zon steps: a single-entry list and escaped strings parse" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const out = try parseZon(testing.allocator, arena_state.allocator(),
        \\.{ .steps = .{ .{ .id = "executor", .definition = "a\\b.md" } } }
    );
    try testing.expectEqual(@as(usize, 1), out.entries.len);
    try testing.expectEqualStrings("a\\b.md", out.entries[0].definition_path.?);
}

test "zon steps: an empty list parses and then refuses as empty" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const out = try parseZon(testing.allocator, arena, ".{ .steps = .{} }");
    try testing.expectEqual(@as(usize, 0), out.entries.len);
    switch (try validate(arena, out.entries)) {
        .ok => return error.TestExpectedRefusal,
        .refused => |r| try testing.expectEqualStrings("steps: empty", r),
    }
}

test "zon steps: an unknown entry key and a missing id surface through validate" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const unknown = try parseZon(testing.allocator, arena,
        \\.{ .steps = .{ .{ .id = "executor" }, .{ .id = "verifier", .model = "x" } } }
    );
    switch (try validate(arena, unknown.entries)) {
        .ok => return error.TestExpectedRefusal,
        .refused => |r| try testing.expectEqualStrings("steps[1]: unknown key \"model\"", r),
    }

    const no_id = try parseZon(testing.allocator, arena, ".{ .steps = .{ .{ .id = \"executor\" }, .{} } }");
    switch (try validate(arena, no_id.entries)) {
        .ok => return error.TestExpectedRefusal,
        .refused => |r| try testing.expectEqualStrings("steps[1]: missing id", r),
    }
}

test "zon steps: wrongly typed values refuse with a reason naming the entry" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_]struct { zon: [:0]const u8, want: []const u8 }{
        .{ .zon = ".{ .steps = 5 }", .want = "steps: malformed" },
        .{ .zon = ".{ .steps = .{ .id = \"executor\" } }", .want = "steps: malformed" },
        .{ .zon = ".{ .steps = null }", .want = "steps: malformed" },
        .{ .zon = ".{ .steps = .{ \"executor\" } }", .want = "steps[0]: malformed" },
        .{ .zon = ".{ .steps = .{ .{ .id = 5 } } }", .want = "steps[0]: bad id" },
        .{ .zon = ".{ .steps = .{ .{ .id = \"executor\" }, .{ .id = \"x\", .tools = \"yes\" } } }", .want = "steps[1]: bad tools" },
        .{ .zon = ".{ .steps = .{ .{ .id = \"x\", .definition = 7 } } }", .want = "steps[0]: definition path" },
    };
    for (cases) |c| {
        const out = try parseZon(testing.allocator, arena, c.zon);
        try testing.expectEqualStrings(c.want, out.refused);
    }
}

test "zon steps: syntactically broken zon is a ParseZon error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(error.ParseZon, parseZon(testing.allocator, arena_state.allocator(), ".{ .steps = .{ "));
}

test "zon steps: the parser releases its scratch allocations" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    _ = try parseZon(testing.allocator, arena_state.allocator(), ".{ .steps = .{ .{ .id = \"executor\" } } }");
    _ = try parseZon(testing.allocator, arena_state.allocator(), ".{ .steps = 5 }");
    try testing.expectError(error.ParseZon, parseZon(testing.allocator, arena_state.allocator(), ".{ .steps = "));
}
