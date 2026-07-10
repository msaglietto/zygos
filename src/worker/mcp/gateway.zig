//! MCP gateway, pure layer (W6, docs/specs/mcp-gateway.md). One JSON-RPC 2.0
//! message in (newline-delimited JSON, the MCP stdio framing), one optional
//! reply out; bus access through an injected Caller vtable. The static tool
//! table below IS the allowlist: exactly the `zygos::tessera::*` functions,
//! unknown tools and bus errors are JSON-RPC errors (fail closed). No stdio
//! here — the binary glue owns the loop.

const std = @import("std");
const json = std.json;

pub const CallError = error{ OutOfMemory, Shutdown };

pub const Result = union(enum) {
    ok: []const u8, // arena-owned reply payload
    err: []const u8, // arena-owned bus error code
};

pub const Caller = struct {
    ctx: *anyopaque,
    callFn: *const fn (ctx: *anyopaque, function: []const u8, request_json: []const u8, arena: std.mem.Allocator) CallError!Result,

    fn call(self: Caller, function: []const u8, request_json: []const u8, arena: std.mem.Allocator) CallError!Result {
        return self.callFn(self.ctx, function, request_json, arena);
    }
};

const Tool = struct {
    name: []const u8,
    function: []const u8,
    description: []const u8,
};

pub const tools = [_]Tool{
    .{ .name = "tessera_project_status", .function = "zygos::tessera::project_status", .description = "Per-project vault digest: sessions, threads, staleness, open actions." },
    .{ .name = "tessera_open_threads", .function = "zygos::tessera::open_threads", .description = "Open threads from a project's newest session entry." },
    .{ .name = "tessera_stale_projects", .function = "zygos::tessera::stale_projects", .description = "Projects with no session in more than 14 days." },
    .{ .name = "tessera_reflect", .function = "zygos::tessera::reflect", .description = "Cross-project pattern detection: stalled loops and recurring threads." },
    .{ .name = "tessera_session_open", .function = "zygos::tessera::session_open", .description = "Read the last session's leaving-behind and open threads for a project." },
    .{ .name = "tessera_session_close", .function = "zygos::tessera::session_close", .description = "Prepend a session entry and promote action items to PROJECT.md." },
    .{ .name = "tessera_capture", .function = "zygos::tessera::capture", .description = "Route raw input to a destination note via the configured taxonomy." },
    .{ .name = "tessera_checkpoint", .function = "zygos::tessera::checkpoint", .description = "Shadow-git checkpoint of the vault before a write." },
    .{ .name = "tessera_undo", .function = "zygos::tessera::undo", .description = "Restore the vault to the most recent checkpoint." },
};

pub const protocol_version = "2025-06-18";
const known_versions = [_][]const u8{ "2024-11-05", "2025-03-26", protocol_version };

/// One JSON-RPC message → optional reply (null for notifications). Any
/// failure other than OOM becomes a JSON-RPC error reply — the loop never
/// crashes on input.
pub fn handle(arena: std.mem.Allocator, caller: Caller, line: []const u8) error{OutOfMemory}!?[]const u8 {
    const root = json.parseFromSliceLeaky(json.Value, arena, line, .{}) catch
        return try errorReply(arena, .null, -32700, "parse error");
    if (root != .object) return try errorReply(arena, .null, -32600, "invalid request");
    const obj = root.object;

    // A request without an id is a notification: never answered, even on error.
    const id: json.Value = obj.get("id") orelse {
        return null;
    };

    const method_v = obj.get("method") orelse
        return try errorReply(arena, id, -32600, "invalid request");
    if (method_v != .string) return try errorReply(arena, id, -32600, "invalid request");
    const method = method_v.string;

    if (std.mem.eql(u8, method, "initialize")) return try initializeReply(arena, obj, id);
    if (std.mem.eql(u8, method, "tools/list")) return try toolsListReply(arena, id);
    if (std.mem.eql(u8, method, "tools/call")) return try toolsCall(arena, caller, obj, id);
    return try errorReply(arena, id, -32601, "method not found");
}

