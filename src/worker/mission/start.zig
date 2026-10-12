//! The `zygos::missions::start` body. One description: the CLI builds it and
//! the orchestrator parses it, so a field name cannot drift between them.
//! The bytes on the bus stay JSON — any process that speaks the wire can
//! still send this body.

const std = @import("std");
const json = std.json;
const jsonx = @import("../jsonx.zig");
const context = @import("../context.zig");
const pipeline = @import("pipeline.zig");

const strField = jsonx.strField;
const uintFieldOr = jsonx.uintFieldOr;
const rawJson = jsonx.rawJson;

pub const ParseError = error{ OutOfMemory, MalformedRequest };

pub const mission_id_key = "mission_id";
pub const planning_root_key = "planning_root";
pub const objective_key = "objective";
pub const brief_key = "brief";
pub const resume_key = "resume";
pub const provider_function_key = "provider_function";
pub const router_function_key = "router_function";
pub const gate_function_key = "gate_function";
pub const policy_function_key = "policy_function";
pub const approval_function_key = "approval_function";
pub const budget_scope_key = "budget_scope";
pub const trace_path_key = "trace_path";
pub const continuity_function_key = "continuity_function";
pub const continuity_project_key = "continuity_project";
pub const context_strategy_key = "context_strategy";
pub const kind_key = "kind";
pub const max_tokens_key = "max_tokens";
pub const role_max_steps_key = "role_max_steps";
pub const max_role_turns_key = "max_role_turns";
pub const fail_threshold_key = "fail_threshold";
pub const gate_threshold_key = "gate_threshold";
pub const tools_key = "tools";
pub const steps_key = "steps";
pub const step_id_key = "id";
pub const step_system_key = "system";
pub const step_sha256_key = "definition_sha256";
pub const step_tools_key = "tools";

pub const StartParams = struct {
    mission_id: []const u8,
    planning: []const u8,
    brief_text: []const u8,
    trace_path: []const u8,
    resume_flag: bool,
    bash_desc: []const u8,
    mcp_entries: []const u8,
    ctx_kind: context.Kind,
    ctx_max_tokens: usize,
    role_max_steps: i64,
    max_role_turns: i64,
    /// The CLI-pinned pipeline. Null (no `.steps` in zygos.zon) omits the
    /// field, which the worker reads as the default pipeline.
    steps: ?[]const pipeline.Step = null,
};

pub const Parsed = struct {
    mission_id: []const u8,
    planning_root: []const u8,
    resume_flag: bool,
    objective: ?[]const u8,
    brief: ?[]const u8,
    context: context.Config,
    provider_function: ?[]const u8,
    router_function: ?[]const u8,
    gate_function: ?[]const u8,
    policy_function: ?[]const u8,
    approval_function: ?[]const u8,
    budget_scope: ?[]const u8,
    continuity_function: ?[]const u8,
    continuity_project: ?[]const u8,
    tools_json: ?[]const u8,
    max_role_turns: usize,
    fail_threshold: usize,
    gate_threshold: usize,
    role_max_steps: usize,
    trace_path: ?[]const u8,
    /// Validated pipeline; the default four when the request carries none.
    /// Meaningless when `steps_refusal` is set.
    steps: []const pipeline.Step,
    /// `pipeline.validate` reason; the orchestrator refuses the start.
    steps_refusal: ?[]const u8,
};

/// The brief's `## Objective` section body when present, else the whole text.
pub fn extractObjective(text: []const u8) []const u8 {
    const heading = "## Objective";
    const start = std.mem.indexOf(u8, text, heading) orelse return text;
    const body_start = start + heading.len;
    const rel_end = std.mem.indexOf(u8, text[body_start..], "\n## ") orelse
        return std.mem.trim(u8, text[body_start..], " \t\r\n");
    return std.mem.trim(u8, text[body_start .. body_start + rel_end], " \t\r\n");
}

/// `,"steps":[...]` for a configured list, "" when none. Every step pins its
/// effective `tools`; `system` and `definition_sha256` ride only for a
/// pinned definition.
fn stepsFragment(gpa: std.mem.Allocator, steps: ?[]const pipeline.Step) error{OutOfMemory}![]u8 {
    const list = steps orelse return gpa.dupe(u8, "");
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    w.print(",\"{s}\":[", .{steps_key}) catch return error.OutOfMemory;
    for (list, 0..) |step, i| {
        if (i > 0) w.writeByte(',') catch return error.OutOfMemory;
        w.print("{{\"{s}\":{f}", .{ step_id_key, json.fmt(step.id, .{}) }) catch return error.OutOfMemory;
        if (step.system) |text| {
            w.print(",\"{s}\":{f}", .{ step_system_key, json.fmt(text, .{}) }) catch return error.OutOfMemory;
        }
        if (step.definition_sha256) |sha| {
            w.print(",\"{s}\":{f}", .{ step_sha256_key, json.fmt(sha, .{}) }) catch return error.OutOfMemory;
        }
        w.print(",\"{s}\":{}}}", .{ step_tools_key, step.tools }) catch return error.OutOfMemory;
    }
    w.writeByte(']') catch return error.OutOfMemory;
    return out.toOwnedSlice() catch error.OutOfMemory;
}

