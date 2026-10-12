//! Typed trace-event schema (M4.7 roadmap: "Typed TraceEvent schema"). The
//! tagged union shared by emitters (mission/turn drivers) and consumers
//! (JSONL sink, TUI model, `zygos mission trace`): adding a variant forces
//! every exhaustive switch to handle it — unknown-event silent drops become
//! compile errors. Serialization is byte-identical to the legacy fmt-string
//! emitters (events.jsonl is a wire format); parsing is tolerant (missing
//! fields read as defaults, unknown event names as null) so consumers keep
//! their raw-passthrough behavior for foreign lines.

const std = @import("std");
const json = std.json;

pub const TraceEvent = union(enum) {
    mission: Mission,
    role_start: RoleStart,
    role_end: RoleEnd,
    task_start: Task,
    task_done: Task,
    step: Step,
    tool_call: ToolCall,
    tool_result: ToolResult,
    usage: Usage,
    turn_end: TurnEnd,
    steer: Steer,

    pub const Steer = struct {
        text: []const u8 = "",
    };

    pub const Mission = struct {
        from: []const u8 = "?",
        to: []const u8 = "?",
        /// The pipeline cursor after the transition: the step id (null at
        /// gating and done) and its index. Both are absent from pre-pipeline
        /// lines; `step_index == null` means "not recorded".
        step: ?[]const u8 = null,
        step_index: ?i64 = null,
        role_turns: i64 = 0,
        tasks_done: i64 = 0,
        tasks: i64 = 0,
    };
    pub const RoleStart = struct {
        role: []const u8 = "?",
        role_turn: i64 = 0,
        tools: bool = false,
        content: []const u8 = "",
    };
    pub const RoleEnd = struct {
        role: []const u8 = "?",
        outcome: []const u8 = "?",
        reason: ?[]const u8 = null,
    };
    pub const Task = struct {
        index: i64 = 0,
        total: i64 = 0,
        desc: []const u8 = "?",
    };
    pub const Step = struct {
        turn_id: []const u8 = "",
        step: i64 = 0,
        provider: []const u8 = "?",
        model: []const u8 = "?",
        attempt: i64 = 0,
    };
    pub const ToolCall = struct {
        turn_id: []const u8 = "",
        step: i64 = 0,
        tool: []const u8 = "?",
        input: []const u8 = "",
    };
    pub const ToolResult = struct {
        step: i64 = 0,
        tool: []const u8 = "?",
        is_error: bool = false,
        bytes: i64 = 0,
        output: []const u8 = "",
    };
    pub const Usage = struct {
        turn_id: []const u8 = "",
        step: i64 = 0,
        input_tokens: i64 = 0,
        output_tokens: i64 = 0,
    };
    pub const TurnEnd = struct {
        turn_id: []const u8 = "",
        stop: []const u8 = "?",
        steps: i64 = 0,
        /// serialized as "error"
        err: ?[]const u8 = null,
    };
};

