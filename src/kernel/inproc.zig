//! In-process bus workers (T1, docs/specs/inproc.md). An inproc worker is a
//! peer: it has a WorkerId, sends real frames as `Command`s, and receives
//! frames through `Outbound` — the kernel cannot tell it from a WS
//! connection, and every kernel semantic (owner CAS, correlation, GC) applies
//! unchanged.
//!
//! Delivery: `Registry` implements `Outbound`; send copies the frame into the
//! target worker's bounded queue (never blocks the kernel thread — full ⇒
//! QueueFull, kernel logs+drops, mirroring the WS writer cap). Unknown ids
//! fall through to the `fallback` Outbound (the WS gateway).
//!
//! Threading: one router thread per worker drains the queue and correlates
//! results; **handlers run on their own thread per invocation** so a handler
//! may itself make blocking bus calls (the turn driver does) without
//! deadlocking its worker's router loop.

const std = @import("std");
const actor_mod = @import("actor.zig");
const protocol = @import("protocol.zig");
const types = @import("types.zig");
const sync = @import("sync.zig");

const log = std.log.scoped(.inproc);

pub const WorkerId = types.WorkerId;

/// Handler contract: `request_json` is the invocation's data; the returned
/// JSON is arena-owned (freed after the result frame is built). `Failed`
/// becomes ErrorBody `handler_failed` on the bus.
pub const Handler = fn (
    ctx: ?*anyopaque,
    arena: std.mem.Allocator,
    request_json: []const u8,
) error{ Failed, OutOfMemory }![]const u8;

/// Outcome of a blocking call. Both payloads are gpa-owned by the caller.
pub const CallResult = union(enum) {
    ok: []u8,
    /// ErrorBody code from the bus (function_not_found, timeout, …).
    err: []u8,

    pub fn deinit(self: CallResult, gpa: std.mem.Allocator) void {
        switch (self) {
            .ok => |b| gpa.free(b),
            .err => |b| gpa.free(b),
        }
    }
};

// ---------------------------------------------------------------------------
// Registry — the Outbound mux
// ---------------------------------------------------------------------------

pub const Registry = struct {
    gpa: std.mem.Allocator,
    fallback: ?actor_mod.Outbound,
    mutex: sync.Mutex = .{},
    map: std.AutoHashMap(WorkerId, *Worker),

    pub fn init(gpa: std.mem.Allocator, fallback: ?actor_mod.Outbound) Registry {
        return .{ .gpa = gpa, .fallback = fallback, .map = std.AutoHashMap(WorkerId, *Worker).init(gpa) };
    }

    pub fn deinit(self: *Registry) void {
        // Workers must be stopped by their owners first.
        self.map.deinit();
        self.mutex.deinit();
    }

    pub fn outbound(self: *Registry) actor_mod.Outbound {
        return .{ .ctx = self, .sendFn = &sendFn };
    }

    fn sendFn(ctx: *anyopaque, to: WorkerId, frame: []const u8) actor_mod.SendError!void {
        const self: *Registry = @ptrCast(@alignCast(ctx));
        const worker = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            break :blk self.map.get(to);
        };
        if (worker) |w| return w.deliver(frame);
        if (self.fallback) |fb| return fb.sendFn(fb.ctx, to, frame);
        return error.Disconnected;
    }

    fn add(self: *Registry, w: *Worker) error{OutOfMemory}!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.map.put(w.id, w);
    }

    fn remove(self: *Registry, id: WorkerId) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.map.remove(id);
    }
};

// ---------------------------------------------------------------------------
// Worker
// ---------------------------------------------------------------------------

const queue_capacity = 64; // mirrors the WS writer cap

const HandlerEntry = struct {
    ctx: ?*anyopaque,
    f: *const Handler,
};

const CallSlot = struct {
    event: sync.ResetEvent = .{},
    outcome: ?CallResult = null, // null after wake = shutdown/OOM
};

