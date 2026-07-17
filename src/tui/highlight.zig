//! Line-oriented keyword highlighter for fenced code in promoted answers.
//! std-only and deliberately shallow: line comments, string literals,
//! numbers, `ident(` as a call, and per-language keyword sets — display
//! coloring, not parsing. Invariant: highlighting never changes the visible
//! text; stripping the SGRs yields the input bytes exactly.

const std = @import("std");
const theme = @import("theme.zig");
const palette = @import("palette.zig");

pub const Lang = enum { zig, python, js, sh, none };

/// Map a fence info string ("```zig") to a language; unknown info means
/// no highlighting, never an error.
pub fn langFromInfo(info: []const u8) Lang {
    const map = .{
        .{ "zig", Lang.zig },
        .{ "python", Lang.python },
        .{ "py", Lang.python },
        .{ "js", Lang.js },
        .{ "javascript", Lang.js },
        .{ "ts", Lang.js },
        .{ "typescript", Lang.js },
        .{ "jsx", Lang.js },
        .{ "tsx", Lang.js },
        .{ "sh", Lang.sh },
        .{ "bash", Lang.sh },
        .{ "shell", Lang.sh },
        .{ "zsh", Lang.sh },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, info, entry[0])) return entry[1];
    }
    return .none;
}

const zig_keywords = [_][]const u8{
    "const", "var",    "fn",          "pub",      "return",      "if",    "else",     "while",
    "for",   "switch", "defer",       "errdefer", "try",         "catch", "struct",   "enum",
    "union", "error",  "test",        "comptime", "inline",      "break", "continue", "orelse",
    "and",   "or",     "unreachable", "null",     "undefined",   "true",  "false",    "usingnamespace",
    "async", "await",  "export",      "extern",   "threadlocal",
};
const python_keywords = [_][]const u8{
    "def",    "class",  "return", "if",       "elif",   "else",     "while",  "for",
    "in",     "import", "from",   "as",       "with",   "try",      "except", "finally",
    "lambda", "pass",   "break",  "continue", "global", "nonlocal", "yield",  "raise",
    "assert", "and",    "or",     "not",      "None",   "True",     "False",  "is",
    "del",    "match",  "case",   "async",    "await",
};
const js_keywords = [_][]const u8{
    "const", "let",       "var",        "function", "return",   "if",    "else",      "while",
    "for",   "switch",    "case",       "break",    "continue", "class", "extends",   "new",
    "this",  "typeof",    "instanceof", "import",   "export",   "from",  "default",   "async",
    "await", "try",       "catch",      "finally",  "throw",    "null",  "undefined", "true",
    "false", "interface", "type",       "enum",     "of",       "in",    "yield",
};
const sh_keywords = [_][]const u8{
    "if",   "then", "else", "elif",     "fi",   "for",    "while",  "do",
    "done", "case", "esac", "function", "in",   "local",  "return", "export",
    "echo", "exit", "set",  "shift",    "read", "source",
};

fn keywords(lang: Lang) []const []const u8 {
    return switch (lang) {
        .zig => &zig_keywords,
        .python => &python_keywords,
        .js => &js_keywords,
        .sh => &sh_keywords,
        .none => &.{},
    };
}

fn commentMarker(lang: Lang) []const u8 {
    return switch (lang) {
        .zig, .js => "//",
        .python, .sh => "#",
        .none => "",
    };
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isNumberChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '.' or c == '_';
}

/// Highlight one line of `lang` code. `restore` is re-emitted after every
/// SGR reset so an enclosing style (the code-panel bg) survives token
/// boundaries. `.none` passes the text through untouched.
pub fn line(
    arena: std.mem.Allocator,
    lang: Lang,
    text: []const u8,
    restore: []const u8,
) error{OutOfMemory}![]const u8 {
    if (lang == .none) return text;
    var out: std.ArrayList(u8) = .empty;
    const marker = commentMarker(lang);

    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (marker.len > 0 and std.mem.startsWith(u8, text[i..], marker)) {
            try emit(arena, &out, palette.syntax.comment, theme.italic, text[i..], restore);
            break;
        }
        if (c == '"' or (c == '\'' and lang != .zig)) {
            const end = stringEnd(text, i, c);
            try emit(arena, &out, palette.syntax.string, "", text[i..end], restore);
            i = end;
            continue;
        }
        if (std.ascii.isDigit(c) and (i == 0 or !isIdentChar(text[i - 1]))) {
            var end = i + 1;
            while (end < text.len and isNumberChar(text[end])) end += 1;
            try emit(arena, &out, palette.syntax.number, "", text[i..end], restore);
            i = end;
            continue;
        }
        if (std.ascii.isAlphabetic(c) or c == '_') {
            var end = i + 1;
            while (end < text.len and isIdentChar(text[end])) end += 1;
            const word = text[i..end];
            if (isKeyword(lang, word)) {
                try emit(arena, &out, palette.syntax.keyword, "", word, restore);
            } else if (end < text.len and text[end] == '(') {
                try emit(arena, &out, palette.syntax.func, "", word, restore);
            } else {
                try out.appendSlice(arena, word);
            }
            i = end;
            continue;
        }
        try out.append(arena, c);
        i += 1;
    }
    return out.items;
}

