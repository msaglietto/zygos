//! Idle watchdog for blocking provider HTTP streams (Z-12). `std.Io`'s
//! `net.Stream.Reader` has no per-read deadline, so a provider that accepts
//! the connection and then goes silent (observed: glm endpoint mid-mission)
//! parks the worker thread in `recv` forever. The guard watches for stream
//! activity pokes and, once none arrive for `idle_ms`, fires a callback whose
//! job is `Stream.shutdown(io, .both)` — which errors the blocked read and
//! lets the turn driver fall back to the next provider route.
//!
//! Network-free core (`IdleDeadline`, injected time) + a thread wrapper.
//! Fire-once contract: the callback runs at most once, never after `stop()`
//! returns (stop joins the thread), so the socket it closes is still valid.

const std = @import("std");
const sync = @import("../kernel/sync.zig");
const ticker = @import("ticker.zig");

/// Default per-request idle timeout for provider streams. Shared by the HTTP
/// clients' StreamOptions and the boot-time StartOptions so the knob has one
/// value everywhere; ZYGOS_STREAM_IDLE_MS overrides it at boot (0 disables).
pub const default_idle_ms: u64 = 120_000;

/// Pure idle bookkeeping over caller-supplied clocks.
pub const IdleDeadline = struct {
    idle_ms: u64,
    last_ms: i64,

    pub fn init(idle_ms: u64, now_ms: i64) IdleDeadline {
        return .{ .idle_ms = idle_ms, .last_ms = now_ms };
    }

    pub fn poke(self: *IdleDeadline, now_ms: i64) void {
        self.last_ms = now_ms;
    }

    pub fn expired(self: *const IdleDeadline, now_ms: i64) bool {
        return now_ms - self.last_ms >= @as(i64, @intCast(self.idle_ms));
    }
};

/// Thread wrapper: checks the deadline every `idle_ms / 4` (min 10ms) and
/// fires `fireFn(ctx)` exactly once on expiry. `poke()` is thread-safe.
pub const StreamGuard = struct {
    mutex: sync.Mutex = .{},
    deadline: IdleDeadline,
    stop_event: sync.ResetEvent = .{},
    thread: ?std.Thread = null,
    ctx: *anyopaque,
    fireFn: *const fn (ctx: *anyopaque) void,
    /// Total pokes observed — the pump's activity trace, asserted in tests.
    pokes: u64 = 0,

    pub fn init(idle_ms: u64, ctx: *anyopaque, fireFn: *const fn (ctx: *anyopaque) void) StreamGuard {
        return .{
            .deadline = IdleDeadline.init(idle_ms, ticker.nowMs()),
            .ctx = ctx,
            .fireFn = fireFn,
        };
    }

    pub fn start(self: *StreamGuard) !void {
        self.thread = try std.Thread.spawn(.{}, loop, .{self});
    }

    /// Stream activity: resets the idle window. Callable from the pumping
    /// thread while the guard thread is running.
    pub fn poke(self: *StreamGuard) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.deadline.poke(ticker.nowMs());
        self.pokes += 1;
    }

    /// Joins the guard thread; after return the callback can no longer fire.
    pub fn stop(self: *StreamGuard) void {
        self.stop_event.set();
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    pub fn deinit(self: *StreamGuard) void {
        self.stop();
        self.stop_event.deinit();
        self.mutex.deinit();
        self.* = undefined;
    }

    fn loop(self: *StreamGuard) void {
        const check_ms = @max(self.deadline.idle_ms / 4, 10);
        while (!self.stop_event.timedWait(check_ms)) {
            self.mutex.lock();
            const hit = self.deadline.expired(ticker.nowMs());
            self.mutex.unlock();
            if (hit) {
                self.fireFn(self.ctx);
                return;
            }
        }
    }
};

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "IdleDeadline: expires only after idle_ms without pokes; poke resets" {
    var d = IdleDeadline.init(100, 1_000);
    try testing.expect(!d.expired(1_000));
    try testing.expect(!d.expired(1_099));
    try testing.expect(d.expired(1_100));

    d.poke(1_090);
    try testing.expect(!d.expired(1_100));
    try testing.expect(!d.expired(1_189));
    try testing.expect(d.expired(1_190));
}

const FireFlag = struct {
    event: sync.ResetEvent = .{},
    count: std.atomic.Value(u32) = .init(0),

    fn fire(ctx: *anyopaque) void {
        const self: *FireFlag = @ptrCast(@alignCast(ctx));
        _ = self.count.fetchAdd(1, .seq_cst);
        self.event.set();
    }

    fn deinit(self: *FireFlag) void {
        self.event.deinit();
    }
};

test "StreamGuard fires once when the stream stays idle" {
    var flag: FireFlag = .{};
    defer flag.deinit();

    var guard = StreamGuard.init(30, @ptrCast(&flag), &FireFlag.fire);
    defer guard.deinit();
    try guard.start();

    try testing.expect(flag.event.timedWait(5_000));
    guard.stop();
    try testing.expectEqual(@as(u32, 1), flag.count.load(.seq_cst));
}

test "StreamGuard stopped before expiry never fires" {
    var flag: FireFlag = .{};
    defer flag.deinit();

    var guard = StreamGuard.init(60_000, @ptrCast(&flag), &FireFlag.fire);
    defer guard.deinit();
    try guard.start();
    guard.stop();

    try testing.expectEqual(@as(u32, 0), flag.count.load(.seq_cst));
}