pub const Worker = struct {
    gpa: std.mem.Allocator,
    actor: *actor_mod.Actor,
    registry: *Registry,
    id: WorkerId,
    name: []const u8, // owned

    // Inbound frame queue (kernel thread pushes, router thread pops).
    q_mutex: sync.Mutex = .{},
    q_not_empty: sync.Condition = .{},
    q_buf: [queue_capacity][]u8 = undefined,
    q_head: usize = 0,
    q_len: usize = 0,
    stopping: bool = false,

    handlers_mutex: sync.Mutex = .{},
    handlers: std.StringHashMap(HandlerEntry),

    pending_mutex: sync.Mutex = .{},
    pending: std.AutoHashMap(types.Uuid, *CallSlot),

    // Live handler threads (join-all on stop).
    hb_mutex: sync.Mutex = .{},
    hb_done: sync.Condition = .{},
    handlers_live: usize = 0,

    router: std.Thread = undefined,

    pub fn spawn(
        gpa: std.mem.Allocator,
        actor: *actor_mod.Actor,
        registry: *Registry,
        name: []const u8,
    ) !*Worker {
        const self = try gpa.create(Worker);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .actor = actor,
            .registry = registry,
            .id = newWorkerId(),
            .name = try gpa.dupe(u8, name),
            .handlers = std.StringHashMap(HandlerEntry).init(gpa),
            .pending = std.AutoHashMap(types.Uuid, *CallSlot).init(gpa),
        };
        errdefer gpa.free(self.name);
        try registry.add(self);
        errdefer registry.remove(self.id);
        self.router = try std.Thread.spawn(.{}, routerLoop, .{self});
        actor.post(.{ .worker_connected = self.id });
        return self;
    }

    /// Deregister from the bus and tear down. Callers must ensure no
    /// in-flight `call`s of their own remain; pendings are woken with a
    /// null outcome. Frees the worker.
    pub fn stop(self: *Worker) void {
        // No new deliveries...
        self.registry.remove(self.id);
        // ...bus-level GC (CAS-gated; a peer's re-registration survives)...
        self.actor.post(.{ .worker_disconnected = self.id });
        // ...wake anyone blocked on our calls...
        {
            self.pending_mutex.lock();
            defer self.pending_mutex.unlock();
            var it = self.pending.iterator();
            while (it.next()) |kv| kv.value_ptr.*.event.set();
            self.pending.clearRetainingCapacity();
        }
        // ...stop the router and wait for handler threads.
        {
            self.q_mutex.lock();
            defer self.q_mutex.unlock();
            self.stopping = true;
            self.q_not_empty.broadcast();
        }
        self.router.join();
        {
            self.hb_mutex.lock();
            defer self.hb_mutex.unlock();
            while (self.handlers_live > 0) self.hb_done.wait(&self.hb_mutex);
        }
        self.destroy();
    }

    fn destroy(self: *Worker) void {
        var i: usize = 0;
        while (i < self.q_len) : (i += 1) {
            self.gpa.free(self.q_buf[(self.q_head + i) % queue_capacity]);
        }
        var hit = self.handlers.iterator();
        while (hit.next()) |kv| self.gpa.free(kv.key_ptr.*);
        self.handlers.deinit();
        self.pending.deinit();
        self.gpa.free(self.name);
        self.hb_done.deinit();
        self.hb_mutex.deinit();
        self.pending_mutex.deinit();
        self.handlers_mutex.deinit();
        self.q_not_empty.deinit();
        self.q_mutex.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    /// Register a function on the bus + the local dispatch table.
    pub fn registerFunction(
        self: *Worker,
        id: []const u8,
        ctx: ?*anyopaque,
        f: *const Handler,
    ) error{OutOfMemory}!void {
        {
            self.handlers_mutex.lock();
            defer self.handlers_mutex.unlock();
            const owned = try self.gpa.dupe(u8, id);
            errdefer self.gpa.free(owned);
            try self.handlers.put(owned, .{ .ctx = ctx, .f = f });
        }
        try self.postFrameFmt("{{\"type\":\"registerfunction\",\"id\":{f}}}", .{
            std.json.fmt(id, .{}),
        });
    }

    /// Blocking invoke over the bus. `payload_json` must be a valid JSON
    /// value. Never call from this worker's own handler serving the same
    /// function chain synchronously — cross-worker nesting is safe (handlers
    /// run on their own threads).
    pub fn call(
        self: *Worker,
        function_id: []const u8,
        payload_json: []const u8,
    ) error{ OutOfMemory, Shutdown }!CallResult {
        var uuid_bytes: types.Uuid = undefined;
        std.c.arc4random_buf(&uuid_bytes, uuid_bytes.len);
        var uuid_text_buf: [36]u8 = undefined;
        const uuid_text = types.formatUuid(uuid_bytes, &uuid_text_buf);

        var slot: CallSlot = .{};
        defer slot.event.deinit();
        {
            self.pending_mutex.lock();
            defer self.pending_mutex.unlock();
            try self.pending.put(uuid_bytes, &slot);
        }
        errdefer {
            self.pending_mutex.lock();
            defer self.pending_mutex.unlock();
            _ = self.pending.remove(uuid_bytes);
        }

        try self.postFrameFmt(
            "{{\"type\":\"invokefunction\",\"invocation_id\":\"{s}\",\"function_id\":{f},\"data\":{s}}}",
            .{ uuid_text, std.json.fmt(function_id, .{}), payload_json },
        );

        slot.event.wait();
        return slot.outcome orelse error.Shutdown;
    }

    /// Fire-and-forget invoke (no invocation_id, no pending anywhere).
    pub fn cast(
        self: *Worker,
        function_id: []const u8,
        payload_json: []const u8,
    ) error{OutOfMemory}!void {
        try self.postFrameFmt(
            "{{\"type\":\"invokefunction\",\"function_id\":{f},\"data\":{s}}}",
            .{ std.json.fmt(function_id, .{}), payload_json },
        );
    }

    // -- outbound delivery (kernel thread) ------------------------------------

    fn deliver(self: *Worker, frame: []const u8) actor_mod.SendError!void {
        const copy = self.gpa.dupe(u8, frame) catch return error.QueueFull;
        self.q_mutex.lock();
        defer self.q_mutex.unlock();
        if (self.stopping or self.q_len == queue_capacity) {
            self.gpa.free(copy);
            return if (self.stopping) error.Disconnected else error.QueueFull;
        }
        self.q_buf[(self.q_head + self.q_len) % queue_capacity] = copy;
        self.q_len += 1;
        self.q_not_empty.signal();
    }

    // -- router thread ---------------------------------------------------------

    fn routerLoop(self: *Worker) void {
        while (self.popFrame()) |frame| {
            defer self.gpa.free(frame);
            self.route(frame);
        }
    }

    fn popFrame(self: *Worker) ?[]u8 {
        self.q_mutex.lock();
        defer self.q_mutex.unlock();
        while (self.q_len == 0 and !self.stopping) self.q_not_empty.wait(&self.q_mutex);
        if (self.q_len == 0) return null; // stopping and drained
        const frame = self.q_buf[self.q_head];
        self.q_head = (self.q_head + 1) % queue_capacity;
        self.q_len -= 1;
        return frame;
    }

    fn route(self: *Worker, frame: []const u8) void {
        var parsed = protocol.parseMessage(self.gpa, frame) catch |err| {
            log.warn("{s}: unparseable inbound frame ({t})", .{ self.name, err });
            return;
        };
        var keep_parsed = false;
        defer if (!keep_parsed) parsed.deinit();

        switch (parsed.value) {
            .invokefunction => |m| {
                // Handler threads own the parse until they finish.
                keep_parsed = true;
                self.dispatchInvoke(parsed, m);
            },
            .invocationresult => |m| self.completeCall(m),
            .workerregistered, .pong => {},
            .ping => {}, // kernel doesn't ping inproc workers; ignore
            else => log.debug("{s}: dropped frame", .{self.name}),
        }
    }

    fn dispatchInvoke(
        self: *Worker,
        parsed: std.json.Parsed(protocol.Message),
        m: protocol.Message.InvokeFunction,
    ) void {
        const entry: ?HandlerEntry = blk: {
            self.handlers_mutex.lock();
            defer self.handlers_mutex.unlock();
            break :blk self.handlers.get(m.function_id);
        };

        {
            self.hb_mutex.lock();
            defer self.hb_mutex.unlock();
            self.handlers_live += 1;
        }
        const t = std.Thread.spawn(.{}, runHandler, .{ self, parsed, m, entry }) catch {
            self.handlerDone();
            parsed.deinit();
            log.err("{s}: handler thread spawn failed, invocation dropped", .{self.name});
            return;
        };
        t.detach();
    }

    fn handlerDone(self: *Worker) void {
        self.hb_mutex.lock();
        defer self.hb_mutex.unlock();
        self.handlers_live -= 1;
        self.hb_done.broadcast();
    }

    fn runHandler(
        self: *Worker,
        parsed: std.json.Parsed(protocol.Message),
        m: protocol.Message.InvokeFunction,
        entry: ?HandlerEntry,
    ) void {
        defer self.handlerDone();
        defer parsed.deinit();

        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const scratch = arena.allocator();

        const iid = m.invocation_id; // null = fire-and-forget: no result frame
        const e = entry orelse {
            if (iid) |i| self.postErrorResult(i, m.function_id, "function_not_found");
            return;
        };

        const request_json = rawJson(scratch, m.data) catch return;
        const response = e.f(e.ctx, scratch, request_json) catch |err| {
            if (iid) |i| self.postErrorResult(i, m.function_id, switch (err) {
                error.Failed => "handler_failed",
                error.OutOfMemory => "out_of_memory",
            });
            return;
        };
        if (iid) |i| {
            self.postFrameFmt(
                "{{\"type\":\"invocationresult\",\"invocation_id\":\"{s}\",\"function_id\":{f},\"result\":{s}}}",
                .{ i, std.json.fmt(m.function_id, .{}), response },
            ) catch {
                // Fail closed: a result the protocol rejects (handler emitted
                // invalid JSON) must still answer the caller — a silent drop
                // parks it until the invoke timeout and reads as a hang.
                self.postErrorResult(i, m.function_id, "invalid_result");
            };
        }
    }

    fn completeCall(self: *Worker, m: protocol.Message.InvocationResult) void {
        const uuid = types.parseUuid(m.invocation_id) catch {
            log.warn("{s}: result with invalid uuid dropped", .{self.name});
            return;
        };
        const slot = blk: {
            self.pending_mutex.lock();
            defer self.pending_mutex.unlock();
            const kv = self.pending.fetchRemove(uuid) orelse break :blk null;
            break :blk kv.value;
        } orelse {
            log.warn("{s}: unknown invocation result dropped", .{self.name});
            return;
        };

        if (m.err) |e| {
            if (self.gpa.dupe(u8, e.code)) |code| {
                slot.outcome = .{ .err = code };
            } else |_| {}
        } else {
            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();
            const text: []const u8 = if (m.result) |v|
                rawJson(arena.allocator(), v) catch "null"
            else
                "null";
            if (self.gpa.dupe(u8, text)) |owned| {
                slot.outcome = .{ .ok = owned };
            } else |_| {}
        }
        slot.event.set();
    }

    // -- frame posting ----------------------------------------------------------

    /// Build a frame as JSON text, parse it through protocol.zig (the same
    /// bytes a WS worker would send), and post it as a command.
    fn postFrameFmt(self: *Worker, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
        const text = try std.fmt.allocPrint(self.gpa, fmt, args);
        defer self.gpa.free(text);
        const parsed = protocol.parseMessage(self.gpa, text) catch |err| {
            // Callers recover (runHandler answers invalid_result), so this
            // is evidence, not a fatality — and log.err would fail tests
            // that exercise the recovery path.
            log.warn("{s}: built an invalid frame ({t}): {s}", .{ self.name, err, text });
            return error.OutOfMemory;
        };
        self.actor.post(.{ .frame = .{ .from = self.id, .parsed = parsed, .now_ms = nowMs() } });
    }

    fn postErrorResult(self: *Worker, iid: []const u8, function_id: []const u8, code: []const u8) void {
        self.postFrameFmt(
            "{{\"type\":\"invocationresult\",\"invocation_id\":\"{s}\",\"function_id\":{f},\"error\":{{\"code\":\"{s}\",\"message\":\"\"}}}}",
            .{ iid, std.json.fmt(function_id, .{}), code },
        ) catch {};
    }
};

