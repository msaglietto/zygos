//! Approval/question worker (U2, docs/specs/approval.md). Owns the
//! human-in-the-loop seam: `zygos::approvals::request` parks its invocation
//! (handlers run on their own threads — parking is safe) until a
//! `zygos::approvals::resolve` answers it, `zygos::approvals::cancel` or the
//! worker's `stop` cancels it, or the timeout fires.
//!
//! Every reply carries one `outcome` from the closed set `Outcome`:
//! `allowed_once` (resolve approved, or auto_approve), `rejected` (resolve
//! denied, or auto_deny), `unavailable` (the manual timeout expired — nobody
//! answered) and `cancelled` (cancel or worker stop while parked). Only
//! `allowed_once` carries `approved:true`; every other outcome is a denial —
//! fail closed. Each reply is preceded by an `approval_asked` and followed by
//! an `approval_decided` trace event (emitted here, where the id is known).

const std = @import("std");
const jsonx = @import("jsonx.zig");
const json = std.json;
const actor_mod = @import("../kernel/actor.zig");
const inproc = @import("../kernel/inproc.zig");
const sync = @import("../kernel/sync.zig");
const trace_mod = @import("trace.zig");

pub const Mode = union(enum) {
    /// Park until resolved; `timeout_ms` bounds the park (`unavailable` on expiry).
    manual: struct { timeout_ms: ?u64 = null },
    auto_approve,
    auto_deny,
};

/// The closed decision set of an approval reply (docs/specs/approval.md,
/// "Outcomes"). The wire form is the tag name.
pub const Outcome = enum {
    allowed_once,
    rejected,
    cancelled,
    unavailable,

    /// Unknown text is null: callers treat it as a denial.
    pub fn parse(text: []const u8) ?Outcome {
        return std.meta.stringToEnum(Outcome, text);
    }
};

const Pending = struct {
    id: []const u8, // owned by the parked request handler's frame
    tool: []const u8,
    reason: []const u8,
    /// The request's `input` re-serialized as JSON text ("null" when absent).
    input: []const u8,
    /// Null when the request carried none (or an empty one).
    step_id: ?[]const u8,
    event: sync.ResetEvent = .{},
    approved: bool = false,
    /// True only when a resolve call answered this request; a timeout,
    /// cancel or worker-stop wake leaves it false, so callers can tell
    /// "denied by a human" from "denied because nobody answered".
    resolved: bool = false,
    /// Set by `cancel` or `stop` before the event fires.
    cancelled: bool = false,
};