pub fn build(gpa: std.mem.Allocator, p: StartParams) error{OutOfMemory}![]u8 {
    const steps_json = try stepsFragment(gpa, p.steps);
    defer gpa.free(steps_json);
    const resume_json: []const u8 = if (p.resume_flag)
        ",\"" ++ resume_key ++ "\":true"
    else
        "";

    return std.fmt.allocPrint(gpa,
        \\{{"{s}":{f},"{s}":{f},"{s}":{f},"{s}":{f},
        \\ "{s}":"zygos::models::resolve",
        \\ "{s}":"zygos::approvals::request",
        \\ "{s}":"zygos::policy::check",
        \\ "{s}":"zygos::approvals::request",
        \\ "{s}":{f},"{s}":{f},
        \\ "{s}":{{"{s}":"{t}","{s}":{d}}},
        \\ "{s}":{d},"{s}":{d}{s}{s},
        \\ "{s}":[
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
        mission_id_key,             json.fmt(p.mission_id, .{}),
        planning_root_key,          json.fmt(p.planning, .{}),
        objective_key,              json.fmt(extractObjective(p.brief_text), .{}),
        brief_key,                  json.fmt(p.brief_text, .{}),
        router_function_key,        gate_function_key,
        policy_function_key,        approval_function_key,
        budget_scope_key,           json.fmt(p.mission_id, .{}),
        trace_path_key,             json.fmt(p.trace_path, .{}),
        context_strategy_key,       kind_key,
        p.ctx_kind,                 max_tokens_key,
        p.ctx_max_tokens,           role_max_steps_key,
        p.role_max_steps,           max_role_turns_key,
        p.max_role_turns,           resume_json,
        steps_json,                 tools_key,
        json.fmt(p.bash_desc, .{}), p.mcp_entries,
    });
}

const StepsResult = union(enum) {
    steps: []const pipeline.Step,
    refused: []const u8,
};

fn refusedAt(arena: std.mem.Allocator, index: usize, what: []const u8) error{OutOfMemory}!StepsResult {
    return .{ .refused = try std.fmt.allocPrint(arena, "steps[{d}]: {s}", .{ index, what }) };
}

/// Absent `steps` is the default pipeline; a present one is held to the same
/// rules the CLI applied, so a hand-built request cannot smuggle in a list
/// the boot refusals would have stopped.
fn parseSteps(arena: std.mem.Allocator, obj: json.ObjectMap) error{OutOfMemory}!StepsResult {
    const v = obj.get(steps_key) orelse return .{ .steps = try pipeline.defaultSteps(arena) };
    if (v != .array) return .{ .refused = "steps: malformed" };
    const entries = try arena.alloc(pipeline.Entry, v.array.items.len);
    for (entries, v.array.items, 0..) |*entry, item, i| {
        entry.* = .{};
        if (item != .object) return refusedAt(arena, i, "malformed");
        var it = item.object.iterator();
        while (it.next()) |kv| {
            const key = kv.key_ptr.*;
            const val = kv.value_ptr.*;
            if (std.mem.eql(u8, key, step_id_key)) {
                if (val != .string) return refusedAt(arena, i, "bad id");
                entry.id = val.string;
            } else if (std.mem.eql(u8, key, step_system_key)) {
                if (val != .string) return refusedAt(arena, i, "no definition");
                entry.system = val.string;
            } else if (std.mem.eql(u8, key, step_sha256_key)) {
                if (val != .string) return refusedAt(arena, i, "definition hash mismatch");
                entry.definition_sha256 = val.string;
            } else if (std.mem.eql(u8, key, step_tools_key)) {
                if (val != .bool) return refusedAt(arena, i, "bad tools");
                entry.tools = val.bool;
            } else if (entry.unknown_key == null) {
                entry.unknown_key = key;
            }
        }
    }
    return switch (try pipeline.validate(arena, entries)) {
        .ok => |steps| .{ .steps = steps },
        .refused => |reason| .{ .refused = reason },
    };
}

pub fn parse(arena: std.mem.Allocator, request_json: []const u8) ParseError!Parsed {
    const root = json.parseFromSliceLeaky(json.Value, arena, request_json, .{}) catch
        return error.MalformedRequest;
    const obj = if (root == .object) root.object else return error.MalformedRequest;

    const mission_id = strField(obj, mission_id_key) orelse return error.MalformedRequest;
    const planning_root = strField(obj, planning_root_key) orelse return error.MalformedRequest;
    if (planning_root.len < 2 or planning_root[0] != '/') return error.MalformedRequest;
    const resume_flag = if (obj.get(resume_key)) |v| v == .bool and v.bool else false;

    const ctx_cfg: context.Config = blk: {
        const v = obj.get(context_strategy_key) orelse
            break :blk .{ .kind = .substrate, .max_tokens = context.default_max_tokens };
        if (v != .object) return error.MalformedRequest;
        const kind_s = strField(v.object, kind_key) orelse "substrate";
        const kind = std.meta.stringToEnum(context.Kind, kind_s) orelse
            return error.MalformedRequest;
        break :blk .{
            .kind = kind,
            .max_tokens = uintFieldOr(v.object, max_tokens_key, context.default_max_tokens),
        };
    };

    const tools_json: ?[]const u8 = blk: {
        const tv = obj.get(tools_key) orelse break :blk null;
        if (tv != .array) return error.MalformedRequest;
        break :blk try rawJson(arena, tv);
    };

    const steps_result = try parseSteps(arena, obj);

    const provider_function = strField(obj, provider_function_key);
    const router_function = strField(obj, router_function_key);
    if (provider_function == null and router_function == null) return error.MalformedRequest;

    const objective = strField(obj, objective_key);
    if (!resume_flag and objective == null) return error.MalformedRequest;

    return .{
        .mission_id = mission_id,
        .planning_root = planning_root,
        .resume_flag = resume_flag,
        .objective = objective,
        .brief = strField(obj, brief_key),
        .context = ctx_cfg,
        .provider_function = provider_function,
        .router_function = router_function,
        .gate_function = strField(obj, gate_function_key),
        .policy_function = strField(obj, policy_function_key),
        .approval_function = strField(obj, approval_function_key),
        .budget_scope = strField(obj, budget_scope_key),
        .continuity_function = strField(obj, continuity_function_key),
        .continuity_project = strField(obj, continuity_project_key),
        .tools_json = tools_json,
        .max_role_turns = uintFieldOr(obj, max_role_turns_key, 16),
        .fail_threshold = uintFieldOr(obj, fail_threshold_key, 3),
        .gate_threshold = uintFieldOr(obj, gate_threshold_key, 3),
        .role_max_steps = uintFieldOr(obj, role_max_steps_key, 8),
        .trace_path = strField(obj, trace_path_key),
        .steps = switch (steps_result) {
            .steps => |s| s,
            .refused => &.{},
        },
        .steps_refusal = switch (steps_result) {
            .steps => null,
            .refused => |reason| reason,
        },
    };
}

const testing = std.testing;

test "build and parse name the same start fields" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = try build(arena, .{
        .mission_id = "m-1",
        .planning = "/tmp/p",
        .brief_text = "# Brief\n## Objective\nShip it\n## Notes\nx",
        .trace_path = "/tmp/p/events.jsonl",
        .resume_flag = true,
        .bash_desc = "run bash",
        .mcp_entries = "",
        .ctx_kind = .thread,
        .ctx_max_tokens = 1000,
        .role_max_steps = 24,
        .max_role_turns = 64,
    });
    const p = try parse(arena, body);
    try testing.expectEqualStrings("m-1", p.mission_id);
    try testing.expectEqualStrings("/tmp/p", p.planning_root);
    try testing.expectEqualStrings("Ship it", p.objective.?);
    try testing.expect(p.brief != null);
    try testing.expect(p.resume_flag);
    try testing.expectEqual(context.Kind.thread, p.context.kind);
    try testing.expectEqual(@as(usize, 1000), p.context.max_tokens);
    try testing.expectEqual(@as(usize, 24), p.role_max_steps);
    try testing.expectEqual(@as(usize, 64), p.max_role_turns);
    try testing.expectEqualStrings("zygos::models::resolve", p.router_function.?);
    try testing.expectEqualStrings("zygos::policy::check", p.policy_function.?);
    try testing.expectEqualStrings("zygos::approvals::request", p.gate_function.?);
    try testing.expect(p.tools_json != null);
}

test "mission start offers bash, web_search, and web_fetch only" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = try build(arena, .{
        .mission_id = "m-tools",
        .planning = "/tmp/plan",
        .brief_text = "# Brief\n## Objective\nList the tools\n",
        .trace_path = "/tmp/plan/events.jsonl",
        .resume_flag = false,
        .bash_desc = "workspace shell",
        .mcp_entries = "",
        .ctx_kind = .substrate,
        .ctx_max_tokens = 1000,
        .role_max_steps = 24,
        .max_role_turns = 48,
    });
    const parsed = try parse(arena, body);
    const tools_json = parsed.tools_json orelse return error.MissingTools;
    const tools = try json.parseFromSliceLeaky(json.Value, arena, tools_json, .{});
    try testing.expect(tools == .array);
    try testing.expectEqual(@as(usize, 3), tools.array.items.len);

    var saw_bash = false;
    var saw_search = false;
    var saw_fetch = false;
    for (tools.array.items) |item| {
        try testing.expect(item == .object);
        const name = strField(item.object, "name") orelse return error.MissingName;
        const function_id = strField(item.object, "function_id") orelse return error.MissingFunction;
        try testing.expect(std.mem.indexOf(u8, name, "read_file") == null);
        try testing.expect(std.mem.indexOf(u8, function_id, "read_file") == null);
        try testing.expect(std.mem.indexOf(u8, name, "write_file") == null);
        try testing.expect(std.mem.indexOf(u8, function_id, "write_file") == null);
        if (std.mem.eql(u8, name, "bash")) {
            saw_bash = true;
            try testing.expectEqualStrings("zygos::tools::bash", function_id);
        } else if (std.mem.eql(u8, name, "web_search")) {
            saw_search = true;
            try testing.expectEqualStrings("zygos::tools::web_search", function_id);
        } else if (std.mem.eql(u8, name, "web_fetch")) {
            saw_fetch = true;
            try testing.expectEqualStrings("zygos::tools::web_fetch", function_id);
        } else {
            return error.UnexpectedTool;
        }
    }
    try testing.expect(saw_bash);
    try testing.expect(saw_search);
    try testing.expect(saw_fetch);
}

