//! OpenAI-compatible provider worker — bus glue over net/openai.zig. Lives
//! in src/net/ so the `std.Io` handle it holds never crosses the Z-02
//! boundary; everything above addresses it as the bus function
//! `zygos::provider::openai::messages` (legacy) or an instance-parameterized
//! name (X2 catalog boot), interchangeable with the anthropic provider and
//! the fakes (same neutral request/reply shapes).
//!
//! Exercised only by the env-gated manual smoke (test/e2e/openai/) —
//! GOAL.md M2 notes; `zig build test` never opens a socket. Catalog boot
//! registration is covered by provider_boot.zig over the bus without HTTP.

const std = @import("std");
const json = std.json;
const actor_mod = @import("../kernel/actor.zig");
const inproc = @import("../kernel/inproc.zig");
const channel_mod = @import("../kernel/channel.zig");
const client = @import("openai.zig");

const log = std.log.scoped(.provider_openai);

/// Instance-parameterized start options (X2). Legacy `start()` is a thin
/// wrapper that fixes the historical worker/function names and no defaults.
pub const StartOptions = struct {
    worker_name: []const u8,
    function_name: []const u8,
    api_key: []const u8,
    base_url: []const u8,
    default_model: ?[]const u8 = null,
    default_max_tokens: ?u32 = null,
    default_temperature: ?f64 = null,
};

/// Pure merge of request fields over instance defaults (network-free).
/// Request values win; defaults fill gaps; model is required from one side
/// (neither ⇒ Failed). max_tokens falls back to 1024 when neither is set
/// (preserves legacy StreamOptions default). temperature stays optional.
pub const MergedFields = struct {
    model: []const u8,
    max_tokens: u32,
    temperature: ?f64,
};

pub fn mergeRequestDefaults(
    request_model: ?[]const u8,
    request_max_tokens: ?u32,
    request_temperature: ?f64,
    default_model: ?[]const u8,
    default_max_tokens: ?u32,
    default_temperature: ?f64,
) error{Failed}!MergedFields {
    return .{
        .model = request_model orelse default_model orelse return error.Failed,
        .max_tokens = request_max_tokens orelse default_max_tokens orelse 1024,
        .temperature = request_temperature orelse default_temperature,
    };
}

