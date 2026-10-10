//! Pure request shaping for one turn: parse the `zygos::turns::run` request
//! into resolved parameters, the tool routing table, and the transcript
//! seed; plus the tool_result wire helper. No bus, no orchestrator state —
//! everything is arena-in, slices point into the arena.

const std = @import("std");
const json = std.json;
const jsonx = @import("../jsonx.zig");

const strField = jsonx.strField;
const rawJson = jsonx.rawJson;

pub const ToolRoute = struct {
    function_id: []const u8,
    requires_approval: bool = false,
};

pub const Parsed = struct {
    model: []const u8,
    system: []const u8,
    max_steps: usize,
    /// Wall-clock budget for the whole turn (ms). Null: unbounded. Checked
    /// before every step; the remainder bounds each bash call.
    wall_clock_ms: ?u64,
    static_provider: ?[]const u8,
    router_fn: ?[]const u8,
    step_id: []const u8,
    policy_fn: ?[]const u8,
    approval_fn: ?[]const u8,
    turn_id: ?[]const u8,
    budget_scope: ?[]const u8,
    budget_fn: []const u8,
    trace_path: ?[]const u8,
    /// Tool name → route; keys/values point into the arena-parsed request.
    routes: std.StringHashMap(ToolRoute),
    /// Raw JSON of the request's tools array ("[]" when absent) — spliced
    /// verbatim into every provider request.
    tools_json: []const u8,
    /// Raw message JSON texts in request order; the turn appends to it.
    transcript: std.ArrayList([]const u8),
};

pub fn parse(arena: std.mem.Allocator, request_json: []const u8) error{ OutOfMemory, MalformedRequest }!Parsed {
    const root = json.parseFromSliceLeaky(json.Value, arena, request_json, .{}) catch
        return error.MalformedRequest;
    const obj = if (root == .object) root.object else return error.MalformedRequest;

    const static_provider = strField(obj, "provider_function");
    const router_fn = strField(obj, "router_function");
    if (static_provider == null and router_fn == null) return error.MalformedRequest;

    // Tool routing table: name → {function_id, requires_approval}.
    var routes = std.StringHashMap(ToolRoute).init(arena);
    const tools_json = blk: {
        const tools_val = obj.get("tools") orelse break :blk "[]";
        if (tools_val != .array) return error.MalformedRequest;
        for (tools_val.array.items) |tv| {
            if (tv != .object) return error.MalformedRequest;
            const name = strField(tv.object, "name") orelse return error.MalformedRequest;
            const fid = strField(tv.object, "function_id") orelse return error.MalformedRequest;
            const approval = if (tv.object.get("requires_approval")) |a| a == .bool and a.bool else false;
            try routes.put(name, .{ .function_id = fid, .requires_approval = approval });
        }
        break :blk try rawJson(arena, tools_val);
    };

    var transcript: std.ArrayList([]const u8) = .empty;
    if (obj.get("messages")) |msgs| {
        if (msgs != .array) return error.MalformedRequest;
        for (msgs.array.items) |m| try transcript.append(arena, try rawJson(arena, m));
    }

    return .{
        .model = strField(obj, "model") orelse "unknown",
        .system = strField(obj, "system") orelse "",
        .max_steps = if (obj.get("max_steps")) |v|
            (if (v == .integer and v.integer > 0) @intCast(v.integer) else 8)
        else
            8,
        .wall_clock_ms = if (obj.get("wall_clock_ms")) |v|
            (if (v == .integer and v.integer > 0) @as(?u64, @intCast(v.integer)) else null)
        else
            null,
        .static_provider = static_provider,
        .router_fn = router_fn,
        .step_id = strField(obj, "step_id") orelse "",
        .policy_fn = strField(obj, "policy_function"),
        .approval_fn = strField(obj, "approval_function"),
        .turn_id = strField(obj, "turn_id"),
        .budget_scope = strField(obj, "budget_scope"),
        .budget_fn = strField(obj, "budget_function") orelse "zygos::budget::check",
        .trace_path = strField(obj, "trace_path"),
        .routes = routes,
        .tools_json = tools_json,
        .transcript = transcript,
    };
}

