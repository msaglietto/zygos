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
const c = std.c;
const json = std.json;
const actor_mod = @import("../../kernel/actor.zig");
const inproc = @import("../../kernel/inproc.zig");
const sync = @import("../../kernel/sync.zig");

const log = std.log.scoped(.mcp_client);

pub const protocol_version = "2025-06-18";

pub const TransportError = error{ Io, OutOfMemory };

/// Line-oriented duplex channel to one MCP server. `readLine` returns null
/// on EOF; returned slices are gpa-owned by the caller.
pub const Transport = struct {
    ctx: *anyopaque,
    writeLineFn: *const fn (ctx: *anyopaque, line: []const u8) TransportError!void,
    readLineFn: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator) TransportError!?[]u8,

    fn writeLine(self: Transport, line: []const u8) TransportError!void {
        return self.writeLineFn(self.ctx, line);
    }
    fn readLine(self: Transport, gpa: std.mem.Allocator) TransportError!?[]u8 {
        return self.readLineFn(self.ctx, gpa);
    }
};

pub const ClientError = error{ OutOfMemory, Io, Protocol };

pub const ToolDef = struct {
    name: []u8, // gpa-owned

    pub fn deinit(self: *ToolDef, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
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
            try defs.append(self.gpa, .{ .name = try self.gpa.dupe(u8, name) });
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

fn strField(obj: json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

// ---------------------------------------------------------------------------
// Config: `.mcp_servers` in zygos.zon (operator-owned, like routes)
// ---------------------------------------------------------------------------

pub const ServerSpec = struct {
    name: []const u8,
    argv: []const []const u8,
};

const McpConfigData = struct {
    mcp_servers: []const ServerSpec = &.{},
};

/// Parsed `.mcp_servers` table. Reads the same zygos.zon as the router —
/// unknown fields are ignored on both sides so the two schemas coexist.
pub const McpConfig = struct {
    gpa: std.mem.Allocator,
    data: McpConfigData,

    pub fn parse(gpa: std.mem.Allocator, zon_text: [:0]const u8) error{ OutOfMemory, ParseZon }!McpConfig {
        return .{
            .gpa = gpa,
            .data = try std.zon.parse.fromSliceAlloc(McpConfigData, gpa, zon_text, null, .{
                .ignore_unknown_fields = true,
            }),
        };
    }

    pub fn deinit(self: *McpConfig) void {
        std.zon.parse.free(self.gpa, self.data);
        self.* = undefined;
    }

    pub fn servers(self: *const McpConfig) []const ServerSpec {
        return self.data.mcp_servers;
    }
};

// ---------------------------------------------------------------------------
// Child-process transport (fork/exec + pipes; libc like tools_ops' popen)
// ---------------------------------------------------------------------------

extern "c" fn fork() c.pid_t;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn dup2(old_fd: c_int, new_fd: c_int) c_int;
extern "c" fn pipe(fds: *[2]c_int) c_int;
extern "c" fn waitpid(pid: c.pid_t, status: ?*c_int, options: c_int) c.pid_t;
extern "c" fn kill(pid: c.pid_t, sig: c_int) c_int;
extern "c" fn fdopen(fd: c_int, mode: [*:0]const u8) ?*c.FILE;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn _exit(status: c_int) noreturn;
extern "c" fn fflush(stream: *c.FILE) c_int;
extern "c" fn fgets(buf: [*]u8, size: c_int, stream: *c.FILE) ?[*:0]u8;

const SIGTERM: c_int = @intFromEnum(c.SIG.TERM);

pub const ChildProcess = struct {
    gpa: std.mem.Allocator,
    pid: c.pid_t,
    to_child: *c.FILE, // requests out
    from_child: *c.FILE, // replies in
    write_mutex: sync.Mutex = .{},

    /// Spawn `argv` with its stdin/stdout piped here; stderr passes through
    /// to ours (server logs stay visible).
    pub fn spawn(gpa: std.mem.Allocator, argv: []const []const u8) error{ OutOfMemory, SpawnFailed }!*ChildProcess {
        std.debug.assert(argv.len > 0);
        var in_pipe: [2]c_int = undefined; // us → child stdin
        var out_pipe: [2]c_int = undefined; // child stdout → us
        if (pipe(&in_pipe) != 0) return error.SpawnFailed;
        if (pipe(&out_pipe) != 0) {
            _ = close(in_pipe[0]);
            _ = close(in_pipe[1]);
            return error.SpawnFailed;
        }

        const argz = try gpa.alloc(?[*:0]const u8, argv.len + 1);
        defer gpa.free(argz);
        var owned: usize = 0;
        defer for (argz[0..owned]) |a| gpa.free(std.mem.span(a.?));
        for (argv, 0..) |a, i| {
            argz[i] = (try gpa.dupeZ(u8, a)).ptr;
            owned += 1;
        }
        argz[argv.len] = null;

        const pid = fork();
        if (pid < 0) {
            _ = close(in_pipe[0]);
            _ = close(in_pipe[1]);
            _ = close(out_pipe[0]);
            _ = close(out_pipe[1]);
            return error.SpawnFailed;
        }
        if (pid == 0) {
            // Child: only async-signal-safe calls until exec.
            _ = dup2(in_pipe[0], 0);
            _ = dup2(out_pipe[1], 1);
            _ = close(in_pipe[0]);
            _ = close(in_pipe[1]);
            _ = close(out_pipe[0]);
            _ = close(out_pipe[1]);
            _ = execvp(argz[0].?, @ptrCast(argz.ptr));
            _exit(127);
        }
        _ = close(in_pipe[0]);
        _ = close(out_pipe[1]);

        const to_child = fdopen(in_pipe[1], "w") orelse {
            _ = close(in_pipe[1]);
            _ = close(out_pipe[0]);
            _ = kill(pid, SIGTERM);
            _ = waitpid(pid, null, 0);
            return error.SpawnFailed;
        };
        const from_child = fdopen(out_pipe[0], "r") orelse {
            _ = c.fclose(to_child);
            _ = close(out_pipe[0]);
            _ = kill(pid, SIGTERM);
            _ = waitpid(pid, null, 0);
            return error.SpawnFailed;
        };

        const self = try gpa.create(ChildProcess);
        self.* = .{ .gpa = gpa, .pid = pid, .to_child = to_child, .from_child = from_child };
        return self;
    }

    /// Close the pipes (EOF lets well-behaved servers exit), then TERM +
    /// reap — never leaves a zombie.
    pub fn stop(self: *ChildProcess) void {
        _ = c.fclose(self.to_child);
        _ = c.fclose(self.from_child);
        _ = kill(self.pid, SIGTERM);
        _ = waitpid(self.pid, null, 0);
        self.write_mutex.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    pub fn transport(self: *ChildProcess) Transport {
        return .{ .ctx = self, .writeLineFn = &writeLine, .readLineFn = &readLine };
    }

    fn writeLine(ctx: *anyopaque, line: []const u8) TransportError!void {
        const self: *ChildProcess = @ptrCast(@alignCast(ctx));
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        if (c.fwrite(line.ptr, 1, line.len, self.to_child) != line.len) return error.Io;
        if (c.fwrite("\n", 1, 1, self.to_child) != 1) return error.Io;
        if (fflush(self.to_child) != 0) return error.Io;
    }

    fn readLine(ctx: *anyopaque, gpa: std.mem.Allocator) TransportError!?[]u8 {
        const self: *ChildProcess = @ptrCast(@alignCast(ctx));
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(gpa);
        var chunk: [1024]u8 = undefined;
        while (true) {
            if (fgets(&chunk, chunk.len, self.from_child) == null) {
                if (buf.items.len == 0) {
                    buf.deinit(gpa);
                    return null; // clean EOF
                }
                break; // EOF mid-line: hand over what we have
            }
            const got = std.mem.sliceTo(&chunk, 0);
            try buf.appendSlice(gpa, got);
            if (got.len > 0 and got[got.len - 1] == '\n') {
                _ = buf.pop();
                break;
            }
        }
        return try buf.toOwnedSlice(gpa);
    }
};

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
                };
                errdefer {
                    gpa.free(b.tool);
                    gpa.free(b.function_id);
                    gpa.free(b.model_name);
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
            const entry = try std.fmt.allocPrint(gpa, ",{{\"name\":{f},\"function_id\":{f}}}", .{
                json.fmt(b.model_name, .{}), json.fmt(b.function_id, .{}),
            });
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
    \\{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"search","inputSchema":{}},{"name":"fetch","inputSchema":{}}]}}
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
    try testing.expectEqualStrings("fetch", defs[1].name);
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

// -- Config --------------------------------------------------------------------

test "McpConfig parses .mcp_servers and coexists with router fields; absent = empty" {
    const zon: [:0]const u8 =
        \\.{ .default = .{}, .routes = .{},
        \\   .mcp_servers = .{
        \\     .{ .name = "tavily", .argv = .{ "npx", "-y", "tavily-mcp" } },
        \\   } }
    ;
    var cfg = try McpConfig.parse(testing.allocator, zon);
    defer cfg.deinit();
    try testing.expectEqual(@as(usize, 1), cfg.servers().len);
    try testing.expectEqualStrings("tavily", cfg.servers()[0].name);
    try testing.expectEqual(@as(usize, 3), cfg.servers()[0].argv.len);

    var empty = try McpConfig.parse(testing.allocator, ".{ .routes = .{} }");
    defer empty.deinit();
    try testing.expectEqual(@as(usize, 0), empty.servers().len);
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
