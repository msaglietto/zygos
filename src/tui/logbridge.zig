//! Reroutes std.log lines into the TUI while it owns the terminal. main.zig's
//! log function calls `capture` first; when a hook is installed the line goes
//! to the TUI model (dim footnote) instead of stderr, where it would corrupt
//! the repainting band. Mutex-guarded because workers log concurrently with
//! the CLI installing/clearing the hook.

const std = @import("std");
const sync = @import("../kernel/sync.zig");

pub const Hook = struct {
    ctx: *anyopaque,
    onLine: *const fn (ctx: *anyopaque, line: []const u8) void,
};

var mutex: sync.Mutex = .{};
var hook: ?Hook = null;

pub fn install(h: Hook) void {
    mutex.lock();
    defer mutex.unlock();
    hook = h;
}

pub fn clear() void {
    mutex.lock();
    defer mutex.unlock();
    hook = null;
}

/// True when the line was consumed by an installed hook; false tells the
/// caller to fall back to its normal stderr path. The line bytes are valid
/// only for the duration of the call.
pub fn capture(line: []const u8) bool {
    mutex.lock();
    defer mutex.unlock();
    const h = hook orelse return false;
    h.onLine(h.ctx, line);
    return true;
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

const Recorder = struct {
    buf: [128]u8 = undefined,
    len: usize = 0,
    calls: usize = 0,

    fn onLine(ctx: *anyopaque, line: []const u8) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.len = @min(line.len, self.buf.len);
        @memcpy(self.buf[0..self.len], line[0..self.len]);
        self.calls += 1;
    }
};

test "capture without a hook reports unconsumed" {
    clear();
    try testing.expect(!capture("[x] (warn): hello"));
}

test "an installed hook consumes lines; clear restores fallback" {
    var rec = Recorder{};
    install(.{ .ctx = @ptrCast(&rec), .onLine = &Recorder.onLine });
    defer clear();

    try testing.expect(capture("[mission] (warn): odd"));
    try testing.expectEqual(@as(usize, 1), rec.calls);
    try testing.expectEqualStrings("[mission] (warn): odd", rec.buf[0..rec.len]);

    clear();
    try testing.expect(!capture("[mission] (warn): after"));
    try testing.expectEqual(@as(usize, 1), rec.calls);
}
