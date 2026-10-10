//! `zygos task run` and `zygos task score`.
//!
//! `run` is the headless Harbor entry. It is not a mission: no product-owner
//! gate, and exit 0 means the process finished and wrote a trial, including
//! when a tool was denied. Exit 2 is a refusal. `--offline` is the scripted
//! provider. Live models are explicitly approved campaign entries.
//! Any other model, dataset, or step cap above the pilot bound is refused.
//!
//! The git sha, target triple, optimize level, and adapter version are pinned
//! into every trial. Cache counts stay on that trial. The trace usage line
//! is not this command's to extend.
//!
//! `--config zygos.zon` routes the task step over the file's ladder
//! (task_config.zig) and pins the file's SHA-256 on the trial. Every attempt
//! must name an approved model and a catalog slug with a key; anything
//! else refuses before a provider boots.

const std = @import("std");
const builtin = @import("builtin");
const zygos = @import("zygos");
const build_info = @import("build_info");

const fsx = zygos.fsx;
const eprint = std.debug.print;

extern "c" fn realpath(path: [*:0]const u8, resolved: [*]u8) ?[*:0]u8;

pub const ArgError = error{ Usage, Help, LiveRefused };

pub const approved_pilot_model = "glm-5.3-flash";
pub const approved_rerun_model = "deepseek/deepseek-v4.1-flash";
pub const approved_pilot_dataset = "terminal-bench/terminal-bench-2-1";
/// Default turn wall clock, under Harbor's default agent ceiling so a trial
/// is still written. The adapter passes the actual value as --timeout-ms.
pub const default_timeout_ms: u64 = 540_000;
pub const timeout_ms_max: u64 = 3_600_000;
/// Kernel backstop for `zygos::turns::run`, past the wall clock.
const invoke_slack_ms: i64 = 120_000;

pub const RunArgs = struct {
    workspace: []const u8,
    out_path: []const u8,
    events: ?[]const u8 = null,
    trim: bool = true,
    model: ?[]const u8 = null,
    step_cap: ?usize = null,
    task_id: ?[]const u8 = null,
    dataset: ?[]const u8 = null,
    instruction_file: ?[]const u8 = null,
    config: ?[]const u8 = null,
    timeout_ms: u64 = default_timeout_ms,
};

pub const ConfigError = error{
    /// An attempt names a model outside the live allowlist.
    ModelRefused,
    /// An attempt's function is not `zygos::providers::<slug>` for a catalog row.
    UnknownProviderSlug,
    /// `--model` is not the ladder's first attempt.
    ModelMismatch,
    /// A routed catalog row resolves no key.
    MissingKey,
    OutOfMemory,
};

pub const ScoreArgs = struct {
    trial_path: []const u8,
    prices_path: []const u8,
};

pub const ScoreTextError = error{
    MalformedTrial,
    MissingBuildIdentity,
    OutOfMemory,
    MissingPrice,
    TrimEvidenceMissing,
    TrimOnZeroReduction,
    UnknownVariable,
};

pub fn run(gpa: std.mem.Allocator, args: *std.process.Args.Iterator) u8 {
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(gpa);
    while (args.next()) |a| list.append(gpa, a) catch return 1;
    return dispatch(gpa, list.items);
}

pub fn dispatch(gpa: std.mem.Allocator, argv: []const []const u8) u8 {
    if (argv.len == 0) {
        printUsage();
        return 2;
    }
    if (isHelp(argv[0])) {
        printUsage();
        return 0;
    }
    if (std.mem.eql(u8, argv[0], "run")) return runTask(gpa, argv[1..]);
    if (std.mem.eql(u8, argv[0], "score")) return runScore(gpa, argv[1..]);
    printUsage();
    return 2;
}

