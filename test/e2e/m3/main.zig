//! V6 exit test (GOAL.md M3): the mission loop over the full M2+M3 stack in
//! one process — kernel actor, mission + turn orchestrators, scripted fake
//! provider, per-role zygos.zon routing (config from a real file), fail-closed
//! policy (ask on bash), approval worker serving both tool asks and the hard
//! completion gate, budget accounting, the Z-09 trim seam, and the REAL bash
//! tool executing plan tasks in a scratch workspace.
//!
//! Two legs: (1) a mission runs define → plan → execute×2 → verify → gate to
//! done; (2) a mid-flight mission substrate is resumed by a FRESH orchestrator
//! instance that never saw it and finishes without re-running earlier roles.
//! Exits 0 on success.

const std = @import("std");
const zygos = @import("zygos");

// -- role turn script (call order: po, plan, exec t1 ×2, exec t2 ×2, verify) --

const po_msg =
    \\{"stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":5},
    \\ "content":[{"type":"text","text":"{\"objective\":\"Ship the gizmo\",\"acceptance\":\"greeting written and count run\"}"}]}
;
const plan_msg =
    \\{"stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":5},
    \\ "content":[{"type":"text","text":"{\"tasks\":[\"write a greeting file\",\"count to 500\"]}"}]}
;
const exec1_tool =
    \\{"stop_reason":"tool_use","usage":{"input_tokens":10,"output_tokens":5},
    \\ "content":[{"type":"tool_use","id":"t-greet","name":"bash","input":{"command":"echo hello > greeting.txt"}}]}
;
const exec1_done =
    \\{"stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":5},
    \\ "content":[{"type":"text","text":"wrote the greeting"}]}
;
const exec2_tool =
    \\{"stop_reason":"tool_use","usage":{"input_tokens":10,"output_tokens":5},
    \\ "content":[{"type":"tool_use","id":"t-count","name":"bash","input":{"command":"seq 1 500"}}]}
;
const exec2_done =
    \\{"stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":5},
    \\ "content":[{"type":"text","text":"counted"}]}
;
const verify_msg =
    \\{"stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":5},
    \\ "content":[{"type":"text","text":"{\"passed\":true,\"reason\":\"acceptance met\"}"}]}
;
// -- leg 2 (resume): one executor turn + one verifier turn ---------------------
const resumed_exec =
    \\{"stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":5},
    \\ "content":[{"type":"text","text":"resumed and finished the count"}]}
;

const route_zon =
    \\.{
    \\    .routes = .{
    \\        .{ .step_id = "product-owner", .attempts = .{
    \\            .{ .provider_function = "zygos::provider::fake::messages", .model = "po-model" },
    \\        } },
    \\        .{ .step_id = "planner", .attempts = .{
    \\            .{ .provider_function = "zygos::provider::fake::messages", .model = "planner-model" },
    \\        } },
    \\        .{ .step_id = "executor", .attempts = .{
    \\            .{ .provider_function = "zygos::provider::fake::messages", .model = "executor-model" },
    \\        } },
    \\        .{ .step_id = "verifier", .attempts = .{
    \\            .{ .provider_function = "zygos::provider::fake::messages", .model = "verifier-model" },
    \\        } },
    \\    },
    \\}
;