fn newWorkerId() WorkerId {
    var id: WorkerId = undefined;
    std.c.arc4random_buf(&id, id.len);
    id[6] = (id[6] & 0x0f) | 0x40;
    id[8] = (id[8] & 0x3f) | 0x80;
    return id;
}

/// Wall-clock ms for poster-stamped commands (same contract as net/ws.zig).
fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

fn rawJson(alloc: std.mem.Allocator, value: std.json.Value) error{OutOfMemory}![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var ws: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    ws.write(value) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

// ===========================================================================
// Tests (docs/specs/inproc.md contract 1–6, 10; 7–9 live in actor.zig)
// ===========================================================================

const testing = std.testing;

const Harness = struct {
    fallback: FakeOutbound,
    registry: Registry,
    actor: actor_mod.Actor,
    kernel: std.Thread,

    const FakeOutbound = struct {
        gpa: std.mem.Allocator,
        mutex: sync.Mutex = .{},
        frames: usize = 0,

        fn sendFn(ctx: *anyopaque, to: WorkerId, frame: []const u8) actor_mod.SendError!void {
            _ = to;
            _ = frame;
            const self: *FakeOutbound = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            defer self.mutex.unlock();
            self.frames += 1;
        }
    };

    fn init(gpa: std.mem.Allocator) !*Harness {
        const self = try gpa.create(Harness);
        self.fallback = .{ .gpa = gpa };
        self.registry = Registry.init(gpa, .{ .ctx = &self.fallback, .sendFn = &FakeOutbound.sendFn });
        self.actor = try actor_mod.Actor.init(gpa, .{}, self.registry.outbound());
        self.kernel = try std.Thread.spawn(.{}, actor_mod.Actor.run, .{&self.actor});
        return self;
    }

    fn deinit(self: *Harness) void {
        self.actor.post(.shutdown);
        self.kernel.join();
        const gpa = self.actor.gpa;
        self.actor.deinit();
        self.registry.deinit();
        self.fallback.mutex.deinit();
        gpa.destroy(self);
    }
};

fn sumHandler(_: ?*anyopaque, arena: std.mem.Allocator, request_json: []const u8) error{ Failed, OutOfMemory }![]const u8 {
    _ = request_json;
    return arena.dupe(u8, "{\"sum\":3}") catch error.OutOfMemory;
}

const CastProbe = struct {
    event: sync.ResetEvent = .{},

    fn handler(ctx: ?*anyopaque, arena: std.mem.Allocator, request_json: []const u8) error{ Failed, OutOfMemory }![]const u8 {
        _ = request_json;
        const self: *CastProbe = @ptrCast(@alignCast(ctx.?));
        self.event.set();
        return arena.dupe(u8, "{}") catch error.OutOfMemory;
    }
};

test "inproc worker registers a function; a second worker calls it and gets the response" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const a = try Worker.spawn(testing.allocator, &h.actor, &h.registry, "worker-a");
    defer a.stop();
    const b = try Worker.spawn(testing.allocator, &h.actor, &h.registry, "worker-b");
    defer b.stop();

    try a.registerFunction("math::add", null, &sumHandler);
    const result = try b.call("math::add", "{\"a\":1,\"b\":2}");
    defer result.deinit(testing.allocator);
    try testing.expect(result == .ok);
    try testing.expectEqualStrings("{\"sum\":3}", result.ok);
}