fn isKeyword(lang: Lang, word: []const u8) bool {
    for (keywords(lang)) |kw| {
        if (std.mem.eql(u8, word, kw)) return true;
    }
    return false;
}

/// End index (exclusive) of a string literal opened at `start` with `quote`;
/// backslash escapes skip; unterminated runs to end of line.
fn stringEnd(text: []const u8, start: usize, quote: u8) usize {
    var i = start + 1;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\\') {
            i += 1;
            continue;
        }
        if (text[i] == quote) return i + 1;
    }
    return text.len;
}

fn emit(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    color: palette.Rgb,
    extra_sgr: []const u8,
    slice: []const u8,
    restore: []const u8,
) error{OutOfMemory}!void {
    var buf: [24]u8 = undefined;
    try out.appendSlice(arena, theme.fg(&buf, color));
    try out.appendSlice(arena, extra_sgr);
    try out.appendSlice(arena, slice);
    try out.appendSlice(arena, theme.reset);
    try out.appendSlice(arena, restore);
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

/// The visible bytes of `s`: everything outside CSI escape sequences.
fn stripSgr(arena: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b and i + 1 < s.len and s[i + 1] == '[') {
            i += 2;
            while (i < s.len and s[i] != 'm') i += 1;
            i += 1;
            continue;
        }
        try out.append(arena, s[i]);
        i += 1;
    }
    return out.items;
}

test "highlighting never changes the visible text" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const samples = [_]struct { lang: Lang, src: []const u8 }{
        .{ .lang = .zig, .src = "pub fn main() !void { const x: u8 = 0xff; } // entry" },
        .{ .lang = .python, .src = "def f(x=1):  # comment with \"quotes\"" },
        .{ .lang = .js, .src = "const s = 'it\\'s'; let n = 3.14; f();" },
        .{ .lang = .sh, .src = "if [ -f \"$1\" ]; then echo ok; fi # check" },
        .{ .lang = .zig, .src = "const s = \"unterminated" },
        .{ .lang = .none, .src = "anything at all `**`" },
    };
    for (samples) |sample| {
        const got = try line(arena, sample.lang, sample.src, "");
        try testing.expectEqualStrings(sample.src, try stripSgr(arena, got));
    }
}

test "keywords, calls, numbers, strings and comments take syntax colors" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const got = try line(arena, .zig, "const n = f(42); // done", "");
    var kw_buf: [24]u8 = undefined;
    var fn_buf: [24]u8 = undefined;
    var num_buf: [24]u8 = undefined;
    var cm_buf: [24]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, got, theme.fg(&kw_buf, palette.syntax.keyword)) != null);
    try testing.expect(std.mem.indexOf(u8, got, theme.fg(&fn_buf, palette.syntax.func)) != null);
    try testing.expect(std.mem.indexOf(u8, got, theme.fg(&num_buf, palette.syntax.number)) != null);
    try testing.expect(std.mem.indexOf(u8, got, theme.fg(&cm_buf, palette.syntax.comment)) != null);
    // Identifier inside a comment is not tokenized: the comment wins.
    const commented = try line(arena, .zig, "// const inside", "");
    const kw_needle = try std.fmt.allocPrint(arena, "{s}const", .{theme.fg(&kw_buf, palette.syntax.keyword)});
    try testing.expect(std.mem.indexOf(u8, commented, kw_needle) == null);
}

test "restore SGR is re-emitted after every reset" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const restore = "\x1b[48;5;234m";
    const got = try line(arena_state.allocator(), .zig, "const x = 1;", restore);
    const resets = std.mem.count(u8, got, theme.reset);
    try testing.expect(resets > 0);
    try testing.expectEqual(resets, std.mem.count(u8, got, restore));
}

test "fence info maps to languages and unknown info to none" {
    try testing.expectEqual(Lang.zig, langFromInfo("zig"));
    try testing.expectEqual(Lang.python, langFromInfo("py"));
    try testing.expectEqual(Lang.js, langFromInfo("typescript"));
    try testing.expectEqual(Lang.sh, langFromInfo("bash"));
    try testing.expectEqual(Lang.none, langFromInfo("brainfuck"));
    try testing.expectEqual(Lang.none, langFromInfo(""));
}
