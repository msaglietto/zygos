//! Approval/question worker (U2, docs/specs/approval.md). Owns the
//! human-in-the-loop seam: `zygos::approvals::request` parks its invocation
//! (handlers run on their own threads — parking is safe) until a
//! `zygos::approvals::resolve` answers it, the timeout fires, or the worker
//! stops. Every non-affirmative outcome is a denial — fail closed.

const std = @import("std");
const jsonx = @import("jsonx.zig");
const json = std.json;
const actor_mod = @import("../kernel/actor.zig");
const inproc = @import("../kernel/inproc.zig");
const sync = @import("../kernel/sync.zig");

pub const Mode = union(enum) {
    /// Park until resolved; `timeout_ms` bounds the park (deny on expiry).
    manual: struct { timeout_ms: ?u64 = null },
    auto_approve,
    auto_deny,
};

const Pending = struct {
    id: []const u8, // owned by the parked request handler's frame
    tool: []const u8,
    reason: []const u8,
    event: sync.ResetEvent = .{},
    approved: bool = false,
    /// True only when a resolve call answered this request; a timeout or
    /// worker-stop wake leaves it false, so callers can tell "denied by a
    /// human" from "denied because nobody answered".
    resolved: bool = false,
};

pub const ApprovalWorker = struct {
    gpa: std.mem.Allocator,
    worker: *inproc.Worker,
    mode: Mode,
    mutex: sync.Mutex = .{},
    next_id: usize = 1,
    pending: std.StringHashMap(*Pending),

    pub fn start(
        gpa: std.mem.Allocator,
        actor: *actor_mod.Actor,
        registry: *inproc.Registry,
        mode: Mode,
    ) !*ApprovalWorker {
        const self = try gpa.create(ApprovalWorker);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .worker = try inproc.Worker.spawn(gpa, actor, registry, "approval"),
            .mode = mode,
            .pending = std.StringHashMap(*Pending).init(gpa),
        };
        errdefer self.worker.stop();
        try self.worker.registerFunction("zygos::approvals::request", self, &requestHandler);
        try self.worker.registerFunction("zygos::approvals::resolve", self, &resolveHandler);
        try self.worker.registerFunction("zygos::approvals::pending", self, &pendingHandler);
        return self;
    }

    pub fn stop(self: *ApprovalWorker) void {
        // Wake every parked request as denied; each handler removes its own
        // entry before worker.stop() finishes joining handler threads.
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            var it = self.pending.valueIterator();
            while (it.next()) |p| p.*.event.set();
        }
        self.worker.stop();
        std.debug.assert(self.pending.count() == 0);
        self.pending.deinit();
        self.mutex.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    fn requestHandler(ctx: ?*anyopaque, arena: std.mem.Allocator, request_json: []const u8) error{ Failed, OutOfMemory }![]const u8 {
        const self: *ApprovalWorker = @ptrCast(@alignCast(ctx.?));

        switch (self.mode) {
            .auto_approve => return arena.dupe(u8, "{\"approved\":true,\"id\":\"auto\",\"resolved\":true}"),
            .auto_deny => return arena.dupe(u8, "{\"approved\":false,\"id\":\"auto\",\"resolved\":true}"),
            .manual => {},
        }
        const timeout_ms = self.mode.manual.timeout_ms;

        var tool: []const u8 = "";
        var reason: []const u8 = "";
        if (json.parseFromSliceLeaky(json.Value, arena, request_json, .{})) |root| {
            if (root == .object) {
                tool = strField(root.object, "tool") orelse "";
                reason = strField(root.object, "reason") orelse "";
            }
        } else |_| {}

        // Park. The Pending lives on this handler thread's frame; gpa-owned
        // strings because resolve/pending readers outlive the arena? No —
        // they run while we're parked, the frame is alive. Arena is fine for
        // tool/reason; the id must be a stable map key, dupe it on gpa.
        var entry: Pending = .{ .id = undefined, .tool = tool, .reason = reason };
        var id_buf: [24]u8 = undefined;
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            const id_text = std.fmt.bufPrint(&id_buf, "a-{d}", .{self.next_id}) catch unreachable;
            self.next_id += 1;
            entry.id = try self.gpa.dupe(u8, id_text);
            errdefer self.gpa.free(@constCast(entry.id));
            try self.pending.put(entry.id, &entry);
        }
        defer self.gpa.free(@constCast(entry.id));
        defer entry.event.deinit();

        const in_time = if (timeout_ms) |ms| entry.event.timedWait(ms) else blk: {
            entry.event.wait();
            break :blk true;
        };
        const outcome = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            _ = self.pending.remove(entry.id);
            break :blk .{ in_time and entry.approved, in_time and entry.resolved };
        };

        return std.fmt.allocPrint(
            arena,
            "{{\"approved\":{},\"id\":\"{s}\",\"resolved\":{}}}",
            .{ outcome[0], entry.id, outcome[1] },
        );
    }

    fn resolveHandler(ctx: ?*anyopaque, arena: std.mem.Allocator, request_json: []const u8) error{ Failed, OutOfMemory }![]const u8 {
        const self: *ApprovalWorker = @ptrCast(@alignCast(ctx.?));

        const root = json.parseFromSliceLeaky(json.Value, arena, request_json, .{}) catch
            return arena.dupe(u8, "{\"resolved\":false}");
        if (root != .object) return arena.dupe(u8, "{\"resolved\":false}");
        const id = strField(root.object, "id") orelse
            return arena.dupe(u8, "{\"resolved\":false}");
        const approved = if (root.object.get("approved")) |v| v == .bool and v.bool else false;

        self.mutex.lock();
        defer self.mutex.unlock();
        const p = self.pending.get(id) orelse
            return arena.dupe(u8, "{\"resolved\":false}");
        p.approved = approved;
        p.resolved = true;
        p.event.set();
        return arena.dupe(u8, "{\"resolved\":true}");
    }

    fn pendingHandler(ctx: ?*anyopaque, arena: std.mem.Allocator, request_json: []const u8) error{ Failed, OutOfMemory }![]const u8 {
        const self: *ApprovalWorker = @ptrCast(@alignCast(ctx.?));
        _ = request_json;

        var out: std.Io.Writer.Allocating = .init(arena);
        errdefer out.deinit();
        var ws: json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .minified } };

        self.mutex.lock();
        defer self.mutex.unlock();
        ws.beginObject() catch return error.OutOfMemory;
        ws.objectField("pending") catch return error.OutOfMemory;
        ws.beginArray() catch return error.OutOfMemory;
        var it = self.pending.valueIterator();
        while (it.next()) |p| {
            ws.beginObject() catch return error.OutOfMemory;
            ws.objectField("id") catch return error.OutOfMemory;
            ws.write(p.*.id) catch return error.OutOfMemory;
            ws.objectField("tool") catch return error.OutOfMemory;
            ws.write(p.*.tool) catch return error.OutOfMemory;
            ws.objectField("reason") catch return error.OutOfMemory;
            ws.write(p.*.reason) catch return error.OutOfMemory;
            ws.endObject() catch return error.OutOfMemory;
        }
        ws.endArray() catch return error.OutOfMemory;
        ws.endObject() catch return error.OutOfMemory;
        return out.toOwnedSlice() catch return error.OutOfMemory;
    }
};

