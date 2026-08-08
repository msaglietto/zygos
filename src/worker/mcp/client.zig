//! MCP client (stdio framing, JSON-RPC 2.0): plugs an external MCP server's
//! tools onto the bus as `zygos::mcp::<server>::<tool>` functions — the
//! inverse of gateway.zig. Pure layer over an injected Transport vtable
//! (tests run in-process; the child-process transport lives below), so the
//! protocol logic never touches a pipe directly.
//!
//! Fail closed: a malformed reply, a JSON-RPC error, or a dead transport is
//! a structured failure, never a guess. Requests are serialized per client
//! (one stdio pipe = one conversation); replies are matched by id and
//! non-matching lines (server notifications) are skipped.

const std = @import("std");
const jsonx = @import("../jsonx.zig");
const json = std.json;
const actor_mod = @import("../../kernel/actor.zig");
const inproc = @import("../../kernel/inproc.zig");
const sync = @import("../../kernel/sync.zig");

const log = std.log.scoped(.mcp_client);

pub const protocol_version = "2025-06-18";

pub const transport_mod = @import("transport.zig");
pub const TransportError = transport_mod.TransportError;
pub const Transport = transport_mod.Transport;
pub const ChildProcess = transport_mod.ChildProcess;

pub const config_mod = @import("config.zig");
pub const ServerSpec = config_mod.ServerSpec;
pub const McpConfig = config_mod.McpConfig;

pub const ClientError = error{ OutOfMemory, Io, Protocol };

pub const ToolDef = struct {
    // All gpa-owned. Schema/description ride to the provider request —
    // a tool without its input schema gets called with empty arguments by
    // schema-following models (the first real Y5 failure mode).
    name: []u8,
    description: []u8,
    schema_json: []u8, // raw inputSchema JSON; "{}" when the server omits it

    pub fn deinit(self: *ToolDef, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        gpa.free(self.description);
        gpa.free(self.schema_json);
    }
};

pub const CallOut = struct {
    text: []const u8, // arena-owned concatenated text content
    is_error: bool,
};