pub fn parseRun(argv: []const []const u8) ArgError!RunArgs {
    var offline = false;
    var help = false;
    var workspace: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var events: ?[]const u8 = null;
    var trim = true;
    var model: ?[]const u8 = null;
    var step_cap: ?usize = null;
    var task_id: ?[]const u8 = null;
    var dataset: ?[]const u8 = null;
    var instruction_file: ?[]const u8 = null;
    var config: ?[]const u8 = null;
    var timeout_ms: ?u64 = null;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (isHelp(a)) {
            help = true;
        } else if (std.mem.eql(u8, a, "--offline")) {
            offline = true;
        } else if (std.mem.eql(u8, a, "--model")) {
            i += 1;
            if (i >= argv.len or argv[i].len == 0) return error.Usage;
            model = argv[i];
        } else if (std.mem.eql(u8, a, "--workspace")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            workspace = argv[i];
        } else if (std.mem.eql(u8, a, "--out")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out_path = argv[i];
        } else if (std.mem.eql(u8, a, "--events")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            events = argv[i];
        } else if (std.mem.eql(u8, a, "--trim")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            if (std.mem.eql(u8, argv[i], "on")) trim = true else if (std.mem.eql(u8, argv[i], "off")) trim = false else return error.Usage;
        } else if (std.mem.eql(u8, a, "--step-cap")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            step_cap = parseUsize(argv[i]) orelse return error.Usage;
        } else if (std.mem.eql(u8, a, "--task-id")) {
            i += 1;
            if (i >= argv.len or argv[i].len == 0) return error.Usage;
            task_id = argv[i];
        } else if (std.mem.eql(u8, a, "--dataset")) {
            i += 1;
            if (i >= argv.len or argv[i].len == 0) return error.Usage;
            dataset = argv[i];
        } else if (std.mem.eql(u8, a, "--instruction-file")) {
            i += 1;
            if (i >= argv.len or argv[i].len == 0) return error.Usage;
            instruction_file = argv[i];
        } else if (std.mem.eql(u8, a, "--config")) {
            i += 1;
            if (i >= argv.len or argv[i].len == 0) return error.Usage;
            config = argv[i];
        } else if (std.mem.eql(u8, a, "--timeout-ms")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            const t = parseUsize(argv[i]) orelse return error.Usage;
            if (t < 1000 or t > timeout_ms_max) return error.Usage;
            timeout_ms = t;
        } else return error.Usage;
    }
    if (help) return error.Help;
    const ws = workspace orelse return error.Usage;
    const out = out_path orelse return error.Usage;
    if (ws.len == 0 or out.len == 0) return error.Usage;
    if (offline) {
        // The offline fixture is byte-stable; a config would change its provider.
        if (model != null or step_cap != null or task_id != null or dataset != null or instruction_file != null or config != null or timeout_ms != null) return error.Usage;
        return .{
            .workspace = ws,
            .out_path = out,
            .events = events,
            .trim = trim,
        };
    }
    const m = model orelse return error.LiveRefused;
    if (!std.mem.eql(u8, m, approved_pilot_model) and
        !std.mem.eql(u8, m, approved_rerun_model)) return error.LiveRefused;
    const cap = step_cap orelse return error.Usage;
    if (cap == 0 or cap > zygos.task.pilot_step_cap_max) return error.LiveRefused;
    const tid = task_id orelse return error.Usage;
    const ds = dataset orelse return error.Usage;
    if (!std.mem.eql(u8, ds, approved_pilot_dataset)) return error.LiveRefused;
    const instr = instruction_file orelse return error.Usage;
    return .{
        .workspace = ws,
        .out_path = out,
        .events = events,
        .trim = trim,
        .model = m,
        .step_cap = cap,
        .task_id = tid,
        .dataset = ds,
        .instruction_file = instr,
        .config = config,
        .timeout_ms = timeout_ms orelse default_timeout_ms,
    };
}

fn approvedModel(m: []const u8) bool {
    return std.mem.eql(u8, m, approved_pilot_model) or std.mem.eql(u8, m, approved_rerun_model);
}

/// Fail closed over the whole ladder before any provider boots: approved
/// models only, every function a catalog slug with a resolvable key, and
/// `--model` equal to the first attempt so the trial's model_id is the
/// model that answers unless a failover happens.
pub fn validateConfig(
    gpa: std.mem.Allocator,
    zon: *const zygos.task_config.TaskZon,
    catalog: *const zygos.providers_catalog.Catalog,
    env: []const zygos.providers_catalog.EnvPair,
    model: []const u8,
) ConfigError!void {
    const ladder = zon.ladder();
    if (ladder.len == 0 or !std.mem.eql(u8, ladder[0].model, model)) return error.ModelMismatch;
    for (ladder) |a| {
        if (!approvedModel(a.model)) return error.ModelRefused;
        const entry = try entryForFunction(gpa, catalog, a.provider_function) orelse return error.UnknownProviderSlug;
        const key = entry.resolveKey(env) orelse "";
        if (key.len == 0) return error.MissingKey;
    }
}

const providers_prefix = "zygos::providers::";

/// The catalog row registered as `zygos::providers::<slug>`, if any.
fn entryForFunction(
    gpa: std.mem.Allocator,
    catalog: *const zygos.providers_catalog.Catalog,
    function: []const u8,
) error{OutOfMemory}!?*const zygos.providers_catalog.Provider {
    if (!std.mem.startsWith(u8, function, providers_prefix)) return null;
    const want = function[providers_prefix.len..];
    for (catalog.providers) |*entry| {
        const s = try zygos.providers_catalog.slug(gpa, entry.name);
        defer gpa.free(s);
        if (std.mem.eql(u8, s, want)) return entry;
    }
    return null;
}

