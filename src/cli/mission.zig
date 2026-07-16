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

const eprint = std.debug.print; // stderr

pub fn run(gpa: std.mem.Allocator, args: *std.process.Args.Iterator) u8 {
    // ---- args --------------------------------------------------------------
    const verb = args.next() orelse return usage();
    var resume_flag = false;
    if (std.mem.eql(u8, verb, "resume")) {
        resume_flag = true;
    } else if (std.mem.eql(u8, verb, "trace")) {
        return runTrace(gpa, args);
    } else if (!std.mem.eql(u8, verb, "start")) {
        return usage();
    }
    var brief_path: ?[]const u8 = null;
    var planning_opt: ?[]const u8 = null;
    var run_stamp = false;
    var no_tui = false;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--planning")) {
            planning_opt = args.next() orelse return usage();
        } else if (std.mem.eql(u8, a, "--resume")) {
            resume_flag = true;
        } else if (std.mem.eql(u8, a, "--run-stamp")) {
            run_stamp = true;
        } else if (std.mem.eql(u8, a, "--no-tui")) {
            no_tui = true;
        } else if (brief_path == null) {
            brief_path = a;
        } else {
            return usage();
        }
    }
    const bp = brief_path orelse return usage();

    // ---- brief (lint before anything boots) --------------------------------
    const brief_text = readWholeFile(gpa, bp) orelse {
        eprint("mission: cannot read brief {s}\n", .{bp});
        return 2;
    };
    switch (zygos.brief.lint(brief_text)) {
        .ok => {},
        .invalid => |e| {
            eprint("mission: brief rejected: {s}\n", .{zygos.brief.tag(e)});
            return 2;
        },
    }

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

    // ---- kernel + roster (the e2e/m3 wiring, catalog + manual approvals) ----
    var registry = zygos.inproc.Registry.init(gpa, null);
    // The blocking missions::start call spans the WHOLE mission — under the
    // flat invoke timeout it doubled as a mission duration cap (a 1h default
    // killed hour-long research runs mid-flight). It gets its own ceiling;
    // everything else (role turns, providers, gates) keeps
    // ZYGOS_INVOKE_TIMEOUT_MS. Must outlive the actor: function-local.
    const timeout_overrides = [_]zygos.actor.TimeoutOverride{
        .{ .prefix = "zygos::missions::", .timeout_ms = envInt(env, "ZYGOS_MISSION_TIMEOUT_MS", 86_400_000) },
    };
    var actor = zygos.actor.Actor.init(gpa, .{
        // Role turns ride bus invocations; real providers and console gates
        // outlive the 30s default.
        .invoke_timeout_ms = envInt(env, "ZYGOS_INVOKE_TIMEOUT_MS", 3_600_000),
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
    const planning_base = absPath(gpa, cwd, planning_opt orelse "./.planning") catch return oom();
    // Unattended-rerun semantics (Y3): --run-stamp gives every scheduled
    // invocation its own planning root; without it, starting over an
    // existing mission substrate refuses instead of clobbering it.
    const planning = if (run_stamp)
        std.fmt.allocPrint(gpa, "{s}-{s}", .{ planning_base, runStamp() }) catch return oom()
    else
        planning_base;
    if (!resume_flag and !run_stamp and fileExists(gpa, planning, "mission.json")) {
        eprint(
            "mission: {s} already holds a mission; resume it, pick a fresh --planning, or pass --run-stamp\n",
            .{planning},
        );
        return 2;
    }

    const turns = zygos.turn.TurnOrchestrator.start(gpa, &actor, &registry) catch return boot_fail();
    const tools = zygos.tools.ToolsWorker.start(gpa, &actor, &registry, cwd) catch return boot_fail();
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
    var policy_rules: std.ArrayList(zygos.policy.Rule) = .empty;
    policy_rules.appendSlice(gpa, &.{
        .{ .tool = "bash", .verdict = .allow },
        .{ .tool = "web_fetch", .verdict = .allow },
        .{ .tool = "web_search", .verdict = .allow },
    }) catch return oom();
    if (mcp) |m| {
        const names = m.toolNames(gpa) catch return oom();
        for (names) |n| policy_rules.append(gpa, .{ .tool = n, .verdict = .allow }) catch return oom();
    }
    const policy = zygos.policy.PolicyWorker.start(gpa, &actor, &registry, policy_rules.items) catch return boot_fail();
    _ = policy;
    // Search backend is operator env config: ZYGOS_SEARCH_ENGINE
    // (brave|searxng) + ZYGOS_SEARCH_ENDPOINT (+ ZYGOS_SEARCH_KEY_ENV,
    // default BRAVE_API_KEY for brave). Unset ⇒ web_search replies a
    // structured error per call; web_fetch always works.
    const web = zygos.web_tools.WebToolsWorker.start(gpa, &actor, &registry, io_boot.io(), .{
        .search = searchConfigFromEnv(env),
    }) catch return boot_fail();
    _ = web;
    const approvals = zygos.approval.ApprovalWorker.start(gpa, &actor, &registry, .{
        .manual = .{ .timeout_ms = @intCast(envInt(env, "ZYGOS_APPROVAL_TIMEOUT_MS", 300_000)) },
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

    const budget_req = std.fmt.allocPrint(gpa, "{{\"scope\":{f},\"max_tokens\":{d}}}", .{
        json.fmt(mission_id, .{}), envInt(env, "ZYGOS_BUDGET_MAX_TOKENS", 1_000_000),
    }) catch return oom();
    const conf = caller.call("zygos::budget::configure", budget_req) catch return boot_fail();
    conf.deinit(gpa);

    // ZYGOS_VAULT_ROOT (Y5): mission artifacts land behind a tessera-undo
    // checkpoint — an unusable vault refuses the run instead of writing
    // into it unprotected (fail closed).
    if (getEnv(env, "ZYGOS_VAULT_ROOT")) |vault_root| {
        const undo = zygos.tessera_undo.UndoWorker.start(gpa, &actor, &registry, .{
            .root = vault_root,
        }) catch return boot_fail();
        _ = undo;
        const cp_req = std.fmt.allocPrint(gpa, "{{\"label\":\"pre-mission {s}\"}}", .{mission_id}) catch return oom();
        const cp = caller.call("zygos::tessera::checkpoint", cp_req) catch {
            eprint("mission: vault checkpoint failed for {s}\n", .{vault_root});
            return 2;
        };
        defer cp.deinit(gpa);
        if (cp == .err) {
            eprint("mission: vault checkpoint failed for {s}\n", .{vault_root});
            return 2;
        }
    }

    // ---- console approvals (detached; EOF ⇒ manual timeouts deny) -----------
    // With a tty on both ends (and no opt-out) the live TUI takes over the
    // terminal: trace events + streamed deltas feed its model, approvals
    // resolve on a single keypress, std.log reroutes through the logbridge.
    // Piped/CI runs keep the plain path byte-identical.
    const console_worker = zygos.inproc.Worker.spawn(gpa, &actor, &registry, "mission-console") catch return boot_fail();
    const trace_path = std.fmt.allocPrint(gpa, "{s}/{s}", .{ planning, zygos.trace.file_name }) catch return oom();

    const want_tui = !no_tui and getEnv(env, "ZYGOS_NO_TUI") == null and zygos.tui.term.RealTerm.isTty();
    var real_term: zygos.tui.term.RealTerm = .{};
    var ui: ?*zygos.tui.Tui = null;
    var ui_sink: ?usize = null;
    var ui_tap: ?usize = null;
    if (want_tui and real_term.enterRaw()) {
        const t = zygos.tui.Tui.create(gpa, real_term.terminal()) catch return oom();
        if (t.start()) {
            ui = t;
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
            if (std.fmt.allocPrint(gpa, "trace → {s}", .{trace_path})) |note| {
                t.model.onLog(note);
                gpa.free(note);
            } else |_| {}
            if (std.Thread.spawn(.{}, tuiApprovalLoop, .{
                gpa, console_worker, t, real_term.terminal(),
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
    const request = std.fmt.allocPrint(gpa,
        \\{{"mission_id":{f},"planning_root":{f},"objective":{f},"brief":{f},
        \\ "router_function":"zygos::models::resolve",
        \\ "gate_function":"zygos::approvals::request",
        \\ "policy_function":"zygos::policy::check",
        \\ "approval_function":"zygos::approvals::request",
        \\ "budget_scope":{f},"trace_path":{f},
        \\ "role_max_steps":{d},"max_role_turns":{d}{s},
        \\ "tools":[
        \\  {{"name":"bash","function_id":"zygos::tools::bash",
        \\   "description":"Run a shell command in the mission workspace and get its output.",
        \\   "input_schema":{{"type":"object","properties":{{"command":{{"type":"string",
        \\    "description":"the shell command to run"}}}},"required":["command"]}}}},
        \\  {{"name":"web_search","function_id":"zygos::tools::web_search",
        \\   "description":"Search the web; returns a list of {{title,url,snippet}} results.",
        \\   "input_schema":{{"type":"object","properties":{{"query":{{"type":"string",
        \\    "description":"the search query"}}}},"required":["query"]}}}},
        \\  {{"name":"web_fetch","function_id":"zygos::tools::web_fetch",
        \\   "description":"Fetch a URL and return its readable text content.",
        \\   "input_schema":{{"type":"object","properties":{{"url":{{"type":"string",
        \\    "description":"the absolute http(s) URL to fetch"}}}},"required":["url"]}}}}{s}]}}
    , .{
        json.fmt(mission_id, .{}),                   json.fmt(planning, .{}),
        json.fmt(extractObjective(brief_text), .{}), json.fmt(brief_text, .{}),
        json.fmt(mission_id, .{}),                   json.fmt(trace_path, .{}),
        envInt(env, "ZYGOS_ROLE_MAX_STEPS", 24),     envInt(env, "ZYGOS_MAX_ROLE_TURNS", 48),
        if (resume_flag) ",\"resume\":true" else "", if (mcp) |m| m.toolEntriesJson(gpa) catch return oom() else "",
    }) catch return oom();

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

fn usage() u8 {
    eprint(
        "usage: zygos mission start|resume <brief.md> [--planning <dir>] [--resume] [--run-stamp] [--no-tui]\n" ++
            "       zygos mission trace <planning-dir|events.jsonl>\n",
        .{},
    );
    return 2;
}

/// `zygos mission trace <planning-dir|events.jsonl>` — render the run's
/// event log as a human view. Read-only; exits 2 when there is no trace.
fn runTrace(gpa: std.mem.Allocator, args: *std.process.Args.Iterator) u8 {
    const target = args.next() orelse return usage();
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

/// 0 only for state:"done"; a W1 server-side refusal is config-shaped (2).
fn terminalExitCode(gpa: std.mem.Allocator, payload: []const u8) u8 {
    var p = json.parseFromSlice(json.Value, gpa, payload, .{}) catch return 1;
    defer p.deinit();
    if (p.value != .object) return 1;
    if (p.value.object.get("refused") != null) return 2;
    const state = p.value.object.get("state") orelse return 1;
    if (state == .string and std.mem.eql(u8, state.string, "done")) return 0;
    return 1;
}

/// The brief's `## Objective` section body when present, else the whole text.
fn extractObjective(text: []const u8) []const u8 {
    const heading = "## Objective";
    const start = std.mem.indexOf(u8, text, heading) orelse return text;
    const body_start = start + heading.len;
    const rel_end = std.mem.indexOf(u8, text[body_start..], "\n## ") orelse
        return std.mem.trim(u8, text[body_start..], " \t\r\n");
    return std.mem.trim(u8, text[body_start .. body_start + rel_end], " \t\r\n");
}

/// Filename stem: basename minus the last extension.
fn stem(path: []const u8) []const u8 {
    const base = if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[i + 1 ..] else path;
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return base;
    return if (dot == 0) base else base[0..dot];
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

fn fileExists(gpa: std.mem.Allocator, dir: []const u8, name: []const u8) bool {
    const path_z = std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ dir, name }, 0) catch return false;
    defer gpa.free(path_z);
    const f = std.c.fopen(path_z.ptr, "r") orelse return false;
    _ = std.c.fclose(f);
    return true;
}

fn absPath(gpa: std.mem.Allocator, cwd: []const u8, path: []const u8) error{OutOfMemory}![]u8 {
    if (path.len > 0 and path[0] == '/') return gpa.dupe(u8, path);
    const rel = if (std.mem.startsWith(u8, path, "./")) path[2..] else path;
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ cwd, rel });
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

/// TUI twin of consoleLoop: the pending ask renders as the model's approval
/// band and resolves on a single keypress (raw mode). Ctrl-C arrives as byte
/// 0x03 (ISIG is off) — repair the terminal and re-raise SIGINT. If the
/// approval worker's manual timeout denies the ask first, the band clears on
/// the next poll — fail closed, same as the console path.
fn tuiApprovalLoop(
    gpa: std.mem.Allocator,
    worker: *zygos.inproc.Worker,
    ui: *zygos.tui.Tui,
    keys: zygos.tui.term.Terminal,
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

fn getEnv(env: []const zygos.providers_catalog.EnvPair, name: []const u8) ?[]const u8 {
    for (env) |p| if (std.mem.eql(u8, p.name, name)) return p.value;
    return null;
}

fn searchConfigFromEnv(env: []const zygos.providers_catalog.EnvPair) ?zygos.web_tools.SearchConfig {
    const engine_raw = getEnv(env, "ZYGOS_SEARCH_ENGINE") orelse return null;
    if (std.mem.eql(u8, engine_raw, "brave")) return .{
        .endpoint = getEnv(env, "ZYGOS_SEARCH_ENDPOINT") orelse "https://api.search.brave.com",
        .key_env = getEnv(env, "ZYGOS_SEARCH_KEY_ENV") orelse "BRAVE_API_KEY",
        .engine = .brave,
    };
    if (std.mem.eql(u8, engine_raw, "searxng")) {
        return .{
            .endpoint = getEnv(env, "ZYGOS_SEARCH_ENDPOINT") orelse return null,
            .engine = .searxng,
        };
    }
    return null;
}

fn envInt(env: []const zygos.providers_catalog.EnvPair, name: []const u8, default: i64) i64 {
    const raw = getEnv(env, name) orelse return default;
    return std.fmt.parseInt(i64, raw, 10) catch default;
}
