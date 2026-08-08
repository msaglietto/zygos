//! Live-mission control registry: one Control block per running mission,
//! shared between the run thread (polls flags, consumes steer, publishes
//! snapshots) and the control handlers (status/abort/steer/pause/list).
//! ALL access is serialized by one registry mutex — a per-control mutex
//! would dangle when the owning turn untracks between a handler's map
//! lookup and its lock.

const std = @import("std");
const sync = @import("../../kernel/sync.zig");
const fsm = @import("fsm.zig");
const model = @import("model.zig");

pub const Control = struct {
    aborted: bool = false,
    /// M6: pause parks the run durably at the next role boundary.
    paused: bool = false,
    /// M6: pending operator steer, gpa-owned, consumed at the next boundary.
    steer: ?[]u8 = null,
    state: fsm.State = .defining,
    stop: model.StopReason = .none,
    task_index: usize = 0,
    fail_count: usize = 0,
    gate_denials: usize = 0,
    role_turns_used: usize = 0,
};

/// Point-in-time copy of a control block, safe to read without the lock.
pub const Snapshot = struct {
    state: fsm.State,
    stop: model.StopReason,
    paused: bool,
    task_index: usize,
    fail_count: usize,
    gate_denials: usize,
    role_turns_used: usize,
};

pub const Entry = struct {
    mission_id: []const u8,
    snap: Snapshot,
};

pub const Registry = struct {
    gpa: std.mem.Allocator,
    mutex: sync.Mutex = .{},
    live: std.StringHashMap(*Control),

    pub fn init(gpa: std.mem.Allocator) Registry {
        return .{ .gpa = gpa, .live = std.StringHashMap(*Control).init(gpa) };
    }

    /// Every tracked mission must have untracked first (the orchestrator
    /// joins all run threads before tearing the registry down).
    pub fn deinit(self: *Registry) void {
        std.debug.assert(self.live.count() == 0);
        self.live.deinit();
        self.mutex.deinit();
    }

    pub fn track(self: *Registry, mission_id: []const u8) error{ OutOfMemory, Duplicate }!*Control {
        const ctl = try self.gpa.create(Control);
        errdefer self.gpa.destroy(ctl);
        ctl.* = .{};
        const key = try self.gpa.dupe(u8, mission_id);
        errdefer self.gpa.free(key);

        self.mutex.lock();
        defer self.mutex.unlock();
        const gop = try self.live.getOrPut(key);
        if (gop.found_existing) return error.Duplicate;
        gop.value_ptr.* = ctl;
        return ctl;
    }

    pub fn untrack(self: *Registry, mission_id: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.live.fetchRemove(mission_id)) |kv| {
            if (kv.value.steer) |s| self.gpa.free(s);
            self.gpa.destroy(kv.value);
            self.gpa.free(kv.key);
        }
    }

    pub fn aborted(self: *Registry, ctl: *Control) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return ctl.aborted;
    }

    pub fn paused(self: *Registry, ctl: *Control) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return ctl.paused;
    }

    /// The pending steer text (gpa-owned, caller frees), clearing the slot.
    pub fn takeSteer(self: *Registry, ctl: *Control) ?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const s = ctl.steer;
        ctl.steer = null;
        return s;
    }

    /// Publish the persisted mission state into the control snapshot.
    pub fn updateSnapshot(self: *Registry, ctl: *Control, m: *const model.Mission) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        ctl.state = m.state;
        ctl.stop = m.stop;
        ctl.task_index = m.task_index;
        ctl.fail_count = m.fail_count;
        ctl.gate_denials = m.gate_denials;
        ctl.role_turns_used = m.role_turns_used;
    }

    /// False when the mission is not live.
    pub fn markAborted(self: *Registry, mission_id: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const ctl = self.live.get(mission_id) orelse return false;
        ctl.aborted = true;
        return true;
    }

    /// False when the mission is not live.
    pub fn markPaused(self: *Registry, mission_id: []const u8, value: bool) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const ctl = self.live.get(mission_id) orelse return false;
        ctl.paused = value;
        return true;
    }

    /// Queue steer text (last write wins while one is pending). False when
    /// the mission is not live.
    pub fn putSteer(self: *Registry, mission_id: []const u8, text: []const u8) error{OutOfMemory}!bool {
        const copy = try self.gpa.dupe(u8, text);
        self.mutex.lock();
        defer self.mutex.unlock();
        const ctl = self.live.get(mission_id) orelse {
            self.gpa.free(copy);
            return false;
        };
        if (ctl.steer) |old| self.gpa.free(old);
        ctl.steer = copy;
        return true;
    }

    pub fn status(self: *Registry, mission_id: []const u8) ?Snapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        const ctl = self.live.get(mission_id) orelse return null;
        return snapshotLocked(ctl);
    }

    /// Arena-owned snapshot of every live mission (M6 dashboard data).
    pub fn snapshotAll(self: *Registry, arena: std.mem.Allocator) error{OutOfMemory}![]Entry {
        self.mutex.lock();
        defer self.mutex.unlock();
        var out = try arena.alloc(Entry, self.live.count());
        var it = self.live.iterator();
        var i: usize = 0;
        while (it.next()) |kv| : (i += 1) {
            out[i] = .{
                .mission_id = try arena.dupe(u8, kv.key_ptr.*),
                .snap = snapshotLocked(kv.value_ptr.*),
            };
        }
        return out;
    }

    fn snapshotLocked(ctl: *const Control) Snapshot {
        return .{
            .state = ctl.state,
            .stop = ctl.stop,
            .paused = ctl.paused,
            .task_index = ctl.task_index,
            .fail_count = ctl.fail_count,
            .gate_denials = ctl.gate_denials,
            .role_turns_used = ctl.role_turns_used,
        };
    }
};

