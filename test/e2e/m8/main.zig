//! S8-exit test (M8, docs/specs/filter.md): the command-aware compression
//! path exercised end-to-end in one process — kernel actor, turn driver,
//! policy gate, approvals, budget, and the REAL bash tool running REAL git
//! commands in a REAL scratch repo, with the trim worker's filters on the
//! compress seam.
//!
//! The unit tests pin each filter against a fixture. This pins the thing a
//! fixture cannot: that the driver's seam context (S8.1) actually reaches
//! the dispatcher with a tool name it recognizes, against output produced by
//! a real command rather than a hand-written string. Exits 0 on success.

const std = @import("std");
const zygos = @import("zygos");

/// Step 1 runs `git diff` (filterable), step 2 the same `git status` twice
/// (dedup), step 3 ends the turn.
const diff_msg =
    \\{"stop_reason":"tool_use","usage":{"input_tokens":5,"output_tokens":2},
    \\ "content":[{"type":"tool_use","id":"t1","name":"bash","input":{"command":"git diff"}}]}
;
const status_msg =
    \\{"stop_reason":"tool_use","usage":{"input_tokens":5,"output_tokens":2},
    \\ "content":[{"type":"tool_use","id":"t2","name":"bash","input":{"command":"git status"}}]}
;
const status_again_msg =
    \\{"stop_reason":"tool_use","usage":{"input_tokens":5,"output_tokens":2},
    \\ "content":[{"type":"tool_use","id":"t3","name":"bash","input":{"command":"git status"}}]}
;
/// The Z-09 escape hatch: same command, but the model asked for exact bytes.
const raw_msg =
    \\{"stop_reason":"tool_use","usage":{"input_tokens":5,"output_tokens":2},
    \\ "content":[{"type":"tool_use","id":"t4","name":"bash",
    \\ "input":{"command":"git diff","raw":true}}]}
;
const end_turn_msg =
    \\{"stop_reason":"end_turn","usage":{"input_tokens":4,"output_tokens":3},
    \\ "content":[{"type":"text","text":"done"}]}
;

const route_zon =
    \\.{
    \\    .routes = .{
    \\        .{ .step_id = "exec", .attempts = .{
    \\            .{ .provider_function = "zygos::provider::fake::messages", .model = "fake-m8" },
    \\        } },
    \\    },
    \\}
;

fn fail(comptime what: []const u8, args: anytype) noreturn {
    std.debug.print("M8 E2E FAIL: " ++ what ++ "\n", args);
    std.process.exit(1);
}

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

extern "c" fn system(cmd: [*:0]const u8) c_int;

fn sh(gpa: std.mem.Allocator, cwd: []const u8, cmd: []const u8) void {
    const full = std.fmt.allocPrintSentinel(gpa, "cd {s} && {s} > /dev/null 2>&1", .{ cwd, cmd }, 0) catch
        fail("oom building shell command", .{});
    defer gpa.free(full);
    _ = system(full.ptr);
}