pub fn toolResult(arena: std.mem.Allocator, tool_use_id: []const u8, content: []const u8, is_error: bool) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "{{\"type\":\"tool_result\",\"tool_use_id\":{f},\"content\":{f},\"is_error\":{}}}",
        .{ json.fmt(tool_use_id, .{}), json.fmt(content, .{}), is_error },
    );
}

pub fn joinComma(arena: std.mem.Allocator, items: []const []const u8) error{OutOfMemory}![]const u8 {
    return std.mem.join(arena, ",", items);
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "parse: full request resolves fields, routes and transcript seed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var p = try parse(arena,
        \\{"model":"m1","system":"s","max_steps":3,"provider_function":"p::f",
        \\ "turn_id":"t1","budget_scope":"b","trace_path":"/tmp/t.jsonl",
        \\ "tools":[{"name":"read","function_id":"fs::read"},
        \\          {"name":"rm","function_id":"fs::rm","requires_approval":true}],
        \\ "messages":[{"role":"user","content":"hi"}]}
    );
    try testing.expectEqualStrings("m1", p.model);
    try testing.expectEqual(@as(usize, 3), p.max_steps);
    try testing.expectEqualStrings("p::f", p.static_provider.?);
    try testing.expectEqualStrings("t1", p.turn_id.?);
    try testing.expectEqualStrings("zygos::budget::check", p.budget_fn);
    try testing.expectEqualStrings("fs::read", p.routes.get("read").?.function_id);
    try testing.expect(p.routes.get("rm").?.requires_approval);
    try testing.expect(!p.routes.get("read").?.requires_approval);
    try testing.expectEqual(@as(usize, 1), p.transcript.items.len);
    try testing.expectEqualStrings("{\"role\":\"user\",\"content\":\"hi\"}", p.transcript.items[0]);
}

test "parse: wall_clock_ms is optional and must be positive" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const set = try parse(arena,
        \\{"provider_function":"p::f","wall_clock_ms":540000}
    );
    try testing.expectEqual(@as(?u64, 540000), set.wall_clock_ms);
    const absent = try parse(arena,
        \\{"provider_function":"p::f"}
    );
    try testing.expectEqual(@as(?u64, null), absent.wall_clock_ms);
    const zero = try parse(arena,
        \\{"provider_function":"p::f","wall_clock_ms":0}
    );
    try testing.expectEqual(@as(?u64, null), zero.wall_clock_ms);
}

test "parse: defaults — max_steps 8 (also on zero/negative), empty tools, no messages" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p = try parse(arena,
        \\{"router_function":"r::f","max_steps":0}
    );
    try testing.expectEqual(@as(usize, 8), p.max_steps);
    try testing.expectEqualStrings("unknown", p.model);
    try testing.expectEqualStrings("[]", p.tools_json);
    try testing.expectEqual(@as(usize, 0), p.transcript.items.len);
    try testing.expectEqual(@as(?[]const u8, null), p.static_provider);
}

test "parse: malformed requests fail closed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Not JSON / not an object / neither provider nor router.
    try testing.expectError(error.MalformedRequest, parse(arena, "nope"));
    try testing.expectError(error.MalformedRequest, parse(arena, "[]"));
    try testing.expectError(error.MalformedRequest, parse(arena, "{\"model\":\"m\"}"));
    // Tools not an array / tool missing name or function_id.
    try testing.expectError(error.MalformedRequest, parse(arena,
        \\{"provider_function":"p","tools":{}}
    ));
    try testing.expectError(error.MalformedRequest, parse(arena,
        \\{"provider_function":"p","tools":[{"function_id":"f"}]}
    ));
    try testing.expectError(error.MalformedRequest, parse(arena,
        \\{"provider_function":"p","tools":[{"name":"n"}]}
    ));
    // Messages not an array.
    try testing.expectError(error.MalformedRequest, parse(arena,
        \\{"provider_function":"p","messages":"hi"}
    ));
}

test "toolResult and joinComma wire shapes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings(
        "{\"type\":\"tool_result\",\"tool_use_id\":\"t1\",\"content\":\"out\",\"is_error\":false}",
        try toolResult(arena, "t1", "out", false),
    );
    try testing.expectEqualStrings("a,b", try joinComma(arena, &.{ "a", "b" }));
    try testing.expectEqualStrings("", try joinComma(arena, &.{}));
}
