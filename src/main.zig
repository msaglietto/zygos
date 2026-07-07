//! Zygos binary entry. Thin: kernel wiring only — GPA, actor on its kernel
//! thread, WS gateway on the front. Port from ZYGOS_PORT (default 49134,
//! the iii SDK default). Stopped by killing the process (M0; signal-driven
//! graceful shutdown lands with the supervisor work).

const std = @import("std");
const zygos = @import("zygos");

pub fn main(init: std.process.Init) !void {
    _ = init;
    const gpa = std.heap.c_allocator;

    var config: zygos.net.Config = .{};
    if (std.c.getenv("ZYGOS_PORT")) |raw| {
        config.port = std.fmt.parseInt(u16, std.mem.span(raw), 10) catch config.port;
    }

    const gateway = try zygos.net.Gateway.create(gpa, config);
    defer gateway.destroy();

    var actor = try zygos.actor.Actor.init(gpa, .{}, gateway.outbound());
    defer actor.deinit();
    gateway.bind(&actor);

    const kernel_thread = try std.Thread.spawn(.{}, zygos.actor.Actor.run, .{&actor});

    try gateway.start();
    gateway.wait(); // parks until the listener exits

    actor.post(.shutdown);
    kernel_thread.join();
}