const strField = jsonx.strField;

// ===========================================================================
// Tests (docs/specs/approval.md contract, RED first)
// ===========================================================================

const testing = std.testing;

const Harness = struct {
    registry: inproc.Registry,
    actor: actor_mod.Actor,
    kernel: std.Thread,
    caller: *inproc.Worker,

    fn init(gpa: std.mem.Allocator) !*Harness {
        const self = try gpa.create(Harness);
        self.registry = inproc.Registry.init(gpa, null);
        self.actor = try actor_mod.Actor.init(gpa, .{}, self.registry.outbound());
        self.kernel = try std.Thread.spawn(.{}, actor_mod.Actor.run, .{&self.actor});
        self.caller = try inproc.Worker.spawn(gpa, &self.actor, &self.registry, "test-caller");
        return self;
    }

    fn deinit(self: *Harness) void {
        const gpa = self.actor.gpa;
        self.caller.stop();
        self.actor.post(.shutdown);
        self.kernel.join();
        self.actor.deinit();
        self.registry.deinit();
        gpa.destroy(self);
    }
};

const req_bash = "{\"tool\":\"bash\",\"input\":{\"command\":\"rm -rf /\"},\"reason\":\"policy ask\"}";

fn approvedOf(payload: []const u8) !bool {
    var p = try json.parseFromSlice(json.Value, testing.allocator, payload, .{});
    defer p.deinit();
    return p.value.object.get("approved").?.bool;
}