pub fn parseScore(argv: []const []const u8) ArgError!ScoreArgs {
    var trial_path: ?[]const u8 = null;
    var prices_path: ?[]const u8 = null;
    var help = false;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (isHelp(a)) {
            help = true;
        } else if (std.mem.eql(u8, a, "--trial")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            trial_path = argv[i];
        } else if (std.mem.eql(u8, a, "--prices")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            prices_path = argv[i];
        } else return error.Usage;
    }
    if (help) return error.Help;
    return .{
        .trial_path = trial_path orelse return error.Usage,
        .prices_path = prices_path orelse return error.Usage,
    };
}

pub fn scoreTexts(
    arena: std.mem.Allocator,
    trial_text: []const u8,
    prices_text: []const u8,
) ScoreTextError!zygos.trial.Scored {
    const record = zygos.trial.parse(arena, trial_text) catch |err| return err;
    const prices = zygos.trial.parsePrices(arena, prices_text) catch |err| return err;
    return zygos.trial.score(record, prices);
}

/// Git sha comes from the build. An empty or "unknown" sha refuses the run
/// so a trial cannot be compared across an unidentified binary.
pub fn buildIdentity(gpa: std.mem.Allocator) error{ OutOfMemory, Refused }!zygos.trial.Identity {
    const sha = std.mem.trim(u8, build_info.git_sha, " \t\r\n");
    if (sha.len == 0 or std.mem.eql(u8, sha, "unknown")) return error.Refused;
    return .{
        .git_sha = sha,
        .target_triple = try std.Target.zigTriple(&builtin.target, gpa),
        .optimize = @tagName(builtin.mode),
        .adapter_version = zygos.trial.adapter_version,
    };
}

fn runTask(gpa: std.mem.Allocator, argv: []const []const u8) u8 {
    const parsed = parseRun(argv) catch |err| switch (err) {
        error.Help => {
            printUsage();
            return 0;
        },
        error.Usage => {
            printUsage();
            return 2;
        },
        error.LiveRefused => {
            eprint("task: refusing a live provider run; pass --offline until a dated model and a spend approval exist\n", .{});
            return 2;
        },
    };
    if (parsed.model != null) return runLive(gpa, parsed);
    return runOffline(gpa, parsed);
}

