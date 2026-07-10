//! Zygos binary entry. Thin: kernel wiring only — GPA, actor on its kernel
//! thread, WS gateway on the front. Port from ZYGOS_PORT (default 49134,
//! the iii SDK default). Stopped by killing the process (M0; signal-driven
//! graceful shutdown lands with the supervisor work).
//!
//! `zygos mcp-gateway` (W6): instead of the WS front, serve MCP over stdio —
//! newline-JSON in/out via libc fd 0/1, tessera workers on an in-process bus
//! over the vault at ZYGOS_VAULT_ROOT. Exits on stdin EOF.

const std = @import("std");
const zygos = @import("zygos");
const cli_mission = @import("cli/mission.zig");

pub fn main(proc: std.process.Init) !void {
    const gpa = std.heap.c_allocator;

    var args = std.process.Args.Iterator.init(proc.minimal.args);
    _ = args.next(); // argv[0]
    if (args.next()) |cmd| {
        if (std.mem.eql(u8, cmd, "mcp-gateway")) return runMcpGateway(gpa);
        if (std.mem.eql(u8, cmd, "mission")) std.process.exit(cli_mission.run(gpa, &args));
        std.debug.print("unknown command: {s} (try: zygos | zygos mission | zygos mcp-gateway)\n", .{cmd});
        std.process.exit(2);
    }

    var config: zygos.net.Config = .{};
    if (std.c.getenv("ZYGOS_PORT")) |raw| {
        config.port = std.fmt.parseInt(u16, std.mem.span(raw), 10) catch config.port;
    }

    const gateway = try zygos.net.Gateway.create(gpa, config);
    defer gateway.destroy();

    var actor = try zygos.actor.Actor.init(gpa, .{}, gateway.outbound());
    defer actor.deinit();
    gateway.bind(&actor);

    const kernel_thread = try std.Thread.spawn(.{}, zygos.actor.Actor.run, .{&actor});

    try gateway.start();
    gateway.wait(); // parks until the listener exits

    actor.post(.shutdown);
    kernel_thread.join();
}

// ---------------------------------------------------------------------------
// mcp-gateway subcommand (W6 binary glue; the pure layer is worker/mcp/gateway.zig)
// ---------------------------------------------------------------------------

/// Adapts an inproc bus worker to the pure gateway's Caller vtable: bus
/// payloads are gpa-owned, replies must be arena-owned, so each result is
/// duped across and the original freed.
const BusCaller = struct {
    gpa: std.mem.Allocator,
    worker: *zygos.inproc.Worker,

    fn caller(self: *BusCaller) zygos.mcp_gateway.Caller {
        return .{ .ctx = self, .callFn = &callFn };
    }

    fn callFn(ctx: *anyopaque, function: []const u8, request_json: []const u8, arena: std.mem.Allocator) zygos.mcp_gateway.CallError!zygos.mcp_gateway.Result {
        const self: *BusCaller = @ptrCast(@alignCast(ctx));
        const res = try self.worker.call(function, request_json);
        defer res.deinit(self.gpa);
        return switch (res) {
            .ok => |p| .{ .ok = try arena.dupe(u8, p) },
            .err => |c| .{ .err = try arena.dupe(u8, c) },
        };
    }
};

fn runMcpGateway(gpa: std.mem.Allocator) !void {
    const root_z = std.c.getenv("ZYGOS_VAULT_ROOT") orelse {
        std.debug.print("mcp-gateway: ZYGOS_VAULT_ROOT is required\n", .{});
        std.process.exit(2);
    };
    const root = std.mem.span(root_z);

    var registry = zygos.inproc.Registry.init(gpa, null);
    defer registry.deinit();
    var actor = try zygos.actor.Actor.init(gpa, .{}, registry.outbound());
    defer actor.deinit();
    const kernel_thread = try std.Thread.spawn(.{}, zygos.actor.Actor.run, .{&actor});

    // The tessera surface. Capture stays unregistered here — it needs a
    // provider + taxonomy; calling its tool through this gateway is a bus
    // error (fail closed), not a half-configured worker.
    var today_buf: [10]u8 = undefined;
    const orient = try zygos.tessera_orient.OrientWorker.start(gpa, &actor, &registry, .{
        .root = root,
        .today = todayStamp(&today_buf),
    });
    const continuity = try zygos.tessera_continuity.ContinuityWorker.start(gpa, &actor, &registry, .{ .root = root });
    const undo = try zygos.tessera_undo.UndoWorker.start(gpa, &actor, &registry, .{ .root = root });

    const gw_worker = try zygos.inproc.Worker.spawn(gpa, &actor, &registry, "mcp-gateway");
    var bus_caller: BusCaller = .{ .gpa = gpa, .worker = gw_worker };

    serveStdio(gpa, bus_caller.caller());

    gw_worker.stop();
    undo.stop();
    continuity.stop();
    orient.stop();
    actor.post(.shutdown);
    kernel_thread.join();
}

/// Newline-JSON loop over libc fd 0/1 (Z-02: no std.Io outside net/). One
/// arena per message. EOF ends the serve; write errors end it too (the
/// client is gone).
fn serveStdio(gpa: std.mem.Allocator, caller: zygos.mcp_gateway.Caller) void {
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(gpa);
    var buf: [4096]u8 = undefined;

    while (true) {
        const n = std.c.read(0, &buf, buf.len);
        if (n <= 0) return; // EOF or error: the client hung up
        pending.appendSlice(gpa, buf[0..@intCast(n)]) catch return;

        while (std.mem.indexOfScalar(u8, pending.items, '\n')) |nl| {
            var arena_state = std.heap.ArenaAllocator.init(gpa);
            defer arena_state.deinit();
            const line = pending.items[0..nl];
            const reply = zygos.mcp_gateway.handle(arena_state.allocator(), caller, line) catch null;
            if (reply) |r| {
                if (!writeAll(1, r) or !writeAll(1, "\n")) return;
            }
            // Shift out the consumed line (buffer stays small: one message).
            const rest = pending.items[nl + 1 ..];
            std.mem.copyForwards(u8, pending.items[0..rest.len], rest);
            pending.shrinkRetainingCapacity(rest.len);
        }
    }
}

fn writeAll(fd: c_int, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.c.write(fd, bytes.ptr + off, bytes.len - off);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

/// Wall-clock "YYYY-MM-DD" (UTC) for orient's staleness math.
fn todayStamp(buf: *[10]u8) []const u8 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    const ep: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(0, ts.sec)) };
    const yd = ep.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    _ = std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        yd.year, md.month.numeric(), md.day_index + 1,
    }) catch unreachable;
    return buf;
}
