//! Headless task run (the Harbor-facing entry, without Harbor).
//!
//! One instruction, the existing turn loop, a step cap, and a trial record.
//! This is not a mission: there is no product-owner, no gate, and the
//! process exit means the process stayed up, not that the task succeeded.
//!
//! Bench policy is deny-by-default. The allowlist is bash, read_file, and
//! write_file inside the workspace. Anything else, a missing policy worker,
//! or a malformed verdict denies. Mission policy is a different function
//! and is not changed here.
//!
//! Trim uses the same limits as the mission CLI. The trim-off arm does not
//! register the worker, so the compress seam stays a pass-through — and the
//! trial then records a zero snapshot the scorer accepts only for trim-off.

const std = @import("std");
const json = std.json;
const jsonx = @import("jsonx.zig");
const actor_mod = @import("../kernel/actor.zig");
const inproc = @import("../kernel/inproc.zig");
const sync = @import("../kernel/sync.zig");
const ops = @import("tools_ops.zig");
const tools_mod = @import("tools.zig");
const policy_mod = @import("policy.zig");
const trim_mod = @import("trim.zig");
const turn_mod = @import("turn.zig");
const fake_mod = @import("provider_fake.zig");
const trial_mod = @import("trial.zig");

/// Same bounds the mission CLI passes to TrimWorker.
pub const trim_limits: trim_mod.Limits = .{
    .max_bytes = 65536,
    .max_lines = 400,
    .head_lines = 120,
    .tail_lines = 80,
};

pub const fixture_rel = "fixture.txt";
pub const fixture_body = "alpha\nbeta\ngamma\n";
pub const fixture_lines: u64 = 3;
/// Four scripted provider messages: bash, read, write, end_turn.
pub const offline_step_cap: usize = 4;
/// The scripted provider. A live hook must name some other function.
pub const fake_upstream = "zygos::provider::fake::messages";
/// Phase 8 bound. A larger cap belongs to a later phase.
pub const pilot_step_cap_max: usize = 32;

pub const TaskError = error{ OutOfMemory, Refused, Failed };

fn mapBoot(err: anyerror) TaskError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Refused => error.Refused,
        else => error.Failed,
    };
}

pub const ExtraTool = struct {
    name: []const u8,
    function_id: []const u8,
};

/// Registers the real provider on the task actor. The task module does not
/// open a socket and does not read a catalog; the caller does, and only
/// when this hook is set. `stop` is idempotent.
pub const LiveHooks = struct {
    ctx: *anyopaque,
    boot: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, actor: *actor_mod.Actor, registry: *inproc.Registry) anyerror!void,
    stop: *const fn (ctx: *anyopaque) void,
};

pub const Config = struct {
    workspace: []const u8,
    instruction: []const u8,
    task_id: []const u8,
    dataset: []const u8,
    model_id: []const u8,
    /// "trim-on" or "trim-off".
    variable: []const u8,
    step_cap: usize,
    identity: trial_mod.Identity,
    script: []const []const u8,
    trace_path: ?[]const u8 = null,
    /// Bus name the turn consults. Default is the worker this run starts.
    /// A name with no worker is a policy failure: the turn denies the tool.
    policy_function: []const u8 = "zygos::policy::check",
    /// When false, TrimWorker is not registered. The seam passes bytes through.
    trim: bool = true,
    seed_fixture: bool = false,
    extra_tools: []const ExtraTool = &.{},
    /// Cache-count bridge target. Offline stays on the scripted fake.
    upstream: []const u8 = fake_upstream,
    /// When set, the scripted provider is not started. `script` must be
    /// empty and `upstream` must be the function `boot` registers.
    live: ?LiveHooks = null,
    /// Deadline for `zygos::turns::run`, which spans every step.
    invoke_timeout_ms: i64 = 30_000,
};

pub const RunResult = struct {
    trial_json: []u8,
    turn_json: []u8,
    exit_code: u8,

    pub fn deinit(self: RunResult, gpa: std.mem.Allocator) void {
        gpa.free(self.trial_json);
        gpa.free(self.turn_json);
    }
};

/// A finished run is a healthy process, including when tools were denied.
/// Boot and bus failures never produce a RunResult; the CLI maps those to
/// a non-zero exit. Harbor's verifier, not this code, decides the task.
pub fn processExit(result: RunResult) u8 {
    return result.exit_code;
}

pub fn benchRules() [3]policy_mod.Rule {
    return .{
        .{ .tool = "bash", .verdict = .allow },
        .{ .tool = "read_file", .verdict = .allow },
        .{ .tool = "write_file", .verdict = .allow },
    };
}