test "auto_approve replies approved" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aw = try ApprovalWorker.start(testing.allocator, &h.actor, &h.registry, .auto_approve);
    defer aw.stop();

    const res = try h.caller.call("zygos::approvals::request", req_bash);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try testing.expect(try approvedOf(res.ok));
}

test "auto_deny replies denied" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aw = try ApprovalWorker.start(testing.allocator, &h.actor, &h.registry, .auto_deny);
    defer aw.stop();

    const res = try h.caller.call("zygos::approvals::request", req_bash);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try testing.expect(!try approvedOf(res.ok));
}

/// Spins on approvals::pending from a second worker until one shows up,
/// then resolves it. No sleeps — bounded by bus dispatch.
const Resolver = struct {
    worker: *inproc.Worker,
    approve: bool,
    saw_tool: bool = false,

    fn run(self: *Resolver) void {
        const gpa = self.worker.gpa;
        // Bounded so a broken worker fails the test instead of hanging it;
        // each iteration is a full bus round trip, thousands = seconds.
        var spins: usize = 0;
        while (spins < 10_000) : (spins += 1) {
            const res = self.worker.call("zygos::approvals::pending", "{}") catch return;
            defer res.deinit(gpa);
            if (res != .ok) return;
            var p = json.parseFromSlice(json.Value, gpa, res.ok, .{}) catch return;
            defer p.deinit();
            const list = p.value.object.get("pending").?.array.items;
            if (list.len == 0) continue;
            const entry = list[0].object;
            const id = entry.get("id").?.string;
            if (entry.get("tool")) |t| self.saw_tool = std.mem.eql(u8, t.string, "bash");
            const req = std.fmt.allocPrint(gpa, "{{\"id\":\"{s}\",\"approved\":{}}}", .{ id, self.approve }) catch return;
            defer gpa.free(req);
            const rr = self.worker.call("zygos::approvals::resolve", req) catch return;
            rr.deinit(gpa);
            return;
        }
    }
};

test "manual: request parks until resolve approves it" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aw = try ApprovalWorker.start(testing.allocator, &h.actor, &h.registry, .{ .manual = .{} });
    defer aw.stop();

    var resolver: Resolver = .{ .worker = h.caller, .approve = true };
    const rt = try std.Thread.spawn(.{}, Resolver.run, .{&resolver});

    const requester = try inproc.Worker.spawn(testing.allocator, &h.actor, &h.registry, "requester");
    defer requester.stop();
    const res = try requester.call("zygos::approvals::request", req_bash);
    defer res.deinit(testing.allocator);
    rt.join();

    try testing.expect(res == .ok);
    try testing.expect(try approvedOf(res.ok));
    try testing.expect(resolver.saw_tool); // pending exposed the tool name
}

test "manual: resolve(approved:false) denies" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aw = try ApprovalWorker.start(testing.allocator, &h.actor, &h.registry, .{ .manual = .{} });
    defer aw.stop();

    var resolver: Resolver = .{ .worker = h.caller, .approve = false };
    const rt = try std.Thread.spawn(.{}, Resolver.run, .{&resolver});

    const requester = try inproc.Worker.spawn(testing.allocator, &h.actor, &h.registry, "requester");
    defer requester.stop();
    const res = try requester.call("zygos::approvals::request", req_bash);
    defer res.deinit(testing.allocator);
    rt.join();

    try testing.expect(res == .ok);
    try testing.expect(!try approvedOf(res.ok));
}