fn initializeReply(arena: std.mem.Allocator, obj: json.ObjectMap, id: json.Value) error{OutOfMemory}![]const u8 {
    // Echo the client's protocolVersion when we know it, else speak ours.
    var version: []const u8 = protocol_version;
    if (obj.get("params")) |p| if (p == .object) if (p.object.get("protocolVersion")) |v| if (v == .string) {
        for (known_versions) |kv| {
            if (std.mem.eql(u8, kv, v.string)) version = v.string;
        }
    };
    return std.fmt.allocPrint(
        arena,
        "{{\"jsonrpc\":\"2.0\",\"id\":{f},\"result\":{{\"protocolVersion\":\"{s}\"," ++
            "\"capabilities\":{{\"tools\":{{}}}}," ++
            "\"serverInfo\":{{\"name\":\"zygos-mcp-gateway\",\"version\":\"0.1.0\"}}}}}}",
        .{ json.fmt(id, .{}), version },
    );
}

fn toolsListReply(arena: std.mem.Allocator, id: json.Value) error{OutOfMemory}![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    errdefer out.deinit();
    const w = &out.writer;
    w.print("{{\"jsonrpc\":\"2.0\",\"id\":{f},\"result\":{{\"tools\":[", .{json.fmt(id, .{})}) catch return error.OutOfMemory;
    for (tools, 0..) |t, i| {
        if (i > 0) w.writeAll(",") catch return error.OutOfMemory;
        // Workers validate their own requests fail-closed; a permissive
        // schema here avoids drifting duplicates (spec).
        w.print("{{\"name\":\"{s}\",\"description\":{f},\"inputSchema\":{{\"type\":\"object\"}}}}", .{
            t.name, json.fmt(t.description, .{}),
        }) catch return error.OutOfMemory;
    }
    w.writeAll("]}}") catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn toolsCall(arena: std.mem.Allocator, caller: Caller, obj: json.ObjectMap, id: json.Value) error{OutOfMemory}![]const u8 {
    const params_v = obj.get("params") orelse
        return try errorReply(arena, id, -32602, "invalid params");
    if (params_v != .object) return try errorReply(arena, id, -32602, "invalid params");
    const name_v = params_v.object.get("name") orelse
        return try errorReply(arena, id, -32602, "invalid params");
    if (name_v != .string) return try errorReply(arena, id, -32602, "invalid params");

    const tool = for (tools) |t| {
        if (std.mem.eql(u8, t.name, name_v.string)) break t;
    } else return try errorReply(arena, id, -32602, "unknown tool");

    const request_json = blk: {
        const args = params_v.object.get("arguments") orelse break :blk "{}";
        break :blk try std.fmt.allocPrint(arena, "{f}", .{json.fmt(args, .{})});
    };

    const res = caller.call(tool.function, request_json, arena) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Shutdown => return try errorReply(arena, id, -32000, "bus shutdown"),
    };
    switch (res) {
        .ok => |payload| return std.fmt.allocPrint(
            arena,
            "{{\"jsonrpc\":\"2.0\",\"id\":{f},\"result\":{{\"content\":[{{\"type\":\"text\",\"text\":{f}}}],\"isError\":false}}}}",
            .{ json.fmt(id, .{}), json.fmt(payload, .{}) },
        ),
        .err => |code| return try errorReply(arena, id, -32000, code),
    }
}

fn errorReply(arena: std.mem.Allocator, id: json.Value, code: i32, message: []const u8) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "{{\"jsonrpc\":\"2.0\",\"id\":{f},\"error\":{{\"code\":{d},\"message\":{f}}}}}",
        .{ json.fmt(id, .{}), code, json.fmt(message, .{}) },
    );
}