/// The event's line body — the caller-fields part of a JSONL line, no
/// surrounding braces and no "ts". Byte-identical to the legacy emitters.
pub fn body(arena: std.mem.Allocator, ev: TraceEvent) error{OutOfMemory}![]const u8 {
    return switch (ev) {
        .mission => |m| missionBody(arena, m),
        .role_start => |r| std.fmt.allocPrint(
            arena,
            "\"event\":\"role_start\",\"role\":{f},\"role_turn\":{d},\"tools\":{},\"content\":{f}",
            .{ json.fmt(r.role, .{}), r.role_turn, r.tools, json.fmt(r.content, .{}) },
        ),
        .role_end => |r| if (r.reason) |reason| std.fmt.allocPrint(
            arena,
            "\"event\":\"role_end\",\"role\":{f},\"outcome\":{f},\"reason\":{f}",
            .{ json.fmt(r.role, .{}), json.fmt(r.outcome, .{}), json.fmt(reason, .{}) },
        ) else std.fmt.allocPrint(
            arena,
            "\"event\":\"role_end\",\"role\":{f},\"outcome\":{f}",
            .{ json.fmt(r.role, .{}), json.fmt(r.outcome, .{}) },
        ),
        .task_start => |t| taskBody(arena, "task_start", t),
        .task_done => |t| taskBody(arena, "task_done", t),
        .step => |s| std.fmt.allocPrint(
            arena,
            "\"event\":\"step\",\"turn_id\":{f},\"step\":{d},\"provider\":{f},\"model\":{f},\"attempt\":{d}",
            .{ json.fmt(s.turn_id, .{}), s.step, json.fmt(s.provider, .{}), json.fmt(s.model, .{}), s.attempt },
        ),
        .tool_call => |tc| std.fmt.allocPrint(
            arena,
            "\"event\":\"tool_call\",\"turn_id\":{f},\"step\":{d},\"tool\":{f},\"input\":{f}",
            .{ json.fmt(tc.turn_id, .{}), tc.step, json.fmt(tc.tool, .{}), json.fmt(tc.input, .{}) },
        ),
        .tool_result => |tr| std.fmt.allocPrint(
            arena,
            "\"event\":\"tool_result\",\"step\":{d},\"tool\":{f},\"is_error\":{},\"bytes\":{d},\"output\":{f}",
            .{ tr.step, json.fmt(tr.tool, .{}), tr.is_error, tr.bytes, json.fmt(tr.output, .{}) },
        ),
        .usage => |u| std.fmt.allocPrint(
            arena,
            "\"event\":\"usage\",\"turn_id\":{f},\"step\":{d},\"input_tokens\":{d},\"output_tokens\":{d}",
            .{ json.fmt(u.turn_id, .{}), u.step, u.input_tokens, u.output_tokens },
        ),
        .steer => |s| std.fmt.allocPrint(
            arena,
            "\"event\":\"steer\",\"text\":{f}",
            .{json.fmt(s.text, .{})},
        ),
        .turn_end => |te| if (te.err) |e| std.fmt.allocPrint(
            arena,
            "\"event\":\"turn_end\",\"turn_id\":{f},\"stop\":{f},\"steps\":{d},\"error\":{f}",
            .{ json.fmt(te.turn_id, .{}), json.fmt(te.stop, .{}), te.steps, json.fmt(e, .{}) },
        ) else std.fmt.allocPrint(
            arena,
            "\"event\":\"turn_end\",\"turn_id\":{f},\"stop\":{f},\"steps\":{d}",
            .{ json.fmt(te.turn_id, .{}), json.fmt(te.stop, .{}), te.steps },
        ),
    };
}

fn missionBody(arena: std.mem.Allocator, m: TraceEvent.Mission) error{OutOfMemory}![]const u8 {
    const cursor = if (m.step_index) |idx|
        try std.fmt.allocPrint(arena, ",\"step\":{f},\"step_index\":{d}", .{ json.fmt(m.step, .{}), idx })
    else
        "";
    return std.fmt.allocPrint(
        arena,
        "\"event\":\"mission\",\"from\":{f},\"to\":{f}{s},\"role_turns\":{d},\"tasks_done\":{d},\"tasks\":{d}",
        .{ json.fmt(m.from, .{}), json.fmt(m.to, .{}), cursor, m.role_turns, m.tasks_done, m.tasks },
    );
}

fn taskBody(arena: std.mem.Allocator, comptime name: []const u8, t: TraceEvent.Task) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "\"event\":\"" ++ name ++ "\",\"index\":{d},\"total\":{d},\"desc\":{f}",
        .{ t.index, t.total, json.fmt(t.desc, .{}) },
    );
}

pub const Parsed = struct { ts: i64, event: TraceEvent };