const testing = std.testing;

test "track rejects a duplicate live mission_id" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    _ = try reg.track("m-1");
    try testing.expectError(error.Duplicate, reg.track("m-1"));
    reg.untrack("m-1");
}

test "untrack frees a pending steer (leak-checked)" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    _ = try reg.track("m-1");
    try testing.expect(try reg.putSteer("m-1", "go left"));
    reg.untrack("m-1");
}

test "putSteer last-write-wins; takeSteer consumes and clears" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    const ctl = try reg.track("m-1");
    defer reg.untrack("m-1");
    try testing.expect(try reg.putSteer("m-1", "first"));
    try testing.expect(try reg.putSteer("m-1", "second"));
    const s = reg.takeSteer(ctl).?;
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("second", s);
    try testing.expectEqual(@as(?[]u8, null), reg.takeSteer(ctl));
}

test "control mutations against an unknown mission report false" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    try testing.expect(!reg.markAborted("nope"));
    try testing.expect(!reg.markPaused("nope", true));
    try testing.expect(!(try reg.putSteer("nope", "text")));
    try testing.expectEqual(@as(?Snapshot, null), reg.status("nope"));
}

test "abort and pause flags round-trip through the polling reads" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    const ctl = try reg.track("m-1");
    defer reg.untrack("m-1");
    try testing.expect(!reg.aborted(ctl));
    try testing.expect(!reg.paused(ctl));
    try testing.expect(reg.markAborted("m-1"));
    try testing.expect(reg.markPaused("m-1", true));
    try testing.expect(reg.aborted(ctl));
    try testing.expect(reg.paused(ctl));
    try testing.expect(reg.markPaused("m-1", false));
    try testing.expect(!reg.paused(ctl));
}

test "updateSnapshot publishes persisted state into status and snapshotAll" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    const ctl = try reg.track("m-1");
    defer reg.untrack("m-1");

    const m: model.Mission = .{
        .mission_id = "m-1",
        .state = .verifying,
        .stop = .none,
        .task_index = 2,
        .fail_count = 1,
        .gate_denials = 3,
        .role_turns_used = 7,
    };
    reg.updateSnapshot(ctl, &m);

    const snap = reg.status("m-1").?;
    try testing.expectEqual(fsm.State.verifying, snap.state);
    try testing.expectEqual(@as(usize, 2), snap.task_index);
    try testing.expectEqual(@as(usize, 1), snap.fail_count);
    try testing.expectEqual(@as(usize, 3), snap.gate_denials);
    try testing.expectEqual(@as(usize, 7), snap.role_turns_used);

    const all = try reg.snapshotAll(arena_state.allocator());
    try testing.expectEqual(@as(usize, 1), all.len);
    try testing.expectEqualStrings("m-1", all[0].mission_id);
    try testing.expectEqual(fsm.State.verifying, all[0].snap.state);
}