fn runOffline(gpa: std.mem.Allocator, parsed: RunArgs) u8 {
    const identity = buildIdentity(gpa) catch |err| switch (err) {
        error.Refused => {
            eprint("task: refusing to write a trial without a git sha\n", .{});
            return 2;
        },
        error.OutOfMemory => return 1,
    };
    defer gpa.free(identity.target_triple);

    const workspace = canonical(gpa, parsed.workspace) orelse {
        eprint("task: workspace not found: {s}\n", .{parsed.workspace});
        return 2;
    };
    defer gpa.free(workspace);
    const out_path = resolvePath(gpa, parsed.out_path) orelse return 1;
    defer gpa.free(out_path);
    // Same failure as --out: an events path that does not resolve must not
    // be dropped, or the run writes a trial and no events file.
    const events = if (parsed.events) |p| (resolvePath(gpa, p) orelse return 1) else null;
    defer if (events) |p| gpa.free(p);

    const script = zygos.task.offlineScript(gpa) catch return 1;
    defer zygos.task.freeScript(gpa, script);

    const result = zygos.task.run(gpa, .{
        .workspace = workspace,
        .instruction = "Read fixture.txt and list numbers.",
        .task_id = "offline-fixture",
        .dataset = "offline-fixture",
        .model_id = "fixture",
        .variable = if (parsed.trim) "trim-on" else "trim-off",
        .step_cap = zygos.task.offline_step_cap,
        .identity = identity,
        .script = script,
        .trace_path = events,
        .trim = parsed.trim,
        .seed_fixture = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return 1,
        error.Refused, error.Failed => {
            eprint("task: refused ({s})\n", .{@errorName(err)});
            return 2;
        },
    };
    defer result.deinit(gpa);

    fsx.writeAtomic(gpa, out_path, result.trial_json) catch |err| {
        eprint("task: cannot write {s} ({s})\n", .{ out_path, @errorName(err) });
        return if (err == error.OutOfMemory) 1 else 2;
    };
    eprint("task: healthy exit={d} out={s}\n", .{ zygos.task.processExit(result), out_path });
    return zygos.task.processExit(result);
}

fn runScore(gpa: std.mem.Allocator, argv: []const []const u8) u8 {
    const parsed = parseScore(argv) catch |err| switch (err) {
        error.Help => {
            printUsage();
            return 0;
        },
        error.Usage => {
            printUsage();
            return 2;
        },
        error.LiveRefused => return 2,
    };
    const trial_text = fsx.readWholeFile(gpa, parsed.trial_path) orelse {
        eprint("score: cannot read trial {s}\n", .{parsed.trial_path});
        return 2;
    };
    defer gpa.free(trial_text);
    const prices_text = fsx.readWholeFile(gpa, parsed.prices_path) orelse {
        eprint("score: cannot read prices {s}\n", .{parsed.prices_path});
        return 2;
    };
    defer gpa.free(prices_text);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const scored = scoreTexts(arena_state.allocator(), trial_text, prices_text) catch |err| {
        eprint("score: {s}\n", .{@errorName(err)});
        return if (err == error.OutOfMemory) 1 else 2;
    };
    eprint("cents={d} source_lines_read={d} reduction={d}\n", .{
        scored.cents,
        scored.source_lines_read,
        scored.reduction,
    });
    return 0;
}

const LiveBoot = struct {
    io_boot: *zygos.provider_boot.IoBoot,
    catalog: *const zygos.providers_catalog.Catalog,
    env: []const zygos.providers_catalog.EnvPair,
    model: []const u8,
    /// With a config, every catalog row its ladder names boots; without
    /// one, only the row for `model`.
    routes: ?*const zygos.task_config.TaskZon = null,
    booted: ?zygos.provider_boot.CatalogBoot = null,

    fn boot(ctx: *anyopaque, gpa: std.mem.Allocator, actor: *zygos.actor.Actor, registry: *zygos.inproc.Registry) anyerror!void {
        const self: *LiveBoot = @ptrCast(@alignCast(ctx));
        var selected: std.ArrayList(zygos.providers_catalog.Provider) = .empty;
        defer selected.deinit(gpa);
        if (self.routes) |zon| {
            for (zon.ladder()) |a| {
                const entry = try entryForFunction(gpa, self.catalog, a.provider_function) orelse return error.UnknownProviderSlug;
                var seen = false;
                for (selected.items) |already| {
                    if (std.mem.eql(u8, already.name, entry.name)) seen = true;
                }
                if (!seen) try selected.append(gpa, entry.*);
            }
        } else {
            const entry = findEntry(self.catalog, self.model) orelse return error.ModelNotFound;
            try selected.append(gpa, entry.*);
        }
        // The view arena owns nothing. Provider slices stay in the parsed catalog.
        var view = zygos.providers_catalog.Catalog{
            .arena = std.heap.ArenaAllocator.init(gpa),
            .providers = selected.items,
            .clis = &.{},
        };
        defer view.arena.deinit();
        self.booted = try zygos.provider_boot.CatalogBoot.start(gpa, actor, registry, self.io_boot.io(), &view, self.env);
    }

    fn stop(ctx: *anyopaque) void {
        const self: *LiveBoot = @ptrCast(@alignCast(ctx));
        if (self.booted) |*booted| {
            booted.stop();
            self.booted = null;
        }
    }
};

fn runLive(gpa: std.mem.Allocator, parsed: RunArgs) u8 {
    const identity = buildIdentity(gpa) catch |err| switch (err) {
        error.Refused => {
            eprint("task: refusing to write a trial without a git sha\n", .{});
            return 2;
        },
        error.OutOfMemory => return 1,
    };
    defer gpa.free(identity.target_triple);

    const workspace = canonical(gpa, parsed.workspace) orelse {
        eprint("task: workspace not found: {s}\n", .{parsed.workspace});
        return 2;
    };
    defer gpa.free(workspace);
    const out_path = resolvePath(gpa, parsed.out_path) orelse return 1;
    defer gpa.free(out_path);
    const events = if (parsed.events) |p| (resolvePath(gpa, p) orelse return 1) else null;
    defer if (events) |p| gpa.free(p);

    const instruction_path = resolvePath(gpa, parsed.instruction_file.?) orelse return 1;
    defer gpa.free(instruction_path);
    const instruction = fsx.readWholeFile(gpa, instruction_path) orelse {
        eprint("task: cannot read instruction\n", .{});
        return 2;
    };
    defer gpa.free(instruction);
    if (instruction.len == 0) {
        eprint("task: instruction is empty\n", .{});
        return 2;
    }

    const env = envPairs(gpa) catch return 1;
    defer gpa.free(env);
    const catalog_path = zygos.providers_catalog.configPath(gpa, env) catch {
        eprint("task: provider catalog path is missing\n", .{});
        return 2;
    };
    defer gpa.free(catalog_path);
    const toml = fsx.readWholeFile(gpa, catalog_path) orelse {
        eprint("task: cannot read provider catalog\n", .{});
        return 2;
    };
    defer gpa.free(toml);
    var catalog = zygos.providers_catalog.Catalog.parse(gpa, toml, null) catch {
        eprint("task: provider catalog refused\n", .{});
        return 2;
    };
    defer catalog.deinit();

    var routes: ?zygos.task_config.TaskZon = null;
    defer if (routes) |*r| r.deinit();
    if (parsed.config) |config_path| {
        const config_abs = resolvePath(gpa, config_path) orelse return 1;
        defer gpa.free(config_abs);
        const zon_text = fsx.readWholeFileZ(gpa, config_abs) orelse {
            eprint("task: cannot read config {s}\n", .{config_path});
            return 2;
        };
        defer gpa.free(zon_text);
        routes = zygos.task_config.TaskZon.parse(gpa, zon_text) catch |err| switch (err) {
            error.OutOfMemory => return 1,
            else => {
                eprint("task: config refused ({s})\n", .{@errorName(err)});
                return 2;
            },
        };
        validateConfig(gpa, &routes.?, &catalog, env, parsed.model.?) catch |err| switch (err) {
            error.OutOfMemory => return 1,
            else => {
                eprint("task: config refused ({s})\n", .{@errorName(err)});
                return 2;
            },
        };
    }

    // Without a config the static upstream is the model's row. With one it
    // is the ladder's first function; the router then picks each step.
    const upstream = if (routes) |*r|
        (gpa.dupe(u8, r.ladder()[0].provider_function) catch return 1)
    else
        zygos.providers_catalog.functionForModel(gpa, &catalog, parsed.model.?) catch |err| {
            eprint("task: model refused ({s})\n", .{@errorName(err)});
            return 2;
        };
    defer gpa.free(upstream);
    if (routes == null) {
        const entry = findEntry(&catalog, parsed.model.?) orelse {
            eprint("task: model refused (ModelNotFound)\n", .{});
            return 2;
        };
        const key = entry.resolveKey(env) orelse "";
        if (key.len == 0) {
            eprint("task: provider key is missing\n", .{});
            return 2;
        }
    }

    var io_boot = zygos.provider_boot.IoBoot.start(gpa);
    defer io_boot.stop();
    var live = LiveBoot{
        .io_boot = &io_boot,
        .catalog = &catalog,
        .env = env,
        .model = parsed.model.?,
        .routes = if (routes) |*r| r else null,
    };
    const result = zygos.task.run(gpa, .{
        .workspace = workspace,
        .instruction = instruction,
        .task_id = parsed.task_id.?,
        .dataset = parsed.dataset.?,
        .model_id = parsed.model.?,
        .variable = if (parsed.trim) "trim-on" else "trim-off",
        .step_cap = parsed.step_cap.?,
        .identity = identity,
        .script = &.{},
        .trace_path = events,
        .trim = parsed.trim,
        .upstream = upstream,
        .invoke_timeout_ms = @as(i64, @intCast(parsed.timeout_ms)) + invoke_slack_ms,
        .wall_clock_ms = parsed.timeout_ms,
        .routes = if (routes) |*r| r else null,
        .live = .{
            .ctx = @ptrCast(&live),
            .boot = LiveBoot.boot,
            .stop = LiveBoot.stop,
        },
    }) catch |err| switch (err) {
        error.OutOfMemory => return 1,
        error.Refused, error.Failed => {
            eprint("task: refused ({s})\n", .{@errorName(err)});
            return 2;
        },
    };
    defer result.deinit(gpa);

    fsx.writeAtomic(gpa, out_path, result.trial_json) catch |err| {
        eprint("task: cannot write {s} ({s})\n", .{ out_path, @errorName(err) });
        return if (err == error.OutOfMemory) 1 else 2;
    };
    eprint("task: healthy exit={d} out={s}\n", .{ zygos.task.processExit(result), out_path });
    return zygos.task.processExit(result);
}

fn findEntry(catalog: *const zygos.providers_catalog.Catalog, model: []const u8) ?*const zygos.providers_catalog.Provider {
    var found: ?*const zygos.providers_catalog.Provider = null;
    for (catalog.providers) |*entry| {
        if (!std.mem.eql(u8, entry.model, model)) continue;
        if (found != null) return null;
        found = entry;
    }
    return found;
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

fn parseUsize(text: []const u8) ?usize {
    if (text.len == 0) return null;
    return std.fmt.parseInt(usize, text, 10) catch null;
}

fn printUsage() void {
    eprint(
        \\usage: zygos task run --offline --workspace DIR --out trial.json [--events events.jsonl] [--trim on|off]
        \\       zygos task run --model MODEL --workspace DIR --out trial.json --step-cap N --task-id ID --dataset terminal-bench/terminal-bench-2-1 --instruction-file PATH [--events events.jsonl] [--trim on|off] [--config zygos.zon] [--timeout-ms MS]
        \\       zygos task score --trial trial.json --prices prices.txt
        \\
        \\--offline is the scripted provider. Live MODEL: glm-5.3-flash or deepseek/deepseek-v4.1-flash.
        \\--config routes the task step over the file's .default/.routes ladder (approved models, catalog slugs only); other settings refuse.
        \\--timeout-ms is the turn wall clock (1000..3600000, default 540000): no step starts past it and bash calls are bounded by the remainder.
        \\N is 1..32. Exit 0 means the process finished.
        \\
    , .{});
}

fn isHelp(a: []const u8) bool {
    return std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "help");
}

fn canonical(gpa: std.mem.Allocator, path: []const u8) ?[]u8 {
    const z = std.fmt.allocPrintSentinel(gpa, "{s}", .{path}, 0) catch return null;
    defer gpa.free(z);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const resolved = realpath(z.ptr, &buf) orelse return null;
    return gpa.dupe(u8, std.mem.span(resolved)) catch null;
}

/// Absolute paths pass through. Relative paths join the current directory.
/// The final component does not have to exist yet (`--out`, `--events`).
fn resolvePath(gpa: std.mem.Allocator, path: []const u8) ?[]u8 {
    if (path.len > 0 and path[0] == '/') return gpa.dupe(u8, path) catch null;
    const cwd = canonical(gpa, ".") orelse return null;
    defer gpa.free(cwd);
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ cwd, path }) catch null;
}

