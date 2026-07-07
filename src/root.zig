//! Zygos public module root. Re-exports kernel modules for consumers and is the
//! root of the library's test binary. Importing `kernel/*` here makes their test
//! blocks part of `zig build test`.

const std = @import("std");

pub const protocol = @import("kernel/protocol.zig");
pub const types = @import("kernel/types.zig");
pub const catalog = @import("kernel/catalog.zig");

test {
    // Pull every declaration (and thus every kernel module's test blocks) into the
    // root test binary so `zig build test` discovers them.
    std.testing.refAllDecls(@This());
}
