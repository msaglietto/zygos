//! Zygos invocation router (S3). Implements GOAL.md criterion S3 and
//! PROTOCOL.md semantics 1 (correlation): pending entries parked on dispatch,
//! completed by uuid-correlated results, timed out by injected-time sweeps.
//!
//! Kernel-actor-owned and single-threaded — no locks (docs/specs/catalog.md
//! threading rationale). The ONLY cross-thread object is `Waiter`
//! (sync.ResetEvent handoff). No clock reads: every time-dependent function
//! takes `now_ms`; tests inject time and never sleep.
//!
//! This module must not import protocol.zig or catalog.zig. ErrorBody
//! synthesis (timeout / worker_disconnected frames) is the actor's job —
//! sweeps/failures only invoke callbacks with (id, reply_target).

const std = @import("std");
const types = @import("types.zig");
const sync = @import("sync.zig");

pub const WorkerId = types.WorkerId;
pub const Uuid = types.Uuid;

/// Result payload handed to an in-process waiter. Slices are NOT owned by the
/// Waiter — the completing side guarantees their lifetime until the waiter
/// wakes and copies what it needs.
pub const Outcome = union(enum) {
    ok: []const u8,
    err: []const u8,
};

/// In-process blocking caller (builtin worker, tests). Handoff rule: the
/// actor writes `result`, then `event.set()`; the waiting thread reads only
/// after `event.wait()` returns (the event's mutex publishes the write).
pub const Waiter = struct {
    event: sync.ResetEvent = .{},
    result: ?Outcome = null,

    pub fn deinit(self: *Waiter) void {
        self.event.deinit();
    }
};

/// Where a completed invocation's result is routed (spec decision 2:
/// completion is routing, not futures).
pub const ReplyTarget = union(enum) {
    /// Forward the invocationresult frame to this caller's writer queue.
    connection: WorkerId,
    /// Wake an in-process blocking caller.
    waiter: *Waiter,
    /// Fire-and-forget with an id we still track (rare).
    none,
};

/// One parked call. `generation` guards the lazy-deletion heap: a Uuid may be
/// re-added after its first pending completes, and the stale heap entry must
/// not time out the new pending.
const Pending = struct {
    callee: WorkerId,
    reply: ReplyTarget,
    deadline_ms: i64,
    generation: u64,
};

const HeapEntry = struct {
    deadline_ms: i64,
    id: Uuid,
    generation: u64,
};

fn lessByDeadline(context: void, a: HeapEntry, b: HeapEntry) std.math.Order {
    _ = context;
    return std.math.order(a.deadline_ms, b.deadline_ms);
}

const DeadlineHeap = std.PriorityQueue(HeapEntry, void, lessByDeadline);

