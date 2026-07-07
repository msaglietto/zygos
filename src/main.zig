//! Zygos binary entry. Thin: kernel wiring only. All real work lives in the
//! kernel modules exposed via the `zygos` library module.

const std = @import("std");
const zygos = @import("zygos");

pub fn main(init: std.process.Init) !void {
    _ = init;
    // Reference the protocol module so the kernel is linked into the binary; the
    // WebSocket loop and actor command bus attach in later milestones.
    std.debug.print("zygos kernel ready (wire types: {s})\n", .{@typeName(zygos.protocol.Message)});
}