pub fn offlineScript(gpa: std.mem.Allocator) error{OutOfMemory}![]const []const u8 {
    // seq 1 500 is over the mission trim line cap (400), so a wired trim
    // worker records reduction > 0. The write proves the allowlist. The
    // read is the only step that counts toward source_lines_read.
    const bash_step = try gpa.dupe(u8,
        \\{"stop_reason":"tool_use","usage":{"input_tokens":11,"output_tokens":2,"cache_read_input_tokens":5},"content":[{"type":"tool_use","id":"t-bash","name":"bash","input":{"command":"seq 1 500"}}]}
    );
    errdefer gpa.free(bash_step);
    const read_step = try gpa.dupe(u8,
        \\{"stop_reason":"tool_use","usage":{"input_tokens":7,"output_tokens":1,"cache_creation_input_tokens":3},"content":[{"type":"tool_use","id":"t-read","name":"read_file","input":{"path":"fixture.txt"}}]}
    );
    errdefer gpa.free(read_step);
    const write_step = try gpa.dupe(u8,
        \\{"stop_reason":"tool_use","usage":{"input_tokens":3,"output_tokens":1},"content":[{"type":"tool_use","id":"t-write","name":"write_file","input":{"path":"note.txt","content":"ok\n"}}]}
    );
    errdefer gpa.free(write_step);
    const end_step = try gpa.dupe(u8,
        \\{"stop_reason":"end_turn","usage":{"input_tokens":4,"output_tokens":2},"content":[{"type":"text","text":"done"}]}
    );
    errdefer gpa.free(end_step);
    const script = try gpa.alloc([]const u8, 4);
    script[0] = bash_step;
    script[1] = read_step;
    script[2] = write_step;
    script[3] = end_step;
    return script;
}

pub fn freeScript(gpa: std.mem.Allocator, script: []const []const u8) void {
    for (script) |line| gpa.free(line);
    gpa.free(script);
}

pub fn run(gpa: std.mem.Allocator, cfg: Config) TaskError!RunResult {
    // "//" and "///" start with '/' and trim to empty, which `resolve` would treat as inside.
    if (cfg.workspace.len < 2 or cfg.workspace[0] != '/') return error.Refused;
    if (std.mem.trimEnd(u8, cfg.workspace, "/").len < 2) return error.Refused;
    if (cfg.step_cap == 0) return error.Refused;
    if (cfg.live != null) {
        if (cfg.script.len != 0) return error.Refused;
        if (cfg.upstream.len == 0 or std.mem.eql(u8, cfg.upstream, fake_upstream)) return error.Refused;
    } else if (cfg.script.len == 0) return error.Refused;
    if (!trial_mod.identityComplete(cfg.identity)) return error.Refused;
    if (cfg.variable.len == 0) return error.Refused;

    if (cfg.seed_fixture) {
        ops.writeFile(gpa, ops.Workspace.init(cfg.workspace), fixture_rel, fixture_body) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Refused,
        };
    }

    var session = try Session.start(gpa, cfg);
    defer session.deinit();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const request = try buildRequest(arena, cfg);

    const res = session.caller.?.call("zygos::turns::run", request) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Shutdown => return error.Failed,
    };
    const turn_json = switch (res) {
        .ok => |payload| payload,
        .err => |code| {
            gpa.free(code);
            return error.Failed;
        },
    };
    errdefer gpa.free(turn_json);

    const snap = if (cfg.trim) try readTrim(gpa, session.caller.?) else zeroSnap();
    const lines = session.tools.?.linesRead();
    const usage = session.bridge.?.totals();

    const record: trial_mod.Trial = .{
        .task_id = cfg.task_id,
        .dataset = cfg.dataset,
        .model_id = cfg.model_id,
        .variable = cfg.variable,
        .step_cap = @intCast(cfg.step_cap),
        .git_sha = cfg.identity.git_sha,
        .target_triple = cfg.identity.target_triple,
        .optimize = cfg.identity.optimize,
        .adapter_version = cfg.identity.adapter_version,
        .source_lines_read = lines,
        .input_tokens = usage.input_tokens,
        .output_tokens = usage.output_tokens,
        .cache_read_tokens = usage.cache_read,
        .cache_creation_tokens = usage.cache_creation,
        .trim = snap,
    };
    const trial_json = trial_mod.write(gpa, record) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };

    return .{
        .trial_json = trial_json,
        .turn_json = turn_json,
        .exit_code = 0,
    };
}

fn zeroSnap() ?trial_mod.TrimSnap {
    return .{
        .calls = 0,
        .filtered = 0,
        .deduped = 0,
        .raw_bytes = 0,
        .sent_bytes = 0,
        .reduction = 0,
    };
}

