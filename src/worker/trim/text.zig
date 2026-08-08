//! Pure lossy-but-honest text trimming (U6, docs/specs/trim.md): strip
//! ANSI, collapse blank-line runs, keep head+tail with a marker saying what
//! was dropped. No bus, no cache, no stats -- TrimWorker composes this.

const std = @import("std");

pub const Limits = struct {
    max_bytes: usize = 16 * 1024,
    max_lines: usize = 256,
    head_lines: usize = 96,
    tail_lines: usize = 96,
};

/// Pure trim pass, applied in order: ANSI strip → blank-run collapse →
/// head/tail elision when over max_lines or max_bytes. Under the limits the
/// clean text passes through byte-identical.
pub fn trim(arena: std.mem.Allocator, text: []const u8, limits: Limits) error{OutOfMemory}![]const u8 {
    const stripped = try stripAnsi(arena, text);
    const collapsed = try collapseBlankRuns(arena, stripped);
    return elide(arena, collapsed, limits);
}

/// Drop CSI (ESC [ … final in 0x40-0x7e) and OSC (ESC ] … BEL | ESC \)
/// sequences; a lone ESC is dropped too.
fn stripAnsi(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]const u8 {
    if (std.mem.indexOfScalar(u8, text, 0x1b) == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] != 0x1b) {
            try out.append(arena, text[i]);
            i += 1;
            continue;
        }
        if (i + 1 < text.len and text[i + 1] == '[') {
            i += 2;
            while (i < text.len and !(text[i] >= 0x40 and text[i] <= 0x7e)) i += 1;
            if (i < text.len) i += 1; // the final byte
        } else if (i + 1 < text.len and text[i + 1] == ']') {
            i += 2;
            while (i < text.len) {
                if (text[i] == 0x07) {
                    i += 1;
                    break;
                }
                if (text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '\\') {
                    i += 2;
                    break;
                }
                i += 1;
            }
        } else {
            i += 1;
        }
    }
    return out.items;
}

/// Runs of 3+ blank lines become one; runs of 1-2 stay as they are.
fn collapseBlankRuns(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]const u8 {
    if (std.mem.indexOf(u8, text, "\n\n\n\n") == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var blanks: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, i, '\n');
        const end = nl orelse text.len;
        const line = text[i..end];
        const has_nl = nl != null;
        if (line.len == 0 and has_nl) {
            blanks += 1;
        } else {
            if (blanks > 0) {
                try out.appendNTimes(arena, '\n', if (blanks >= 3) 1 else blanks);
                blanks = 0;
            }
            try out.appendSlice(arena, line);
            if (has_nl) try out.append(arena, '\n');
        }
        i = end + @intFromBool(has_nl);
    }
    if (blanks > 0) try out.appendNTimes(arena, '\n', if (blanks >= 3) 1 else blanks);
    return out.items;
}

fn marker(arena: std.mem.Allocator, lines: usize, bytes: usize) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(arena, "[... zygos trimmed {d} lines ({d} bytes) ...]\n", .{ lines, bytes });
}

fn elide(arena: std.mem.Allocator, text: []const u8, limits: Limits) error{OutOfMemory}![]const u8 {
    const line_count = std.mem.count(u8, text, "\n") + @intFromBool(text.len > 0 and text[text.len - 1] != '\n');
    if (text.len <= limits.max_bytes and line_count <= limits.max_lines) return text;

    // Line-based head/tail elision first.
    if (line_count > limits.head_lines + limits.tail_lines) {
        var starts: std.ArrayList(usize) = .empty; // start offset of every line
        try starts.append(arena, 0);
        for (text, 0..) |b, off| {
            if (b == '\n' and off + 1 < text.len) try starts.append(arena, off + 1);
        }
        const head_end = starts.items[limits.head_lines];
        const tail_start = starts.items[starts.items.len - limits.tail_lines];
        if (head_end < tail_start) {
            const dropped_lines = starts.items.len - limits.head_lines - limits.tail_lines;
            var out: std.ArrayList(u8) = .empty;
            try out.appendSlice(arena, text[0..head_end]);
            try out.appendSlice(arena, try marker(arena, dropped_lines, tail_start - head_end));
            try out.appendSlice(arena, text[tail_start..]);
            if (out.items.len <= limits.max_bytes) return out.items;
            return byteFallback(arena, out.items, limits);
        }
    }
    return byteFallback(arena, text, limits);
}

