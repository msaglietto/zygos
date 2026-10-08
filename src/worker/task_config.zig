//! `zygos task run --config zygos.zon`: the part of a mission route table a
//! headless task can honor. Only `.default` and `.routes` are accepted.
//! Any other top-level setting (`.context_strategy`, `.mcp_servers`, ...)
//! refuses the run instead of being ignored: a benchmark arm that "changed
//! the config" must have changed something this path executes.
//!
//! The task turn is routed as step id "task". Its ladder is the `task`
//! route when present, else `.default`. The SHA-256 of the file text is the
//! arm identity the trial carries, so two arms cannot claim the same config
//! while running different bytes.

const std = @import("std");
const router = @import("router.zig");

pub const step_id = "task";
/// Each attempt's provider is called through a task bridge under this
/// prefix so usage and cache counts are recorded per step (task.zig).
pub const via_prefix = "zygos::provider::task::via::";

pub const ParseError = error{ OutOfMemory, ParseZon, UnsupportedSetting, NoTaskRoute };

const Data = struct {
    default: []const router.Attempt = &.{},
    routes: []const router.Route = &.{},
};

pub const TaskZon = struct {
    gpa: std.mem.Allocator,
    data: Data,
    sha256_hex: [64]u8,

    /// Strict parse: an unknown top-level field is `UnsupportedSetting`,
    /// malformed ZON is `ParseZon`, a table with no ladder for the task
    /// step is `NoTaskRoute`. An attempt with an empty function or model
    /// is `ParseZon`.
    pub fn parse(gpa: std.mem.Allocator, text: [:0]const u8) ParseError!TaskZon {
        // std's unknown-field note allocates into the diagnostics; a null
        // diagnostics leaks it (Zig 0.16), so one is always supplied.
        var diag: std.zon.parse.Diagnostics = .{};
        defer diag.deinit(gpa);
        const data = std.zon.parse.fromSliceAlloc(Data, gpa, text, &diag, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ParseZon => {
                // The strict parse failed. If a lenient parse succeeds the
                // only difference was an unknown field.
                const lenient = std.zon.parse.fromSliceAlloc(Data, gpa, text, null, .{
                    .ignore_unknown_fields = true,
                }) catch |lenient_err| switch (lenient_err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.ParseZon => return error.ParseZon,
                };
                std.zon.parse.free(gpa, lenient);
                return error.UnsupportedSetting;
            },
        };
        errdefer std.zon.parse.free(gpa, data);
        for (data.default) |a| try checkAttempt(a);
        for (data.routes) |r| {
            if (r.step_id.len == 0) return error.ParseZon;
            for (r.attempts) |a| try checkAttempt(a);
        }
        if (ladderOf(data).len == 0) return error.NoTaskRoute;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
        return .{
            .gpa = gpa,
            .data = data,
            .sha256_hex = std.fmt.bytesToHex(digest, .lower),
        };
    }

    pub fn deinit(self: *TaskZon) void {
        std.zon.parse.free(self.gpa, self.data);
        self.* = undefined;
    }

    /// The escalation ladder the task step walks.
    pub fn ladder(self: *const TaskZon) []const router.Attempt {
        return ladderOf(self.data);
    }

    /// A router table for the task session: one default ladder whose
    /// attempts name the task bridge for each upstream. The caller owns
    /// the result (`router.Config.deinit`, which `RouterWorker.stop` runs).
    pub fn routerConfig(self: *const TaskZon, gpa: std.mem.Allocator) error{OutOfMemory}!router.Config {
        const src = self.ladder();
        const attempts = try gpa.alloc(router.Attempt, src.len);
        var n: usize = 0;
        errdefer {
            for (attempts[0..n]) |a| {
                gpa.free(a.provider_function);
                gpa.free(a.model);
            }
            gpa.free(attempts);
        }
        for (src) |a| {
            const pf = try viaName(gpa, a.provider_function);
            errdefer gpa.free(pf);
            const model = try gpa.dupe(u8, a.model);
            attempts[n] = .{ .provider_function = pf, .model = model };
            n += 1;
        }
        return .{
            .gpa = gpa,
            .data = .{ .default = attempts, .routes = &.{} },
        };
    }
};

fn checkAttempt(a: router.Attempt) ParseError!void {
    if (a.provider_function.len == 0 or a.model.len == 0) return error.ParseZon;
}

fn ladderOf(data: Data) []const router.Attempt {
    for (data.routes) |r| {
        if (std.mem.eql(u8, r.step_id, step_id)) return r.attempts;
    }
    return data.default;
}

