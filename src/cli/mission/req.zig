//! CLI-side shaping around `zygos::missions::start`: exit codes, paths, and
//! the brief objective. The start body itself is `zygos.mission.start`, so
//! the CLI and the orchestrator share one description. No sockets.

const std = @import("std");
const json = std.json;
const zygos = @import("zygos");

pub const StartParams = zygos.mission.start.StartParams;
pub const buildStartRequest = zygos.mission.start.build;
pub const extractObjective = zygos.mission.start.extractObjective;

pub fn bashDesc(gpa: std.mem.Allocator, workspace: []const u8) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "Run a shell command and get its output. The shell runs in the mission workspace: {s}. " ++
            "Do all work inside this directory (relative paths work); never write to $HOME or system paths.",
        .{workspace},
    );
}

/// Filename stem: basename minus the last extension.
pub fn stem(path: []const u8) []const u8 {
    const base = if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[i + 1 ..] else path;
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return base;
    return if (dot == 0) base else base[0..dot];
}

/// 0 only for state:"done"; a W1 server-side refusal is config-shaped (2).
pub fn terminalExitCode(gpa: std.mem.Allocator, payload: []const u8) u8 {
    var p = json.parseFromSlice(json.Value, gpa, payload, .{}) catch return 1;
    defer p.deinit();
    if (p.value != .object) return 1;
    if (p.value.object.get("refused") != null) return 2;
    const state = p.value.object.get("state") orelse return 1;
    if (state == .string and std.mem.eql(u8, state.string, "done")) return 0;
    return 1;
}

pub fn absPath(gpa: std.mem.Allocator, cwd: []const u8, path: []const u8) error{OutOfMemory}![]u8 {
    if (path.len > 0 and path[0] == '/') return gpa.dupe(u8, path);
    const rel = if (std.mem.startsWith(u8, path, "./")) path[2..] else path;
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ cwd, rel });
}

const testing = std.testing;

test "buildStartRequest: valid JSON carrying id, objective, tools and flags" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = try buildStartRequest(arena, .{
        .mission_id = "m-1",
        .planning = "/tmp/p",
        .brief_text = "# Brief\n## Objective\nShip it\n## Notes\nx",
        .trace_path = "/tmp/p/events.jsonl",
        .resume_flag = false,
        .bash_desc = "run bash",
        .mcp_entries = "",
        .ctx_kind = .thread,
        .ctx_max_tokens = 1000,
        .role_max_steps = 24,
        .max_role_turns = 64,
    });
    const v = try json.parseFromSliceLeaky(json.Value, arena, body, .{});
    try testing.expectEqualStrings("m-1", v.object.get("mission_id").?.string);
    try testing.expectEqualStrings("Ship it", v.object.get("objective").?.string);
    try testing.expectEqual(@as(usize, 3), v.object.get("tools").?.array.items.len);
    try testing.expect(v.object.get("resume") == null);
    try testing.expectEqual(@as(i64, 24), v.object.get("role_max_steps").?.integer);
}

test "buildStartRequest: resume flag rides the body" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = try buildStartRequest(arena, .{
        .mission_id = "m-2",
        .planning = "/tmp/p",
        .brief_text = "objective only",
        .trace_path = "",
        .resume_flag = true,
        .bash_desc = "",
        .mcp_entries = "",
        .ctx_kind = .thread,
        .ctx_max_tokens = 1,
        .role_max_steps = 1,
        .max_role_turns = 1,
    });
    const v = try json.parseFromSliceLeaky(json.Value, arena, body, .{});
    try testing.expect(v.object.get("resume").?.bool);
    // No `## Objective` heading: the whole brief is the objective.
    try testing.expectEqualStrings("objective only", v.object.get("objective").?.string);
}

test "extractObjective: heading body, trailing section, absent heading" {
    try testing.expectEqualStrings("Ship it", extractObjective("## Objective\nShip it\n## Next\nx"));
    try testing.expectEqualStrings("Ship it", extractObjective("intro\n## Objective\n Ship it \n"));
    try testing.expectEqualStrings("whole text", extractObjective("whole text"));
}

test "stem: basename minus last extension; dotfiles keep their name" {
    try testing.expectEqualStrings("brief", stem("/a/b/brief.md"));
    try testing.expectEqualStrings("archive.tar", stem("archive.tar.gz"));
    try testing.expectEqualStrings("noext", stem("dir/noext"));
    try testing.expectEqualStrings(".hidden", stem("/x/.hidden"));
}

test "terminalExitCode: done=0, refused=2, anything else=1" {
    try testing.expectEqual(@as(u8, 0), terminalExitCode(testing.allocator, "{\"state\":\"done\"}"));
    try testing.expectEqual(@as(u8, 2), terminalExitCode(testing.allocator, "{\"refused\":true}"));
    try testing.expectEqual(@as(u8, 1), terminalExitCode(testing.allocator, "{\"state\":\"failed\"}"));
    try testing.expectEqual(@as(u8, 1), terminalExitCode(testing.allocator, "not json"));
}

test "absPath: absolute passes, relative joins, ./ strips" {
    const a = try absPath(testing.allocator, "/cwd", "/abs/x");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("/abs/x", a);
    const b = try absPath(testing.allocator, "/cwd", "./rel/x");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("/cwd/rel/x", b);
}
