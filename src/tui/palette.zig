//! Semantic color roles for the mission TUI, measured from the grok CLI
//! capture (2026-07-17). Every role carries the truecolor value plus an
//! xterm-256 fallback index; theme.zig picks one per terminal mode. Roles
//! that predate the palette keep their historical 256 indices so
//! indexed-mode output stays byte-identical.

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,
    /// xterm-256 index emitted when the terminal lacks truecolor.
    fallback: u8,
};

// -- core roles --------------------------------------------------------------

/// Headers, active step, thinking label.
pub const accent = Rgb{ .r = 0x7a, .g = 0xa2, .b = 0xf7, .fallback = 75 };
/// Completed / success.
pub const ok = Rgb{ .r = 0x9e, .g = 0xce, .b = 0x6a, .fallback = 71 };
/// Failures, approval asks.
pub const err = Rgb{ .r = 0xe0, .g = 0x6c, .b = 0x75, .fallback = 167 };
/// Timestamps, footnotes, collapsed steps.
pub const muted = Rgb{ .r = 0x6c, .g = 0x6c, .b = 0x6c, .fallback = 244 };
/// Tool names, inline code.
pub const tool = Rgb{ .r = 0x3a, .g = 0x95, .b = 0xab, .fallback = 179 };
/// Emphasis text.
pub const bright = Rgb{ .r = 0xe1, .g = 0xe1, .b = 0xe1, .fallback = 254 };
/// Answer body text.
pub const body = Rgb{ .r = 0xc8, .g = 0xc8, .b = 0xc8, .fallback = 251 };
/// Box rails and rules.
pub const border = Rgb{ .r = 0x50, .g = 0x50, .b = 0x58, .fallback = 239 };
/// Fenced-code panel background.
pub const panel = Rgb{ .r = 0x1c, .g = 0x1c, .b = 0x1c, .fallback = 234 };

// -- syntax sub-palette (Tokyo Night; fenced-code highlighting) ---------------

pub const syntax = struct {
    pub const keyword = Rgb{ .r = 0xbb, .g = 0x9a, .b = 0xf7, .fallback = 141 };
    pub const func = Rgb{ .r = 0x7a, .g = 0xa2, .b = 0xf7, .fallback = 111 };
    pub const typ = Rgb{ .r = 0x0d, .g = 0xb9, .b = 0xd7, .fallback = 38 };
    pub const number = Rgb{ .r = 0xff, .g = 0x9e, .b = 0x64, .fallback = 215 };
    pub const string = Rgb{ .r = 0xe0, .g = 0xaf, .b = 0x68, .fallback = 179 };
    pub const comment = Rgb{ .r = 0x51, .g = 0x59, .b = 0x7d, .fallback = 60 };
    pub const punct = Rgb{ .r = 0xb2, .g = 0xb2, .b = 0xb2, .fallback = 249 };
};

// ===========================================================================
// Tests
// ===========================================================================

const std = @import("std");
const testing = std.testing;

test "pre-palette roles keep their historical 256 indices" {
    // Indexed-mode output must stay byte-identical to the pre-palette TUI.
    try testing.expectEqual(@as(u8, 75), accent.fallback);
    try testing.expectEqual(@as(u8, 71), ok.fallback);
    try testing.expectEqual(@as(u8, 167), err.fallback);
    try testing.expectEqual(@as(u8, 244), muted.fallback);
    try testing.expectEqual(@as(u8, 179), tool.fallback);
}