test "parse: a relative planning root and a missing router are malformed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectError(error.MalformedRequest, parse(arena, "{\"mission_id\":\"m\",\"planning_root\":\"rel\",\"objective\":\"o\",\"router_function\":\"r\"}"));
    try testing.expectError(error.MalformedRequest, parse(arena, "{\"mission_id\":\"m\",\"planning_root\":\"/abs\",\"objective\":\"o\"}"));
}

fn minimalRequest(arena: std.mem.Allocator, steps_json: []const u8) ![]u8 {
    return std.fmt.allocPrint(arena,
        \\{{"mission_id":"m","planning_root":"/abs","objective":"o","router_function":"r"{s}}}
    , .{steps_json});
}

fn expectStepsRefusal(want: []const u8, steps_json: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p = try parse(arena, try minimalRequest(arena, steps_json));
    try testing.expectEqualStrings(want, p.steps_refusal orelse return error.TestExpectedRefusal);
}

const steps_params: StartParams = .{
    .mission_id = "m-steps",
    .planning = "/tmp/p",
    .brief_text = "# Brief\n## Objective\nShip it\n",
    .trace_path = "/tmp/p/events.jsonl",
    .resume_flag = false,
    .bash_desc = "run bash",
    .mcp_entries = "",
    .ctx_kind = .substrate,
    .ctx_max_tokens = 1000,
    .role_max_steps = 8,
    .max_role_turns = 16,
};

