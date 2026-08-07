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
    /// 429-only search retry budget: rate limits (Brave free tier is ~1 rps)
    /// get one polite retry; every other status still fails closed at once.
    search_retry_max: usize = 1,
    search_retry_delay_ms: u64 = 1100,
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

/// Injection seam for the HTTP leg: unit tests swap in a socket-free fake to
/// exercise the retry path; real runs use `defaultTransport` (httpGet).
pub const Transport = *const fn (
    ctx: ?*anyopaque,
    gpa: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    headers: []const std.http.Header,
    max_bytes: usize,
) HttpGetError!HttpBody;

fn defaultTransport(
    ctx: ?*anyopaque,
    gpa: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    headers: []const std.http.Header,
    max_bytes: usize,
) HttpGetError!HttpBody {
    _ = ctx;
    return httpGet(gpa, io, url, headers, max_bytes);
}

pub const WebToolsWorker = struct {
    gpa: std.mem.Allocator,
    worker: *inproc.Worker,
    io: std.Io,
    max_fetch_bytes: usize,
    max_text_bytes: usize,
    search_retry_max: usize,
    search_retry_delay_ms: u64,
    transport: Transport = defaultTransport,
    transport_ctx: ?*anyopaque = null,
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
            .search_retry_max = opts.search_retry_max,
            .search_retry_delay_ms = opts.search_retry_delay_ms,
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
            error.HttpFailed => {
                log.warn("web_fetch {s}: transport failure", .{url});
                return errorReply(arena, "HttpFailed");
            },
            error.NonTextContent => return errorReply(arena, "NonTextContent"),
            error.HttpStatus => {
                log.warn("web_fetch {s}: HTTP {d}", .{ url, last_http_status });
                return statusReply(arena);
            },
        };
        defer self.gpa.free(body.bytes);
        defer self.gpa.free(body.content_type);

        if (!isTextContentType(body.content_type)) return errorReply(arena, "NonTextContent");

        const converted = try htmlToText(arena, body.bytes, self.max_text_bytes);
        const pct: usize = if (body.bytes.len == 0) 0 else converted.text.len * 100 / body.bytes.len;
        log.info("web_fetch {s}: {d} bytes → {d} text ({d}% of source, truncated: {})", .{
            url, body.bytes.len, converted.text.len, pct, converted.truncated,
        });
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

        var attempt: usize = 0;
        const body = while (true) {
            break self.transport(self.transport_ctx, self.gpa, self.io, url, headers, self.max_fetch_bytes) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.HttpFailed => {
                    log.warn("web_search \"{s}\": transport failure", .{query});
                    return errorReply(arena, "HttpFailed");
                },
                error.NonTextContent => return errorReply(arena, "NonTextContent"),
                error.HttpStatus => {
                    log.warn("web_search \"{s}\": HTTP {d} (attempt {d})", .{ query, last_http_status, attempt });
                    if (last_http_status == 429 and attempt < self.search_retry_max) {
                        attempt += 1;
                        if (self.search_retry_delay_ms > 0) {
                            var interval: std.c.timespec = .{
                                .sec = @intCast(self.search_retry_delay_ms / 1000),
                                .nsec = @intCast((self.search_retry_delay_ms % 1000) * std.time.ns_per_ms),
                            };
                            var rem: std.c.timespec = undefined;
                            _ = std.c.nanosleep(&interval, &rem);
                        }
                        continue;
                    }
                    return statusReply(arena);
                },
            };
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

/// Socket-free fake transport: replays a scripted sequence of outcomes
/// (either an HTTP status failure or a JSON body) and counts calls.
const FakeTransport = struct {
    script: []const Step,
    calls: usize = 0,

    const Step = union(enum) { status: u16, body: []const u8 };

    fn transport(
        ctx: ?*anyopaque,
        gpa: std.mem.Allocator,
        io: std.Io,
        url: []const u8,
        headers: []const std.http.Header,
        max_bytes: usize,
    ) HttpGetError!HttpBody {
        _ = io;
        _ = url;
        _ = headers;
        _ = max_bytes;
        const self: *FakeTransport = @ptrCast(@alignCast(ctx.?));
        const step = self.script[@min(self.calls, self.script.len - 1)];
        self.calls += 1;
        switch (step) {
            .status => |code| {
                last_http_status = code;
                return error.HttpStatus;
            },
            .body => |b| return .{
                .bytes = try gpa.dupe(u8, b),
                .content_type = try gpa.dupe(u8, "application/json"),
            },
        }
    }
};

const brave_search_opts: Options = .{
    .search = .{
        .endpoint = "https://api.search.brave.com",
        .key_env = "BRAVE_API_KEY",
        .key = "test-key",
        .engine = .brave,
    },
    .search_retry_delay_ms = 0,
};

test "search retries once on 429 and succeeds on the second attempt" {
    var h = try Harness.init(testing.allocator, brave_search_opts);
    defer h.deinit();
    var fake = FakeTransport{ .script = &.{ .{ .status = 429 }, .{ .body = fixture_brave } } };
    h.worker.transport = FakeTransport.transport;
    h.worker.transport_ctx = &fake;

    const res = try h.caller.call("zygos::tools::web_search", "{\"query\":\"zig\"}");
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try testing.expect(std.mem.indexOf(u8, res.ok, "Zig Programming Language") != null);
    try testing.expectEqual(@as(usize, 2), fake.calls);
}

test "persistent 429 exhausts the retry budget and fails closed with the status" {
    var h = try Harness.init(testing.allocator, brave_search_opts);
    defer h.deinit();
    var fake = FakeTransport{ .script = &.{.{ .status = 429 }} };
    h.worker.transport = FakeTransport.transport;
    h.worker.transport_ctx = &fake;

    const res = try h.caller.call("zygos::tools::web_search", "{\"query\":\"zig\"}");
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try testing.expect(std.mem.indexOf(u8, res.ok, "\"status\":429") != null);
    try testing.expectEqual(@as(usize, 2), fake.calls); // 1 attempt + 1 retry
}

test "non-429 status is never retried" {
    var h = try Harness.init(testing.allocator, brave_search_opts);
    defer h.deinit();
    var fake = FakeTransport{ .script = &.{.{ .status = 500 }} };
    h.worker.transport = FakeTransport.transport;
    h.worker.transport_ctx = &fake;

    const res = try h.caller.call("zygos::tools::web_search", "{\"query\":\"zig\"}");
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try testing.expect(std.mem.indexOf(u8, res.ok, "\"status\":500") != null);
    try testing.expectEqual(@as(usize, 1), fake.calls);
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
