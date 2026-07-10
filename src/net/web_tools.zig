//! Web-tools worker (Y1/Y2, docs/specs/web-tools.md).
//!
//! Registers `zygos::tools::{web_search,web_fetch}` on the bus. Lives in
//! `src/net/` because handlers hold `std.Io` for HTTP (Z-02). The pure layer
//! (html/URL/JSON) is fixture-tested; the HTTP leg compiles but is never
//! exercised by `zig build test` — bus tests fail closed on invalid input
//! before any socket opens.

const std = @import("std");
const json = std.json;
const actor_mod = @import("../kernel/actor.zig");
const inproc = @import("../kernel/inproc.zig");

const log = std.log.scoped(.web_tools);

// ---------------------------------------------------------------------------
// Config / pure types
// ---------------------------------------------------------------------------

pub const SearchEngine = enum { brave, searxng };

/// Operator-injected search backend. `key` is the resolved secret (or null when
/// missing); `key_env` is the env var name used in missing-key error replies.
pub const SearchConfig = struct {
    endpoint: []const u8,
    key_env: ?[]const u8 = null,
    key: ?[]const u8 = null,
    engine: SearchEngine,
};

pub const Options = struct {
    search: ?SearchConfig = null,
    max_fetch_bytes: usize = 512 * 1024,
    max_text_bytes: usize = 64 * 1024,
};

pub const HtmlText = struct {
    text: []const u8,
    truncated: bool,
};

pub const SearchResult = struct {
    title: []const u8,
    url: []const u8,
    snippet: []const u8,
};

pub const ValidateError = error{InvalidUrl};
pub const ParseError = error{ OutOfMemory, UpstreamMalformed };

// ---------------------------------------------------------------------------
// Pure layer
// ---------------------------------------------------------------------------

/// https/http only. Rejects file:, ftp:, and anything Uri.parse rejects.
pub fn validateUrl(url: []const u8) ValidateError!void {
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    if (!(std.ascii.eqlIgnoreCase(uri.scheme, "http") or std.ascii.eqlIgnoreCase(uri.scheme, "https")))
        return error.InvalidUrl;
    // A fetchable URL needs a host; bare "http:" / scheme-only garbage fails.
    if (uri.host == null) return error.InvalidUrl;
}

