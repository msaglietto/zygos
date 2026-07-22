//! Mission-boot decision layer (M4.7 roadmap: "Extract mission_boot from the
//! CLI"). Pure argv→config rules `zygos mission` applies before any kernel
//! boots: arg parsing, timeout ceilings, search-backend resolution (key_env
//! resolved into key at boot — the Y5 brave defect), the run-stamp start
//! refusal, policy seeding, and the vault-checkpoint verdict. No IO here —
//! the CLI supplies env/argv/filesystem facts and wires the results.

const std = @import("std");
const providers = @import("../config/providers.zig");
const web_tools = @import("../net/web_tools.zig");
const policy = @import("policy.zig");
const inproc = @import("../kernel/inproc.zig");

pub const EnvPair = providers.EnvPair;

// ---------------------------------------------------------------------------
// env helpers
// ---------------------------------------------------------------------------

pub fn getEnv(env: []const EnvPair, name: []const u8) ?[]const u8 {
    for (env) |p| if (std.mem.eql(u8, p.name, name)) return p.value;
    return null;
}

/// Malformed values keep the default (boot must not die on a typo'd env var).
pub fn envInt(env: []const EnvPair, name: []const u8, default: i64) i64 {
    const raw = getEnv(env, name) orelse return default;
    return std.fmt.parseInt(i64, raw, 10) catch default;
}

// ---------------------------------------------------------------------------
// argv → Args
// ---------------------------------------------------------------------------

pub const Verb = enum { start, trace, attach };

/// `resume` normalizes to `.start` + `resume_flag`; for `.trace`/`.attach`,
/// `brief_path` holds the target (planning dir, or events.jsonl for trace).
pub const Args = struct {
    verb: Verb,
    brief_path: []const u8,
    planning: ?[]const u8 = null,
    resume_flag: bool = false,
    run_stamp: bool = false,
    no_tui: bool = false,
};

pub const ArgsError = error{Usage};

/// argv excludes the leading `mission`; argv[0] is the verb.
pub fn parseArgs(argv: []const []const u8) ArgsError!Args {
    if (argv.len == 0) return error.Usage;
    const verb = argv[0];
    var out: Args = .{ .verb = .start, .brief_path = "" };
    if (std.mem.eql(u8, verb, "resume")) {
        out.resume_flag = true;
    } else if (std.mem.eql(u8, verb, "trace")) {
        out.verb = .trace;
    } else if (std.mem.eql(u8, verb, "attach")) {
        out.verb = .attach;
    } else if (!std.mem.eql(u8, verb, "start")) {
        return error.Usage;
    }
    var positional: ?[]const u8 = null;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--planning")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.planning = argv[i];
        } else if (std.mem.eql(u8, a, "--resume")) {
            out.resume_flag = true;
        } else if (std.mem.eql(u8, a, "--run-stamp")) {
            out.run_stamp = true;
        } else if (std.mem.eql(u8, a, "--no-tui")) {
            out.no_tui = true;
        } else if (positional == null) {
            positional = a;
        } else {
            return error.Usage;
        }
    }
    out.brief_path = positional orelse return error.Usage;
    return out;
}

// ---------------------------------------------------------------------------
// timeout ceilings
// ---------------------------------------------------------------------------

pub const Timeouts = struct {
    /// Role turns ride bus invocations; real providers and console gates
    /// outlive the 30s kernel default.
    invoke_ms: i64 = 3_600_000,
    /// The blocking missions::start call spans the WHOLE mission — under the
    /// flat invoke timeout it doubled as a mission duration cap.
    mission_ms: i64 = 86_400_000,
    approval_ms: i64 = 300_000,
    budget_max_tokens: i64 = 1_000_000,
    /// Scripted-test defaults are too tight for real executors iterating
    /// with tools — a real mission gets room by default.
    role_max_steps: i64 = 24,
    max_role_turns: i64 = 48,
};

pub fn timeouts(env: []const EnvPair) Timeouts {
    const d: Timeouts = .{};
    return .{
        .invoke_ms = envInt(env, "ZYGOS_INVOKE_TIMEOUT_MS", d.invoke_ms),
        .mission_ms = envInt(env, "ZYGOS_MISSION_TIMEOUT_MS", d.mission_ms),
        .approval_ms = envInt(env, "ZYGOS_APPROVAL_TIMEOUT_MS", d.approval_ms),
        .budget_max_tokens = envInt(env, "ZYGOS_BUDGET_MAX_TOKENS", d.budget_max_tokens),
        .role_max_steps = envInt(env, "ZYGOS_ROLE_MAX_STEPS", d.role_max_steps),
        .max_role_turns = envInt(env, "ZYGOS_MAX_ROLE_TURNS", d.max_role_turns),
    };
}