const testing = std.testing;

test "task run accepts explicitly approved DeepSeek Flash on both trim arms" {
    for ([_][]const u8{ "on", "off" }) |arm| {
        const args = try parseRun(&.{
            "--model",            "deepseek/deepseek-v4.1-flash",
            "--workspace",        "w",
            "--out",              "o",
            "--step-cap",         "24",
            "--task-id",          "t",
            "--dataset",          "terminal-bench/terminal-bench-2-1",
            "--instruction-file", "i",
            "--trim",             arm,
        });
        try testing.expectEqualStrings("deepseek/deepseek-v4.1-flash", args.model.?);
        try testing.expectEqual(@as(usize, 24), args.step_cap.?);
        try testing.expectEqual(std.mem.eql(u8, arm, "on"), args.trim);
    }
}

test "task run accepts --config on a live invocation and refuses it offline" {
    const args = try parseRun(&.{
        "--model",            "deepseek/deepseek-v4.1-flash",
        "--workspace",        "w",
        "--out",              "o",
        "--step-cap",         "24",
        "--task-id",          "t",
        "--dataset",          "terminal-bench/terminal-bench-2-1",
        "--instruction-file", "i",
        "--config",           "arm.zon",
    });
    try testing.expectEqualStrings("arm.zon", args.config.?);
    try testing.expectError(error.Usage, parseRun(&.{ "--offline", "--workspace", "w", "--out", "o", "--config", "arm.zon" }));
    try testing.expectError(error.Usage, parseRun(&.{ "--model", "deepseek/deepseek-v4.1-flash", "--workspace", "w", "--out", "o", "--config" }));
}