pub const Client = struct {
    gpa: std.mem.Allocator,
    transport: Transport,
    mutex: sync.Mutex = .{},
    next_id: i64 = 1,

    pub fn init(gpa: std.mem.Allocator, transport: Transport) Client {
        return .{ .gpa = gpa, .transport = transport };
    }

    pub fn deinit(self: *Client) void {
        self.mutex.deinit();
        self.* = undefined;
    }

    /// initialize handshake + initialized notification. Any error reply or
    /// malformed result refuses the server (fail closed).
    pub fn initialize(self: *Client, arena: std.mem.Allocator) ClientError!void {
        const params = "{\"protocolVersion\":\"" ++ protocol_version ++
            "\",\"capabilities\":{},\"clientInfo\":{\"name\":\"zygos\",\"version\":\"0\"}}";
        const reply = try self.request(arena, "initialize", params);
        const result = reply.object.get("result") orelse return error.Protocol;
        if (result != .object) return error.Protocol;
        if (result.object.get("protocolVersion") == null) return error.Protocol;
        try self.notify("notifications/initialized");
    }

    /// tools/list → tool names. Caller frees each def and the slice.
    pub fn listTools(self: *Client, arena: std.mem.Allocator) ClientError![]ToolDef {
        const reply = try self.request(arena, "tools/list", "{}");
        const result = reply.object.get("result") orelse return error.Protocol;
        if (result != .object) return error.Protocol;
        const tools_val = result.object.get("tools") orelse return error.Protocol;
        if (tools_val != .array) return error.Protocol;

        var defs: std.ArrayList(ToolDef) = .empty;
        errdefer {
            for (defs.items) |*d| d.deinit(self.gpa);
            defs.deinit(self.gpa);
        }
        for (tools_val.array.items) |tv| {
            if (tv != .object) return error.Protocol;
            const name = strField(tv.object, "name") orelse return error.Protocol;
            if (name.len == 0) return error.Protocol;
            const name_owned = try self.gpa.dupe(u8, name);
            errdefer self.gpa.free(name_owned);
            const desc_owned = try self.gpa.dupe(u8, strField(tv.object, "description") orelse "");
            errdefer self.gpa.free(desc_owned);
            const schema_owned = blk: {
                const s = tv.object.get("inputSchema") orelse break :blk try self.gpa.dupe(u8, "{}");
                break :blk try rawJsonGpa(self.gpa, s);
            };
            errdefer self.gpa.free(schema_owned);
            try defs.append(self.gpa, .{
                .name = name_owned,
                .description = desc_owned,
                .schema_json = schema_owned,
            });
        }
        return defs.toOwnedSlice(self.gpa);
    }

    /// tools/call with raw JSON arguments. Concatenates the reply's text
    /// content blocks; `isError` rides through untouched.
    pub fn callTool(
        self: *Client,
        arena: std.mem.Allocator,
        name: []const u8,
        arguments_json: []const u8,
    ) ClientError!CallOut {
        const params = try std.fmt.allocPrint(
            arena,
            "{{\"name\":{f},\"arguments\":{s}}}",
            .{ json.fmt(name, .{}), arguments_json },
        );
        const reply = try self.request(arena, "tools/call", params);
        const result = reply.object.get("result") orelse return error.Protocol;
        if (result != .object) return error.Protocol;

        var text: std.ArrayList(u8) = .empty;
        if (result.object.get("content")) |content| {
            if (content != .array) return error.Protocol;
            for (content.array.items) |block| {
                if (block != .object) continue;
                const btype = strField(block.object, "type") orelse continue;
                if (!std.mem.eql(u8, btype, "text")) continue;
                if (strField(block.object, "text")) |t| try text.appendSlice(arena, t);
            }
        }
        const is_error = if (result.object.get("isError")) |v| v == .bool and v.bool else false;
        return .{ .text = try text.toOwnedSlice(arena), .is_error = is_error };
    }

    /// One JSON-RPC round trip under the client mutex. Skips lines that are
    /// not our reply (notifications, stray output); a JSON-RPC error reply
    /// or EOF is a failure.
    fn request(
        self: *Client,
        arena: std.mem.Allocator,
        method: []const u8,
        params_json: []const u8,
    ) ClientError!json.Value {
        self.mutex.lock();
        defer self.mutex.unlock();
        const id = self.next_id;
        self.next_id += 1;

        const line = try std.fmt.allocPrint(
            arena,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":{f},\"params\":{s}}}",
            .{ id, json.fmt(method, .{}), params_json },
        );
        self.transport.writeLine(line) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Io => return error.Io,
        };

        while (true) {
            const raw = self.transport.readLine(self.gpa) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Io => return error.Io,
            } orelse return error.Io; // EOF mid-conversation
            defer self.gpa.free(raw);

            const v = json.parseFromSliceLeaky(json.Value, arena, raw, .{}) catch continue;
            if (v != .object) continue;
            const got_id = v.object.get("id") orelse continue; // notification
            if (got_id != .integer or got_id.integer != id) continue;
            if (v.object.get("error") != null) return error.Protocol;
            return v;
        }
    }

    fn notify(self: *Client, method: []const u8) ClientError!void {
        var buf: [128]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\"}}", .{method}) catch
            return error.Protocol;
        self.transport.writeLine(line) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Io => return error.Io,
        };
    }
};

const strField = jsonx.strField;
const rawJsonGpa = jsonx.rawJson;

// ---------------------------------------------------------------------------
// Bus worker: one registration per server tool
// ---------------------------------------------------------------------------

/// One handshaken server the worker exposes. The caller owns the Client
/// (and its transport) and keeps both alive past `stop()`.
pub const ServerHandle = struct {
    name: []const u8,
    client: *Client,
};

