//! U6 exit test (GOAL.md M2): a scripted tool-use turn through the full M2
//! stack in one process — kernel actor, turn driver, fail-closed policy gate
//! (ask verdict), approval worker, zygos.zon routing (config written to and
//! parsed back from a real file), budget enforcement + usage accounting, the
//! Z-09 output-trim filter on the compress seam, and the REAL bash tool in a
//! scratch workspace. Exits 0 on success.

const std = @import("std");
const zygos = @import("zygos");

const tool_use_msg =
    \\{"stop_reason":"tool_use","usage":{"input_tokens":11,"output_tokens":4},
    \\ "content":[{"type":"tool_use","id":"toolu_m2","name":"bash","input":{"command":"seq 1 500"}}]}
;
const end_turn_msg =
    \\{"stop_reason":"end_turn","usage":{"input_tokens":9,"output_tokens":6},
    \\ "content":[{"type":"text","text":"done"}]}
;

const route_zon =
    \\.{
    \\    .routes = .{
    \\        .{ .step_id = "exec", .attempts = .{
    \\            .{ .provider_function = "zygos::provider::fake::messages", .model = "fake-m2" },
    \\        } },
    \\    },
    \\}
;

fn fail(comptime what: []const u8, args: anytype) noreturn {
    std.debug.print("M2 E2E FAIL: " ++ what ++ "\n", args);
    std.process.exit(1);
}

/// libc file round-trip — std.Io stays out of e2e code paths above net/.
fn writeFile(path: [:0]const u8, bytes: []const u8) void {
    const f = std.c.fopen(path.ptr, "w") orelse fail("cannot write {s}", .{path});
    defer _ = std.c.fclose(f);
    if (std.c.fwrite(bytes.ptr, 1, bytes.len, f) != bytes.len) fail("short write to {s}", .{path});
}

fn readFileZ(gpa: std.mem.Allocator, path: [:0]const u8) ![:0]u8 {
    const f = std.c.fopen(path.ptr, "r") orelse fail("cannot read {s}", .{path});
    defer _ = std.c.fclose(f);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = std.c.fread(&chunk, 1, chunk.len, f);
        if (n == 0) break;
        try buf.appendSlice(gpa, chunk[0..n]);
    }
    return buf.toOwnedSliceSentinel(gpa, 0);
}

pub fn main(init: std.process.Init) !void {
    _ = init;
    const gpa = std.heap.c_allocator;

    // Scratch workspace: the real bash tool + the zygos.zon routing config.
    var root_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrintZ(&root_buf, "/tmp/zygos-m2-e2e-{d}", .{std.c.getpid()});
    _ = std.c.mkdir(root.ptr, 0o755);
    var zon_path_buf: [256]u8 = undefined;
    const zon_path = try std.fmt.bufPrintZ(&zon_path_buf, "{s}/zygos.zon", .{root});
    writeFile(zon_path, route_zon);

    var registry = zygos.inproc.Registry.init(gpa, null);
    var actor = try zygos.actor.Actor.init(gpa, .{}, registry.outbound());
    const kernel = try std.Thread.spawn(.{}, zygos.actor.Actor.run, .{&actor});

    // The full M2 worker roster.
    const orch = try zygos.turn.TurnOrchestrator.start(gpa, &actor, &registry);
    const provider = try zygos.provider_fake.FakeProvider.start(gpa, &actor, &registry, &.{
        tool_use_msg,
        end_turn_msg,
    });
    const tools = try zygos.tools.ToolsWorker.start(gpa, &actor, &registry, root);
    const policy = try zygos.policy.PolicyWorker.start(gpa, &actor, &registry, &.{
        .{ .tool = "bash", .verdict = .ask }, // everything else: fail-closed deny
    });
    const approvals = try zygos.approval.ApprovalWorker.start(gpa, &actor, &registry, .auto_approve);
    const zon_text = try readFileZ(gpa, zon_path);
    const route_cfg = try zygos.router.Config.parse(gpa, zon_text);
    gpa.free(zon_text);
    const router = try zygos.router.RouterWorker.start(gpa, &actor, &registry, route_cfg);
    const budget = try zygos.budget.BudgetWorker.start(gpa, &actor, &registry);
    const trim = try zygos.trim.TrimWorker.start(gpa, &actor, &registry, .{
        .max_bytes = 512,
        .max_lines = 50,
        .head_lines = 10,
        .tail_lines = 5,
    }, "m2-turn");
    const caller = try zygos.inproc.Worker.spawn(gpa, &actor, &registry, "e2e-caller");

    const conf = try caller.call("zygos::budget::configure", "{\"scope\":\"m2-turn\",\"max_tokens\":1000}");
    conf.deinit(gpa);

    const request =
        \\{"system":"m2 e2e","max_steps":4,"turn_id":"m2-1",
        \\ "router_function":"zygos::models::resolve","step_id":"exec",
        \\ "policy_function":"zygos::policy::check",
        \\ "approval_function":"zygos::approvals::request",
        \\ "budget_scope":"m2-turn",
        \\ "messages":[{"role":"user","content":"prove the M2 loop"}],
        \\ "tools":[{"name":"bash","function_id":"zygos::tools::bash"}]}
    ;
    const res = try caller.call("zygos::turns::run", request);
    defer res.deinit(gpa);
    if (res != .ok) fail("turn call errored: {s}", .{res.err});

    var p = try std.json.parseFromSlice(std.json.Value, gpa, res.ok, .{});
    defer p.deinit();
    const obj = p.value.object;

    const stop = obj.get("stop").?.string;
    if (!std.mem.eql(u8, stop, "end_turn")) fail("stop was {s}: {s}", .{ stop, res.ok });
    const steps = obj.get("steps").?.integer;
    if (steps != 2) fail("steps was {d}", .{steps});

    // Deltas streamed over the kernel channel, both steps.
    const deltas = obj.get("deltas").?.string;
    if (!std.mem.eql(u8, deltas, "hello worldhello world")) fail("deltas were '{s}'", .{deltas});

    // The REAL bash tool ran through ask->approval, and Z-09 trimmed its
    // 500-line output on the compress seam before it entered the transcript.
    if (std.mem.indexOf(u8, res.ok, "exit_code") == null)
        fail("bash reply shape missing from transcript: {s}", .{res.ok});
    if (std.mem.indexOf(u8, res.ok, "zygos trimmed") == null)
        fail("trim marker missing - seam not exercised: {s}", .{res.ok});

    // Budget saw both steps' usage (11+4+9+6) and the trim savings.
    const check = try caller.call("zygos::budget::check", "{\"scope\":\"m2-turn\"}");
    defer check.deinit(gpa);
    if (std.mem.indexOf(u8, check.ok, "\"used_tokens\":30") == null)
        fail("usage not recorded: {s}", .{check.ok});
    var cp = try std.json.parseFromSlice(std.json.Value, gpa, check.ok, .{});
    defer cp.deinit();
    const saved = cp.value.object.get("saved_bytes").?.integer;
    if (saved <= 0) fail("no trim savings recorded: {s}", .{check.ok});

    // Orderly teardown.
    caller.stop();
    trim.stop();
    budget.stop();
    router.stop();
    approvals.stop();
    policy.stop();
    tools.stop();
    provider.stop();
    orch.stop();
    actor.post(.shutdown);
    kernel.join();
    actor.deinit();
    registry.deinit();

    std.debug.print(
        "M2 E2E OK: stop={s} steps={d} used_tokens=30 saved_bytes={d}\n",
        .{ stop, steps, saved },
    );
}
