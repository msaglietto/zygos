//! Model router worker (U3, docs/specs/router.md). Routing truth is a
//! `zygos.zon` config: per-step escalation ladders of
//! {provider_function, model} attempts, plus a default ladder.
//! `zygos::models::resolve(step_id, attempt)` walks the ladder; past its end
//! is a `route_exhausted` REPLY (not a bus error) so callers can tell "no
//! more routes" from "router is down" — both fail a turn, differently.
//!
//! Config.parse takes ZON text, not a path: file IO in Zig 0.16 lives in
//! std.Io, which Z-02 confines to src/net/ — binaries read the file.

const std = @import("std");
const jsonx = @import("jsonx.zig");
const json = std.json;
const actor_mod = @import("../kernel/actor.zig");
const inproc = @import("../kernel/inproc.zig");

pub const Attempt = struct {
    provider_function: []const u8,
    model: []const u8,
};

pub const Route = struct {
    step_id: []const u8,
    attempts: []const Attempt,
};

const ConfigData = struct {
    default: []const Attempt = &.{},
    routes: []const Route = &.{},
};

pub const Config = struct {
    gpa: std.mem.Allocator,
    data: ConfigData,

    pub fn parse(gpa: std.mem.Allocator, zon_text: [:0]const u8) error{ OutOfMemory, ParseZon }!Config {
        return .{
            .gpa = gpa,
            // ignore_unknown_fields: zygos.zon also carries non-routing
            // tables (.mcp_servers) parsed by their own owners.
            .data = try std.zon.parse.fromSliceAlloc(ConfigData, gpa, zon_text, null, .{
                .ignore_unknown_fields = true,
            }),
        };
    }

    pub fn deinit(self: *Config) void {
        std.zon.parse.free(self.gpa, self.data);
        self.* = undefined;
    }

    /// Ladder lookup: the step's own ladder, else the default; null past
    /// the end (= route_exhausted).
    pub fn resolve(self: *const Config, step_id: []const u8, attempt: usize) ?Attempt {
        const ladder = for (self.data.routes) |r| {
            if (std.mem.eql(u8, r.step_id, step_id)) break r.attempts;
        } else self.data.default;
        if (attempt >= ladder.len) return null;
        return ladder[attempt];
    }
};

pub const RouterWorker = struct {
    gpa: std.mem.Allocator,
    worker: *inproc.Worker,
    config: Config, // owned; freed on stop

    pub fn start(
        gpa: std.mem.Allocator,
        actor: *actor_mod.Actor,
        registry: *inproc.Registry,
        config: Config,
    ) !*RouterWorker {
        const self = try gpa.create(RouterWorker);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .worker = try inproc.Worker.spawn(gpa, actor, registry, "model-router"),
            .config = config,
        };
        errdefer self.worker.stop();
        try self.worker.registerFunction("zygos::models::resolve", self, &handler);
        return self;
    }

    pub fn stop(self: *RouterWorker) void {
        self.worker.stop();
        self.config.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    fn handler(ctx: ?*anyopaque, arena: std.mem.Allocator, request_json: []const u8) error{ Failed, OutOfMemory }![]const u8 {
        const self: *RouterWorker = @ptrCast(@alignCast(ctx.?));

        const exhausted = "{\"error\":\"route_exhausted\"}";
        const root = json.parseFromSliceLeaky(json.Value, arena, request_json, .{}) catch
            return arena.dupe(u8, exhausted);
        if (root != .object) return arena.dupe(u8, exhausted);
        const step_id = strField(root.object, "step_id") orelse "";
        const attempt: usize = if (root.object.get("attempt")) |v|
            (if (v == .integer and v.integer >= 0) @intCast(v.integer) else return arena.dupe(u8, exhausted))
        else
            0;

        const a = self.config.resolve(step_id, attempt) orelse
            return arena.dupe(u8, exhausted);
        return std.fmt.allocPrint(arena, "{{\"provider_function\":{f},\"model\":{f}}}", .{
            json.fmt(a.provider_function, .{}),
            json.fmt(a.model, .{}),
        });
    }
};

const strField = jsonx.strField;

// ===========================================================================
// Tests (docs/specs/router.md contract, RED first)
// ===========================================================================

const testing = std.testing;

const test_zon: [:0]const u8 =
    \\.{
    \\    .default = .{
    \\        .{ .provider_function = "zygos::provider::fake::messages", .model = "fake-default" },
    \\    },
    \\    .routes = .{
    \\        .{
    \\            .step_id = "plan",
    \\            .attempts = .{
    \\                .{ .provider_function = "zygos::provider::anthropic::messages", .model = "claude-opus" },
    \\                .{ .provider_function = "zygos::provider::openai::messages", .model = "gpt-x" },
    \\            },
    \\        },
    \\    },
    \\}