/// Stats live on the trim worker. A bus or parse failure leaves the snapshot
/// null so the scorer reports missing evidence instead of a fake zero.
fn readTrim(gpa: std.mem.Allocator, caller: *inproc.Worker) TaskError!?trial_mod.TrimSnap {
    const res = caller.call("zygos::output::stats", "{}") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Shutdown => return null,
    };
    defer res.deinit(gpa);
    const payload = switch (res) {
        .ok => |p| p,
        .err => return null,
    };
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = json.parseFromSliceLeaky(json.Value, arena, payload, .{}) catch return null;
    if (root != .object) return null;
    const calls = jsonx.uintField(root.object, "calls") orelse return null;
    const filtered = jsonx.uintField(root.object, "filtered") orelse return null;
    const deduped = jsonx.uintField(root.object, "deduped") orelse return null;
    const raw_bytes = jsonx.uintField(root.object, "raw_bytes") orelse return null;
    const sent_bytes = jsonx.uintField(root.object, "sent_bytes") orelse return null;
    return .{
        .calls = calls,
        .filtered = filtered,
        .deduped = deduped,
        .raw_bytes = raw_bytes,
        .sent_bytes = sent_bytes,
        .reduction = trial_mod.reductionOf(raw_bytes, sent_bytes),
    };
}

const Session = struct {
    gpa: std.mem.Allocator,
    registry: inproc.Registry,
    actor: actor_mod.Actor,
    kernel: std.Thread,
    tools: ?*tools_mod.ToolsWorker = null,
    policy: ?*policy_mod.PolicyWorker = null,
    trim: ?*trim_mod.TrimWorker = null,
    fake: ?*fake_mod.FakeProvider = null,
    live_ctx: ?*anyopaque = null,
    live_stop: ?*const fn (ctx: *anyopaque) void = null,
    bridge: ?*Bridge = null,
    turns: ?*turn_mod.TurnOrchestrator = null,
    caller: ?*inproc.Worker = null,

    fn start(gpa: std.mem.Allocator, cfg: Config) TaskError!*Session {
        const self = try gpa.create(Session);
        self.* = .{
            .gpa = gpa,
            .registry = inproc.Registry.init(gpa, null),
            .actor = undefined,
            .kernel = undefined,
        };
        self.actor = actor_mod.Actor.init(gpa, .{
            .invoke_timeout_ms = cfg.invoke_timeout_ms,
        }, self.registry.outbound()) catch |err| switch (err) {
            error.OutOfMemory => {
                self.registry.deinit();
                gpa.destroy(self);
                return error.OutOfMemory;
            },
        };
        self.kernel = std.Thread.spawn(.{}, actor_mod.Actor.run, .{&self.actor}) catch |err| {
            self.actor.deinit();
            self.registry.deinit();
            gpa.destroy(self);
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.Failed,
            };
        };
        errdefer self.deinit();

        self.tools = tools_mod.ToolsWorker.start(gpa, &self.actor, &self.registry, cfg.workspace) catch |err| {
            return mapBoot(err);
        };
        const rules = benchRules();
        self.policy = policy_mod.PolicyWorker.start(gpa, &self.actor, &self.registry, &rules) catch |err| {
            return mapBoot(err);
        };
        if (cfg.trim) {
            self.trim = trim_mod.TrimWorker.start(gpa, &self.actor, &self.registry, trim_limits, null) catch |err| {
                return mapBoot(err);
            };
        }
        if (cfg.live) |hooks| {
            hooks.boot(hooks.ctx, gpa, &self.actor, &self.registry) catch |err| return mapBoot(err);
            self.live_ctx = hooks.ctx;
            self.live_stop = hooks.stop;
        } else {
            self.fake = fake_mod.FakeProvider.start(gpa, &self.actor, &self.registry, cfg.script) catch |err| {
                return mapBoot(err);
            };
        }
        self.bridge = Bridge.start(gpa, &self.actor, &self.registry, cfg.upstream) catch |err| return mapBoot(err);
        self.turns = turn_mod.TurnOrchestrator.start(gpa, &self.actor, &self.registry) catch |err| {
            return mapBoot(err);
        };
        self.caller = inproc.Worker.spawn(gpa, &self.actor, &self.registry, "task-cli") catch |err| {
            return mapBoot(err);
        };
        return self;
    }

    fn deinit(self: *Session) void {
        const gpa = self.gpa;
        if (self.caller) |w| w.stop();
        if (self.turns) |w| w.stop();
        if (self.bridge) |w| w.stop();
        if (self.live_stop) |stop| stop(self.live_ctx.?);
        if (self.fake) |w| w.stop();
        if (self.trim) |w| w.stop();
        if (self.policy) |w| w.stop();
        if (self.tools) |w| w.stop();
        self.actor.post(.shutdown);
        self.kernel.join();
        self.actor.deinit();
        self.registry.deinit();
        gpa.destroy(self);
    }
};

