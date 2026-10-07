//! Ingestion scrubber for terminal-bound bytes (model deltas, thinking,
//! tool output previews, approval summaries, captured log lines).
//!
//! Threat: any bytes the model relays — a fetched page, a file it `cat`s,
//! bash stdout — reach `write(fd2, …)` otherwise verbatim. CSI/OSC there
//! means terminal escape injection (OSC-52 clipboard, hyperlinks, title and
//! alt-screen hijack); raw C0 (\r especially) desyncs the renderer's row
//! accounting. The TUI's own sequences are emitted by frame/term and never
//! pass through here — scrub at ingestion, never at the sink.
//!
//! Kept: \n (layout), printable bytes, valid non-C1 UTF-8 (width.zig
//! measures it safely). Normalized: \t → one space. Dropped: every escape
//! sequence, all other C0, DEL, C1 controls (as 2-byte UTF-8).

const std = @import("std");

/// Append `s` to `out` with unsafe bytes removed/normalized.
pub fn appendScrubbed(gpa: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) std.mem.Allocator.Error!void {
    var i: usize = 0;
    while (i < s.len) {
        const b = s[i];
        if (b == 0x1b) {
            i = skipEscape(s, i);
            continue;
        }
        if (b == '\n') {
            try out.append(gpa, '\n');
            i += 1;
            continue;
        }
        if (b == '\t') {
            try out.append(gpa, ' ');
            i += 1;
            continue;
        }
        if (b < 0x20 or b == 0x7f) {
            i += 1;
            continue;
        }
        if (b >= 0x80) {
            const len = std.unicode.utf8ByteSequenceLength(b) catch {
                i += 1;
                continue;
            };
            if (len > s.len - i) break;
            const cp = std.unicode.utf8Decode(s[i..][0..len]) catch {
                i += 1;
                continue;
            };
            if (cp < 0x80 or cp > 0x9f) try out.appendSlice(gpa, s[i..][0..len]);
            i += len;
            continue;
        }
        try out.append(gpa, b);
        i += 1;
    }
}

/// Owned scrubbed copy.
pub fn scrub(gpa: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try appendScrubbed(gpa, &out, s);
    return out.toOwnedSlice(gpa);
}

/// Index just past one escape sequence starting at `i` (s[i] == 0x1b).
/// Unterminated sequences consume the rest of the input — nothing escapes.
fn skipEscape(s: []const u8, i: usize) usize {
    if (i + 1 >= s.len) return s.len;
    switch (s[i + 1]) {
        '[' => { // CSI: params until a final byte 0x40..0x7e
            var j = i + 2;
            while (j < s.len) : (j += 1) {
                if (s[j] >= 0x40 and s[j] <= 0x7e) return j + 1;
            }
            return s.len;
        },
        ']' => return skipUntil(s, i + 2), // OSC: BEL or ST terminated
        'P', '_', '^' => return skipUntilSt(s, i + 2), // DCS/APC/PM: ST only
        else => return i + 2, // two-byte escape (ESC M, ESC 7, …)
    }
}

/// OSC body: ends at BEL or ESC \ (ST).
fn skipUntil(s: []const u8, from: usize) usize {
    var j = from;
    while (j < s.len) : (j += 1) {
        if (s[j] == 0x07) return j + 1;
        if (s[j] == 0x1b and j + 1 < s.len and s[j + 1] == '\\') return j + 2;
    }
    return s.len;
}

/// DCS/APC/PM body: ends at ESC \ (ST) only.
fn skipUntilSt(s: []const u8, from: usize) usize {
    var j = from;
    while (j < s.len) : (j += 1) {
        if (s[j] == 0x1b and j + 1 < s.len and s[j + 1] == '\\') return j + 2;
    }
    return s.len;
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

fn check(input: []const u8, want: []const u8) !void {
    const got = try scrub(testing.allocator, input);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "scrub strips SGR/CIS color and cursor sequences, keeps the text" {
    try check("\x1b[31mred\x1b[0m text", "red text");
    try check("a\x1b[2K\rb", "ab");
    try check("\x1b[?1049hhijack\x1b[?1049l", "hijack");
    try check("\x1b[10;20Hhome", "home");
}

test "scrub strips OSC (52 clipboard, 8 hyperlinks, title), BEL and ST forms" {
    try check("\x1b]52;c.aG90dGVzdA==\x07clipped", "clipped");
    try check("\x1b]8;;https://evil.example\x1b\\link\x1b]8;;\x1b\\", "link");
    try check("before\x1b]0;owned title\x07after", "beforeafter");
}

test "scrub strips DCS/APC/PM and two-byte escapes" {
    try check("\x1bP1;2q payload\x1b\\data", "data");
    try check("x\x1b_y\x1b\\z", "xz"); // APC payload 'y' dropped
    try check("a\x1bMb", "ab");
}

test "scrub drops C0 controls and DEL, keeps newline, tab becomes space" {
    try check("line1\nline2", "line1\nline2");
    try check("col\x08back", "colback");
    try check("be\x07ll", "bell");
    try check("a\rb", "ab");
    try check("x\x00y", "xy");
    try check("end\x7f.", "end.");
    try check("tab\there", "tab here");
}

test "scrub drops C1 controls encoded as UTF-8, keeps real UTF-8" {
    try check("keep \xe2\x9c\x93 and \xc3\xa9", "keep \xe2\x9c\x93 and \xc3\xa9");
    try check("a\xc2\x9bb", "ab"); // C1 CSI (0x9b)
    try check("a\xc2\x85b", "ab"); // C1 NEL
}

test "scrub drops a trailing or lone ESC and unterminated sequences" {
    try check("dangling\x1b", "dangling");
    try check("open\x1b[31", "open"); // CSI with no final byte
    try check("open\x1b]52;p", "open"); // OSC with no terminator
    try check("\x1b", "");
}

test "scrub leaves plain ASCII and JSON alone" {
    try check(
        "{\"command\":\"echo hello > greeting.txt\",\"exit_code\":0}",
        "{\"command\":\"echo hello > greeting.txt\",\"exit_code\":0}",
    );
    try check("", "");
}

test "scrub refuses raw C1 bytes and split UTF-8 control encodings" {
    try check("a\x9bb", "ab");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try appendScrubbed(testing.allocator, &out, "a\xc2");
    try appendScrubbed(testing.allocator, &out, "\x9bb");
    try testing.expectEqualStrings("ab", out.items);
}
