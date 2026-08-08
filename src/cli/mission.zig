//! `zygos mission start|resume <brief.md>` (X3, docs/specs/mission-cli.md).
//! Binary glue only: libc file/stdin IO (Z-02 — the std.Io lives inside
//! provider_boot.IoBoot), the e2e/m3 worker roster with catalog providers
//! and manual approvals, one blocking `zygos::missions::start` call.
//!
//! Config errors exit 2 before any kernel boots (fail closed); a terminal
//! mission exits 0 only on `state:"done"`. Approvals prompt on stderr and
//! read y/n from stdin; EOF stops prompting and the manual timeout denies.

const std = @import("std");
const json = std.json;
const zygos = @import("zygos");
const req_mod = @import("mission/req.zig");
const view_mod = @import("mission/view.zig");

const StartParams = req_mod.StartParams;
const buildStartRequest = req_mod.buildStartRequest;
const bashDesc = req_mod.bashDesc;
const extractObjective = req_mod.extractObjective;
const stem = req_mod.stem;
const terminalExitCode = req_mod.terminalExitCode;
const absPath = req_mod.absPath;

const eprint = std.debug.print; // stderr

pub fn run(gpa: std.mem.Allocator, args: *std.process.Args.Iterator) u8 {
    // ---- args (rules live in worker/mission_boot.zig) ----------------------
    var argv: std.ArrayList([]const u8) = .empty;
    while (args.next()) |a| argv.append(gpa, a) catch return oom();
    const parsed = zygos.mission_boot.parseArgs(argv.items) catch return usage();
    if (parsed.verb == .trace) return runTrace(gpa, parsed.brief_path);
    if (parsed.verb == .attach) return runAttach(gpa, parsed.brief_path);
    if (parsed.verb == .dashboard) return runDashboard(gpa, parsed.brief_path);
    const queue_mode = parsed.verb == .queue;
    const resume_flag = parsed.resume_flag;
    const run_stamp = parsed.run_stamp;
    const no_tui = parsed.no_tui or queue_mode;
    const bp = parsed.brief_path;

    // ---- briefs (lint everything before anything boots) --------------------
    var brief_paths: std.ArrayList([]const u8) = .empty;
    brief_paths.append(gpa, bp) catch return oom();
    if (queue_mode) brief_paths.appendSlice(gpa, parsed.rest) catch return oom();
    var brief_texts: std.ArrayList([]const u8) = .empty;
    for (brief_paths.items) |path| {
        const text = readWholeFile(gpa, path) orelse {
            eprint("mission: cannot read brief {s}\n", .{path});
            return 2;
        };
        switch (zygos.brief.lint(text)) {
            .ok => {},
            .invalid => |e| {
                eprint("mission: brief {s} rejected: {s}\n", .{ path, zygos.brief.tag(e) });
                return 2;
            },
        }
        brief_texts.append(gpa, text) catch return oom();
    }
    const brief_text = brief_texts.items[0];

    // ---- provider catalog ---------------------------------------------------
    const env = envPairs(gpa) catch return oom();
    const cat_path = zygos.providers_catalog.configPath(gpa, env) catch |err| switch (err) {
        error.NoHome => {
            eprint("mission: no AI_PROVIDERS_CONFIG and no HOME\n", .{});
            return 2;
        },
        error.OutOfMemory => return oom(),
    };
    const cat_text = readWholeFile(gpa, cat_path) orelse {
        eprint("mission: cannot read provider catalog {s}\n", .{cat_path});
        return 2;
    };
    var diag: zygos.providers_catalog.Diag = .{};
    var catalog = zygos.providers_catalog.Catalog.parse(gpa, cat_text, &diag) catch |err| switch (err) {
        error.OutOfMemory => return oom(),
        else => {
            eprint("mission: {s}:{d}: {s}\n", .{ cat_path, diag.line, diag.message });
            return 2;
        },
    };

    // ---- route table + boot refusal -----------------------------------------
    const zon_path = getEnv(env, "ZYGOS_CONFIG") orelse "./zygos.zon";
    const zon_text = readWholeFile(gpa, zon_path) orelse {
        eprint("mission: cannot read route table {s}\n", .{zon_path});
        return 2;
    };
    const route_cfg = zygos.router.Config.parse(gpa, zon_text) catch {
        eprint("mission: cannot parse route table {s}\n", .{zon_path});
        return 2;
    };
    zygos.provider_boot.checkRoutes(&catalog, &route_cfg) catch {
        eprint("mission: route table {s} names an unknown zygos::providers::* slug\n", .{zon_path});
        return 2;
    };
    const mcp_cfg = zygos.mcp_client.McpConfig.parse(gpa, zon_text) catch {
        eprint("mission: cannot parse .mcp_servers in {s}\n", .{zon_path});
        return 2;
    };
    const ctx_cfg = zygos.context.Config.parse(gpa, zon_text) catch {
        eprint("mission: invalid .context_strategy in {s}\n", .{zon_path});
        return 2;
    };

    // ---- kernel + roster (the e2e/m3 wiring, catalog + manual approvals) ----
    var registry = zygos.inproc.Registry.init(gpa, null);
    const tm = zygos.mission_boot.timeouts(env);
    // The blocking missions::start call spans the WHOLE mission, so it gets
    // its own ceiling; everything else keeps the invoke timeout. Must
    // outlive the actor: function-local.
    const timeout_overrides = [_]zygos.actor.TimeoutOverride{
        .{ .prefix = "zygos::missions::", .timeout_ms = tm.mission_ms },
    };
    var actor = zygos.actor.Actor.init(gpa, .{
        .invoke_timeout_ms = tm.invoke_ms,
        .invoke_timeout_overrides = &timeout_overrides,
    }, registry.outbound()) catch return oom();
    const kernel = std.Thread.spawn(.{}, zygos.actor.Actor.run, .{&actor}) catch {
        eprint("mission: cannot spawn kernel thread\n", .{});
        return 2;
    };
    _ = kernel;

    // Without a tick source the kernel never sweeps invocation deadlines and
    // ZYGOS_INVOKE_TIMEOUT_MS silently never fires (the WS gateway has its
    // own timer; this headless path must pump ticks itself).
    var tick_timer = zygos.ticker.Ticker.init(&actor, 250);
    tick_timer.start() catch {
        eprint("mission: cannot spawn tick timer\n", .{});
        return 2;
    };

    var io_boot = zygos.provider_boot.IoBoot.start(gpa);
    var boot = zygos.provider_boot.CatalogBoot.start(gpa, &actor, &registry, io_boot.io(), &catalog, env) catch {
        eprint("mission: provider boot failed\n", .{});
        return 2;
    };
    _ = &boot;

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse {
        eprint("mission: cannot resolve cwd\n", .{});
        return 2;
    };
    const cwd = std.mem.sliceTo(&cwd_buf, 0);

    const mission_id = stem(bp);
    const planning_base = absPath(gpa, cwd, parsed.planning orelse "./.planning") catch return oom();
    // Unattended-rerun semantics (Y3): --run-stamp gives every scheduled
    // invocation its own planning root; without it, starting over an
    // existing mission substrate refuses instead of clobbering it.
    const planning = zygos.mission_boot.planningRoot(gpa, planning_base, run_stamp, runStamp()) catch return oom();
    if (!queue_mode and zygos.mission_boot.refuseStart(resume_flag, run_stamp, fileExists(gpa, planning, "mission.json"))) {
        eprint(
            "mission: {s} already holds a mission; resume it, pick a fresh --planning, or pass --run-stamp\n",
            .{planning},
        );
        return 2;
    }

    // M7 executor worktree isolation: ZYGOS_WORKTREE=1 gives the executor a
    // detached git worktree under the planning root — the main tree stays
    // clean. A repo that cannot provide one refuses the run (fail closed:
    // isolation was requested). Queue mode re-isolates per mission below.
    var workspace: []const u8 = cwd;
    if (!queue_mode and zygos.mission_boot.worktreeEnabled(env)) {
        workspace = setupWorktree(gpa, cwd, planning) orelse return 2;
    }

    const turns = zygos.turn.TurnOrchestrator.start(gpa, &actor, &registry) catch return boot_fail();
    const tools = zygos.tools.ToolsWorker.start(gpa, &actor, &registry, workspace) catch return boot_fail();
    _ = tools;

    // ---- MCP servers (.mcp_servers in zygos.zon): spawn + handshake ---------
    // A configured-but-broken server refuses the run (fail closed); its tools
    // land on the bus as zygos::mcp::<server>::<tool> and in the turn's tool
    // list as <server>_<tool>, riding the same policy/trim/budget gates.
    var mcp_handles: std.ArrayList(zygos.mcp_client.ServerHandle) = .empty;
    for (mcp_cfg.servers()) |spec| {
        const child = zygos.mcp_client.ChildProcess.spawn(gpa, spec.argv) catch {
            eprint("mission: cannot spawn MCP server {s}\n", .{spec.name});
            return 2;
        };
        const cl = gpa.create(zygos.mcp_client.Client) catch return oom();
        cl.* = zygos.mcp_client.Client.init(gpa, child.transport());
        mcp_handles.append(gpa, .{ .name = spec.name, .client = cl }) catch return oom();
    }
    const mcp: ?*zygos.mcp_client.McpClientWorker = if (mcp_handles.items.len > 0)
        zygos.mcp_client.McpClientWorker.start(gpa, &actor, &registry, mcp_handles.items) catch {
            eprint("mission: MCP server handshake failed (fail closed)\n", .{});
            return 2;
        }
    else
        null;

    // bash=allow for X3: the console gate is the human boundary here;
    // per-tool asks return with X5's tightening pass. Web tools (Y1) ride
    // the same policy gate with the URL in the policy request (Y2). MCP
    // tools are operator-configured, so they boot as allow too.
    const mcp_names: []const []const u8 = if (mcp) |m| m.toolNames(gpa) catch return oom() else &.{};
    const policy_rules = zygos.mission_boot.policySeed(gpa, mcp_names) catch return oom();
    const policy = zygos.policy.PolicyWorker.start(gpa, &actor, &registry, policy_rules) catch return boot_fail();
    _ = policy;
    const web = zygos.web_tools.WebToolsWorker.start(gpa, &actor, &registry, io_boot.io(), .{
        .search = zygos.mission_boot.searchConfigFromEnv(env),
    }) catch return boot_fail();
    _ = web;
    const approvals = zygos.approval.ApprovalWorker.start(gpa, &actor, &registry, .{
        .manual = .{ .timeout_ms = @intCast(tm.approval_ms) },
    }) catch return boot_fail();
    _ = approvals;
    const router = zygos.router.RouterWorker.start(gpa, &actor, &registry, route_cfg) catch return boot_fail();
    _ = router;
    const budget = zygos.budget.BudgetWorker.start(gpa, &actor, &registry) catch return boot_fail();
    _ = budget;
    const trim = zygos.trim.TrimWorker.start(gpa, &actor, &registry, .{
        .max_bytes = 65536,
        .max_lines = 400,
        .head_lines = 120,
        .tail_lines = 80,
    }, mission_id) catch return boot_fail();
    _ = trim;
    const orch = zygos.mission.MissionOrchestrator.start(gpa, &actor, &registry) catch return boot_fail();
    _ = orch;
    const caller = zygos.inproc.Worker.spawn(gpa, &actor, &registry, "mission-cli") catch return boot_fail();

    if (!queue_mode) {
        const budget_req = std.fmt.allocPrint(gpa, "{{\"scope\":{f},\"max_tokens\":{d}}}", .{
            json.fmt(mission_id, .{}), zygos.mission_boot.budgetMaxTokens(env, brief_text),
        }) catch return oom();
        const conf = caller.call("zygos::budget::configure", budget_req) catch return boot_fail();
        conf.deinit(gpa);
    }

    // ZYGOS_VAULT_ROOT (Y5): mission artifacts land behind a tessera-undo
    // checkpoint — an unusable vault refuses the run instead of writing
    // into it unprotected (fail closed).
    if (getEnv(env, "ZYGOS_VAULT_ROOT")) |vault_root| {
        const undo = zygos.tessera_undo.UndoWorker.start(gpa, &actor, &registry, .{
            .root = vault_root,
        }) catch return boot_fail();
        _ = undo;
    }
    if (!queue_mode) {
        single_checkpoint: {
            const vault_root = getEnv(env, "ZYGOS_VAULT_ROOT") orelse break :single_checkpoint;
            const cp_req = zygos.mission_boot.checkpointRequest(gpa, mission_id) catch return oom();
            const cp = caller.call("zygos::tessera::checkpoint", cp_req) catch {
                eprint("mission: vault checkpoint failed for {s}\n", .{vault_root});
                return 2;
            };
            defer cp.deinit(gpa);
            if (zygos.mission_boot.checkpointVerdict(cp) == .refuse) {
                eprint("mission: vault checkpoint failed for {s}\n", .{vault_root});
                return 2;
            }
        }
    }

    // ---- console approvals (detached; EOF ⇒ manual timeouts deny) -----------
    // With a tty on both ends (and no opt-out) the live TUI takes over the
    // terminal: trace events + streamed deltas feed its model, approvals
    // resolve on a single keypress, std.log reroutes through the logbridge.
    // Piped/CI runs keep the plain path byte-identical.
    const console_worker = zygos.inproc.Worker.spawn(gpa, &actor, &registry, "mission-console") catch return boot_fail();
    const trace_path = std.fmt.allocPrint(gpa, "{s}/{s}", .{ planning, zygos.trace.file_name }) catch return oom();

    // Control channel (M6): a detached poller tails <planning>/control.jsonl
    // and dispatches steer/pause/resume/approve commands appended by
    // `zygos mission attach` onto the bus.
    if (!queue_mode) {
        const ctl_worker = zygos.inproc.Worker.spawn(gpa, &actor, &registry, "mission-control-tail") catch return boot_fail();
        if (std.Thread.spawn(.{}, controlLoop, .{ gpa, ctl_worker, planning, mission_id })) |t| t.detach() else |_| {}
    }

    const want_tui = !no_tui and getEnv(env, "ZYGOS_NO_TUI") == null and zygos.tui.term.RealTerm.isTty();
    var real_term: zygos.tui.term.RealTerm = .{};
    var ui: ?*zygos.tui.Tui = null;
    var ui_sink: ?usize = null;
    var ui_tap: ?usize = null;
    if (want_tui and real_term.enterRaw()) {
        // Truecolor before the render thread exists (theme mode is write-once).
        if (getEnv(env, "COLORTERM")) |ct| {
            if (std.mem.eql(u8, ct, "truecolor") or std.mem.eql(u8, ct, "24bit"))
                zygos.tui.theme.setMode(.truecolor);
        }
        // fd 2 points into the planning root while the TUI owns the screen:
        // writers that bypass std.log (std.debug stack dumps on unexpected
        // errnos in Debug builds) would otherwise splice into the band.
        mkdirQuiet(gpa, planning);
        if (std.fmt.allocPrintSentinel(gpa, "{s}/tui-stderr.log", .{planning}, 0)) |errlog| {
            real_term.redirectStderr(errlog.ptr);
            gpa.free(errlog);
        } else |_| {}
        // ZYGOS_TUI_CAPTURE=<path>: tee raw frames for terminal debugging.
        if (getEnv(env, "ZYGOS_TUI_CAPTURE")) |cap| {
            if (std.fmt.allocPrintSentinel(gpa, "{s}", .{cap}, 0)) |cap_z| {
                real_term.setCapture(cap_z.ptr);
                gpa.free(cap_z);
            } else |_| {}
        }
        const t = zygos.tui.Tui.create(gpa, real_term.terminal()) catch return oom();
        if (t.start()) {
            ui = t;
            t.model.setObjective(extractObjective(brief_text));
            ui_sink = zygos.trace.registerSink(.{
                .ctx = @ptrCast(&t.model),
                .onEvent = &zygos.tui.model.Model.sinkOnEvent,
            });
            turns.setDeltaObserver(.{
                .ctx = @ptrCast(&t.model),
                .onDelta = &zygos.tui.model.Model.observerOnDelta,
            });
            ui_tap = zygos.stream_tap.register(.{
                .ctx = @ptrCast(&t.model),
                .onDelta = &tapToModel,
            });
            zygos.tui.logbridge.install(.{
                .ctx = @ptrCast(&t.model),
                .onLine = &zygos.tui.model.Model.hookOnLine,
            });
            if (std.fmt.allocPrint(gpa, "trace → {s} · stderr → {s}/tui-stderr.log", .{ trace_path, planning })) |note| {
                t.model.onLog(note);
                gpa.free(note);
            } else |_| {}
            if (std.Thread.spawn(.{}, tuiApprovalLoop, .{
                gpa, console_worker, t, real_term.terminal(), mission_id,
            })) |thr| thr.detach() else |_| {}
        } else |_| {
            real_term.restore();
            t.stop();
        }
    }
    if (ui == null) {
        if (std.Thread.spawn(.{}, consoleLoop, .{ gpa, console_worker })) |t| t.detach() else |_| {}
        eprint("mission: trace → {s} (view: zygos mission trace {s})\n", .{ trace_path, planning });
    }

    // ---- the mission ---------------------------------------------------------
    // Scripted-test defaults (8 steps/turn, 16 turns) are too tight for real
    // executors iterating with tools — a real mission gets room by default.
    // The workspace path rides in the bash description: a model that does
    // not know its cwd wastes steps probing $HOME or inventing /home paths.
    const bash_desc = bashDesc(gpa, workspace) catch return oom();

    // ---- queue (M6): N missions sequentially under this one kernel ---------
    // Per-mission planning roots (<base>-<stem>) and budget scopes; an
    // existing substrate resumes instead of refusing (idempotent, cron-safe);
    // terminal substrates report and move on. SIGINT stops the queue between
    // missions and aborts the one in flight. Trim's saved_bytes scope stays
    // pinned to the first mission id (v1 shared-roster limit).
    if (queue_mode) {
        installSigint();
        var worst: u8 = 0;
        for (brief_paths.items, brief_texts.items) |qpath, qtext| {
            if (sigint_hits.load(.acquire) > 0) break;
            const mid = stem(qpath);
            var root = std.fmt.allocPrint(gpa, "{s}-{s}", .{ planning_base, mid }) catch return oom();
            if (run_stamp)
                root = std.fmt.allocPrint(gpa, "{s}-{s}", .{ root, runStamp() }) catch return oom();
            const resume_q = fileExists(gpa, root, "mission.json");

            const bconf = std.fmt.allocPrint(gpa, "{{\"scope\":{f},\"max_tokens\":{d}}}", .{
                json.fmt(mid, .{}), zygos.mission_boot.budgetMaxTokens(env, qtext),
            }) catch return oom();
            const conf = caller.call("zygos::budget::configure", bconf) catch return boot_fail();
            conf.deinit(gpa);

            if (getEnv(env, "ZYGOS_VAULT_ROOT")) |vault_root| {
                const cp_req = zygos.mission_boot.checkpointRequest(gpa, mid) catch return oom();
                const cp = caller.call("zygos::tessera::checkpoint", cp_req) catch {
                    eprint("mission: vault checkpoint failed for {s}\n", .{vault_root});
                    return 2;
                };
                defer cp.deinit(gpa);
                if (zygos.mission_boot.checkpointVerdict(cp) == .refuse) {
                    eprint("mission: vault checkpoint failed for {s}\n", .{vault_root});
                    return 2;
                }
            }

            {
                const ctl_worker = zygos.inproc.Worker.spawn(gpa, &actor, &registry, "mission-control-tail") catch return boot_fail();
                if (std.Thread.spawn(.{}, controlLoop, .{ gpa, ctl_worker, root, mid })) |t| t.detach() else |_| {}
                const sig_worker = zygos.inproc.Worker.spawn(gpa, &actor, &registry, "mission-sigint") catch return boot_fail();
                if (std.Thread.spawn(.{}, sigintWatch, .{ gpa, sig_worker, mid })) |t| t.detach() else |_| {}
            }

            // Per-mission worktree (the queue item is the wave): a fresh
            // ToolsWorker re-registers zygos::tools::* (last-wins) at the
            // new workspace.
            var q_bash = bash_desc;
            if (zygos.mission_boot.worktreeEnabled(env)) {
                const q_workspace = setupWorktree(gpa, cwd, root) orelse return 2;
                _ = zygos.tools.ToolsWorker.start(gpa, &actor, &registry, q_workspace) catch return boot_fail();
                q_bash = bashDesc(gpa, q_workspace) catch return oom();
            }

            const qtrace = std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, zygos.trace.file_name }) catch return oom();
            eprint("mission queue: {s} → {s}{s}\n", .{ mid, root, if (resume_q) " (resume)" else "" });
            const qreq = buildStartRequest(gpa, .{
                .mission_id = mid,
                .planning = root,
                .brief_text = qtext,
                .trace_path = qtrace,
                .resume_flag = resume_q,
                .bash_desc = q_bash,
                .mcp_entries = if (mcp) |mm| mm.toolEntriesJson(gpa) catch return oom() else "",
                .ctx_kind = ctx_cfg.kind,
                .ctx_max_tokens = ctx_cfg.max_tokens,
                .role_max_steps = tm.role_max_steps,
                .max_role_turns = tm.max_role_turns,
            }) catch return oom();
            const qres = caller.call("zygos::missions::start", qreq) catch {
                eprint("mission {s}: bus call failed\n", .{mid});
                worst = @max(worst, 1);
                continue;
            };
            defer qres.deinit(gpa);
            switch (qres) {
                .err => |code| {
                    eprint("mission {s}: errored: {s}\n", .{ mid, code });
                    worst = @max(worst, 1);
                },
                .ok => |payload| {
                    writeStdout(payload);
                    writeStdout("\n");
                    worst = @max(worst, terminalExitCode(gpa, payload));
                },
            }
        }
        return worst;
    }

    const request = buildStartRequest(gpa, .{
        .mission_id = mission_id,
        .planning = planning,
        .brief_text = brief_text,
        .trace_path = trace_path,
        .resume_flag = resume_flag,
        .bash_desc = bash_desc,
        .mcp_entries = if (mcp) |m| m.toolEntriesJson(gpa) catch return oom() else "",
        .ctx_kind = ctx_cfg.kind,
        .ctx_max_tokens = ctx_cfg.max_tokens,
        .role_max_steps = tm.role_max_steps,
        .max_role_turns = tm.max_role_turns,
    }) catch return oom();

    // M7 net hardening: SIGINT (cron kill, Ctrl-C) lands as a clean abort —
    // the watcher posts missions::abort and the blocking start returns a
    // terminal "aborted" state through the normal exit path. A second
    // SIGINT hard-exits.
    installSigint();
    {
        const sig_worker = zygos.inproc.Worker.spawn(gpa, &actor, &registry, "mission-sigint") catch return boot_fail();
        if (std.Thread.spawn(.{}, sigintWatch, .{ gpa, sig_worker, mission_id })) |t| t.detach() else |_| {}
    }

    const res = caller.call("zygos::missions::start", request) catch {
        if (ui) |t| tuiStop(t, ui_sink, ui_tap, turns, &real_term);
        eprint("mission: bus call failed\n", .{});
        return 1;
    };
    // ALWAYS before touching stdout/stderr: the final JSON must print onto a
    // restored (cooked, cursor-visible) terminal, below the TUI's last frame.
    if (ui) |t| tuiStop(t, ui_sink, ui_tap, turns, &real_term);
    switch (res) {
        .err => |code| {
            eprint("mission: errored: {s}\n", .{code});
            return 1;
        },
        .ok => |payload| {
            writeStdout(payload);
            writeStdout("\n");
            return terminalExitCode(gpa, payload);
        },
    }
}