fn buildRequest(arena: std.mem.Allocator, cfg: Config) TaskError![]u8 {
    const tools_json = try toolsJson(arena, cfg.extra_tools);
    const trace = if (cfg.trace_path) |p|
        try std.fmt.allocPrint(arena, ",\"trace_path\":{f}", .{json.fmt(p, .{})})
    else
        "";
    return std.fmt.allocPrint(arena,
        \\{{"model":{f},"system":"Headless Zygos task. Tool denials are results, not a crashed process.","messages":[{{"role":"user","content":{f}}}],"max_steps":{d},"provider_function":"zygos::provider::task::messages","policy_function":{f},"turn_id":"task","tools":{s}{s}}}
    , .{
        json.fmt(cfg.model_id, .{}),
        json.fmt(cfg.instruction, .{}),
        cfg.step_cap,
        json.fmt(cfg.policy_function, .{}),
        tools_json,
        trace,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
}

fn toolsJson(arena: std.mem.Allocator, extras: []const ExtraTool) TaskError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "[{\"name\":\"bash\",\"function_id\":\"zygos::tools::bash\"},{\"name\":\"read_file\",\"function_id\":\"zygos::tools::read_file\"},{\"name\":\"write_file\",\"function_id\":\"zygos::tools::write_file\"}");
    for (extras) |extra| {
        try out.print(arena, ",{{\"name\":{f},\"function_id\":{f}}}", .{
            json.fmt(extra.name, .{}),
            json.fmt(extra.function_id, .{}),
        });
    }
    try out.append(arena, ']');
    return out.toOwnedSlice(arena);
}

const UsageTotals = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_read: ?u64 = null,
    cache_creation: ?u64 = null,
};

/// Sits in front of the scripted provider and copies cache counts off the
/// provider payload before the turn driver writes the usage trace line.
/// The trace line is not modified.
const Bridge = struct {
    gpa: std.mem.Allocator,
    worker: *inproc.Worker,
    upstream: []const u8,
    mutex: sync.Mutex = .{},
    totals_value: UsageTotals = .{},

    fn start(
        gpa: std.mem.Allocator,
        actor: *actor_mod.Actor,
        registry: *inproc.Registry,
        upstream: []const u8,
    ) TaskError!*Bridge {
        const self = try gpa.create(Bridge);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .worker = undefined,
            .upstream = upstream,
        };
        errdefer self.mutex.deinit();
        self.worker = inproc.Worker.spawn(gpa, actor, registry, "task-provider") catch |err| return mapBoot(err);
        errdefer self.worker.stop();
        self.worker.registerFunction("zygos::provider::task::messages", self, &handler) catch |err| return mapBoot(err);
        return self;
    }

    fn stop(self: *Bridge) void {
        self.worker.stop();
        self.mutex.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    fn totals(self: *Bridge) UsageTotals {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.totals_value;
    }

    fn handler(ctx: ?*anyopaque, arena: std.mem.Allocator, request_json: []const u8) error{ Failed, OutOfMemory }![]const u8 {
        const self: *Bridge = @ptrCast(@alignCast(ctx.?));
        const res = self.worker.call(self.upstream, request_json) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Shutdown => return error.Failed,
        };
        defer res.deinit(self.gpa);
        switch (res) {
            .err => return error.Failed,
            .ok => |payload| {
                self.absorb(payload);
                return try arena.dupe(u8, payload);
            },
        }
    }

    fn absorb(self: *Bridge, payload: []const u8) void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const root = json.parseFromSliceLeaky(json.Value, arena, payload, .{}) catch return;
        if (root != .object) return;
        const usage_val = root.object.get("usage") orelse return;
        if (usage_val != .object) return;
        const usage = usage_val.object;

        self.mutex.lock();
        defer self.mutex.unlock();
        if (jsonx.uintField(usage, "input_tokens")) |n| self.totals_value.input_tokens += n;
        if (jsonx.uintField(usage, "output_tokens")) |n| self.totals_value.output_tokens += n;
        if (firstUint(usage, "cache_read_input_tokens", "cache_read_tokens")) |n| {
            self.totals_value.cache_read = (self.totals_value.cache_read orelse 0) + n;
        }
        if (firstUint(usage, "cache_creation_input_tokens", "cache_creation_tokens")) |n| {
            self.totals_value.cache_creation = (self.totals_value.cache_creation orelse 0) + n;
        }
    }
};