/// One JSONL line → typed event. Null when the line is not JSON, not an
/// object, or names an unknown event — callers keep raw-passthrough
/// semantics. Slices alias `arena`-parsed memory.
pub fn parse(arena: std.mem.Allocator, line: []const u8) ?Parsed {
    const v = json.parseFromSliceLeaky(json.Value, arena, line, .{}) catch return null;
    if (v != .object) return null;
    const obj = v.object;
    const name = str(obj, "event") orelse return null;
    const ts = int(obj, "ts");

    const ev: TraceEvent = if (std.mem.eql(u8, name, "mission")) .{ .mission = .{
        .from = str(obj, "from") orelse "?",
        .to = str(obj, "to") orelse "?",
        .step = str(obj, "step"),
        .step_index = if (obj.get("step_index")) |si| (if (si == .integer) si.integer else null) else null,
        .role_turns = int(obj, "role_turns"),
        .tasks_done = int(obj, "tasks_done"),
        .tasks = int(obj, "tasks"),
    } } else if (std.mem.eql(u8, name, "role_start")) .{ .role_start = .{
        .role = str(obj, "role") orelse "?",
        .role_turn = int(obj, "role_turn"),
        .tools = boolOf(obj, "tools"),
        .content = str(obj, "content") orelse "",
    } } else if (std.mem.eql(u8, name, "role_end")) .{ .role_end = .{
        .role = str(obj, "role") orelse "?",
        .outcome = str(obj, "outcome") orelse "?",
        .reason = str(obj, "reason"),
    } } else if (std.mem.eql(u8, name, "task_start")) .{
        .task_start = parseTask(obj),
    } else if (std.mem.eql(u8, name, "task_done")) .{
        .task_done = parseTask(obj),
    } else if (std.mem.eql(u8, name, "step")) .{ .step = .{
        .turn_id = str(obj, "turn_id") orelse "",
        .step = int(obj, "step"),
        .provider = str(obj, "provider") orelse "?",
        .model = str(obj, "model") orelse "?",
        .attempt = int(obj, "attempt"),
    } } else if (std.mem.eql(u8, name, "tool_call")) .{ .tool_call = .{
        .turn_id = str(obj, "turn_id") orelse "",
        .step = int(obj, "step"),
        .tool = str(obj, "tool") orelse "?",
        .input = str(obj, "input") orelse "",
    } } else if (std.mem.eql(u8, name, "tool_result")) .{ .tool_result = .{
        .step = int(obj, "step"),
        .tool = str(obj, "tool") orelse "?",
        .is_error = boolOf(obj, "is_error"),
        .bytes = int(obj, "bytes"),
        .output = str(obj, "output") orelse "",
    } } else if (std.mem.eql(u8, name, "usage")) .{ .usage = .{
        .turn_id = str(obj, "turn_id") orelse "",
        .step = int(obj, "step"),
        .input_tokens = int(obj, "input_tokens"),
        .output_tokens = int(obj, "output_tokens"),
    } } else if (std.mem.eql(u8, name, "steer")) .{ .steer = .{
        .text = str(obj, "text") orelse "",
    } } else if (std.mem.eql(u8, name, "turn_end")) .{ .turn_end = .{
        .turn_id = str(obj, "turn_id") orelse "",
        .stop = str(obj, "stop") orelse "?",
        .steps = int(obj, "steps"),
        .err = str(obj, "error"),
    } } else return null;

    return .{ .ts = ts, .event = ev };
}

fn parseTask(obj: json.ObjectMap) TraceEvent.Task {
    return .{
        .index = int(obj, "index"),
        .total = int(obj, "total"),
        .desc = str(obj, "desc") orelse "?",
    };
}

// ---------------------------------------------------------------------------
// tolerant field readers (shared with the legacy consumers' semantics)
// ---------------------------------------------------------------------------