/// Unhook the model from every producer, stop rendering (paints the final
/// frame), restore the terminal. Deliberately never destroys the Tui: the
/// detached approval thread may still hold the model, and the process exits
/// right after (run() leaks its workers the same way).
fn tuiStop(ui: *zygos.tui.Tui, sink: ?usize, tap: ?usize, turns: *zygos.turn.TurnOrchestrator, real: *zygos.tui.term.RealTerm) void {
    turns.setDeltaObserver(null);
    if (sink) |token| zygos.trace.unregisterSink(token);
    if (tap) |token| zygos.stream_tap.unregister(token);
    zygos.tui.logbridge.clear();
    ui.stop();
    real.restore();
}

/// stream_tap → model adapter: thinking/tool kinds map onto the model's
/// live blocks (tui/ stays free of worker types; this switch is the glue).
fn tapToModel(ctx: *anyopaque, kind: zygos.stream_tap.Kind, bytes: []const u8) void {
    const model: *zygos.tui.model.Model = @ptrCast(@alignCast(ctx));
    switch (kind) {
        .thinking => model.onThinking(bytes),
        .tool_name => model.onToolName(bytes),
        .tool_args => model.onToolArgs(bytes),
    }
}

// ---- SIGINT → clean abort (M7) ----------------------------------------------

