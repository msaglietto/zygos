//! WebSocket gateway (S6 path) — the only module that touches sockets.
//! Composes protocol.zig + actor.zig per docs/specs/net.md: handler callbacks
//! post `Command`s; the `Outbound` implementation writes frames back to the
//! owning connection. Backed by karlseguin/websocket.zig, which requires
//! `std.Io.Threaded` — permitted here and only here by the Z-02 amendment
//! (GOAL.md, 2026-07-07); kernel modules stay std.Io-free.
//!
//! Connection lifecycle (spec): accept → fresh WorkerId (UUID v4) → register
//! in the conn table → post worker_connected (actor answers workerregistered).
//! Text frame → parse → post .frame with poster-stamped now_ms — the only
//! wall-clock reads in the system live in this file. Parse failure → log,
//! drop the frame, keep the connection. Binary telemetry magic (OTLP/MTRC/
//! LOGS) → accept + drop (M0 stub); other binary falls through to JSON.
//! Close → post worker_disconnected exactly once.

const std = @import("std");
const websocket = @import("websocket");
const actor_mod = @import("../kernel/actor.zig");
const protocol = @import("../kernel/protocol.zig");
const types = @import("../kernel/types.zig");
const sync = @import("../kernel/sync.zig");

const log = std.log.scoped(.ws);

pub const WorkerId = types.WorkerId;

pub const Config = struct {
    address: []const u8 = "127.0.0.1",
    port: u16 = 49134, // iii Node SDK default (measured, docs/specs/net.md)
    tick_interval_ms: u64 = 250,
    max_frame_bytes: usize = 16 * 1024 * 1024,
};

/// Wall-clock milliseconds. The gateway stamps commands so the kernel never
/// reads a clock (actor spec boundary contract 3).
pub fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

/// Fresh worker identity: 16 random bytes with RFC 4122 v4 version/variant
/// bits, so the uuid text the SDK sees is well-formed.
fn newWorkerId() WorkerId {
    var id: WorkerId = undefined;
    std.c.arc4random_buf(&id, id.len);
    id[6] = (id[6] & 0x0f) | 0x40;
    id[8] = (id[8] & 0x3f) | 0x80;
    return id;
}

/// M0 telemetry stub: binary frames with a known 4-byte magic are accepted
/// and dropped; anything else falls through to JSON decode (PROTOCOL.md).
fn isTelemetryMagic(data: []const u8) bool {
    if (data.len < 4) return false;
    const magic = data[0..4];
    return std.mem.eql(u8, magic, "OTLP") or
        std.mem.eql(u8, magic, "MTRC") or
        std.mem.eql(u8, magic, "LOGS");
}

