//! Pure wire shaping for one role turn over `zygos::turns::run`: build the
//! turn request JSON from resolved parameters, and parse the turn reply into
//! a `RoleOut`. The bus call between the two stays in the orchestrator —
//! this module never sees a worker or an allocator it didn't get handed.

const std = @import("std");
const json = std.json;
const jsonx = @import("../jsonx.zig");
const out_mod = @import("out.zig");

const strField = jsonx.strField;

pub const RoleOut = union(enum) {
    ok: []const u8, // final assistant text, arena-owned
    failed: []const u8, // human-readable reason, arena-owned
    exhausted, // the turn stopped on its step budget (max_steps), not an error
};

/// Resolved turn parameters. Optionals are emitted only when present;
/// `tools_json` is already gated by the caller's with_tools decision.
pub const Req = struct {
    system: []const u8,
    step_id: []const u8,
    max_steps: usize,
    content: []const u8,
    provider_function: ?[]const u8 = null,
    router_function: ?[]const u8 = null,
    policy_function: ?[]const u8 = null,
    approval_function: ?[]const u8 = null,
    budget_scope: ?[]const u8 = null,
    tools_json: ?[]const u8 = null,
    trace_path: ?[]const u8 = null,
};

pub fn buildRequest(arena: std.mem.Allocator, r: Req) error{OutOfMemory}![]const u8 {
    var req: std.Io.Writer.Allocating = .init(arena);
    errdefer req.deinit();
    const w = &req.writer;
    w.print("{{\"system\":{f},\"step_id\":{f},\"max_steps\":{d}," ++
        "\"messages\":[{{\"role\":\"user\",\"content\":{f}}}]", .{
        json.fmt(r.system, .{}),
        json.fmt(r.step_id, .{}),
        r.max_steps,
        json.fmt(r.content, .{}),
    }) catch return error.OutOfMemory;
    if (r.provider_function) |v|
        w.print(",\"provider_function\":{f}", .{json.fmt(v, .{})}) catch return error.OutOfMemory;
    if (r.router_function) |v|
        w.print(",\"router_function\":{f}", .{json.fmt(v, .{})}) catch return error.OutOfMemory;
    if (r.policy_function) |v|
        w.print(",\"policy_function\":{f}", .{json.fmt(v, .{})}) catch return error.OutOfMemory;
    if (r.approval_function) |v|
        w.print(",\"approval_function\":{f}", .{json.fmt(v, .{})}) catch return error.OutOfMemory;
    if (r.budget_scope) |v|
        w.print(",\"budget_scope\":{f}", .{json.fmt(v, .{})}) catch return error.OutOfMemory;
    if (r.tools_json) |t|
        w.print(",\"tools\":{s}", .{t}) catch return error.OutOfMemory;
    if (r.trace_path) |v|
        w.print(",\"trace_path\":{f}", .{json.fmt(v, .{})}) catch return error.OutOfMemory;
    w.writeAll("}") catch return error.OutOfMemory;
    return req.written();
}

/// Fail-closed parse of a turn reply: anything but end_turn with an
/// assistant message in the transcript is a failure (max_steps excepted —
/// that's the caller's retry signal, not an error).
pub fn parseReply(
    arena: std.mem.Allocator,
    step_id: []const u8,
    payload: []const u8,
) error{OutOfMemory}!RoleOut {
    const reply = json.parseFromSliceLeaky(json.Value, arena, payload, .{}) catch
        return .{ .failed = "malformed turn reply" };
    if (reply != .object) return .{ .failed = "malformed turn reply" };
    const stop = strField(reply.object, "stop") orelse "failed";
    if (std.mem.eql(u8, stop, "max_steps")) return .exhausted;
    if (!std.mem.eql(u8, stop, "end_turn"))
        return .{ .failed = try std.fmt.allocPrint(arena, "{s} turn stopped: {s}", .{ step_id, stop }) };

    const transcript = reply.object.get("transcript") orelse
        return .{ .failed = "turn reply carried no transcript" };
    if (transcript != .array) return .{ .failed = "turn reply carried no transcript" };
    var i = transcript.array.items.len;
    while (i > 0) {
        i -= 1;
        const msg = transcript.array.items[i];
        if (msg != .object) continue;
        const mrole = strField(msg.object, "role") orelse continue;
        if (!std.mem.eql(u8, mrole, "assistant")) continue;
        return .{ .ok = try out_mod.assistantText(arena, msg.object) };
    }
    return .{ .failed = "no assistant message in the turn transcript" };
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "buildRequest: minimal request carries only the required fields" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const req = try buildRequest(arena, .{
        .system = "be brief",
        .step_id = "planner",
        .max_steps = 3,
        .content = "plan it",
    });
    try testing.expectEqualStrings(
        "{\"system\":\"be brief\",\"step_id\":\"planner\",\"max_steps\":3," ++
            "\"messages\":[{\"role\":\"user\",\"content\":\"plan it\"}]}",
        req,
    );
}

test "buildRequest: optionals appear when set, tools_json is spliced raw" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const req = try buildRequest(arena, .{
        .system = "s",
        .step_id = "executor",
        .max_steps = 8,
        .content = "go",
        .provider_function = "p::f",
        .budget_scope = "m1",
        .tools_json = "[{\"name\":\"read_file\"}]",
        .trace_path = "/tmp/t.jsonl",
    });
    const parsed = try json.parseFromSliceLeaky(json.Value, arena, req, .{});
    try testing.expectEqualStrings("p::f", parsed.object.get("provider_function").?.string);
    try testing.expectEqualStrings("m1", parsed.object.get("budget_scope").?.string);
    try testing.expectEqualStrings("/tmp/t.jsonl", parsed.object.get("trace_path").?.string);
    try testing.expectEqualStrings("read_file", parsed.object.get("tools").?.array.items[0].object.get("name").?.string);
    try testing.expectEqual(@as(?json.Value, null), parsed.object.get("router_function"));
}

test "parseReply: end_turn returns the last assistant message's text" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const out = try parseReply(arena, "planner",
        \\{"stop":"end_turn","transcript":[
        \\  {"role":"assistant","content":"draft"},
        \\  {"role":"user","content":"tool result"},
        \\  {"role":"assistant","content":[{"type":"text","text":"final"}]}
        \\]}
    );
    try testing.expectEqualStrings("final", out.ok);
}

test "parseReply: max_steps is exhausted, any other stop fails with the stop named" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqual(RoleOut.exhausted, try parseReply(arena, "executor",
        \\{"stop":"max_steps","transcript":[]}
    ));
    const failed = try parseReply(arena, "executor",
        \\{"stop":"aborted","transcript":[]}
    );
    try testing.expectEqualStrings("executor turn stopped: aborted", failed.failed);
}

test "parseReply: malformed reply, missing transcript and no assistant all fail closed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("malformed turn reply", (try parseReply(arena, "r", "not json")).failed);
    try testing.expectEqualStrings("malformed turn reply", (try parseReply(arena, "r", "[]")).failed);
    try testing.expectEqualStrings(
        "turn reply carried no transcript",
        (try parseReply(arena, "r", "{\"stop\":\"end_turn\"}")).failed,
    );
    try testing.expectEqualStrings(
        "no assistant message in the turn transcript",
        (try parseReply(arena, "r",
            \\{"stop":"end_turn","transcript":[{"role":"user","content":"x"}]}
        )).failed,
    );
}
