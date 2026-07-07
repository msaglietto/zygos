//! Incremental Server-Sent Events (text/event-stream) decoder.
//!
//! Pure std-only: no sockets, no clocks, no external imports. Bytes arrive
//! in arbitrary chunks via `feed`; complete events are popped via `next`.
//! The decoder buffers incomplete lines internally and never emits an event
//! until its terminating blank line has arrived.

const std = @import("std");

/// A decoded SSE event. Slices are owned by the `Decoder` and valid ONLY
/// until the next call to `next()` or `feed()` — callers must copy what
/// they intend to keep.
pub const Event = struct {
    /// null when no `event:` field was present.
    event: ?[]const u8,
    /// Multi-line `data:` fields joined with '\n'. Empty string if no data lines.
    data: []const u8,
    /// null when no `id:` field was present.
    id: ?[]const u8,
};

pub const Decoder = struct {
    gpa: std.mem.Allocator,
    /// Raw byte buffer — unconsumed bytes from the stream.
    raw: std.ArrayList(u8) = .empty,
    /// Parse cursor into `raw`.
    pos: usize = 0,

    // --- In-progress event field storage ---------------------------------
    // Field values are copied here from `raw` so that compacting `raw`
    // never invalidates a returned `Event`'s slices.
    ev_name: std.ArrayList(u8) = .empty,
    ev_data: std.ArrayList(u8) = .empty,
    ev_id: std.ArrayList(u8) = .empty,
    has_event: bool = false,
    has_id: bool = false,
    /// Tracks whether any `data:` line was seen (for '\n' join logic).
    has_data: bool = false,
    /// Any non-comment, non-blank line sets this — only events with at
    /// least one field are emitted.
    has_fields: bool = false,

    // True when ev_* buffers hold a previously returned event.  The next
    // call to next()/feed() must clear them before reuse, invalidating the
    // old slices per the API contract.
    ev_returned: bool = false,

    pub fn init(gpa: std.mem.Allocator) Decoder {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Decoder) void {
        self.raw.deinit(self.gpa);
        self.ev_name.deinit(self.gpa);
        self.ev_data.deinit(self.gpa);
        self.ev_id.deinit(self.gpa);
    }

    /// Append raw bytes from the stream.  Arbitrary chunk boundaries are
    /// fine — the decoder just buffers.
    pub fn feed(self: *Decoder, bytes: []const u8) error{OutOfMemory}!void {
        if (self.ev_returned) self.resetEvent();
        try self.raw.appendSlice(self.gpa, bytes);
    }

    /// Pop the next complete event, or null if none is ready yet.
    /// Returned slices are owned by the decoder and valid ONLY until the
    /// next call to next() or feed().
    pub fn next(self: *Decoder) error{OutOfMemory}!?Event {
        if (self.ev_returned) self.resetEvent();
        self.compact();

        while (self.pos < self.raw.items.len) {
            const b = self.raw.items[self.pos];

            // --- Empty-line dispatch (buffer starts with a terminator) -----
            // Per WHATWG: \r at the start of the remaining buffer is treated
            // as a bare-\r line ending even when it is the final byte, so a
            // trailing bare-\r empty line is recognised without more data.
            if (b == '\n') {
                self.pos += 1;
                if (self.has_fields) {
                    self.ev_returned = true;
                    return self.makeEvent();
                }
                self.resetEvent();
                continue;
            }
            if (b == '\r') {
                if (self.pos + 1 < self.raw.items.len and
                    self.raw.items[self.pos + 1] == '\n')
                {
                    self.pos += 2; // CRLF
                } else {
                    self.pos += 1; // bare CR
                }
                if (self.has_fields) {
                    self.ev_returned = true;
                    return self.makeEvent();
                }
                self.resetEvent();
                continue;
            }

            // --- Non-empty line: locate its terminator ---------------------
            const line_start = self.pos;
            var i = self.pos;
            while (i < self.raw.items.len) : (i += 1) {
                if (self.raw.items[i] == '\n' or self.raw.items[i] == '\r') break;
            }
            if (i >= self.raw.items.len) break; // incomplete line — hold

            // Advance past the line and its terminator.
            if (self.raw.items[i] == '\n') {
                self.pos = i + 1;
            } else {
                // '\r'
                if (i + 1 < self.raw.items.len and self.raw.items[i + 1] == '\n') {
                    self.pos = i + 2; // CRLF
                } else if (i + 1 < self.raw.items.len) {
                    self.pos = i + 1; // bare CR followed by other data
                } else {
                    break; // '\r' at end of buffer — might be CRLF, hold
                }
            }

            try self.processLine(self.raw.items[line_start..i]);
        }

        return null;
    }

    /// Parse one field line and accumulate into the in-progress event.
    fn processLine(self: *Decoder, line: []const u8) error{OutOfMemory}!void {
        // Comment lines start with ':'.
        if (line.len > 0 and line[0] == ':') return;

        self.has_fields = true;

        const colon = std.mem.indexOfScalar(u8, line, ':');
        const name = if (colon) |c| line[0..c] else line;
        var value = if (colon) |c| line[c + 1 ..] else "";

        // Strip exactly ONE leading space after the colon.
        if (value.len > 0 and value[0] == ' ') value = value[1..];

        if (std.mem.eql(u8, name, "data")) {
            if (self.has_data) try self.ev_data.append(self.gpa, '\n');
            try self.ev_data.appendSlice(self.gpa, value);
            self.has_data = true;
        } else if (std.mem.eql(u8, name, "event")) {
            self.ev_name.clearRetainingCapacity();
            try self.ev_name.appendSlice(self.gpa, value);
            self.has_event = true;
        } else if (std.mem.eql(u8, name, "id")) {
            self.ev_id.clearRetainingCapacity();
            try self.ev_id.appendSlice(self.gpa, value);
            self.has_id = true;
        }
        // "retry" and unknown field names: parse-and-ignore.
    }

    /// Build the Event struct from current accumulator state.
    /// Slices point into the decoder's own ArrayLists.
    fn makeEvent(self: *Decoder) Event {
        return .{
            .event = if (self.has_event) self.ev_name.items else null,
            .data = self.ev_data.items,
            .id = if (self.has_id) self.ev_id.items else null,
        };
    }

    /// Clear all in-progress field buffers and flags.
    fn resetEvent(self: *Decoder) void {
        self.ev_name.clearRetainingCapacity();
        self.ev_data.clearRetainingCapacity();
        self.ev_id.clearRetainingCapacity();
        self.has_event = false;
        self.has_id = false;
        self.has_data = false;
        self.has_fields = false;
        self.ev_returned = false;
    }

    /// Move unconsumed bytes to the front of `raw` so the buffer doesn't
    /// grow without bound.  Safe because returned Event slices point into
    /// ev_* ArrayLists, not into `raw`.
    fn compact(self: *Decoder) void {
        if (self.pos == 0) return;
        const remaining = self.raw.items[self.pos..];
        if (remaining.len > 0) {
            std.mem.copyForwards(u8, self.raw.items[0..remaining.len], remaining);
        }
        self.raw.items.len = remaining.len;
        self.pos = 0;
    }
};

