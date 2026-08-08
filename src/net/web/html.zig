//! Boilerplate-stripping HTML -> text extraction, tuned for token cost.
//! Pure: no sockets, no worker — web_tools.zig composes this.

const std = @import("std");

pub const HtmlText = struct {
    text: []const u8,
    truncated: bool,
};

/// Boilerplate-stripping HTML -> text extraction, tuned for token cost.
/// Drops non-content elements whole, keeps block structure as newlines
/// (headings as `#`, list items as `- `), decodes entities, collapses
/// whitespace, caps at `max_out` with `truncated`.
pub fn htmlToText(arena: std.mem.Allocator, bytes: []const u8, max_out: usize) error{OutOfMemory}!HtmlText {
    const stripped = try dropNonContent(arena, bytes);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);

    var i: usize = 0;
    while (i < stripped.len) {
        if (stripped[i] == '<') {
            const gt = std.mem.indexOfScalarPos(u8, stripped, i + 1, '>') orelse stripped.len;
            const tag = stripped[i + 1 .. @min(gt, stripped.len)];
            i = if (gt < stripped.len) gt + 1 else stripped.len;
            try emitTagBoundary(arena, &out, tag);
            continue;
        }
        if (stripped[i] == '&') {
            if (try matchEntity(arena, stripped[i..])) |ent| {
                try out.appendSlice(arena, ent.replacement);
                i += ent.len;
                continue;
            }
        }
        try out.append(arena, stripped[i]);
        i += 1;
    }

    const collapsed = try collapseWhitespace(arena, out.items);
    if (collapsed.len <= max_out) {
        return .{ .text = collapsed, .truncated = false };
    }
    return .{ .text = try arena.dupe(u8, collapsed[0..max_out]), .truncated = true };
}

/// Tags whose text is layout/chrome, never page content.
const drop_whole = [_][]const u8{
    "script", "style",    "noscript", "svg",     "head",
    "nav",    "header",   "footer",   "aside",   "form",
    "iframe", "template", "select",   "button",  "canvas",
    "video",  "audio",    "object",   "picture", "map",
};

/// Tags that end a line of text.
const block_tags = [_][]const u8{
    "p",  "div", "br",     "li",         "tr",  "section", "article",
    "ul", "ol",  "table",  "blockquote", "pre", "hr",      "main",
    "h1", "h2",  "h3",     "h4",         "h5",  "h6",      "dl",
    "dt", "dd",  "figure", "figcaption",
};

/// Emit the text-level marker a tag stands for: newline for block tags
/// (with `#` / `- ` prefixes for headings and list items), else one space.
fn emitTagBoundary(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    tag: []const u8,
) error{OutOfMemory}!void {
    const closing = tag.len > 0 and tag[0] == SLASH;
    const body = if (closing) tag[1..] else tag;
    const name = tagName(body);
    if (name.len == 0) return;

    if (isBlockTag(name)) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != NL)
            try out.append(arena, NL);
        if (closing) return;
        if (name.len == 2 and (name[0] == 'h' or name[0] == 'H') and name[1] >= '1' and name[1] <= '6') {
            try out.appendNTimes(arena, HASH, name[1] - '0');
            try out.append(arena, SP);
        } else if (std.ascii.eqlIgnoreCase(name, "li")) {
            try out.appendSlice(arena, "- ");
        }
        return;
    }
    const last = if (out.items.len > 0) out.items[out.items.len - 1] else NL;
    if (last != SP and last != NL) try out.append(arena, SP);
}

const SLASH: u8 = '/';
const NL: u8 = '\n';
const SP: u8 = ' ';
const HASH: u8 = '#';

fn tagName(body: []const u8) []const u8 {
    var n: usize = 0;
    while (n < body.len and std.ascii.isAlphanumeric(body[n])) : (n += 1) {}
    return body[0..n];
}