test "manual: pending is empty after resolution" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aw = try ApprovalWorker.start(testing.allocator, &h.actor, &h.registry, .{ .manual = .{} });
    defer aw.stop();

    var resolver: Resolver = .{ .worker = h.caller, .approve = true };
    const rt = try std.Thread.spawn(.{}, Resolver.run, .{&resolver});
    const requester = try inproc.Worker.spawn(testing.allocator, &h.actor, &h.registry, "requester");
    defer requester.stop();
    const res = try requester.call("zygos::approvals::request", req_bash);
    res.deinit(testing.allocator);
    rt.join();

    const after = try h.caller.call("zygos::approvals::pending", "{}");
    defer after.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, after.ok, "\"pending\":[]") != null);
}

test "manual with timeout_ms denies unresolved requests" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aw = try ApprovalWorker.start(testing.allocator, &h.actor, &h.registry, .{ .manual = .{ .timeout_ms = 20 } });
    defer aw.stop();

    const res = try h.caller.call("zygos::approvals::request", req_bash);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try testing.expect(!try approvedOf(res.ok));
}

test "timeout deny replies resolved:false (unanswered, not refused)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aw = try ApprovalWorker.start(testing.allocator, &h.actor, &h.registry, .{ .manual = .{ .timeout_ms = 20 } });
    defer aw.stop();

    const res = try h.caller.call("zygos::approvals::request", req_bash);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try testing.expect(!try approvedOf(res.ok));
    try testing.expect(std.mem.indexOf(u8, res.ok, "\"resolved\":false") != null);
}

test "explicit resolve deny replies resolved:true (a human said no)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aw = try ApprovalWorker.start(testing.allocator, &h.actor, &h.registry, .{ .manual = .{} });
    defer aw.stop();

    var resolver: Resolver = .{ .worker = h.caller, .approve = false };
    const rt = try std.Thread.spawn(.{}, Resolver.run, .{&resolver});
    const requester = try inproc.Worker.spawn(testing.allocator, &h.actor, &h.registry, "requester");
    defer requester.stop();
    const res = try requester.call("zygos::approvals::request", req_bash);
    defer res.deinit(testing.allocator);
    rt.join();

    try testing.expect(!try approvedOf(res.ok));
    try testing.expect(std.mem.indexOf(u8, res.ok, "\"resolved\":true") != null);
}

test "auto modes reply resolved:true (a configured decision, not silence)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aw = try ApprovalWorker.start(testing.allocator, &h.actor, &h.registry, .auto_deny);
    defer aw.stop();

    const res = try h.caller.call("zygos::approvals::request", req_bash);
    defer res.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, res.ok, "\"resolved\":true") != null);
}

test "resolve with unknown id reports resolved:false" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aw = try ApprovalWorker.start(testing.allocator, &h.actor, &h.registry, .{ .manual = .{} });
    defer aw.stop();

    const res = try h.caller.call("zygos::approvals::resolve", "{\"id\":\"a-999\",\"approved\":true}");
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try testing.expect(std.mem.indexOf(u8, res.ok, "\"resolved\":false") != null);
}

test "no leaks under park/resolve loops" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aw = try ApprovalWorker.start(testing.allocator, &h.actor, &h.registry, .{ .manual = .{} });
    defer aw.stop();

    const requester = try inproc.Worker.spawn(testing.allocator, &h.actor, &h.registry, "requester");
    defer requester.stop();

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        var resolver: Resolver = .{ .worker = h.caller, .approve = i % 2 == 0 };
        const rt = try std.Thread.spawn(.{}, Resolver.run, .{&resolver});
        const res = try requester.call("zygos::approvals::request", req_bash);
        res.deinit(testing.allocator);
        rt.join();
    }
}
