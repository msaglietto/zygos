//! Zygos keyed byte channels (S5). Implements GOAL.md criterion S5 and
//! PROTOCOL.md semantics 8: channel_id + access_key gate access, each
//! endpoint is taken exactly once, direction is enforced, idle channels are
//! TTL-swept, owner disconnect reaps.
//!
//! Threading model — this module is the kernel's exception (see
//! docs/specs/channel.md): the `Channels` registry is actor-owned and
//! single-threaded like the other registries, but `Pipe` is a cross-thread
//! bounded ring (sync.Mutex + two sync.Condition) so producers and consumers
//! stream bytes without routing chunks through the actor inbox.
//!
//! No clock reads anywhere: registry operations take `now_ms`. Pipe push/pop
//! take no time parameter at all — activity is tracked with a monotonic
//! counter the sweep converts to time (see `sweepIdle`).

const std = @import("std");
const types = @import("types.zig");
const sync = @import("sync.zig");
const entropy = @import("entropy.zig");

pub const WorkerId = types.WorkerId;

pub const Direction = enum { read, write };

/// Wire shape: StreamChannelRef. The slices are owned by the registry entry
/// and remain valid until the channel is reaped (the actor serializes them
/// into payloads immediately).
pub const Ref = struct {
    channel_id: []const u8,
    access_key: []const u8,
    direction: Direction,
};

/// One streamed chunk; maps to a WS text/binary frame. Bytes are owned by the
/// pipe while queued and by the popper after `pop` (free via `deinit` with
/// the registry's allocator).
pub const Item = union(enum) {
    text: []u8,
    binary: []u8,

    pub fn bytes(self: Item) []u8 {
        return switch (self) {
            .text => |b| b,
            .binary => |b| b,
        };
    }

    pub fn deinit(self: Item, gpa: std.mem.Allocator) void {
        gpa.free(self.bytes());
    }
};

const key_len = 64; // 32 random bytes, hex-encoded

// ---------------------------------------------------------------------------
// Pipe — the cross-thread transport
// ---------------------------------------------------------------------------

/// Refcounted: the registry entry plus each taken endpoint holds one ref;
/// the pipe frees itself when the last ref drops. Refcount mutations happen
/// under the pipe mutex (no atomics needed).
const Pipe = struct {
    gpa: std.mem.Allocator,
    mutex: sync.Mutex = .{},
    not_empty: sync.Condition = .{},
    not_full: sync.Condition = .{},
    ring: []Item,
    head: usize = 0,
    len: usize = 0,
    sender_closed: bool = false,
    receiver_closed: bool = false,
    refs: usize = 1, // creator (registry entry)
    /// Bumped on every push/pop; `Channels.sweepIdle` converts change into
    /// a fresh last-activity timestamp (pipes never read clocks).
    activity: u64 = 0,

    fn create(gpa: std.mem.Allocator, capacity: usize) error{OutOfMemory}!*Pipe {
        const ring = try gpa.alloc(Item, capacity);
        errdefer gpa.free(ring);
        const self = try gpa.create(Pipe);
        self.* = .{ .gpa = gpa, .ring = ring };
        return self;
    }

    fn retain(self: *Pipe) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.refs += 1;
    }

    fn release(self: *Pipe) void {
        self.mutex.lock();
        self.refs -= 1;
        const last = self.refs == 0;
        self.mutex.unlock();
        if (last) self.destroy();
    }

    fn destroy(self: *Pipe) void {
        // No refs left — nobody can be blocked inside; safe to tear down.
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            self.ring[(self.head + i) % self.ring.len].deinit(self.gpa);
        }
        self.not_full.deinit();
        self.not_empty.deinit();
        self.mutex.deinit();
        self.gpa.free(self.ring);
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    /// Close one or both directions and wake every blocked party.
    fn close(self: *Pipe, send_side: bool, recv_side: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (send_side) self.sender_closed = true;
        if (recv_side) self.receiver_closed = true;
        self.not_empty.broadcast();
        self.not_full.broadcast();
    }

    /// Dupe `item`'s bytes into the ring. Blocking mode waits on not-full.
    fn push(self: *Pipe, item: Item, blocking: bool) error{ Full, ReceiverGone, Closed }!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (true) {
            if (self.receiver_closed) return error.ReceiverGone;
            if (self.sender_closed) return error.Closed;
            if (self.len < self.ring.len) break;
            if (!blocking) return error.Full;
            self.not_full.wait(&self.mutex);
        }

        const copy = self.gpa.dupe(u8, item.bytes()) catch return error.Full;
        const owned: Item = switch (item) {
            .text => .{ .text = copy },
            .binary => .{ .binary = copy },
        };
        self.ring[(self.head + self.len) % self.ring.len] = owned;
        self.len += 1;
        self.activity +%= 1;
        self.not_empty.signal();
    }

    /// Drain-then-close semantics: queued items are delivered even after the
    /// sender closed; EndOfStream only once empty and closed (either side).
    fn pop(self: *Pipe, blocking: bool) error{EndOfStream}!?Item {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (true) {
            if (self.len > 0) {
                const item = self.ring[self.head];
                self.head = (self.head + 1) % self.ring.len;
                self.len -= 1;
                self.activity +%= 1;
                self.not_full.signal();
                return item;
            }
            if (self.sender_closed or self.receiver_closed) return error.EndOfStream;
            if (!blocking) return null;
            self.not_empty.wait(&self.mutex);
        }
    }
};