var sigint_hits = std.atomic.Value(u8).init(0);

fn onSigint(_: c_int) callconv(.c) void {
    // Async-signal-safe only: flip the atomic; the watcher does the work.
    if (sigint_hits.fetchAdd(1, .acq_rel) >= 1) {
        zygos.tui.emergencyRestore();
        std.c._exit(130);
    }
}

extern "c" fn signal(sig: c_int, handler: ?*const fn (c_int) callconv(.c) void) ?*const fn (c_int) callconv(.c) void;

fn installSigint() void {
    _ = signal(2, &onSigint); // SIGINT
}

/// Detached: waits for the flag, aborts the mission over the bus once.
fn sigintWatch(gpa: std.mem.Allocator, worker: *zygos.inproc.Worker, mission_id: []const u8) void {
    while (sigint_hits.load(.acquire) == 0) {
        var interval: std.c.timespec = .{ .sec = 0, .nsec = 200 * std.time.ns_per_ms };
        var rem: std.c.timespec = undefined;
        _ = std.c.nanosleep(&interval, &rem);
    }
    const req = std.fmt.allocPrint(gpa, "{{\"mission_id\":{f}}}", .{json.fmt(mission_id, .{})}) catch return;
    defer gpa.free(req);
    const res = worker.call("zygos::missions::abort", req) catch return;
    res.deinit(gpa);
}