pub const Gateway = struct {
    gpa: std.mem.Allocator,
    config: Config,
    actor: *actor_mod.Actor,
    conns: ConnTable,
    io_backing: std.Io.Threaded,
    server: ?websocket.Server(Handler) = null,
    listen_thread: ?std.Thread = null,
    timer_thread: ?std.Thread = null,
    timer_stop: sync.ResetEvent = .{},

    /// Two-phase construction (Actor and Gateway reference each other):
    /// create the Gateway with a placeholder, init the Actor with
    /// `gateway.outbound()`, then `gateway.bind(&actor)` before `start()`.
    pub fn create(gpa: std.mem.Allocator, config: Config) error{OutOfMemory}!*Gateway {
        const self = try gpa.create(Gateway);
        self.* = .{
            .gpa = gpa,
            .config = config,
            .actor = undefined, // set by bind()
            .conns = .{ .map = std.AutoHashMap(WorkerId, *websocket.Conn).init(gpa) },
            .io_backing = std.Io.Threaded.init(gpa, .{}),
        };
        return self;
    }

    pub fn bind(self: *Gateway, actor: *actor_mod.Actor) void {
        self.actor = actor;
    }

    pub fn destroy(self: *Gateway) void {
        if (self.server) |*s| s.deinit();
        self.io_backing.deinit();
        self.conns.map.deinit();
        self.conns.mutex.deinit();
        self.timer_stop.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    pub fn outbound(self: *Gateway) actor_mod.Outbound {
        return .{ .ctx = self, .sendFn = &sendFn };
    }

    /// Start the WS listener + tick timer. Returns once both threads run.
    pub fn start(self: *Gateway) !void {
        self.server = try websocket.Server(Handler).init(self.io_backing.io(), self.gpa, .{
            .address = self.config.address,
            .port = self.config.port,
            .max_message_size = self.config.max_frame_bytes,
            .handshake = .{ .timeout = 10 },
        });
        self.listen_thread = try self.server.?.listenInNewThread(self);
        self.timer_thread = try std.Thread.spawn(.{}, timerLoop, .{self});
        log.info("zygos kernel listening on ws://{s}:{d}", .{ self.config.address, self.config.port });
    }

    pub fn stop(self: *Gateway) void {
        self.timer_stop.set();
        if (self.timer_thread) |t| t.join();
        if (self.server) |*s| s.stop();
        if (self.listen_thread) |t| t.join();
    }

    /// Block until the listener exits (main-thread parking for the binary).
    pub fn wait(self: *Gateway) void {
        if (self.listen_thread) |t| {
            t.join();
            self.listen_thread = null;
        }
    }

    // -- conn table -----------------------------------------------------------

    const ConnTable = struct {
        mutex: sync.Mutex = .{},
        map: std.AutoHashMap(WorkerId, *websocket.Conn),
    };

    fn addConn(self: *Gateway, id: WorkerId, conn: *websocket.Conn) error{OutOfMemory}!void {
        self.conns.mutex.lock();
        defer self.conns.mutex.unlock();
        try self.conns.map.put(id, conn);
    }

    /// Returns false if already removed — the exactly-once disconnect guard.
    fn removeConn(self: *Gateway, id: WorkerId) bool {
        self.conns.mutex.lock();
        defer self.conns.mutex.unlock();
        return self.conns.map.remove(id);
    }

    /// Outbound implementation. The write happens under the table mutex:
    /// this serializes sends and guarantees a closing connection cannot be
    /// freed mid-write (Handler.close's removeConn blocks until the write
    /// completes; after removal no new send can reach the conn). M0
    /// simplicity — per-connection writer queues (cap 64) are the M1
    /// hardening called out in docs/specs/net.md.
    fn sendFn(ctx: *anyopaque, to: WorkerId, frame: []const u8) actor_mod.SendError!void {
        const self: *Gateway = @ptrCast(@alignCast(ctx));
        self.conns.mutex.lock();
        defer self.conns.mutex.unlock();
        const conn = self.conns.map.get(to) orelse return error.Disconnected;
        conn.writeText(frame) catch return error.Disconnected;
    }

    // -- timer ----------------------------------------------------------------

    fn timerLoop(self: *Gateway) void {
        const interval: std.c.timespec = .{
            .sec = @intCast(self.config.tick_interval_ms / 1000),
            .nsec = @intCast((self.config.tick_interval_ms % 1000) * std.time.ns_per_ms),
        };
        while (!self.timer_stop.isSet()) {
            var rem: std.c.timespec = undefined;
            _ = std.c.nanosleep(&interval, &rem);
            self.actor.post(.{ .tick = nowMs() });
        }
    }
};

/// One instance per connection, driven by websocket.zig's worker threads.
pub const Handler = struct {
    gw: *Gateway,
    worker_id: WorkerId,

    pub fn init(_: *const websocket.Handshake, conn: *websocket.Conn, gw: *Gateway) !Handler {
        const id = newWorkerId();
        try gw.addConn(id, conn);
        gw.actor.post(.{ .worker_connected = id });
        return .{ .gw = gw, .worker_id = id };
    }

    pub fn clientMessage(self: *Handler, data: []const u8, tpe: websocket.MessageTextType) !void {
        if (tpe == .binary and isTelemetryMagic(data)) return; // M0: accept + drop

        const parsed = protocol.parseMessage(self.gw.gpa, data) catch |err| {
            // Tolerate garbage frames without dropping the worker (net spec);
            // the peer is bounded by max_message_size.
            log.warn("unparseable frame from worker ({t}): {s}", .{ err, data[0..@min(data.len, 256)] });
            return;
        };
        self.gw.actor.post(.{ .frame = .{
            .from = self.worker_id,
            .parsed = parsed,
            .now_ms = nowMs(),
        } });
    }

    /// Called once by websocket.zig's cleanup; removeConn's return guards
    /// the exactly-once worker_disconnected.
    pub fn close(self: *Handler) void {
        if (self.gw.removeConn(self.worker_id))
            self.gw.actor.post(.{ .worker_disconnected = self.worker_id });
    }
};

// ===========================================================================
// Tests — socket-free units only; the wire path is verified end-to-end by
// test/e2e/node-sdk (S6).
// ===========================================================================

const testing = std.testing;

test "telemetry magic matches OTLP/MTRC/LOGS and nothing else" {
    try testing.expect(isTelemetryMagic("OTLP...payload"));
    try testing.expect(isTelemetryMagic("MTRC"));
    try testing.expect(isTelemetryMagic("LOGS\x00\x01"));
    try testing.expect(!isTelemetryMagic("otlp lowercase"));
    try testing.expect(!isTelemetryMagic("{\"type\":\"ping\"}"));
    try testing.expect(!isTelemetryMagic("OT"));
    try testing.expect(!isTelemetryMagic(""));
}

test "new worker ids are v4-shaped and unique" {
    const a = newWorkerId();
    const b = newWorkerId();
    try testing.expect(!std.mem.eql(u8, &a, &b));
    try testing.expectEqual(@as(u8, 0x40), a[6] & 0xf0);
    try testing.expect((a[8] & 0xc0) == 0x80);

    // And the text form parses back through the kernel's uuid helpers.
    var buf: [36]u8 = undefined;
    const text = types.formatUuid(a, &buf);
    try testing.expectEqual(a, try types.parseUuid(text));
}

test "nowMs is sane and monotonic-ish" {
    const t1 = nowMs();
    try testing.expect(t1 > 1_700_000_000_000); // after Nov 2023 — clock is real
    const t2 = nowMs();
    try testing.expect(t2 >= t1);
}