// ---------------------------------------------------------------------------
// Endpoints
// ---------------------------------------------------------------------------

pub const Sender = struct {
    pipe: *Pipe,

    /// Blocks on not-full. `item` bytes are borrowed and duped into the pipe.
    pub fn push(self: *Sender, item: Item) error{ ReceiverGone, Closed }!void {
        return self.pipe.push(item, true) catch |err| switch (err) {
            error.Full => unreachable, // blocking mode never reports Full
            error.ReceiverGone => error.ReceiverGone,
            error.Closed => error.Closed,
        };
    }

    pub fn tryPush(self: *Sender, item: Item) error{ Full, ReceiverGone, Closed }!void {
        return self.pipe.push(item, false);
    }

    /// Idempotent; receiver drains remaining items then sees EndOfStream.
    pub fn close(self: *Sender) void {
        self.pipe.close(true, false);
    }

    pub fn deinit(self: *Sender) void {
        self.close();
        self.pipe.release();
        self.* = undefined;
    }
};

pub const Receiver = struct {
    pipe: *Pipe,

    /// Blocks on not-empty; drains queued items, then EndOfStream once the
    /// sender closed. Popped items are owned by the caller (Item.deinit).
    pub fn pop(self: *Receiver) error{EndOfStream}!Item {
        const item = try self.pipe.pop(true);
        return item.?; // blocking mode returns an item or errors
    }

    /// Null = empty but still open.
    pub fn tryPop(self: *Receiver) error{EndOfStream}!?Item {
        return self.pipe.pop(false);
    }

    /// Idempotent; the sender's next push fails ReceiverGone.
    pub fn close(self: *Receiver) void {
        self.pipe.close(false, true);
    }

    pub fn deinit(self: *Receiver) void {
        self.close();
        self.pipe.release();
        self.* = undefined;
    }
};

// ---------------------------------------------------------------------------
// Registry — actor-owned, single-threaded
// ---------------------------------------------------------------------------

const Entry = struct {
    writer_key: []const u8, // owned, hex
    reader_key: []const u8, // owned, hex
    owner: WorkerId,
    pipe: *Pipe,
    writer_taken: bool = false,
    reader_taken: bool = false,
    last_activity_ms: i64,
    /// Pipe activity counter at the last sweep — change proves streaming
    /// happened since, which refreshes last_activity_ms (injectable time).
    seen_activity: u64 = 0,
};

