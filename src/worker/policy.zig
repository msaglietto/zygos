//! Policy gate worker (U1, docs/specs/policy.md). Registers
//! `zygos::policy::check`; the turn driver consults it before every tool
//! dispatch. Fail-closed at both ends: the worker's default verdict is deny
//! (no rule matched), and the driver treats every failure mode as deny.

const std = @import("std");
const json = std.json;
const actor_mod = @import("../kernel/actor.zig");
const inproc = @import("../kernel/inproc.zig");

pub const Verdict = enum { allow, deny, ask };

pub const Rule = struct {
    /// Matched against the request's `tool` name and `function_id`; a
    /// trailing '*' does prefix match on either.
    tool: []const u8,
    verdict: Verdict,
};

pub const PolicyWorker = struct {
    gpa: std.mem.Allocator,
    worker: *inproc.Worker,
    /// Owned deep copy — callers may pass stack-lived rule slices.
    rules: []Rule,

    pub fn start(
        gpa: std.mem.Allocator,
        actor: *actor_mod.Actor,
        registry: *inproc.Registry,
        rules: []const Rule,
    ) !*PolicyWorker {
        const self = try gpa.create(PolicyWorker);
        errdefer gpa.destroy(self);
        const owned = try gpa.alloc(Rule, rules.len);
        errdefer gpa.free(owned);
        var copied: usize = 0;
        errdefer for (owned[0..copied]) |r| gpa.free(@constCast(r.tool));
        for (rules, 0..) |r, i| {
            owned[i] = .{ .tool = try gpa.dupe(u8, r.tool), .verdict = r.verdict };
            copied += 1;
        }
        self.* = .{
            .gpa = gpa,
            .worker = try inproc.Worker.spawn(gpa, actor, registry, "policy"),
            .rules = owned,
        };
        errdefer self.worker.stop();
        try self.worker.registerFunction("zygos::policy::check", self, &handler);
        return self;
    }

    pub fn stop(self: *PolicyWorker) void {
        self.worker.stop();
        for (self.rules) |r| self.gpa.free(@constCast(r.tool));
        self.gpa.free(self.rules);
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    fn handler(ctx: ?*anyopaque, arena: std.mem.Allocator, request_json: []const u8) error{ Failed, OutOfMemory }![]const u8 {
        const self: *PolicyWorker = @ptrCast(@alignCast(ctx.?));

        // Malformed input is a deny reply, never a bus error — the gate
        // must answer, and the answer to garbage is "no".
        const root = json.parseFromSliceLeaky(json.Value, arena, request_json, .{}) catch
            return reply(arena, .deny, "malformed request");
        if (root != .object) return reply(arena, .deny, "malformed request");
        const tool = strField(root.object, "tool") orelse
            return reply(arena, .deny, "malformed request");
        const function_id = strField(root.object, "function_id") orelse "";

        for (self.rules) |r| {
            if (matches(r.tool, tool) or matches(r.tool, function_id)) {
                return replyRule(arena, r.verdict, r.tool);
            }
        }
        return reply(arena, .deny, "no rule matched");
    }

    fn matches(pattern: []const u8, name: []const u8) bool {
        if (name.len == 0) return false;
        if (std.mem.endsWith(u8, pattern, "*"))
            return std.mem.startsWith(u8, name, pattern[0 .. pattern.len - 1]);
        return std.mem.eql(u8, pattern, name);
    }

    fn reply(arena: std.mem.Allocator, verdict: Verdict, reason: []const u8) error{OutOfMemory}![]const u8 {
        return std.fmt.allocPrint(arena, "{{\"verdict\":\"{t}\",\"reason\":{f}}}", .{
            verdict, json.fmt(reason, .{}),
        });
    }

    fn replyRule(arena: std.mem.Allocator, verdict: Verdict, pattern: []const u8) error{OutOfMemory}![]const u8 {
        const reason = try std.fmt.allocPrint(arena, "rule: {s}", .{pattern});
        return reply(arena, verdict, reason);
    }
};

fn strField(obj: json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

// ===========================================================================
// Tests (docs/specs/policy.md contract, RED first)
// ===========================================================================

const testing = std.testing;

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

/// Calls zygos::policy::check and returns the parsed verdict + reason.
fn check(h: *Harness, request: []const u8) !struct { verdict: []u8, reason: []u8 } {
    const res = try h.caller.call("zygos::policy::check", request);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    var p = try json.parseFromSlice(json.Value, testing.allocator, res.ok, .{});
    defer p.deinit();
    return .{
        .verdict = try testing.allocator.dupe(u8, p.value.object.get("verdict").?.string),
        .reason = try testing.allocator.dupe(u8, p.value.object.get("reason").?.string),
    };
}

test "allow rule matches by tool name" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const pw = try PolicyWorker.start(testing.allocator, &h.actor, &h.registry, &.{
        .{ .tool = "bash", .verdict = .allow },
    });
    defer pw.stop();

    const r = try check(h, "{\"tool\":\"bash\",\"function_id\":\"zygos::tools::bash\",\"input\":{}}");
    defer testing.allocator.free(r.verdict);
    defer testing.allocator.free(r.reason);
    try testing.expectEqualStrings("allow", r.verdict);
}

test "first matching rule wins" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const pw = try PolicyWorker.start(testing.allocator, &h.actor, &h.registry, &.{
        .{ .tool = "bash", .verdict = .allow },
        .{ .tool = "bash", .verdict = .deny },
    });
    defer pw.stop();

    const r = try check(h, "{\"tool\":\"bash\",\"function_id\":\"zygos::tools::bash\"}");
    defer testing.allocator.free(r.verdict);
    defer testing.allocator.free(r.reason);
    try testing.expectEqualStrings("allow", r.verdict);
}