pub const Invocations = struct {
    gpa: std.mem.Allocator,
    pending: std.AutoHashMap(Uuid, Pending),
    /// Min-heap on deadline with lazy deletion: completed/failed/dropped
    /// entries linger here and are skipped on sweep via map presence +
    /// generation checks. Never double-completes.
    heap: DeadlineHeap,
    next_gen: u64,

    pub fn init(gpa: std.mem.Allocator) Invocations {
        return .{
            .gpa = gpa,
            .pending = std.AutoHashMap(Uuid, Pending).init(gpa),
            .heap = .empty,
            .next_gen = 0,
        };
    }

    pub fn deinit(self: *Invocations) void {
        self.pending.deinit();
        self.heap.deinit(self.gpa);
    }

    /// Park a pending call. `deadline_ms` is absolute (caller computes
    /// now + timeout).
    pub fn add(
        self: *Invocations,
        id: Uuid,
        callee: WorkerId,
        reply: ReplyTarget,
        deadline_ms: i64,
    ) error{ OutOfMemory, DuplicateId }!void {
        if (self.pending.contains(id)) return error.DuplicateId;

        const gen = self.next_gen;
        self.next_gen += 1;

        try self.pending.put(id, .{
            .callee = callee,
            .reply = reply,
            .deadline_ms = deadline_ms,
            .generation = gen,
        });
        errdefer _ = self.pending.remove(id);

        try self.heap.push(self.gpa, .{
            .deadline_ms = deadline_ms,
            .id = id,
            .generation = gen,
        });
    }

    /// Correlate a result. Returns the ReplyTarget to route to, or null if
    /// unknown/already-completed — the caller logs & drops, never crashes
    /// (PROTOCOL.md §1). The stale heap entry is skipped on sweep.
    pub fn complete(self: *Invocations, id: Uuid) ?ReplyTarget {
        const removed = self.pending.fetchRemove(id) orelse return null;
        return removed.value.reply;
    }

    /// Fire timeouts: for every entry with deadline <= now_ms, remove it and
    /// invoke `on_timeout(ctx, id, reply)` so the actor can synthesize an
    /// invocationresult with ErrorBody{code="timeout"}. Lazy-deletion safe.
    pub fn sweepExpired(
        self: *Invocations,
        now_ms: i64,
        ctx: anytype,
        comptime on_timeout: fn (@TypeOf(ctx), Uuid, ReplyTarget) void,
    ) usize {
        var fired: usize = 0;
        while (self.heap.peek()) |min| {
            if (min.deadline_ms > now_ms) break;
            const entry = self.heap.pop().?;

            // Lazy deletion: only a live pending of the same generation fires.
            const live = self.pending.get(entry.id) orelse continue;
            if (live.generation != entry.generation) continue;

            _ = self.pending.remove(entry.id);
            on_timeout(ctx, entry.id, live.reply);
            fired += 1;
        }
        return fired;
    }

    /// Callee died: complete each of its pendings via `on_fail` (the actor
    /// sends a worker_disconnected error to the reply target). Returns count.
    pub fn failAllForCallee(
        self: *Invocations,
        callee: WorkerId,
        ctx: anytype,
        comptime on_fail: fn (@TypeOf(ctx), Uuid, ReplyTarget) void,
    ) usize {
        // Collect first — the map must not be mutated mid-iteration.
        var to_fail: std.ArrayList(Uuid) = .empty;
        defer to_fail.deinit(self.gpa);

        var it = self.pending.iterator();
        while (it.next()) |kv| {
            if (std.mem.eql(u8, &kv.value_ptr.callee, &callee)) {
                to_fail.append(self.gpa, kv.key_ptr.*) catch break;
            }
        }

        for (to_fail.items) |id| {
            const removed = self.pending.fetchRemove(id) orelse continue;
            on_fail(ctx, id, removed.value.reply);
        }
        return to_fail.items.len;
    }

    /// Caller died: silently drop all pendings whose reply target is that
    /// connection. Waiter/none targets are unaffected. Returns count.
    pub fn dropAllForCaller(self: *Invocations, caller: WorkerId) usize {
        var to_drop: std.ArrayList(Uuid) = .empty;
        defer to_drop.deinit(self.gpa);

        var it = self.pending.iterator();
        while (it.next()) |kv| {
            switch (kv.value_ptr.reply) {
                .connection => |conn| {
                    if (std.mem.eql(u8, &conn, &caller)) {
                        to_drop.append(self.gpa, kv.key_ptr.*) catch break;
                    }
                },
                .waiter, .none => {},
            }
        }

        for (to_drop.items) |id| _ = self.pending.remove(id);
        return to_drop.items.len;
    }

    pub fn count(self: *const Invocations) usize {
        return self.pending.count();
    }
};

// ===========================================================================
// Tests (docs/specs/invocation.md test contract, named exactly)
// ===========================================================================

const testing = std.testing;

fn uuidOf(n: u8) Uuid {
    return [_]u8{n} ** 16;
}

fn widOf(n: u8) WorkerId {
    return [_]u8{n} ** 16;
}

/// Callback recorder shared by sweep/fail tests.
const Recorder = struct {
    fired: usize = 0,
    last_id: ?Uuid = null,
    last_reply: ?ReplyTarget = null,

    fn onFire(self: *Recorder, id: Uuid, reply: ReplyTarget) void {
        self.fired += 1;
        self.last_id = id;
        self.last_reply = reply;
    }
};

test "add then complete returns the reply target and removes the entry" {
    var inv = Invocations.init(testing.allocator);
    defer inv.deinit();

    try inv.add(uuidOf(1), widOf(2), .{ .connection = widOf(3) }, 1_000);
    try testing.expectEqual(@as(usize, 1), inv.count());

    const reply = inv.complete(uuidOf(1)) orelse return error.TestUnexpectedResult;
    try testing.expect(reply == .connection);
    try testing.expect(std.mem.eql(u8, &reply.connection, &widOf(3)));
    try testing.expectEqual(@as(usize, 0), inv.count());
}

test "complete unknown id returns null" {
    var inv = Invocations.init(testing.allocator);
    defer inv.deinit();
    try testing.expect(inv.complete(uuidOf(9)) == null);
}

test "duplicate complete returns null the second time" {
    var inv = Invocations.init(testing.allocator);
    defer inv.deinit();

    try inv.add(uuidOf(1), widOf(2), .none, 1_000);
    try testing.expect(inv.complete(uuidOf(1)) != null);
    try testing.expect(inv.complete(uuidOf(1)) == null);
}

test "add with duplicate id returns DuplicateId" {
    var inv = Invocations.init(testing.allocator);
    defer inv.deinit();

    try inv.add(uuidOf(1), widOf(2), .none, 1_000);
    try testing.expectError(error.DuplicateId, inv.add(uuidOf(1), widOf(2), .none, 2_000));
}

test "sweepExpired fires only entries at or past the deadline" {
    var inv = Invocations.init(testing.allocator);
    defer inv.deinit();

    try inv.add(uuidOf(1), widOf(9), .none, 100);
    try inv.add(uuidOf(2), widOf(9), .none, 200);
    try inv.add(uuidOf(3), widOf(9), .none, 300);

    var rec: Recorder = .{};
    const fired = inv.sweepExpired(200, &rec, Recorder.onFire);
    try testing.expectEqual(@as(usize, 2), fired);
    try testing.expectEqual(@as(usize, 2), rec.fired);
    try testing.expectEqual(@as(usize, 1), inv.count());
    // The survivor is the 300-deadline entry.
    try testing.expect(inv.complete(uuidOf(3)) != null);
}