pub const Channels = struct {
    gpa: std.mem.Allocator,
    ttl_ms: i64,
    entries: std.StringHashMap(Entry),
    next_id: u64,

    pub fn init(gpa: std.mem.Allocator, ttl_ms: i64) Channels {
        return .{
            .gpa = gpa,
            .ttl_ms = ttl_ms,
            .entries = std.StringHashMap(Entry).init(gpa),
            .next_id = 0,
        };
    }

    pub fn deinit(self: *Channels) void {
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            reapEntry(self.gpa, kv.value_ptr);
            self.gpa.free(kv.key_ptr.*);
        }
        self.entries.deinit();
    }

    /// One pipe, two distinct access keys. The returned Refs' slices are
    /// owned by the registry entry (valid until reap).
    pub fn create(
        self: *Channels,
        capacity: usize,
        owner: WorkerId,
        now_ms: i64,
    ) error{OutOfMemory}!struct { writer: Ref, reader: Ref } {
        const id = try std.fmt.allocPrint(self.gpa, "{d}", .{self.next_id});
        errdefer self.gpa.free(id);
        self.next_id += 1;

        const writer_key = try randomKey(self.gpa);
        errdefer self.gpa.free(writer_key);
        const reader_key = try randomKey(self.gpa);
        errdefer self.gpa.free(reader_key);

        const pipe = try Pipe.create(self.gpa, capacity);
        errdefer pipe.release();

        try self.entries.put(id, .{
            .writer_key = writer_key,
            .reader_key = reader_key,
            .owner = owner,
            .pipe = pipe,
            .last_activity_ms = now_ms,
        });

        return .{
            .writer = .{ .channel_id = id, .access_key = writer_key, .direction = .write },
            .reader = .{ .channel_id = id, .access_key = reader_key, .direction = .read },
        };
    }

    pub fn takeSender(
        self: *Channels,
        id: []const u8,
        key: []const u8,
        now_ms: i64,
    ) error{ NotFound, BadKey, AlreadyTaken }!Sender {
        const entry = self.entries.getPtr(id) orelse return error.NotFound;
        if (!keyEql(entry.writer_key, key)) return error.BadKey;
        if (entry.writer_taken) return error.AlreadyTaken;
        entry.writer_taken = true;
        entry.last_activity_ms = now_ms;
        entry.pipe.retain();
        return .{ .pipe = entry.pipe };
    }

    pub fn takeReceiver(
        self: *Channels,
        id: []const u8,
        key: []const u8,
        now_ms: i64,
    ) error{ NotFound, BadKey, AlreadyTaken }!Receiver {
        const entry = self.entries.getPtr(id) orelse return error.NotFound;
        if (!keyEql(entry.reader_key, key)) return error.BadKey;
        if (entry.reader_taken) return error.AlreadyTaken;
        entry.reader_taken = true;
        entry.last_activity_ms = now_ms;
        entry.pipe.retain();
        return .{ .pipe = entry.pipe };
    }

    /// Reap channels idle for >= ttl_ms. Pipe streaming since the previous
    /// sweep counts as activity and refreshes the timestamp to this sweep's
    /// `now_ms` (the registry never observes pushes/pops directly).
    pub fn sweepIdle(self: *Channels, now_ms: i64) usize {
        var to_reap: std.ArrayList([]const u8) = .empty;
        defer to_reap.deinit(self.gpa);

        var it = self.entries.iterator();
        while (it.next()) |kv| {
            const entry = kv.value_ptr;
            const current_activity = blk: {
                entry.pipe.mutex.lock();
                defer entry.pipe.mutex.unlock();
                break :blk entry.pipe.activity;
            };
            if (current_activity != entry.seen_activity) {
                entry.seen_activity = current_activity;
                entry.last_activity_ms = now_ms;
                continue;
            }
            if (now_ms - entry.last_activity_ms >= self.ttl_ms) {
                to_reap.append(self.gpa, kv.key_ptr.*) catch break;
            }
        }

        for (to_reap.items) |id| self.removeAndReap(id);
        return to_reap.items.len;
    }

    /// Owner disconnected: reap every channel it created. Live endpoint
    /// holders see EndOfStream/ReceiverGone; refcounts free memory safely.
    pub fn reapOwner(self: *Channels, owner: WorkerId) usize {
        var to_reap: std.ArrayList([]const u8) = .empty;
        defer to_reap.deinit(self.gpa);

        var it = self.entries.iterator();
        while (it.next()) |kv| {
            if (std.mem.eql(u8, &kv.value_ptr.owner, &owner)) {
                to_reap.append(self.gpa, kv.key_ptr.*) catch break;
            }
        }

        for (to_reap.items) |id| self.removeAndReap(id);
        return to_reap.items.len;
    }

    pub fn count(self: *const Channels) usize {
        return self.entries.count();
    }

    fn removeAndReap(self: *Channels, id: []const u8) void {
        const removed = self.entries.fetchRemove(id) orelse return;
        var entry = removed.value;
        reapEntry(self.gpa, &entry);
        self.gpa.free(removed.key);
    }
};