pub const ApprovalWorker = struct {
    gpa: std.mem.Allocator,
    worker: *inproc.Worker,
    mode: Mode,
    mutex: sync.Mutex = .{},
    next_id: usize = 1,
    /// Set by `stop` under `mutex`: a request that arrives after the wake
    /// sweep must not park for a wake that already happened.
    stopping: bool = false,
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
        try self.worker.registerFunction("zygos::approvals::cancel", self, &cancelHandler);
        return self;
    }

    pub fn stop(self: *ApprovalWorker) void {
        // Wake every parked request as cancelled; each handler removes its own
        // entry before worker.stop() finishes joining handler threads.
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.stopping = true;
            var it = self.pending.valueIterator();
            while (it.next()) |p| {
                p.*.cancelled = true;
                p.*.event.set();
            }
        }
        // `inproc.Worker.stop` deregisters first, and the bus then fails any
        // invocation whose reply has not been posted yet with
        // `worker_disconnected`. Let the woken handlers finish (the reply is
        // posted before a handler counts as done) so their callers receive the
        // `cancelled` reply instead of a transport error.
        self.worker.waitHandlersIdle();
        self.worker.stop();
        std.debug.assert(self.pending.count() == 0);
        self.pending.deinit();
        self.mutex.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    fn requestHandler(ctx: ?*anyopaque, arena: std.mem.Allocator, request_json: []const u8) error{ Failed, OutOfMemory }![]const u8 {
        const self: *ApprovalWorker = @ptrCast(@alignCast(ctx.?));

        var tool: []const u8 = "";
        var reason: []const u8 = "";
        var input: []const u8 = "null";
        var step_id: ?[]const u8 = null;
        var trace_path: ?[]const u8 = null;
        if (json.parseFromSliceLeaky(json.Value, arena, request_json, .{})) |root| {
            if (root == .object) {
                tool = strField(root.object, "tool") orelse "";
                reason = strField(root.object, "reason") orelse "";
                if (root.object.get("input")) |v| input = try jsonx.rawJson(arena, v);
                if (strField(root.object, "step_id")) |s| {
                    if (s.len > 0) step_id = s;
                }
                trace_path = strField(root.object, "trace_path");
            }
        } else |_| {}

        // Allocated before the entry is parked: once parked, every exit must go
        // through the wait below or `removeEntry`, and an `OutOfMemory` here
        // would otherwise leave `pending` pointing into a dead frame.
        const clipped_input = try trace_mod.clip(arena, input);

        // Park. The Pending lives on this handler thread's frame; the id must
        // be a stable map key, so it is duped on gpa. Everything else is
        // arena-owned and outlives the entry (removed before this returns).
        var entry: Pending = .{
            .id = undefined,
            .tool = tool,
            .reason = reason,
            .input = input,
            .step_id = step_id,
        };
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            var id_buf: [24]u8 = undefined;
            const id_text = std.fmt.bufPrint(&id_buf, "a-{d}", .{self.next_id}) catch unreachable;
            self.next_id += 1;
            entry.id = try self.gpa.dupe(u8, id_text);
            errdefer self.gpa.free(@constCast(entry.id));
            if (self.mode == .manual) {
                try self.pending.put(entry.id, &entry);
                if (self.stopping) {
                    entry.cancelled = true;
                    entry.event.set();
                }
            }
        }
        defer self.gpa.free(@constCast(entry.id));
        defer entry.event.deinit();

        // Emitted outside the mutex, after the entry is visible to resolve and
        // cancel, so the asked line always precedes the decided one.
        trace_mod.emit(arena, trace_path, .{ .approval_asked = .{
            .id = entry.id,
            .tool = tool,
            .step = step_id,
            .input = clipped_input,
        } }) catch |err| {
            if (self.mode == .manual) self.removeEntry(entry.id);
            return err;
        };

        const outcome: Outcome = switch (self.mode) {
            .auto_approve => .allowed_once,
            .auto_deny => .rejected,
            .manual => |m| blk: {
                const in_time = if (m.timeout_ms) |ms| entry.event.timedWait(ms) else b: {
                    entry.event.wait();
                    break :b true;
                };
                self.mutex.lock();
                defer self.mutex.unlock();
                _ = self.pending.remove(entry.id);
                // A resolve that raced the deadline loses: an unanswered
                // question is a "no" (fail closed).
                if (!in_time) break :blk .unavailable;
                if (entry.cancelled) break :blk .cancelled;
                if (entry.resolved) break :blk if (entry.approved) .allowed_once else .rejected;
                break :blk .unavailable; // woken with no decision recorded
            },
        };

        try trace_mod.emit(arena, trace_path, .{ .approval_decided = .{
            .id = entry.id,
            .outcome = @tagName(outcome),
        } });

        const approved = outcome == .allowed_once;
        // `resolved`: an answer (resolve call or auto mode) exists, as
        // opposed to silence (timeout) or abandonment (cancel, stop).
        const resolved = outcome == .allowed_once or outcome == .rejected;
        return std.fmt.allocPrint(
            arena,
            "{{\"approved\":{},\"id\":\"{s}\",\"outcome\":\"{s}\",\"resolved\":{}}}",
            .{ approved, entry.id, @tagName(outcome), resolved },
        );
    }

    fn removeEntry(self: *ApprovalWorker, id: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.pending.remove(id);
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
        // First decision wins: a cancelled or already-resolved request that has
        // not yet woken cannot be flipped by a late resolve.
        if (p.cancelled or p.resolved) return arena.dupe(u8, "{\"resolved\":false}");
        p.approved = approved;
        p.resolved = true;
        p.event.set();
        return arena.dupe(u8, "{\"resolved\":true}");
    }

    /// `{}` cancels every parked request, `{"id":"a-1"}` that one. Malformed
    /// bodies and unknown ids wake nothing.
    fn cancelHandler(ctx: ?*anyopaque, arena: std.mem.Allocator, request_json: []const u8) error{ Failed, OutOfMemory }![]const u8 {
        const self: *ApprovalWorker = @ptrCast(@alignCast(ctx.?));
        const none = "{\"cancelled\":0}";

        const root = json.parseFromSliceLeaky(json.Value, arena, request_json, .{}) catch
            return arena.dupe(u8, none);
        if (root != .object) return arena.dupe(u8, none);
        const target: ?[]const u8 = if (root.object.get("id")) |v| blk: {
            if (v != .string) return arena.dupe(u8, none);
            break :blk v.string;
        } else null;

        var woken: usize = 0;
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (target) |id| {
                if (self.pending.get(id)) |p| woken += cancelEntry(p);
            } else {
                var it = self.pending.valueIterator();
                while (it.next()) |p| woken += cancelEntry(p.*);
            }
        }
        return std.fmt.allocPrint(arena, "{{\"cancelled\":{d}}}", .{woken});
    }

    /// Caller holds the mutex. An entry already decided is not woken twice.
    fn cancelEntry(p: *Pending) usize {
        if (p.cancelled or p.resolved) return 0;
        p.cancelled = true;
        p.event.set();
        return 1;
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
            if (p.*.step_id) |s| {
                ws.objectField("step_id") catch return error.OutOfMemory;
                ws.write(s) catch return error.OutOfMemory;
            }
            ws.objectField("input") catch return error.OutOfMemory;
            // Already valid JSON text (rawJson of the request's value): a value, not a string.
            ws.beginWriteRaw() catch return error.OutOfMemory;
            out.writer.writeAll(p.*.input) catch return error.OutOfMemory;
            ws.endWriteRaw();
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

// -- Outcomes, cancel, pending input and the audit pair (spec items 12-23) ----

const trace_mod_test = @import("trace.zig");

extern "c" fn realpath(path: [*:0]const u8, resolved: [*]u8) ?[*:0]u8;

/// Absolute path of `events.jsonl` inside the test's tmp dir.
fn tmpTracePath(tmp: *testing.TmpDir, buf: []u8) ![]const u8 {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    var rel_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rel = try std.fmt.bufPrintZ(&rel_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const dir = std.mem.span(realpath(rel, &dir_buf) orelse return error.RealpathFailed);
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, trace_mod_test.file_name });
}