// ---------------------------------------------------------------------------
// search backend (Y5 brave key_env defect lives here)
// ---------------------------------------------------------------------------

/// Operator env config: ZYGOS_SEARCH_ENGINE (brave|searxng) +
/// ZYGOS_SEARCH_ENDPOINT (+ ZYGOS_SEARCH_KEY_ENV, default BRAVE_API_KEY for
/// brave). The named env var is resolved into `key` HERE — web_tools never
/// reads the environment, so leaving `key` null meant every brave search
/// failed with MissingSearchKey even with the key exported (Y5 defect).
/// Slices alias `env`; unset ⇒ web_search replies a structured error per call.
pub fn searchConfigFromEnv(env: []const EnvPair) ?web_tools.SearchConfig {
    const engine_raw = getEnv(env, "ZYGOS_SEARCH_ENGINE") orelse return null;
    if (std.mem.eql(u8, engine_raw, "brave")) {
        const key_env = getEnv(env, "ZYGOS_SEARCH_KEY_ENV") orelse "BRAVE_API_KEY";
        return .{
            .endpoint = getEnv(env, "ZYGOS_SEARCH_ENDPOINT") orelse "https://api.search.brave.com",
            .key_env = key_env,
            .key = getEnv(env, key_env),
            .engine = .brave,
        };
    }
    if (std.mem.eql(u8, engine_raw, "searxng")) {
        return .{
            .endpoint = getEnv(env, "ZYGOS_SEARCH_ENDPOINT") orelse return null,
            .engine = .searxng,
        };
    }
    return null;
}

// ---------------------------------------------------------------------------
// run-stamp refusal + planning root
// ---------------------------------------------------------------------------

/// Fresh `start` over an existing mission substrate refuses instead of
/// clobbering it; `resume` and `--run-stamp` runs proceed.
pub fn refuseStart(resume_flag: bool, run_stamp: bool, mission_exists: bool) bool {
    return !resume_flag and !run_stamp and mission_exists;
}

/// `--run-stamp` gives every scheduled invocation its own planning root.
pub fn planningRoot(
    gpa: std.mem.Allocator,
    base: []const u8,
    run_stamp: bool,
    stamp: []const u8,
) error{OutOfMemory}![]u8 {
    if (!run_stamp) return gpa.dupe(u8, base);
    return std.fmt.allocPrint(gpa, "{s}-{s}", .{ base, stamp });
}

// ---------------------------------------------------------------------------
// policy seeding
// ---------------------------------------------------------------------------

/// Base tool rules + operator-configured MCP tools, all `.allow` (the console
/// gate is the human boundary). Rule.tool slices alias the caller's strings.
pub fn policySeed(
    gpa: std.mem.Allocator,
    mcp_tools: []const []const u8,
) error{OutOfMemory}![]policy.Rule {
    var rules = try gpa.alloc(policy.Rule, 3 + mcp_tools.len);
    rules[0] = .{ .tool = "bash", .verdict = .allow };
    rules[1] = .{ .tool = "web_fetch", .verdict = .allow };
    rules[2] = .{ .tool = "web_search", .verdict = .allow };
    for (mcp_tools, 0..) |name, i| rules[3 + i] = .{ .tool = name, .verdict = .allow };
    return rules;
}

// ---------------------------------------------------------------------------
// vault-checkpoint protocol
// ---------------------------------------------------------------------------

pub const CheckpointVerdict = enum { proceed, refuse };

/// An unusable vault refuses the run instead of writing into it unprotected.
pub fn checkpointVerdict(res: inproc.CallResult) CheckpointVerdict {
    return switch (res) {
        .ok => .proceed,
        .err => .refuse,
    };
}

pub fn checkpointRequest(gpa: std.mem.Allocator, mission_id: []const u8) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(gpa, "{{\"label\":\"pre-mission {s}\"}}", .{mission_id});
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const t = std.testing;

test "parseArgs: start requires a brief path (fail closed)" {
    try t.expectError(error.Usage, parseArgs(&.{"start"}));
    try t.expectError(error.Usage, parseArgs(&.{}));
    try t.expectError(error.Usage, parseArgs(&.{"bogus"}));
}

