//! Budget worker (U5, docs/specs/budget.md). Per-scope token/savings
//! counters behind `zygos::budget::{configure,record,check}`. Scopes are
//! arbitrary strings (turn id, mission id, "global"); counters are
//! saturating u64 adds under one mutex.

const std = @import("std");
const json = std.json;
const actor_mod = @import("../kernel/actor.zig");
const inproc = @import("../kernel/inproc.zig");
const sync = @import("../kernel/sync.zig");

const Scope = struct {
    max_tokens: ?u64 = null,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    saved_bytes: u64 = 0,
};

pub const BudgetWorker = struct {
    gpa: std.mem.Allocator,
    worker: *inproc.Worker,
    mutex: sync.Mutex = .{},
    scopes: std.StringHashMap(Scope),

    pub fn start(
        gpa: std.mem.Allocator,
        actor: *actor_mod.Actor,
        registry: *inproc.Registry,
    ) !*BudgetWorker {
        const self = try gpa.create(BudgetWorker);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .worker = try inproc.Worker.spawn(gpa, actor, registry, "llm-budget"),
            .scopes = std.StringHashMap(Scope).init(gpa),
        };
        errdefer self.worker.stop();
        try self.worker.registerFunction("zygos::budget::configure", self, &configureHandler);
        try self.worker.registerFunction("zygos::budget::record", self, &recordHandler);
        try self.worker.registerFunction("zygos::budget::check", self, &checkHandler);
        return self;
    }

    pub fn stop(self: *BudgetWorker) void {
        self.worker.stop();
        var it = self.scopes.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.scopes.deinit();
        self.mutex.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    /// Get-or-create under the caller-held mutex; key duped on first sight.
    fn scopeFor(self: *BudgetWorker, name: []const u8) error{OutOfMemory}!*Scope {
        const gop = try self.scopes.getOrPut(name);
        if (!gop.found_existing) {
            gop.key_ptr.* = self.gpa.dupe(u8, name) catch |err| {
                _ = self.scopes.remove(name);
                return err;
            };
            gop.value_ptr.* = .{};
        }
        return gop.value_ptr;
    }

    const nope = "{\"ok\":false}";

    fn configureHandler(ctx: ?*anyopaque, arena: std.mem.Allocator, request_json: []const u8) error{ Failed, OutOfMemory }![]const u8 {
        const self: *BudgetWorker = @ptrCast(@alignCast(ctx.?));
        const obj = parseObj(arena, request_json) orelse return arena.dupe(u8, nope);
        const name = strField(obj, "scope") orelse return arena.dupe(u8, nope);
        const max = uintField(obj, "max_tokens");

        self.mutex.lock();
        defer self.mutex.unlock();
        const s = try self.scopeFor(name);
        s.* = .{ .max_tokens = max }; // re-configure resets counters
        return arena.dupe(u8, "{\"ok\":true}");
    }

    fn recordHandler(ctx: ?*anyopaque, arena: std.mem.Allocator, request_json: []const u8) error{ Failed, OutOfMemory }![]const u8 {
        const self: *BudgetWorker = @ptrCast(@alignCast(ctx.?));
        const obj = parseObj(arena, request_json) orelse return arena.dupe(u8, nope);
        const name = strField(obj, "scope") orelse return arena.dupe(u8, nope);
        const kind = strField(obj, "kind") orelse return arena.dupe(u8, nope);
        const amount = uintField(obj, "amount") orelse return arena.dupe(u8, nope);

        self.mutex.lock();
        defer self.mutex.unlock();
        const s = try self.scopeFor(name);
        const counter: *u64 = if (std.mem.eql(u8, kind, "input_tokens"))
            &s.input_tokens
        else if (std.mem.eql(u8, kind, "output_tokens"))
            &s.output_tokens
        else if (std.mem.eql(u8, kind, "saved_bytes"))
            &s.saved_bytes
        else
            return arena.dupe(u8, nope);
        counter.* +|= amount;
        return arena.dupe(u8, "{\"ok\":true}");
    }

    fn checkHandler(ctx: ?*anyopaque, arena: std.mem.Allocator, request_json: []const u8) error{ Failed, OutOfMemory }![]const u8 {
        const self: *BudgetWorker = @ptrCast(@alignCast(ctx.?));
        const obj = parseObj(arena, request_json) orelse return arena.dupe(u8, nope);
        const name = strField(obj, "scope") orelse return arena.dupe(u8, nope);

        self.mutex.lock();
        defer self.mutex.unlock();
        const s: Scope = if (self.scopes.get(name)) |found| found else .{};
        const used = s.input_tokens +| s.output_tokens;
        const ok = if (s.max_tokens) |max| used < max else true;
        if (s.max_tokens) |max| {
            return std.fmt.allocPrint(
                arena,
                "{{\"ok\":{},\"used_tokens\":{d},\"max_tokens\":{d},\"saved_bytes\":{d}}}",
                .{ ok, used, max, s.saved_bytes },
            );
        }
        return std.fmt.allocPrint(
            arena,
            "{{\"ok\":{},\"used_tokens\":{d},\"max_tokens\":null,\"saved_bytes\":{d}}}",
            .{ ok, used, s.saved_bytes },
        );
    }
};

