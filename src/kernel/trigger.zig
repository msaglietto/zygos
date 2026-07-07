//! Zygos trigger registry (S4). Implements GOAL.md criterion S4 and
//! PROTOCOL.md semantics 4 (type replay), 5 (trigger ownership), 6
//! (registration acks). Kernel-actor-owned, single-threaded, no locks.
//! No clock reads — time-dependent functions take `now_ms`.
//!
//! This module knows nothing of sockets, wire parsing, or the catalog; it
//! must not import protocol.zig, catalog.zig, or invocation.zig. Only
//! types.zig is shared (WorkerId).

const std = @import("std");
const types = @import("types.zig");

// ---------------------------------------------------------------------------
// Re-exported identity types (module independence rule, AGENTS.md)
// ---------------------------------------------------------------------------

pub const WorkerId = types.WorkerId;

/// The type-owner worker the actor must forward the binding frame to.
pub const ForwardTo = types.WorkerId;

/// Outcome of `completeAck`.
pub const AckOutcome = enum { completed, failed_binding_removed, unknown };

// ---------------------------------------------------------------------------
// Data model
// ---------------------------------------------------------------------------

/// A registered trigger type. All `[]const u8` fields are owned copies
/// (duped on insert, freed on overwrite/remove/deinit). Schemas stay raw
/// JSON text — the registry never interprets them.
pub const TriggerType = struct {
    owner: WorkerId,
    description: []const u8,
    trigger_request_format: ?[]const u8 = null,
    call_request_format: ?[]const u8 = null,
};

/// Input to `registerType`: same shape as `TriggerType` but all slices are
/// **borrowed** from the caller for the duration of the call only.
/// `registerType` dupes everything it stores.
pub const TypeInit = struct {
    owner: WorkerId,
    description: []const u8,
    trigger_request_format: ?[]const u8 = null,
    call_request_format: ?[]const u8 = null,
};

/// A trigger binding keyed by id. All `[]const u8` fields are owned copies.
/// `owner == null` means durable (survives disconnects); `owner != null`
/// means connection-owned (GC'd when that connection drops).
pub const Binding = struct {
    trigger_type: []const u8,
    function_id: []const u8,
    config: []const u8,
    owner: ?WorkerId,
    metadata: ?[]const u8 = null,
};

/// Input to `registerBinding`: borrowed-slice variant of `Binding`.
pub const BindingInit = struct {
    trigger_type: []const u8,
    function_id: []const u8,
    config: []const u8,
    owner: ?WorkerId,
    metadata: ?[]const u8 = null,
};

// ---------------------------------------------------------------------------
// Internal types: pending-ack map + deadline heap
//
// The ack deadline heap uses lazy deletion (identical pattern to the
// invocation spec): entries popped during `sweepExpiredAcks` are validated
// against the live ack map before firing. A `generation` counter guards
// against id reuse — when a binding id is removed and re-registered as
// durable, the old heap entry must not fire for the new ack. Each new ack
// gets a unique generation; the heap entry carries the generation it was
// created with, and sweep skips entries whose generation no longer matches.
// ---------------------------------------------------------------------------

const PendingAck = struct {
    deadline_ms: i64,
    generation: u64,
};

/// One node in the deadline min-heap. `binding_id` is an **owned** copy so
/// it never dangles when the ack map key is freed (the heap entry outlives
/// the ack it references). Freed on pop (sweep) or deinit.
const AckHeapEntry = struct {
    deadline_ms: i64,
    binding_id: []const u8,
    generation: u64,
};

fn lessByDeadline(context: void, a: AckHeapEntry, b: AckHeapEntry) std.math.Order {
    _ = context;
    return std.math.order(a.deadline_ms, b.deadline_ms);
}

const AckHeap = std.PriorityQueue(AckHeapEntry, void, lessByDeadline);

// ---------------------------------------------------------------------------
// Memory helpers
// ---------------------------------------------------------------------------