pub const McpClientWorker = struct {
    gpa: std.mem.Allocator,
    worker: *inproc.Worker,
    bindings: std.ArrayList(*Binding) = .empty,

    const Binding = struct {
        client: *Client,
        tool: []u8,
        function_id: []u8,
        model_name: []u8, // "<server>_<tool>" — Anthropic tool-name-safe
        description: []u8,
        schema_json: []u8,
    };

    /// initialize + tools/list every server and register each tool as
    /// `zygos::mcp::<server>::<tool>`. Any server that fails its handshake
    /// fails the boot — a configured-but-broken server is a config error,
    /// not a silent gap (fail closed).
    pub fn start(
        gpa: std.mem.Allocator,
        actor: *actor_mod.Actor,
        registry: *inproc.Registry,
        servers: []const ServerHandle,
    ) !*McpClientWorker {
        const self = try gpa.create(McpClientWorker);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .worker = try inproc.Worker.spawn(gpa, actor, registry, "mcp-client"),
        };
        errdefer self.teardown();

        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();

        for (servers) |srv| {
            const arena = arena_state.allocator();
            try srv.client.initialize(arena);
            const defs = try srv.client.listTools(arena);
            defer {
                for (defs) |*d| @constCast(d).deinit(gpa);
                gpa.free(defs);
            }
            for (defs) |d| {
                const b = try gpa.create(Binding);
                errdefer gpa.destroy(b);
                b.* = .{
                    .client = srv.client,
                    .tool = try gpa.dupe(u8, d.name),
                    .function_id = try std.fmt.allocPrint(gpa, "zygos::mcp::{s}::{s}", .{ srv.name, d.name }),
                    .model_name = try std.fmt.allocPrint(gpa, "{s}_{s}", .{ srv.name, d.name }),
                    .description = try gpa.dupe(u8, d.description),
                    .schema_json = try gpa.dupe(u8, d.schema_json),
                };
                errdefer {
                    gpa.free(b.tool);
                    gpa.free(b.function_id);
                    gpa.free(b.model_name);
                    gpa.free(b.description);
                    gpa.free(b.schema_json);
                }
                try self.bindings.append(gpa, b);
                try self.worker.registerFunction(b.function_id, b, &callHandler);
                log.info("registered {s}", .{b.function_id});
            }
            _ = arena_state.reset(.retain_capacity);
        }
        return self;
    }

    pub fn stop(self: *McpClientWorker) void {
        self.teardown();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    fn teardown(self: *McpClientWorker) void {
        self.worker.stop();
        for (self.bindings.items) |b| {
            self.gpa.free(b.tool);
            self.gpa.free(b.function_id);
            self.gpa.free(b.model_name);
            self.gpa.free(b.description);
            self.gpa.free(b.schema_json);
            self.gpa.destroy(b);
        }
        self.bindings.deinit(self.gpa);
    }

    /// Turn-request `tools` entries for every registered MCP tool, comma-
    /// prefixed so callers can append to a static list. Empty when no tools.
    pub fn toolEntriesJson(self: *McpClientWorker, gpa: std.mem.Allocator) error{OutOfMemory}![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        for (self.bindings.items) |b| {
            const entry = try std.fmt.allocPrint(
                gpa,
                ",{{\"name\":{f},\"function_id\":{f},\"description\":{f},\"input_schema\":{s}}}",
                .{
                    json.fmt(b.model_name, .{}),  json.fmt(b.function_id, .{}),
                    json.fmt(b.description, .{}), b.schema_json,
                },
            );
            defer gpa.free(entry);
            try out.appendSlice(gpa, entry);
        }
        return out.toOwnedSlice(gpa);
    }

    /// Model-facing tool names (for policy tables). Slice is gpa-owned;
    /// names borrow from the worker and live until `stop()`.
    pub fn toolNames(self: *McpClientWorker, gpa: std.mem.Allocator) error{OutOfMemory}![]const []const u8 {
        const names = try gpa.alloc([]const u8, self.bindings.items.len);
        for (self.bindings.items, 0..) |b, i| names[i] = b.model_name;
        return names;
    }

    /// Bus request JSON = MCP tool arguments, verbatim. Failures follow the
    /// web_tools convention: structured `{"error":...}` payloads the model
    /// can read, never a silent drop.
    fn callHandler(ctx: ?*anyopaque, arena: std.mem.Allocator, request_json: []const u8) error{ Failed, OutOfMemory }![]const u8 {
        const b: *Binding = @ptrCast(@alignCast(ctx.?));
        const args = if (std.mem.trim(u8, request_json, " \t\r\n").len == 0) "{}" else request_json;
        const out = b.client.callTool(arena, b.tool, args) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Io => return errorReply(arena, "McpServerUnavailable"),
            error.Protocol => return errorReply(arena, "McpMalformedReply"),
        };
        if (out.is_error) {
            return std.fmt.allocPrint(arena, "{{\"error\":\"McpToolError\",\"detail\":{f}}}", .{
                json.fmt(out.text, .{}),
            });
        }
        // Bus reply payloads must be JSON (inproc frame contract) — the raw
        // MCP text rides as a "content" string, like web_fetch's replies.
        return std.fmt.allocPrint(arena, "{{\"content\":{f}}}", .{json.fmt(out.text, .{})});
    }
};

