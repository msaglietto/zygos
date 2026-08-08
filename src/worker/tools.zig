//! Agent-tools worker (T5) — bus glue over tools_ops.zig's pure operations.
//! Registers `zygos::tools::{bash,read_file,write_file}`, all confined to
//! the workspace root. Operational failures reply as structured payloads
//! (`{"error":"PathEscapesWorkspace"}`) so the model sees them as tool
//! results; only malformed requests fail the bus call.

const std = @import("std");
const jsonx = @import("jsonx.zig");
const json = std.json;
const actor_mod = @import("../kernel/actor.zig");
const inproc = @import("../kernel/inproc.zig");
const ops = @import("tools_ops.zig");

pub const ToolsWorker = struct {
    gpa: std.mem.Allocator,
    worker: *inproc.Worker,
    root: []const u8, // owned
    ws: ops.Workspace,

    pub fn start(
        gpa: std.mem.Allocator,
        actor: *actor_mod.Actor,
        registry: *inproc.Registry,
        workspace_root: []const u8,
    ) !*ToolsWorker {
        const self = try gpa.create(ToolsWorker);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .worker = try inproc.Worker.spawn(gpa, actor, registry, "agent-tools"),
            .root = try gpa.dupe(u8, workspace_root),
            .ws = undefined,
        };
        self.ws = ops.Workspace.init(self.root);
        errdefer self.worker.stop();
        try self.worker.registerFunction("zygos::tools::bash", self, &bashHandler);
        try self.worker.registerFunction("zygos::tools::read_file", self, &readHandler);
        try self.worker.registerFunction("zygos::tools::write_file", self, &writeHandler);
        return self;
    }

    pub fn stop(self: *ToolsWorker) void {
        self.worker.stop();
        self.gpa.free(self.root);
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    fn bashHandler(ctx: ?*anyopaque, arena: std.mem.Allocator, request_json: []const u8) error{ Failed, OutOfMemory }![]const u8 {
        const self: *ToolsWorker = @ptrCast(@alignCast(ctx.?));
        const obj = try parseObject(arena, request_json);
        const command = strField(obj, "command") orelse return error.Failed;

        const result = ops.bash(self.gpa, self.ws, command) catch |err| return opError(arena, err);
        defer self.gpa.free(result.output);
        return std.fmt.allocPrint(arena, "{{\"exit_code\":{d},\"output\":{f}}}", .{
            result.exit_code,
            json.fmt(result.output, .{}),
        });
    }

    fn readHandler(ctx: ?*anyopaque, arena: std.mem.Allocator, request_json: []const u8) error{ Failed, OutOfMemory }![]const u8 {
        const self: *ToolsWorker = @ptrCast(@alignCast(ctx.?));
        const obj = try parseObject(arena, request_json);
        const path = strField(obj, "path") orelse return error.Failed;

        const content = ops.readFile(self.gpa, self.ws, path) catch |err| return opError(arena, err);
        defer self.gpa.free(content);
        return std.fmt.allocPrint(arena, "{{\"content\":{f}}}", .{json.fmt(content, .{})});
    }

    fn writeHandler(ctx: ?*anyopaque, arena: std.mem.Allocator, request_json: []const u8) error{ Failed, OutOfMemory }![]const u8 {
        const self: *ToolsWorker = @ptrCast(@alignCast(ctx.?));
        const obj = try parseObject(arena, request_json);
        const path = strField(obj, "path") orelse return error.Failed;
        const content = strField(obj, "content") orelse return error.Failed;

        ops.writeFile(self.gpa, self.ws, path, content) catch |err| return opError(arena, err);
        return arena.dupe(u8, "{\"ok\":true}");
    }
};

fn opError(arena: std.mem.Allocator, err: ops.OpsError) error{ Failed, OutOfMemory }![]const u8 {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return std.fmt.allocPrint(arena, "{{\"error\":\"{t}\"}}", .{err});
}

fn parseObject(arena: std.mem.Allocator, request_json: []const u8) error{Failed}!json.ObjectMap {
    const root = json.parseFromSliceLeaky(json.Value, arena, request_json, .{}) catch
        return error.Failed;
    return if (root == .object) root.object else error.Failed;
}

const strField = jsonx.strField;

// ===========================================================================
// Tests — bus-level round-trips over a real kernel; the op edge cases live
// in tools_ops.zig.
// ===========================================================================

const testing = std.testing;

// libc realpath (io-free); std's Dir.realPath needs an Io instance.
extern "c" fn realpath(path: [*:0]const u8, resolved: [*]u8) ?[*:0]u8;

const Harness = struct {
    registry: inproc.Registry,
    actor: actor_mod.Actor,
    kernel: std.Thread,
    tools: *ToolsWorker,
    caller: *inproc.Worker,
    tmp: std.testing.TmpDir,
    root_buf: [std.fs.max_path_bytes]u8,

    fn init(gpa: std.mem.Allocator) !*Harness {
        const self = try gpa.create(Harness);
        self.tmp = std.testing.tmpDir(.{});
        var rel_buf: [std.fs.max_path_bytes]u8 = undefined;
        const rel = try std.fmt.bufPrintZ(&rel_buf, ".zig-cache/tmp/{s}", .{self.tmp.sub_path});
        const resolved = realpath(rel, &self.root_buf) orelse return error.RealpathFailed;
        const root = std.mem.span(resolved);
        self.registry = inproc.Registry.init(gpa, null);
        self.actor = try actor_mod.Actor.init(gpa, .{}, self.registry.outbound());
        self.kernel = try std.Thread.spawn(.{}, actor_mod.Actor.run, .{&self.actor});
        self.tools = try ToolsWorker.start(gpa, &self.actor, &self.registry, root);
        self.caller = try inproc.Worker.spawn(gpa, &self.actor, &self.registry, "caller");
        return self;
    }

    fn deinit(self: *Harness) void {
        const gpa = self.actor.gpa;
        self.caller.stop();
        self.tools.stop();
        self.actor.post(.shutdown);
        self.kernel.join();
        self.actor.deinit();
        self.registry.deinit();
        self.tmp.cleanup();
        gpa.destroy(self);
    }
};

test "bash tool runs over the bus and reports exit code and output" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const res = try h.caller.call("zygos::tools::bash", "{\"command\":\"echo bus-hi\"}");
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);

    var p = try json.parseFromSlice(json.Value, testing.allocator, res.ok, .{});
    defer p.deinit();
    try testing.expectEqual(@as(i64, 0), p.value.object.get("exit_code").?.integer);
    try testing.expectEqualStrings("bus-hi\n", p.value.object.get("output").?.string);
}

test "write then read round-trips over the bus; escapes are structured errors" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const w = try h.caller.call("zygos::tools::write_file",
        \\{"path":"notes/a.txt","content":"hello tools"}
    );
    defer w.deinit(testing.allocator);
    try testing.expect(w == .ok);

    const r = try h.caller.call("zygos::tools::read_file", "{\"path\":\"notes/a.txt\"}");
    defer r.deinit(testing.allocator);
    var p = try json.parseFromSlice(json.Value, testing.allocator, r.ok, .{});
    defer p.deinit();
    try testing.expectEqualStrings("hello tools", p.value.object.get("content").?.string);

    const esc = try h.caller.call("zygos::tools::read_file", "{\"path\":\"../../etc/passwd\"}");
    defer esc.deinit(testing.allocator);
    var pe = try json.parseFromSlice(json.Value, testing.allocator, esc.ok, .{});
    defer pe.deinit();
    try testing.expectEqualStrings("PathEscapesWorkspace", pe.value.object.get("error").?.string);
}