test "parseArgs: resume verb sets resume_flag; flags parse" {
    const a = try parseArgs(&.{ "resume", "b.md", "--run-stamp", "--no-tui", "--planning", "p" });
    try t.expectEqual(Verb.start, a.verb);
    try t.expect(a.resume_flag);
    try t.expect(a.run_stamp);
    try t.expect(a.no_tui);
    try t.expectEqualStrings("b.md", a.brief_path);
    try t.expectEqualStrings("p", a.planning.?);
}

test "parseArgs: --resume flag on start; --planning without value is usage" {
    const a = try parseArgs(&.{ "start", "--resume", "b.md" });
    try t.expect(a.resume_flag);
    try t.expectEqual(Verb.start, a.verb);
    try t.expectError(error.Usage, parseArgs(&.{ "start", "b.md", "--planning" }));
}

test "parseArgs: a second positional is usage" {
    try t.expectError(error.Usage, parseArgs(&.{ "start", "a.md", "b.md" }));
}

test "parseArgs: trace requires a target" {
    try t.expectError(error.Usage, parseArgs(&.{"trace"}));
    const a = try parseArgs(&.{ "trace", ".planning" });
    try t.expectEqual(Verb.trace, a.verb);
    try t.expectEqualStrings(".planning", a.brief_path);
}

test "parseArgs: attach takes a planning-dir target" {
    try t.expectError(error.Usage, parseArgs(&.{"attach"}));
    const a = try parseArgs(&.{ "attach", ".planning" });
    try t.expectEqual(Verb.attach, a.verb);
    try t.expectEqualStrings(".planning", a.brief_path);
}

test "timeouts: defaults match the shipped ceilings" {
    const tm = timeouts(&.{});
    try t.expectEqual(@as(i64, 3_600_000), tm.invoke_ms);
    try t.expectEqual(@as(i64, 86_400_000), tm.mission_ms);
    try t.expectEqual(@as(i64, 300_000), tm.approval_ms);
    try t.expectEqual(@as(i64, 1_000_000), tm.budget_max_tokens);
    try t.expectEqual(@as(i64, 24), tm.role_max_steps);
    try t.expectEqual(@as(i64, 48), tm.max_role_turns);
}

test "timeouts: env overrides apply; malformed values keep defaults" {
    const env = [_]EnvPair{
        .{ .name = "ZYGOS_INVOKE_TIMEOUT_MS", .value = "5000" },
        .{ .name = "ZYGOS_MISSION_TIMEOUT_MS", .value = "9000" },
        .{ .name = "ZYGOS_APPROVAL_TIMEOUT_MS", .value = "not-a-number" },
        .{ .name = "ZYGOS_BUDGET_MAX_TOKENS", .value = "42" },
        .{ .name = "ZYGOS_ROLE_MAX_STEPS", .value = "7" },
        .{ .name = "ZYGOS_MAX_ROLE_TURNS", .value = "9" },
    };
    const tm = timeouts(&env);
    try t.expectEqual(@as(i64, 5000), tm.invoke_ms);
    try t.expectEqual(@as(i64, 9000), tm.mission_ms);
    try t.expectEqual(@as(i64, 300_000), tm.approval_ms); // malformed → default
    try t.expectEqual(@as(i64, 42), tm.budget_max_tokens);
    try t.expectEqual(@as(i64, 7), tm.role_max_steps);
    try t.expectEqual(@as(i64, 9), tm.max_role_turns);
}

test "searchConfigFromEnv: brave resolves key_env into key at boot (Y5 regression)" {
    const env = [_]EnvPair{
        .{ .name = "ZYGOS_SEARCH_ENGINE", .value = "brave" },
        .{ .name = "BRAVE_API_KEY", .value = "sk-test" },
    };
    const cfg = searchConfigFromEnv(&env).?;
    try t.expectEqual(web_tools.SearchEngine.brave, cfg.engine);
    try t.expectEqualStrings("https://api.search.brave.com", cfg.endpoint);
    try t.expectEqualStrings("BRAVE_API_KEY", cfg.key_env.?);
    try t.expectEqualStrings("sk-test", cfg.key.?);
}

test "searchConfigFromEnv: brave with the key unset leaves key null" {
    const env = [_]EnvPair{
        .{ .name = "ZYGOS_SEARCH_ENGINE", .value = "brave" },
    };
    const cfg = searchConfigFromEnv(&env).?;
    try t.expectEqual(@as(?[]const u8, null), cfg.key);
    try t.expectEqualStrings("BRAVE_API_KEY", cfg.key_env.?);
}