fn usage() u8 {
    eprint(
        "usage: zygos mission start|resume <brief.md> [--planning <dir>] [--resume] [--run-stamp] [--no-tui]\n" ++
            "       zygos mission queue [--planning <base>] [--run-stamp] <brief.md>...\n" ++
            "       zygos mission trace <planning-dir|events.jsonl>\n" ++
            "       zygos mission attach <planning-dir>\n" ++
            "       zygos mission dashboard <dir>\n",
        .{},
    );
    return 2;
}

/// Create (or reuse) the mission's detached git worktree under the planning
/// root. Null = refusal: isolation was requested and the repo cannot
/// provide it (fail closed). An existing worktree (resume) is reused.
fn setupWorktree(gpa: std.mem.Allocator, repo: []const u8, planning: []const u8) ?[]const u8 {
    const path = zygos.mission_boot.worktreePath(gpa, planning) catch return null;
    if (fileExists(gpa, path, ".git")) return path; // resumed run: reuse
    mkdirQuiet(gpa, planning);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const argv = zygos.mission_boot.worktreeAddArgv(repo, path);
    const runner = zygos.context_thread.PopenRunner.runner();
    _ = runner.run(arena_state.allocator(), &argv) orelse {
        eprint("mission: git worktree add failed in {s} (is it a git repo?)\n", .{repo});
        return null;
    };
    return path;
}

