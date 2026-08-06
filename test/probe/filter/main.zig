//! Filter reality check (M8): runs REAL commands, pipes their REAL output
//! through the dispatcher + filters, and reports what each family actually
//! achieves. Not a pass/fail test — a measurement tool for checking that the
//! noise patterns match what these tools really print on this machine, which
//! a hand-written fixture cannot tell you.
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

pub fn main(init: std.process.Init) !void {
    _ = init;
    const gpa = std.heap.c_allocator;

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

        const sel = zygos.filter_dispatch.select("bash", c.label);
        const filtered = if (sel) |s| (try s.filter(arena, raw)) else null;
        const body = filtered orelse raw;
        const saved: isize = @as(isize, @intCast(raw.len)) - @as(isize, @intCast(body.len));
        const pct: isize = if (raw.len == 0) 0 else @divTrunc(saved * 100, @as(isize, @intCast(raw.len)));

        total_raw += raw.len;
        total_out += body.len;

        std.debug.print("{s:<26} {d:>9} {d:>9} {d:>6}%  {s}\n", .{
            c.label,
            raw.len,
            body.len,
            pct,
            if (sel) |s| @tagName(s.family) else "(none selected)",
        });

        // Surface a filter that selected but declined — usually a sign the
        // noise patterns do not match this tool's real output.
        if (sel != null and filtered == null and raw.len > 200) {
            std.debug.print("{s:<26}   ^ selected but declined to filter\n", .{""});
        }
    }

    std.debug.print("{s}\n", .{"-" ** 74});
    const tp: usize = if (total_raw == 0) 0 else (total_raw - total_out) * 100 / total_raw;
    std.debug.print("{s:<26} {d:>9} {d:>9} {d:>6}%\n\n", .{ "TOTAL", total_raw, total_out, tp });
}