fn dupeTriggerType(gpa: std.mem.Allocator, t: TypeInit) error{OutOfMemory}!TriggerType {
    const description = try gpa.dupe(u8, t.description);
    errdefer gpa.free(description);

    const trigger_request_format = if (t.trigger_request_format) |s|
        try gpa.dupe(u8, s)
    else
        null;
    errdefer if (trigger_request_format) |s| gpa.free(s);

    const call_request_format = if (t.call_request_format) |s|
        try gpa.dupe(u8, s)
    else
        null;

    return .{
        .owner = t.owner,
        .description = description,
        .trigger_request_format = trigger_request_format,
        .call_request_format = call_request_format,
    };
}

fn freeTriggerType(gpa: std.mem.Allocator, t: TriggerType) void {
    gpa.free(t.description);
    if (t.trigger_request_format) |s| gpa.free(s);
    if (t.call_request_format) |s| gpa.free(s);
}

fn dupeBinding(gpa: std.mem.Allocator, b: BindingInit) error{OutOfMemory}!Binding {
    const trigger_type = try gpa.dupe(u8, b.trigger_type);
    errdefer gpa.free(trigger_type);

    const function_id = try gpa.dupe(u8, b.function_id);
    errdefer gpa.free(function_id);

    const config = try gpa.dupe(u8, b.config);
    errdefer gpa.free(config);

    const metadata = if (b.metadata) |s| try gpa.dupe(u8, s) else null;

    return .{
        .trigger_type = trigger_type,
        .function_id = function_id,
        .config = config,
        .owner = b.owner,
        .metadata = metadata,
    };
}

fn freeBinding(gpa: std.mem.Allocator, b: Binding) void {
    gpa.free(b.trigger_type);
    gpa.free(b.function_id);
    gpa.free(b.config);
    if (b.metadata) |s| gpa.free(s);
}

// ---------------------------------------------------------------------------
// Triggers
// ---------------------------------------------------------------------------

