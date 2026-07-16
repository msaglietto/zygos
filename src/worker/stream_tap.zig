//! Live stream tap — observability for delta kinds that never ride the
//! kernel channel: model thinking/reasoning and streaming tool-call
//! fragments. The channel's Item union is wire format (PROTOCOL.md,
//! human-gated), so these flow through a process-global registry instead,
//! mirroring trace.zig's sink pattern: registered once by the CLI for the
//! TUI, emitted best-effort by the stream assemblers.
//!
//! Fail-open contract: taps return void, bytes are valid only during the
//! call, and emission must never stall or fail a stream. Missions run turns
//! sequentially, so interleaving across concurrent streams is not a concern
//! for the single-mission CLI; a multi-tenant embedding would need per-turn
//! scoping first.

const std = @import("std");
const sync = @import("../kernel/sync.zig");

pub const Kind = enum {
    /// Model reasoning text (anthropic thinking_delta, openai-compatible
    /// reasoning_content) — never part of the terminal message.
    thinking,
    /// A tool call opened on the stream; bytes are the tool name.
    tool_name,
    /// Streaming tool-arguments JSON fragment (partial, unparseable alone).
    tool_args,
};

pub const Tap = struct {
    ctx: *anyopaque,
    onDelta: *const fn (ctx: *anyopaque, kind: Kind, bytes: []const u8) void,
};

var tap_mutex: sync.Mutex = .{};
var taps: [2]?Tap = .{ null, null };
var tap_count = std.atomic.Value(u8).init(0);

/// Returns a token for unregister, or null when all slots are taken.
pub fn register(t: Tap) ?usize {
    tap_mutex.lock();
    defer tap_mutex.unlock();
    for (&taps, 0..) |*slot, i| {
        if (slot.* == null) {
            slot.* = t;
            _ = tap_count.fetchAdd(1, .release);
            return i;
        }
    }
    return null;
}

/// Idempotent; in-flight callbacks finish first (delivery holds the lock).
pub fn unregister(token: usize) void {
    tap_mutex.lock();
    defer tap_mutex.unlock();
    if (taps[token] != null) {
        taps[token] = null;
        _ = tap_count.fetchSub(1, .release);
    }
}

/// Best-effort fan-out; a no-op with nothing registered (lock-free check).
pub fn emit(kind: Kind, bytes: []const u8) void {
    if (tap_count.load(.acquire) == 0) return;
    tap_mutex.lock();
    defer tap_mutex.unlock();
    for (taps) |maybe| {
        if (maybe) |t| t.onDelta(t.ctx, kind, bytes);
    }
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

const Capture = struct {
    gpa: std.mem.Allocator,
    kinds: std.ArrayList(Kind) = .empty,
    chunks: std.ArrayList([]u8) = .empty,

    fn onDelta(ctx: *anyopaque, kind: Kind, bytes: []const u8) void {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        const copy = self.gpa.dupe(u8, bytes) catch return;
        self.chunks.append(self.gpa, copy) catch {
            self.gpa.free(copy);
            return;
        };
        self.kinds.append(self.gpa, kind) catch {};
    }

    fn tap(self: *Capture) Tap {
        return .{ .ctx = @ptrCast(self), .onDelta = &onDelta };
    }

    fn deinit(self: *Capture) void {
        for (self.chunks.items) |c| self.gpa.free(c);
        self.chunks.deinit(self.gpa);
        self.kinds.deinit(self.gpa);
    }
};

test "emit with no taps is a no-op; a registered tap sees kind and bytes" {
    emit(.thinking, "dropped");

    var cap = Capture{ .gpa = testing.allocator };
    defer cap.deinit();
    const token = register(cap.tap()) orelse return error.NoSlot;
    defer unregister(token);

    emit(.thinking, "let me check");
    emit(.tool_name, "bash");
    emit(.tool_args, "{\"comm");

    try testing.expectEqual(@as(usize, 3), cap.chunks.items.len);
    try testing.expectEqual(Kind.thinking, cap.kinds.items[0]);
    try testing.expectEqualStrings("let me check", cap.chunks.items[0]);
    try testing.expectEqual(Kind.tool_name, cap.kinds.items[1]);
    try testing.expectEqual(Kind.tool_args, cap.kinds.items[2]);
}

test "unregister stops delivery and is idempotent; slots are reusable" {
    var cap = Capture{ .gpa = testing.allocator };
    defer cap.deinit();
    const token = register(cap.tap()) orelse return error.NoSlot;
    unregister(token);
    unregister(token);
    emit(.thinking, "after");
    try testing.expectEqual(@as(usize, 0), cap.chunks.items.len);

    const token2 = register(cap.tap()) orelse return error.NoSlot;
    defer unregister(token2);
    emit(.thinking, "again");
    try testing.expectEqual(@as(usize, 1), cap.chunks.items.len);
}