fn errorReply(arena: std.mem.Allocator, name: []const u8) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(arena, "{{\"error\":{f}}}", .{json.fmt(name, .{})});
}

// ===========================================================================
// Tests — pure layer over a scripted transport
// ===========================================================================

const testing = std.testing;

const init_reply =
    \\{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{},"serverInfo":{"name":"stub","version":"1"}}}
;
const list_reply =
    \\{"jsonrpc":"2.0","id":2,"result":{"tools":[
    \\ {"name":"search","description":"web search","inputSchema":{"type":"object","properties":{"q":{"type":"string"}},"required":["q"]}},
    \\ {"name":"fetch","inputSchema":{}}]}}
;

/// Scripted transport: records written lines, replays scripted reads.
const FakeTransport = struct {
    gpa: std.mem.Allocator,
    script: []const []const u8,
    reads: usize = 0,
    written: std.ArrayList([]u8) = .empty,

    fn deinit(self: *FakeTransport) void {
        for (self.written.items) |w| self.gpa.free(w);
        self.written.deinit(self.gpa);
    }

    fn transport(self: *FakeTransport) Transport {
        return .{ .ctx = self, .writeLineFn = &writeLine, .readLineFn = &readLine };
    }

    fn writeLine(ctx: *anyopaque, line: []const u8) TransportError!void {
        const self: *FakeTransport = @ptrCast(@alignCast(ctx));
        try self.written.append(self.gpa, try self.gpa.dupe(u8, line));
    }

    fn readLine(ctx: *anyopaque, gpa: std.mem.Allocator) TransportError!?[]u8 {
        const self: *FakeTransport = @ptrCast(@alignCast(ctx));
        if (self.reads >= self.script.len) return null; // EOF
        const line = self.script[self.reads];
        self.reads += 1;
        return try gpa.dupe(u8, line);
    }
};

test "initialize handshakes then sends the initialized notification" {
    var ft: FakeTransport = .{ .gpa = testing.allocator, .script = &.{init_reply} };
    defer ft.deinit();
    var client = Client.init(testing.allocator, ft.transport());
    defer client.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try client.initialize(arena_state.allocator());

    try testing.expectEqual(@as(usize, 2), ft.written.items.len);
    try testing.expect(std.mem.indexOf(u8, ft.written.items[0], "\"method\":\"initialize\"") != null);
    try testing.expect(std.mem.indexOf(u8, ft.written.items[0], protocol_version) != null);
    try testing.expect(std.mem.indexOf(u8, ft.written.items[1], "notifications/initialized") != null);
}

test "initialize refuses a JSON-RPC error reply (fail closed)" {
    var ft: FakeTransport = .{ .gpa = testing.allocator, .script = &.{
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32600,"message":"nope"}}
    } };
    defer ft.deinit();
    var client = Client.init(testing.allocator, ft.transport());
    defer client.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(error.Protocol, client.initialize(arena_state.allocator()));
}

