//! Live-progress terminal UI for `zygos mission run`. Hand-rolled raw ANSI —
//! no external deps. libc terminal control (termios/ioctl/poll) is confined
//! to this directory, mirroring the net/ exception (Z-02); kernel modules
//! stay terminal-free. This is a progress view over the existing mission
//! trace stream, not a console.

const std = @import("std");

pub const width = @import("width.zig");
pub const term = @import("term.zig");
pub const theme = @import("theme.zig");
pub const palette = @import("palette.zig");
pub const fmt = @import("fmt.zig");
pub const chatlog = @import("chatlog.zig");
pub const band = @import("band.zig");
pub const entries = @import("entries.zig");
pub const tasks = @import("tasks.zig");
pub const frame = @import("frame.zig");
pub const markdown = @import("markdown.zig");
pub const highlight = @import("highlight.zig");
pub const model = @import("model.zig");
pub const partialjson = @import("partialjson.zig");
pub const loop = @import("loop.zig");
pub const logbridge = @import("logbridge.zig");

pub const Tui = loop.Tui;
pub const emergencyRestore = term.emergencyRestore;

test {
    std.testing.refAllDecls(@This());
}