fn firstUint(obj: json.ObjectMap, primary: []const u8, fallback: []const u8) ?u64 {
    return jsonx.uintField(obj, primary) orelse jsonx.uintField(obj, fallback);
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

extern "c" fn realpath(path: [*:0]const u8, resolved: [*]u8) ?[*:0]u8;

const TestDir = struct {
    tmp: std.testing.TmpDir,
    root_buf: [std.fs.max_path_bytes]u8 = undefined,

    fn init() !TestDir {
        return .{ .tmp = std.testing.tmpDir(.{}) };
    }

    fn root(self: *TestDir) ![]const u8 {
        var rel_buf: [std.fs.max_path_bytes]u8 = undefined;
        const rel = try std.fmt.bufPrintZ(&rel_buf, ".zig-cache/tmp/{s}", .{self.tmp.sub_path});
        const resolved = realpath(rel, &self.root_buf) orelse return error.RealpathFailed;
        return std.mem.span(resolved);
    }

    fn deinit(self: *TestDir) void {
        self.tmp.cleanup();
    }
};

fn testIdentity() trial_mod.Identity {
    return .{
        .git_sha = "0123456789abcdef0123456789abcdef01234567",
        .target_triple = "aarch64-macos",
        .optimize = "Debug",
        .adapter_version = trial_mod.adapter_version,
    };
}

fn offlineConfig(root: []const u8, trace_path: ?[]const u8, script: []const []const u8) Config {
    return .{
        .workspace = root,
        .instruction = "Read fixture.txt and list numbers.",
        .task_id = "offline-fixture",
        .dataset = "offline-fixture",
        .model_id = "fixture",
        .variable = "trim-on",
        .step_cap = offline_step_cap,
        .identity = testIdentity(),
        .script = script,
        .trace_path = trace_path,
        .trim = true,
        .seed_fixture = true,
    };
}

const fsx_mod = @import("fsx.zig");

const fixture_price = trial_mod.Price{ .model_id = "fixture", .cents_per_mtok = 300 };

const end_turn_line =
    \\{"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1},"content":[{"type":"text","text":"done"}]}
;

fn ownedLines(gpa: std.mem.Allocator, lines: []const []const u8) error{OutOfMemory}![]const []const u8 {
    const out = try gpa.alloc([]const u8, lines.len);
    var n: usize = 0;
    errdefer {
        for (out[0..n]) |line| gpa.free(line);
        gpa.free(out);
    }
    for (lines) |line| {
        out[n] = try gpa.dupe(u8, line);
        n += 1;
    }
    return out;
}

fn parseTrial(arena: std.mem.Allocator, bytes: []const u8) !trial_mod.Trial {
    return trial_mod.parse(arena, bytes);
}

test "offline task records trim reduction, build identity, and read-file lines" {
    var dir = try TestDir.init();
    defer dir.deinit();
    const root = try dir.root();
    const events = try std.fmt.allocPrint(testing.allocator, "{s}/events.jsonl", .{root});
    defer testing.allocator.free(events);

    const script = try offlineScript(testing.allocator);
    defer freeScript(testing.allocator, script);
    const result = try run(testing.allocator, offlineConfig(root, events, script));
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), processExit(result));
    try testing.expect(std.mem.indexOf(u8, result.turn_json, "\"stop\":\"end_turn\"") != null);
    try testing.expect(std.mem.indexOf(u8, result.turn_json, "policy_denied") == null);
    try testing.expect(std.mem.indexOf(u8, result.turn_json, "unknown tool") == null);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const trial = try parseTrial(arena_state.allocator(), result.trial_json);
    const id = testIdentity();
    try testing.expectEqualStrings(id.git_sha, trial.git_sha);
    try testing.expectEqualStrings(id.target_triple, trial.target_triple);
    try testing.expectEqualStrings(id.optimize, trial.optimize);
    try testing.expectEqualStrings(id.adapter_version, trial.adapter_version);
    try testing.expectEqualStrings("trim-on", trial.variable);
    // Bash printed 500 lines. Only the three-line read_file counts.
    try testing.expectEqual(@as(u64, fixture_lines), trial.source_lines_read);
    try testing.expectEqual(@as(u64, 25), trial.input_tokens);
    try testing.expectEqual(@as(u64, 6), trial.output_tokens);
    try testing.expectEqual(@as(?u64, 5), trial.cache_read_tokens);
    try testing.expectEqual(@as(?u64, 3), trial.cache_creation_tokens);
    const snap = trial.trim orelse return error.TrimEvidenceMissing;
    try testing.expect(snap.calls > 0);
    try testing.expect(snap.reduction > 0);
    try testing.expect(snap.sent_bytes < snap.raw_bytes);

    const scored = try trial_mod.score(trial, &.{fixture_price});
    try testing.expect(scored.reduction > 0);
    try testing.expectEqual(@as(u64, fixture_lines), scored.source_lines_read);

    const note = try std.fmt.allocPrint(testing.allocator, "{s}/note.txt", .{root});
    defer testing.allocator.free(note);
    const written = fsx_mod.readWholeFile(testing.allocator, note) orelse return error.WriteNotAllowed;
    defer testing.allocator.free(written);
    try testing.expectEqualStrings("ok\n", written);

    const log_bytes = fsx_mod.readWholeFile(testing.allocator, events) orelse return error.NoTrace;
    defer testing.allocator.free(log_bytes);
    try testing.expect(std.mem.indexOf(u8, log_bytes, "\"event\":\"usage\"") != null);
    try testing.expect(std.mem.indexOf(u8, log_bytes, "input_tokens") != null);
    try testing.expect(std.mem.indexOf(u8, log_bytes, "cache") == null);
}