/// `{"tool":"bash","input":<input_json>,"reason":"policy ask"[,"step_id":..][,"trace_path":..]}`
fn buildRequest(
    arena: std.mem.Allocator,
    input_json: ?[]const u8,
    step_id: ?[]const u8,
    trace_path: ?[]const u8,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "{\"tool\":\"bash\",\"reason\":\"policy ask\"");
    if (input_json) |i| try out.print(arena, ",\"input\":{s}", .{i});
    if (step_id) |s| try out.print(arena, ",\"step_id\":{f}", .{json.fmt(s, .{})});
    if (trace_path) |t| try out.print(arena, ",\"trace_path\":{f}", .{json.fmt(t, .{})});
    try out.append(arena, '}');
    return out.items;
}

fn outcomeOf(arena: std.mem.Allocator, payload: []const u8) ![]const u8 {
    const v = try json.parseFromSliceLeaky(json.Value, arena, payload, .{});
    const o = v.object.get("outcome") orelse return error.MissingOutcome;
    if (o != .string) return error.MissingOutcome;
    return o.string;
}

fn idOf(arena: std.mem.Allocator, payload: []const u8) ![]const u8 {
    const v = try json.parseFromSliceLeaky(json.Value, arena, payload, .{});
    return v.object.get("id").?.string;
}

/// Runs one `approvals::request` on its own thread so the test can drive
/// pending/resolve/cancel/stop while it is parked.
const AsyncRequest = struct {
    worker: *inproc.Worker,
    payload: []const u8,
    reply: ?[]u8 = null,

    fn run(self: *AsyncRequest) void {
        const gpa = self.worker.gpa;
        const res = self.worker.call("zygos::approvals::request", self.payload) catch return;
        defer res.deinit(gpa);
        if (res == .ok) self.reply = gpa.dupe(u8, res.ok) catch null;
    }

    fn deinit(self: *AsyncRequest) void {
        if (self.reply) |r| self.worker.gpa.free(r);
    }
};

/// Bounded spin on `approvals::pending` until `count` requests are parked;
/// returns the pending reply text (caller frees with `gpa`).
fn awaitParked(worker: *inproc.Worker, count: usize) ![]u8 {
    const gpa = worker.gpa;
    var spins: usize = 0;
    while (spins < 20_000) : (spins += 1) {
        const res = try worker.call("zygos::approvals::pending", "{}");
        defer res.deinit(gpa);
        if (res != .ok) return error.PendingFailed;
        var p = try json.parseFromSlice(json.Value, gpa, res.ok, .{});
        defer p.deinit();
        if (p.value.object.get("pending").?.array.items.len >= count) return gpa.dupe(u8, res.ok);
    }
    return error.NeverParked;
}

fn callOk(worker: *inproc.Worker, fn_id: []const u8, payload: []const u8) ![]u8 {
    const gpa = worker.gpa;
    const res = try worker.call(fn_id, payload);
    defer res.deinit(gpa);
    if (res != .ok) return error.CallFailed;
    return gpa.dupe(u8, res.ok);
}