fn isBlockTag(name: []const u8) bool {
    for (block_tags) |t| if (std.ascii.eqlIgnoreCase(name, t)) return true;
    return false;
}

const Entity = struct { len: usize, replacement: []const u8 };

/// Named entities (five basic + apos/nbsp) plus numeric decimal/hex.
/// Unknown entities return null so they pass through verbatim.
fn matchEntity(arena: std.mem.Allocator, s: []const u8) error{OutOfMemory}!?Entity {
    const table = [_]struct { []const u8, []const u8 }{
        .{ "&amp;", "&" },
        .{ "&lt;", "<" },
        .{ "&gt;", ">" },
        .{ "&quot;", "\"" },
        .{ "&#39;", "'" },
        .{ "&apos;", "'" },
        .{ "&nbsp;", " " },
    };
    for (table) |row| {
        if (std.mem.startsWith(u8, s, row[0])) return .{ .len = row[0].len, .replacement = row[1] };
    }
    if (s.len > 3 and s[1] == '#') {
        const hex = s[2] == 'x' or s[2] == 'X';
        const digits_start: usize = if (hex) 3 else 2;
        const semi = std.mem.indexOfScalarPos(u8, s, digits_start, ';') orelse return null;
        if (semi == digits_start or semi - digits_start > 7) return null;
        const cp = std.fmt.parseInt(u21, s[digits_start..semi], if (hex) 16 else 10) catch return null;
        if (cp == 0 or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF)) return null;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch return null;
        return .{ .len = semi + 1, .replacement = try arena.dupe(u8, buf[0..n]) };
    }
    return null;
}

/// Remove comments/doctype and every `drop_whole` element (open tag through
/// matching close, or to EOF when unclosed).
fn dropNonContent(arena: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    var i: usize = 0;
    outer: while (i < bytes.len) {
        if (bytes[i] == '<' and i + 1 < bytes.len and bytes[i + 1] == '!') {
            if (std.mem.startsWith(u8, bytes[i..], "<!--")) {
                const rel = std.mem.indexOf(u8, bytes[i + 4 ..], "-->") orelse break;
                i = i + 4 + rel + 3;
            } else {
                const gt = std.mem.indexOfScalarPos(u8, bytes, i + 1, '>') orelse break;
                i = gt + 1;
            }
            continue;
        }
        if (bytes[i] == '<') {
            for (drop_whole) |name| {
                if (!startsWithTagIgnoreCase(bytes[i..], name)) continue;
                const gt = std.mem.indexOfScalarPos(u8, bytes, i + 1, '>') orelse break :outer;
                // Self-closing (e.g. `<svg ... />`) has no body to skip.
                if (bytes[gt - 1] == SLASH) {
                    i = gt + 1;
                    continue :outer;
                }
                const close = try std.fmt.allocPrint(arena, "</{s}>", .{name});
                const rest = bytes[gt + 1 ..];
                if (indexOfIgnoreCase(rest, close)) |rel| {
                    i = gt + 1 + rel + close.len;
                    continue :outer;
                }
                break :outer; // unclosed block: drop the rest
            }
        }
        try out.append(arena, bytes[i]);
        i += 1;
    }
    return out.toOwnedSlice(arena);
}

fn startsWithTagIgnoreCase(s: []const u8, name: []const u8) bool {
    if (s.len < 1 + name.len) return false;
    if (s[0] != '<') return false;
    return std.ascii.startsWithIgnoreCase(s[1..], name) and
        (s.len == 1 + name.len or !std.ascii.isAlphabetic(s[1 + name.len]));
}

fn indexOfIgnoreCase(hay: []const u8, needle: []const u8) ?usize {
    if (needle.len > hay.len) return null;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i..][0..needle.len], needle)) return i;
    }
    return null;
}