pub const Triggers = struct {
    gpa: std.mem.Allocator,
    types: std.StringHashMap(TriggerType),
    bindings: std.StringHashMap(Binding),
    acks: std.StringHashMap(PendingAck),
    ack_heap: AckHeap,
    /// Monotonic counter for ack generation guards (see module comment).
    next_gen: u64,

    pub fn init(gpa: std.mem.Allocator) Triggers {
        return .{
            .gpa = gpa,
            .types = std.StringHashMap(TriggerType).init(gpa),
            .bindings = std.StringHashMap(Binding).init(gpa),
            .acks = std.StringHashMap(PendingAck).init(gpa),
            .ack_heap = .empty,
            .next_gen = 0,
        };
    }

    pub fn deinit(self: *Triggers) void {
        // Free all binding entries (key + owned value).
        var bind_it = self.bindings.iterator();
        while (bind_it.next()) |kv| {
            freeBinding(self.gpa, kv.value_ptr.*);
            self.gpa.free(kv.key_ptr.*);
        }
        self.bindings.deinit();

        // Free all ack keys (values are plain structs).
        var ack_it = self.acks.iterator();
        while (ack_it.next()) |kv| {
            self.gpa.free(kv.key_ptr.*);
        }
        self.acks.deinit();

        // Free all type entries (key + owned value).
        var type_it = self.types.iterator();
        while (type_it.next()) |kv| {
            freeTriggerType(self.gpa, kv.value_ptr.*);
            self.gpa.free(kv.key_ptr.*);
        }
        self.types.deinit();

        // Free each heap entry's owned binding_id copy, then the backing buffer.
        for (self.ack_heap.items) |entry| {
            self.gpa.free(entry.binding_id);
        }
        self.ack_heap.deinit(self.gpa);
    }

    /// Last-wins type registration. Re-registering an existing type id
    /// replaces owner/formats and returns the list of existing binding ids
    /// of that type so the actor can re-forward them to the new owner
    /// (PROTOCOL.md §4, provider-reconnect support).
    ///
    /// Lifetime: the appended slices point at the registry's OWN stored
    /// binding-id keys. They are valid only until the next mutation of the
    /// registry. The actor consumes them immediately (forwards each binding
    /// to the new owner) and must not retain them across mutations.
    pub fn registerType(
        self: *Triggers,
        id: []const u8,
        t: TypeInit,
        replay: *std.ArrayList([]const u8),
    ) error{OutOfMemory}!enum { new, replaced } {
        if (self.types.getPtr(id)) |existing| {
            // Dupe new data before freeing old (clean rollback on error).
            const new_type = try dupeTriggerType(self.gpa, t);
            freeTriggerType(self.gpa, existing.*);
            existing.* = new_type;

            // Collect replay set: all bindings whose trigger_type == id.
            var it = self.bindings.iterator();
            while (it.next()) |kv| {
                if (std.mem.eql(u8, kv.value_ptr.trigger_type, id)) {
                    try replay.append(self.gpa, kv.key_ptr.*);
                }
            }
            return .replaced;
        }

        // New type — dupe id + data.
        const owned_id = try self.gpa.dupe(u8, id);
        errdefer self.gpa.free(owned_id);

        const new_type = try dupeTriggerType(self.gpa, t);
        errdefer freeTriggerType(self.gpa, new_type);

        try self.types.put(owned_id, new_type);
        return .new;
    }

    /// Register a binding. With a known type → returns the type owner
    /// (ForwardTo) so the actor can forward the binding frame. Unknown type
    /// → `error.UnknownTriggerType`; duplicate id → `error.DuplicateId`.
    /// Nothing is stored on either error.
    ///
    /// A durable binding (`owner == null`) parks a pending ack that the
    /// actor completes via `completeAck` or `sweepExpiredAcks` fails at
    /// deadline (PROTOCOL.md §6). Connection-owned bindings are
    /// fire-and-forget. `ack_deadline_ms` is an absolute deadline computed
    /// by the caller (`now_ms + 10_000`); `null` ⇒ never expires via sweep.
    pub fn registerBinding(
        self: *Triggers,
        id: []const u8,
        b: BindingInit,
        ack_deadline_ms: ?i64,
    ) error{ OutOfMemory, UnknownTriggerType, DuplicateId }!ForwardTo {
        // Type must exist.
        const type_entry = self.types.getPtr(b.trigger_type) orelse
            return error.UnknownTriggerType;
        const type_owner = type_entry.owner;

        // Id must be unique.
        if (self.bindings.contains(id)) return error.DuplicateId;

        // Dupe and store binding.
        const owned_id = try self.gpa.dupe(u8, id);
        errdefer self.gpa.free(owned_id);

        const new_binding = try dupeBinding(self.gpa, b);
        errdefer freeBinding(self.gpa, new_binding);

        try self.bindings.put(owned_id, new_binding);
        errdefer _ = self.bindings.fetchRemove(owned_id);

        // Durable bindings park a pending ack.
        if (b.owner == null) {
            const deadline = ack_deadline_ms orelse std.math.maxInt(i64);
            const gen = self.next_gen;
            self.next_gen += 1;

            const ack_key = try self.gpa.dupe(u8, id);
            errdefer self.gpa.free(ack_key);

            try self.acks.put(ack_key, .{ .deadline_ms = deadline, .generation = gen });
            errdefer _ = self.acks.fetchRemove(ack_key);

            // Heap entry owns its own binding-id copy (see AckHeapEntry doc).
            const heap_id = try self.gpa.dupe(u8, id);
            errdefer self.gpa.free(heap_id);

            try self.ack_heap.push(self.gpa, .{
                .deadline_ms = deadline,
                .binding_id = heap_id,
                .generation = gen,
            });
        }

        return type_owner;
    }

    /// Complete (or fail) a pending ack. `failed == false` keeps the
    /// binding; `failed == true` drops it and reports error
    /// (PROTOCOL.md §6). Returns `.unknown` for late/duplicate acks (log,
    /// don't crash — same rule as invocation correlation).
    pub fn completeAck(self: *Triggers, binding_id: []const u8, failed: bool) AckOutcome {
        // Remove the ack. The stale heap entry is skipped during sweep via
        // the generation check (lazy deletion).
        const removed = self.acks.fetchRemove(binding_id) orelse return .unknown;
        self.gpa.free(removed.key);

        if (failed) {
            if (self.bindings.fetchRemove(binding_id)) |b| {
                freeBinding(self.gpa, b.value);
                self.gpa.free(b.key);
            }
            return .failed_binding_removed;
        }
        return .completed;
    }

    /// Pop every ack whose deadline ≤ `now_ms`, removing the binding **before**
    /// firing the callback (PROTOCOL.md §6). Returns the number expired.
    /// Stale heap entries (ack already gone or generation mismatch) are
    /// silently skipped — lazy deletion.
    pub fn sweepExpiredAcks(
        self: *Triggers,
        now_ms: i64,
        ctx: anytype,
        comptime on_expired: fn (@TypeOf(ctx), []const u8) void,
    ) usize {
        var fired: usize = 0;
        while (self.ack_heap.peek()) |min| {
            if (min.deadline_ms > now_ms) break;

            const entry = self.ack_heap.pop().?;
            // Free the heap entry's owned binding-id at scope exit (covers
            // both `continue` and the normal path).
            defer self.gpa.free(entry.binding_id);

            // Lazy deletion: validate against the live ack map.
            const ack = self.acks.getPtr(entry.binding_id) orelse continue;
            if (ack.generation != entry.generation) continue;

            // Expired — remove binding first, then ack, then fire callback.
            if (self.bindings.fetchRemove(entry.binding_id)) |removed| {
                freeBinding(self.gpa, removed.value);
                self.gpa.free(removed.key);
            }
            if (self.acks.fetchRemove(entry.binding_id)) |removed| {
                self.gpa.free(removed.key);
            }

            on_expired(ctx, entry.binding_id);
            fired += 1;
        }
        return fired;
    }

    /// Remove a binding by id. `trigger_type` is an optional consistency
    /// check: if provided and it doesn't match the stored type, the call is
    /// a no-op returning false (PROTOCOL.md optional field semantics).
    pub fn unregisterBinding(self: *Triggers, id: []const u8, trigger_type: ?[]const u8) bool {
        const b = self.bindings.getPtr(id) orelse return false;
        if (trigger_type) |tt| {
            if (!std.mem.eql(u8, b.trigger_type, tt)) return false;
        }
        self.removeBindingAndAck(id);
        return true;
    }

    /// Disconnect GC (PROTOCOL.md §5): remove bindings whose `owner ==
    /// departing`; durable bindings (`owner == null`) survive. Types owned
    /// by the departing worker **stay** registered (bindings must survive
    /// to be replayed on reconnect). Returns the removed binding count.
    pub fn unregisterWorker(self: *Triggers, departing: WorkerId) usize {
        // Collect ids first — can't mutate the map during iteration.
        // The collected slices alias the bindings map's owned keys; they
        // remain valid until we call fetchRemove on each.
        var to_remove: std.ArrayList([]const u8) = .empty;
        defer to_remove.deinit(self.gpa);

        var it = self.bindings.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.owner) |owner| {
                if (std.mem.eql(u8, &owner, &departing)) {
                    to_remove.append(self.gpa, kv.key_ptr.*) catch break;
                }
            }
        }

        var removed: usize = 0;
        for (to_remove.items) |id| {
            self.removeBindingAndAck(id);
            removed += 1;
        }
        return removed;
    }

    pub fn typeOwner(self: *const Triggers, type_id: []const u8) ?WorkerId {
        const t = self.types.getPtr(type_id) orelse return null;
        return t.owner;
    }

    pub fn binding(self: *const Triggers, id: []const u8) ?*const Binding {
        return self.bindings.getPtr(id);
    }

    pub fn countBindings(self: *const Triggers) usize {
        return self.bindings.count();
    }

    /// Remove a binding and its pending ack (if any), freeing all owned
    /// memory. The corresponding heap entry (if any) becomes stale and is
    /// skipped during sweep via the generation check.
    fn removeBindingAndAck(self: *Triggers, id: []const u8) void {
        if (self.bindings.fetchRemove(id)) |removed| {
            freeBinding(self.gpa, removed.value);
            self.gpa.free(removed.key);
        }
        if (self.acks.fetchRemove(id)) |removed| {
            self.gpa.free(removed.key);
        }
    }
};

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