test "resolve(approved:true) replies outcome allowed_once" {
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

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualStrings("allowed_once", try outcomeOf(arena_state.allocator(), res.ok));
    try testing.expect(try approvedOf(res.ok));
    try testing.expect(std.mem.indexOf(u8, res.ok, "\"resolved\":true") != null);
}

test "resolve(approved:false) replies outcome rejected" {
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

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualStrings("rejected", try outcomeOf(arena_state.allocator(), res.ok));
    try testing.expect(!try approvedOf(res.ok));
    try testing.expect(std.mem.indexOf(u8, res.ok, "\"resolved\":true") != null);
}

test "timeout replies outcome unavailable with resolved:false" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aw = try ApprovalWorker.start(testing.allocator, &h.actor, &h.registry, .{ .manual = .{ .timeout_ms = 20 } });
    defer aw.stop();

    const res = try h.caller.call("zygos::approvals::request", req_bash);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualStrings("unavailable", try outcomeOf(arena_state.allocator(), res.ok));
    try testing.expect(!try approvedOf(res.ok));
    try testing.expect(std.mem.indexOf(u8, res.ok, "\"resolved\":false") != null);
}

test "cancel wakes a parked request as outcome cancelled; cancel with nothing parked reports 0" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aw = try ApprovalWorker.start(testing.allocator, &h.actor, &h.registry, .{ .manual = .{} });
    defer aw.stop();
    const gpa = testing.allocator;

    const none = try callOk(h.caller, "zygos::approvals::cancel", "{}");
    defer gpa.free(none);
    try testing.expectEqualStrings("{\"cancelled\":0}", none);

    const requester = try inproc.Worker.spawn(gpa, &h.actor, &h.registry, "requester");
    defer requester.stop();
    var areq: AsyncRequest = .{ .worker = requester, .payload = req_bash };
    defer areq.deinit();
    const rt = try std.Thread.spawn(.{}, AsyncRequest.run, .{&areq});

    const parked = try awaitParked(h.caller, 1);
    gpa.free(parked);

    // Unknown id and malformed bodies wake nothing.
    for ([_][]const u8{ "{\"id\":\"a-999\"}", "\"str\"", "[]", "{\"id\":7}" }) |body| {
        const r = try callOk(h.caller, "zygos::approvals::cancel", body);
        defer gpa.free(r);
        try testing.expectEqualStrings("{\"cancelled\":0}", r);
    }

    const cancelled = try callOk(h.caller, "zygos::approvals::cancel", "{}");
    defer gpa.free(cancelled);
    try testing.expectEqualStrings("{\"cancelled\":1}", cancelled);
    rt.join();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const reply = areq.reply orelse return error.NoReply;
    try testing.expectEqualStrings("cancelled", try outcomeOf(arena_state.allocator(), reply));
    try testing.expect(!try approvedOf(reply));
    try testing.expect(std.mem.indexOf(u8, reply, "\"resolved\":false") != null);
}

test "cancel by id wakes only that request" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aw = try ApprovalWorker.start(testing.allocator, &h.actor, &h.registry, .{ .manual = .{} });
    defer aw.stop();
    const gpa = testing.allocator;

    const r1 = try inproc.Worker.spawn(gpa, &h.actor, &h.registry, "requester-1");
    defer r1.stop();
    const r2 = try inproc.Worker.spawn(gpa, &h.actor, &h.registry, "requester-2");
    defer r2.stop();
    var a1: AsyncRequest = .{ .worker = r1, .payload = req_bash };
    defer a1.deinit();
    var a2: AsyncRequest = .{ .worker = r2, .payload = req_bash };
    defer a2.deinit();
    const t1 = try std.Thread.spawn(.{}, AsyncRequest.run, .{&a1});
    gpa.free(try awaitParked(h.caller, 1));
    const t2 = try std.Thread.spawn(.{}, AsyncRequest.run, .{&a2});
    gpa.free(try awaitParked(h.caller, 2));

    // a-1 is whichever request got the first id; cancel it, resolve the other.
    const one = try callOk(h.caller, "zygos::approvals::cancel", "{\"id\":\"a-1\"}");
    defer gpa.free(one);
    try testing.expectEqualStrings("{\"cancelled\":1}", one);
    const rest = try callOk(h.caller, "zygos::approvals::resolve", "{\"id\":\"a-2\",\"approved\":true}");
    gpa.free(rest);
    t1.join();
    t2.join();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_]*AsyncRequest{ &a1, &a2 }) |a| {
        const reply = a.reply orelse return error.NoReply;
        const id = try idOf(arena, reply);
        const want: []const u8 = if (std.mem.eql(u8, id, "a-1")) "cancelled" else "allowed_once";
        try testing.expectEqualStrings(want, try outcomeOf(arena, reply));
    }
}