/// Collapse space runs to one space and blank-line runs to at most one blank
/// line; drop trailing spaces per line; trim the whole output.
fn collapseWhitespace(arena: std.mem.Allocator, s: []const u8) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    var i: usize = 0;
    while (i < s.len) {
        if (!std.ascii.isWhitespace(s[i])) {
            try out.append(arena, s[i]);
            i += 1;
            continue;
        }
        var newlines: usize = 0;
        while (i < s.len and std.ascii.isWhitespace(s[i])) : (i += 1) {
            if (s[i] == NL) newlines += 1;
        }
        if (out.items.len == 0) continue; // trim leading
        if (newlines > 0) {
            while (out.items.len > 0 and out.items[out.items.len - 1] == SP) _ = out.pop();
            if (out.items.len == 0) continue;
            try out.appendNTimes(arena, NL, @min(newlines, 2));
        } else {
            try out.append(arena, SP);
        }
    }
    while (out.items.len > 0 and std.ascii.isWhitespace(out.items[out.items.len - 1])) _ = out.pop();
    return out.toOwnedSlice(arena);
}

const testing = std.testing;

const fixture_html =
    \\<html><head><style>body { color: red; }</style>
    \\<script>alert("xss")</script></head>
    \\<body><h1>Hello&amp;World</h1>
    \\<p>A &lt;B&gt; &quot;C&quot; &#39;D&#39;</p>
    \\
    \\
    \\<p>more</p></body></html>
;

const fixture_page =
    \\<!doctype html>
    \\<html lang="en"><head>
    \\<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
    \\<title>Example Article — Example Site</title>
    \\<link rel="stylesheet" href="/assets/app.4f2c9a1b.css">
    \\<script src="/assets/analytics.js" async></script>
    \\<style>body{font-family:system-ui;margin:0}.nav{display:flex;gap:1rem}.card{border:1px solid #eee}</style>
    \\</head>
    \\<body class="page page--article theme-light">
    \\<header class="site-header"><div class="logo">ExampleSite</div></header>
    \\<nav class="nav" aria-label="Primary"><a href="/">Home</a><a href="/blog">Blog</a><a href="/about">About</a><a href="/contact">Contact</a></nav>
    \\<main>
    \\<article class="card card--article" data-id="12345" data-analytics="article-view">
    \\<h1 class="card__title">Example Article</h1>
    \\<p class="card__body">The quick brown fox jumps over the lazy dog.</p>
    \\<p class="card__body">Second paragraph with an <a class="link" href="/somewhere?utm_source=x&amp;utm_medium=y">inline link</a> inside it.</p>
    \\<ul class="list"><li class="list__item">alpha</li><li class="list__item">beta</li></ul>
    \\</article>
    \\</main>
    \\<aside class="sidebar"><h3>Related</h3><ul><li><a href="/a">Other post one</a></li><li><a href="/b">Other post two</a></li></ul></aside>
    \\<form class="newsletter" action="/subscribe" method="post"><input type="email" name="email" placeholder="you@example.com"><button type="submit">Subscribe</button></form>
    \\<footer class="site-footer"><p>Copyright 2026 ExampleSite. All rights reserved.</p></footer>
    \\<noscript>Please enable JavaScript to view this site.</noscript>
    \\<script>window.__DATA__={"a":1,"b":[1,2,3],"c":"lots of json payload here"};</script>
    \\</body></html>
;

test "htmlToText: tags/script/style stripped, entities decoded, blank runs collapsed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const got = try htmlToText(arena, fixture_html, 64 * 1024);
    try testing.expect(!got.truncated);
    // Script/style bodies gone; tags gone; entities decoded; blanks collapsed.
    try testing.expect(std.mem.indexOf(u8, got.text, "alert") == null);
    try testing.expect(std.mem.indexOf(u8, got.text, "color") == null);
    try testing.expect(std.mem.indexOf(u8, got.text, "<") == null or std.mem.indexOf(u8, got.text, "<B>") != null);
    try testing.expect(std.mem.indexOf(u8, got.text, "Hello&World") != null);
    try testing.expect(std.mem.indexOf(u8, got.text, "A <B> \"C\" 'D'") != null);
    try testing.expect(std.mem.indexOf(u8, got.text, "more") != null);
    // No multi-space blank runs remain.
    try testing.expect(std.mem.indexOf(u8, got.text, "  ") == null);
}