test "unknown tool is denied and the process stays healthy" {
    var dir = try TestDir.init();
    defer dir.deinit();
    const root = try dir.root();
    const script = try ownedLines(testing.allocator, &.{
        \\{"stop_reason":"tool_use","usage":{"input_tokens":1,"output_tokens":1},"content":[{"type":"tool_use","id":"t-g","name":"grep","input":{"pattern":"alpha"}}]}
        ,
        end_turn_line,
    });
    defer freeScript(testing.allocator, script);
    var cfg = offlineConfig(root, null, script);
    cfg.seed_fixture = false;
    cfg.step_cap = 3;
    const result = try run(testing.allocator, cfg);
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), processExit(result));
    try testing.expect(std.mem.indexOf(u8, result.turn_json, "unknown tool") != null);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const trial = try parseTrial(arena_state.allocator(), result.trial_json);
    try testing.expectEqual(@as(u64, 0), trial.source_lines_read);
}

test "a tool outside the allowlist is policy-denied and the process stays healthy" {
    var dir = try TestDir.init();
    defer dir.deinit();
    const root = try dir.root();
    const script = try ownedLines(testing.allocator, &.{
        \\{"stop_reason":"tool_use","usage":{"input_tokens":1,"output_tokens":1},"content":[{"type":"tool_use","id":"t-g","name":"grep","input":{"pattern":"alpha"}}]}
        ,
        end_turn_line,
    });
    defer freeScript(testing.allocator, script);
    const extras = [_]ExtraTool{.{ .name = "grep", .function_id = "zygos::tools::bash" }};
    var cfg = offlineConfig(root, null, script);
    cfg.seed_fixture = false;
    cfg.step_cap = 3;
    cfg.extra_tools = &extras;
    const result = try run(testing.allocator, cfg);
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), processExit(result));
    try testing.expect(std.mem.indexOf(u8, result.turn_json, "policy_denied") != null);
    try testing.expect(std.mem.indexOf(u8, result.turn_json, "unknown tool") == null);
}

test "a workspace path escape is denied and does not count source lines" {
    var dir = try TestDir.init();
    defer dir.deinit();
    const root = try dir.root();
    const script = try ownedLines(testing.allocator, &.{
        \\{"stop_reason":"tool_use","usage":{"input_tokens":1,"output_tokens":1},"content":[{"type":"tool_use","id":"t-e","name":"read_file","input":{"path":"../../etc/passwd"}}]}
        ,
        end_turn_line,
    });
    defer freeScript(testing.allocator, script);
    var cfg = offlineConfig(root, null, script);
    cfg.seed_fixture = false;
    cfg.step_cap = 3;
    const result = try run(testing.allocator, cfg);
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), processExit(result));
    try testing.expect(std.mem.indexOf(u8, result.turn_json, "PathEscapesWorkspace") != null);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const trial = try parseTrial(arena_state.allocator(), result.trial_json);
    try testing.expectEqual(@as(u64, 0), trial.source_lines_read);
}

test "a missing policy worker denies the tool and the process stays healthy" {
    var dir = try TestDir.init();
    defer dir.deinit();
    const root = try dir.root();
    const script = try ownedLines(testing.allocator, &.{
        \\{"stop_reason":"tool_use","usage":{"input_tokens":1,"output_tokens":1},"content":[{"type":"tool_use","id":"t-b","name":"bash","input":{"command":"echo hi"}}]}
        ,
        end_turn_line,
    });
    defer freeScript(testing.allocator, script);
    var cfg = offlineConfig(root, null, script);
    cfg.seed_fixture = false;
    cfg.step_cap = 3;
    cfg.policy_function = "zygos::policy::missing";
    const result = try run(testing.allocator, cfg);
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), processExit(result));
    try testing.expect(std.mem.indexOf(u8, result.turn_json, "policy_denied") != null);
}