test "start round-trips the configured steps with pinned definitions" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = "Design the system.\n";
    const sha = pipeline.sha256Hex(text);
    const configured = [_]pipeline.Step{
        .{ .id = "architect", .kind = .custom, .system = text, .definition_sha256 = &sha, .tools = true },
        .{ .id = "executor", .kind = .executor, .system = null, .definition_sha256 = null, .tools = true },
        .{ .id = "verifier", .kind = .verifier, .system = null, .definition_sha256 = null, .tools = false },
    };
    var params = steps_params;
    params.steps = &configured;
    const body = try build(arena, params);

    const v = try json.parseFromSliceLeaky(json.Value, arena, body, .{});
    const wire = v.object.get("steps").?.array.items;
    try testing.expectEqual(@as(usize, 3), wire.len);
    try testing.expectEqualStrings(text, wire[0].object.get("system").?.string);
    try testing.expectEqualStrings(&sha, wire[0].object.get("definition_sha256").?.string);
    try testing.expect(wire[1].object.get("system") == null);
    try testing.expect(wire[1].object.get("definition_sha256") == null);
    try testing.expect(wire[1].object.get("tools").?.bool);
    try testing.expect(!wire[2].object.get("tools").?.bool);

    const p = try parse(arena, body);
    try testing.expect(p.steps_refusal == null);
    try testing.expectEqual(@as(usize, 3), p.steps.len);
    for (configured, p.steps) |want, got| {
        try testing.expectEqualStrings(want.id, got.id);
        try testing.expectEqual(want.kind, got.kind);
        try testing.expectEqual(want.tools, got.tools);
        try testing.expectEqualStrings(want.system orelse "", got.system orelse "");
        try testing.expectEqualStrings(want.definition_sha256 orelse "", got.definition_sha256 orelse "");
    }
    // The other fields still ride the same body.
    try testing.expectEqualStrings("m-steps", p.mission_id);
    try testing.expectEqualStrings("Ship it", p.objective.?);
}