;

test "parse: routes + default from ZON text" {
    var cfg = try Config.parse(testing.allocator, test_zon);
    defer cfg.deinit();

    try testing.expectEqual(@as(usize, 1), cfg.data.default.len);
    try testing.expectEqual(@as(usize, 1), cfg.data.routes.len);
    try testing.expectEqualStrings("plan", cfg.data.routes[0].step_id);
    try testing.expectEqual(@as(usize, 2), cfg.data.routes[0].attempts.len);
    try testing.expectEqualStrings("claude-opus", cfg.data.routes[0].attempts[0].model);
}

test "router parse keeps ignoring .steps" {
    const zon: [:0]const u8 =
        \\.{
        \\    .default = .{ .{ .provider_function = "zygos::providers::x", .model = "m" } },
        \\    .steps = .{
        \\        .{ .id = "architect", .definition = "agents/architect.md", .tools = true },
        \\        .{ .id = "executor", .unknown = 1 },
        \\    },
        \\}
    ;
    var cfg = try Config.parse(testing.allocator, zon);
    defer cfg.deinit();
    try testing.expectEqual(@as(usize, 1), cfg.data.default.len);
    try testing.expectEqualStrings("m", cfg.data.default[0].model);
    try testing.expectEqual(@as(usize, 0), cfg.data.routes.len);
}

test "malformed ZON is a parse error, no leaks" {
    try testing.expectError(error.ParseZon, Config.parse(testing.allocator, ".{ .routes = 42 }"));
}

const Harness = struct {
    registry: inproc.Registry,
    actor: actor_mod.Actor,
    kernel: std.Thread,
    caller: *inproc.Worker,

    fn init(gpa: std.mem.Allocator) !*Harness {
        const self = try gpa.create(Harness);
        self.registry = inproc.Registry.init(gpa, null);
        self.actor = try actor_mod.Actor.init(gpa, .{}, self.registry.outbound());
        self.kernel = try std.Thread.spawn(.{}, actor_mod.Actor.run, .{&self.actor});
        self.caller = try inproc.Worker.spawn(gpa, &self.actor, &self.registry, "test-caller");
        return self;
    }

    fn deinit(self: *Harness) void {
        const gpa = self.actor.gpa;
        self.caller.stop();
        self.actor.post(.shutdown);
        self.kernel.join();
        self.actor.deinit();
        self.registry.deinit();
        gpa.destroy(self);
    }
};

fn startRouter(h: *Harness, zon: [:0]const u8) !*RouterWorker {
    const cfg = try Config.parse(testing.allocator, zon);
    return RouterWorker.start(testing.allocator, &h.actor, &h.registry, cfg);
}

test "resolve walks the step ladder by attempt" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const rw = try startRouter(h, test_zon);
    defer rw.stop();

    const a0 = try h.caller.call("zygos::models::resolve", "{\"step_id\":\"plan\",\"attempt\":0}");
    defer a0.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, a0.ok, "claude-opus") != null);

    const a1 = try h.caller.call("zygos::models::resolve", "{\"step_id\":\"plan\",\"attempt\":1}");
    defer a1.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, a1.ok, "gpt-x") != null);
    try testing.expect(std.mem.indexOf(u8, a1.ok, "zygos::provider::openai::messages") != null);
}

test "attempt past the ladder is route_exhausted" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const rw = try startRouter(h, test_zon);
    defer rw.stop();

    const res = try h.caller.call("zygos::models::resolve", "{\"step_id\":\"plan\",\"attempt\":2}");
    defer res.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, res.ok, "route_exhausted") != null);
}

test "unknown step falls back to the default ladder" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const rw = try startRouter(h, test_zon);
    defer rw.stop();

    const res = try h.caller.call("zygos::models::resolve", "{\"step_id\":\"mystery\",\"attempt\":0}");
    defer res.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, res.ok, "fake-default") != null);
}

test "unknown step with no default is route_exhausted" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const rw = try startRouter(h, ".{}");
    defer rw.stop();

    const res = try h.caller.call("zygos::models::resolve", "{\"step_id\":\"mystery\",\"attempt\":0}");
    defer res.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, res.ok, "route_exhausted") != null);
}

test "malformed resolve request is route_exhausted, not a bus error" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const rw = try startRouter(h, test_zon);
    defer rw.stop();

    const res = try h.caller.call("zygos::models::resolve", "\"nonsense\"");
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try testing.expect(std.mem.indexOf(u8, res.ok, "route_exhausted") != null);
}

test "no leaks under resolve loops" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const rw = try startRouter(h, test_zon);
    defer rw.stop();

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const res = try h.caller.call("zygos::models::resolve", "{\"step_id\":\"plan\",\"attempt\":0}");
        res.deinit(testing.allocator);
    }
}
