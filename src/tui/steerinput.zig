//! M6 intervention line editor: the one-line steer input the operator types
//! into while a mission runs. Pure buffer state — Model owns the lock and
//! the dirty event; every mutator reports whether a repaint is needed.

const std = @import("std");

pub const SteerInput = struct {
    /// null = closed.
    buf: ?std.ArrayList(u8) = null,

    pub fn deinit(self: *SteerInput, gpa: std.mem.Allocator) void {
        if (self.buf) |*b| b.deinit(gpa);
        self.buf = null;
    }

    pub fn isOpen(self: *const SteerInput) bool {
        return self.buf != null;
    }

    /// The text typed so far (empty when closed); borrowed, valid until the
    /// next mutation.
    pub fn text(self: *const SteerInput) ?[]const u8 {
        return if (self.buf) |b| b.items else null;
    }

    pub fn open(self: *SteerInput) void {
        if (self.buf == null) self.buf = .empty;
    }

    /// One raw key into the open input; 0x7f/0x08 backspace. Returns false
    /// (no repaint) when closed or the key is non-printable.
    pub fn key(self: *SteerInput, gpa: std.mem.Allocator, k: u8) bool {
        const b = if (self.buf) |*b| b else return false;
        if (k == 0x7f or k == 0x08) {
            if (b.items.len > 0) b.items.len -= 1;
        } else if (k >= 0x20 and k < 0x7f) {
            b.append(gpa, k) catch {};
        } else return false;
        return true;
    }

    pub fn cancel(self: *SteerInput, gpa: std.mem.Allocator) void {
        self.deinit(gpa);
    }

    /// Close the input and hand the text over (gpa-owned, caller frees);
    /// an empty or closed input yields null — nothing to send.
    pub fn take(self: *SteerInput, gpa: std.mem.Allocator) ?[]u8 {
        var b = self.buf orelse return null;
        self.buf = null;
        if (b.items.len == 0) {
            b.deinit(gpa);
            return null;
        }
        return b.toOwnedSlice(gpa) catch {
            b.deinit(gpa);
            return null;
        };
    }
};

const testing = std.testing;

test "closed input: keys are no-ops, take yields null" {
    var s: SteerInput = .{};
    defer s.deinit(testing.allocator);
    try testing.expect(!s.isOpen());
    try testing.expect(!s.key(testing.allocator, 'x'));
    try testing.expectEqual(@as(?[]u8, null), s.take(testing.allocator));
}

test "open, type, backspace edits the buffer" {
    var s: SteerInput = .{};
    defer s.deinit(testing.allocator);
    s.open();
    try testing.expect(s.isOpen());
    try testing.expect(s.key(testing.allocator, 'h'));
    try testing.expect(s.key(testing.allocator, 'i'));
    try testing.expect(s.key(testing.allocator, '!'));
    try testing.expect(s.key(testing.allocator, 0x7f));
    try testing.expectEqualStrings("hi", s.text().?);
    // Non-printable bytes are rejected without touching the buffer.
    try testing.expect(!s.key(testing.allocator, 0x1b));
    try testing.expectEqualStrings("hi", s.text().?);
}

test "backspace on an empty open input stays open and repaints" {
    var s: SteerInput = .{};
    defer s.deinit(testing.allocator);
    s.open();
    try testing.expect(s.key(testing.allocator, 0x08));
    try testing.expect(s.isOpen());
    try testing.expectEqualStrings("", s.text().?);
}

test "take hands ownership and closes; empty take yields null" {
    var s: SteerInput = .{};
    defer s.deinit(testing.allocator);
    s.open();
    _ = s.key(testing.allocator, 'g');
    _ = s.key(testing.allocator, 'o');
    const out = s.take(testing.allocator).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("go", out);
    try testing.expect(!s.isOpen());

    s.open();
    try testing.expectEqual(@as(?[]u8, null), s.take(testing.allocator));
    try testing.expect(!s.isOpen());
}

test "cancel discards; reopening starts blank" {
    var s: SteerInput = .{};
    defer s.deinit(testing.allocator);
    s.open();
    _ = s.key(testing.allocator, 'x');
    s.cancel(testing.allocator);
    try testing.expect(!s.isOpen());
    s.open();
    try testing.expectEqualStrings("", s.text().?);
}
