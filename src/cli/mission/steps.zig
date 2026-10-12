//! Loads the pipeline a `zygos.zon` `.steps` list names (docs/specs/mission.md
//! "Boot refusals" and "Definitions"). Pure rules live in
//! worker/mission/pipeline.zig; this file adds the file checks: each
//! `.definition` resolves against the zon's directory, is read ONCE, and its
//! raw bytes and sha256 are pinned into the step that rides the start request.
//! The worker never reads definition files.

const std = @import("std");
const zygos = @import("zygos");
const pipeline = zygos.mission.pipeline;

extern "c" fn realpath(path: [*:0]const u8, resolved: [*]u8) ?[*:0]u8;

/// A definition larger than this is refused, not truncated.
pub const max_definition_bytes: usize = 64 * 1024;

pub const Resolved = union(enum) {
    /// No `.steps` in the file: the default pipeline (the start request omits `steps`).
    absent,
    /// Validated steps with every `.definition` pinned. Allocated from `arena`.
    ok: []pipeline.Step,
    /// Boot refusal reason, e.g. `steps[1]: definition unreadable`.
    refused: []const u8,
};

/// Parses `.steps` from `zon_text`, validates it, then pins each
/// `.definition` relative to `zon_path`'s directory. Pure refusals come
/// first, so a bad id is reported before any file is touched. `scratch`
/// holds parser temporaries; everything returned lives in `arena`.
pub fn resolve(
    scratch: std.mem.Allocator,
    arena: std.mem.Allocator,
    zon_path: []const u8,
    zon_text: [:0]const u8,
) error{OutOfMemory}!Resolved {
    const parsed = pipeline.parseZon(scratch, arena, zon_text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => return .{ .refused = "steps: malformed" },
    };
    const entries = switch (parsed) {
        .absent => return .absent,
        .refused => |reason| return .{ .refused = reason },
        .entries => |e| e,
    };
    const steps = switch (try pipeline.validate(arena, entries)) {
        .ok => |s| s,
        .refused => |reason| return .{ .refused = reason },
    };

    var dir: ?[]const u8 = null; // realpath of the zon directory, on first use
    for (entries, steps, 0..) |entry, *step, i| {
        const rel = entry.definition_path orelse continue;
        pipeline.checkDefinitionPath(rel) catch return refuseAt(arena, i, "definition path");
        if (dir == null) {
            dir = canonical(arena, zonDir(zon_path)) orelse return refuseAt(arena, i, "definition unreadable");
        }
        const joined = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir.?, rel });
        const real = canonical(arena, joined) orelse return refuseAt(arena, i, "definition unreadable");
        if (!within(dir.?, real)) return refuseAt(arena, i, "definition path");

        const bytes = readCapped(arena, real) orelse return refuseAt(arena, i, "definition unreadable");
        if (bytes.len > max_definition_bytes) return refuseAt(arena, i, "definition unreadable");
        if (std.mem.trim(u8, bytes, &std.ascii.whitespace).len == 0) {
            return refuseAt(arena, i, "definition unreadable");
        }
        step.system = bytes;
        step.definition_sha256 = try arena.dupe(u8, &pipeline.sha256Hex(bytes));
    }
    return .{ .ok = steps };
}

fn refuseAt(arena: std.mem.Allocator, index: usize, what: []const u8) error{OutOfMemory}!Resolved {
    return .{ .refused = try std.fmt.allocPrint(arena, "steps[{d}]: {s}", .{ index, what }) };
}

fn zonDir(zon_path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, zon_path, '/') orelse return ".";
    return if (slash == 0) "/" else zon_path[0..slash];
}

fn canonical(arena: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const z = arena.dupeZ(u8, path) catch return null;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const resolved = realpath(z.ptr, &buf) orelse return null;
    return arena.dupe(u8, std.mem.span(resolved)) catch null;
}

/// Component-wise prefix test: `/a/cfg-evil` is not inside `/a/cfg`.
fn within(dir: []const u8, path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, dir)) return false;
    if (dir.len > 0 and dir[dir.len - 1] == '/') return true;
    return path.len > dir.len and path[dir.len] == '/';
}