/// Strip script/style blocks, strip tags, decode the five basic entities,
/// collapse blank/whitespace runs, cap at `max_out` with `truncated`.
pub fn htmlToText(arena: std.mem.Allocator, bytes: []const u8, max_out: usize) error{OutOfMemory}!HtmlText {
    const stripped = try stripScriptAndStyle(arena, bytes);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);

    var i: usize = 0;
    while (i < stripped.len) {
        if (stripped[i] == '<') {
            // Skip to end of tag (or EOF).
            const gt = std.mem.indexOfScalarPos(u8, stripped, i + 1, '>') orelse stripped.len;
            i = if (gt < stripped.len) gt + 1 else stripped.len;
            // Keep a space so block-adjacent text doesn't glue together.
            if (out.items.len > 0 and out.items[out.items.len - 1] != ' ')
                try out.append(arena, ' ');
            continue;
        }
        if (stripped[i] == '&') {
            if (matchEntity(stripped[i..])) |ent| {
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

/// Brave Search API web results → neutral `{title,url,snippet}[]`.
pub fn parseBraveResults(arena: std.mem.Allocator, json_text: []const u8) ParseError![]SearchResult {
    const root = json.parseFromSliceLeaky(json.Value, arena, json_text, .{}) catch
        return error.UpstreamMalformed;
    if (root != .object) return error.UpstreamMalformed;
    const web = root.object.get("web") orelse return error.UpstreamMalformed;
    if (web != .object) return error.UpstreamMalformed;
    const results = web.object.get("results") orelse return error.UpstreamMalformed;
    if (results != .array) return error.UpstreamMalformed;
    return collectResults(arena, results.array.items, "description");
}

/// searxng JSON results → neutral `{title,url,snippet}[]`.
pub fn parseSearxngResults(arena: std.mem.Allocator, json_text: []const u8) ParseError![]SearchResult {
    const root = json.parseFromSliceLeaky(json.Value, arena, json_text, .{}) catch
        return error.UpstreamMalformed;
    if (root != .object) return error.UpstreamMalformed;
    const results = root.object.get("results") orelse return error.UpstreamMalformed;
    if (results != .array) return error.UpstreamMalformed;
    return collectResults(arena, results.array.items, "content");
}

fn collectResults(
    arena: std.mem.Allocator,
    items: []const json.Value,
    snippet_key: []const u8,
) ParseError![]SearchResult {
    var out: std.ArrayList(SearchResult) = .empty;
    errdefer out.deinit(arena);
    for (items) |item| {
        if (item != .object) return error.UpstreamMalformed;
        const title = strField(item.object, "title") orelse return error.UpstreamMalformed;
        const url = strField(item.object, "url") orelse return error.UpstreamMalformed;
        const snippet = strField(item.object, snippet_key) orelse "";
        try out.append(arena, .{
            .title = try arena.dupe(u8, title),
            .url = try arena.dupe(u8, url),
            .snippet = try arena.dupe(u8, snippet),
        });
    }
    return out.toOwnedSlice(arena);
}

// ---------------------------------------------------------------------------
// Worker
// ---------------------------------------------------------------------------

pub const WebToolsWorker = struct {
    gpa: std.mem.Allocator,
    worker: *inproc.Worker,
    io: std.Io,
    max_fetch_bytes: usize,
    max_text_bytes: usize,
    /// Owned deep copy of search config, or null when search is unconfigured.
    search: ?OwnedSearch,

    const OwnedSearch = struct {
        endpoint: []const u8,
        key_env: ?[]const u8,
        key: ?[]const u8,
        engine: SearchEngine,
    };

    pub fn start(
        gpa: std.mem.Allocator,
        actor: *actor_mod.Actor,
        registry: *inproc.Registry,
        io: std.Io,
        opts: Options,
    ) !*WebToolsWorker {
        const self = try gpa.create(WebToolsWorker);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .worker = try inproc.Worker.spawn(gpa, actor, registry, "web-tools"),
            .io = io,
            .max_fetch_bytes = opts.max_fetch_bytes,
            .max_text_bytes = opts.max_text_bytes,
            .search = null,
        };
        errdefer self.worker.stop();

        if (opts.search) |sc| {
            self.search = .{
                .endpoint = try gpa.dupe(u8, sc.endpoint),
                .key_env = if (sc.key_env) |e| try gpa.dupe(u8, e) else null,
                .key = if (sc.key) |k| try gpa.dupe(u8, k) else null,
                .engine = sc.engine,
            };
        }

        try self.worker.registerFunction("zygos::tools::web_fetch", self, &fetchHandler);
        try self.worker.registerFunction("zygos::tools::web_search", self, &searchHandler);
        return self;
    }

    pub fn stop(self: *WebToolsWorker) void {
        self.worker.stop();
        if (self.search) |sc| {
            self.gpa.free(sc.endpoint);
            if (sc.key_env) |e| self.gpa.free(e);
            if (sc.key) |k| self.gpa.free(k);
        }
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    fn fetchHandler(ctx: ?*anyopaque, arena: std.mem.Allocator, request_json: []const u8) error{ Failed, OutOfMemory }![]const u8 {
        const self: *WebToolsWorker = @ptrCast(@alignCast(ctx.?));
        const obj = try parseObject(arena, request_json);
        const url = strField(obj, "url") orelse return error.Failed;

        validateUrl(url) catch return errorReply(arena, "InvalidUrl");

        const body = httpGet(self.gpa, self.io, url, &.{}, self.max_fetch_bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.HttpFailed => return errorReply(arena, "HttpFailed"),
            error.NonTextContent => return errorReply(arena, "NonTextContent"),
            error.HttpStatus => return statusReply(arena),
        };
        defer self.gpa.free(body.bytes);
        defer self.gpa.free(body.content_type);

        if (!isTextContentType(body.content_type)) return errorReply(arena, "NonTextContent");

        const converted = try htmlToText(arena, body.bytes, self.max_text_bytes);
        return std.fmt.allocPrint(arena, "{{\"url\":{f},\"text\":{f},\"truncated\":{}}}", .{
            json.fmt(url, .{}),
            json.fmt(converted.text, .{}),
            converted.truncated,
        });
    }

    fn searchHandler(ctx: ?*anyopaque, arena: std.mem.Allocator, request_json: []const u8) error{ Failed, OutOfMemory }![]const u8 {
        const self: *WebToolsWorker = @ptrCast(@alignCast(ctx.?));
        const obj = try parseObject(arena, request_json);
        const query = strField(obj, "query") orelse return error.Failed;
        const count: u32 = u32Field(obj, "count") orelse 5;

        const sc = self.search orelse return errorReply(arena, "SearchNotConfigured");

        // Brave requires a key; missing key fails closed naming the env var.
        if (sc.engine == .brave) {
            if (sc.key == null) {
                if (sc.key_env) |env_name| {
                    return std.fmt.allocPrint(arena, "{{\"error\":\"MissingSearchKey\",\"key_env\":{f}}}", .{
                        json.fmt(env_name, .{}),
                    });
                }
                return errorReply(arena, "MissingSearchKey");
            }
        }

        const url = try buildSearchUrl(arena, sc, query, count);
        const headers = try buildSearchHeaders(arena, sc);

        const body = httpGet(self.gpa, self.io, url, headers, self.max_fetch_bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.HttpFailed => return errorReply(arena, "HttpFailed"),
            error.NonTextContent => return errorReply(arena, "NonTextContent"),
            error.HttpStatus => return statusReply(arena),
        };
        defer self.gpa.free(body.bytes);
        defer self.gpa.free(body.content_type);

        const results = switch (sc.engine) {
            .brave => parseBraveResults(arena, body.bytes),
            .searxng => parseSearxngResults(arena, body.bytes),
        } catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UpstreamMalformed => return errorReply(arena, "UpstreamMalformed"),
        };

        return renderResults(arena, results);
    }
};

// ---------------------------------------------------------------------------
// HTTP (compiled; not exercised by unit tests — fail before socket on bad input)
// ---------------------------------------------------------------------------

const HttpGetError = error{ OutOfMemory, HttpFailed, NonTextContent } || error{HttpStatus};

const HttpBody = struct {
    bytes: []u8,
    content_type: []u8,
};

/// Sentinel: `error.HttpStatus` is raised with the numeric code stashed in
/// threadlocal so handlers can name it in the structured reply. Unit tests
/// never open a socket, so this path is only for real runs / future e2e.
threadlocal var last_http_status: u16 = 0;

fn httpGet(
    gpa: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    headers: []const std.http.Header,
    max_bytes: usize,
) HttpGetError!HttpBody {
    const uri = std.Uri.parse(url) catch return error.HttpFailed;

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var req = client.request(.GET, uri, .{
        .extra_headers = headers,
        .redirect_behavior = @enumFromInt(3),
    }) catch return error.HttpFailed;
    defer req.deinit();

    req.sendBodiless() catch return error.HttpFailed;

    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch return error.HttpFailed;

    if (response.head.status.class() != .success) {
        last_http_status = @intFromEnum(response.head.status);
        return error.HttpStatus;
    }

    const ct_raw = response.head.content_type orelse "application/octet-stream";
    const ct = gpa.dupe(u8, ct_raw) catch return error.OutOfMemory;
    errdefer gpa.free(ct);

    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    var transfer_buf: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buf);
    var chunk: [8 * 1024]u8 = undefined;
    while (true) {
        const n = reader.readSliceShort(&chunk) catch return error.HttpFailed;
        if (n == 0) break;
        const take = @min(n, max_bytes -| list.items.len);
        if (take > 0) list.appendSlice(gpa, chunk[0..take]) catch return error.OutOfMemory;
        // Past the cap we stop reading further bytes into the buffer; the
        // connection is dropped on req.deinit.
        if (list.items.len >= max_bytes) break;
    }

    return .{
        .bytes = list.toOwnedSlice(gpa) catch return error.OutOfMemory,
        .content_type = ct,
    };
}

fn isTextContentType(ct: []const u8) bool {
    const semi = std.mem.indexOfScalar(u8, ct, ';') orelse ct.len;
    const main = std.mem.trim(u8, ct[0..semi], " \t");
    if (std.ascii.startsWithIgnoreCase(main, "text/")) return true;
    if (std.ascii.eqlIgnoreCase(main, "application/xhtml+xml")) return true;
    // Search backends return application/json; fetch itself still rejects it.
    return false;
}

fn buildSearchUrl(
    arena: std.mem.Allocator,
    sc: WebToolsWorker.OwnedSearch,
    query: []const u8,
    count: u32,
) error{OutOfMemory}![]const u8 {
    const encoded = try percentEncodeQuery(arena, query);
    return switch (sc.engine) {
        .brave => std.fmt.allocPrint(arena, "{s}/res/v1/web/search?q={s}&count={d}", .{
            trimTrailingSlash(sc.endpoint), encoded, count,
        }),
        .searxng => std.fmt.allocPrint(arena, "{s}/search?q={s}&format=json", .{
            trimTrailingSlash(sc.endpoint), encoded,
        }),
    };
}

fn buildSearchHeaders(
    arena: std.mem.Allocator,
    sc: WebToolsWorker.OwnedSearch,
) error{OutOfMemory}![]const std.http.Header {
    if (sc.engine == .brave) {
        const key = sc.key orelse return &.{};
        const headers = try arena.alloc(std.http.Header, 1);
        headers[0] = .{ .name = "X-Subscription-Token", .value = key };
        return headers;
    }
    return &.{};
}

fn percentEncodeQuery(arena: std.mem.Allocator, s: []const u8) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try out.append(arena, c);
        } else if (c == ' ') {
            try out.append(arena, '+');
        } else {
            var buf: [3]u8 = undefined;
            const enc = std.fmt.bufPrint(&buf, "%{X:0>2}", .{c}) catch unreachable;
            try out.appendSlice(arena, enc);
        }
    }
    return out.toOwnedSlice(arena);
}