test "trim-off records a zero snapshot the scorer accepts" {
    var dir = try TestDir.init();
    defer dir.deinit();
    const root = try dir.root();
    const script = try ownedLines(testing.allocator, &.{end_turn_line});
    defer freeScript(testing.allocator, script);
    var cfg = offlineConfig(root, null, script);
    cfg.trim = false;
    cfg.variable = "trim-off";
    cfg.seed_fixture = false;
    cfg.step_cap = 2;
    const result = try run(testing.allocator, cfg);
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), processExit(result));

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const trial = try parseTrial(arena_state.allocator(), result.trial_json);
    const snap = trial.trim orelse return error.TrimEvidenceMissing;
    try testing.expectEqual(@as(u64, 0), snap.calls);
    try testing.expectEqual(@as(u64, 0), snap.reduction);
    const scored = try trial_mod.score(trial, &.{fixture_price});
    try testing.expectEqual(@as(u64, 0), scored.reduction);
}

test "a non-absolute workspace or an empty build identity is refused" {
    const script = [_][]const u8{end_turn_line};
    try testing.expectError(error.Refused, run(testing.allocator, offlineConfig("relative", null, &script)));
    try testing.expectError(error.Refused, run(testing.allocator, offlineConfig("", null, &script)));
    try testing.expectError(error.Refused, run(testing.allocator, offlineConfig("//", null, &script)));
    try testing.expectError(error.Refused, run(testing.allocator, offlineConfig("///", null, &script)));
    var cfg = offlineConfig("/workspace", null, &script);
    cfg.identity.git_sha = "";
    cfg.seed_fixture = false;
    try testing.expectError(error.Refused, run(testing.allocator, cfg));
}

test "eval runner stays outside zig build test and pins the dataset" {
    const build_text = fsx_mod.readWholeFile(testing.allocator, "build.zig") orelse return error.NoBuildZig;
    defer testing.allocator.free(build_text);
    try testing.expect(std.mem.indexOf(u8, build_text, "eval/run.sh") == null);

    const runner = fsx_mod.readWholeFile(testing.allocator, "eval/run.sh") orelse return error.NoRunner;
    defer testing.allocator.free(runner);
    try testing.expect(std.mem.indexOf(u8, runner, "terminal-bench/terminal-bench-2-1") != null);
    // One adapter version: the shell reads `trial.adapter_version`. It does not echo a second copy.
    try testing.expect(std.mem.indexOf(u8, runner, "pub const adapter_version") != null);
    try testing.expect(std.mem.indexOf(u8, runner, "$script_dir/image-platforms.json") != null);
    try testing.expect(std.mem.indexOf(u8, runner, "inventory_file=\"eval/image-platforms.json\"") == null);
    try testing.expect(std.mem.indexOf(u8, runner, "*ready*") == null);
    try testing.expect(std.mem.indexOf(u8, runner, "zygos task run --offline") != null);
    try testing.expect(std.mem.indexOf(u8, runner, "terminal-bench/terminal-bench@4.0.0") != null);
    try testing.expect(std.mem.indexOf(u8, runner, "refusing a live Harbor run") != null);
    try testing.expect(std.mem.indexOf(u8, runner, "glm-5.3-flash") != null);
    try testing.expect(std.mem.indexOf(u8, runner, "DOCKER_DEFAULT_PLATFORM=linux/amd64") != null);
    try testing.expect(std.mem.indexOf(u8, runner, "-k 1") != null);
    try testing.expect(std.mem.indexOf(u8, runner, "--upload") == null);

    const trial_src = fsx_mod.readWholeFile(testing.allocator, "src/worker/trial.zig") orelse return error.NoTrial;
    defer testing.allocator.free(trial_src);
    const decl = "pub const adapter_version = \"" ++ trial_mod.adapter_version ++ "\";";
    try testing.expect(std.mem.indexOf(u8, trial_src, decl) != null);

    const agent = fsx_mod.readWholeFile(testing.allocator, "eval/harbor/zygos_agent.py") orelse return error.NoAgent;
    defer testing.allocator.free(agent);
    try testing.expect(std.mem.indexOf(u8, agent, "src/worker/trial.zig") != null);
    try testing.expect(std.mem.indexOf(u8, agent, "ADAPTER_VERSION = \"0.1.0\"") == null);

    const inventory = fsx_mod.readWholeFile(testing.allocator, "eval/image-platforms.json") orelse return error.NoInventory;
    defer testing.allocator.free(inventory);
    // The triple is the string std.Target.zigTriple stamps for -Dtarget=x86_64-linux-gnu.
    // Every Terminal-Bench 2.1 environment image publishes linux/amd64.
    try testing.expect(std.mem.indexOf(u8, inventory, "\"status\": \"ready\"") != null);
    try testing.expect(std.mem.indexOf(u8, inventory, "\"chosen_platform\": \"linux/amd64\"") != null);
    try testing.expect(std.mem.indexOf(u8, inventory, "\"chosen_triple\": \"x86_64-linux.5.10...6.19-gnu.2.31\"") != null);
    try testing.expect(std.mem.indexOf(u8, inventory, "\"image_count\": 89") != null);
    try testing.expect(std.mem.indexOf(u8, inventory, "\"chosen_triple\": null") == null);
}