/// Detached control-channel poller inside the RUNNING mission: tail
/// control.jsonl, translate each command onto the bus. Malformed lines are
/// skipped; a dead bus ends the loop (the process is exiting).
fn controlLoop(gpa: std.mem.Allocator, worker: *zygos.inproc.Worker, planning: []const u8, mission_id: []const u8) void {
    var tail: zygos.control.Tail = .{};
    while (true) {
        var interval: std.c.timespec = .{ .sec = 0, .nsec = 300 * std.time.ns_per_ms };
        var rem: std.c.timespec = undefined;
        _ = std.c.nanosleep(&interval, &rem);

        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ planning, zygos.control.file_name }) catch continue;
        const lines = tail.poll(arena, path) catch continue;
        for (lines) |line| {
            const cmd = zygos.control.parseCommandLine(arena, line) orelse continue;
            const req = zygos.control.requestFor(arena, mission_id, cmd) catch continue;
            const res = worker.call(req.function, req.body) catch return;
            res.deinit(gpa);
        }
    }
}

/// `zygos mission dashboard <dir>` — one status line per mission substrate
/// under <dir> (the dir itself and its immediate children). File-based, so
/// live, parked, and crashed runs all list from any process; pair with
/// `zygos mission attach <root>` to intervene.
fn runDashboard(gpa: std.mem.Allocator, dir: []const u8) u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const trimmed = std.mem.trimEnd(u8, dir, "/");
    const runner = zygos.context_thread.PopenRunner.runner();
    var shown: usize = 0;
    for ([_][]const u8{ "/mission.json", "/*/mission.json" }) |suffix| {
        const glob = std.mem.concat(arena, u8, &.{ trimmed, suffix }) catch return oom();
        const listing = runner.run(arena, &.{ "ls", "-1d", glob }) orelse continue;
        var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, listing, "\n"), '\n');
        while (lines.next()) |path| {
            if (path.len == 0) continue;
            const line = dashboardLine(arena, path) orelse continue;
            writeStdout(line);
            shown += 1;
        }
    }
    if (shown == 0) {
        eprint("dashboard: no mission substrates under {s}\n", .{trimmed});
        return 2;
    }
    return 0;
}