test "searchConfigFromEnv: custom ZYGOS_SEARCH_KEY_ENV resolves that var" {
    const env = [_]EnvPair{
        .{ .name = "ZYGOS_SEARCH_ENGINE", .value = "brave" },
        .{ .name = "ZYGOS_SEARCH_KEY_ENV", .value = "MY_BRAVE_KEY" },
        .{ .name = "MY_BRAVE_KEY", .value = "zz" },
        .{ .name = "BRAVE_API_KEY", .value = "wrong" },
    };
    const cfg = searchConfigFromEnv(&env).?;
    try t.expectEqualStrings("MY_BRAVE_KEY", cfg.key_env.?);
    try t.expectEqualStrings("zz", cfg.key.?);
}

test "searchConfigFromEnv: searxng requires endpoint; unknown engine is null" {
    const bare = [_]EnvPair{
        .{ .name = "ZYGOS_SEARCH_ENGINE", .value = "searxng" },
    };
    try t.expectEqual(@as(?web_tools.SearchConfig, null), searchConfigFromEnv(&bare));
    const full = [_]EnvPair{
        .{ .name = "ZYGOS_SEARCH_ENGINE", .value = "searxng" },
        .{ .name = "ZYGOS_SEARCH_ENDPOINT", .value = "http://localhost:8888" },
    };
    const cfg = searchConfigFromEnv(&full).?;
    try t.expectEqual(web_tools.SearchEngine.searxng, cfg.engine);
    try t.expectEqualStrings("http://localhost:8888", cfg.endpoint);
    const unknown = [_]EnvPair{
        .{ .name = "ZYGOS_SEARCH_ENGINE", .value = "bing" },
    };
    try t.expectEqual(@as(?web_tools.SearchConfig, null), searchConfigFromEnv(&unknown));
}

test "refuseStart: fresh start over existing substrate refuses; resume/run-stamp proceed" {
    try t.expect(refuseStart(false, false, true));
    try t.expect(!refuseStart(true, false, true));
    try t.expect(!refuseStart(false, true, true));
    try t.expect(!refuseStart(false, false, false));
}

test "planningRoot: run-stamp suffixes the base; plain base unchanged" {
    const plain = try planningRoot(t.allocator, "/w/.planning", false, "20260721-120000");
    defer t.allocator.free(plain);
    try t.expectEqualStrings("/w/.planning", plain);
    const stamped = try planningRoot(t.allocator, "/w/.planning", true, "20260721-120000");
    defer t.allocator.free(stamped);
    try t.expectEqualStrings("/w/.planning-20260721-120000", stamped);
}

test "policySeed: base tools + mcp tools all allow" {
    const mcp = [_][]const u8{ "tessera_orient", "tessera_capture" };
    const rules = try policySeed(t.allocator, &mcp);
    defer t.allocator.free(rules);
    try t.expectEqual(@as(usize, 5), rules.len);
    try t.expectEqualStrings("bash", rules[0].tool);
    try t.expectEqualStrings("web_fetch", rules[1].tool);
    try t.expectEqualStrings("web_search", rules[2].tool);
    try t.expectEqualStrings("tessera_orient", rules[3].tool);
    try t.expectEqualStrings("tessera_capture", rules[4].tool);
    for (rules) |r| try t.expectEqual(policy.Verdict.allow, r.verdict);
}

test "checkpointVerdict: bus err refuses the run (fail closed)" {
    const ok_body = try t.allocator.dupe(u8, "{\"checkpoint\":\"abc\"}");
    const ok: inproc.CallResult = .{ .ok = ok_body };
    defer ok.deinit(t.allocator);
    try t.expectEqual(CheckpointVerdict.proceed, checkpointVerdict(ok));
    const err_body = try t.allocator.dupe(u8, "vault_unusable");
    const err: inproc.CallResult = .{ .err = err_body };
    defer err.deinit(t.allocator);
    try t.expectEqual(CheckpointVerdict.refuse, checkpointVerdict(err));
}

test "checkpointRequest: pre-mission label shape" {
    const req = try checkpointRequest(t.allocator, "brief-2");
    defer t.allocator.free(req);
    try t.expectEqualStrings("{\"label\":\"pre-mission brief-2\"}", req);
}