fn fail(comptime what: []const u8, args: anytype) noreturn {
    std.debug.print("M3 E2E FAIL: " ++ what ++ "\n", args);
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

fn expectTerminal(gpa: std.mem.Allocator, payload: []const u8, role_turns: i64, tasks_done: i64) void {
    var p = std.json.parseFromSlice(std.json.Value, gpa, payload, .{}) catch
        fail("unparseable mission reply: {s}", .{payload});
    defer p.deinit();
    const obj = p.value.object;
    if (!std.mem.eql(u8, obj.get("state").?.string, "done")) fail("state: {s}", .{payload});
    if (!std.mem.eql(u8, obj.get("stop").?.string, "completed")) fail("stop: {s}", .{payload});
    if (obj.get("role_turns").?.integer != role_turns) fail("role_turns: {s}", .{payload});
    if (obj.get("tasks_done").?.integer != tasks_done) fail("tasks_done: {s}", .{payload});
}

pub fn main(init: std.process.Init) !void {
    _ = init;
    const gpa = std.heap.c_allocator;

    // Scratch tree: bash workspace, zygos.zon, and two planning roots.
    var root_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrintZ(&root_buf, "/tmp/zygos-m3-e2e-{d}", .{std.c.getpid()});
    _ = std.c.mkdir(root.ptr, 0o755);
    var zon_path_buf: [256]u8 = undefined;
    const zon_path = try std.fmt.bufPrintZ(&zon_path_buf, "{s}/zygos.zon", .{root});
    writeFile(zon_path, route_zon);
    var planning_buf: [256]u8 = undefined;
    const planning = try std.fmt.bufPrint(&planning_buf, "{s}/.planning", .{root});
    var planning2_buf: [256]u8 = undefined;
    const planning2 = try std.fmt.bufPrint(&planning2_buf, "{s}/.planning-resume", .{root});

    var registry = zygos.inproc.Registry.init(gpa, null);
    var actor = try zygos.actor.Actor.init(gpa, .{}, registry.outbound());
    const kernel = try std.Thread.spawn(.{}, zygos.actor.Actor.run, .{&actor});

    // The full M2+M3 worker roster.
    const turns = try zygos.turn.TurnOrchestrator.start(gpa, &actor, &registry);
    const provider = try zygos.provider_fake.FakeProvider.start(gpa, &actor, &registry, &.{
        po_msg,     plan_msg,     exec1_tool, exec1_done, exec2_tool, exec2_done,
        verify_msg, resumed_exec, verify_msg,
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
    }, "m3-mission");
    const caller = try zygos.inproc.Worker.spawn(gpa, &actor, &registry, "e2e-caller");

    const conf = try caller.call("zygos::budget::configure", "{\"scope\":\"m3-mission\",\"max_tokens\":10000}");
    conf.deinit(gpa);

    // ---- Leg 1: a full mission to done -------------------------------------
    var orch = try zygos.mission.MissionOrchestrator.start(gpa, &actor, &registry);

    const request = try std.fmt.allocPrint(gpa,
        \\{{"mission_id":"m3-live","planning_root":"{s}",
        \\ "objective":"seed: ship the gizmo",
        \\ "router_function":"zygos::models::resolve",
        \\ "gate_function":"zygos::approvals::request",
        \\ "policy_function":"zygos::policy::check",
        \\ "approval_function":"zygos::approvals::request",
        \\ "budget_scope":"m3-mission",
        \\ "tools":[{{"name":"bash","function_id":"zygos::tools::bash"}}]}}
    , .{planning});
    const res = try caller.call("zygos::missions::start", request);
    gpa.free(request);
    defer res.deinit(gpa);
    if (res != .ok) fail("mission call errored: {s}", .{res.err});
    expectTerminal(gpa, res.ok, 5, 2); // po + plan + exec×2 + verify

    // The REAL bash tool ran the plan's first task in the workspace.
    var greet_buf: [256]u8 = undefined;
    const greet_path = try std.fmt.bufPrintZ(&greet_buf, "{s}/greeting.txt", .{root});
    const greeting = try readFileZ(gpa, greet_path);
    defer gpa.free(greeting);
    if (!std.mem.eql(u8, greeting, "hello\n")) fail("greeting.txt was '{s}'", .{greeting});

    // The substrate holds the artifacts and the terminal record.
    const store = zygos.mission_store.Store.init(planning);
    const brief = try store.readArtifact(gpa, "MISSION.md");
    defer gpa.free(brief);
    if (std.mem.indexOf(u8, brief, "Ship the gizmo") == null) fail("MISSION.md: {s}", .{brief});
    const verdict = try store.readArtifact(gpa, "VERIFY.md");
    defer gpa.free(verdict);
    if (std.mem.indexOf(u8, verdict, "passed: true") == null) fail("VERIFY.md: {s}", .{verdict});

    // Budget saw all 7 provider calls (7 × 15 tokens) and the Z-09 seam
    // trimmed the 500-line count inside the executor turn.
    const check = try caller.call("zygos::budget::check", "{\"scope\":\"m3-mission\"}");
    defer check.deinit(gpa);
    if (std.mem.indexOf(u8, check.ok, "\"used_tokens\":105") == null)
        fail("usage not recorded: {s}", .{check.ok});
    var cp = try std.json.parseFromSlice(std.json.Value, gpa, check.ok, .{});
    defer cp.deinit();
    const saved = cp.value.object.get("saved_bytes").?.integer;
    if (saved <= 0) fail("no trim savings recorded: {s}", .{check.ok});

    // ---- Leg 2: a fresh orchestrator resumes a mid-flight substrate ---------
    orch.stop();
    orch = try zygos.mission.MissionOrchestrator.start(gpa, &actor, &registry);

    // Seed .planning-resume exactly as a killed mission leaves it: state is
    // persisted before every role turn, so an interrupted executor shows as
    // `executing` with its task not yet done.
    var tasks = [_]zygos.mission.Task{
        .{ .desc = "write a greeting file", .done = true },
        .{ .desc = "count to 500", .done = false },
    };
    const seeded: zygos.mission.Mission = .{
        .mission_id = "m3-resume",
        .state = .executing,
        .objective = "Ship the gizmo",
        .acceptance = "greeting written and count run",
        .tasks = &tasks,
        .task_index = 1,
        .role_turns_used = 3,
    };
    const store2 = zygos.mission_store.Store.init(planning2);
    try store2.save(gpa, &seeded);
    try store2.writeArtifact(gpa, "MISSION.md", "# Mission m3-resume\n\nShip the gizmo\n");
    try store2.writeArtifact(gpa, "PLAN.md", "# Plan\n\n- [x] write a greeting file\n- [ ] count to 500\n");

    const resume_req = try std.fmt.allocPrint(gpa,
        \\{{"mission_id":"m3-resume","planning_root":"{s}","resume":true,
        \\ "provider_function":"zygos::provider::fake::messages",
        \\ "gate_function":"zygos::approvals::request"}}
    , .{planning2});
    const res2 = try caller.call("zygos::missions::start", resume_req);
    gpa.free(resume_req);
    defer res2.deinit(gpa);
    if (res2 != .ok) fail("resume call errored: {s}", .{res2.err});
    expectTerminal(gpa, res2.ok, 5, 2); // 3 persisted + exec + verify

    // Earlier roles were NOT re-run: 7 leg-1 calls + exec + verify only.
    if (provider.calls != 9) fail("provider ran {d} times, want 9", .{provider.calls});

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
    turns.stop();
    actor.post(.shutdown);
    kernel.join();
    actor.deinit();
    registry.deinit();

    std.debug.print(
        "M3 E2E OK: live=done/completed resumed=done/completed role_turns=5+5 used_tokens=105 saved_bytes={d}\n",
        .{saved},
    );
}