pub const OpenAiProvider = struct {
    gpa: std.mem.Allocator,
    actor: *actor_mod.Actor,
    worker: *inproc.Worker,
    io: std.Io,
    api_key: []const u8, // owned
    base_url: []const u8, // owned
    default_model: ?[]const u8 = null, // owned when set
    default_max_tokens: ?u32 = null,
    default_temperature: ?f64 = null,

    /// Legacy fixed name, no instance defaults. Thin wrapper over `startWith`.
    pub fn start(
        gpa: std.mem.Allocator,
        actor: *actor_mod.Actor,
        registry: *inproc.Registry,
        io: std.Io,
        api_key: []const u8,
        base_url: []const u8,
    ) !*OpenAiProvider {
        return startWith(gpa, actor, registry, io, .{
            .worker_name = "provider-openai",
            .function_name = "zygos::provider::openai::messages",
            .api_key = api_key,
            .base_url = base_url,
        });
    }

    pub fn startWith(
        gpa: std.mem.Allocator,
        actor: *actor_mod.Actor,
        registry: *inproc.Registry,
        io: std.Io,
        opts: StartOptions,
    ) !*OpenAiProvider {
        const self = try gpa.create(OpenAiProvider);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .actor = actor,
            .worker = try inproc.Worker.spawn(gpa, actor, registry, opts.worker_name),
            .io = io,
            .api_key = try gpa.dupe(u8, opts.api_key),
            .base_url = try gpa.dupe(u8, opts.base_url),
            .default_model = if (opts.default_model) |m| try gpa.dupe(u8, m) else null,
            .default_max_tokens = opts.default_max_tokens,
            .default_temperature = opts.default_temperature,
        };
        errdefer {
            self.gpa.free(self.api_key);
            self.gpa.free(self.base_url);
            if (self.default_model) |m| self.gpa.free(m);
            self.worker.stop();
        }
        try self.worker.registerFunction(opts.function_name, self, &handler);
        return self;
    }

    pub fn stop(self: *OpenAiProvider) void {
        self.worker.stop();
        self.gpa.free(self.api_key);
        self.gpa.free(self.base_url);
        if (self.default_model) |m| self.gpa.free(m);
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    fn handler(ctx: ?*anyopaque, arena: std.mem.Allocator, request_json: []const u8) error{ Failed, OutOfMemory }![]const u8 {
        const self: *OpenAiProvider = @ptrCast(@alignCast(ctx.?));

        const root = json.parseFromSliceLeaky(json.Value, arena, request_json, .{}) catch
            return error.Failed;
        if (root != .object) return error.Failed;
        const obj = root.object;

        const merged = mergeRequestDefaults(
            strField(obj, "model"),
            u32Field(obj, "max_tokens"),
            f64Field(obj, "temperature"),
            self.default_model,
            self.default_max_tokens,
            self.default_temperature,
        ) catch return error.Failed;

        const system = strField(obj, "system") orelse "";
        const messages_json = try rawField(arena, obj, "messages") orelse return error.Failed;
        const tools_json = try rawField(arena, obj, "tools") orelse "[]";

        var sender: ?channel_mod.Sender = null;
        if (obj.get("stream_channel")) |cv| if (cv == .object) {
            const id = strField(cv.object, "channel_id") orelse "";
            const key = strField(cv.object, "access_key") orelse "";
            sender = self.actor.channelTakeSender(id, key, 0) catch null;
        };

        const out = client.streamChat(self.gpa, self.io, .{
            .api_key = self.api_key,
            .model = merged.model,
            .system = system,
            .messages_json = messages_json,
            .tools_json = tools_json,
            .max_tokens = merged.max_tokens,
            .base_url = self.base_url,
            .temperature = merged.temperature,
        }, if (sender) |*s| s else null) catch |err| {
            if (sender) |*s| s.deinit();
            log.warn("openai-compat stream failed: {t}", .{err});
            return error.Failed;
        };
        if (sender) |*s| s.deinit();
        defer self.gpa.free(out);
        return arena.dupe(u8, out);
    }
};

fn strField(obj: json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn u32Field(obj: json.ObjectMap, key: []const u8) ?u32 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |n| if (n >= 0 and n <= std.math.maxInt(u32)) @intCast(n) else null,
        else => null,
    };
}

fn f64Field(obj: json.ObjectMap, key: []const u8) ?f64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .float => |f| f,
        .integer => |n| @floatFromInt(n),
        else => null,
    };
}

fn rawField(arena: std.mem.Allocator, obj: json.ObjectMap, key: []const u8) error{OutOfMemory}!?[]const u8 {
    const v = obj.get(key) orelse return null;
    var out: std.Io.Writer.Allocating = .init(arena);
    errdefer out.deinit();
    var ws: json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    ws.write(v) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

// ===========================================================================
// Tests — pure merge helper only; bus registration lives in provider_boot.zig
// ===========================================================================

const testing = std.testing;

test "mergeRequestDefaults: request model wins; absent falls to default; neither fails" {
    const a = try mergeRequestDefaults("req-model", null, null, "def-model", 100, 0.5);
    try testing.expectEqualStrings("req-model", a.model);

    const b = try mergeRequestDefaults(null, null, null, "def-model", 100, 0.5);
    try testing.expectEqualStrings("def-model", b.model);

    try testing.expectError(error.Failed, mergeRequestDefaults(null, null, null, null, null, null));
}

test "mergeRequestDefaults: max_tokens and temperature request wins / default fills" {
    const a = try mergeRequestDefaults("m", 2048, 0.2, "d", 512, 0.9);
    try testing.expectEqual(@as(u32, 2048), a.max_tokens);
    try testing.expectEqual(@as(f64, 0.2), a.temperature.?);

    const b = try mergeRequestDefaults("m", null, null, "d", 512, 0.9);
    try testing.expectEqual(@as(u32, 512), b.max_tokens);
    try testing.expectEqual(@as(f64, 0.9), b.temperature.?);

    // neither max_tokens → legacy StreamOptions default 1024; neither temp → null
    const c = try mergeRequestDefaults("m", null, null, "d", null, null);
    try testing.expectEqual(@as(u32, 1024), c.max_tokens);
    try testing.expectEqual(@as(?f64, null), c.temperature);
}