/// Park one request, call stop() on the worker from the test thread, and
/// return the reply the parked caller received (caller frees).
fn stopWhileParked(trace_path: ?[]const u8) ![]u8 {
    const gpa = testing.allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();
    const aw = try ApprovalWorker.start(gpa, &h.actor, &h.registry, .{ .manual = .{} });
    var stopped = false;
    defer if (!stopped) aw.stop();

    const requester = try inproc.Worker.spawn(gpa, &h.actor, &h.registry, "requester");
    defer requester.stop();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const payload = try buildRequest(arena_state.allocator(), "{\"command\":\"ls\"}", "executor", trace_path);

    var areq: AsyncRequest = .{ .worker = requester, .payload = payload };
    defer areq.deinit();
    const rt = try std.Thread.spawn(.{}, AsyncRequest.run, .{&areq});
    gpa.free(try awaitParked(h.caller, 1));

    aw.stop();
    stopped = true;
    rt.join();
    return gpa.dupe(u8, areq.reply orelse return error.NoReply);
}

test "stop while parked replies outcome cancelled" {
    const reply = try stopWhileParked(null);
    defer testing.allocator.free(reply);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualStrings("cancelled", try outcomeOf(arena_state.allocator(), reply));
    try testing.expect(!try approvedOf(reply));
    try testing.expect(std.mem.indexOf(u8, reply, "\"resolved\":false") != null);
}

test "auto modes reply allowed_once / rejected with sequential ids" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    inline for (.{ .{ Mode.auto_approve, "allowed_once", true }, .{ Mode.auto_deny, "rejected", false } }) |c| {
        var h = try Harness.init(testing.allocator);
        defer h.deinit();
        const aw = try ApprovalWorker.start(testing.allocator, &h.actor, &h.registry, c[0]);
        defer aw.stop();

        var n: usize = 1;
        while (n <= 3) : (n += 1) {
            const res = try h.caller.call("zygos::approvals::request", req_bash);
            defer res.deinit(testing.allocator);
            try testing.expect(res == .ok);
            try testing.expectEqualStrings(c[1], try outcomeOf(arena, res.ok));
            try testing.expectEqual(c[2], try approvedOf(res.ok));
            const want = try std.fmt.allocPrint(arena, "a-{d}", .{n});
            try testing.expectEqualStrings(want, try idOf(arena, res.ok));
            try testing.expect(std.mem.indexOf(u8, res.ok, "\"resolved\":true") != null);
        }
    }
}

test "pending carries the request's input (the command text) and step_id" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aw = try ApprovalWorker.start(testing.allocator, &h.actor, &h.registry, .{ .manual = .{} });
    defer aw.stop();
    const gpa = testing.allocator;

    const requester = try inproc.Worker.spawn(gpa, &h.actor, &h.registry, "requester");
    defer requester.stop();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const payload = try buildRequest(arena, "{\"command\":\"rm -rf /\"}", "executor", null);
    var areq: AsyncRequest = .{ .worker = requester, .payload = payload };
    defer areq.deinit();
    const rt = try std.Thread.spawn(.{}, AsyncRequest.run, .{&areq});

    const text = try awaitParked(h.caller, 1);
    defer gpa.free(text);
    const cancel = try callOk(h.caller, "zygos::approvals::cancel", "{}");
    gpa.free(cancel);
    rt.join();

    const root = try json.parseFromSliceLeaky(json.Value, arena, text, .{});
    const entry = root.object.get("pending").?.array.items[0].object;
    try testing.expectEqualStrings("bash", entry.get("tool").?.string);
    try testing.expectEqualStrings("executor", entry.get("step_id").?.string);
    try testing.expectEqualStrings("policy ask", entry.get("reason").?.string);
    const input = entry.get("input").?;
    try testing.expect(input == .object); // a JSON value, not a quoted string
    try testing.expectEqualStrings("rm -rf /", input.object.get("command").?.string);
}