// =========================================================================
// TESTS — written first per TDD, implementation follows once these go red.
// =========================================================================

test "single event with event: and data: fields decodes" {
    var d = Decoder.init(std.testing.allocator);
    defer d.deinit();

    try d.feed("event: update\ndata: hello\n\n");
    const ev = try d.next();
    try std.testing.expect(ev != null);
    try std.testing.expectEqualStrings("update", ev.?.event.?);
    try std.testing.expectEqualStrings("hello", ev.?.data);
    try std.testing.expect(ev.?.id == null);
}

test "two events in one feed decode in order" {
    var d = Decoder.init(std.testing.allocator);
    defer d.deinit();

    try d.feed("event: first\ndata: a\n\nevent: second\ndata: b\n\n");

    const ev1 = try d.next();
    try std.testing.expect(ev1 != null);
    try std.testing.expectEqualStrings("first", ev1.?.event.?);
    try std.testing.expectEqualStrings("a", ev1.?.data);

    const ev2 = try d.next();
    try std.testing.expect(ev2 != null);
    try std.testing.expectEqualStrings("second", ev2.?.event.?);
    try std.testing.expectEqualStrings("b", ev2.?.data);

    try std.testing.expect((try d.next()) == null);
}

test "event split across many tiny feeds (feed one byte at a time) decodes identically" {
    var d = Decoder.init(std.testing.allocator);
    defer d.deinit();

    const input = "event: update\ndata: hello\n\n";
    var got: ?Event = null;
    for (input) |b| {
        try d.feed(&.{b});
        const ev = try d.next();
        if (ev != null) {
            try std.testing.expect(got == null); // exactly one event expected
            got = ev;
        }
    }
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("update", got.?.event.?);
    try std.testing.expectEqualStrings("hello", got.?.data);
    try std.testing.expect(got.?.id == null);
}

test "multi-line data joins with newline" {
    var d = Decoder.init(std.testing.allocator);
    defer d.deinit();

    try d.feed("data: line1\ndata: line2\ndata: line3\n\n");
    const ev = try d.next();
    try std.testing.expect(ev != null);
    try std.testing.expectEqualStrings("line1\nline2\nline3", ev.?.data);
    try std.testing.expect(ev.?.event == null);
    try std.testing.expect(ev.?.id == null);
}

test "CRLF and bare-CR line endings both work" {
    // CRLF endings
    {
        var d = Decoder.init(std.testing.allocator);
        defer d.deinit();
        try d.feed("event: crlf\r\ndata: hello\r\n\r\n");
        const ev = try d.next();
        try std.testing.expect(ev != null);
        try std.testing.expectEqualStrings("crlf", ev.?.event.?);
        try std.testing.expectEqualStrings("hello", ev.?.data);
    }
    // Bare CR endings
    {
        var d = Decoder.init(std.testing.allocator);
        defer d.deinit();
        try d.feed("event: cr\rdata: world\r\r");
        const ev = try d.next();
        try std.testing.expect(ev != null);
        try std.testing.expectEqualStrings("cr", ev.?.event.?);
        try std.testing.expectEqualStrings("world", ev.?.data);
    }
}