fn makeWorker(comptime byte: u8) WorkerId {
    return [_]u8{byte} ** 16;
}

const worker_a = makeWorker(0xAA);
const worker_b = makeWorker(0xBB);

/// Callback context for sweep tests. The callback receives a `binding_id`
/// that is only valid for the duration of the call (the sweep frees it
/// immediately after), so we check content during the call rather than
/// storing the pointer.
const ExpiredCtx = struct {
    fired: usize = 0,
    saw_b1: bool = false,
};

fn onExpiredCb(ctx: *ExpiredCtx, binding_id: []const u8) void {
    ctx.fired += 1;
    if (std.mem.eql(u8, binding_id, "b1")) ctx.saw_b1 = true;
}

// 1 -----------------------------------------------------------------------

test "registerType new; typeOwner resolves" {
    var tr = Triggers.init(testing.allocator);
    defer tr.deinit();

    var replay: std.ArrayList([]const u8) = .empty;
    defer replay.deinit(testing.allocator);

    const result = try tr.registerType("cron", .{
        .owner = worker_a,
        .description = "cron trigger",
    }, &replay);
    try testing.expect(result == .new);
    try testing.expectEqual(worker_a, tr.typeOwner("cron").?);
    try testing.expectEqual(@as(usize, 0), replay.items.len);
}

