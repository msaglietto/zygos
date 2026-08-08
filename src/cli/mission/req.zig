//! Pure request/reply shaping for the mission CLI: the missions::start body,
//! brief parsing, and exit-code mapping. No sockets, no libc, no stderr —
//! cli/mission.zig owns the wiring.

const std = @import("std");
const json = std.json;
const zygos = @import("zygos");

pub const StartParams = struct {
    mission_id: []const u8,
    planning: []const u8,
    brief_text: []const u8,
    trace_path: []const u8,
    resume_flag: bool,
    bash_desc: []const u8,
    mcp_entries: []const u8,
    ctx_kind: zygos.context.Kind,
    ctx_max_tokens: usize,
    role_max_steps: i64,
    max_role_turns: i64,
};

/// The missions::start request body — shared by the single-mission path and
/// the queue loop so the wire shape can never drift between them.
pub fn buildStartRequest(gpa: std.mem.Allocator, p: StartParams) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(gpa,
        \\{{"mission_id":{f},"planning_root":{f},"objective":{f},"brief":{f},
        \\ "router_function":"zygos::models::resolve",
        \\ "gate_function":"zygos::approvals::request",
        \\ "policy_function":"zygos::policy::check",
        \\ "approval_function":"zygos::approvals::request",
        \\ "budget_scope":{f},"trace_path":{f},
        \\ "context_strategy":{{"kind":"{t}","max_tokens":{d}}},
        \\ "role_max_steps":{d},"max_role_turns":{d}{s},
        \\ "tools":[
        \\  {{"name":"bash","function_id":"zygos::tools::bash",
        \\   "description":{f},
        \\   "input_schema":{{"type":"object","properties":{{"command":{{"type":"string",
        \\    "description":"the shell command to run"}}}},"required":["command"]}}}},
        \\  {{"name":"web_search","function_id":"zygos::tools::web_search",
        \\   "description":"Search the web; returns a list of {{title,url,snippet}} results.",
        \\   "input_schema":{{"type":"object","properties":{{"query":{{"type":"string",
        \\    "description":"the search query"}}}},"required":["query"]}}}},
        \\  {{"name":"web_fetch","function_id":"zygos::tools::web_fetch",
        \\   "description":"Fetch a URL and return its readable text content.",
        \\   "input_schema":{{"type":"object","properties":{{"url":{{"type":"string",
        \\    "description":"the absolute http(s) URL to fetch"}}}},"required":["url"]}}}}{s}]}}
    , .{
        json.fmt(p.mission_id, .{}),                   json.fmt(p.planning, .{}),
        json.fmt(extractObjective(p.brief_text), .{}), json.fmt(p.brief_text, .{}),
        json.fmt(p.mission_id, .{}),                   json.fmt(p.trace_path, .{}),
        p.ctx_kind,                                    p.ctx_max_tokens,
        p.role_max_steps,                              p.max_role_turns,
        if (p.resume_flag) ",\"resume\":true" else "", json.fmt(p.bash_desc, .{}),
        p.mcp_entries,
    });
}

pub fn bashDesc(gpa: std.mem.Allocator, workspace: []const u8) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "Run a shell command and get its output. The shell runs in the mission workspace: {s}. " ++
            "Do all work inside this directory (relative paths work); never write to $HOME or system paths.",
        .{workspace},
    );
}

/// The brief's `## Objective` section body when present, else the whole text.
pub fn extractObjective(text: []const u8) []const u8 {
    const heading = "## Objective";
    const start = std.mem.indexOf(u8, text, heading) orelse return text;
    const body_start = start + heading.len;
    const rel_end = std.mem.indexOf(u8, text[body_start..], "\n## ") orelse
        return std.mem.trim(u8, text[body_start..], " \t\r\n");
    return std.mem.trim(u8, text[body_start .. body_start + rel_end], " \t\r\n");
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