fn trimTrailingSlash(s: []const u8) []const u8 {
    return std.mem.trimEnd(u8, s, "/");
}

fn renderResults(arena: std.mem.Allocator, results: []const SearchResult) error{OutOfMemory}![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    errdefer parts.deinit(arena);
    for (results) |r| {
        const item = try std.fmt.allocPrint(arena, "{{\"title\":{f},\"url\":{f},\"snippet\":{f}}}", .{
            json.fmt(r.title, .{}),
            json.fmt(r.url, .{}),
            json.fmt(r.snippet, .{}),
        });
        try parts.append(arena, item);
    }
    const joined = try std.mem.join(arena, ",", parts.items);
    return std.fmt.allocPrint(arena, "{{\"results\":[{s}]}}", .{joined});
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

fn parseObject(arena: std.mem.Allocator, request_json: []const u8) error{Failed}!json.ObjectMap {
    const root = json.parseFromSliceLeaky(json.Value, arena, request_json, .{}) catch
        return error.Failed;
    return if (root == .object) root.object else error.Failed;
}

fn strField(obj: json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn u32Field(obj: json.ObjectMap, key: []const u8) ?u32 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |n| if (n >= 0 and n <= std.math.maxInt(u32)) @intCast(n) else null,
        else => null,
    };
}