test "comment lines and unknown fields are ignored" {
    var d = Decoder.init(std.testing.allocator);
    defer d.deinit();

    try d.feed(": this is a comment\nunknown: field\nevent: real\ndata: payload\n\n");
    const ev = try d.next();
    try std.testing.expect(ev != null);
    try std.testing.expectEqualStrings("real", ev.?.event.?);
    try std.testing.expectEqualStrings("payload", ev.?.data);
    try std.testing.expect(ev.?.id == null);
}

test "data: with no space and data: with space both strip correctly (value equality pinned)" {
    var d = Decoder.init(std.testing.allocator);
    defer d.deinit();

    try d.feed("data:no space\ndata: with space\ndata:  two spaces\n\n");
    const ev = try d.next();
    try std.testing.expect(ev != null);
    try std.testing.expectEqualStrings("no space\nwith space\n two spaces", ev.?.data);
}

test "empty-line-only / comment-only input emits nothing" {
    // Just blank lines.
    {
        var d = Decoder.init(std.testing.allocator);
        defer d.deinit();
        try d.feed("\n\n");
        try std.testing.expect((try d.next()) == null);
    }
    // Only comments then a blank line.
    {
        var d = Decoder.init(std.testing.allocator);
        defer d.deinit();
        try d.feed(": comment\n: another\n\n");
        try std.testing.expect((try d.next()) == null);
    }
}

test "incomplete trailing event is held until the blank line arrives" {
    var d = Decoder.init(std.testing.allocator);
    defer d.deinit();

    try d.feed("data: hello");
    try std.testing.expect((try d.next()) == null);

    try d.feed("\n");
    try std.testing.expect((try d.next()) == null);

    try d.feed("\n");
    const ev = try d.next();
    try std.testing.expect(ev != null);
    try std.testing.expectEqualStrings("hello", ev.?.data);
}

test "slices invalidated contract: copy before next call proves valid-until-next" {
    var d = Decoder.init(std.testing.allocator);
    defer d.deinit();

    // Feed first event and pop it.
    try d.feed("event: a\ndata: aaa\n\n");
    const ev1 = try d.next();
    try std.testing.expect(ev1 != null);

    // Copy values BEFORE the next call (the contract demands this).
    const event_copy = try std.testing.allocator.dupe(u8, ev1.?.event.?);
    defer std.testing.allocator.free(event_copy);
    const data_copy = try std.testing.allocator.dupe(u8, ev1.?.data);
    defer std.testing.allocator.free(data_copy);

    try std.testing.expectEqualStrings("a", event_copy);
    try std.testing.expectEqualStrings("aaa", data_copy);

    // Feed second event and pop it — this invalidates ev1's slices.
    try d.feed("event: b\ndata: bbb\n\n");
    const ev2 = try d.next();
    try std.testing.expect(ev2 != null);
    try std.testing.expectEqualStrings("b", ev2.?.event.?);
    try std.testing.expectEqualStrings("bbb", ev2.?.data);

    // The copies we made earlier are still intact.
    try std.testing.expectEqualStrings("a", event_copy);
    try std.testing.expectEqualStrings("aaa", data_copy);
}

test "no leaks under a 100-event feed/next loop" {
    var d = Decoder.init(std.testing.allocator);
    defer d.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try buf.appendSlice(std.testing.allocator, "data: event\n\n");
    }
    try d.feed(buf.items);

    i = 0;
    while (i < 100) : (i += 1) {
        const ev = try d.next();
        try std.testing.expect(ev != null);
        try std.testing.expectEqualStrings("event", ev.?.data);
    }
    try std.testing.expect((try d.next()) == null);
}

test "anthropic-shaped fixture: decode the exact bytes" {
    var d = Decoder.init(std.testing.allocator);
    defer d.deinit();

    const fixture =
        "event: message_start\n" ++
        "data: {\"type\":\"message_start\"}\n" ++
        "\n" ++
        "event: ping\n" ++
        "data: {}\n" ++
        "\n";
    try d.feed(fixture);

    const ev1 = try d.next();
    try std.testing.expect(ev1 != null);
    try std.testing.expectEqualStrings("message_start", ev1.?.event.?);
    try std.testing.expectEqualStrings("{\"type\":\"message_start\"}", ev1.?.data);
    try std.testing.expect(ev1.?.id == null);

    const ev2 = try d.next();
    try std.testing.expect(ev2 != null);
    try std.testing.expectEqualStrings("ping", ev2.?.event.?);
    try std.testing.expectEqualStrings("{}", ev2.?.data);
    try std.testing.expect(ev2.?.id == null);
}
