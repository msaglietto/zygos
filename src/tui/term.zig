//! Terminal seam: named escape sequences, a vtable the renderer draws
//! through (so tests capture bytes instead of touching a tty), and the real
//! termios-backed implementation. The TUI writes to fd 2 and reads keys from
//! fd 0 — stdout stays reserved for the final mission JSON.

const std = @import("std");

pub const Size = struct { cols: usize, rows: usize };

/// Escape sequences the renderer emits. Curated from zot's terminal.go —
/// works across iTerm/Ghostty/Kitty/Alacritty/Apple Terminal/VS Code.
pub const esc = struct {
    pub const hide_cursor = "\x1b[?25l";
    pub const show_cursor = "\x1b[?25h";
    pub const clear_line = "\x1b[2K";
    pub const clear_below = "\x1b[0J";
    pub const sync_on = "\x1b[?2026h"; // synchronized output: frame presents atomically
    pub const sync_off = "\x1b[?2026l";
    pub const sgr_reset = "\x1b[0m";

    pub fn moveTo(buf: []u8, row: usize, col: usize) []const u8 {
        return std.fmt.bufPrint(buf, "\x1b[{d};{d}H", .{ row, col }) catch unreachable;
    }

    pub fn cursorUp(buf: []u8, n: usize) []const u8 {
        if (n == 0) return "";
        return std.fmt.bufPrint(buf, "\x1b[{d}A", .{n}) catch unreachable;
    }

    pub fn cursorDown(buf: []u8, n: usize) []const u8 {
        if (n == 0) return "";
        return std.fmt.bufPrint(buf, "\x1b[{d}B", .{n}) catch unreachable;
    }

    pub fn cursorCol(buf: []u8, col: usize) []const u8 {
        return std.fmt.bufPrint(buf, "\x1b[{d}G", .{col}) catch unreachable;
    }
};

/// The renderer's only IO surface. Writes must not fail (best-effort UI);
/// readKey returns null on timeout or EOF.
pub const Terminal = struct {
    ctx: *anyopaque,
    writeFn: *const fn (ctx: *anyopaque, bytes: []const u8) void,
    sizeFn: *const fn (ctx: *anyopaque) Size,
    readKeyFn: *const fn (ctx: *anyopaque, timeout_ms: i32) ?u8,

    pub fn write(self: Terminal, bytes: []const u8) void {
        self.writeFn(self.ctx, bytes);
    }

    pub fn size(self: Terminal) Size {
        return self.sizeFn(self.ctx);
    }

    pub fn readKey(self: Terminal, timeout_ms: i32) ?u8 {
        return self.readKeyFn(self.ctx, timeout_ms);
    }
};

/// Termios snapshot for the panic/signal path. One tty per process, so a
/// module-level slot suffices; enterRaw fills it, restore clears it.
var emergency_saved: ?std.c.termios = null;
/// Dup of the original fd 2 (the tty) while stderr is redirected.
var emergency_saved_stderr: ?c_int = null;

/// Best-effort terminal repair for panic and signal handlers: put the real
/// tty back on fd 2 (so the panic message is visible, not swallowed by the
/// stderr log file), re-show the cursor, reset SGR, end synchronized
/// output, restore cooked mode. Only async-signal-safe calls (dup2, write,
/// tcsetattr). Idempotent, never fails.
pub fn emergencyRestore() void {
    if (emergency_saved_stderr) |tty| {
        _ = std.c.dup2(tty, 2);
        emergency_saved_stderr = null;
    }
    const seq = esc.show_cursor ++ esc.sgr_reset ++ esc.sync_off ++ "\r\n";
    _ = std.c.write(2, seq, seq.len);
    if (emergency_saved) |t| {
        _ = std.c.tcsetattr(0, .FLUSH, &t);
        emergency_saved = null;
    }
}

