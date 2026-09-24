//! Pure wire shaping for one role turn over `zygos::turns::run`: build the
//! turn request JSON from resolved parameters, and parse the turn reply into
//! a `RoleOut`. The bus call between the two stays in the orchestrator —
//! this module never sees a worker or an allocator it didn't get handed.

const std = @import("std");
const json = std.json;
const jsonx = @import("../jsonx.zig");

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
        return .{ .ok = try jsonx.assistantText(arena, msg.object) };
    }
    return .{ .failed = "no assistant message in the turn transcript" };
}

pub const Reject = struct {
    raw: []const u8,
    reason: []const u8,
};

pub const DefineOut = union(enum) {
    ok: struct { objective: []const u8, acceptance: []const u8 },
    reject: Reject,
};

pub const PlanOut = union(enum) {
    ok: []const []const u8,
    reject: Reject,
};

pub const VerifyOut = union(enum) {
    ok: struct { passed: bool, reason: []const u8 },
    reject: Reject,
};

/// Real providers wrap role JSON in one whole-output markdown fence.
/// Unwrapping exactly that shape is deterministic — anything else is
/// returned untouched and must still parse as strict JSON (fail closed).
pub fn unwrapFence(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "```")) return trimmed;
    if (!std.mem.endsWith(u8, trimmed, "```")) return trimmed;
    const open_end = std.mem.indexOfScalar(u8, trimmed, '\n') orelse return trimmed;
    if (trimmed.len < open_end + 1 + 3) return trimmed;
    return std.mem.trim(u8, trimmed[open_end + 1 .. trimmed.len - 3], " \t\r\n");
}

/// Excerpt of a task outcome carried into later executor turns. Cuts on a
/// UTF-8 boundary, prefers a word break past max/2, appends an ellipsis.
pub fn outcomeExcerpt(arena: std.mem.Allocator, text: []const u8, max: usize) error{OutOfMemory}![]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len <= max) return arena.dupe(u8, trimmed);
    var end = max;
    while (end > 0 and (trimmed[end] & 0xC0) == 0x80) end -= 1;
    if (std.mem.lastIndexOfScalar(u8, trimmed[0..end], ' ')) |sp| {
        if (sp > max / 2) end = sp;
    }
    return std.fmt.allocPrint(arena, "{s}…", .{std.mem.trimEnd(u8, trimmed[0..end], " \t\r\n")});
}

fn reject(text: []const u8, reason: []const u8) Reject {
    return .{ .raw = text, .reason = reason };
}

pub fn interpretDefine(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}!DefineOut {
    const parsed = json.parseFromSliceLeaky(json.Value, arena, unwrapFence(text), .{}) catch
        return .{ .reject = reject(text, "product-owner output is not JSON") };
    if (parsed != .object)
        return .{ .reject = reject(text, "product-owner output is not an object") };
    const objective = strField(parsed.object, "objective") orelse
        return .{ .reject = reject(text, "product-owner output lacks objective") };
    const acceptance = strField(parsed.object, "acceptance") orelse
        return .{ .reject = reject(text, "product-owner output lacks acceptance") };
    return .{ .ok = .{ .objective = objective, .acceptance = acceptance } };
}

pub fn interpretPlan(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}!PlanOut {
    const parsed = json.parseFromSliceLeaky(json.Value, arena, unwrapFence(text), .{}) catch
        return .{ .reject = reject(text, "planner output is not JSON") };
    if (parsed != .object)
        return .{ .reject = reject(text, "planner output is not an object") };
    const tasks_val = parsed.object.get("tasks") orelse
        return .{ .reject = reject(text, "planner output lacks tasks") };
    if (tasks_val != .array or tasks_val.array.items.len == 0 or tasks_val.array.items.len > 32)
        return .{ .reject = reject(text, "planner tasks must be 1..32 entries") };

    const tasks = try arena.alloc([]const u8, tasks_val.array.items.len);
    for (tasks_val.array.items, 0..) |tv, i| {
        if (tv != .string or tv.string.len == 0)
            return .{ .reject = reject(text, "planner tasks must be non-empty strings") };
        tasks[i] = tv.string;
    }
    return .{ .ok = tasks };
}

pub fn interpretVerify(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}!VerifyOut {
    const parsed = json.parseFromSliceLeaky(json.Value, arena, unwrapFence(text), .{}) catch
        return .{ .reject = reject(text, "verifier output is not JSON") };
    if (parsed != .object)
        return .{ .reject = reject(text, "verifier output is not an object") };
    const passed_val = parsed.object.get("passed") orelse
        return .{ .reject = reject(text, "verifier output lacks passed") };
    if (passed_val != .bool)
        return .{ .reject = reject(text, "verifier passed must be a bool") };
    return .{ .ok = .{
        .passed = passed_val.bool,
        .reason = strField(parsed.object, "reason") orelse "",
    } };
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

test "unwrapFence: whole-output fence with and without a language tag" {
    try testing.expectEqualStrings("{\"a\":1}", unwrapFence("```json\n{\"a\":1}\n```"));
    try testing.expectEqualStrings("{\"a\":1}", unwrapFence("```\n{\"a\":1}\n```"));
    try testing.expectEqualStrings("{\"a\":1}", unwrapFence("  ```json\n{\"a\":1}\n```  \n"));
}

test "unwrapFence: anything but exactly one whole-output fence is untouched" {
    try testing.expectEqualStrings("{\"a\":1}", unwrapFence(" {\"a\":1} "));
    try testing.expectEqualStrings("```{\"a\":1}```", unwrapFence("```{\"a\":1}```"));
    try testing.expectEqualStrings("pre ```json\n{}\n```", unwrapFence("pre ```json\n{}\n```"));
}

test "outcomeExcerpt: short text is duped verbatim, long text cuts on a word" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("done", try outcomeExcerpt(arena, "  done \n", 10));
    const cut = try outcomeExcerpt(arena, "alpha beta gamma delta", 12);
    try testing.expectEqualStrings("alpha beta…", cut);
}

test "outcomeExcerpt: never cuts inside a UTF-8 sequence" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // "ééééé" is 10 bytes; max 9 lands mid-codepoint and must back up.
    const cut = try outcomeExcerpt(arena, "ééééé", 9);
    try testing.expect(std.unicode.utf8ValidateSlice(cut));
}

test "interpretDefine: a fenced object yields objective and acceptance" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const out = try interpretDefine(arena, "```json\n{\"objective\":\"ship\",\"acceptance\":\"tests green\"}\n```");
    try testing.expectEqualStrings("ship", out.ok.objective);
    try testing.expectEqualStrings("tests green", out.ok.acceptance);
}

test "interpretPlan: rejects an empty task list and keeps the raw text" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const out = try interpretPlan(arena, "{\"tasks\":[]}");
    try testing.expectEqualStrings("planner tasks must be 1..32 entries", out.reject.reason);
    try testing.expectEqualStrings("{\"tasks\":[]}", out.reject.raw);
}

test "interpretVerify: passed must be a bool" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bad = try interpretVerify(arena, "{\"passed\":\"yes\"}");
    try testing.expectEqualStrings("verifier passed must be a bool", bad.reject.reason);
    const good = try interpretVerify(arena, "{\"passed\":false,\"reason\":\"nope\"}");
    try testing.expect(!good.ok.passed);
    try testing.expectEqualStrings("nope", good.ok.reason);
}
