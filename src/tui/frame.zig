//! Scrollback-flow line renderer, ported from zot's DrawLog. The logical
//! buffer is chat ++ bottom ++ one margin row. Chat rows scroll into the
//! terminal's own scrollback via \r\n and are never re-addressed; only the
//! changed row range is repainted in place. A change above the visible
//! viewport cannot be patched and forces a full clear + replay. Frames are
//! wrapped in synchronized output (?2026) so terminals present them
//! atomically. Wire invariant: the renderer tracks `hardware_row` (logical
//! row the cursor sits on) and `viewport_top` (first logical row still on
//! screen) — every emitted cursor move must keep these in sync with the
//! real terminal, or every subsequent frame lands on the wrong rows.

const std = @import("std");
const term = @import("term.zig");
const width = @import("width.zig");

pub const Renderer = struct {
    gpa: std.mem.Allocator,
    out: term.Terminal,
    cols: usize = 0,
    rows: usize = 0,
    /// Last frame's logical lines, truncated; entries owned by gpa.
    prev: std.ArrayList([]u8) = .empty,
    viewport_top: usize = 0,
    hardware_row: usize = 0,
    initialized: bool = false,
    /// Set by invalidate/resize: the next full draw must clear the screen
    /// (a first-ever draw must NOT — it appends below the shell prompt).
    needs_clear: bool = false,

    pub fn init(gpa: std.mem.Allocator, out: term.Terminal) Renderer {
        const size = out.size();
        return .{ .gpa = gpa, .out = out, .cols = size.cols, .rows = size.rows };
    }

    pub fn deinit(self: *Renderer) void {
        self.freePrev();
        self.prev.deinit(self.gpa);
        self.* = undefined;
    }

    fn freePrev(self: *Renderer) void {
        for (self.prev.items) |line| self.gpa.free(line);
        self.prev.clearRetainingCapacity();
    }

    /// Force a full repaint (with clear) on the next drawLog.
    pub fn invalidate(self: *Renderer) void {
        self.initialized = false;
        self.needs_clear = true;
    }

    /// Re-query the terminal size; a change invalidates the frame.
    pub fn resizeIfNeeded(self: *Renderer) void {
        const size = self.out.size();
        if (size.cols != self.cols or size.rows != self.rows) {
            self.cols = size.cols;
            self.rows = size.rows;
            self.invalidate();
        }
    }

    pub fn drawLog(
        self: *Renderer,
        chat: []const []const u8,
        bottom: []const []const u8,
    ) std.mem.Allocator.Error!void {
        if (self.cols == 0 or self.rows == 0) return;

        // Build this frame's logical lines (truncated, gpa-owned). Ownership
        // transfers to self.prev at the end of the call.
        var lines: std.ArrayList([]u8) = .empty;
        errdefer {
            for (lines.items) |l| self.gpa.free(l);
            lines.deinit(self.gpa);
        }
        try lines.ensureTotalCapacity(self.gpa, chat.len + bottom.len + 1);
        for (chat) |line| lines.appendAssumeCapacity(try width.truncateToWidth(self.gpa, line, self.cols));
        for (bottom) |line| lines.appendAssumeCapacity(try width.truncateToWidth(self.gpa, line, self.cols));
        // Renderer-owned margin row below the band keeps the last content
        // row off the terminal's bottom edge.
        lines.appendAssumeCapacity(try self.gpa.dupe(u8, ""));

        // Idle no-op fast path: identical frame emits zero bytes.
        if (self.initialized and self.sameAsPrev(lines.items)) {
            for (lines.items) |l| self.gpa.free(l);
            lines.deinit(self.gpa);
            return;
        }

        var w: std.ArrayList(u8) = .empty;
        defer w.deinit(self.gpa);
        try w.appendSlice(self.gpa, term.esc.sync_on);
        try w.appendSlice(self.gpa, term.esc.hide_cursor);

        if (!self.initialized or self.prev.items.len == 0) {
            try self.writeFull(&w, lines.items, self.needs_clear);
        } else {
            try self.writeDiff(&w, lines.items);
        }

        try w.appendSlice(self.gpa, term.esc.sync_off);
        self.out.write(w.items);

        self.freePrev();
        self.prev.deinit(self.gpa);
        self.prev = lines;
        self.initialized = true;
        self.needs_clear = false;
    }

    fn sameAsPrev(self: *const Renderer, lines: []const []u8) bool {
        if (lines.len != self.prev.items.len) return false;
        for (lines, self.prev.items) |a, b| {
            if (!std.mem.eql(u8, a, b)) return false;
        }
        return true;
    }

    fn emitRow(self: *Renderer, w: *std.ArrayList(u8), line: []const u8) !void {
        try w.appendSlice(self.gpa, term.esc.sgr_reset);
        try w.appendSlice(self.gpa, term.esc.clear_line);
        try w.appendSlice(self.gpa, line);
    }

    fn writeFull(self: *Renderer, w: *std.ArrayList(u8), lines: []const []u8, clear: bool) !void {
        var buf: [32]u8 = undefined;
        if (clear) {
            try w.appendSlice(self.gpa, "\x1b[2J");
            try w.appendSlice(self.gpa, term.esc.moveTo(&buf, 1, 1));
        }
        for (lines, 0..) |line, idx| {
            if (idx > 0) try w.appendSlice(self.gpa, "\r\n");
            try self.emitRow(w, line);
        }
        self.hardware_row = lines.len - 1;
        self.viewport_top = if (lines.len > self.rows) lines.len - self.rows else 0;
    }

    fn writeDiff(self: *Renderer, w: *std.ArrayList(u8), lines: []const []u8) !void {
        const old = self.prev.items;
        var buf: [32]u8 = undefined;

        var first_changed: ?usize = null;
        var last_changed: usize = 0;
        const max_len = @max(lines.len, old.len);
        var idx: usize = 0;
        while (idx < max_len) : (idx += 1) {
            const old_line: []const u8 = if (idx < old.len) old[idx] else "";
            const new_line: []const u8 = if (idx < lines.len) lines[idx] else "";
            if (!std.mem.eql(u8, old_line, new_line)) {
                if (first_changed == null) first_changed = idx;
                last_changed = idx;
            }
        }
        // Grown buffer: even if the appended rows equal the implicit ""
        // past the old end, the hardware cursor must advance past them.
        if (lines.len > old.len) {
            if (first_changed == null) first_changed = old.len;
            last_changed = @max(last_changed, lines.len - 1);
        }
        const first = first_changed orelse return;

        if (first < self.viewport_top) {
            // Changes above the visible viewport cannot be patched.
            try self.writeFull(w, lines, true);
            return;
        }

        var viewport_top = self.viewport_top;
        var hardware_row = self.hardware_row;
        const prev_viewport_bottom = viewport_top + self.rows - 1;
        // Pure append past the old end: start from the last old row and
        // scroll down with \r\n instead of addressing a row that does not
        // exist on screen yet.
        const append_start = lines.len > old.len and first == old.len and first > 0;
        const move_target = if (append_start) first - 1 else first;

        if (move_target > prev_viewport_bottom) {
            // Target is below the screen: drop to the bottom row, then
            // scroll the viewport down with newlines.
            const screen_row = @min(hardware_row -| viewport_top, self.rows - 1);
            const to_bottom = self.rows - 1 - screen_row;
            if (to_bottom > 0) try w.appendSlice(self.gpa, term.esc.cursorDown(&buf, to_bottom));
            const scroll = move_target - prev_viewport_bottom;
            var s: usize = 0;
            while (s < scroll) : (s += 1) try w.appendSlice(self.gpa, "\r\n");
            viewport_top += scroll;
            hardware_row = move_target;
        }

        const screen_row = hardware_row -| viewport_top;
        const target_screen_row = move_target - viewport_top;
        if (target_screen_row > screen_row) {
            try w.appendSlice(self.gpa, term.esc.cursorDown(&buf, target_screen_row - screen_row));
        } else if (target_screen_row < screen_row) {
            try w.appendSlice(self.gpa, term.esc.cursorUp(&buf, screen_row - target_screen_row));
        }
        try w.appendSlice(self.gpa, if (append_start) "\r\n" else "\r");

        const render_end = @min(last_changed, lines.len - 1);
        idx = first;
        while (idx <= render_end) : (idx += 1) {
            if (idx > first) try w.appendSlice(self.gpa, "\r\n");
            try self.emitRow(w, lines[idx]);
        }
        var final_row = render_end;

        if (old.len > lines.len) {
            const extra = old.len - lines.len;
            if (extra > self.rows) {
                try self.writeFull(w, lines, true);
                return;
            }
            // Clear the rows the shrunken buffer vacated, then return.
            var e: usize = 0;
            while (e < extra) : (e += 1) {
                try w.appendSlice(self.gpa, term.esc.cursorDown(&buf, 1));
                try w.appendSlice(self.gpa, "\r");
                try w.appendSlice(self.gpa, term.esc.sgr_reset);
                try w.appendSlice(self.gpa, term.esc.clear_line);
                final_row += 1;
            }
            try w.appendSlice(self.gpa, term.esc.cursorUp(&buf, extra));
            final_row -= extra;
        }

        self.hardware_row = final_row;
        self.viewport_top = viewport_top;
        if (self.hardware_row + 1 > self.rows) {
            self.viewport_top = @max(self.viewport_top, self.hardware_row + 1 - self.rows);
        }
    }
};

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

