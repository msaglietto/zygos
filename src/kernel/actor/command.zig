//! Kernel actor command surface: what can be posted to the inbox and how
//! finished frames leave the kernel. Pure types — the loop lives in actor.zig.

const std = @import("std");
const json = std.json;
const protocol = @import("../protocol.zig");
const channel_mod = @import("../channel.zig");
const types = @import("../types.zig");
const sync = @import("../sync.zig");

pub const WorkerId = types.WorkerId;

pub const SendError = error{ Disconnected, QueueFull };

/// How finished frames leave the kernel. The net layer backs this with
/// per-connection bounded writer queues (cap 64); tests record the pairs.
/// On error the actor logs and drops — connection teardown is the net
/// layer's job (it posts `worker_disconnected`).
pub const Outbound = struct {
    ctx: *anyopaque,
    sendFn: *const fn (ctx: *anyopaque, to: WorkerId, frame: []const u8) SendError!void,

    pub fn send(self: Outbound, to: WorkerId, frame: []const u8) SendError!void {
        return self.sendFn(self.ctx, to, frame);
    }
};

pub const Command = union(enum) {
    worker_connected: WorkerId,
    worker_disconnected: WorkerId,
    frame: Frame,
    tick: i64, // now_ms
    shutdown,
    // Channel sync bridge (T1): registry ops must run on the kernel thread,
    // but endpoints are cross-thread objects. The op structs live on the
    // calling thread's stack; the kernel thread fills the slot and sets the
    // event. Callers MUST NOT invoke these from the kernel thread (deadlock).
    channel_create: *ChannelCreateOp,
    channel_take_sender: *ChannelTakeSenderOp,
    channel_take_receiver: *ChannelTakeReceiverOp,

    pub const Frame = struct {
        from: WorkerId,
        parsed: json.Parsed(protocol.Message),
        now_ms: i64,
    };
};

pub const CreatedChannel = struct {
    writer: channel_mod.Ref,
    reader: channel_mod.Ref,
};

pub const ChannelCreateOp = struct {
    capacity: usize,
    owner: WorkerId,
    event: sync.ResetEvent = .{},
    /// null after event.set() means OOM (or kernel shutdown drain).
    /// Ref slices are owned by the channels registry — valid until reap.
    result: ?CreatedChannel = null,
};

pub const ChannelTakeError = error{ NotFound, BadKey, AlreadyTaken, Shutdown };

pub const ChannelTakeSenderOp = struct {
    id: []const u8, // caller-owned; caller blocks, so stack slices are safe
    key: []const u8,
    event: sync.ResetEvent = .{},
    result: union(enum) { pending, ok: channel_mod.Sender, err: ChannelTakeError } = .pending,
};

pub const ChannelTakeReceiverOp = struct {
    id: []const u8,
    key: []const u8,
    event: sync.ResetEvent = .{},
    result: union(enum) { pending, ok: channel_mod.Receiver, err: ChannelTakeError } = .pending,
};

pub const Config = struct {
    invoke_timeout_ms: i64 = 30_000,
    ack_timeout_ms: i64 = 10_000,
    channel_ttl_ms: i64 = 300_000,
    inbox_capacity: usize = 1024,
    /// Per-function deadline policy, matched by function-id prefix (first
    /// match wins; fallback `invoke_timeout_ms`). The embedder supplies the
    /// naming — the kernel stays worker-agnostic. Motivation: one global
    /// timeout cannot serve both a whole-mission blocking call and the
    /// provider calls inside it. Entries must outlive the actor.
    invoke_timeout_overrides: []const TimeoutOverride = &.{},
};

pub const TimeoutOverride = struct {
    prefix: []const u8,
    timeout_ms: i64,
};

/// Drain-path cleanup: frames own memory; bridge ops have a blocked caller
/// that must be woken (with a shutdown-shaped result) or it hangs forever.
pub fn freeCommand(cmd: Command) void {
    switch (cmd) {
        .frame => |f| f.parsed.deinit(),
        .channel_create => |op| op.event.set(), // result stays null
        .channel_take_sender => |op| {
            op.result = .{ .err = error.Shutdown };
            op.event.set();
        },
        .channel_take_receiver => |op| {
            op.result = .{ .err = error.Shutdown };
            op.event.set();
        },
        else => {},
    }
}