/// Middle-out byte cut for line-poor oversized text (one giant line, or
/// head+tail still over the cap). Cuts land on UTF-8 boundaries.
fn byteFallback(arena: std.mem.Allocator, text: []const u8, limits: Limits) error{OutOfMemory}![]const u8 {
    if (text.len <= limits.max_bytes) return text;
    const keep = limits.max_bytes / 2;
    var front_end = @min(keep, text.len);
    while (front_end > 0 and (text[front_end] & 0xC0) == 0x80) front_end -= 1;
    var back_start = text.len - @min(keep, text.len);
    while (back_start < text.len and (text[back_start] & 0xC0) == 0x80) back_start += 1;
    if (back_start <= front_end) return text;

    const middle = text[front_end..back_start];
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, text[0..front_end]);
    try out.append(arena, '\n');
    try out.appendSlice(arena, try marker(arena, std.mem.count(u8, middle, "\n"), middle.len));
    try out.appendSlice(arena, text[back_start..]);
    return out.items;
}

const testing = std.testing;

const tiny: Limits = .{ .max_bytes = 200, .max_lines = 10, .head_lines = 3, .tail_lines = 2 };

test "short clean text passes through byte-identical" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const text = "line one\nline two\nline three\n";
    try testing.expectEqualStrings(text, try trim(arena.allocator(), text, .{}));
}

test "ANSI escapes are stripped (CSI colors + OSC title)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const text = "\x1b[31mred\x1b[0m plain \x1b]0;title\x07tail";
    try testing.expectEqualStrings("red plain tail", try trim(arena.allocator(), text, .{}));
}

test "blank-line runs of 3+ collapse to one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const text = "a\n\n\n\n\nb\n\nc\n";
    // 4 blank lines between a and b collapse to one; the single blank
    // between b and c stays.
    try testing.expectEqualStrings("a\n\nb\n\nc\n", try trim(arena.allocator(), text, .{}));
}

test "over max_lines keeps head+tail with a counting marker" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var lb: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        try buf.appendSlice(testing.allocator, std.fmt.bufPrint(&lb, "line-{d}\n", .{i}) catch unreachable);
    }

    const out = try trim(arena.allocator(), buf.items, tiny);
    try testing.expect(std.mem.indexOf(u8, out, "line-0\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "line-2\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "line-18\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "line-19\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "line-9\n") == null); // middle dropped
    try testing.expect(std.mem.indexOf(u8, out, "zygos trimmed 15 lines") != null);
}

test "over max_bytes with few lines still trims" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const long = "x" ** 500; // one line, 500 bytes against max_bytes=200
    const out = try trim(arena.allocator(), long, tiny);
    try testing.expect(out.len < long.len);
    try testing.expect(std.mem.indexOf(u8, out, "zygos trimmed") != null);
}

test "trimmed output respects the byte limit (with marker slack)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var lb: [40]u8 = undefined;
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        try buf.appendSlice(testing.allocator, std.fmt.bufPrint(&lb, "padding-line-{d}\n", .{i}) catch unreachable);
    }

    const out = try trim(arena.allocator(), buf.items, tiny);
    // head 3 + tail 2 short lines + marker sit well under 2x the byte cap.
    try testing.expect(out.len <= tiny.max_bytes * 2);
    try testing.expect(std.mem.indexOf(u8, out, "zygos trimmed") != null);
}

test "trim never splits a UTF-8 sequence on byte fallback" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // One giant line of 3-byte runes — every byte boundary is a hazard.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var i: usize = 0;
    while (i < 300) : (i += 1) try buf.appendSlice(testing.allocator, "€");

    const out = try trim(arena.allocator(), buf.items, tiny);
    try testing.expect(out.len < buf.items.len);
    try testing.expect(std.unicode.utf8ValidateSlice(out));
}