test "trailing-star glob matches function_id prefix" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const pw = try PolicyWorker.start(testing.allocator, &h.actor, &h.registry, &.{
        .{ .tool = "zygos::tools::*", .verdict = .allow },
    });
    defer pw.stop();

    const hit = try check(h, "{\"tool\":\"read_file\",\"function_id\":\"zygos::tools::read_file\"}");
    defer testing.allocator.free(hit.verdict);
    defer testing.allocator.free(hit.reason);
    try testing.expectEqualStrings("allow", hit.verdict);

    const miss = try check(h, "{\"tool\":\"deploy\",\"function_id\":\"prod::deploy\"}");
    defer testing.allocator.free(miss.verdict);
    defer testing.allocator.free(miss.reason);
    try testing.expectEqualStrings("deny", miss.verdict);
}

test "no rule matched denies (fail-closed default)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const pw = try PolicyWorker.start(testing.allocator, &h.actor, &h.registry, &.{
        .{ .tool = "bash", .verdict = .allow },
    });
    defer pw.stop();

    const r = try check(h, "{\"tool\":\"write_file\",\"function_id\":\"zygos::tools::write_file\"}");
    defer testing.allocator.free(r.verdict);
    defer testing.allocator.free(r.reason);
    try testing.expectEqualStrings("deny", r.verdict);
    try testing.expectEqualStrings("no rule matched", r.reason);
}

test "ask verdict round-trips" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const pw = try PolicyWorker.start(testing.allocator, &h.actor, &h.registry, &.{
        .{ .tool = "bash", .verdict = .ask },
    });
    defer pw.stop();

    const r = try check(h, "{\"tool\":\"bash\",\"function_id\":\"zygos::tools::bash\"}");
    defer testing.allocator.free(r.verdict);
    defer testing.allocator.free(r.reason);
    try testing.expectEqualStrings("ask", r.verdict);
}

test "malformed request denies without failing the handler" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const pw = try PolicyWorker.start(testing.allocator, &h.actor, &h.registry, &.{
        .{ .tool = "bash", .verdict = .allow },
    });
    defer pw.stop();

    // No `tool` field at all.
    const r = try check(h, "{\"whatever\":1}");
    defer testing.allocator.free(r.verdict);
    defer testing.allocator.free(r.reason);
    try testing.expectEqualStrings("deny", r.verdict);

    // Not even an object — still a deny reply, not handler_failed.
    const res = try h.caller.call("zygos::policy::check", "42");
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try testing.expect(std.mem.indexOf(u8, res.ok, "deny") != null);
}

test "no leaks under repeated checks" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const pw = try PolicyWorker.start(testing.allocator, &h.actor, &h.registry, &.{
        .{ .tool = "a", .verdict = .allow },
        .{ .tool = "b*", .verdict = .ask },
    });
    defer pw.stop();

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const res = try h.caller.call("zygos::policy::check", "{\"tool\":\"b-tool\",\"function_id\":\"x\"}");
        res.deinit(testing.allocator);
    }
}