fn parseObj(arena: std.mem.Allocator, request_json: []const u8) ?json.ObjectMap {
    const root = json.parseFromSliceLeaky(json.Value, arena, request_json, .{}) catch return null;
    return if (root == .object) root.object else null;
}

fn strField(obj: json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn uintField(obj: json.ObjectMap, key: []const u8) ?u64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |n| if (n >= 0) @intCast(n) else null,
        else => null,
    };
}

// ===========================================================================
// Tests (docs/specs/budget.md contract, RED first)
// ===========================================================================

const testing = std.testing;

const Harness = struct {
    registry: inproc.Registry,
    actor: actor_mod.Actor,
    kernel: std.Thread,
    caller: *inproc.Worker,
    budget: *BudgetWorker,

    fn init(gpa: std.mem.Allocator) !*Harness {
        const self = try gpa.create(Harness);
        self.registry = inproc.Registry.init(gpa, null);
        self.actor = try actor_mod.Actor.init(gpa, .{}, self.registry.outbound());
        self.kernel = try std.Thread.spawn(.{}, actor_mod.Actor.run, .{&self.actor});
        self.caller = try inproc.Worker.spawn(gpa, &self.actor, &self.registry, "test-caller");
        self.budget = try BudgetWorker.start(gpa, &self.actor, &self.registry);
        return self;
    }

    fn deinit(self: *Harness) void {
        const gpa = self.actor.gpa;
        self.budget.stop();
        self.caller.stop();
        self.actor.post(.shutdown);
        self.kernel.join();
        self.actor.deinit();
        self.registry.deinit();
        gpa.destroy(self);
    }

    fn callOk(self: *Harness, function: []const u8, request: []const u8) ![]u8 {
        const res = try self.caller.call(function, request);
        errdefer res.deinit(testing.allocator);
        try testing.expect(res == .ok);
        return res.ok;
    }
};

const Checked = struct { ok: bool, used_tokens: u64, max_tokens: ?u64, saved_bytes: u64 };

fn check(h: *Harness, scope: []const u8) !Checked {
    const req = try std.fmt.allocPrint(testing.allocator, "{{\"scope\":\"{s}\"}}", .{scope});
    defer testing.allocator.free(req);
    const payload = try h.callOk("zygos::budget::check", req);
    defer testing.allocator.free(payload);
    var p = try json.parseFromSlice(json.Value, testing.allocator, payload, .{});
    defer p.deinit();
    const obj = p.value.object;
    return .{
        .ok = obj.get("ok").?.bool,
        .used_tokens = @intCast(obj.get("used_tokens").?.integer),
        .max_tokens = if (obj.get("max_tokens")) |v| switch (v) {
            .integer => |n| @intCast(n),
            else => null,
        } else null,
        .saved_bytes = @intCast(obj.get("saved_bytes").?.integer),
    };
}

test "configure + record + check round-trip; ok flips at the limit" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    testing.allocator.free(try h.callOk("zygos::budget::configure", "{\"scope\":\"t1\",\"max_tokens\":10}"));
    testing.allocator.free(try h.callOk("zygos::budget::record", "{\"scope\":\"t1\",\"kind\":\"input_tokens\",\"amount\":6}"));

    const mid = try check(h, "t1");
    try testing.expect(mid.ok);
    try testing.expectEqual(@as(u64, 6), mid.used_tokens);
    try testing.expectEqual(@as(?u64, 10), mid.max_tokens);

    testing.allocator.free(try h.callOk("zygos::budget::record", "{\"scope\":\"t1\",\"kind\":\"output_tokens\",\"amount\":4}"));
    const at_limit = try check(h, "t1");
    try testing.expect(!at_limit.ok); // used == max is over: strict `<`
    try testing.expectEqual(@as(u64, 10), at_limit.used_tokens);
}