pub fn main(init: std.process.Init) !void {
    _ = init;
    const gpa = std.heap.c_allocator;

    // A real git repo with a real uncommitted change, so the filters see
    // output no fixture author chose.
    var root_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrintZ(&root_buf, "/tmp/zygos-m8-e2e-{d}", .{std.c.getpid()});
    _ = std.c.mkdir(root.ptr, 0o755);

    sh(gpa, root, "git init -q .");
    sh(gpa, root, "git config user.email e2e@zygos.local");
    sh(gpa, root, "git config user.name zygos-e2e");
    // The ratio covers verbose status hints and standard diff context.
    // Runner/user Git settings must not change the input to this exit gate.
    sh(gpa, root, "git config advice.statusHints true");
    sh(gpa, root, "git config diff.context 3");
    // A file with enough context that a diff carries real metadata + padding.
    {
        var p: [320]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&p, "{s}/subject.txt", .{root});
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(gpa);
        for (0..60) |i| {
            var lb: [64]u8 = undefined;
            try body.appendSlice(gpa, try std.fmt.bufPrint(&lb, "context line {d}\n", .{i}));
        }
        writeFile(path, body.items);
        sh(gpa, root, "git add -A && git commit -q -m base");
        // Change exactly one line in the middle.
        var body2: std.ArrayList(u8) = .empty;
        defer body2.deinit(gpa);
        for (0..60) |i| {
            var lb: [64]u8 = undefined;
            try body2.appendSlice(gpa, if (i == 30)
                try std.fmt.bufPrint(&lb, "CHANGED LINE MARKER\n", .{})
            else
                try std.fmt.bufPrint(&lb, "context line {d}\n", .{i}));
        }
        writeFile(path, body2.items);
    }

    var zon_path_buf: [256]u8 = undefined;
    const zon_path = try std.fmt.bufPrintZ(&zon_path_buf, "{s}/zygos.zon", .{root});
    writeFile(zon_path, route_zon);

    var registry = zygos.inproc.Registry.init(gpa, null);
    var actor = try zygos.actor.Actor.init(gpa, .{}, registry.outbound());
    const kernel = try std.Thread.spawn(.{}, zygos.actor.Actor.run, .{&actor});

    const orch = try zygos.turn.TurnOrchestrator.start(gpa, &actor, &registry);
    const provider = try zygos.provider_fake.FakeProvider.start(gpa, &actor, &registry, &.{
        diff_msg,
        status_msg,
        status_again_msg,
        raw_msg,
        end_turn_msg,
    });
    const tools = try zygos.tools.ToolsWorker.start(gpa, &actor, &registry, root);
    const policy = try zygos.policy.PolicyWorker.start(gpa, &actor, &registry, &.{
        .{ .tool = "bash", .verdict = .allow },
    });
    const approvals = try zygos.approval.ApprovalWorker.start(gpa, &actor, &registry, .auto_approve);
    const zon_text = try readFileZ(gpa, zon_path);
    const route_cfg = try zygos.router.Config.parse(gpa, zon_text);
    gpa.free(zon_text);
    const router = try zygos.router.RouterWorker.start(gpa, &actor, &registry, route_cfg);
    const budget = try zygos.budget.BudgetWorker.start(gpa, &actor, &registry);
    // Generous generic limits: anything compressed here was compressed by a
    // command-aware filter, not by head/tail elision.
    const trim = try zygos.trim.TrimWorker.start(gpa, &actor, &registry, .{
        .max_bytes = 1 << 20,
        .max_lines = 100_000,
        .head_lines = 50_000,
        .tail_lines = 50_000,
    }, "m8-turn");
    const caller = try zygos.inproc.Worker.spawn(gpa, &actor, &registry, "e2e-caller");

    const conf = try caller.call("zygos::budget::configure", "{\"scope\":\"m8-turn\",\"max_tokens\":10000}");
    conf.deinit(gpa);

    const request =
        \\{"system":"m8 e2e","max_steps":8,"turn_id":"m8-1",
        \\ "router_function":"zygos::models::resolve","step_id":"exec",
        \\ "policy_function":"zygos::policy::check",
        \\ "approval_function":"zygos::approvals::request",
        \\ "budget_scope":"m8-turn",
        \\ "messages":[{"role":"user","content":"inspect the repo"}],
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

    // 1. The git filter ran on real `git diff` output: the change survived,
    //    the blob-hash metadata did not.
    if (std.mem.indexOf(u8, res.ok, "CHANGED LINE MARKER") == null)
        fail("the actual change was lost - filter is destructive: {s}", .{res.ok});
    if (std.mem.indexOf(u8, res.ok, "zygos diff:") == null)
        fail("git filter never ran on a real git diff: {s}", .{res.ok});
    // Far context was dropped (line 0 is 30 lines from the change).
    if (std.mem.indexOf(u8, res.ok, "context line 0\\n") != null)
        fail("far context survived - filter did not compress: {s}", .{res.ok});

    // 2. The dedup cache collapsed the repeated `git status`.
    if (std.mem.indexOf(u8, res.ok, "output unchanged since") == null)
        fail("repeated git status was not deduped: {s}", .{res.ok});

    // 3. The raw escape hatch bypassed the seam entirely: the second `git
    //    diff` still carries the metadata the filter strips.
    if (std.mem.indexOf(u8, res.ok, "index ") == null)
        fail("raw:true did not bypass the seam - metadata was stripped: {s}", .{res.ok});

    // 4. Stats prove the ratio over real command output.
    const stats = try caller.call("zygos::output::stats", "{}");
    defer stats.deinit(gpa);
    var sp = try std.json.parseFromSlice(std.json.Value, gpa, stats.ok, .{});
    defer sp.deinit();
    const raw_bytes: u64 = @intCast(sp.value.object.get("raw_bytes").?.integer);
    const sent_bytes: u64 = @intCast(sp.value.object.get("sent_bytes").?.integer);
    const filtered: i64 = sp.value.object.get("filtered").?.integer;
    const deduped: i64 = sp.value.object.get("deduped").?.integer;
    if (filtered < 1) fail("no call was filtered: {s}", .{stats.ok});
    if (deduped != 1) fail("expected exactly one dedup, got {d}: {s}", .{ deduped, stats.ok });
    if (sent_bytes >= raw_bytes) fail("no bytes saved: {s}", .{stats.ok});
    const pct = 100 - (sent_bytes * 100 / raw_bytes);
    if (pct < 60) fail("ratio {d}% below the 60% S8-exit floor: {s}", .{ pct, stats.ok });

    // 5. Savings reached the budget ledger.
    const check = try caller.call("zygos::budget::check", "{\"scope\":\"m8-turn\"}");
    defer check.deinit(gpa);
    var cp = try std.json.parseFromSlice(std.json.Value, gpa, check.ok, .{});
    defer cp.deinit();
    const saved = cp.value.object.get("saved_bytes").?.integer;
    if (saved <= 0) fail("no savings recorded to the budget: {s}", .{check.ok});

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
        "M8 E2E OK: real git output {d} -> {d} bytes ({d}% saved), filtered={d} deduped={d} budget_saved={d}\n",
        .{ raw_bytes, sent_bytes, pct, filtered, deduped, saved },
    );
}
