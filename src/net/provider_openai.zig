//! OpenAI-compatible provider worker — bus glue over net/openai.zig. Lives
//! in src/net/ so the `std.Io` handle it holds never crosses the Z-02
//! boundary; everything above addresses it as the bus function
//! `zygos::provider::openai::messages`, interchangeable with the anthropic
//! provider and the fakes (same neutral request/reply shapes).
//!
//! Exercised only by the env-gated manual smoke (test/e2e/openai/) —
//! GOAL.md M2 notes; `zig build test` never opens a socket.

const std = @import("std");
const json = std.json;
const actor_mod = @import("../kernel/actor.zig");
const inproc = @import("../kernel/inproc.zig");
const channel_mod = @import("../kernel/channel.zig");
const client = @import("openai.zig");

const log = std.log.scoped(.provider_openai);

pub const OpenAiProvider = struct {
    gpa: std.mem.Allocator,
    actor: *actor_mod.Actor,
    worker: *inproc.Worker,
    io: std.Io,
    api_key: []const u8, // owned
    base_url: []const u8, // owned

    pub fn start(
        gpa: std.mem.Allocator,
        actor: *actor_mod.Actor,
        registry: *inproc.Registry,
        io: std.Io,
        api_key: []const u8,
        base_url: []const u8,
    ) !*OpenAiProvider {
        const self = try gpa.create(OpenAiProvider);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .actor = actor,
            .worker = try inproc.Worker.spawn(gpa, actor, registry, "provider-openai"),
            .io = io,
            .api_key = try gpa.dupe(u8, api_key),
            .base_url = try gpa.dupe(u8, base_url),
        };
        try self.worker.registerFunction("zygos::provider::openai::messages", self, &handler);
        return self;
    }

    pub fn stop(self: *OpenAiProvider) void {
        self.worker.stop();
        self.gpa.free(self.api_key);
        self.gpa.free(self.base_url);
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    fn handler(ctx: ?*anyopaque, arena: std.mem.Allocator, request_json: []const u8) error{ Failed, OutOfMemory }![]const u8 {
        const self: *OpenAiProvider = @ptrCast(@alignCast(ctx.?));

        const root = json.parseFromSliceLeaky(json.Value, arena, request_json, .{}) catch
            return error.Failed;
        if (root != .object) return error.Failed;
        const obj = root.object;

        const model = strField(obj, "model") orelse return error.Failed;
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
            .model = model,
            .system = system,
            .messages_json = messages_json,
            .tools_json = tools_json,
            .base_url = self.base_url,
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

fn rawField(arena: std.mem.Allocator, obj: json.ObjectMap, key: []const u8) error{OutOfMemory}!?[]const u8 {
    const v = obj.get(key) orelse return null;
    var out: std.Io.Writer.Allocating = .init(arena);
    errdefer out.deinit();
    var ws: json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    ws.write(v) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}