test "pending omits step_id when the request has none and shows input null when absent" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aw = try ApprovalWorker.start(testing.allocator, &h.actor, &h.registry, .{ .manual = .{} });
    defer aw.stop();
    const gpa = testing.allocator;

    const r1 = try inproc.Worker.spawn(gpa, &h.actor, &h.registry, "requester-1");
    defer r1.stop();
    const r2 = try inproc.Worker.spawn(gpa, &h.actor, &h.registry, "requester-2");
    defer r2.stop();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // No input, no step_id; and an empty step_id, which counts as absent.
    var a1: AsyncRequest = .{ .worker = r1, .payload = try buildRequest(arena, null, null, null) };
    defer a1.deinit();
    var a2: AsyncRequest = .{ .worker = r2, .payload = try buildRequest(arena, "\"x\"", "", null) };
    defer a2.deinit();
    const t1 = try std.Thread.spawn(.{}, AsyncRequest.run, .{&a1});
    gpa.free(try awaitParked(h.caller, 1));
    const t2 = try std.Thread.spawn(.{}, AsyncRequest.run, .{&a2});
    const text = try awaitParked(h.caller, 2);
    defer gpa.free(text);
    gpa.free(try callOk(h.caller, "zygos::approvals::cancel", "{}"));
    t1.join();
    t2.join();

    const root = try json.parseFromSliceLeaky(json.Value, arena, text, .{});
    const items = root.object.get("pending").?.array.items;
    try testing.expectEqual(@as(usize, 2), items.len);
    for (items) |it| {
        try testing.expect(it.object.get("step_id") == null);
        const id = it.object.get("id").?.string;
        const input = it.object.get("input").?;
        if (std.mem.eql(u8, id, "a-1")) {
            try testing.expect(input == .null);
        } else {
            try testing.expectEqualStrings("x", input.string);
        }
    }
}

const Resolution = enum { approve, reject, none };

/// One request in a fresh worker with its own trace file; asserts the file
/// holds exactly approval_asked then approval_decided, same id, `want`.
fn expectTracedPair(mode: Mode, how: Resolution, want: []const u8) !void {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmpTracePath(&tmp, &path_buf);

    var h = try Harness.init(gpa);
    defer h.deinit();
    const aw = try ApprovalWorker.start(gpa, &h.actor, &h.registry, mode);
    defer aw.stop();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const payload = try buildRequest(arena, "{\"command\":\"ls\"}", "executor", path);

    var resolver: Resolver = .{ .worker = h.caller, .approve = how == .approve };
    var rt: ?std.Thread = null;
    if (how != .none) rt = try std.Thread.spawn(.{}, Resolver.run, .{&resolver});
    const requester = try inproc.Worker.spawn(gpa, &h.actor, &h.registry, "requester");
    defer requester.stop();
    const res = try requester.call("zygos::approvals::request", payload);
    defer res.deinit(gpa);
    if (rt) |t| t.join();
    try testing.expect(res == .ok);

    const text = trace_mod_test.readFile(gpa, path) orelse return error.NoTrace;
    defer gpa.free(text);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    const asked = try json.parseFromSliceLeaky(json.Value, arena, lines.next() orelse return error.NoAsked, .{});
    const decided = try json.parseFromSliceLeaky(json.Value, arena, lines.next() orelse return error.NoDecided, .{});
    try testing.expect(lines.next() == null);

    try testing.expectEqualStrings("approval_asked", asked.object.get("event").?.string);
    try testing.expectEqualStrings("bash", asked.object.get("tool").?.string);
    try testing.expectEqualStrings("executor", asked.object.get("step").?.string);
    try testing.expectEqualStrings("{\"command\":\"ls\"}", asked.object.get("input").?.string);
    try testing.expectEqualStrings("approval_decided", decided.object.get("event").?.string);
    try testing.expectEqualStrings(try idOf(arena, res.ok), asked.object.get("id").?.string);
    try testing.expectEqualStrings(asked.object.get("id").?.string, decided.object.get("id").?.string);
    try testing.expectEqualStrings(want, decided.object.get("outcome").?.string);
    try testing.expectEqualStrings(want, try outcomeOf(arena, res.ok));
}

test "trace: approve, reject and timeout each write approval_asked then approval_decided with the same id and the matching outcome" {
    try expectTracedPair(.{ .manual = .{} }, .approve, "allowed_once");
    try expectTracedPair(.{ .manual = .{} }, .reject, "rejected");
    try expectTracedPair(.{ .manual = .{ .timeout_ms = 20 } }, .none, "unavailable");
    // Auto modes write the pair too (they used to reply "auto" with no trace).
    try expectTracedPair(.auto_approve, .none, "allowed_once");
    try expectTracedPair(.auto_deny, .none, "rejected");
}

