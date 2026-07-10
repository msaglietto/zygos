//! W6 exit test, leg 1 (GOAL.md M4): a scripted mission runs to done with the
//! W3 continuity seam pointed at the vault in ZYGOS_VAULT_ROOT — the mission
//! auto-logs a SESSIONS.md entry, no model asked to remember. Leg 2 (an
//! external MCP client reading that entry back through `zygos mcp-gateway`
//! stdio) lives in run.sh. Exits 0 on success.

const std = @import("std");
const zygos = @import("zygos");

const po_msg =
    \\{"stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":5},
    \\ "content":[{"type":"text","text":"{\"objective\":\"Ship the gizmo\",\"acceptance\":\"the gizmo ships\"}"}]}
;
const plan_msg =
    \\{"stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":5},
    \\ "content":[{"type":"text","text":"{\"tasks\":[\"assemble the gizmo\"]}"}]}
;
const exec_msg =
    \\{"stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":5},
    \\ "content":[{"type":"text","text":"assembled"}]}
;
const verify_msg =
    \\{"stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":5},
    \\ "content":[{"type":"text","text":"{\"passed\":true,\"reason\":\"acceptance met\"}"}]}
;

fn fail(comptime what: []const u8, args: anytype) noreturn {
    std.debug.print("M4 E2E FAIL: " ++ what ++ "\n", args);
    std.process.exit(1);
}

/// libc read — std.Io stays out of e2e code paths above net/.
fn readFileZ(gpa: std.mem.Allocator, path: [:0]const u8) ![]u8 {
    const f = std.c.fopen(path.ptr, "r") orelse fail("cannot open {s}", .{path});
    defer _ = std.c.fclose(f);
    var out: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.c.fread(&buf, 1, buf.len, f);
        if (n == 0) break;
        try out.appendSlice(gpa, buf[0..n]);
    }
    return out.toOwnedSlice(gpa);
}

pub fn main() !void {
    const gpa = std.heap.c_allocator;

    const vault_z = std.c.getenv("ZYGOS_VAULT_ROOT") orelse fail("ZYGOS_VAULT_ROOT not set", .{});
    const vault = std.mem.span(vault_z);

    var planning_buf: [512]u8 = undefined;
    const planning = try std.fmt.bufPrint(&planning_buf, "{s}/.planning", .{vault});

    var registry = zygos.inproc.Registry.init(gpa, null);
    var actor = try zygos.actor.Actor.init(gpa, .{}, registry.outbound());
    const kernel = try std.Thread.spawn(.{}, zygos.actor.Actor.run, .{&actor});

    const turns = try zygos.turn.TurnOrchestrator.start(gpa, &actor, &registry);
    const provider = try zygos.provider_fake.FakeProvider.start(gpa, &actor, &registry, &.{
        po_msg, plan_msg, exec_msg, verify_msg,
    });
    const approvals = try zygos.approval.ApprovalWorker.start(gpa, &actor, &registry, .auto_approve);
    const continuity = try zygos.tessera_continuity.ContinuityWorker.start(gpa, &actor, &registry, .{
        .root = vault,
    });
    const orch = try zygos.mission.MissionOrchestrator.start(gpa, &actor, &registry);
    const caller = try zygos.inproc.Worker.spawn(gpa, &actor, &registry, "e2e-caller");

    const request = try std.fmt.allocPrint(gpa,
        \\{{"mission_id":"m4-live","planning_root":"{s}",
        \\ "objective":"seed: ship the gizmo",
        \\ "provider_function":"zygos::provider::fake::messages",
        \\ "gate_function":"zygos::approvals::request",
        \\ "continuity_function":"zygos::tessera::session_close",
        \\ "continuity_project":"zygos-e2e"}}
    , .{planning});
    const res = try caller.call("zygos::missions::start", request);
    gpa.free(request);
    if (res != .ok) fail("mission call errored: {s}", .{res.err});
    if (std.mem.indexOf(u8, res.ok, "\"state\":\"done\"") == null)
        fail("mission not done: {s}", .{res.ok});
    res.deinit(gpa);

    // The continuity seam wrote the session entry — the harness remembered.
    var sessions_buf: [512]u8 = undefined;
    const sessions_path = try std.fmt.bufPrintZ(&sessions_buf, "{s}/Projects/zygos-e2e/SESSIONS.md", .{vault});
    const sessions = try readFileZ(gpa, sessions_path);
    defer gpa.free(sessions);
    if (std.mem.indexOf(u8, sessions, "## Session — ") == null)
        fail("SESSIONS.md has no session entry:\n{s}", .{sessions});
    if (std.mem.indexOf(u8, sessions, "mission done") == null)
        fail("SESSIONS.md leaving-behind missing:\n{s}", .{sessions});
    if (std.mem.indexOf(u8, sessions, "gating → done") == null)
        fail("SESSIONS.md phase log missing:\n{s}", .{sessions});

    caller.stop();
    orch.stop();
    continuity.stop();
    approvals.stop();
    provider.stop();
    turns.stop();
    actor.post(.shutdown);
    kernel.join();
    actor.deinit();
    registry.deinit();

    std.debug.print("M4 E2E leg 1 OK: mission auto-logged {s}\n", .{sessions_path});
}