// 2 -----------------------------------------------------------------------

test "registerType replace returns replay set of existing bindings" {
    var tr = Triggers.init(testing.allocator);
    defer tr.deinit();

    var replay: std.ArrayList([]const u8) = .empty;

    // Register both types.
    _ = try tr.registerType("cron", .{ .owner = worker_a, .description = "c" }, &replay);
    _ = try tr.registerType("http", .{ .owner = worker_a, .description = "h" }, &replay);

    // 2 bindings of type cron + 1 of type http.
    _ = try tr.registerBinding("c1", .{
        .trigger_type = "cron",
        .function_id = "fn",
        .config = "{}",
        .owner = null,
    }, 99_999);
    _ = try tr.registerBinding("c2", .{
        .trigger_type = "cron",
        .function_id = "fn",
        .config = "{}",
        .owner = null,
    }, 99_999);
    _ = try tr.registerBinding("h1", .{
        .trigger_type = "http",
        .function_id = "fn",
        .config = "{}",
        .owner = null,
    }, 99_999);

    // Re-register cron → replay should contain exactly the 2 cron bindings.
    const result = try tr.registerType("cron", .{
        .owner = worker_b,
        .description = "cron-v2",
    }, &replay);
    defer replay.deinit(testing.allocator);

    try testing.expect(result == .replaced);
    try testing.expectEqual(@as(usize, 2), replay.items.len);

    // Both ids should be present (order is unspecified).
    var found_c1 = false;
    var found_c2 = false;
    for (replay.items) |bid| {
        if (std.mem.eql(u8, bid, "c1")) found_c1 = true;
        if (std.mem.eql(u8, bid, "c2")) found_c2 = true;
    }
    try testing.expect(found_c1);
    try testing.expect(found_c2);

    // Owner is now worker_b.
    try testing.expectEqual(worker_b, tr.typeOwner("cron").?);

    // Clean up pending acks so deinit has nothing to sweep.
    _ = tr.completeAck("c1", true);
    _ = tr.completeAck("c2", true);
    _ = tr.completeAck("h1", true);
}

// 3 -----------------------------------------------------------------------

test "registerBinding known type returns the type owner to forward to" {
    var tr = Triggers.init(testing.allocator);
    defer tr.deinit();

    var replay: std.ArrayList([]const u8) = .empty;
    defer replay.deinit(testing.allocator);

    _ = try tr.registerType("cron", .{ .owner = worker_a, .description = "c" }, &replay);

    const fwd = try tr.registerBinding("b1", .{
        .trigger_type = "cron",
        .function_id = "fn-1",
        .config = "{}",
        .owner = worker_a,
    }, null);
    try testing.expectEqual(worker_a, fwd);
    try testing.expectEqual(@as(usize, 1), tr.countBindings());
}