test "late result after timeout returns null" {
    var inv = Invocations.init(testing.allocator);
    defer inv.deinit();

    try inv.add(uuidOf(1), widOf(9), .none, 100);
    var rec: Recorder = .{};
    _ = inv.sweepExpired(200, &rec, Recorder.onFire);
    try testing.expectEqual(@as(usize, 1), rec.fired);

    try testing.expect(inv.complete(uuidOf(1)) == null);
}

test "completed entry never times out" {
    var inv = Invocations.init(testing.allocator);
    defer inv.deinit();

    try inv.add(uuidOf(1), widOf(9), .none, 100);
    _ = inv.complete(uuidOf(1));

    var rec: Recorder = .{};
    const fired = inv.sweepExpired(10_000, &rec, Recorder.onFire);
    try testing.expectEqual(@as(usize, 0), fired);
    try testing.expectEqual(@as(usize, 0), rec.fired);
}

test "failAllForCallee completes only that callee's pendings" {
    var inv = Invocations.init(testing.allocator);
    defer inv.deinit();

    try inv.add(uuidOf(1), widOf(7), .{ .connection = widOf(1) }, 1_000);
    try inv.add(uuidOf(2), widOf(7), .{ .connection = widOf(2) }, 1_000);
    try inv.add(uuidOf(3), widOf(8), .{ .connection = widOf(3) }, 1_000);

    var rec: Recorder = .{};
    const failed = inv.failAllForCallee(widOf(7), &rec, Recorder.onFire);
    try testing.expectEqual(@as(usize, 2), failed);
    try testing.expectEqual(@as(usize, 2), rec.fired);
    try testing.expectEqual(@as(usize, 1), inv.count());
    // The other callee's pending is intact and completable.
    try testing.expect(inv.complete(uuidOf(3)) != null);
}

test "dropAllForCaller drops silently and only for that caller" {
    var inv = Invocations.init(testing.allocator);
    defer inv.deinit();

    try inv.add(uuidOf(1), widOf(9), .{ .connection = widOf(5) }, 1_000);
    try inv.add(uuidOf(2), widOf(9), .{ .connection = widOf(5) }, 1_000);
    try inv.add(uuidOf(3), widOf(9), .{ .connection = widOf(6) }, 1_000);
    var w: Waiter = .{};
    defer w.deinit();
    try inv.add(uuidOf(4), widOf(9), .{ .waiter = &w }, 1_000);

    const dropped = inv.dropAllForCaller(widOf(5));
    try testing.expectEqual(@as(usize, 2), dropped);
    try testing.expectEqual(@as(usize, 2), inv.count());
    // Waiter-target and other-caller pendings survive.
    try testing.expect(inv.complete(uuidOf(3)) != null);
    try testing.expect(inv.complete(uuidOf(4)) != null);
}

test "waiter handoff: result slot visible after event set" {
    var inv = Invocations.init(testing.allocator);
    defer inv.deinit();

    const Ctx = struct {
        waiter: Waiter = .{},
        copied: [16]u8 = undefined,
        copied_len: usize = 0,

        fn blockingCaller(self: *@This()) void {
            self.waiter.event.wait();
            // Handoff rule: read the slot only after wait() returns.
            const outcome = self.waiter.result.?;
            const bytes = outcome.ok;
            @memcpy(self.copied[0..bytes.len], bytes);
            self.copied_len = bytes.len;
        }
    };
    var ctx: Ctx = .{};
    defer ctx.waiter.deinit();

    try inv.add(uuidOf(1), widOf(9), .{ .waiter = &ctx.waiter }, 1_000);
    const t = try std.Thread.spawn(.{}, Ctx.blockingCaller, .{&ctx});

    // Actor side: correlate, write the slot, then set the event.
    const reply = inv.complete(uuidOf(1)).?;
    const w = reply.waiter;
    w.result = .{ .ok = "done" };
    w.event.set();

    t.join(); // bounded by set(); no sleeps anywhere
    try testing.expectEqualStrings("done", ctx.copied[0..ctx.copied_len]);
}

test "no leaks under add/complete and add/sweep loops" {
    var inv = Invocations.init(testing.allocator);
    defer inv.deinit();

    var i: u8 = 0;
    while (i < 100) : (i += 1) {
        try inv.add(uuidOf(i), widOf(1), .none, 1_000);
        try testing.expect(inv.complete(uuidOf(i)) != null);
    }
    try testing.expectEqual(@as(usize, 0), inv.count());

    var rec: Recorder = .{};
    i = 0;
    while (i < 100) : (i += 1) {
        try inv.add(uuidOf(i), widOf(1), .none, @as(i64, i));
    }
    const fired = inv.sweepExpired(1_000, &rec, Recorder.onFire);
    try testing.expectEqual(@as(usize, 100), fired);
    try testing.expectEqual(@as(usize, 0), inv.count());
}