// ---------------------------------------------------------------------------
// Tests (docs/specs/mcp-gateway.md test contract)
// ---------------------------------------------------------------------------

const testing = std.testing;

const FakeCaller = struct {
    reply: Result = .{ .ok = "{\"fake\":true}" },
    fail_shutdown: bool = false,
    calls: usize = 0,
    last_function: []const u8 = "",
    last_request: []const u8 = "",

    fn caller(self: *FakeCaller) Caller {
        return .{ .ctx = self, .callFn = &callFn };
    }

    fn callFn(ctx: *anyopaque, function: []const u8, request_json: []const u8, arena: std.mem.Allocator) CallError!Result {
        const self: *FakeCaller = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.last_function = try arena.dupe(u8, function);
        self.last_request = try arena.dupe(u8, request_json);
        if (self.fail_shutdown) return error.Shutdown;
        return switch (self.reply) {
            .ok => |p| .{ .ok = try arena.dupe(u8, p) },
            .err => |c| .{ .err = try arena.dupe(u8, c) },
        };
    }
};

const TestCtx = struct {
    arena_state: std.heap.ArenaAllocator,
    fake: FakeCaller = .{},

    fn init() TestCtx {
        return .{ .arena_state = std.heap.ArenaAllocator.init(testing.allocator) };
    }

    fn deinit(self: *TestCtx) void {
        self.arena_state.deinit();
    }

    fn run(self: *TestCtx, line: []const u8) !?[]const u8 {
        return handle(self.arena_state.allocator(), self.fake.caller(), line);
    }

    /// Parse a reply and return the parsed root (arena-backed).
    fn parsed(self: *TestCtx, reply: []const u8) !json.Value {
        return json.parseFromSliceLeaky(json.Value, self.arena_state.allocator(), reply, .{});
    }
};

test "initialize replies with tools capability and echoes a known protocolVersion" {
    var t = TestCtx.init();
    defer t.deinit();
    const reply = (try t.run(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}
    )).?;
    const v = try t.parsed(reply);
    const result = v.object.get("result").?.object;
    try testing.expectEqualStrings("2024-11-05", result.get("protocolVersion").?.string);
    try testing.expect(result.get("capabilities").?.object.get("tools") != null);
    try testing.expectEqual(@as(i64, 1), v.object.get("id").?.integer);

    // Unknown version → ours.
    const reply2 = (try t.run(
        \\{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}
    )).?;
    const v2 = try t.parsed(reply2);
    try testing.expectEqualStrings(protocol_version, v2.object.get("result").?.object.get("protocolVersion").?.string);
}

test "notifications produce no reply" {
    var t = TestCtx.init();
    defer t.deinit();
    try testing.expectEqual(@as(?[]const u8, null), try t.run(
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    ));
    // Even an unknown or malformed method without an id stays silent.
    try testing.expectEqual(@as(?[]const u8, null), try t.run(
        \\{"jsonrpc":"2.0","method":"no/such/method"}
    ));
    try testing.expectEqual(@as(usize, 0), t.fake.calls);
}

test "tools/list returns exactly the 9 tessera tools" {
    var t = TestCtx.init();
    defer t.deinit();
    const reply = (try t.run(
        \\{"jsonrpc":"2.0","id":3,"method":"tools/list"}
    )).?;
    const v = try t.parsed(reply);
    const list = v.object.get("result").?.object.get("tools").?.array.items;
    try testing.expectEqual(@as(usize, 9), list.len);
    for (list, tools) |item, expected| {
        try testing.expectEqualStrings(expected.name, item.object.get("name").?.string);
        try testing.expect(item.object.get("inputSchema") != null);
    }
}