/// Real tty on fd 2 (out) / fd 0 (in). enterRaw/restore are idempotent;
/// restore also re-shows the cursor and resets SGR so an aborted TUI never
/// leaves the shell garbled.
pub const RealTerm = struct {
    saved: ?std.c.termios = null,
    /// Where frames go: fd 2, or a dup of the tty while stderr is redirected.
    out_fd: c_int = 2,
    /// Dup of the original fd 2, kept to undo redirectStderr.
    saved_stderr: ?c_int = null,

    pub fn isTty() bool {
        return std.c.isatty(2) != 0 and std.c.isatty(0) != 0;
    }

    /// Point fd 2 at `log_path` (append) and keep rendering on a dup of the
    /// real tty. Anything that writes stderr directly — std.debug stack
    /// dumps on unexpected errnos (Debug builds), stray prints from deps —
    /// lands in the log instead of splicing into the repaint band. The
    /// logbridge still captures std.log lines as footnotes; this catches
    /// the writers that bypass std.log entirely. Best-effort: any failure
    /// leaves fd 2 untouched.
    pub fn redirectStderr(self: *RealTerm, log_path: [*:0]const u8) void {
        if (self.saved_stderr != null) return;
        const tty = std.c.dup(2);
        if (tty < 0) return;
        const log_fd = std.c.open(log_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, @as(std.c.mode_t, 0o644));
        if (log_fd < 0) {
            _ = std.c.close(tty);
            return;
        }
        if (std.c.dup2(log_fd, 2) < 0) {
            _ = std.c.close(tty);
            _ = std.c.close(log_fd);
            return;
        }
        _ = std.c.close(log_fd);
        self.out_fd = tty;
        self.saved_stderr = tty;
        emergency_saved_stderr = tty;
    }

    /// Byte-in-byte-out mode on fd 0: no echo, no line buffering, signals
    /// arrive as bytes (0x03 = Ctrl-C — the input loop decides). Returns
    /// false when fd 0 is not a tty.
    pub fn enterRaw(self: *RealTerm) bool {
        if (self.saved != null) return true;
        var t: std.c.termios = undefined;
        if (std.c.tcgetattr(0, &t) != 0) return false;
        self.saved = t;
        emergency_saved = t;
        t.lflag.ECHO = false;
        t.lflag.ICANON = false;
        t.lflag.ISIG = false;
        t.lflag.IEXTEN = false;
        t.iflag.IXON = false;
        t.iflag.ICRNL = false;
        t.iflag.BRKINT = false;
        t.cc[@intFromEnum(std.c.V.MIN)] = 0;
        t.cc[@intFromEnum(std.c.V.TIME)] = 0;
        if (std.c.tcsetattr(0, .FLUSH, &t) != 0) {
            self.saved = null;
            return false;
        }
        return true;
    }

    /// Idempotent; safe to call without a prior enterRaw. Also undoes
    /// redirectStderr, putting the real tty back on fd 2.
    pub fn restore(self: *RealTerm) void {
        writeFd(self.out_fd, esc.show_cursor ++ esc.sgr_reset ++ esc.sync_off);
        if (self.saved) |t| {
            _ = std.c.tcsetattr(0, .FLUSH, &t);
            self.saved = null;
            emergency_saved = null;
        }
        if (self.saved_stderr) |tty| {
            _ = std.c.dup2(tty, 2);
            _ = std.c.close(tty);
            self.saved_stderr = null;
            self.out_fd = 2;
            emergency_saved_stderr = null;
        }
    }

    pub fn terminal(self: *RealTerm) Terminal {
        return .{
            .ctx = @ptrCast(self),
            .writeFn = &realWrite,
            .sizeFn = &realSize,
            .readKeyFn = &realReadKey,
        };
    }

    fn realWrite(ctx: *anyopaque, bytes: []const u8) void {
        const self: *RealTerm = @ptrCast(@alignCast(ctx));
        writeFd(self.out_fd, bytes);
    }

    fn realSize(ctx: *anyopaque) Size {
        const self: *RealTerm = @ptrCast(@alignCast(ctx));
        var ws: std.c.winsize = undefined;
        if (std.c.ioctl(self.out_fd, std.c.T.IOCGWINSZ, &ws) == 0 and ws.col > 0 and ws.row > 0) {
            return .{ .cols = ws.col, .rows = ws.row };
        }
        return .{ .cols = 80, .rows = 24 };
    }

    fn realReadKey(_: *anyopaque, timeout_ms: i32) ?u8 {
        var fds = [_]std.c.pollfd{.{ .fd = 0, .events = std.c.POLL.IN, .revents = 0 }};
        if (std.c.poll(&fds, 1, timeout_ms) <= 0) return null;
        var b: [1]u8 = undefined;
        if (std.c.read(0, &b, 1) != 1) return null;
        return b[0];
    }

    fn writeFd(fd: c_int, bytes: []const u8) void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = std.c.write(fd, bytes.ptr + off, bytes.len - off);
            if (n <= 0) return;
            off += @intCast(n);
        }
    }
};