const fixture_catalog =
    \\[[providers]]
    \\name = "Deepseek Flash"
    \\type = "openai_compatible"
    \\model = "deepseek/deepseek-v4.1-flash"
    \\endpoint = "https://example.invalid/v1"
    \\key_env = "DEEPSEEK_API_KEY"
    \\
    \\[[providers]]
    \\name = "GLM Flash"
    \\type = "anthropic_compatible"
    \\model = "glm-5.3-flash"
    \\endpoint = "https://example.invalid/anthropic"
    \\key_env = "Z_AI_API_KEY"
    \\
    \\[[providers]]
    \\name = "Big Model"
    \\type = "openai_compatible"
    \\model = "big-model"
    \\endpoint = "https://example.invalid/v1"
    \\key_env = "BIG_API_KEY"
    \\
;

fn expectConfig(zon: [:0]const u8, env: []const zygos.providers_catalog.EnvPair, model: []const u8, expected: ?ConfigError) !void {
    var catalog = try zygos.providers_catalog.Catalog.parse(testing.allocator, fixture_catalog, null);
    defer catalog.deinit();
    var parsed = try zygos.task_config.TaskZon.parse(testing.allocator, zon);
    defer parsed.deinit();
    const got = validateConfig(testing.allocator, &parsed, &catalog, env, model);
    if (expected) |e| try testing.expectError(e, got) else try got;
}