fn errorReply(arena: std.mem.Allocator, name: []const u8) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(arena, "{{\"error\":{f}}}", .{json.fmt(name, .{})});
}

fn statusReply(arena: std.mem.Allocator) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(arena, "{{\"error\":\"HttpStatus\",\"status\":{d}}}", .{last_http_status});
}

const Entity = struct { len: usize, replacement: []const u8 };

fn matchEntity(s: []const u8) ?Entity {
    const table = [_]struct { []const u8, []const u8 }{
        .{ "&amp;", "&" },
        .{ "&lt;", "<" },
        .{ "&gt;", ">" },
        .{ "&quot;", "\"" },
        .{ "&#39;", "'" },
    };
    for (table) |row| {
        if (std.mem.startsWith(u8, s, row[0])) return .{ .len = row[0].len, .replacement = row[1] };
    }
    return null;
}

fn stripScriptAndStyle(arena: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    var i: usize = 0;
    while (i < bytes.len) {
        if (startsWithTagIgnoreCase(bytes[i..], "script") or startsWithTagIgnoreCase(bytes[i..], "style")) {
            const is_script = startsWithTagIgnoreCase(bytes[i..], "script");
            const close = if (is_script) "</script>" else "</style>";
            // Advance past the opening tag.
            const gt = std.mem.indexOfScalarPos(u8, bytes, i + 1, '>') orelse {
                i = bytes.len;
                break;
            };
            const rest = bytes[gt + 1 ..];
            if (indexOfIgnoreCase(rest, close)) |rel| {
                i = gt + 1 + rel + close.len;
                continue;
            }
            // Unclosed block: drop the rest.
            break;
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

fn collapseWhitespace(arena: std.mem.Allocator, s: []const u8) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    var i: usize = 0;
    // Trim leading.
    while (i < s.len and std.ascii.isWhitespace(s[i])) : (i += 1) {}
    var last_was_space = false;
    while (i < s.len) : (i += 1) {
        if (std.ascii.isWhitespace(s[i])) {
            if (!last_was_space) {
                try out.append(arena, ' ');
                last_was_space = true;
            }
        } else {
            try out.append(arena, s[i]);
            last_was_space = false;
        }
    }
    // Trim trailing space we may have appended.
    if (out.items.len > 0 and out.items[out.items.len - 1] == ' ')
        _ = out.pop();
    return out.toOwnedSlice(arena);
}

// ===========================================================================
// Tests — docs/specs/web-tools.md contract (RED first; no sockets)
// ===========================================================================

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

const fixture_brave =
    \\{"web":{"results":[
    \\  {"title":"Zig Programming Language","url":"https://ziglang.org/","description":"Zig is a general-purpose programming language."},
    \\  {"title":"Zig GitHub","url":"https://github.com/ziglang/zig","description":"General-purpose programming language and toolchain."}
    \\]}}
;

const fixture_searxng =
    \\{"results":[
    \\  {"title":"Zig Programming Language","url":"https://ziglang.org/","content":"Zig is a general-purpose programming language."},
    \\  {"title":"Zig GitHub","url":"https://github.com/ziglang/zig","content":"General-purpose programming language and toolchain."}
    \\]}
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

test "validateUrl: https/http pass; file:, ftp:, garbage ⇒ error" {
    try validateUrl("https://example.com/path");
    try validateUrl("http://localhost:8080/");
    try testing.expectError(error.InvalidUrl, validateUrl("file:///etc/passwd"));
    try testing.expectError(error.InvalidUrl, validateUrl("ftp://files.example.com/x"));
    try testing.expectError(error.InvalidUrl, validateUrl("not a url"));
    try testing.expectError(error.InvalidUrl, validateUrl(""));
}

test "parseBraveResults + parseSearxngResults: recorded fixtures → neutral shape" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const brave = try parseBraveResults(arena, fixture_brave);
    try testing.expectEqual(@as(usize, 2), brave.len);
    try testing.expectEqualStrings("Zig Programming Language", brave[0].title);
    try testing.expectEqualStrings("https://ziglang.org/", brave[0].url);
    try testing.expectEqualStrings("Zig is a general-purpose programming language.", brave[0].snippet);
    try testing.expectEqualStrings("Zig GitHub", brave[1].title);

    const searx = try parseSearxngResults(arena, fixture_searxng);
    try testing.expectEqual(@as(usize, 2), searx.len);
    try testing.expectEqualStrings("Zig Programming Language", searx[0].title);
    try testing.expectEqualStrings("https://ziglang.org/", searx[0].url);
    try testing.expectEqualStrings("Zig is a general-purpose programming language.", searx[0].snippet);
}

test "malformed upstream search JSON ⇒ error, no crash, no leak" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectError(error.UpstreamMalformed, parseBraveResults(arena, "not-json"));
    try testing.expectError(error.UpstreamMalformed, parseBraveResults(arena, "{\"web\":\"nope\"}"));
    try testing.expectError(error.UpstreamMalformed, parseBraveResults(arena, "{\"web\":{}}"));
    try testing.expectError(error.UpstreamMalformed, parseSearxngResults(arena, "[]"));
    try testing.expectError(error.UpstreamMalformed, parseSearxngResults(arena, "{\"results\":\"x\"}"));
    try testing.expectError(error.UpstreamMalformed, parseSearxngResults(arena, "{\"results\":[1]}"));
}

