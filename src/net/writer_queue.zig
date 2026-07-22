//! Bounded per-connection writer queue (M7 net hardening; docs/specs/net.md
//! "specified, never built"). The gateway's Outbound previously wrote frames
//! directly under the conn-table mutex — a stalled TCP consumer parked the
//! kernel thread. Now sends enqueue (never block); a dedicated writer thread
//! drains through a Sink vtable (the socket in production, a recorder in
//! tests). Cap 64 frames, mirroring iii: a full queue is `error.QueueFull`
//! back to the kernel, which treats it like any send failure.
//!
//! Lifecycle: `start` spawns the writer; `stop` closes, wakes, joins, and
//! frees whatever was still queued. A sink Disconnected closes the queue —
//! subsequent pushes fail fast with Closed.

const std = @import("std");
const sync = @import("../kernel/sync.zig");

pub const capacity = 64;

pub const Sink = struct {
    ctx: *anyopaque,
    writeFn: *const fn (ctx: *anyopaque, frame: []const u8) error{Disconnected}!void,

    fn write(self: Sink, frame: []const u8) error{Disconnected}!void {
        return self.writeFn(self.ctx, frame);
    }
};

pub const PushError = error{ QueueFull, Closed, OutOfMemory };

pub const WriterQueue = struct {
    gpa: std.mem.Allocator,
    sink: Sink,
    mutex: sync.Mutex = .{},
    cond: sync.Condition = .{},
    ring: [capacity]?[]u8 = @splat(null),
    head: usize = 0,
    len: usize = 0,
    closed: bool = false,
    thread: ?std.Thread = null,

    pub fn init(gpa: std.mem.Allocator, sink: Sink) WriterQueue {
        return .{ .gpa = gpa, .sink = sink };
    }

    pub fn start(self: *WriterQueue) !void {
        self.thread = try std.Thread.spawn(.{}, drainLoop, .{self});
    }

    /// Close, wake the writer, join it, free the backlog. Idempotent.
    pub fn stop(self: *WriterQueue) void {
        self.mutex.lock();
        self.closed = true;
        self.cond.broadcast();
        self.mutex.unlock();
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        self.mutex.lock();
        while (self.len > 0) {
            if (self.ring[self.head]) |f| self.gpa.free(f);
            self.ring[self.head] = null;
            self.head = (self.head + 1) % capacity;
            self.len -= 1;
        }
        self.mutex.unlock();
    }

    pub fn deinit(self: *WriterQueue) void {
        self.stop();
        self.cond.deinit();
        self.mutex.deinit();
        self.* = undefined;
    }

    /// Never blocks: the frame is duped and queued, or refused.
    pub fn push(self: *WriterQueue, frame: []const u8) PushError!void {
        const copy = try self.gpa.dupe(u8, frame);
        errdefer self.gpa.free(copy);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closed) return error.Closed;
        if (self.len == capacity) return error.QueueFull;
        self.ring[(self.head + self.len) % capacity] = copy;
        self.len += 1;
        self.cond.signal();
    }

    /// One queued frame (owned by the caller) or null; used by the drain
    /// loop and by tests that drain manually.
    pub fn pop(self: *WriterQueue) ?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.len == 0) return null;
        const frame = self.ring[self.head].?;
        self.ring[self.head] = null;
        self.head = (self.head + 1) % capacity;
        self.len -= 1;
        return frame;
    }

    fn drainLoop(self: *WriterQueue) void {
        while (true) {
            self.mutex.lock();
            while (self.len == 0 and !self.closed) self.cond.wait(&self.mutex);
            if (self.len == 0 and self.closed) {
                self.mutex.unlock();
                return;
            }
            self.mutex.unlock();
            const frame = self.pop() orelse continue;
            defer self.gpa.free(frame);
            self.sink.write(frame) catch {
                // Peer gone: close so pushes fail fast; stop() reaps the rest.
                self.mutex.lock();
                self.closed = true;
                self.mutex.unlock();
                return;
            };
        }
    }
};

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

const RecSink = struct {
    gpa: std.mem.Allocator,
    mutex: sync.Mutex = .{},
    frames: std.ArrayList([]u8) = .empty,
    fail: bool = false,

    fn write(ctx: *anyopaque, frame: []const u8) error{Disconnected}!void {
        const self: *RecSink = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.fail) return error.Disconnected;
        const copy = self.gpa.dupe(u8, frame) catch return error.Disconnected;
        self.frames.append(self.gpa, copy) catch self.gpa.free(copy);
    }

    fn sink(self: *RecSink) Sink {
        return .{ .ctx = @ptrCast(self), .writeFn = &write };
    }

    fn count(self: *RecSink) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.frames.items.len;
    }

    fn deinit(self: *RecSink) void {
        for (self.frames.items) |f| self.gpa.free(f);
        self.frames.deinit(self.gpa);
        self.mutex.deinit();
    }
};

test "push preserves order; pop drains FIFO without a thread" {
    var rec = RecSink{ .gpa = testing.allocator };
    defer rec.deinit();
    var q = WriterQueue.init(testing.allocator, rec.sink());
    defer q.deinit();

    try q.push("one");
    try q.push("two");
    try q.push("three");
    const a = q.pop().?;
    defer testing.allocator.free(a);
    const b = q.pop().?;
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("one", a);
    try testing.expectEqualStrings("two", b);
    // "three" left queued: deinit frees it (leak check proves it).
}

test "a full queue refuses with QueueFull instead of blocking the pusher" {
    var rec = RecSink{ .gpa = testing.allocator };
    defer rec.deinit();
    var q = WriterQueue.init(testing.allocator, rec.sink());
    defer q.deinit();

    var i: usize = 0;
    while (i < capacity) : (i += 1) try q.push("frame");
    try testing.expectError(error.QueueFull, q.push("overflow"));
    // Draining one makes room again.
    testing.allocator.free(q.pop().?);
    try q.push("fits-again");
}

test "the writer thread drains pushes through the sink in order" {
    var rec = RecSink{ .gpa = testing.allocator };
    defer rec.deinit();
    var q = WriterQueue.init(testing.allocator, rec.sink());
    try q.start();
    defer q.deinit();

    try q.push("a");
    try q.push("b");
    var spins: usize = 0;
    while (rec.count() < 2 and spins < 500) : (spins += 1) std.Thread.yield() catch {};
    try testing.expectEqual(@as(usize, 2), rec.count());
    try testing.expectEqualStrings("a", rec.frames.items[0]);
    try testing.expectEqualStrings("b", rec.frames.items[1]);
}

test "a disconnected sink closes the queue; pushes then fail fast with Closed" {
    var rec = RecSink{ .gpa = testing.allocator, .fail = true };
    defer rec.deinit();
    var q = WriterQueue.init(testing.allocator, rec.sink());
    try q.start();
    defer q.deinit();

    try q.push("doomed");
    var spins: usize = 0;
    while (spins < 500) : (spins += 1) {
        q.mutex.lock();
        const closed = q.closed;
        q.mutex.unlock();
        if (closed) break;
        std.Thread.yield() catch {};
    }
    try testing.expectError(error.Closed, q.push("after-close"));
}

test "stop is idempotent and frees the backlog (leak-checked)" {
    var rec = RecSink{ .gpa = testing.allocator };
    defer rec.deinit();
    var q = WriterQueue.init(testing.allocator, rec.sink());
    try q.push("left");
    try q.push("behind");
    q.stop();
    q.stop();
    q.deinit();
}
