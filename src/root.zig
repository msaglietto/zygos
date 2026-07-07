//! Zygos public module root. Re-exports kernel modules for consumers and is the
//! root of the library's test binary. Importing `kernel/*` here makes their test
//! blocks part of `zig build test`.

const std = @import("std");

pub const protocol = @import("kernel/protocol.zig");
pub const actor = @import("kernel/actor.zig");
pub const inproc = @import("kernel/inproc.zig");
pub const net = @import("net/ws.zig");
pub const types = @import("kernel/types.zig");
pub const sync = @import("kernel/sync.zig");
pub const catalog = @import("kernel/catalog.zig");
pub const channel = @import("kernel/channel.zig");
pub const invocation = @import("kernel/invocation.zig");
pub const trigger = @import("kernel/trigger.zig");

test {
    // Pull every declaration (and thus every kernel module's test blocks) into the
    // root test binary so `zig build test` discovers them.
    std.testing.refAllDecls(@This());
}