const Harness = struct {
    registry: inproc.Registry,
    actor: actor_mod.Actor,
    kernel: std.Thread,
    caller: *inproc.Worker,
    io_backing: std.Io.Threaded,
    worker: *WebToolsWorker,

    fn init(gpa: std.mem.Allocator, opts: Options) !*Harness {
        const self = try gpa.create(Harness);
        errdefer gpa.destroy(self);
        self.io_backing = std.Io.Threaded.init(gpa, .{});
        errdefer self.io_backing.deinit();
        self.registry = inproc.Registry.init(gpa, null);
        self.actor = try actor_mod.Actor.init(gpa, .{}, self.registry.outbound());
        self.kernel = try std.Thread.spawn(.{}, actor_mod.Actor.run, .{&self.actor});
        self.caller = try inproc.Worker.spawn(gpa, &self.actor, &self.registry, "test-caller");
        self.worker = try WebToolsWorker.start(gpa, &self.actor, &self.registry, self.io_backing.io(), opts);
        return self;
    }

    fn deinit(self: *Harness) void {
        const gpa = self.actor.gpa;
        self.worker.stop();
        self.caller.stop();
        self.actor.post(.shutdown);
        self.kernel.join();
        self.actor.deinit();
        self.registry.deinit();
        self.io_backing.deinit();
        gpa.destroy(self);
    }
};