// 4 -----------------------------------------------------------------------

test "registerBinding unknown type errors; nothing stored" {
    var tr = Triggers.init(testing.allocator);
    defer tr.deinit();

    try testing.expectError(error.UnknownTriggerType, tr.registerBinding("b1", .{
        .trigger_type = "nope",
        .function_id = "fn",
        .config = "{}",
        .owner = null,
    }, 99_999));
    try testing.expectEqual(@as(usize, 0), tr.countBindings());
    try testing.expect(tr.binding("b1") == null);
}

// 5 -----------------------------------------------------------------------

test "duplicate binding id errors" {
    var tr = Triggers.init(testing.allocator);
    defer tr.deinit();

    var replay: std.ArrayList([]const u8) = .empty;
    defer replay.deinit(testing.allocator);

    _ = try tr.registerType("cron", .{ .owner = worker_a, .description = "c" }, &replay);

    _ = try tr.registerBinding("b1", .{
        .trigger_type = "cron",
        .function_id = "fn",
        .config = "{}",
        .owner = worker_a,
    }, null);

    try testing.expectError(error.DuplicateId, tr.registerBinding("b1", .{
        .trigger_type = "cron",
        .function_id = "fn2",
        .config = "{}",
        .owner = worker_a,
    }, null));
    try testing.expectEqual(@as(usize, 1), tr.countBindings());
}

// 6 -----------------------------------------------------------------------

test "durable binding parks an ack; completeAck(ok) keeps the binding" {
    var tr = Triggers.init(testing.allocator);
    defer tr.deinit();

    var replay: std.ArrayList([]const u8) = .empty;
    defer replay.deinit(testing.allocator);

    _ = try tr.registerType("cron", .{ .owner = worker_a, .description = "c" }, &replay);
    _ = try tr.registerBinding("b1", .{
        .trigger_type = "cron",
        .function_id = "fn",
        .config = "{}",
        .owner = null,
    }, 99_999);

    const outcome = tr.completeAck("b1", false);
    try testing.expect(outcome == .completed);

    // Binding survives a successful ack.
    try testing.expect(tr.binding("b1") != null);
    try testing.expectEqual(@as(usize, 1), tr.countBindings());
}

// 7 -----------------------------------------------------------------------

test "completeAck(failed) removes the binding" {
    var tr = Triggers.init(testing.allocator);
    defer tr.deinit();

    var replay: std.ArrayList([]const u8) = .empty;
    defer replay.deinit(testing.allocator);

    _ = try tr.registerType("cron", .{ .owner = worker_a, .description = "c" }, &replay);
    _ = try tr.registerBinding("b1", .{
        .trigger_type = "cron",
        .function_id = "fn",
        .config = "{}",
        .owner = null,
    }, 99_999);

    const outcome = tr.completeAck("b1", true);
    try testing.expect(outcome == .failed_binding_removed);

    try testing.expect(tr.binding("b1") == null);
    try testing.expectEqual(@as(usize, 0), tr.countBindings());
}

// 8 -----------------------------------------------------------------------

test "ack timeout removes binding then fires callback" {
    var tr = Triggers.init(testing.allocator);
    defer tr.deinit();

    var replay: std.ArrayList([]const u8) = .empty;
    defer replay.deinit(testing.allocator);

    _ = try tr.registerType("cron", .{ .owner = worker_a, .description = "c" }, &replay);
    _ = try tr.registerBinding("b1", .{
        .trigger_type = "cron",
        .function_id = "fn",
        .config = "{}",
        .owner = null,
    }, 1_000); // absolute deadline

    // Sweep well past the deadline.
    var expired_ctx = ExpiredCtx{};
    const n = tr.sweepExpiredAcks(5_000, &expired_ctx, onExpiredCb);

    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(usize, 1), expired_ctx.fired);
    try testing.expect(expired_ctx.saw_b1);

    // Binding was removed before the callback fired.
    try testing.expect(tr.binding("b1") == null);
    try testing.expectEqual(@as(usize, 0), tr.countBindings());
}