test "call to an unknown function surfaces the ErrorBody code" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const b = try Worker.spawn(testing.allocator, &h.actor, &h.registry, "worker-b");
    defer b.stop();

    const result = try b.call("missing::fn", "{}");
    defer result.deinit(testing.allocator);
    try testing.expect(result == .err);
    try testing.expectEqualStrings("function_not_found", result.err);
}

test "a handler result the protocol rejects errors the caller instead of hanging" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const a = try Worker.spawn(testing.allocator, &h.actor, &h.registry, "worker-a");
    defer a.stop();
    const b = try Worker.spawn(testing.allocator, &h.actor, &h.registry, "worker-b");
    defer b.stop();

    // Duplicate keys — the exact GLM tool-args shape that made the result
    // frame unparseable: the caller must get an error result, never a
    // silent drop that parks it until the invoke timeout.
    try a.registerFunction("bad::json", null, &duplicateKeyHandler);
    const result = try b.call("bad::json", "{}");
    defer result.deinit(testing.allocator);
    try testing.expect(result == .err);
    try testing.expectEqualStrings("invalid_result", result.err);
}

fn duplicateKeyHandler(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8) error{ Failed, OutOfMemory }![]const u8 {
    return "{\"command\":\"long one\",\"command\":\"ls -la\"}";
}

