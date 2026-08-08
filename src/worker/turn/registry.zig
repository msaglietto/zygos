//! Live-turn control registry (U2): `zygos::turns::abort` flips the flag,
//! `zygos::turns::steer` queues text; the driver polls at step boundaries.
//! ALL access is serialized by one registry mutex — a per-control mutex
//! would dangle when the owning turn untracks between a handler's map
//! lookup and its lock.

const std = @import("std");
const sync = @import("../../kernel/sync.zig");

pub const Control = struct {
    aborted: bool = false,
    steer_text: std.ArrayList(u8) = .empty,
};

pub const Registry = struct {
    gpa: std.mem.Allocator,
    mutex: sync.Mutex = .{},
    controls: std.StringHashMap(*Control),

    pub fn init(gpa: std.mem.Allocator) Registry {
        return .{ .gpa = gpa, .controls = std.StringHashMap(*Control).init(gpa) };
    }

    /// Every tracked turn must have untracked first (the orchestrator joins
    /// all run threads before tearing the registry down).
    pub fn deinit(self: *Registry) void {
        std.debug.assert(self.controls.count() == 0);
        self.controls.deinit();
        self.mutex.deinit();
    }

    pub fn track(self: *Registry, turn_id: []const u8) error{ OutOfMemory, Duplicate }!*Control {
        const ctl = try self.gpa.create(Control);
        errdefer self.gpa.destroy(ctl);
        ctl.* = .{};
        const key = try self.gpa.dupe(u8, turn_id);
        errdefer self.gpa.free(key);

        self.mutex.lock();
        defer self.mutex.unlock();
        const gop = try self.controls.getOrPut(key);
        if (gop.found_existing) return error.Duplicate;
        gop.value_ptr.* = ctl;
        return ctl;
    }

    pub fn untrack(self: *Registry, turn_id: []const u8) void {
        const kv = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            break :blk self.controls.fetchRemove(turn_id) orelse return;
        };
        kv.value.steer_text.deinit(self.gpa);
        self.gpa.destroy(kv.value);
        self.gpa.free(kv.key);
    }

    /// False when the turn is not live (unknown/finished ids are not errors).
    pub fn markAborted(self: *Registry, turn_id: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const ctl = self.controls.get(turn_id) orelse return false;
        ctl.aborted = true;
        return true;
    }

    /// Queue steer text (appends — steers accumulate until drained). False
    /// when the turn is not live.
    pub fn appendSteer(self: *Registry, turn_id: []const u8, text: []const u8) error{OutOfMemory}!bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const ctl = self.controls.get(turn_id) orelse return false;
        try ctl.steer_text.appendSlice(self.gpa, text);
        return true;
    }

    pub fn aborted(self: *Registry, ctl: ?*Control) bool {
        const c = ctl orelse return false;
        self.mutex.lock();
        defer self.mutex.unlock();
        return c.aborted;
    }

    /// Drain-and-clear queued steer text (duped into the turn's arena so the
    /// control can keep mutating). Distinct from aborted() so an abort check
    /// never silently discards queued steering.
    pub fn drainSteer(self: *Registry, ctl: ?*Control, arena: std.mem.Allocator) error{OutOfMemory}!?[]const u8 {
        const c = ctl orelse return null;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (c.steer_text.items.len == 0) return null;
        const copy = try arena.dupe(u8, c.steer_text.items);
        c.steer_text.clearRetainingCapacity();
        return copy;
    }
};

const testing = std.testing;

test "track rejects a duplicate live turn_id" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    _ = try reg.track("t-1");
    try testing.expectError(error.Duplicate, reg.track("t-1"));
    reg.untrack("t-1");
}

test "untrack frees queued steer text (leak-checked)" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    _ = try reg.track("t-1");
    try testing.expect(try reg.appendSteer("t-1", "queued but never drained"));
    reg.untrack("t-1");
}

test "steers accumulate until drained; drain clears the queue" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    const ctl = try reg.track("t-1");
    defer reg.untrack("t-1");

    try testing.expect(try reg.appendSteer("t-1", "first "));
    try testing.expect(try reg.appendSteer("t-1", "second"));
    try testing.expectEqualStrings("first second", (try reg.drainSteer(ctl, arena)).?);
    try testing.expectEqual(@as(?[]const u8, null), try reg.drainSteer(ctl, arena));
}

test "control mutations against an unknown turn report false" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    try testing.expect(!reg.markAborted("nope"));
    try testing.expect(!(try reg.appendSteer("nope", "text")));
}

test "an untracked (null) control polls as not aborted and drains nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    try testing.expect(!reg.aborted(null));
    try testing.expectEqual(@as(?[]const u8, null), try reg.drainSteer(null, arena_state.allocator()));
}

test "abort flag round-trips through the polling read" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    const ctl = try reg.track("t-1");
    defer reg.untrack("t-1");
    try testing.expect(!reg.aborted(ctl));
    try testing.expect(reg.markAborted("t-1"));
    try testing.expect(reg.aborted(ctl));
}
