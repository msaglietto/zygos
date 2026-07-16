//! ANSI-aware terminal cell-width measurement (wcwidth-lite).
//!
//! Scope: escape sequences (CSI, OSC) measure zero cells; combining marks,
//! variation selectors, and zero-width joiners measure zero; East Asian
//! wide/fullwidth ranges and emoji measure two; everything else measures one.
//! Grapheme clusters (ZWJ emoji, flags) are NOT composed — each code point is
//! measured alone, so a cluster may over-measure. Truncation is therefore
//! conservative: it can clip early but never overflows a row.

const std = @import("std");

const Range = struct { lo: u21, hi: u21 };

/// Code points that occupy no terminal cell.
const zero_ranges = [_]Range{
    .{ .lo = 0x0300, .hi = 0x036F }, // combining diacritics
    .{ .lo = 0x0483, .hi = 0x0489 }, // Cyrillic combining
    .{ .lo = 0x0591, .hi = 0x05BD }, // Hebrew points
    .{ .lo = 0x200B, .hi = 0x200D }, // ZWSP / ZWNJ / ZWJ
    .{ .lo = 0x1AB0, .hi = 0x1AFF }, // combining extended
    .{ .lo = 0x20D0, .hi = 0x20FF }, // combining for symbols
    .{ .lo = 0xFE00, .hi = 0xFE0F }, // variation selectors
    .{ .lo = 0xFEFF, .hi = 0xFEFF }, // BOM / ZWNBSP
};

/// Code points that occupy two terminal cells (East Asian W/F + emoji).
const wide_ranges = [_]Range{
    .{ .lo = 0x1100, .hi = 0x115F }, // Hangul Jamo
    .{ .lo = 0x2E80, .hi = 0xA4CF }, // CJK radicals .. Yi (incl. U+3000 ideographic space)
    .{ .lo = 0xAC00, .hi = 0xD7A3 }, // Hangul syllables
    .{ .lo = 0xF900, .hi = 0xFAFF }, // CJK compat ideographs
    .{ .lo = 0xFE30, .hi = 0xFE4F }, // CJK compat forms
    .{ .lo = 0xFF00, .hi = 0xFF60 }, // fullwidth forms
    .{ .lo = 0xFFE0, .hi = 0xFFE6 }, // fullwidth signs
    .{ .lo = 0x1F300, .hi = 0x1FAFF }, // emoji & pictographs
    .{ .lo = 0x20000, .hi = 0x2FFFD }, // CJK ext B..F
};

fn inRanges(cp: u21, ranges: []const Range) bool {
    for (ranges) |r| {
        if (cp >= r.lo and cp <= r.hi) return true;
    }
    return false;
}

/// Cells one code point occupies: 0, 1, or 2.
pub fn runeWidth(cp: u21) u2 {
    if (cp < 0x20 or (cp >= 0x7F and cp < 0xA0)) return 0; // C0/C1 controls
    if (inRanges(cp, &zero_ranges)) return 0;
    if (inRanges(cp, &wide_ranges)) return 2;
    return 1;
}

/// Byte length of the escape sequence starting at `s[i]` (which must be ESC).
/// CSI runs to its final byte (0x40..0x7E); OSC runs to BEL or ESC-backslash;
/// any other escape is ESC + one byte. Unterminated sequences swallow the rest.
fn escapeLen(s: []const u8, i: usize) usize {
    std.debug.assert(s[i] == 0x1b);
    if (i + 1 >= s.len) return s.len - i;
    switch (s[i + 1]) {
        '[' => {
            var j = i + 2;
            while (j < s.len) : (j += 1) {
                if (s[j] >= 0x40 and s[j] <= 0x7E) return j + 1 - i;
            }
            return s.len - i;
        },
        ']' => {
            var j = i + 2;
            while (j < s.len) : (j += 1) {
                if (s[j] == 0x07) return j + 1 - i;
                if (s[j] == 0x1b and j + 1 < s.len and s[j + 1] == '\\') return j + 2 - i;
            }
            return s.len - i;
        },
        else => return @min(2, s.len - i),
    }
}

/// Cells the string occupies on screen. Escape sequences are zero-width;
/// invalid UTF-8 bytes count one cell each (they render as replacement glyphs).
pub fn visibleWidth(s: []const u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b) {
            i += escapeLen(s, i);
            continue;
        }
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            w += 1;
            i += 1;
            continue;
        };
        if (i + n > s.len) {
            w += 1;
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(s[i .. i + n]) catch {
            w += 1;
            i += 1;
            continue;
        };
        w += runeWidth(cp);
        i += n;
    }
    return w;
}