/// Bridge function name for an upstream provider function. Caller owns.
pub fn viaName(gpa: std.mem.Allocator, upstream: []const u8) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(gpa, "{s}{s}", .{ via_prefix, upstream }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
}

// ===========================================================================
// Tests (docs/specs/task.md "Configuration", RED first)
// ===========================================================================

const testing = std.testing;

const routed_zon: [:0]const u8 =
    \\.{
    \\    .default = .{
    \\        .{ .provider_function = "zygos::providers::other", .model = "other-model" },
    \\    },
    \\    .routes = .{
    \\        .{ .step_id = "task", .attempts = .{
    \\            .{ .provider_function = "zygos::providers::deepseek-flash", .model = "deepseek/deepseek-v4.1-flash" },
    \\            .{ .provider_function = "zygos::providers::glm-flash", .model = "glm-5.3-flash" },
    \\        } },
    \\    },
    \\}
;

const default_only_zon: [:0]const u8 =
    \\.{ .default = .{ .{ .provider_function = "zygos::providers::deepseek-flash", .model = "deepseek/deepseek-v4.1-flash" } } }
;

test "parse: the task route wins over default and the sha pins the file bytes" {
    var cfg = try TaskZon.parse(testing.allocator, routed_zon);
    defer cfg.deinit();
    const l = cfg.ladder();
    try testing.expectEqual(@as(usize, 2), l.len);
    try testing.expectEqualStrings("zygos::providers::deepseek-flash", l[0].provider_function);
    try testing.expectEqualStrings("glm-5.3-flash", l[1].model);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(routed_zon, &digest, .{});
    try testing.expectEqualStrings(&std.fmt.bytesToHex(digest, .lower), &cfg.sha256_hex);

    var only_default = try TaskZon.parse(testing.allocator, default_only_zon);
    defer only_default.deinit();
    try testing.expectEqual(@as(usize, 1), only_default.ladder().len);
    try testing.expect(!std.mem.eql(u8, &cfg.sha256_hex, &only_default.sha256_hex));
}

test "parse: an unsupported mission setting refuses, malformed ZON is a parse error" {
    const with_context: [:0]const u8 =
        \\.{
        \\    .default = .{ .{ .provider_function = "zygos::providers::deepseek-flash", .model = "m" } },
        \\    .context_strategy = .{ .kind = "recall" },
        \\}
    ;
    try testing.expectError(error.UnsupportedSetting, TaskZon.parse(testing.allocator, with_context));
    const with_mcp: [:0]const u8 =
        \\.{
        \\    .default = .{ .{ .provider_function = "zygos::providers::deepseek-flash", .model = "m" } },
        \\    .mcp_servers = .{},
        \\}
    ;
    try testing.expectError(error.UnsupportedSetting, TaskZon.parse(testing.allocator, with_mcp));
    try testing.expectError(error.ParseZon, TaskZon.parse(testing.allocator, ".{ .default = .{ .{ .provider_function = 1 } } }"));
    try testing.expectError(error.ParseZon, TaskZon.parse(testing.allocator, ".{ .default = "));
    try testing.expectError(error.ParseZon, TaskZon.parse(testing.allocator,
        \\.{ .default = .{ .{ .provider_function = "", .model = "m" } } }
    ));
}

test "parse: no ladder for the task step refuses" {
    try testing.expectError(error.NoTaskRoute, TaskZon.parse(testing.allocator, ".{}"));
    try testing.expectError(error.NoTaskRoute, TaskZon.parse(testing.allocator,
        \\.{ .routes = .{ .{ .step_id = "planner", .attempts = .{ .{ .provider_function = "zygos::providers::x", .model = "m" } } } } }
    ));
}

test "routerConfig: every attempt is routed through the task bridge, in ladder order" {
    var cfg = try TaskZon.parse(testing.allocator, routed_zon);
    defer cfg.deinit();
    var rc = try cfg.routerConfig(testing.allocator);
    defer rc.deinit();
    const a0 = rc.resolve(step_id, 0) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("zygos::provider::task::via::zygos::providers::deepseek-flash", a0.provider_function);
    try testing.expectEqualStrings("deepseek/deepseek-v4.1-flash", a0.model);
    const a1 = rc.resolve(step_id, 1) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("zygos::provider::task::via::zygos::providers::glm-flash", a1.provider_function);
    try testing.expect(rc.resolve(step_id, 2) == null);
}