fn dashboardLine(arena: std.mem.Allocator, state_path: []const u8) ?[]const u8 {
    const text = readWholeFile(arena, state_path) orelse return null;
    return view_mod.dashboardLine(arena, state_path, text);
}

/// `zygos mission attach <planning-dir>` — tail the run's events.jsonl as a
/// live rendered stream while stdin lines drive the control channel:
/// `steer <text>` | `pause` | `resume` | `approve <id> y|n`. Works against a
/// crashed mission too: the view shows what happened, commands park in
/// control.jsonl until a resume picks them up. Ctrl-D detaches.
fn runAttach(gpa: std.mem.Allocator, target: []const u8) u8 {
    const dir = std.mem.trimEnd(u8, target, "/");
    const events_path = std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, zygos.trace.file_name }) catch return oom();
    eprint(
        "attach: {s}\ncommands: steer <text> | pause | resume | approve <id> y|n | Ctrl-D detaches\n",
        .{dir},
    );

    const Tailer = struct {
        fn run(alloc: std.mem.Allocator, path: []const u8) void {
            var tail: zygos.control.Tail = .{};
            while (true) {
                var interval: std.c.timespec = .{ .sec = 0, .nsec = 300 * std.time.ns_per_ms };
                var rem: std.c.timespec = undefined;
                _ = std.c.nanosleep(&interval, &rem);
                var arena_state = std.heap.ArenaAllocator.init(alloc);
                defer arena_state.deinit();
                const arena = arena_state.allocator();
                const lines = tail.poll(arena, path) catch continue;
                for (lines) |line| {
                    const with_nl = std.fmt.allocPrint(arena, "{s}\n", .{line}) catch continue;
                    const rendered = zygos.trace.render(arena, with_nl) catch continue;
                    writeStdout(rendered);
                }
            }
        }
    };
    if (std.Thread.spawn(.{}, Tailer.run, .{ gpa, events_path })) |t| t.detach() else |_| {
        eprint("attach: cannot spawn tailer\n", .{});
        return 2;
    }

    var line_buf: [4096]u8 = undefined;
    while (readStdinLine(&line_buf)) |line| {
        const cmd: zygos.control.Command = switch (view_mod.parseAttachCommand(line)) {
            .ignore => continue,
            .err => |msg| {
                eprint("attach: {s}: {s}\n", .{ msg, std.mem.trim(u8, line, " \t") });
                continue;
            },
            .cmd => |c| c,
        };
        zygos.control.appendCommand(gpa, dir, cmd) catch return oom();
        eprint("attach: queued\n", .{});
    }
    return 0;
}

