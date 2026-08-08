//! Bounded MPSC command ring for the kernel actor: producers block when the
//! ring is full (backpressure to the net layer), the single consumer blocks
//! when it is empty. Generic so it is testable without dragging in Command.

const std = @import("std");
const sync = @import("../sync.zig");

pub fn Inbox(comptime T: type) type {
    return struct {
        const Self = @This();

        mutex: sync.Mutex = .{},
        not_empty: sync.Condition = .{},
        not_full: sync.Condition = .{},
        buf: []T,
        head: usize = 0,
        len: usize = 0,

        pub fn init(gpa: std.mem.Allocator, capacity: usize) error{OutOfMemory}!Self {
            return .{ .buf = try gpa.alloc(T, capacity) };
        }

        /// Caller drains first — deinit does not run element cleanup.
        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.not_full.deinit();
            self.not_empty.deinit();
            self.mutex.deinit();
            gpa.free(self.buf);
        }

        pub fn push(self: *Self, item: T) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (self.len == self.buf.len) self.not_full.wait(&self.mutex);
            self.buf[(self.head + self.len) % self.buf.len] = item;
            self.len += 1;
            self.not_empty.signal();
        }

        pub fn popBlocking(self: *Self) T {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (self.len == 0) self.not_empty.wait(&self.mutex);
            return self.takeLocked();
        }

        pub fn tryPop(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.len == 0) return null;
            return self.takeLocked();
        }

        fn takeLocked(self: *Self) T {
            const item = self.buf[self.head];
            self.head = (self.head + 1) % self.buf.len;
            self.len -= 1;
            self.not_full.signal();
            return item;
        }
    };
}

const testing = std.testing;

test "FIFO order survives ring wrap-around" {
    var inbox = try Inbox(u32).init(testing.allocator, 4);
    defer inbox.deinit(testing.allocator);

    // Fill, half-drain, refill: forces head to wrap.
    var next: u32 = 0;
    var expect: u32 = 0;
    while (next < 4) : (next += 1) inbox.push(next);
    while (expect < 2) : (expect += 1) try testing.expectEqual(expect, inbox.tryPop().?);
    while (next < 6) : (next += 1) inbox.push(next);
    while (inbox.tryPop()) |v| : (expect += 1) try testing.expectEqual(expect, v);
    try testing.expectEqual(next, expect);
}

test "tryPop on an empty inbox is null, not a block" {
    var inbox = try Inbox(u8).init(testing.allocator, 2);
    defer inbox.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, null), inbox.tryPop());
}

test "popBlocking waits for a producer" {
    var inbox = try Inbox(u8).init(testing.allocator, 2);
    defer inbox.deinit(testing.allocator);

    const producer = try std.Thread.spawn(.{}, struct {
        fn run(q: *Inbox(u8)) void {
            q.push(42);
        }
    }.run, .{&inbox});
    try testing.expectEqual(@as(u8, 42), inbox.popBlocking());
    producer.join();
}

test "push blocks at capacity until the consumer pops" {
    var inbox = try Inbox(u8).init(testing.allocator, 1);
    defer inbox.deinit(testing.allocator);
    inbox.push(1);

    const producer = try std.Thread.spawn(.{}, struct {
        fn run(q: *Inbox(u8)) void {
            q.push(2); // blocks until the pop below frees a slot
        }
    }.run, .{&inbox});
    try testing.expectEqual(@as(u8, 1), inbox.popBlocking());
    try testing.expectEqual(@as(u8, 2), inbox.popBlocking());
    producer.join();
}