fn reapEntry(gpa: std.mem.Allocator, entry: *Entry) void {
    entry.pipe.close(true, true); // wake and end both sides
    entry.pipe.release(); // drop the registry's ref
    gpa.free(entry.writer_key);
    gpa.free(entry.reader_key);
}

fn randomKey(gpa: std.mem.Allocator) error{OutOfMemory}![]const u8 {
    var raw: [32]u8 = undefined;
    entropy.fill(&raw);
    const out = try gpa.alloc(u8, key_len);
    const hex = "0123456789abcdef";
    for (raw, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0xf];
    }
    return out;
}

/// Constant-time comparison so key probing can't time-side-channel the match
/// prefix. Wrong-direction keys fail the same way (don't leak which part was
/// wrong — spec semantics 1).
fn keyEql(stored: []const u8, provided: []const u8) bool {
    if (provided.len != key_len or stored.len != key_len) return false;
    return std.crypto.timing_safe.eql([key_len]u8, stored[0..key_len].*, provided[0..key_len].*);
}

// ===========================================================================
// Tests (docs/specs/channel.md test contract, named exactly)
// ===========================================================================

const testing = std.testing;

fn widOf(n: u8) WorkerId {
    return [_]u8{n} ** 16;
}

test "create returns distinct keys for writer and reader" {
    var ch = Channels.init(testing.allocator, 300_000);
    defer ch.deinit();

    const refs = try ch.create(4, widOf(1), 0);
    try testing.expect(!std.mem.eql(u8, refs.writer.access_key, refs.reader.access_key));
    try testing.expectEqualStrings(refs.writer.channel_id, refs.reader.channel_id);
    try testing.expect(refs.writer.direction == .write);
    try testing.expect(refs.reader.direction == .read);
}

test "takeSender with reader key fails BadKey; correct key succeeds" {
    var ch = Channels.init(testing.allocator, 300_000);
    defer ch.deinit();

    const refs = try ch.create(4, widOf(1), 0);
    try testing.expectError(error.BadKey, ch.takeSender(refs.writer.channel_id, refs.reader.access_key, 0));
    try testing.expectError(error.BadKey, ch.takeSender(refs.writer.channel_id, "garbage", 0));

    var sender = try ch.takeSender(refs.writer.channel_id, refs.writer.access_key, 0);
    sender.deinit();
}

test "second take of same endpoint fails AlreadyTaken" {
    var ch = Channels.init(testing.allocator, 300_000);
    defer ch.deinit();

    const refs = try ch.create(4, widOf(1), 0);
    var sender = try ch.takeSender(refs.writer.channel_id, refs.writer.access_key, 0);
    defer sender.deinit();
    try testing.expectError(error.AlreadyTaken, ch.takeSender(refs.writer.channel_id, refs.writer.access_key, 0));

    var receiver = try ch.takeReceiver(refs.reader.channel_id, refs.reader.access_key, 0);
    defer receiver.deinit();
    try testing.expectError(error.AlreadyTaken, ch.takeReceiver(refs.reader.channel_id, refs.reader.access_key, 0));
}

test "take on unknown id fails NotFound" {
    var ch = Channels.init(testing.allocator, 300_000);
    defer ch.deinit();
    try testing.expectError(error.NotFound, ch.takeSender("nope", "key", 0));
    try testing.expectError(error.NotFound, ch.takeReceiver("nope", "key", 0));
}