test "listTools parses names; notifications interleaved before the reply are skipped" {
    var ft: FakeTransport = .{ .gpa = testing.allocator, .script = &.{
        init_reply,
        \\{"jsonrpc":"2.0","method":"notifications/progress","params":{}}
        ,
        list_reply,
    } };
    defer ft.deinit();
    var client = Client.init(testing.allocator, ft.transport());
    defer client.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try client.initialize(arena_state.allocator());
    const defs = try client.listTools(arena_state.allocator());
    defer {
        for (defs) |*d| @constCast(d).deinit(testing.allocator);
        testing.allocator.free(defs);
    }
    try testing.expectEqual(@as(usize, 2), defs.len);
    try testing.expectEqualStrings("search", defs[0].name);
    try testing.expectEqualStrings("web search", defs[0].description);
    try testing.expect(std.mem.indexOf(u8, defs[0].schema_json, "\"required\":[\"q\"]") != null);
    try testing.expectEqualStrings("fetch", defs[1].name);
    try testing.expectEqualStrings("", defs[1].description);
    try testing.expectEqualStrings("{}", defs[1].schema_json);
}

test "callTool concatenates text content and carries isError through" {
    var ft: FakeTransport = .{ .gpa = testing.allocator, .script = &.{
        \\{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"hello "},{"type":"text","text":"world"}],"isError":false}}
        ,
        \\{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"boom"}],"isError":true}}
    } };
    defer ft.deinit();
    var client = Client.init(testing.allocator, ft.transport());
    defer client.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const ok = try client.callTool(arena, "search", "{\"q\":\"zig\"}");
    try testing.expectEqualStrings("hello world", ok.text);
    try testing.expect(!ok.is_error);
    try testing.expect(std.mem.indexOf(u8, ft.written.items[0], "\"name\":\"search\"") != null);
    try testing.expect(std.mem.indexOf(u8, ft.written.items[0], "\"q\":\"zig\"") != null);

    const bad = try client.callTool(arena, "search", "{}");
    try testing.expectEqualStrings("boom", bad.text);
    try testing.expect(bad.is_error);
}

// -- Bus worker over a scripted transport -------------------------------------

const call_reply =
    \\{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"found it"}],"isError":false}}
;

const WorkerHarness = struct {
    registry: inproc.Registry,
    actor: actor_mod.Actor,
    kernel: std.Thread,
    caller: *inproc.Worker,

    fn init(gpa: std.mem.Allocator) !*WorkerHarness {
        const self = try gpa.create(WorkerHarness);
        self.registry = inproc.Registry.init(gpa, null);
        self.actor = try actor_mod.Actor.init(gpa, .{}, self.registry.outbound());
        self.kernel = try std.Thread.spawn(.{}, actor_mod.Actor.run, .{&self.actor});
        self.caller = try inproc.Worker.spawn(gpa, &self.actor, &self.registry, "test-caller");
        return self;
    }

    fn deinit(self: *WorkerHarness) void {
        const gpa = self.actor.gpa;
        self.caller.stop();
        self.actor.post(.shutdown);
        self.kernel.join();
        self.actor.deinit();
        self.registry.deinit();
        gpa.destroy(self);
    }
};

test "worker registers zygos::mcp::<server>::<tool> and bridges tools/call over the bus" {
    var h = try WorkerHarness.init(testing.allocator);
    defer h.deinit();

    var ft: FakeTransport = .{ .gpa = testing.allocator, .script = &.{ init_reply, list_reply, call_reply } };
    defer ft.deinit();
    var client = Client.init(testing.allocator, ft.transport());
    defer client.deinit();

    const mcp = try McpClientWorker.start(testing.allocator, &h.actor, &h.registry, &.{
        .{ .name = "stub", .client = &client },
    });
    defer mcp.stop();

    const res = try h.caller.call("zygos::mcp::stub::search", "{\"q\":\"zig\"}");
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try testing.expectEqualStrings("{\"content\":\"found it\"}", res.ok);

    // The MCP wire saw the bus request as tools/call arguments.
    const wire = ft.written.items[ft.written.items.len - 1];
    try testing.expect(std.mem.indexOf(u8, wire, "\"method\":\"tools/call\"") != null);
    try testing.expect(std.mem.indexOf(u8, wire, "\"name\":\"search\"") != null);
    try testing.expect(std.mem.indexOf(u8, wire, "\"q\":\"zig\"") != null);

    // Turn-request entries carry the schema + description to the provider —
    // schema-less tools get called with empty arguments by strict models.
    const entries = try mcp.toolEntriesJson(testing.allocator);
    defer testing.allocator.free(entries);
    try testing.expect(std.mem.indexOf(u8, entries, "\"name\":\"stub_search\"") != null);
    try testing.expect(std.mem.indexOf(u8, entries, "\"description\":\"web search\"") != null);
    try testing.expect(std.mem.indexOf(u8, entries, "\"input_schema\":{") != null);
    try testing.expect(std.mem.indexOf(u8, entries, "\"required\":[\"q\"]") != null);
}