test "unconfigured scope accumulates and is always ok with null max" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    testing.allocator.free(try h.callOk("zygos::budget::record", "{\"scope\":\"wild\",\"kind\":\"output_tokens\",\"amount\":999}"));
    const c = try check(h, "wild");
    try testing.expect(c.ok);
    try testing.expectEqual(@as(u64, 999), c.used_tokens);
    try testing.expectEqual(@as(?u64, null), c.max_tokens);
}

test "re-configure resets counters" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    testing.allocator.free(try h.callOk("zygos::budget::configure", "{\"scope\":\"t2\",\"max_tokens\":5}"));
    testing.allocator.free(try h.callOk("zygos::budget::record", "{\"scope\":\"t2\",\"kind\":\"input_tokens\",\"amount\":5}"));
    try testing.expect(!(try check(h, "t2")).ok);

    testing.allocator.free(try h.callOk("zygos::budget::configure", "{\"scope\":\"t2\",\"max_tokens\":5}"));
    const fresh = try check(h, "t2");
    try testing.expect(fresh.ok);
    try testing.expectEqual(@as(u64, 0), fresh.used_tokens);
}

test "saved_bytes accumulates separately and never counts against tokens" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    testing.allocator.free(try h.callOk("zygos::budget::configure", "{\"scope\":\"t3\",\"max_tokens\":10}"));
    testing.allocator.free(try h.callOk("zygos::budget::record", "{\"scope\":\"t3\",\"kind\":\"saved_bytes\",\"amount\":5000}"));

    const c = try check(h, "t3");
    try testing.expect(c.ok);
    try testing.expectEqual(@as(u64, 0), c.used_tokens);
    try testing.expectEqual(@as(u64, 5000), c.saved_bytes);
}

test "unknown kind records nothing and reports ok:false" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const payload = try h.callOk("zygos::budget::record", "{\"scope\":\"t4\",\"kind\":\"vibes\",\"amount\":7}");
    defer testing.allocator.free(payload);
    try testing.expect(std.mem.indexOf(u8, payload, "\"ok\":false") != null);
    try testing.expectEqual(@as(u64, 0), (try check(h, "t4")).used_tokens);
}

test "malformed requests reply ok:false, never a bus error" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    inline for (.{ "zygos::budget::configure", "zygos::budget::record", "zygos::budget::check" }) |f| {
        const payload = try h.callOk(f, "42");
        defer testing.allocator.free(payload);
        try testing.expect(std.mem.indexOf(u8, payload, "\"ok\":false") != null);
    }
}

test "concurrent records from two callers sum exactly" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const second = try inproc.Worker.spawn(testing.allocator, &h.actor, &h.registry, "second-caller");
    defer second.stop();

    const Recorder = struct {
        fn run(w: *inproc.Worker, ok: *bool) void {
            var i: usize = 0;
            while (i < 50) : (i += 1) {
                const res = w.call("zygos::budget::record", "{\"scope\":\"conc\",\"kind\":\"input_tokens\",\"amount\":1}") catch return;
                defer res.deinit(w.gpa);
                if (res != .ok) return;
            }
            ok.* = true;
        }
    };
    var ok_a = false;
    var ok_b = false;
    const t1 = try std.Thread.spawn(.{}, Recorder.run, .{ h.caller, &ok_a });
    const t2 = try std.Thread.spawn(.{}, Recorder.run, .{ second, &ok_b });
    t1.join();
    t2.join();
    try testing.expect(ok_a and ok_b);
    try testing.expectEqual(@as(u64, 100), (try check(h, "conc")).used_tokens);
}

test "no leaks under record loops" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const res = try h.caller.call("zygos::budget::record", "{\"scope\":\"loop\",\"kind\":\"output_tokens\",\"amount\":2}");
        res.deinit(testing.allocator);
    }
}
