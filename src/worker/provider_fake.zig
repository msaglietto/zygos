//! Scripted fake provider (T6). Speaks the exact provider contract the turn
//! driver uses (docs/specs/turn.md): takes the request's stream channel,
//! pushes two text deltas, replies with the next scripted terminal message.
//! Interchangeable with the real anthropic provider — both are just bus
//! functions.

const std = @import("std");
const json = std.json;
const actor_mod = @import("../kernel/actor.zig");
const inproc = @import("../kernel/inproc.zig");
const sync = @import("../kernel/sync.zig");

pub const FakeProvider = struct {
    gpa: std.mem.Allocator,
    actor: *actor_mod.Actor,
    worker: *inproc.Worker,
    script: []const []const u8,
    mutex: sync.Mutex = .{},
    calls: usize = 0,

    /// Registers `zygos::provider::fake::messages`. Call N answers
    /// script[N] (the last entry repeats).
    pub fn start(
        gpa: std.mem.Allocator,
        actor: *actor_mod.Actor,
        registry: *inproc.Registry,
        script: []const []const u8,
    ) !*FakeProvider {
        std.debug.assert(script.len > 0);
        const self = try gpa.create(FakeProvider);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .actor = actor,
            .worker = try inproc.Worker.spawn(gpa, actor, registry, "fake-provider"),
            .script = script,
        };
        errdefer self.worker.stop();
        try self.worker.registerFunction("zygos::provider::fake::messages", self, &handler);
        return self;
    }

    pub fn stop(self: *FakeProvider) void {
        self.worker.stop();
        self.mutex.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    fn handler(ctx: ?*anyopaque, arena: std.mem.Allocator, request_json: []const u8) error{ Failed, OutOfMemory }![]const u8 {
        const self: *FakeProvider = @ptrCast(@alignCast(ctx.?));
        const n = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            const n = self.calls;
            self.calls += 1;
            break :blk n;
        };

        // Stream two deltas over the caller-provided channel, then close.
        const root = json.parseFromSliceLeaky(json.Value, arena, request_json, .{}) catch
            return error.Failed;
        if (root == .object) if (root.object.get("stream_channel")) |cv| if (cv == .object) {
            const id = cv.object.get("channel_id");
            const key = cv.object.get("access_key");
            if (id != null and key != null and id.? == .string and key.? == .string) {
                if (self.actor.channelTakeSender(id.?.string, key.?.string)) |sender_const| {
                    var sender = sender_const;
                    var d1 = "hello ".*;
                    var d2 = "world".*;
                    sender.push(.{ .text = &d1 }) catch {};
                    sender.push(.{ .text = &d2 }) catch {};
                    sender.deinit();
                } else |_| {}
            }
        };

        const idx = @min(n, self.script.len - 1);
        return arena.dupe(u8, self.script[idx]);
    }
};
