//! Wall-clock tick pump for headless kernel embeddings (Z-11). The actor's
//! timeout sweeps (`onTick`: invocation deadlines, trigger acks, idle
//! channels) only run when someone posts `.tick` — the WS gateway's timer
//! thread did, but `zygos mission start` ran the kernel with no tick source,
//! so ZYGOS_INVOKE_TIMEOUT_MS was parked in the pending map and never swept.
//! Lives in src/net/ because it reads the wall clock (poster-stamped time is
//! a net-layer duty; kernel modules never read a clock).

const std = @import("std");
const actor_mod = @import("../kernel/actor.zig");
const sync = @import("../kernel/sync.zig");

/// Wall-clock milliseconds. Same clock the WS gateway stamps frames with.
pub fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

/// Posts `.tick` to the actor every `interval_ms` until stopped. One per
/// kernel; start after the kernel thread is running, stop before actor deinit.
pub const Ticker = struct {
    actor: *actor_mod.Actor,
    interval_ms: u64,
    stop_event: sync.ResetEvent = .{},
    thread: ?std.Thread = null,

    pub fn init(actor: *actor_mod.Actor, interval_ms: u64) Ticker {
        return .{ .actor = actor, .interval_ms = interval_ms };
    }

    pub fn start(self: *Ticker) !void {
        self.thread = try std.Thread.spawn(.{}, loop, .{self});
    }

    /// Idempotent; joins the timer thread. Safe to call before actor shutdown.
    pub fn stop(self: *Ticker) void {
        self.stop_event.set();
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    pub fn deinit(self: *Ticker) void {
        self.stop();
        self.stop_event.deinit();
        self.* = undefined;
    }

    fn loop(self: *Ticker) void {
        // timedWait doubles as the interval sleep: stop() wakes it promptly
        // instead of waiting out a nanosleep.
        while (!self.stop_event.timedWait(self.interval_ms)) {
            self.actor.post(.{ .tick = nowMs() });
        }
    }
};

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;
const types = @import("../kernel/types.zig");
const invocation_mod = @import("../kernel/invocation.zig");

fn noopSend(_: *anyopaque, _: types.WorkerId, _: []const u8) actor_mod.SendError!void {}

test "a running ticker sweeps expired invocations without any frame traffic" {
    var dummy: u8 = 0;
    var actor = try actor_mod.Actor.init(testing.allocator, .{}, .{
        .ctx = @ptrCast(&dummy),
        .sendFn = &noopSend,
    });
    defer actor.deinit();

    // Park a waiter-target pending whose wall-clock deadline is imminent.
    // Nothing in this test ever posts a frame: only tick sweeps can fire it.
    var w: invocation_mod.Waiter = .{};
    defer w.deinit();
    const uuid = try types.parseUuid("11111111-2222-3333-4444-555555555555");
    const callee: types.WorkerId = [_]u8{7} ** 16;
    try actor.invocations.add(uuid, callee, "f", .{ .waiter = &w }, nowMs() + 50);

    const kernel = try std.Thread.spawn(.{}, actor_mod.Actor.run, .{&actor});

    var ticker = Ticker.init(&actor, 10);
    defer ticker.deinit();
    try ticker.start();

    // Fails when no ticks arrive — exactly the mission-start hang.
    try testing.expect(w.event.timedWait(5_000));
    ticker.stop();
    actor.post(.shutdown);
    kernel.join();

    const outcome = w.result orelse return error.NoOutcome;
    try testing.expect(outcome == .err);
    testing.allocator.free(outcome.err);
}