/// Test double: captures every written byte, serves scripted keys, reports a
/// fixed size. Owned by the test; not thread-safe.
pub const FakeTerm = struct {
    gpa: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,
    keys: []const u8 = "",
    key_idx: usize = 0,
    fixed: Size = .{ .cols = 80, .rows = 24 },

    pub fn init(gpa: std.mem.Allocator) FakeTerm {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *FakeTerm) void {
        self.out.deinit(self.gpa);
    }

    pub fn terminal(self: *FakeTerm) Terminal {
        return .{
            .ctx = @ptrCast(self),
            .writeFn = &fakeWrite,
            .sizeFn = &fakeSize,
            .readKeyFn = &fakeReadKey,
        };
    }

    pub fn written(self: *const FakeTerm) []const u8 {
        return self.out.items;
    }

    pub fn clear(self: *FakeTerm) void {
        self.out.clearRetainingCapacity();
    }

    fn fakeWrite(ctx: *anyopaque, bytes: []const u8) void {
        const self: *FakeTerm = @ptrCast(@alignCast(ctx));
        self.out.appendSlice(self.gpa, bytes) catch {};
    }

    fn fakeSize(ctx: *anyopaque) Size {
        const self: *FakeTerm = @ptrCast(@alignCast(ctx));
        return self.fixed;
    }

    fn fakeReadKey(ctx: *anyopaque, timeout_ms: i32) ?u8 {
        _ = timeout_ms;
        const self: *FakeTerm = @ptrCast(@alignCast(ctx));
        if (self.key_idx >= self.keys.len) return null;
        const b = self.keys[self.key_idx];
        self.key_idx += 1;
        return b;
    }
};

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "moveTo emits CSI row;col H" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("\x1b[3;1H", esc.moveTo(&buf, 3, 1));
    try testing.expectEqualStrings("\x1b[120;42H", esc.moveTo(&buf, 120, 42));
}

test "cursorUp and cursorDown emit CSI n A/B; zero is a no-op" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("\x1b[2A", esc.cursorUp(&buf, 2));
    try testing.expectEqualStrings("\x1b[7B", esc.cursorDown(&buf, 7));
    try testing.expectEqualStrings("", esc.cursorUp(&buf, 0));
    try testing.expectEqualStrings("", esc.cursorDown(&buf, 0));
}

test "FakeTerm captures writes in order" {
    var fake = FakeTerm.init(testing.allocator);
    defer fake.deinit();
    const t = fake.terminal();
    t.write("abc");
    t.write(esc.clear_line);
    try testing.expectEqualStrings("abc\x1b[2K", fake.written());
}

test "FakeTerm serves scripted keys then null" {
    var fake = FakeTerm.init(testing.allocator);
    defer fake.deinit();
    fake.keys = "yn";
    const t = fake.terminal();
    try testing.expectEqual(@as(?u8, 'y'), t.readKey(0));
    try testing.expectEqual(@as(?u8, 'n'), t.readKey(0));
    try testing.expectEqual(@as(?u8, null), t.readKey(0));
}

test "FakeTerm reports its fixed size" {
    var fake = FakeTerm.init(testing.allocator);
    defer fake.deinit();
    fake.fixed = .{ .cols = 120, .rows = 40 };
    try testing.expectEqual(@as(usize, 120), fake.terminal().size().cols);
    try testing.expectEqual(@as(usize, 40), fake.terminal().size().rows);
}

test "restore before enterRaw is a safe no-op" {
    var real = RealTerm{};
    real.restore(); // must not crash or touch termios (saved == null)
    try testing.expectEqual(@as(?std.c.termios, null), real.saved);
}