test "worker maps MCP tool isError and dead transports to structured error payloads" {
    var h = try WorkerHarness.init(testing.allocator);
    defer h.deinit();

    var ft: FakeTransport = .{ .gpa = testing.allocator, .script = &.{
        init_reply,
        list_reply,
        \\{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"no such host"}],"isError":true}}
    } };
    defer ft.deinit();
    var client = Client.init(testing.allocator, ft.transport());
    defer client.deinit();

    const mcp = try McpClientWorker.start(testing.allocator, &h.actor, &h.registry, &.{
        .{ .name = "stub", .client = &client },
    });
    defer mcp.stop();

    const bad = try h.caller.call("zygos::mcp::stub::fetch", "{}");
    defer bad.deinit(testing.allocator);
    try testing.expect(bad == .ok);
    try testing.expect(std.mem.indexOf(u8, bad.ok, "McpToolError") != null);
    try testing.expect(std.mem.indexOf(u8, bad.ok, "no such host") != null);

    // Script exhausted = EOF = server gone: structured, not a crash.
    const dead = try h.caller.call("zygos::mcp::stub::fetch", "{}");
    defer dead.deinit(testing.allocator);
    try testing.expect(dead == .ok);
    try testing.expect(std.mem.indexOf(u8, dead.ok, "McpServerUnavailable") != null);
}

test "worker start refuses when a server fails its handshake (fail closed)" {
    var h = try WorkerHarness.init(testing.allocator);
    defer h.deinit();

    var ft: FakeTransport = .{ .gpa = testing.allocator, .script = &.{} }; // EOF immediately
    defer ft.deinit();
    var client = Client.init(testing.allocator, ft.transport());
    defer client.deinit();

    try testing.expectError(error.Io, McpClientWorker.start(testing.allocator, &h.actor, &h.registry, &.{
        .{ .name = "stub", .client = &client },
    }));
}

// -- Child-process transport (a real subprocess, like tessera_undo's real git) --

test "child-process transport handshakes with a real subprocess over pipes" {
    const stub =
        "while IFS= read -r line; do case \"$line\" in " ++
        "*\\\"initialize\\\"*) printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-06-18\"}}';; " ++
        "*tools/list*) printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"echo\"}]}}';; " ++
        "esac; done";
    const child = try ChildProcess.spawn(testing.allocator, &.{ "sh", "-c", stub });
    defer child.stop();

    var client = Client.init(testing.allocator, child.transport());
    defer client.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    try client.initialize(arena_state.allocator());
    const defs = try client.listTools(arena_state.allocator());
    defer {
        for (defs) |*d| @constCast(d).deinit(testing.allocator);
        testing.allocator.free(defs);
    }
    try testing.expectEqual(@as(usize, 1), defs.len);
    try testing.expectEqualStrings("echo", defs[0].name);
}

test "spawn of a nonexistent binary yields Io on first use, and stop reaps the child" {
    const child = try ChildProcess.spawn(testing.allocator, &.{"/nonexistent-zygos-mcp-server"});
    defer child.stop();
    var client = Client.init(testing.allocator, child.transport());
    defer client.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(error.Io, client.initialize(arena_state.allocator()));
}

test "callTool on a closed transport is Io, malformed result is Protocol (fail closed)" {
    var ft: FakeTransport = .{ .gpa = testing.allocator, .script = &.{
        \\{"jsonrpc":"2.0","id":1,"result":{"content":"not-an-array"}}
    } };
    defer ft.deinit();
    var client = Client.init(testing.allocator, ft.transport());
    defer client.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectError(error.Protocol, client.callTool(arena, "t", "{}"));
    try testing.expectError(error.Io, client.callTool(arena, "t", "{}")); // script exhausted = EOF
}