test "htmlToText: max_text_bytes cap sets truncated" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const got = try htmlToText(arena, fixture_html, 10);
    try testing.expect(got.truncated);
    try testing.expectEqual(@as(usize, 10), got.text.len);
}

test "htmlToText: boilerplate elements dropped whole" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const html =
        \\<!doctype html><html><head><title>t</title></head><body>
        \\<nav><a href="/x">Home</a><a href="/y">About</a></nav>
        \\<header>SiteName</header>
        \\<aside>Related junk</aside>
        \\<noscript>Enable JS</noscript>
        \\<svg><path d="M0 0"/></svg>
        \\<form><select><option>pick</option></select><button>Go</button></form>
        \\<main><p>Real content here.</p></main>
        \\<footer>Copyright junk</footer>
        \\</body></html>
    ;
    const got = try htmlToText(arena, html, 64 * 1024);
    try testing.expect(std.mem.indexOf(u8, got.text, "Real content here.") != null);
    try testing.expect(std.mem.indexOf(u8, got.text, "<title>") == null);
    for ([_][]const u8{ "Home", "About", "SiteName", "Related junk", "Enable JS", "M0 0", "pick", "Go", "Copyright junk" }) |junk| {
        try testing.expect(std.mem.indexOf(u8, got.text, junk) == null);
    }
}

test "htmlToText: comments and doctype dropped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const got = try htmlToText(arena, "<!doctype html><!-- secret note --><p>keep</p>", 64 * 1024);
    try testing.expect(std.mem.indexOf(u8, got.text, "secret") == null);
    try testing.expect(std.mem.indexOf(u8, got.text, "doctype") == null);
    try testing.expect(std.mem.indexOf(u8, got.text, "keep") != null);
}

test "htmlToText: block tags become newlines, headings get #, list items get -" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const got = try htmlToText(arena, "<h2>Title</h2><p>One</p><ul><li>a</li><li>b</li></ul>", 64 * 1024);
    try testing.expect(std.mem.indexOf(u8, got.text, "## Title") != null);
    try testing.expect(std.mem.indexOf(u8, got.text, "\nOne") != null);
    try testing.expect(std.mem.indexOf(u8, got.text, "- a") != null);
    try testing.expect(std.mem.indexOf(u8, got.text, "- b") != null);
}

test "htmlToText: nbsp and numeric entities decoded; unknown entity passes through" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const got = try htmlToText(arena, "<p>a&nbsp;b &#65; &#x42; &bogus;</p>", 64 * 1024);
    try testing.expect(std.mem.indexOf(u8, got.text, "a b") != null);
    try testing.expect(std.mem.indexOf(u8, got.text, "A") != null);
    try testing.expect(std.mem.indexOf(u8, got.text, "B") != null);
    try testing.expect(std.mem.indexOf(u8, got.text, "&bogus;") != null);
}

test "htmlToText: blank-line runs collapse to at most one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const got = try htmlToText(arena, "<p>a</p><div></div><div></div><div></div><p>b</p>", 64 * 1024);
    try testing.expect(std.mem.indexOf(u8, got.text, "\n\n\n") == null);
    try testing.expect(std.mem.indexOf(u8, got.text, "a") != null);
    try testing.expect(std.mem.indexOf(u8, got.text, "b") != null);
}

test "htmlToText: realistic page compresses to a small fraction of input" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const got = try htmlToText(arena, fixture_page, 64 * 1024);
    try testing.expect(std.mem.indexOf(u8, got.text, "The quick brown fox") != null);
    // Boilerplate-stripping must beat a naive tag strip by a wide margin.
    try testing.expect(got.text.len * 5 < fixture_page.len);
}
