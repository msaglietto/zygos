//! Env-gated manual smoke for the REAL Anthropic provider (GOAL.md M1 notes:
//! never part of `zig build test`). Requires ANTHROPIC_API_KEY; exits 2 when
//! unset so scripts can treat it as skipped. Makes ONE small streaming call
//! through the full bus path and prints the result.

const std = @import("std");
const zygos = @import("zygos");

pub fn main(init: std.process.Init) !void {
    _ = init;
    const gpa = std.heap.c_allocator;

    const key_z = std.c.getenv("ANTHROPIC_API_KEY") orelse {
        std.debug.print("SMOKE SKIPPED: ANTHROPIC_API_KEY not set\n", .{});
        std.process.exit(2);
    };
    const api_key = std.mem.span(key_z);
    const model = if (std.c.getenv("ZYGOS_SMOKE_MODEL")) |m| std.mem.span(m) else "claude-haiku-4-5-20251001";

    var io_backing = std.Io.Threaded.init(gpa, .{});
    defer io_backing.deinit();

    var registry = zygos.inproc.Registry.init(gpa, null);
    var actor = try zygos.actor.Actor.init(gpa, .{}, registry.outbound());
    const kernel = try std.Thread.spawn(.{}, zygos.actor.Actor.run, .{&actor});

    const provider = try zygos.provider_anthropic.AnthropicProvider.start(
        gpa,
        &actor,
        &registry,
        io_backing.io(),
        api_key,
        "https://api.anthropic.com",
    );
    const caller = try zygos.inproc.Worker.spawn(gpa, &actor, &registry, "smoke-caller");

    const request = try std.fmt.allocPrint(gpa,
        \\{{"model":"{s}","system":"answer in one word",
        \\ "messages":[{{"role":"user","content":"What planet do humans live on?"}}],"tools":[]}}
    , .{model});
    defer gpa.free(request);

    const res = try caller.call("zygos::provider::anthropic::messages", request);
    defer res.deinit(gpa);

    switch (res) {
        .ok => |payload| std.debug.print("SMOKE OK: {s}\n", .{payload}),
        .err => |code| {
            std.debug.print("SMOKE FAIL: {s}\n", .{code});
            std.process.exit(1);
        },
    }

    caller.stop();
    provider.stop();
    actor.post(.shutdown);
    kernel.join();
    actor.deinit();
    registry.deinit();
}