test "fire-and-forget cast dispatches without a pending" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const a = try Worker.spawn(testing.allocator, &h.actor, &h.registry, "worker-a");
    defer a.stop();
    const b = try Worker.spawn(testing.allocator, &h.actor, &h.registry, "worker-b");
    defer b.stop();

    var probe: CastProbe = .{};
    defer probe.event.deinit();
    try a.registerFunction("probe::hit", &probe, &CastProbe.handler);

    try b.cast("probe::hit", "{}");
    probe.event.wait(); // bounded by dispatch; no sleeps
    try testing.expectEqual(@as(usize, 0), h.actor.invocations.count());
}

test "two inproc workers call each other concurrently without deadlock" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const a = try Worker.spawn(testing.allocator, &h.actor, &h.registry, "worker-a");
    defer a.stop();
    const b = try Worker.spawn(testing.allocator, &h.actor, &h.registry, "worker-b");
    defer b.stop();

    try a.registerFunction("a::fn", null, &sumHandler);
    try b.registerFunction("b::fn", null, &sumHandler);

    const Caller = struct {
        fn run(w: *Worker, target: []const u8, ok: *bool) void {
            var i: usize = 0;
            while (i < 10) : (i += 1) {
                const r = w.call(target, "{}") catch return;
                defer r.deinit(w.gpa);
                if (r != .ok) return;
            }
            ok.* = true;
        }
    };
    var ok_ab = false;
    var ok_ba = false;
    const t1 = try std.Thread.spawn(.{}, Caller.run, .{ a, "b::fn", &ok_ab });
    const t2 = try std.Thread.spawn(.{}, Caller.run, .{ b, "a::fn", &ok_ba });
    t1.join();
    t2.join();
    try testing.expect(ok_ab and ok_ba);
}