test "validateConfig: approved models on catalog slugs with keys pass; everything else refuses" {
    const both = [_]zygos.providers_catalog.EnvPair{
        .{ .name = "DEEPSEEK_API_KEY", .value = "k1" },
        .{ .name = "Z_AI_API_KEY", .value = "k2" },
        .{ .name = "BIG_API_KEY", .value = "k3" },
    };
    const ladder: [:0]const u8 =
        \\.{ .routes = .{ .{ .step_id = "task", .attempts = .{
        \\    .{ .provider_function = "zygos::providers::deepseek-flash", .model = "deepseek/deepseek-v4.1-flash" },
        \\    .{ .provider_function = "zygos::providers::glm-flash", .model = "glm-5.3-flash" },
        \\} } } }
    ;
    try expectConfig(ladder, &both, "deepseek/deepseek-v4.1-flash", null);
    try expectConfig(ladder, &both, "glm-5.3-flash", error.ModelMismatch);
    try expectConfig(ladder, &.{.{ .name = "DEEPSEEK_API_KEY", .value = "k1" }}, "deepseek/deepseek-v4.1-flash", error.MissingKey);
    try expectConfig(
        \\.{ .default = .{ .{ .provider_function = "zygos::providers::big-model", .model = "big-model" } } }
    , &both, "big-model", error.ModelRefused);
    try expectConfig(
        \\.{ .default = .{ .{ .provider_function = "zygos::providers::nobody", .model = "deepseek/deepseek-v4.1-flash" } } }
    , &both, "deepseek/deepseek-v4.1-flash", error.UnknownProviderSlug);
    try expectConfig(
        \\.{ .default = .{ .{ .provider_function = "zygos::provider::fake::messages", .model = "deepseek/deepseek-v4.1-flash" } } }
    , &both, "deepseek/deepseek-v4.1-flash", error.UnknownProviderSlug);
}

test "task run --timeout-ms is a bounded live-only wall clock with a default" {
    const live = [_][]const u8{
        "--model",            "deepseek/deepseek-v4.1-flash",
        "--workspace",        "w",
        "--out",              "o",
        "--step-cap",         "24",
        "--task-id",          "t",
        "--dataset",          "terminal-bench/terminal-bench-2-1",
        "--instruction-file", "i",
    };
    try testing.expectEqual(default_timeout_ms, (try parseRun(&live)).timeout_ms);
    try testing.expectEqual(@as(u64, 300_000), (try parseRun(&(live ++ [_][]const u8{ "--timeout-ms", "300000" }))).timeout_ms);
    try testing.expectError(error.Usage, parseRun(&(live ++ [_][]const u8{ "--timeout-ms", "999" })));
    try testing.expectError(error.Usage, parseRun(&(live ++ [_][]const u8{ "--timeout-ms", "3600001" })));
    try testing.expectError(error.Usage, parseRun(&(live ++ [_][]const u8{ "--timeout-ms", "soon" })));
    try testing.expectError(error.Usage, parseRun(&.{ "--offline", "--workspace", "w", "--out", "o", "--timeout-ms", "5000" }));
}

test "task run without --offline is refused" {
    try testing.expectError(error.LiveRefused, parseRun(&.{ "--workspace", "w", "--out", "o" }));
    try testing.expectEqual(@as(u8, 2), dispatch(testing.allocator, &.{ "run", "--workspace", "/tmp", "--out", "t.json" }));
}

test "task run accepts only the approved pilot model" {
    const ok = try parseRun(&.{
        "--model",            "glm-5.3-flash",
        "--workspace",        "w",
        "--out",              "o",
        "--step-cap",         "16",
        "--task-id",          "modernize-scientific-stack",
        "--dataset",          "terminal-bench/terminal-bench-2-1",
        "--instruction-file", "instr.txt",
    });
    try testing.expectEqualStrings("glm-5.3-flash", ok.model.?);
    try testing.expectEqual(@as(usize, 16), ok.step_cap.?);
    try testing.expectEqualStrings("modernize-scientific-stack", ok.task_id.?);
    try testing.expectEqualStrings("terminal-bench/terminal-bench-2-1", ok.dataset.?);
    try testing.expectEqualStrings("instr.txt", ok.instruction_file.?);

    // A live argv must not reach dispatch: that path reads the real catalog.
    const other = parseRun(&.{
        "--model",            "glm-5.3",
        "--workspace",        "w",
        "--out",              "o",
        "--step-cap",         "16",
        "--task-id",          "t",
        "--dataset",          "terminal-bench/terminal-bench-2-1",
        "--instruction-file", "i",
    });
    try testing.expectError(error.LiveRefused, other);
    try testing.expectError(error.LiveRefused, parseRun(&.{
        "--model",            "glm5.3-flash",
        "--workspace",        "w",
        "--out",              "o",
        "--step-cap",         "16",
        "--task-id",          "t",
        "--dataset",          "terminal-bench/terminal-bench-2-1",
        "--instruction-file", "i",
    }));
    try testing.expectError(error.Usage, parseRun(&.{
        "--offline",
        "--model",
        "glm-5.3-flash",
        "--workspace",
        "w",
        "--out",
        "o",
    }));
    try testing.expectError(error.Usage, parseRun(&.{
        "--model",     "glm-5.3-flash",
        "--workspace", "w",
        "--out",       "o",
    }));
    try testing.expectError(error.LiveRefused, parseRun(&.{
        "--model",            "glm-5.3-flash",
        "--workspace",        "w",
        "--out",              "o",
        "--step-cap",         "16",
        "--task-id",          "t",
        "--dataset",          "terminal-bench/terminal-bench@4.0.0",
        "--instruction-file", "i",
    }));
    try testing.expectError(error.LiveRefused, parseRun(&.{
        "--model",            "glm-5.3-flash",
        "--workspace",        "w",
        "--out",              "o",
        "--step-cap",         "33",
        "--task-id",          "t",
        "--dataset",          "terminal-bench/terminal-bench-2-1",
        "--instruction-file", "i",
    }));
}

