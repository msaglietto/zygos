//! Colors and animation for the progress view. Spinner frames are derived
//! from the wall clock, not stored state — any thread can render the current
//! frame without coordination (zot's pattern).

const std = @import("std");
const width = @import("width.zig");
const palette = @import("palette.zig");

pub const dim = "\x1b[2m";
pub const bold = "\x1b[1m";
pub const italic = "\x1b[3m";
pub const reset = "\x1b[0m";

/// Palette roles (truecolor + 256 fallback). Kept under the historical
/// `Color` name so call sites read the same.
pub const Color = struct {
    pub const accent = palette.accent;
    pub const ok = palette.ok;
    pub const err = palette.err;
    pub const muted = palette.muted;
    pub const tool = palette.tool;
};

pub const Mode = enum { indexed256, truecolor };

/// Write-once at startup (COLORTERM detection in the CLI), strictly before
/// the render thread exists — read unlocked on every fg/bg emit after that.
var mode: Mode = .indexed256;

pub fn setMode(m: Mode) void {
    mode = m;
}

/// Foreground SGR for a palette role into caller's buffer (≥ 20 bytes):
/// "\x1b[38;2;R;G;Bm" in truecolor mode, "\x1b[38;5;Nm" fallback otherwise.
pub fn fg(buf: []u8, color: palette.Rgb) []const u8 {
    return switch (mode) {
        .indexed256 => std.fmt.bufPrint(buf, "\x1b[38;5;{d}m", .{color.fallback}) catch unreachable,
        .truecolor => std.fmt.bufPrint(buf, "\x1b[38;2;{d};{d};{d}m", .{ color.r, color.g, color.b }) catch unreachable,
    };
}

/// Background SGR for a palette role into caller's buffer (≥ 20 bytes).
pub fn bg(buf: []u8, color: palette.Rgb) []const u8 {
    return switch (mode) {
        .indexed256 => std.fmt.bufPrint(buf, "\x1b[48;5;{d}m", .{color.fallback}) catch unreachable,
        .truecolor => std.fmt.bufPrint(buf, "\x1b[48;2;{d};{d};{d}m", .{ color.r, color.g, color.b }) catch unreachable,
    };
}

pub const spinner_frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
const spinner_interval_ms: i64 = 80;

/// Current spinner glyph for a wall-clock timestamp.
pub fn spinnerFrame(now_ms: i64) []const u8 {
    const tick = @divTrunc(@max(now_ms, 0), spinner_interval_ms);
    return spinner_frames[@intCast(@mod(tick, spinner_frames.len))];
}

/// "Ns" / "MmSSs" / "HhMMm" elapsed since start into caller's buffer.
pub fn elapsed(buf: []u8, start_ms: i64, now_ms: i64) []const u8 {
    const total_s = @divTrunc(@max(now_ms - start_ms, 0), 1000);
    const s = @mod(total_s, 60);
    const m = @mod(@divTrunc(total_s, 60), 60);
    const h = @divTrunc(total_s, 3600);
    if (h > 0) return std.fmt.bufPrint(buf, "{d}h{d:0>2}m", .{ h, m }) catch unreachable;
    if (m > 0) return std.fmt.bufPrint(buf, "{d}m{d:0>2}s", .{ m, s }) catch unreachable;
    return std.fmt.bufPrint(buf, "{d}s", .{s}) catch unreachable;
}

/// "999" / "1.2k" / "3.4M" token counts into caller's buffer.
pub fn tokens(buf: []u8, n: i64) []const u8 {
    const v = @max(n, 0);
    if (v >= 1_000_000) {
        return std.fmt.bufPrint(buf, "{d}.{d}M", .{ @divTrunc(v, 1_000_000), @mod(@divTrunc(v, 100_000), 10) }) catch unreachable;
    }
    if (v >= 1_000) {
        return std.fmt.bufPrint(buf, "{d}.{d}k", .{ @divTrunc(v, 1_000), @mod(@divTrunc(v, 100), 10) }) catch unreachable;
    }
    return std.fmt.bufPrint(buf, "{d}", .{v}) catch unreachable;
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "fg emits the 256-color fallback SGR in indexed mode" {
    var buf: [24]u8 = undefined;
    try testing.expectEqualStrings("\x1b[38;5;75m", fg(&buf, Color.accent));
    try testing.expectEqualStrings("\x1b[38;5;179m", fg(&buf, Color.tool));
}

test "fg and bg emit truecolor SGRs when the mode is set" {
    setMode(.truecolor);
    defer setMode(.indexed256);
    var buf: [24]u8 = undefined;
    try testing.expectEqualStrings("\x1b[38;2;122;162;247m", fg(&buf, Color.accent));
    try testing.expectEqualStrings("\x1b[48;2;28;28;28m", bg(&buf, palette.panel));
}

test "bg emits the 256-color fallback SGR in indexed mode" {
    var buf: [24]u8 = undefined;
    try testing.expectEqualStrings("\x1b[48;5;234m", bg(&buf, palette.panel));
}

test "spinner frame derives from the clock" {
    try testing.expectEqualStrings(spinner_frames[0], spinnerFrame(0));
    try testing.expectEqualStrings(spinner_frames[1], spinnerFrame(80));
    try testing.expectEqualStrings(spinner_frames[9], spinnerFrame(9 * 80));
    // Wraps after a full cycle.
    try testing.expectEqualStrings(spinner_frames[0], spinnerFrame(10 * 80));
    // Never panics on a pre-epoch clock.
    try testing.expectEqualStrings(spinner_frames[0], spinnerFrame(-5));
}

test "every spinner frame is exactly one cell wide" {
    for (spinner_frames) |f| {
        try testing.expectEqual(@as(usize, 1), width.visibleWidth(f));
    }
}

test "elapsed formats seconds, minutes, hours" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("0s", elapsed(&buf, 0, 0));
    try testing.expectEqualStrings("59s", elapsed(&buf, 0, 59_000));
    try testing.expectEqualStrings("1m00s", elapsed(&buf, 0, 60_000));
    try testing.expectEqualStrings("2m14s", elapsed(&buf, 0, 134_000));
    try testing.expectEqualStrings("1h05m", elapsed(&buf, 0, 3_900_000));
    // Clock skew (now < start) clamps to zero instead of underflowing.
    try testing.expectEqualStrings("0s", elapsed(&buf, 1000, 0));
}

test "tokens formats with k/M suffixes" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("999", tokens(&buf, 999));
    try testing.expectEqualStrings("1.0k", tokens(&buf, 1000));
    try testing.expectEqualStrings("12.4k", tokens(&buf, 12_400));
    try testing.expectEqualStrings("3.4M", tokens(&buf, 3_400_000));
    try testing.expectEqualStrings("0", tokens(&buf, -7));
}