test "tools/call routes to the mapped bus function with arguments as request JSON" {
    var t = TestCtx.init();
    defer t.deinit();
    t.fake.reply = .{ .ok = "{\"projects\":[]}" };
    const reply = (try t.run(
        \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"tessera_open_threads","arguments":{"project":"zygos"}}}
    )).?;
    try testing.expectEqualStrings("zygos::tessera::open_threads", t.fake.last_function);
    const req = try t.parsed(t.fake.last_request);
    try testing.expectEqualStrings("zygos", req.object.get("project").?.string);

    const v = try t.parsed(reply);
    const result = v.object.get("result").?.object;
    try testing.expectEqual(false, result.get("isError").?.bool);
    const content = result.get("content").?.array.items;
    try testing.expectEqualStrings("{\"projects\":[]}", content[0].object.get("text").?.string);
}

test "tools/call with no arguments sends {}" {
    var t = TestCtx.init();
    defer t.deinit();
    _ = (try t.run(
        \\{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"tessera_reflect"}}
    )).?;
    try testing.expectEqualStrings("{}", t.fake.last_request);
}

test "unknown tool name is -32602; nothing bus-called" {
    var t = TestCtx.init();
    defer t.deinit();
    const reply = (try t.run(
        \\{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"rm_rf_vault"}}
    )).?;
    const v = try t.parsed(reply);
    try testing.expectEqual(@as(i64, -32602), v.object.get("error").?.object.get("code").?.integer);
    try testing.expectEqual(@as(usize, 0), t.fake.calls);
}

test "bus error surfaces as -32000 with the code; never a result" {
    var t = TestCtx.init();
    defer t.deinit();
    t.fake.reply = .{ .err = "function_not_found" };
    const reply = (try t.run(
        \\{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"tessera_undo","arguments":{}}}
    )).?;
    const v = try t.parsed(reply);
    try testing.expect(v.object.get("result") == null);
    const e = v.object.get("error").?.object;
    try testing.expectEqual(@as(i64, -32000), e.get("code").?.integer);
    try testing.expectEqualStrings("function_not_found", e.get("message").?.string);

    // Shutdown is a bus error too.
    t.fake.fail_shutdown = true;
    const reply2 = (try t.run(
        \\{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"tessera_undo"}}
    )).?;
    const v2 = try t.parsed(reply2);
    try testing.expectEqual(@as(i64, -32000), v2.object.get("error").?.object.get("code").?.integer);
}

test "parse error -32700, bad request -32600, unknown method -32601, ids preserved" {
    var t = TestCtx.init();
    defer t.deinit();

    const bad_json = (try t.run("{nope")).?;
    var v = try t.parsed(bad_json);
    try testing.expectEqual(@as(i64, -32700), v.object.get("error").?.object.get("code").?.integer);
    try testing.expect(v.object.get("id").? == .null);

    const not_object = (try t.run("[1,2]")).?;
    v = try t.parsed(not_object);
    try testing.expectEqual(@as(i64, -32600), v.object.get("error").?.object.get("code").?.integer);

    const no_method = (try t.run(
        \\{"jsonrpc":"2.0","id":"abc"}
    )).?;
    v = try t.parsed(no_method);
    try testing.expectEqual(@as(i64, -32600), v.object.get("error").?.object.get("code").?.integer);
    try testing.expectEqualStrings("abc", v.object.get("id").?.string);

    const unknown = (try t.run(
        \\{"jsonrpc":"2.0","id":9,"method":"resources/list"}
    )).?;
    v = try t.parsed(unknown);
    try testing.expectEqual(@as(i64, -32601), v.object.get("error").?.object.get("code").?.integer);
    try testing.expectEqual(@as(i64, 9), v.object.get("id").?.integer);
}

test "no leaks" {
    // Every test runs under an arena over std.testing.allocator; a leak in
    // handle() would trip any of them. This block exercises the longest path
    // once more end-to-end.
    var t = TestCtx.init();
    defer t.deinit();
    _ = try t.run(
        \\{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"tessera_capture","arguments":{"input":"x","date":"2026-07-09 12:00"}}}
    );
    try testing.expectEqualStrings("zygos::tessera::capture", t.fake.last_function);
}