test "absent steps omit the field and parse as the default four" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = try build(arena, steps_params);
    const v = try json.parseFromSliceLeaky(json.Value, arena, body, .{});
    try testing.expect(v.object.get("steps") == null);

    const p = try parse(arena, body);
    try testing.expect(p.steps_refusal == null);
    try testing.expectEqual(@as(usize, 4), p.steps.len);
    try testing.expectEqualStrings("product-owner", p.steps[0].id);
    try testing.expectEqualStrings("executor", p.steps[2].id);
    try testing.expect(p.steps[2].tools);
    try testing.expect(!p.steps[3].tools);
}

test "steps: a definition without a hash gets one computed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p = try parse(arena, try minimalRequest(arena,
        \\,"steps":[{"id":"architect","system":"design it"},{"id":"executor"}]
    ));
    try testing.expect(p.steps_refusal == null);
    const want = pipeline.sha256Hex("design it");
    try testing.expectEqualStrings(&want, p.steps[0].definition_sha256.?);
    try testing.expect(p.steps[1].definition_sha256 == null);
    try testing.expect(p.steps[1].tools);
    try testing.expect(!p.steps[0].tools);
}

test "steps: a definition whose hash does not match fails closed" {
    try expectStepsRefusal("steps[0]: definition hash mismatch",
        \\,"steps":[{"id":"architect","system":"design it","definition_sha256":"00"},{"id":"executor"}]
    );
    try expectStepsRefusal("steps[1]: definition hash mismatch",
        \\,"steps":[{"id":"planner"},{"id":"executor","definition_sha256":"abc"}]
    );
}

test "steps: the worker re-validates the list and refuses with the pipeline reason" {
    try expectStepsRefusal("steps: empty",
        \\,"steps":[]
    );
    try expectStepsRefusal("steps: no executor",
        \\,"steps":[{"id":"planner"},{"id":"verifier"}]
    );
    try expectStepsRefusal("steps[1]: unknown key \"model\"",
        \\,"steps":[{"id":"executor"},{"id":"verifier","model":"x"}]
    );
    try expectStepsRefusal("steps[1]: missing id",
        \\,"steps":[{"id":"executor"},{}]
    );
    try expectStepsRefusal("steps[0]: bad id",
        \\,"steps":[{"id":"Executor"}]
    );
    try expectStepsRefusal("steps[0]: reserved id",
        \\,"steps":[{"id":"task","system":"x"},{"id":"executor"}]
    );
    try expectStepsRefusal("steps[1]: verifier cannot have tools",
        \\,"steps":[{"id":"executor"},{"id":"verifier","tools":true}]
    );
    try expectStepsRefusal("steps[0]: no definition",
        \\,"steps":[{"id":"architect"},{"id":"executor"}]
    );
}

test "steps: wrongly typed values refuse instead of being ignored" {
    try expectStepsRefusal("steps: malformed",
        \\,"steps":"executor"
    );
    try expectStepsRefusal("steps: malformed",
        \\,"steps":null
    );
    try expectStepsRefusal("steps[0]: malformed",
        \\,"steps":["executor"]
    );
    try expectStepsRefusal("steps[0]: bad id",
        \\,"steps":[{"id":7}]
    );
    try expectStepsRefusal("steps[1]: bad tools",
        \\,"steps":[{"id":"executor"},{"id":"verifier","tools":"no"}]
    );
    try expectStepsRefusal("steps[0]: no definition",
        \\,"steps":[{"id":"architect","system":5},{"id":"executor"}]
    );
}