const Harness = struct {
    fake: term.FakeTerm,
    r: Renderer,

    fn init(cols: usize, rows: usize) Harness {
        var h = Harness{ .fake = term.FakeTerm.init(testing.allocator), .r = undefined };
        h.fake.fixed = .{ .cols = cols, .rows = rows };
        return h;
    }

    fn renderer(self: *Harness) *Renderer {
        self.r = Renderer.init(testing.allocator, self.fake.terminal());
        return &self.r;
    }

    fn deinit(self: *Harness) void {
        self.r.deinit();
        self.fake.deinit();
    }
};

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, i, needle)) |at| {
        n += 1;
        i = at + needle.len;
    }
    return n;
}

test "first draw emits every line without clearing the screen" {
    var h = Harness.init(80, 24);
    const r = h.renderer();
    defer h.deinit();

    try r.drawLog(&.{"chat one"}, &.{"status"});
    const out = h.fake.written();
    try testing.expect(std.mem.indexOf(u8, out, "chat one") != null);
    try testing.expect(std.mem.indexOf(u8, out, "status") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[2J") == null);
    // chat before bottom in the byte stream
    try testing.expect(std.mem.indexOf(u8, out, "chat one").? < std.mem.indexOf(u8, out, "status").?);
}

test "frames are bracketed by synchronized output and cursor hide" {
    var h = Harness.init(80, 24);
    const r = h.renderer();
    defer h.deinit();

    try r.drawLog(&.{"a"}, &.{"b"});
    const out = h.fake.written();
    try testing.expect(std.mem.startsWith(u8, out, term.esc.sync_on ++ term.esc.hide_cursor));
    try testing.expect(std.mem.endsWith(u8, out, term.esc.sync_off));
}

test "identical redraw emits zero bytes" {
    var h = Harness.init(80, 24);
    const r = h.renderer();
    defer h.deinit();

    try r.drawLog(&.{"a"}, &.{"b"});
    h.fake.clear();
    try r.drawLog(&.{"a"}, &.{"b"});
    try testing.expectEqual(@as(usize, 0), h.fake.written().len);
}

test "appending a chat line never re-addresses earlier chat rows" {
    var h = Harness.init(80, 24);
    const r = h.renderer();
    defer h.deinit();

    try r.drawLog(&.{"first chat line"}, &.{"band"});
    h.fake.clear();
    try r.drawLog(&.{ "first chat line", "second chat line" }, &.{"band"});
    const out = h.fake.written();
    try testing.expect(std.mem.indexOf(u8, out, "second chat line") != null);
    try testing.expect(std.mem.indexOf(u8, out, "first chat line") == null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[2J") == null);
}

test "bottom-only change moves the cursor up and never touches chat rows" {
    var h = Harness.init(80, 24);
    const r = h.renderer();
    defer h.deinit();

    try r.drawLog(&.{"chat row"}, &.{ "band one", "band two" });
    h.fake.clear();
    try r.drawLog(&.{"chat row"}, &.{ "band one", "band CHANGED" });
    const out = h.fake.written();
    try testing.expect(std.mem.indexOf(u8, out, "band CHANGED") != null);
    try testing.expect(std.mem.indexOf(u8, out, "chat row") == null);
    try testing.expect(std.mem.indexOf(u8, out, "band one") == null);
    // Repaints in place via a cursor-up move, not a scroll.
    try testing.expect(std.mem.indexOf(u8, out, "A") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[2J") == null);
}

test "a change above the viewport forces a full clear and replay" {
    var h = Harness.init(80, 4);
    const r = h.renderer();
    defer h.deinit();

    // 8 chat rows on a 4-row screen: rows 0..5 are above the viewport.
    var chat: [8][]const u8 = undefined;
    var bufs: [8][16]u8 = undefined;
    for (0..8) |i| chat[i] = std.fmt.bufPrint(&bufs[i], "row {d}", .{i}) catch unreachable;
    try r.drawLog(&chat, &.{"band"});
    h.fake.clear();

    chat[0] = "row 0 CHANGED";
    try r.drawLog(&chat, &.{"band"});
    const out = h.fake.written();
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[2J") != null);
    try testing.expect(std.mem.indexOf(u8, out, "row 0 CHANGED") != null);
    try testing.expect(std.mem.indexOf(u8, out, "row 7") != null);
}

test "shrinking the bottom band erases the vacated rows" {
    var h = Harness.init(80, 24);
    const r = h.renderer();
    defer h.deinit();

    try r.drawLog(&.{"chat"}, &.{ "band one", "band two", "band three" });
    h.fake.clear();
    try r.drawLog(&.{"chat"}, &.{"band one"});
    const out = h.fake.written();
    // Two vacated rows are cleared in place (cursor-down + clear-line pairs)
    // and the frame never grows the scrollback.
    try testing.expect(countOccurrences(out, term.esc.clear_line) >= 2);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[1B") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[2J") == null);
}

test "resize invalidates and repaints from scratch" {
    var h = Harness.init(80, 24);
    const r = h.renderer();
    defer h.deinit();

    try r.drawLog(&.{"chat"}, &.{"band"});
    h.fake.clear();
    h.fake.fixed = .{ .cols = 100, .rows = 30 };
    r.resizeIfNeeded();
    try r.drawLog(&.{"chat"}, &.{"band"});
    const out = h.fake.written();
    // Full repaint with clear: both rows re-emitted.
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[2J") != null);
    try testing.expect(std.mem.indexOf(u8, out, "chat") != null);
    try testing.expect(std.mem.indexOf(u8, out, "band") != null);
}

test "every emitted row is truncated to cols" {
    var h = Harness.init(6, 24);
    const r = h.renderer();
    defer h.deinit();

    try r.drawLog(&.{"世界世界世界"}, &.{"abcdefghij"});
    const out = h.fake.written();
    // 6 cols: three 2-cell runes fit; the rest is clipped.
    try testing.expect(std.mem.indexOf(u8, out, "世界世") != null);
    try testing.expect(std.mem.indexOf(u8, out, "世界世界") == null);
    try testing.expect(std.mem.indexOf(u8, out, "abcdef") != null);
    try testing.expect(std.mem.indexOf(u8, out, "abcdefg") == null);
}

test "growth below the viewport scrolls with newlines instead of addressing offscreen rows" {
    var h = Harness.init(80, 3);
    const r = h.renderer();
    defer h.deinit();

    try r.drawLog(&.{ "r0", "r1" }, &.{"band"});
    h.fake.clear();
    try r.drawLog(&.{ "r0", "r1", "r2", "r3" }, &.{"band"});
    const out = h.fake.written();
    try testing.expect(std.mem.indexOf(u8, out, "r2") != null);
    try testing.expect(std.mem.indexOf(u8, out, "r3") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[2J") == null);
    // The already-scrolled-out rows are not re-emitted.
    try testing.expect(std.mem.indexOf(u8, out, "r0") == null);
}

test "empty bottom band still renders the chat" {
    var h = Harness.init(80, 24);
    const r = h.renderer();
    defer h.deinit();

    try r.drawLog(&.{"only chat"}, &.{});
    try testing.expect(std.mem.indexOf(u8, h.fake.written(), "only chat") != null);
}