/// `zygos mission trace <planning-dir|events.jsonl>` — render the run's
/// event log as a human view. Read-only; exits 2 when there is no trace.
fn runTrace(gpa: std.mem.Allocator, target: []const u8) u8 {
    // Planning root first: fopen("r") on a directory succeeds with an empty
    // read on macOS, so trying the bare target first would render nothing.
    const joined = std.fmt.allocPrint(gpa, "{s}/{s}", .{
        std.mem.trimEnd(u8, target, "/"), zygos.trace.file_name,
    }) catch return oom();
    defer gpa.free(joined);
    const text = readWholeFile(gpa, joined) orelse readWholeFile(gpa, target) orelse {
        eprint("mission: no trace at {s} (is this a planning root?)\n", .{target});
        return 2;
    };
    const rendered = zygos.trace.render(gpa, text) catch return oom();
    writeStdout(rendered);
    return 0;
}

fn oom() u8 {
    eprint("mission: out of memory\n", .{});
    return 2;
}

fn boot_fail() u8 {
    eprint("mission: worker boot failed\n", .{});
    return 2;
}

var stamp_buf: [15]u8 = undefined;

/// Wall-clock "YYYYMMDD-HHMMSS" (UTC) for --run-stamp planning roots.
fn runStamp() []const u8 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    const ep: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(0, ts.sec)) };
    const yd = ep.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = ep.getDaySeconds();
    _ = std.fmt.bufPrint(&stamp_buf, "{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}", .{
        yd.year,              md.month.numeric(),      md.day_index + 1,
        ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    }) catch unreachable;
    return &stamp_buf;
}

fn mkdirQuiet(gpa: std.mem.Allocator, path: []const u8) void {
    const path_z = std.fmt.allocPrintSentinel(gpa, "{s}", .{path}, 0) catch return;
    defer gpa.free(path_z);
    _ = std.c.mkdir(path_z.ptr, 0o755); // EEXIST and friends: fine, best-effort
}

fn fileExists(gpa: std.mem.Allocator, dir: []const u8, name: []const u8) bool {
    const path_z = std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ dir, name }, 0) catch return false;
    defer gpa.free(path_z);
    const f = std.c.fopen(path_z.ptr, "r") orelse return false;
    _ = std.c.fclose(f);
    return true;
}

// ---- console approvals ------------------------------------------------------

/// Poll pending asks, prompt on stderr, resolve from stdin lines. Detached:
/// stdin EOF (or any bus failure) ends the loop and the approval worker's
/// manual timeout denies whatever is still parked — fail closed.
fn consoleLoop(gpa: std.mem.Allocator, worker: *zygos.inproc.Worker) void {
    var handled = std.StringHashMap(void).init(gpa);
    while (true) {
        var interval: std.c.timespec = .{ .sec = 0, .nsec = 300 * std.time.ns_per_ms };
        var rem: std.c.timespec = undefined;
        _ = std.c.nanosleep(&interval, &rem);
        const res = worker.call("zygos::approvals::pending", "{}") catch return;
        defer res.deinit(gpa);
        if (res != .ok) return;

        var p = json.parseFromSlice(json.Value, gpa, res.ok, .{}) catch continue;
        defer p.deinit();
        const list = p.value.object.get("pending") orelse continue;
        if (list != .array) continue;
        for (list.array.items) |item| {
            if (item != .object) continue;
            const id = strOf(item.object.get("id")) orelse continue;
            if (handled.contains(id)) continue;
            const tool = strOf(item.object.get("tool")) orelse "?";
            const reason = strOf(item.object.get("reason")) orelse "";
            eprint("approve {s}: {s}? [y/N] ", .{ tool, reason });

            var line_buf: [64]u8 = undefined;
            const line = readStdinLine(&line_buf) orelse return; // EOF: fail closed
            const approved = line.len > 0 and (line[0] == 'y' or line[0] == 'Y');
            const req = std.fmt.allocPrint(gpa, "{{\"id\":{f},\"approved\":{}}}", .{
                json.fmt(id, .{}), approved,
            }) catch return;
            defer gpa.free(req);
            const rr = worker.call("zygos::approvals::resolve", req) catch return;
            rr.deinit(gpa);
            handled.put(gpa.dupe(u8, id) catch return, {}) catch return;
        }
    }
}