test "task run parses offline trim on and off" {
    try testing.expectError(error.Help, parseRun(&.{"--help"}));
    try testing.expectError(error.Usage, parseRun(&.{"--offline"}));
    const on = try parseRun(&.{ "--offline", "--workspace", "w", "--out", "o", "--events", "e" });
    try testing.expect(on.trim);
    try testing.expectEqualStrings("e", on.events.?);
    const off = try parseRun(&.{ "--offline", "--trim", "off", "--workspace", "w", "--out", "o" });
    try testing.expect(!off.trim);
    try testing.expectEqual(@as(u8, 0), dispatch(testing.allocator, &.{"--help"}));
}

test "embedded build identity pins sha, triple, optimize, and adapter version" {
    // A tarball, a git-less checkout, or a dirty tree embeds "unknown" and
    // buildIdentity refuses. That refusal is the contract; the length check
    // runs only when a real sha was embedded.
    const id = buildIdentity(testing.allocator) catch |err| switch (err) {
        error.Refused => return,
        error.OutOfMemory => return err,
    };
    defer testing.allocator.free(id.target_triple);
    try testing.expect(id.git_sha.len == 40 or id.git_sha.len == 64);
    try testing.expect(id.target_triple.len > 0);
    try testing.expect(id.optimize.len > 0);
    try testing.expectEqualStrings(zygos.trial.adapter_version, id.adapter_version);
}

const fixture_prices = "fixture 300\n# comment ignored\n";

const trim_on_zero =
    \\{"task_id":"t","dataset":"d","model_id":"fixture","variable":"trim-on","step_cap":4,"git_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","target_triple":"aarch64-macos","optimize":"Debug","adapter_version":"0.1.0","source_lines_read":0,"input_tokens":1,"output_tokens":1,"trim":{"calls":2,"filtered":0,"deduped":0,"raw_bytes":10,"sent_bytes":10,"reduction":0}}
;

const trim_on_missing =
    \\{"task_id":"t","dataset":"d","model_id":"fixture","variable":"trim-on","step_cap":4,"git_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","target_triple":"aarch64-macos","optimize":"Debug","adapter_version":"0.1.0","source_lines_read":0,"input_tokens":1,"output_tokens":1}
;

const empty_sha =
    \\{"task_id":"t","dataset":"d","model_id":"fixture","variable":"trim-on","step_cap":4,"git_sha":"","target_triple":"aarch64-macos","optimize":"Debug","adapter_version":"0.1.0","source_lines_read":0,"input_tokens":1,"output_tokens":1,"trim":{"calls":2,"filtered":0,"deduped":0,"raw_bytes":100,"sent_bytes":40,"reduction":60}}
;

const missing_price =
    \\{"task_id":"t","dataset":"d","model_id":"no-such-model","variable":"trim-on","step_cap":4,"git_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","target_triple":"aarch64-macos","optimize":"Debug","adapter_version":"0.1.0","source_lines_read":0,"input_tokens":1,"output_tokens":1,"trim":{"calls":2,"filtered":0,"deduped":0,"raw_bytes":100,"sent_bytes":40,"reduction":60}}
;

const trim_off_zero =
    \\{"task_id":"t","dataset":"d","model_id":"fixture","variable":"trim-off","step_cap":4,"git_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","target_triple":"aarch64-macos","optimize":"Debug","adapter_version":"0.1.0","source_lines_read":0,"input_tokens":1,"output_tokens":1,"trim":{"calls":0,"filtered":0,"deduped":0,"raw_bytes":0,"sent_bytes":0,"reduction":0}}
;

test "score texts refuse trim-on zero, missing evidence, missing identity, and missing price" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectError(error.TrimOnZeroReduction, scoreTexts(arena, trim_on_zero, fixture_prices));
    try testing.expectError(error.TrimEvidenceMissing, scoreTexts(arena, trim_on_missing, fixture_prices));
    try testing.expectError(error.MissingBuildIdentity, scoreTexts(arena, empty_sha, fixture_prices));
    try testing.expectError(error.MissingPrice, scoreTexts(arena, missing_price, fixture_prices));
    const scored = try scoreTexts(arena, trim_off_zero, fixture_prices);
    try testing.expectEqual(@as(u64, 0), scored.reduction);
    try testing.expectEqual(@as(u64, 0), scored.cents);
}