test "bench rules allow bash, read_file, and write_file and deny everything else" {
    const gpa = testing.allocator;
    var registry = inproc.Registry.init(gpa, null);
    defer registry.deinit();
    var act = try actor_mod.Actor.init(gpa, .{}, registry.outbound());
    defer act.deinit();
    const kernel = try std.Thread.spawn(.{}, actor_mod.Actor.run, .{&act});
    defer {
        act.post(.shutdown);
        kernel.join();
    }
    const rules = benchRules();
    const pw = try policy_mod.PolicyWorker.start(gpa, &act, &registry, &rules);
    defer pw.stop();
    const caller = try inproc.Worker.spawn(gpa, &act, &registry, "bench-rules");
    defer caller.stop();

    const cases = [_]struct { tool: []const u8, function_id: []const u8, verdict: []const u8 }{
        .{ .tool = "bash", .function_id = "zygos::tools::bash", .verdict = "allow" },
        .{ .tool = "read_file", .function_id = "zygos::tools::read_file", .verdict = "allow" },
        .{ .tool = "write_file", .function_id = "zygos::tools::write_file", .verdict = "allow" },
        .{ .tool = "grep", .function_id = "zygos::tools::bash", .verdict = "deny" },
        .{ .tool = "web_fetch", .function_id = "zygos::tools::web_fetch", .verdict = "deny" },
        .{ .tool = "", .function_id = "zygos::tools::bash", .verdict = "deny" },
    };
    for (cases) |case| {
        const req = try std.fmt.allocPrint(gpa, "{{\"tool\":{f},\"function_id\":{f},\"input\":{{}}}}", .{
            json.fmt(case.tool, .{}),
            json.fmt(case.function_id, .{}),
        });
        defer gpa.free(req);
        const res = try caller.call("zygos::policy::check", req);
        defer res.deinit(gpa);
        try testing.expect(res == .ok);
        try testing.expect(std.mem.indexOf(u8, res.ok, case.verdict) != null);
    }
}

const stub_end_turn = "{\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":4,\"output_tokens\":2,\"cache_read_input_tokens\":9},\"content\":[{\"type\":\"text\",\"text\":\"done\"}]}";

const StubProvider = struct {
    worker: ?*inproc.Worker = null,

    fn boot(ctx: *anyopaque, gpa: std.mem.Allocator, actor: *actor_mod.Actor, registry: *inproc.Registry) anyerror!void {
        const self: *StubProvider = @ptrCast(@alignCast(ctx));
        const worker = try inproc.Worker.spawn(gpa, actor, registry, "stub-provider");
        errdefer worker.stop();
        try worker.registerFunction("zygos::providers::stub", self, &handler);
        self.worker = worker;
    }

    fn stop(ctx: *anyopaque) void {
        const self: *StubProvider = @ptrCast(@alignCast(ctx));
        if (self.worker) |w| {
            self.worker = null;
            w.stop();
        }
    }

    fn handler(_: ?*anyopaque, arena: std.mem.Allocator, _: []const u8) error{ Failed, OutOfMemory }![]const u8 {
        return arena.dupe(u8, stub_end_turn);
    }
};

test "a live hook is forwarded and an empty script without one is refused" {
    var dir = try TestDir.init();
    defer dir.deinit();
    const root = try dir.root();
    try testing.expectError(error.Refused, run(testing.allocator, .{
        .workspace = root,
        .instruction = "x",
        .task_id = "t",
        .dataset = "d",
        .model_id = "m",
        .variable = "trim-off",
        .step_cap = 1,
        .identity = testIdentity(),
        .script = &.{},
        .trim = false,
    }));

    var stub = StubProvider{};
    const result = try run(testing.allocator, .{
        .workspace = root,
        .instruction = "Say done.",
        .task_id = "pilot-stub",
        .dataset = "terminal-bench/terminal-bench-2-1",
        .model_id = "glm-5.3-flash",
        .variable = "trim-off",
        .step_cap = 1,
        .identity = testIdentity(),
        .script = &.{},
        .trim = false,
        .upstream = "zygos::providers::stub",
        .live = .{
            .ctx = @ptrCast(&stub),
            .boot = StubProvider.boot,
            .stop = StubProvider.stop,
        },
    });
    defer result.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, result.trial_json, "\"model_id\":\"glm-5.3-flash\"") != null);
    try testing.expect(std.mem.indexOf(u8, result.trial_json, "\"input_tokens\":4") != null);
    try testing.expect(std.mem.indexOf(u8, result.trial_json, "\"cache_read_tokens\":9") != null);
}
