//! `zygos task run` and `zygos task score`.
//!
//! `run` is the headless Harbor entry. It is not a mission: no product-owner
//! gate, and exit 0 means the process finished and wrote a trial, including
//! when a tool was denied. Exit 2 is a refusal. A live provider is refused
//! until a dated model id and a separate spend approval exist.
//!
//! The git sha, target triple, optimize level, and adapter version are pinned
//! into every trial. Cache counts stay on that trial. The trace usage line
//! is not this command's to extend.

const std = @import("std");
const builtin = @import("builtin");
const zygos = @import("zygos");
const build_info = @import("build_info");

const fsx = zygos.fsx;
const eprint = std.debug.print;

extern "c" fn realpath(path: [*:0]const u8, resolved: [*]u8) ?[*:0]u8;

pub const ArgError = error{ Usage, Help, LiveRefused };

pub const RunArgs = struct {
    workspace: []const u8,
    out_path: []const u8,
    events: ?[]const u8 = null,
    trim: bool = true,
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
    if (std.mem.eql(u8, argv[0], "run")) return runOffline(gpa, argv[1..]);
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
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (isHelp(a)) {
            help = true;
        } else if (std.mem.eql(u8, a, "--offline")) {
            offline = true;
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
        } else return error.Usage;
    }
    if (help) return error.Help;
    if (!offline) return error.LiveRefused;
    const ws = workspace orelse return error.Usage;
    const out = out_path orelse return error.Usage;
    if (ws.len == 0 or out.len == 0) return error.Usage;
    return .{ .workspace = ws, .out_path = out, .events = events, .trim = trim };
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

fn runOffline(gpa: std.mem.Allocator, argv: []const []const u8) u8 {
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
    const events = if (parsed.events) |p| resolvePath(gpa, p) else null;
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

fn printUsage() void {
    eprint(
        \\usage: zygos task run --offline --workspace DIR --out trial.json [--events events.jsonl] [--trim on|off]
        \\       zygos task score --trial trial.json --prices prices.txt
        \\
        \\run refuses a live provider. Pass --offline. Exit 0 means the process finished.
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

test "task run without --offline is refused" {
    try testing.expectError(error.LiveRefused, parseRun(&.{ "--workspace", "w", "--out", "o" }));
    try testing.expectEqual(@as(u8, 2), dispatch(testing.allocator, &.{ "run", "--workspace", "/tmp", "--out", "t.json" }));
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
    const id = try buildIdentity(testing.allocator);
    defer testing.allocator.free(id.target_triple);
    try testing.expectEqual(@as(usize, 40), id.git_sha.len);
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