/// TUI twin of consoleLoop, plus the M6 intervention keys: the pending ask
/// resolves on y/n; `s` opens the steer input line (Enter sends over the
/// bus, Esc discards), `p`/`r` pause/resume the mission. Ctrl-C arrives as
/// byte 0x03 (ISIG is off) — repair the terminal and re-raise SIGINT (the
/// M7 handler turns it into a clean abort). If the approval worker's manual
/// timeout denies the ask first, the band clears on the next poll — fail
/// closed, same as the console path.
fn tuiApprovalLoop(
    gpa: std.mem.Allocator,
    worker: *zygos.inproc.Worker,
    ui: *zygos.tui.Tui,
    keys: zygos.tui.term.Terminal,
    mission_id: []const u8,
) void {
    var handled = std.StringHashMap(void).init(gpa);
    var current_id: ?[]u8 = null;
    while (true) {
        // The 100ms key poll doubles as the loop interval.
        if (keys.readKey(100)) |k| {
            if (k == 0x03) {
                zygos.tui.emergencyRestore();
                _ = std.c.raise(.INT);
                return;
            }
            if (ui.model.steerInputOpen()) {
                switch (k) {
                    '\r', '\n' => if (ui.model.steerTake()) |text| {
                        defer gpa.free(text);
                        const req = std.fmt.allocPrint(gpa, "{{\"mission_id\":{f},\"text\":{f}}}", .{
                            json.fmt(mission_id, .{}), json.fmt(text, .{}),
                        }) catch continue;
                        defer gpa.free(req);
                        const res = worker.call("zygos::missions::steer", req) catch return;
                        res.deinit(gpa);
                        ui.model.onLog("⚑ steer queued for the next role boundary");
                    },
                    0x1b => ui.model.steerCancel(),
                    else => ui.model.steerKey(k),
                }
                continue;
            }
            if (current_id == null) switch (k) {
                's' => {
                    ui.model.steerOpen();
                    continue;
                },
                'p', 'r' => {
                    const fun = if (k == 'p') "zygos::missions::pause" else "zygos::missions::resume";
                    const req = std.fmt.allocPrint(gpa, "{{\"mission_id\":{f}}}", .{
                        json.fmt(mission_id, .{}),
                    }) catch continue;
                    defer gpa.free(req);
                    const res = worker.call(fun, req) catch return;
                    res.deinit(gpa);
                    ui.model.setPaused(k == 'p');
                    continue;
                },
                else => {},
            };
            const id = current_id orelse continue;
            const approved = switch (k) {
                'y', 'Y' => true,
                'n', 'N', '\r', '\n' => false,
                else => continue,
            };
            const req = std.fmt.allocPrint(gpa, "{{\"id\":{f},\"approved\":{}}}", .{
                json.fmt(id, .{}), approved,
            }) catch return;
            defer gpa.free(req);
            const rr = worker.call("zygos::approvals::resolve", req) catch return;
            rr.deinit(gpa);
            ui.model.setPendingApproval(null);
            handled.put(id, {}) catch return; // key ownership moves to the map
            current_id = null;
            continue;
        }

        const res = worker.call("zygos::approvals::pending", "{}") catch return;
        defer res.deinit(gpa);
        if (res != .ok) return;
        var p = json.parseFromSlice(json.Value, gpa, res.ok, .{}) catch continue;
        defer p.deinit();
        const list = p.value.object.get("pending") orelse continue;
        if (list != .array) continue;

        if (current_id) |id| {
            var still_pending = false;
            for (list.array.items) |item| {
                if (item != .object) continue;
                const pid = strOf(item.object.get("id")) orelse continue;
                if (std.mem.eql(u8, pid, id)) still_pending = true;
            }
            if (!still_pending) { // timed out server-side: denied
                ui.model.setPendingApproval(null);
                handled.put(id, {}) catch return;
                current_id = null;
            }
        }
        if (current_id == null) for (list.array.items) |item| {
            if (item != .object) continue;
            const id = strOf(item.object.get("id")) orelse continue;
            if (handled.contains(id)) continue;
            const tool = strOf(item.object.get("tool")) orelse "?";
            const reason = strOf(item.object.get("reason")) orelse "";
            const summary = std.fmt.allocPrint(gpa, "{s}: {s}", .{ tool, reason }) catch return;
            defer gpa.free(summary);
            ui.model.setPendingApproval(summary);
            current_id = gpa.dupe(u8, id) catch return;
            break;
        };
    }
}

fn strOf(v: ?json.Value) ?[]const u8 {
    const val = v orelse return null;
    return if (val == .string) val.string else null;
}

fn readStdinLine(buf: []u8) ?[]const u8 {
    var i: usize = 0;
    while (i < buf.len) {
        var ch: [1]u8 = undefined;
        const n = std.c.read(0, &ch, 1);
        if (n <= 0) return null;
        if (ch[0] == '\n') break;
        buf[i] = ch[0];
        i += 1;
    }
    return buf[0..i];
}

// ---- libc plumbing (Z-02: no std.Io here) ------------------------------------

fn writeStdout(bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.c.write(1, bytes.ptr + off, bytes.len - off);
        if (n <= 0) return;
        off += @intCast(n);
    }
}

fn readWholeFile(gpa: std.mem.Allocator, path: []const u8) ?[:0]u8 {
    const path_z = std.fmt.allocPrintSentinel(gpa, "{s}", .{path}, 0) catch return null;
    defer gpa.free(path_z);
    const f = std.c.fopen(path_z.ptr, "r") orelse return null;
    defer _ = std.c.fclose(f);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = std.c.fread(&chunk, 1, chunk.len, f);
        if (n == 0) break;
        buf.appendSlice(gpa, chunk[0..n]) catch return null;
    }
    return buf.toOwnedSliceSentinel(gpa, 0) catch null;
}

fn envPairs(gpa: std.mem.Allocator) error{OutOfMemory}![]zygos.providers_catalog.EnvPair {
    var list: std.ArrayList(zygos.providers_catalog.EnvPair) = .empty;
    defer list.deinit(gpa);
    var i: usize = 0;
    while (std.c.environ[i]) |entry| : (i += 1) {
        const span = std.mem.span(entry);
        const eq = std.mem.indexOfScalar(u8, span, '=') orelse continue;
        try list.append(gpa, .{ .name = span[0..eq], .value = span[eq + 1 ..] });
    }
    return list.toOwnedSlice(gpa);
}

const getEnv = zygos.mission_boot.getEnv;