fn str(obj: json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn int(obj: json.ObjectMap, key: []const u8) i64 {
    const v = obj.get(key) orelse return 0;
    return if (v == .integer) v.integer else 0;
}

fn boolOf(obj: json.ObjectMap, key: []const u8) bool {
    const v = obj.get(key) orelse return false;
    return v == .bool and v.bool;
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

fn expectBody(expected: []const u8, ev: TraceEvent) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualStrings(expected, try body(arena_state.allocator(), ev));
}

test "body: every variant serializes byte-identical to the legacy emitters" {
    try expectBody(
        \\"event":"mission","from":"planning","to":"executing","role_turns":2,"tasks_done":1,"tasks":6
    , .{ .mission = .{ .from = "planning", .to = "executing", .role_turns = 2, .tasks_done = 1, .tasks = 6 } });
    try expectBody(
        \\"event":"mission","from":"running","to":"running","step":"executor","step_index":2,"role_turns":2,"tasks_done":1,"tasks":6
    , .{ .mission = .{ .from = "running", .to = "running", .step = "executor", .step_index = 2, .role_turns = 2, .tasks_done = 1, .tasks = 6 } });
    try expectBody(
        \\"event":"mission","from":"running","to":"gating","step":null,"step_index":4,"role_turns":4,"tasks_done":1,"tasks":1
    , .{ .mission = .{ .from = "running", .to = "gating", .step_index = 4, .role_turns = 4, .tasks_done = 1, .tasks = 1 } });
    try expectBody(
        \\"event":"role_start","role":"executor","role_turn":3,"tools":true,"content":"Objective: ship"
    , .{ .role_start = .{ .role = "executor", .role_turn = 3, .tools = true, .content = "Objective: ship" } });
    try expectBody(
        \\"event":"role_end","role":"executor","outcome":"ok"
    , .{ .role_end = .{ .role = "executor", .outcome = "ok" } });
    try expectBody(
        \\"event":"role_end","role":"executor","outcome":"failed","reason":"max_steps"
    , .{ .role_end = .{ .role = "executor", .outcome = "failed", .reason = "max_steps" } });
    try expectBody(
        \\"event":"task_start","index":2,"total":6,"desc":"implement the lexer"
    , .{ .task_start = .{ .index = 2, .total = 6, .desc = "implement the lexer" } });
    try expectBody(
        \\"event":"task_done","index":2,"total":6,"desc":"implement the lexer"
    , .{ .task_done = .{ .index = 2, .total = 6, .desc = "implement the lexer" } });
    try expectBody(
        \\"event":"step","turn_id":"t1","step":1,"provider":"zygos::providers::glm","model":"glm-5.2","attempt":0
    , .{ .step = .{ .turn_id = "t1", .step = 1, .provider = "zygos::providers::glm", .model = "glm-5.2" } });
    try expectBody(
        \\"event":"tool_call","turn_id":"t1","step":1,"tool":"bash","input":"{\"command\":\"ls\"}"
    , .{ .tool_call = .{ .turn_id = "t1", .step = 1, .tool = "bash", .input = "{\"command\":\"ls\"}" } });
    try expectBody(
        \\"event":"tool_result","step":1,"tool":"bash","is_error":false,"bytes":512,"output":"ok"
    , .{ .tool_result = .{ .step = 1, .tool = "bash", .bytes = 512, .output = "ok" } });
    try expectBody(
        \\"event":"usage","turn_id":"t1","step":2,"input_tokens":1200,"output_tokens":88
    , .{ .usage = .{ .turn_id = "t1", .step = 2, .input_tokens = 1200, .output_tokens = 88 } });
    try expectBody(
        \\"event":"turn_end","turn_id":"t1","stop":"end_turn","steps":4
    , .{ .turn_end = .{ .turn_id = "t1", .stop = "end_turn", .steps = 4 } });
    try expectBody(
        \\"event":"turn_end","turn_id":"t1","stop":"failed","steps":0,"error":"route_exhausted"
    , .{ .turn_end = .{ .turn_id = "t1", .stop = "failed", .steps = 0, .err = "route_exhausted" } });
}

test "parse: body round-trips through a full line for every variant" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cases = [_]TraceEvent{
        .{ .mission = .{ .from = "a", .to = "b", .role_turns = 1, .tasks_done = 2, .tasks = 3 } },
        .{ .mission = .{ .from = "running", .to = "running", .step = "architect", .step_index = 1, .role_turns = 1, .tasks_done = 0, .tasks = 0 } },
        .{ .mission = .{ .from = "running", .to = "gating", .step = null, .step_index = 3, .role_turns = 2, .tasks_done = 1, .tasks = 1 } },
        .{ .role_start = .{ .role = "planner", .role_turn = 1, .tools = false, .content = "hi" } },
        .{ .role_end = .{ .role = "planner", .outcome = "failed", .reason = "why" } },
        .{ .task_start = .{ .index = 1, .total = 2, .desc = "d" } },
        .{ .task_done = .{ .index = 2, .total = 2, .desc = "d" } },
        .{ .step = .{ .turn_id = "t", .step = 3, .provider = "p", .model = "m", .attempt = 1 } },
        .{ .tool_call = .{ .turn_id = "t", .step = 3, .tool = "bash", .input = "{}" } },
        .{ .tool_result = .{ .step = 3, .tool = "bash", .is_error = true, .bytes = 9, .output = "no" } },
        .{ .usage = .{ .turn_id = "t", .step = 3, .input_tokens = 10, .output_tokens = 2 } },
        .{ .turn_end = .{ .turn_id = "t", .stop = "aborted", .steps = 3, .err = "boom" } },
        .{ .steer = .{ .text = "focus on the docs" } },
    };
    for (cases) |ev| {
        const line = try std.fmt.allocPrint(arena, "{{\"ts\":42,{s}}}", .{try body(arena, ev)});
        const parsed = parse(arena, line) orelse return error.ParseFailed;
        try testing.expectEqual(@as(i64, 42), parsed.ts);
        try testing.expectEqualDeep(ev, parsed.event);
    }
}

test "parse: unknown event names, non-objects, and garbage are null" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expect(parse(arena, "{\"ts\":1,\"event\":\"novel_kind\",\"x\":1}") == null);
    try testing.expect(parse(arena, "[1,2,3]") == null);
    try testing.expect(parse(arena, "not-json garbage line") == null);
    try testing.expect(parse(arena, "{\"ts\":1}") == null); // no event field
}

test "parse: missing fields read as defaults, absent ts as 0" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parsed = parse(arena, "{\"event\":\"role_end\"}") orelse return error.ParseFailed;
    try testing.expectEqual(@as(i64, 0), parsed.ts);
    try testing.expectEqualStrings("?", parsed.event.role_end.role);
    try testing.expectEqualStrings("?", parsed.event.role_end.outcome);
    try testing.expect(parsed.event.role_end.reason == null);
}