// 9 -----------------------------------------------------------------------

test "late ack after timeout returns .unknown" {
    var tr = Triggers.init(testing.allocator);
    defer tr.deinit();

    var replay: std.ArrayList([]const u8) = .empty;
    defer replay.deinit(testing.allocator);

    _ = try tr.registerType("cron", .{ .owner = worker_a, .description = "c" }, &replay);
    _ = try tr.registerBinding("b1", .{
        .trigger_type = "cron",
        .function_id = "fn",
        .config = "{}",
        .owner = null,
    }, 1_000);

    // Let it time out.
    var expired_ctx = ExpiredCtx{};
    _ = tr.sweepExpiredAcks(5_000, &expired_ctx, onExpiredCb);

    // Late ack is a no-op.
    const outcome = tr.completeAck("b1", false);
    try testing.expect(outcome == .unknown);
}

// 10 ----------------------------------------------------------------------

test "connection-owned binding creates no ack entry" {
    var tr = Triggers.init(testing.allocator);
    defer tr.deinit();

    var replay: std.ArrayList([]const u8) = .empty;
    defer replay.deinit(testing.allocator);

    _ = try tr.registerType("cron", .{ .owner = worker_a, .description = "c" }, &replay);
    _ = try tr.registerBinding("b1", .{
        .trigger_type = "cron",
        .function_id = "fn",
        .config = "{}",
        .owner = worker_a, // connection-owned → fire-and-forget
    }, 1_000);

    // No ack was parked.
    const outcome = tr.completeAck("b1", false);
    try testing.expect(outcome == .unknown);

    // Even a sweep at the deadline fires nothing.
    var expired_ctx = ExpiredCtx{};
    _ = tr.sweepExpiredAcks(5_000, &expired_ctx, onExpiredCb);
    try testing.expectEqual(@as(usize, 0), expired_ctx.fired);

    // Binding still there.
    try testing.expect(tr.binding("b1") != null);
}

// 11 ----------------------------------------------------------------------

test "unregisterWorker removes only that worker's connection-owned bindings; durable and other workers' bindings survive" {
    var tr = Triggers.init(testing.allocator);
    defer tr.deinit();

    var replay: std.ArrayList([]const u8) = .empty;
    defer replay.deinit(testing.allocator);

    _ = try tr.registerType("cron", .{ .owner = worker_a, .description = "c" }, &replay);

    // worker_a connection-owned
    _ = try tr.registerBinding("conn-a", .{
        .trigger_type = "cron",
        .function_id = "fn",
        .config = "{}",
        .owner = worker_a,
    }, null);
    // worker_b connection-owned
    _ = try tr.registerBinding("conn-b", .{
        .trigger_type = "cron",
        .function_id = "fn",
        .config = "{}",
        .owner = worker_b,
    }, null);
    // durable
    _ = try tr.registerBinding("dur-1", .{
        .trigger_type = "cron",
        .function_id = "fn",
        .config = "{}",
        .owner = null,
    }, 99_999);

    const removed = tr.unregisterWorker(worker_a);
    try testing.expectEqual(@as(usize, 1), removed);

    try testing.expect(tr.binding("conn-a") == null);
    try testing.expect(tr.binding("conn-b") != null);
    try testing.expect(tr.binding("dur-1") != null);
    try testing.expectEqual(@as(usize, 2), tr.countBindings());

    // Clean up the durable ack.
    _ = tr.completeAck("dur-1", true);
}

// 12 ----------------------------------------------------------------------