/// At most `max_definition_bytes + 1` bytes, so an oversize file is seen as
/// oversize without being read whole. Null when the file cannot be opened
/// or read.
fn readCapped(arena: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const z = arena.dupeZ(u8, path) catch return null;
    const fd = std.c.open(z.ptr, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    var buf: std.ArrayList(u8) = .empty;
    var chunk: [4096]u8 = undefined;
    while (buf.items.len <= max_definition_bytes) {
        const want = @min(chunk.len, max_definition_bytes + 1 - buf.items.len);
        const n = std.c.read(fd, &chunk, want);
        if (n < 0) return null;
        if (n == 0) break;
        buf.appendSlice(arena, chunk[0..@intCast(n)]) catch return null;
    }
    return buf.items;
}

// ===========================================================================
// Tests (real tmp files, offline)
// ===========================================================================

const testing = std.testing;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    root_buf: [std.fs.max_path_bytes]u8 = undefined,
    root_len: usize = 0,

    fn init() !Fixture {
        var f: Fixture = .{ .tmp = std.testing.tmpDir(.{}) };
        var rel_buf: [std.fs.max_path_bytes]u8 = undefined;
        const rel = try std.fmt.bufPrintZ(&rel_buf, ".zig-cache/tmp/{s}", .{f.tmp.sub_path});
        const resolved = realpath(rel, &f.root_buf) orelse return error.RealpathFailed;
        f.root_len = std.mem.span(resolved).len;
        return f;
    }

    fn root(self: *const Fixture) []const u8 {
        return self.root_buf[0..self.root_len];
    }

    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
    }

    fn path(self: *const Fixture, arena: std.mem.Allocator, rel: []const u8) ![]u8 {
        return std.fmt.allocPrint(arena, "{s}/{s}", .{ self.root(), rel });
    }

    fn write(self: *const Fixture, arena: std.mem.Allocator, rel: []const u8, bytes: []const u8) !void {
        try zygos.fsx.writeAtomic(arena, try self.path(arena, rel), bytes);
    }

    fn symlink(self: *const Fixture, arena: std.mem.Allocator, target: []const u8, rel: []const u8) !void {
        const link_z = try arena.dupeZ(u8, try self.path(arena, rel));
        const target_z = try arena.dupeZ(u8, target);
        if (std.c.symlink(target_z, link_z) != 0) return error.SymlinkFailed;
    }
};

fn zonWith(arena: std.mem.Allocator, definition: []const u8) ![:0]const u8 {
    return std.fmt.allocPrintSentinel(arena,
        \\.{{ .steps = .{{
        \\    .{{ .id = "architect", .definition = "{s}" }},
        \\    .{{ .id = "executor" }},
        \\}} }}
    , .{definition}, 0);
}

fn expectRefused(want: []const u8, got: Resolved) !void {
    switch (got) {
        .refused => |reason| try testing.expectEqualStrings(want, reason),
        .absent => return error.TestExpectedRefusal,
        .ok => return error.TestExpectedRefusal,
    }
}

test "a definition is read once and pinned with its raw bytes and sha256" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fx = try Fixture.init();
    defer fx.deinit();

    const raw = "  You are the architect.\n\n";
    try fx.write(arena, "cfg/agents/architect.md", raw);
    const zon_path = try fx.path(arena, "cfg/zygos.zon");

    const got = try resolve(testing.allocator, arena, zon_path, try zonWith(arena, "agents/architect.md"));
    const steps = got.ok;
    try testing.expectEqual(@as(usize, 2), steps.len);
    try testing.expectEqualStrings("architect", steps[0].id);
    try testing.expectEqual(pipeline.Kind.custom, steps[0].kind);
    try testing.expectEqualStrings(raw, steps[0].system.?);
    const want = pipeline.sha256Hex(raw);
    try testing.expectEqualStrings(&want, steps[0].definition_sha256.?);
    try testing.expect(steps[1].system == null);
    try testing.expect(steps[1].definition_sha256 == null);
    try testing.expect(steps[1].tools);
}

test "a definition of exactly 64 KiB is accepted and one byte more is unreadable" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fx = try Fixture.init();
    defer fx.deinit();

    const exact = try arena.alloc(u8, max_definition_bytes);
    @memset(exact, 'a');
    try fx.write(arena, "cfg/exact.md", exact);
    try fx.write(arena, "cfg/over.md", try std.fmt.allocPrint(arena, "{s}a", .{exact}));
    const zon_path = try fx.path(arena, "cfg/zygos.zon");

    const ok = try resolve(testing.allocator, arena, zon_path, try zonWith(arena, "exact.md"));
    try testing.expectEqual(max_definition_bytes, ok.ok[0].system.?.len);
    try expectRefused("steps[0]: definition unreadable", try resolve(testing.allocator, arena, zon_path, try zonWith(arena, "over.md")));
}