/// Copy of `s` clipped to at most `cols` cells. Never splits a code point;
/// a 2-cell rune that would straddle the boundary is dropped. Escape
/// sequences after the clip point are still appended (zero-width), so
/// trailing SGR resets survive truncation. Caller owns the result.
pub fn truncateToWidth(gpa: std.mem.Allocator, s: []const u8, cols: usize) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var w: usize = 0;
    var i: usize = 0;
    var clipped = false;
    while (i < s.len) {
        if (s[i] == 0x1b) {
            const n = escapeLen(s, i);
            try out.appendSlice(gpa, s[i .. i + n]);
            i += n;
            continue;
        }
        var n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        if (i + n > s.len) n = 1;
        const cp: u21 = if (n == 1) s[i] else std.unicode.utf8Decode(s[i .. i + n]) catch blk: {
            n = 1;
            break :blk s[i];
        };
        const cw: usize = if (n == 1 and cp > 0x7F) 1 else runeWidth(@intCast(cp));
        if (clipped or w + cw > cols) {
            clipped = true;
            i += n;
            continue;
        }
        try out.appendSlice(gpa, s[i .. i + n]);
        w += cw;
        i += n;
    }
    return out.toOwnedSlice(gpa);
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "ASCII is 1 cell" {
    try testing.expectEqual(@as(u2, 1), runeWidth('a'));
    try testing.expectEqual(@as(u2, 1), runeWidth(' '));
    try testing.expectEqual(@as(usize, 5), visibleWidth("hello"));
}

test "CJK and emoji are 2 cells" {
    try testing.expectEqual(@as(u2, 2), runeWidth('世'));
    try testing.expectEqual(@as(u2, 2), runeWidth('가'));
    try testing.expectEqual(@as(u2, 2), runeWidth(0x1F600)); // 😀
    try testing.expectEqual(@as(usize, 4), visibleWidth("世界"));
}

test "combining marks are 0 cells" {
    try testing.expectEqual(@as(u2, 0), runeWidth(0x0301)); // combining acute
    try testing.expectEqual(@as(u2, 0), runeWidth(0x200D)); // ZWJ
    try testing.expectEqual(@as(u2, 0), runeWidth(0xFE0F)); // variation selector
    // "e" + combining acute renders in one cell.
    try testing.expectEqual(@as(usize, 1), visibleWidth("e\u{0301}"));
}

test "control characters are 0 cells" {
    try testing.expectEqual(@as(u2, 0), runeWidth('\n'));
    try testing.expectEqual(@as(u2, 0), runeWidth(0x07));
}

test "CSI sequences consume no cells" {
    try testing.expectEqual(@as(usize, 2), visibleWidth("\x1b[38;5;196mok\x1b[0m"));
    try testing.expectEqual(@as(usize, 0), visibleWidth("\x1b[2K"));
}

test "OSC sequences consume no cells" {
    try testing.expectEqual(@as(usize, 2), visibleWidth("\x1b]0;title\x07ok"));
    try testing.expectEqual(@as(usize, 2), visibleWidth("\x1b]8;;url\x1b\\ok"));
}

test "unterminated escape swallows the tail, never panics" {
    try testing.expectEqual(@as(usize, 1), visibleWidth("a\x1b[38;5"));
    try testing.expectEqual(@as(usize, 1), visibleWidth("a\x1b"));
}

test "invalid UTF-8 measures 1 cell per byte" {
    try testing.expectEqual(@as(usize, 2), visibleWidth("\xff\xfe"));
}

test "truncate leaves short strings intact" {
    const got = try truncateToWidth(testing.allocator, "hello", 10);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("hello", got);
}

test "truncate clips to the column budget" {
    const got = try truncateToWidth(testing.allocator, "hello world", 5);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("hello", got);
}

test "truncate never splits a code point" {
    const got = try truncateToWidth(testing.allocator, "世界", 3);
    defer testing.allocator.free(got);
    // Second 2-cell rune would straddle cell 3..4: dropped, not split.
    try testing.expectEqualStrings("世", got);
}

test "truncate of a 2-cell rune at the boundary drops it" {
    const got = try truncateToWidth(testing.allocator, "a世", 2);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("a", got);
}

test "truncate keeps trailing SGR reset" {
    const got = try truncateToWidth(testing.allocator, "\x1b[31mhello\x1b[0m", 3);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("\x1b[31mhel\x1b[0m", got);
}

test "truncate preserves escapes and clips only visible cells" {
    const got = try truncateToWidth(testing.allocator, "ab\x1b[1mcd\x1b[0mef", 4);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("ab\x1b[1mcd\x1b[0m", got);
    try testing.expectEqual(@as(usize, 4), visibleWidth(got));
}