test "bus: both functions registered; malformed request bytes ⇒ structured error reply" {
    var h = try Harness.init(testing.allocator, .{});
    defer h.deinit();

    // Unparseable / non-object ⇒ bus handler_failed (tools_ops pattern).
    const bad_fetch = try h.caller.call("zygos::tools::web_fetch", "\"not-a-request-object\"");
    defer bad_fetch.deinit(testing.allocator);
    try testing.expect(bad_fetch == .err);
    try testing.expectEqualStrings("handler_failed", bad_fetch.err);

    const bad_search = try h.caller.call("zygos::tools::web_search", "42");
    defer bad_search.deinit(testing.allocator);
    try testing.expect(bad_search == .err);
    try testing.expectEqualStrings("handler_failed", bad_search.err);

    // Parseable but invalid URL fails closed as a tool-result error shape —
    // never a crash, never a socket.
    const inv = try h.caller.call("zygos::tools::web_fetch", "{\"url\":\"file:///etc/passwd\"}");
    defer inv.deinit(testing.allocator);
    try testing.expect(inv == .ok);
    try testing.expect(std.mem.indexOf(u8, inv.ok, "InvalidUrl") != null);

    // Missing search config also structured, no socket.
    const nos = try h.caller.call("zygos::tools::web_search", "{\"query\":\"zig\"}");
    defer nos.deinit(testing.allocator);
    try testing.expect(nos == .ok);
    try testing.expect(std.mem.indexOf(u8, nos.ok, "SearchNotConfigured") != null);
}

test "search with no key configured ⇒ structured error naming the env var" {
    var h = try Harness.init(testing.allocator, .{
        .search = .{
            .endpoint = "https://api.search.brave.com",
            .key_env = "BRAVE_API_KEY",
            .key = null,
            .engine = .brave,
        },
    });
    defer h.deinit();

    const res = try h.caller.call("zygos::tools::web_search", "{\"query\":\"zig lang\",\"count\":3}");
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try testing.expect(std.mem.indexOf(u8, res.ok, "MissingSearchKey") != null);
    try testing.expect(std.mem.indexOf(u8, res.ok, "BRAVE_API_KEY") != null);
}

test "no leaks across handler loops" {
    var h = try Harness.init(testing.allocator, .{
        .search = .{
            .endpoint = "https://api.search.brave.com",
            .key_env = "BRAVE_API_KEY",
            .key = null,
            .engine = .brave,
        },
    });
    defer h.deinit();

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const a = try h.caller.call("zygos::tools::web_fetch", "{\"url\":\"ftp://x\"}");
        a.deinit(testing.allocator);
        const b = try h.caller.call("zygos::tools::web_search", "{\"query\":\"q\"}");
        b.deinit(testing.allocator);
        const c = try h.caller.call("zygos::tools::web_fetch", "\"nope\"");
        c.deinit(testing.allocator);
    }
}