test "worker stop posts worker_disconnected; its functions are reaped" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const a = try Worker.spawn(testing.allocator, &h.actor, &h.registry, "worker-a");
    try a.registerFunction("gone::fn", null, &sumHandler);

    const b = try Worker.spawn(testing.allocator, &h.actor, &h.registry, "worker-b");
    defer b.stop();

    // Prove it works while A is alive...
    const before = try b.call("gone::fn", "{}");
    before.deinit(testing.allocator);

    a.stop();

    // ...and is CAS-reaped after A stops.
    const after = try b.call("gone::fn", "{}");
    defer after.deinit(testing.allocator);
    try testing.expect(after == .err);
    try testing.expectEqualStrings("function_not_found", after.err);
}

test "mux falls back to the fallback outbound for non-inproc ids" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // A connect for a worker the registry doesn't know → workerregistered
    // goes through the fallback.
    h.actor.post(.{ .worker_connected = [_]u8{9} ** 16 });

    const b = try Worker.spawn(testing.allocator, &h.actor, &h.registry, "worker-b");
    b.stop(); // forces at least one full kernel round-trip so the post above was handled

    // The fallback write happens on the kernel thread; the round-trip above
    // makes it imminent but not yet observed. Poll with a deadline instead of
    // asserting instantly — same invariant, no timing sensitivity.
    var waited_ms: usize = 0;
    while (waited_ms < 5000) : (waited_ms += 10) {
        h.fallback.mutex.lock();
        const frames = h.fallback.frames;
        h.fallback.mutex.unlock();
        if (frames >= 1) return;
        const interval: std.c.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        var rem: std.c.timespec = undefined;
        _ = std.c.nanosleep(&interval, &rem);
    }
    return error.FallbackFrameNeverArrived;
}

test "no leaks under register/call loops" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const a = try Worker.spawn(testing.allocator, &h.actor, &h.registry, "worker-a");
    defer a.stop();
    const b = try Worker.spawn(testing.allocator, &h.actor, &h.registry, "worker-b");
    defer b.stop();

    try a.registerFunction("math::add", null, &sumHandler);
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const r = try b.call("math::add", "{\"i\":1}");
        r.deinit(testing.allocator);
    }
}
