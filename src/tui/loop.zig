//! TUI lifecycle: one render thread over the model + renderer. The Tui does
//! NOT touch the bus or the trace registry — the CLI composes those (it
//! registers the model as a trace sink / delta observer and runs the
//! approval key loop), keeping tui/ free of worker dependencies.
//!
//! Teardown invariant: callers stop() the Tui — which joins the render
//! thread and paints one final frame so the last state survives in
//! scrollback — only AFTER unhooking the model from trace/turn observers,
//! and destroy() only after stop().

const std = @import("std");
const sync = @import("../kernel/sync.zig");
const term = @import("term.zig");
const frame = @import("frame.zig");
const model_mod = @import("model.zig");

/// Animation cadence: spinner/elapsed repaint while idle.
const tick_ms: u64 = 120;
/// Burst coalescing: at most ~60 paints/second under heavy event traffic.
const coalesce_ms: u64 = 16;

fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

pub const Tui = struct {
    gpa: std.mem.Allocator,
    model: model_mod.Model,
    renderer: frame.Renderer,
    out: term.Terminal,
    stop_event: sync.ResetEvent = .{},
    thread: ?std.Thread = null,
    stopped: bool = false,

    /// Heap-allocated so &self.model stays stable for observer callbacks.
    pub fn create(gpa: std.mem.Allocator, out: term.Terminal) error{OutOfMemory}!*Tui {
        const self = try gpa.create(Tui);
        self.* = .{
            .gpa = gpa,
            .model = model_mod.Model.init(gpa, nowMs()),
            .renderer = frame.Renderer.init(gpa, out),
            .out = out,
        };
        return self;
    }

    pub fn start(self: *Tui) !void {
        self.thread = try std.Thread.spawn(.{}, renderLoop, .{self});
    }

    /// Idempotent. Joins the render thread and paints one final frame, then
    /// drops the cursor to a fresh line below the band.
    pub fn stop(self: *Tui) void {
        if (self.stopped) return;
        self.stopped = true;
        self.stop_event.set();
        self.model.dirty.set(); // wake the render wait promptly
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        self.out.write("\r\n");
    }

    /// Call only after stop(). The model must already be unhooked from the
    /// trace sink / delta observer (worker threads may not call in anymore).
    pub fn destroy(self: *Tui) void {
        std.debug.assert(self.stopped);
        self.renderer.deinit();
        self.model.deinit();
        self.stop_event.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    fn renderLoop(self: *Tui) void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        while (true) {
            _ = self.model.dirty.timedWait(tick_ms);
            if (self.stop_event.isSet()) break;
            if (self.stop_event.timedWait(coalesce_ms)) break;
            self.model.dirty.reset();
            self.paint(arena_state.allocator());
            _ = arena_state.reset(.retain_capacity);
        }
        // Final frame: the run's last state must land in scrollback.
        self.paint(arena_state.allocator());
    }

    fn paint(self: *Tui, arena: std.mem.Allocator) void {
        self.renderer.resizeIfNeeded();
        const f = self.model.render(arena, self.renderer.cols, nowMs()) catch return;
        self.renderer.drawLog(f.chat, f.bottom) catch {};
    }
};

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "start/stop joins the render thread and leaves the last frame drawn" {
    var fake = term.FakeTerm.init(testing.allocator);
    defer fake.deinit();
    const tui = try Tui.create(testing.allocator, fake.terminal());
    defer tui.destroy();
    try tui.start();

    tui.model.onEvent(
        \\{"ts":1,"event":"mission","from":"defining","to":"planning","role_turns":0,"tasks_done":0,"tasks":4}
    );
    tui.stop();

    const out = fake.written();
    // The final frame paints the mission transition and the header band.
    try testing.expect(std.mem.indexOf(u8, out, "mission defining → planning") != null);
    try testing.expect(std.mem.indexOf(u8, out, "planning · tasks 0/4") != null);
    try testing.expect(std.mem.indexOf(u8, out, term.esc.sync_on) != null);
    // Cursor parked on a fresh line after teardown.
    try testing.expect(std.mem.endsWith(u8, out, "\r\n"));
}

test "stop is idempotent" {
    var fake = term.FakeTerm.init(testing.allocator);
    defer fake.deinit();
    const tui = try Tui.create(testing.allocator, fake.terminal());
    defer tui.destroy();
    try tui.start();
    tui.stop();
    tui.stop();
    tui.stop();
}

test "model calls after stop are safe until destroy" {
    var fake = term.FakeTerm.init(testing.allocator);
    defer fake.deinit();
    const tui = try Tui.create(testing.allocator, fake.terminal());
    defer tui.destroy();
    try tui.start();
    tui.stop();
    // A straggler worker event between stop() and unhooking must not crash.
    tui.model.onEvent(
        \\{"ts":9,"event":"usage","input_tokens":1,"output_tokens":1}
    );
    tui.model.onDelta("late");
}

test "a pending approval is visible in the painted band" {
    var fake = term.FakeTerm.init(testing.allocator);
    defer fake.deinit();
    const tui = try Tui.create(testing.allocator, fake.terminal());
    defer tui.destroy();
    try tui.start();
    tui.model.setPendingApproval("bash: rm -rf ./scratch");
    tui.stop();
    try testing.expect(std.mem.indexOf(u8, fake.written(), "approve bash: rm -rf ./scratch? [y/N]") != null);
}

test "a never-started tui can still be stopped and destroyed" {
    var fake = term.FakeTerm.init(testing.allocator);
    defer fake.deinit();
    const tui = try Tui.create(testing.allocator, fake.terminal());
    tui.stop();
    tui.destroy();
}