test "fifo order preserved across push/pop" {
    var ch = Channels.init(testing.allocator, 300_000);
    defer ch.deinit();

    const refs = try ch.create(8, widOf(1), 0);
    var sender = try ch.takeSender(refs.writer.channel_id, refs.writer.access_key, 0);
    defer sender.deinit();
    var receiver = try ch.takeReceiver(refs.reader.channel_id, refs.reader.access_key, 0);
    defer receiver.deinit();

    var text_buf: [1]u8 = undefined;
    for ("abc") |chr| {
        text_buf[0] = chr;
        try sender.tryPush(.{ .text = &text_buf });
    }
    for ("abc") |expected| {
        const item = (try receiver.tryPop()).?;
        defer item.deinit(testing.allocator);
        try testing.expect(item == .text);
        try testing.expectEqual(expected, item.bytes()[0]);
    }
    try testing.expect((try receiver.tryPop()) == null);
}

test "tryPush on full pipe returns Full; pop frees a slot" {
    var ch = Channels.init(testing.allocator, 300_000);
    defer ch.deinit();

    const refs = try ch.create(2, widOf(1), 0);
    var sender = try ch.takeSender(refs.writer.channel_id, refs.writer.access_key, 0);
    defer sender.deinit();
    var receiver = try ch.takeReceiver(refs.reader.channel_id, refs.reader.access_key, 0);
    defer receiver.deinit();

    var one = [_]u8{'x'};
    try sender.tryPush(.{ .text = &one });
    try sender.tryPush(.{ .text = &one });
    try testing.expectError(error.Full, sender.tryPush(.{ .text = &one }));

    const item = (try receiver.tryPop()).?;
    item.deinit(testing.allocator);
    try sender.tryPush(.{ .text = &one }); // slot freed
}

test "cross-thread stream: producer pushes N items, consumer pops all N in order, then EndOfStream after close" {
    var ch = Channels.init(testing.allocator, 300_000);
    defer ch.deinit();

    const n = 100;
    const refs = try ch.create(4, widOf(1), 0); // capacity 4 forces blocking
    var sender = try ch.takeSender(refs.writer.channel_id, refs.writer.access_key, 0);
    var receiver = try ch.takeReceiver(refs.reader.channel_id, refs.reader.access_key, 0);
    defer receiver.deinit();

    const Producer = struct {
        fn run(s: *Sender) void {
            var i: u8 = 0;
            while (i < n) : (i += 1) {
                var payload = [_]u8{i};
                s.push(.{ .binary = &payload }) catch break;
            }
            s.deinit(); // close: consumer drains then sees EndOfStream
        }
    };
    const t = try std.Thread.spawn(.{}, Producer.run, .{&sender});

    var i: u8 = 0;
    while (i < n) : (i += 1) {
        const item = try receiver.pop();
        defer item.deinit(testing.allocator);
        try testing.expectEqual(i, item.bytes()[0]);
    }
    try testing.expectError(error.EndOfStream, receiver.pop());
    t.join();
}

test "blocked pop wakes on close with EndOfStream" {
    var ch = Channels.init(testing.allocator, 300_000);
    defer ch.deinit();

    const refs = try ch.create(4, widOf(1), 0);
    var sender = try ch.takeSender(refs.writer.channel_id, refs.writer.access_key, 0);
    defer sender.deinit();
    var receiver = try ch.takeReceiver(refs.reader.channel_id, refs.reader.access_key, 0);
    defer receiver.deinit();

    const Consumer = struct {
        fn run(r: *Receiver, saw_eos: *bool) void {
            _ = r.pop() catch {
                saw_eos.* = true;
                return;
            };
        }
    };
    var saw_eos = false;
    const t = try std.Thread.spawn(.{}, Consumer.run, .{ &receiver, &saw_eos });
    sender.close(); // wakes the blocked pop
    t.join();
    try testing.expect(saw_eos);
}

test "push after receiver close fails ReceiverGone" {
    var ch = Channels.init(testing.allocator, 300_000);
    defer ch.deinit();

    const refs = try ch.create(4, widOf(1), 0);
    var sender = try ch.takeSender(refs.writer.channel_id, refs.writer.access_key, 0);
    defer sender.deinit();
    var receiver = try ch.takeReceiver(refs.reader.channel_id, refs.reader.access_key, 0);
    receiver.deinit(); // closes the read side

    var one = [_]u8{'x'};
    try testing.expectError(error.ReceiverGone, sender.push(.{ .text = &one }));
    try testing.expectError(error.ReceiverGone, sender.tryPush(.{ .text = &one }));
}

