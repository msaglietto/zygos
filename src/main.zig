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
const cli_task = @import("cli/task.zig");

// Runtime log filter: ZYGOS_LOG=err|warn|info|debug (default warn). The
// comptime ceiling stays .debug so the filter decides at runtime; workers'
// info-level progress lines are the harness's debug feed (stderr).
pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = filteredLog,
};

/// A panic mid-TUI must repair the terminal (cooked mode, cursor, end
/// synchronized output) BEFORE printing, or the message lands invisibly
/// inside a ?2026 frame on a raw-mode screen.
pub const panic = std.debug.FullPanic(zygosPanic);

fn zygosPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    zygos.tui.emergencyRestore();
    std.debug.defaultPanic(msg, first_trace_addr);
}

var log_filter: std.log.Level = .warn;

fn filteredLog(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(level) > @intFromEnum(log_filter)) return;
    // While the TUI owns stderr, raw log writes would corrupt the repaint
    // band: warn/err become model footnotes, the rest drop.
    if (zygos.tui.logbridge.active()) {
        if (comptime (level == .err or level == .warn)) {
            const prefix = "[" ++ @tagName(scope) ++ "] (" ++ comptime level.asText() ++ "): ";
            var buf: [1024]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, prefix ++ format, args) catch prefix ++ "<line too long>";
            _ = zygos.tui.logbridge.capture(line);
        }
        return;
    }
    std.log.defaultLog(level, scope, format, args);
}

// M7 net hardening: SIGINT lands as a graceful stop, not process death.
// The handler only flips an atomic (async-signal-safe); the main thread
// polls it and runs the ordered teardown. A second SIGINT hard-exits.
var sigint_hits = std.atomic.Value(u8).init(0);

fn onSigint(_: c_int) callconv(.c) void {
    const hits = sigint_hits.fetchAdd(1, .acq_rel);
    if (hits >= 1) {
        zygos.tui.emergencyRestore();
        std.c._exit(130);
    }
}

extern "c" fn signal(sig: c_int, handler: ?*const fn (c_int) callconv(.c) void) ?*const fn (c_int) callconv(.c) void;

pub fn installSigint() void {
    _ = signal(2, &onSigint); // SIGINT
}

pub fn sigintRequested() bool {
    return sigint_hits.load(.acquire) > 0;
}

fn initLogFilter() void {
    const raw = std.c.getenv("ZYGOS_LOG") orelse return;
    const s = std.mem.span(raw);
    log_filter = std.meta.stringToEnum(std.log.Level, s) orelse log_filter;
}

/// Comma-separated ZYGOS_ALLOW_ORIGIN → slices. Process-lifetime config:
/// the allocation rides until exit (freed never, like the env it mirrors).
fn splitOrigins(gpa: std.mem.Allocator, raw: []const u8) []const []const u8 {
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |_| count += 1;
    const out = gpa.alloc([]const u8, count) catch return &.{};
    it = std.mem.splitScalar(u8, raw, ',');
    var i: usize = 0;
    while (it.next()) |o| : (i += 1) out[i] = std.mem.trim(u8, o, " ");
    return out;
}

pub fn main(proc: std.process.Init) !void {
    const gpa = std.heap.c_allocator;

    initLogFilter();
    var args = std.process.Args.Iterator.init(proc.minimal.args);
    _ = args.next(); // argv[0]
    if (args.next()) |cmd| {
        if (std.mem.eql(u8, cmd, "mcp-gateway")) return runMcpGateway(gpa);
        if (std.mem.eql(u8, cmd, "mission")) std.process.exit(cli_mission.run(gpa, &args));
        if (std.mem.eql(u8, cmd, "task")) std.process.exit(cli_task.run(gpa, &args));
        std.debug.print("unknown command: {s} (try: zygos | zygos mission | zygos task | zygos mcp-gateway)\n", .{cmd});
        std.process.exit(2);
    }

    var config: zygos.net.Config = .{};
    if (std.c.getenv("ZYGOS_PORT")) |raw| {
        config.port = std.fmt.parseInt(u16, std.mem.span(raw), 10) catch config.port;
    }
    // Bus admission (see net/ws.zig admitHandshake): a page in the
    // operator's browser must not join the loopback bus. Browsers always
    // send Origin (refused unless allowlisted via ZYGOS_ALLOW_ORIGIN);
    // ZYGOS_TOKEN, when set, must ride ?token= on every peer's open.
    if (std.c.getenv("ZYGOS_TOKEN")) |raw| config.token = std.mem.span(raw);
    if (std.c.getenv("ZYGOS_ALLOW_ORIGIN")) |raw| {
        config.allowed_origins = splitOrigins(gpa, std.mem.span(raw));
    }

    const gateway = try zygos.net.Gateway.create(gpa, config);
    defer gateway.destroy();

    var actor = try zygos.actor.Actor.init(gpa, .{}, gateway.outbound());
    defer actor.deinit();
    gateway.bind(&actor);

    const kernel_thread = try std.Thread.spawn(.{}, zygos.actor.Actor.run, .{&actor});

    try gateway.start();
    installSigint();
    // Park until SIGINT: the ordered teardown (stop listener, shut the
    // kernel down, join) runs on the main thread — never in the handler.
    while (!sigintRequested()) {
        var interval: std.c.timespec = .{ .sec = 0, .nsec = 200 * std.time.ns_per_ms };
        var rem: std.c.timespec = undefined;
        _ = std.c.nanosleep(&interval, &rem);
    }
    std.log.info("SIGINT: stopping gateway and kernel", .{});
    gateway.stop();

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

test {
    std.testing.refAllDecls(cli_mission);
    // The exe test binary's root is this file; nothing references cli/ in
    // test mode (main() is not a test-root), so pull the CLI's pure
    // submodules in explicitly for test discovery.
    std.testing.refAllDecls(@import("cli/mission/req.zig"));
    std.testing.refAllDecls(@import("cli/mission/view.zig"));
    std.testing.refAllDecls(@import("cli/mission/steps.zig"));
    std.testing.refAllDecls(@import("cli/task.zig"));
}
