//! T6 exit test (GOAL.md M1): a scripted 2-step tool-use turn through the
//! full M1 stack — kernel actor, inproc bus workers, turn FSM driver, fake
//! provider streaming deltas over a kernel channel, and the REAL agent-tools
//! bash tool running in a scratch workspace. Exits 0 on success.

const std = @import("std");
const zygos = @import("zygos");

const tool_use_msg =
    \\{"stop_reason":"tool_use","content":[{"type":"text","text":"running"},
    \\ {"type":"tool_use","id":"toolu_e2e","name":"bash","input":{"command":"echo zygos-e2e-proof"}}]}
;
const end_turn_msg =
    \\{"stop_reason":"end_turn","content":[{"type":"text","text":"all done"}]}
;

fn fail(comptime what: []const u8, args: anytype) noreturn {
    std.debug.print("TURN E2E FAIL: " ++ what ++ "\n", args);
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    _ = init;
    const gpa = std.heap.c_allocator;

    // Scratch workspace for the real bash tool.
    var root_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrintZ(&root_buf, "/tmp/zygos-turn-e2e-{d}", .{std.c.getpid()});
    _ = std.c.mkdir(root.ptr, 0o755);

    var registry = zygos.inproc.Registry.init(gpa, null);
    var actor = try zygos.actor.Actor.init(gpa, .{}, registry.outbound());
    const kernel = try std.Thread.spawn(.{}, zygos.actor.Actor.run, .{&actor});

    const orch = try zygos.turn.TurnOrchestrator.start(gpa, &actor, &registry);
    const provider = try zygos.provider_fake.FakeProvider.start(gpa, &actor, &registry, &.{
        tool_use_msg,
        end_turn_msg,
    });
    const tools = try zygos.tools.ToolsWorker.start(gpa, &actor, &registry, root);
    const caller = try zygos.inproc.Worker.spawn(gpa, &actor, &registry, "e2e-caller");

    const request =
        \\{"model":"fake-1","system":"e2e","max_steps":4,
        \\ "provider_function":"zygos::provider::fake::messages",
        \\ "messages":[{"role":"user","content":"prove the loop"}],
        \\ "tools":[{"name":"bash","function_id":"zygos::tools::bash"}]}
    ;
    const res = try caller.call("zygos::turns::run", request);
    defer res.deinit(gpa);
    if (res != .ok) fail("turn call errored: {s}", .{res.err});

    var p = try std.json.parseFromSlice(std.json.Value, gpa, res.ok, .{});
    defer p.deinit();
    const obj = p.value.object;

    const stop = obj.get("stop").?.string;
    if (!std.mem.eql(u8, stop, "end_turn")) fail("stop was {s}", .{stop});
    const steps = obj.get("steps").?.integer;
    if (steps != 2) fail("steps was {d}", .{steps});

    // Deltas streamed over the kernel channel, both steps.
    const deltas = obj.get("deltas").?.string;
    if (!std.mem.eql(u8, deltas, "hello worldhello world")) fail("deltas were '{s}'", .{deltas});

    // The REAL bash tool ran: its output (echoed marker) is embedded in the
    // transcript's tool_result content. The tool_use input also contains the
    // marker, so anchor on the tool's JSON reply shape.
    const transcript_raw = res.ok;
    if (std.mem.indexOf(u8, transcript_raw, "exit_code") == null or
        std.mem.indexOf(u8, transcript_raw, "zygos-e2e-proof") == null)
        fail("bash output missing from transcript: {s}", .{transcript_raw});
    if (std.mem.indexOf(u8, transcript_raw, "\"is_error\":false") == null)
        fail("tool_result not marked success", .{});

    // Orderly teardown.
    caller.stop();
    tools.stop();
    provider.stop();
    orch.stop();
    actor.post(.shutdown);
    kernel.join();
    actor.deinit();
    registry.deinit();

    std.debug.print("TURN E2E OK: stop={s} steps={d} deltas=\"{s}\"\n", .{ stop, steps, deltas });
}