test "type survives its owner's disconnect; bindings of it remain replayable" {
    var tr = Triggers.init(testing.allocator);
    defer tr.deinit();

    var replay: std.ArrayList([]const u8) = .empty;
    defer replay.deinit(testing.allocator);

    _ = try tr.registerType("cron", .{ .owner = worker_a, .description = "c" }, &replay);
    _ = try tr.registerBinding("dur-1", .{
        .trigger_type = "cron",
        .function_id = "fn",
        .config = "{}",
        .owner = null, // durable
    }, 99_999);

    // Owner disconnects — type stays; durable binding survives.
    const removed = tr.unregisterWorker(worker_a);
    try testing.expectEqual(@as(usize, 0), removed);

    // Type still registered (old owner until replaced).
    try testing.expect(tr.typeOwner("cron") != null);
    try testing.expect(tr.binding("dur-1") != null);

    // Re-register the type with a new owner → replay must include dur-1.
    var replay2: std.ArrayList([]const u8) = .empty;
    defer replay2.deinit(testing.allocator);

    const result = try tr.registerType("cron", .{
        .owner = worker_b,
        .description = "cron-v2",
    }, &replay2);
    try testing.expect(result == .replaced);
    try testing.expectEqual(@as(usize, 1), replay2.items.len);
    try testing.expectEqualStrings("dur-1", replay2.items[0]);

    // Clean up.
    _ = tr.completeAck("dur-1", true);
}

// 13 ----------------------------------------------------------------------

test "unregisterBinding with mismatched trigger_type is a no-op returning false" {
    var tr = Triggers.init(testing.allocator);
    defer tr.deinit();

    var replay: std.ArrayList([]const u8) = .empty;
    defer replay.deinit(testing.allocator);

    _ = try tr.registerType("cron", .{ .owner = worker_a, .description = "c" }, &replay);
    _ = try tr.registerBinding("b1", .{
        .trigger_type = "cron",
        .function_id = "fn",
        .config = "{}",
        .owner = worker_a,
    }, null);

    // Mismatch → no-op.
    try testing.expect(!tr.unregisterBinding("b1", "http"));

    // Match → removes.
    try testing.expect(tr.unregisterBinding("b1", "cron"));
    try testing.expect(tr.binding("b1") == null);

    // null trigger_type → skip check, remove by id.
    _ = try tr.registerBinding("b2", .{
        .trigger_type = "cron",
        .function_id = "fn",
        .config = "{}",
        .owner = worker_a,
    }, null);
    try testing.expect(tr.unregisterBinding("b2", null));
    try testing.expect(tr.binding("b2") == null);
}

// 14 ----------------------------------------------------------------------

test "no leaks under register/replace/unregister loops" {
    var tr = Triggers.init(testing.allocator);
    defer tr.deinit();

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var replay: std.ArrayList([]const u8) = .empty;
        defer replay.deinit(testing.allocator);

        const type_id = switch (i % 3) {
            0 => "cron",
            1 => "http",
            else => "timer",
        };

        // Re/register the type (last-wins).
        _ = try tr.registerType(type_id, .{
            .owner = worker_a,
            .description = "desc",
        }, &replay);

        // Durable binding with a deadline.
        const dur_buf = try std.fmt.allocPrint(testing.allocator, "dur-{d}", .{i});
        defer testing.allocator.free(dur_buf);
        _ = tr.registerBinding(dur_buf, .{
            .trigger_type = type_id,
            .function_id = "fn",
            .config = "{}",
            .owner = null,
        }, @as(i64, @intCast(i)) * 1000) catch {};

        // Connection-owned binding.
        const conn_buf = try std.fmt.allocPrint(testing.allocator, "conn-{d}", .{i});
        defer testing.allocator.free(conn_buf);
        _ = tr.registerBinding(conn_buf, .{
            .trigger_type = type_id,
            .function_id = "fn",
            .config = "{}",
            .owner = worker_a,
        }, null) catch {};

        // Complete some acks.
        _ = tr.completeAck(dur_buf, i % 2 == 0);

        // Periodic GC of the worker.
        if (i % 10 == 9) {
            _ = tr.unregisterWorker(worker_a);
        }
    }

    // Expire remaining acks so the heap is drained.
    var expired_ctx = ExpiredCtx{};
    _ = tr.sweepExpiredAcks(std.math.maxInt(i64), &expired_ctx, onExpiredCb);

    // Under testing.allocator, deinit catches leaks.
}