test "sweepIdle reaps only channels past ttl; activity resets the clock" {
    var ch = Channels.init(testing.allocator, 100);
    defer ch.deinit();

    const a = try ch.create(4, widOf(1), 0);
    const b = try ch.create(4, widOf(1), 0);
    _ = a;

    // Take on b at t=50 refreshes its timestamp.
    var sender = try ch.takeSender(b.writer.channel_id, b.writer.access_key, 50);
    defer sender.deinit();

    // t=120: a idle 120 >= 100 → reaped; b idle 70 → survives.
    try testing.expectEqual(@as(usize, 1), ch.sweepIdle(120));
    try testing.expectEqual(@as(usize, 1), ch.count());

    // Pipe streaming counts as activity: push before the next sweep.
    var one = [_]u8{'x'};
    try sender.tryPush(.{ .text = &one });
    // t=160: b streamed since last sweep → refreshed to 160, survives.
    try testing.expectEqual(@as(usize, 0), ch.sweepIdle(160));
    // t=259: idle 99 < 100 → survives.
    try testing.expectEqual(@as(usize, 0), ch.sweepIdle(259));
    // t=260: idle 100 >= 100 → reaped.
    try testing.expectEqual(@as(usize, 1), ch.sweepIdle(260));
    try testing.expectEqual(@as(usize, 0), ch.count());
}

test "reapOwner reaps that worker's channels only; live endpoint sees clean end" {
    var ch = Channels.init(testing.allocator, 300_000);
    defer ch.deinit();

    const mine = try ch.create(4, widOf(1), 0);
    const other = try ch.create(4, widOf(2), 0);

    var receiver = try ch.takeReceiver(mine.reader.channel_id, mine.reader.access_key, 0);
    defer receiver.deinit();
    var sender = try ch.takeSender(mine.writer.channel_id, mine.writer.access_key, 0);
    defer sender.deinit();

    try testing.expectEqual(@as(usize, 1), ch.reapOwner(widOf(1)));
    try testing.expectEqual(@as(usize, 1), ch.count());

    // Live endpoints observe a clean end, and the other worker's channel survives.
    try testing.expectError(error.EndOfStream, receiver.pop());
    var one = [_]u8{'x'};
    try testing.expectError(error.ReceiverGone, sender.push(.{ .text = &one }));
    try testing.expect(ch.entries.contains(other.reader.channel_id));
}

test "popped item is caller-owned; undrained items freed on deinit (no leaks)" {
    var ch = Channels.init(testing.allocator, 300_000);
    defer ch.deinit();

    const refs = try ch.create(8, widOf(1), 0);
    var sender = try ch.takeSender(refs.writer.channel_id, refs.writer.access_key, 0);
    defer sender.deinit();
    var receiver = try ch.takeReceiver(refs.reader.channel_id, refs.reader.access_key, 0);
    defer receiver.deinit();

    var payload = "hello".*;
    try sender.tryPush(.{ .text = &payload });
    try sender.tryPush(.{ .text = &payload });
    try sender.tryPush(.{ .binary = &payload });

    // Pop one: caller owns it; mutate our source to prove it was duped.
    const item = (try receiver.tryPop()).?;
    payload[0] = 'X';
    try testing.expectEqualStrings("hello", item.bytes());
    item.deinit(testing.allocator);
    // Two undrained items are freed by ch.deinit() (leak-checked allocator).
}

test "no leaks under create/take/close loops" {
    var ch = Channels.init(testing.allocator, 300_000);
    defer ch.deinit();

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const refs = try ch.create(2, widOf(1), 0);
        var sender = try ch.takeSender(refs.writer.channel_id, refs.writer.access_key, 0);
        var receiver = try ch.takeReceiver(refs.reader.channel_id, refs.reader.access_key, 0);
        var one = [_]u8{'x'};
        try sender.tryPush(.{ .text = &one });
        const item = (try receiver.tryPop()).?;
        item.deinit(testing.allocator);
        sender.deinit();
        receiver.deinit();
    }
    try testing.expectEqual(@as(usize, 100), ch.count());
    _ = ch.reapOwner(widOf(1));
    try testing.expectEqual(@as(usize, 0), ch.count());
}