test "a missing, empty or whitespace-only definition is unreadable" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fx = try Fixture.init();
    defer fx.deinit();

    try fx.write(arena, "cfg/empty.md", "");
    try fx.write(arena, "cfg/blank.md", " \t\r\n  \n");
    const zon_path = try fx.path(arena, "cfg/zygos.zon");
    for ([_][]const u8{ "missing.md", "empty.md", "blank.md" }) |name| {
        try expectRefused("steps[0]: definition unreadable", try resolve(testing.allocator, arena, zon_path, try zonWith(arena, name)));
    }
}

test "a directory named as a definition is unreadable" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fx = try Fixture.init();
    defer fx.deinit();

    try fx.write(arena, "cfg/agents/x.md", "x");
    const zon_path = try fx.path(arena, "cfg/zygos.zon");
    try expectRefused("steps[0]: definition unreadable", try resolve(testing.allocator, arena, zon_path, try zonWith(arena, "agents")));
}

test "a definition path that is absolute or climbs with .. is refused as a path" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fx = try Fixture.init();
    defer fx.deinit();

    try fx.write(arena, "secret.md", "outside");
    try fx.write(arena, "cfg/zygos.zon", ".{}");
    const zon_path = try fx.path(arena, "cfg/zygos.zon");
    const absolute = try fx.path(arena, "secret.md");
    for ([_][]const u8{ absolute, "../secret.md", "agents/../../secret.md" }) |p| {
        try expectRefused("steps[0]: definition path", try resolve(testing.allocator, arena, zon_path, try zonWith(arena, p)));
    }
}

test "a symlink that escapes the zon directory is refused as a path" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fx = try Fixture.init();
    defer fx.deinit();

    try fx.write(arena, "outside/secret.md", "outside");
    try fx.write(arena, "cfg/inside.md", "inside");
    try fx.symlink(arena, "../outside/secret.md", "cfg/leak.md");
    try fx.symlink(arena, "inside.md", "cfg/alias.md");
    try fx.symlink(arena, "../outside", "cfg/linkdir");
    const zon_path = try fx.path(arena, "cfg/zygos.zon");

    try expectRefused("steps[0]: definition path", try resolve(testing.allocator, arena, zon_path, try zonWith(arena, "leak.md")));
    try expectRefused("steps[0]: definition path", try resolve(testing.allocator, arena, zon_path, try zonWith(arena, "linkdir/secret.md")));
    // A symlink that stays inside the directory is fine.
    const ok = try resolve(testing.allocator, arena, zon_path, try zonWith(arena, "alias.md"));
    try testing.expectEqualStrings("inside", ok.ok[0].system.?);
}

test "a sibling directory sharing the zon directory's name prefix is outside" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fx = try Fixture.init();
    defer fx.deinit();

    try fx.write(arena, "cfg-evil/secret.md", "outside");
    try fx.write(arena, "cfg/zygos.zon", ".{}");
    try fx.symlink(arena, "../cfg-evil/secret.md", "cfg/leak.md");
    const zon_path = try fx.path(arena, "cfg/zygos.zon");
    try expectRefused("steps[0]: definition path", try resolve(testing.allocator, arena, zon_path, try zonWith(arena, "leak.md")));
}

test "no .steps is absent, and the pure refusals come before any file is read" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fx = try Fixture.init();
    defer fx.deinit();
    const zon_path = try fx.path(arena, "cfg/zygos.zon");

    const absent = try resolve(testing.allocator, arena, zon_path, ".{ .default = .{} }");
    try testing.expect(absent == .absent);

    try expectRefused("steps: no executor", try resolve(testing.allocator, arena, zon_path,
        \\.{ .steps = .{ .{ .id = "planner" } } }
    ));
    // Entry 0's unreadable file does not mask entry 1's bad id.
    try expectRefused("steps[1]: bad id", try resolve(testing.allocator, arena, zon_path,
        \\.{ .steps = .{ .{ .id = "executor", .definition = "nope.md" }, .{ .id = "BAD" } } }
    ));
    try expectRefused("steps: malformed", try resolve(testing.allocator, arena, zon_path, ".{ .steps = 3 }"));
    try expectRefused("steps: malformed", try resolve(testing.allocator, arena, zon_path, ".{ .steps = .{ "));
}

test "a zon path without a directory resolves against the current directory" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // build.zig is in the test cwd (the repo root).
    const got = try resolve(testing.allocator, arena, "zygos.zon", try zonWith(arena, "build.zig"));
    try testing.expect(got.ok[0].system.?.len > 0);
}
