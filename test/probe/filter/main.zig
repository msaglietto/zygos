//! Filter reality check (M8): runs REAL commands and pipes their REAL output
//! through `zygos::output::compress` — the seam the turn driver uses, envelope
//! and all. Not a pass/fail test — a measurement of what that seam keeps.
//!
//! Run with `zig build filter-probe`.

const std = @import("std");
const zygos = @import("zygos");

extern "c" fn popen(cmd: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn pclose(stream: ?*anyopaque) c_int;
extern "c" fn fread(ptr: *anyopaque, size: usize, n: usize, stream: ?*anyopaque) usize;

fn capture(gpa: std.mem.Allocator, cmd: [:0]const u8) ![]u8 {
    const f = popen(cmd.ptr, "r") orelse return error.PopenFailed;
    defer _ = pclose(f);
    var out: std.ArrayList(u8) = .empty;
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = fread(&chunk, 1, chunk.len, f);
        if (n == 0) break;
        try out.appendSlice(gpa, chunk[0..n]);
    }
    return out.toOwnedSlice(gpa);
}

const Seam = struct {
    registry: zygos.inproc.Registry,
    actor: zygos.actor.Actor,
    kernel: std.Thread,
    caller: *zygos.inproc.Worker,
    trim: *zygos.trim.TrimWorker,

    fn init(gpa: std.mem.Allocator) !*Seam {
        const self = try gpa.create(Seam);
        self.registry = zygos.inproc.Registry.init(gpa, null);
        self.actor = try zygos.actor.Actor.init(gpa, .{}, self.registry.outbound());
        self.kernel = try std.Thread.spawn(.{}, zygos.actor.Actor.run, .{&self.actor});
        self.caller = try zygos.inproc.Worker.spawn(gpa, &self.actor, &self.registry, "probe");
        self.trim = try zygos.trim.TrimWorker.start(gpa, &self.actor, &self.registry, .{}, null);
        return self;
    }

    fn deinit(self: *Seam) void {
        const gpa = self.actor.gpa;
        self.trim.stop();
        self.caller.stop();
        self.actor.post(.shutdown);
        self.kernel.join();
        self.actor.deinit();
        self.registry.deinit();
        gpa.destroy(self);
    }
};

fn payloadLen(arena: std.mem.Allocator, reply_json: []const u8, raw_len: usize) usize {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, reply_json, .{}) catch return raw_len;
    if (root != .object) return raw_len;
    const content = root.object.get("content") orelse return raw_len;
    if (content != .string) return raw_len;
    const inner = std.json.parseFromSliceLeaky(std.json.Value, arena, content.string, .{}) catch
        return content.string.len;
    if (inner == .object) {
        if (inner.object.get("output")) |o| if (o == .string) return o.string.len;
        if (inner.object.get("text")) |o| if (o == .string) return o.string.len;
    }
    return content.string.len;
}

pub fn main(init: std.process.Init) !void {
    _ = init;
    const gpa = std.heap.c_allocator;
    var seam = try Seam.init(gpa);
    defer seam.deinit();

    const cases = [_]struct { cmd: [:0]const u8, label: []const u8 }{
        .{ .cmd = "git status 2>&1", .label = "git status" },
        .{ .cmd = "git log -20 2>&1", .label = "git log -20" },
        .{ .cmd = "git diff HEAD~1 2>&1", .label = "git diff HEAD~1" },
        .{ .cmd = "ls -la src/worker 2>&1", .label = "ls -la src/worker" },
        .{ .cmd = "find src -name '*.zig' 2>&1", .label = "find src -name *.zig" },
        .{ .cmd = "zig build test 2>&1", .label = "zig build test" },
        .{ .cmd = "zig build 2>&1", .label = "zig build" },
    };

    var total_raw: usize = 0;
    var total_out: usize = 0;

    std.debug.print("\n{s:<26} {s:>9} {s:>9} {s:>7}  {s}\n", .{ "command", "raw", "filtered", "saved", "filter" });
    std.debug.print("{s}\n", .{"-" ** 74});

    for (cases) |c| {
        const raw = capture(gpa, c.cmd) catch |e| {
            std.debug.print("{s:<26} capture failed: {t}\n", .{ c.label, e });
            continue;
        };
        defer gpa.free(raw);

        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        // The label is the command the seam classifies. The captured argv
        // carries `2>&1`, which the dispatcher treats as a pipeline and skips.
        const envelope = try std.fmt.allocPrint(arena, "{{\"exit_code\":0,\"output\":{f}}}", .{std.json.fmt(raw, .{})});
        const req = try std.fmt.allocPrint(
            arena,
            "{{\"content\":{f},\"tool\":\"bash\",\"input\":{{\"command\":{f}}}}}",
            .{ std.json.fmt(envelope, .{}), std.json.fmt(c.label, .{}) },
        );
        const res = seam.caller.call("zygos::output::compress", req) catch |e| {
            std.debug.print("{s:<26} seam failed: {t}\n", .{ c.label, e });
            continue;
        };
        defer res.deinit(gpa);
        if (res != .ok) {
            std.debug.print("{s:<26} seam error: {s}\n", .{ c.label, res.err });
            continue;
        }

        const body_len = payloadLen(arena, res.ok, raw.len);
        const saved: isize = @as(isize, @intCast(raw.len)) - @as(isize, @intCast(body_len));
        const pct: isize = if (raw.len == 0) 0 else @divTrunc(saved * 100, @as(isize, @intCast(raw.len)));

        total_raw += raw.len;
        total_out += body_len;

        std.debug.print("{s:<26} {d:>9} {d:>9} {d:>6}%  {s}\n", .{
            c.label,
            raw.len,
            body_len,
            pct,
            "seam",
        });

        if (body_len == raw.len and raw.len > 200) {
            std.debug.print("{s:<26}   ^ seam left the payload unchanged\n", .{""});
        }
    }

    std.debug.print("{s}\n", .{"-" ** 74});
    const tp: usize = if (total_raw == 0) 0 else (total_raw - total_out) * 100 / total_raw;
    std.debug.print("{s:<26} {d:>9} {d:>9} {d:>6}%\n\n", .{ "TOTAL", total_raw, total_out, tp });
}