test "trace: stop while parked records approval_decided cancelled" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmpTracePath(&tmp, &path_buf);

    const reply = try stopWhileParked(path);
    defer gpa.free(reply);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("cancelled", try outcomeOf(arena, reply));

    const text = trace_mod_test.readFile(gpa, path) orelse return error.NoTrace;
    defer gpa.free(text);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    const asked = try json.parseFromSliceLeaky(json.Value, arena, lines.next() orelse return error.NoAsked, .{});
    const decided = try json.parseFromSliceLeaky(json.Value, arena, lines.next() orelse return error.NoDecided, .{});
    try testing.expect(lines.next() == null);
    try testing.expectEqualStrings("approval_asked", asked.object.get("event").?.string);
    try testing.expectEqualStrings("approval_decided", decided.object.get("event").?.string);
    try testing.expectEqualStrings(asked.object.get("id").?.string, decided.object.get("id").?.string);
    try testing.expectEqualStrings("cancelled", decided.object.get("outcome").?.string);
}

test "trace: approval_asked input is clipped like tool_call input" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmpTracePath(&tmp, &path_buf);

    var h = try Harness.init(gpa);
    defer h.deinit();
    const aw = try ApprovalWorker.start(gpa, &h.actor, &h.registry, .auto_approve);
    defer aw.stop();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const big = try arena.alloc(u8, 5000);
    @memset(big, 'x');
    const input = try std.fmt.allocPrint(arena, "{{\"command\":\"{s}\"}}", .{big});
    const res = try h.caller.call("zygos::approvals::request", try buildRequest(arena, input, null, path));
    defer res.deinit(gpa);
    try testing.expect(res == .ok);

    const text = trace_mod_test.readFile(gpa, path) orelse return error.NoTrace;
    defer gpa.free(text);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    const asked = try json.parseFromSliceLeaky(json.Value, arena, lines.next().?, .{});
    const clipped = asked.object.get("input").?.string;
    try testing.expectEqualStrings(try trace_mod_test.clip(arena, input), clipped);
    try testing.expect(std.mem.indexOf(u8, clipped, "bytes total]") != null);
    try testing.expect(clipped.len < input.len);
    // No step on the request: null, not an empty string.
    try testing.expect(asked.object.get("step").? == .null);
}

// -- Failure paths and first-decision-wins (spec items 24-28) -----------------

/// A worker with no bus behind it, for driving the handlers directly. The
/// handlers touch only `gpa`, `mode`, `mutex`, `next_id`, `stopping` and
/// `pending`, never `worker`.
fn bareWorker(mode: Mode) ApprovalWorker {
    return .{
        .gpa = testing.allocator,
        .worker = undefined,
        .mode = mode,
        .pending = std.StringHashMap(*Pending).init(testing.allocator),
    };
}

fn deinitBare(self: *ApprovalWorker) void {
    self.pending.deinit();
    self.mutex.deinit();
}

test "request: an allocation failure never leaves a parked entry behind" {
    var self = bareWorker(.{ .manual = .{} });
    defer deinitBare(&self);
    // `stopping` makes the success path return `cancelled` at once instead of
    // parking, so every iteration finishes and `pending` can be inspected.
    self.stopping = true;

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    // Over the trace clip limit, so `trace.clip` allocates its marker text.
    const big = try arena_state.allocator().alloc(u8, trace_mod.max_field_bytes + 100);
    @memset(big, 'x');
    const input = try std.fmt.allocPrint(arena_state.allocator(), "{{\"command\":\"{s}\"}}", .{big});
    const payload = try buildRequest(arena_state.allocator(), input, "executor", null);

    var saw_oom = false;
    var fail_index: usize = 0;
    while (fail_index < 256) : (fail_index += 1) {
        // The handler gets the failing allocator itself (an arena in front of
        // it would batch small requests into one backing allocation and hide
        // most failure points); the scratch arena only reclaims what it frees.
        var scratch = std.heap.ArenaAllocator.init(testing.allocator);
        defer scratch.deinit();
        var failing = testing.FailingAllocator.init(scratch.allocator(), .{ .fail_index = fail_index });
        const result = ApprovalWorker.requestHandler(&self, failing.allocator(), payload);
        // Whatever failed, nothing may stay parked: the entry lives on the
        // handler's frame and the map key is freed on return.
        try testing.expectEqual(@as(usize, 0), self.pending.count());
        if (result) |reply| {
            try testing.expect(std.mem.indexOf(u8, reply, "\"outcome\":\"cancelled\"") != null);
            // Allocation number `fail_index` was never reached: all paths covered.
            if (!failing.has_induced_failure) break;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            saw_oom = true;
        }
    } else return error.NeverCompleted;
    try testing.expect(saw_oom);
}

test "resolve: the first decision wins and a later resolve or cancel cannot flip it" {
    var self = bareWorker(.{ .manual = .{} });
    defer deinitBare(&self);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Recorded but not yet woken: no handler thread is waiting on `p`, which
    // is exactly the window between `event.set()` and the handler waking.
    var p: Pending = .{ .id = "a-1", .tool = "bash", .reason = "", .input = "null", .step_id = null };
    defer p.event.deinit();
    try self.pending.put(p.id, &p);

    const first = try ApprovalWorker.resolveHandler(&self, arena, "{\"id\":\"a-1\",\"approved\":true}");
    try testing.expectEqualStrings("{\"resolved\":true}", first);
    const flip = try ApprovalWorker.resolveHandler(&self, arena, "{\"id\":\"a-1\",\"approved\":false}");
    try testing.expectEqualStrings("{\"resolved\":false}", flip);
    try testing.expect(p.approved);
    try testing.expect(p.resolved);
    // A cancel after the decision wakes nothing either.
    const late_cancel = try ApprovalWorker.cancelHandler(&self, arena, "{}");
    try testing.expectEqualStrings("{\"cancelled\":0}", late_cancel);
    try testing.expect(!p.cancelled);
}

test "resolve after cancel replies resolved:false and cannot revive the request" {
    var self = bareWorker(.{ .manual = .{} });
    defer deinitBare(&self);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var p: Pending = .{ .id = "a-1", .tool = "bash", .reason = "", .input = "null", .step_id = null };
    defer p.event.deinit();
    try self.pending.put(p.id, &p);

    const cancelled = try ApprovalWorker.cancelHandler(&self, arena, "{\"id\":\"a-1\"}");
    try testing.expectEqualStrings("{\"cancelled\":1}", cancelled);
    const late = try ApprovalWorker.resolveHandler(&self, arena, "{\"id\":\"a-1\",\"approved\":true}");
    try testing.expectEqualStrings("{\"resolved\":false}", late);
    try testing.expect(p.cancelled);
    try testing.expect(!p.resolved);
    try testing.expect(!p.approved);
}

test "trace: cancel while parked records approval_decided cancelled" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmpTracePath(&tmp, &path_buf);

    var h = try Harness.init(gpa);
    defer h.deinit();
    const aw = try ApprovalWorker.start(gpa, &h.actor, &h.registry, .{ .manual = .{} });
    defer aw.stop();
    const requester = try inproc.Worker.spawn(gpa, &h.actor, &h.registry, "requester");
    defer requester.stop();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const payload = try buildRequest(arena, "{\"command\":\"ls\"}", "executor", path);
    var areq: AsyncRequest = .{ .worker = requester, .payload = payload };
    defer areq.deinit();
    const rt = try std.Thread.spawn(.{}, AsyncRequest.run, .{&areq});
    gpa.free(try awaitParked(h.caller, 1));
    const cancelled = try callOk(h.caller, "zygos::approvals::cancel", "{}");
    gpa.free(cancelled);
    rt.join();

    const reply = areq.reply orelse return error.NoReply;
    try testing.expectEqualStrings("cancelled", try outcomeOf(arena, reply));

    const text = trace_mod_test.readFile(gpa, path) orelse return error.NoTrace;
    defer gpa.free(text);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    const asked = try json.parseFromSliceLeaky(json.Value, arena, lines.next() orelse return error.NoAsked, .{});
    const decided = try json.parseFromSliceLeaky(json.Value, arena, lines.next() orelse return error.NoDecided, .{});
    try testing.expect(lines.next() == null);
    try testing.expectEqualStrings("approval_asked", asked.object.get("event").?.string);
    try testing.expectEqualStrings("approval_decided", decided.object.get("event").?.string);
    try testing.expectEqualStrings(asked.object.get("id").?.string, decided.object.get("id").?.string);
    try testing.expectEqualStrings("cancelled", decided.object.get("outcome").?.string);
}

test "a request that arrives while the worker is stopping replies cancelled and parks nothing" {
    const gpa = testing.allocator;
    var h = try Harness.init(gpa);
    defer h.deinit();
    const aw = try ApprovalWorker.start(gpa, &h.actor, &h.registry, .{ .manual = .{} });
    defer aw.stop();

    // `stop` sets this under the mutex after its wake sweep; the handler is
    // still registered until `inproc.Worker.stop`, so a request can land here.
    {
        aw.mutex.lock();
        defer aw.mutex.unlock();
        aw.stopping = true;
    }
    const res = try h.caller.call("zygos::approvals::request", req_bash);
    defer res.deinit(gpa);
    try testing.expect(res == .ok);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    try testing.expectEqualStrings("cancelled", try outcomeOf(arena_state.allocator(), res.ok));
    try testing.expect(!try approvedOf(res.ok));
    try testing.expect(std.mem.indexOf(u8, res.ok, "\"resolved\":false") != null);
    try testing.expectEqual(@as(usize, 0), aw.pending.count());
}
