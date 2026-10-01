//! Web-tools worker (Y1/Y2, docs/specs/web-tools.md).
//!
//! Registers `zygos::tools::{web_search,web_fetch}` on the bus. Lives in
//! `src/net/` because handlers hold `std.Io` for HTTP (Z-02). The pure layer
//! (html/URL/JSON) is fixture-tested; the HTTP leg compiles but is never
//! exercised by `zig build test` — bus tests fail closed on invalid input
//! before any socket opens.

const std = @import("std");
const jsonx = @import("../worker/jsonx.zig");
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
    /// SSRF screen escape hatch (ZYGOS_FETCH_ALLOW_PRIVATE=1): allows
    /// loopback/private hosts — localhost stubs, self-hosted mirrors.
    allow_private_hosts: bool = false,
};

pub const html = @import("web/html.zig");
pub const search = @import("web/search.zig");

pub const HtmlText = html.HtmlText;
pub const htmlToText = html.htmlToText;
pub const SearchResult = search.SearchResult;
pub const ParseError = search.ParseError;
pub const parseBraveResults = search.parseBraveResults;
pub const parseSearxngResults = search.parseSearxngResults;
const renderResults = search.renderResults;

pub const ValidateError = error{InvalidUrl};

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

// ---------------------------------------------------------------------------
// SSRF screen (fetch-time; validateUrl above is scheme admission only)
// ---------------------------------------------------------------------------

/// Default-refused host classes: loopback (name and literal), link-local,
/// private ranges, unspecified, multicast, the RFC 6598 shared range, and
/// their IPv6 forms (incl. v4-mapped). Prompt-injected content must not
/// aim web_fetch at internal services or cloud metadata. DNS names other
/// than localhost pass — resolve-then-rebind is documented out of scope.
pub fn hostBlocked(host_text: []const u8) bool {
    // IPv6 literals arrive bracketed in the authority: [::1], [fe80::1].
    if (host_text.len >= 2 and host_text[0] == '[' and host_text[host_text.len - 1] == ']')
        return v6Blocked(host_text[1 .. host_text.len - 1]);
    if (parseIpv4(host_text)) |b| return isBlockedV4(b[0], b[1], b[2], b[3]);
    return isLocalName(host_text);
}

fn isLocalName(name: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(name, "localhost")) return true;
    return name.len > ".localhost".len and
        std.ascii.endsWithIgnoreCase(name, ".localhost");
}

fn isBlockedV4(a: u8, b: u8, c: u8, d: u8) bool {
    _ = c;
    _ = d;
    return switch (a) {
        0, 10, 127 => true, // this-network, private, loopback
        169 => b == 254, // link-local 169.254.0.0/16 (incl. metadata 169.254.169.254)
        172 => b >= 16 and b <= 31, // private 172.16.0.0/12
        192 => b == 168, // private 192.168.0.0/16
        100 => b >= 64 and b <= 127, // RFC 6598 shared
        224...255 => true, // multicast + reserved
        else => false,
    };
}

/// Strict dotted-quad parse (no ports — Uri separates the port).
fn parseIpv4(s: []const u8) ?[4]u8 {
    var out: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, s, '.');
    var i: usize = 0;
    while (it.next()) |part| {
        if (i >= 4) return null;
        if (part.len == 0 or part.len > 3) return null;
        var v: u16 = 0;
        for (part) |ch| {
            if (ch < '0' or ch > '9') return null;
            v = v * 10 + (ch - '0');
        }
        if (v > 255) return null;
        out[i] = @intCast(v);
        i += 1;
    }
    if (i != 4) return null;
    return out;
}

fn v6Blocked(s: []const u8) bool {
    if (s.len == 0) return true;
    if (std.mem.eql(u8, s, "::1") or std.mem.eql(u8, s, "::")) return true;
    // v4-mapped ::ffff:a.b.c.d — screen the embedded v4.
    if (std.mem.startsWith(u8, s, "::ffff:")) {
        if (parseIpv4(s["::ffff:".len..])) |b| return isBlockedV4(b[0], b[1], b[2], b[3]);
        return true; // unparseable mapped form: fail closed
    }
    // fe80::/10 (fe8x-febx), fc00::/7 (fc/fd), ff00::/8, and any other
    // "::"-prefixed special form — conservative fail closed.
    if (startsWithHex(s, "fe8") or startsWithHex(s, "fe9") or
        startsWithHex(s, "fea") or startsWithHex(s, "feb")) return true;
    if (startsWithHex(s, "fc") or startsWithHex(s, "fd")) return true;
    if (startsWithHex(s, "ff")) return true;
    if (std.mem.startsWith(u8, s, "::")) return true;
    return false;
}

fn startsWithHex(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    for (s[0..prefix.len], prefix) |a, b| {
        if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    }
    return true;
}

/// True when `url`'s host class is refused by the screen. Unparseable or
/// host-less URLs are not this gate's problem (validateUrl answers those).
pub fn fetchHostBlocked(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    const host = uri.host orelse return false;
    const text = switch (host) {
        .raw => |s| s,
        .percent_encoded => |s| s,
    };
    return hostBlocked(text);
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
    /// SSRF screen escape hatch (ZYGOS_FETCH_ALLOW_PRIVATE=1): localhost
    /// stubs and self-hosted mirrors need it; default is screen-on.
    allow_private_hosts: bool = false,
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

        // SSRF screen: private/loopback/link-local hosts refuse (structured,
        // fail closed) unless the operator allowed them (localhost stubs,
        // self-hosted mirrors — ZYGOS_FETCH_ALLOW_PRIVATE=1).
        if (!self.allow_private_hosts and fetchHostBlocked(url))
            return errorReply(arena, "PrivateHost");

        const body = self.transport(self.transport_ctx, self.gpa, self.io, url, &.{}, self.max_fetch_bytes) catch |err| switch (err) {
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

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

fn parseObject(arena: std.mem.Allocator, request_json: []const u8) error{Failed}!json.ObjectMap {
    const root = json.parseFromSliceLeaky(json.Value, arena, request_json, .{}) catch
        return error.Failed;
    return if (root == .object) root.object else error.Failed;
}

const strField = jsonx.strField;

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

// ===========================================================================
// Tests — docs/specs/web-tools.md contract (RED first; no sockets)
// ===========================================================================

const testing = std.testing;

test "validateUrl: https/http pass; file:, ftp:, garbage ⇒ error" {
    try validateUrl("https://example.com/path");
    try validateUrl("http://localhost:8080/");
    try testing.expectError(error.InvalidUrl, validateUrl("file:///etc/passwd"));
    try testing.expectError(error.InvalidUrl, validateUrl("ftp://files.example.com/x"));
    try testing.expectError(error.InvalidUrl, validateUrl("not a url"));
    try testing.expectError(error.InvalidUrl, validateUrl(""));
}

test "SSRF screen: loopback/private/link-local hosts blocked; public pass" {
    // Loopback and local names.
    try testing.expect(fetchHostBlocked("http://localhost/x"));
    try testing.expect(fetchHostBlocked("http://api.localhost/x"));
    try testing.expect(fetchHostBlocked("http://LOCALHOST/x"));
    // Private / link-local / metadata / shared v4.
    try testing.expect(fetchHostBlocked("http://127.0.0.1/x"));
    try testing.expect(fetchHostBlocked("http://10.1.2.3/x"));
    try testing.expect(fetchHostBlocked("http://192.168.1.1/x"));
    try testing.expect(fetchHostBlocked("http://172.16.0.9/x"));
    try testing.expect(fetchHostBlocked("http://172.31.255.1/x"));
    try testing.expect(fetchHostBlocked("http://169.254.169.254/latest/meta-data"));
    try testing.expect(fetchHostBlocked("http://0.0.0.0/x"));
    try testing.expect(fetchHostBlocked("http://100.64.0.1/x"));
    // IPv6 loopback / link-local / unique-local / v4-mapped private.
    try testing.expect(fetchHostBlocked("http://[::1]/x"));
    try testing.expect(fetchHostBlocked("http://[::]/x"));
    try testing.expect(fetchHostBlocked("http://[fe80::1]/x"));
    try testing.expect(fetchHostBlocked("http://[fd12:3456::1]/x"));
    try testing.expect(fetchHostBlocked("http://[::ffff:10.0.0.1]/x"));
    // Public hosts fetch.
    try testing.expect(!fetchHostBlocked("https://example.com/path"));
    try testing.expect(!fetchHostBlocked("http://8.8.8.8/x"));
    try testing.expect(!fetchHostBlocked("http://[2606:4700::6810:85e5]/x"));
    try testing.expect(!fetchHostBlocked("http://172.32.0.1/x")); // just outside 172.16/12
    // Not this gate's problem: garbage passes through to validateUrl.
    try testing.expect(!fetchHostBlocked("not a url"));
}

test "web_fetch: private host refuses with PrivateHost before the transport; the allow flag overrides" {
    var h = try Harness.init(testing.allocator, .{});
    defer h.deinit();

    const FetchFake = struct {
        calls: usize = 0,

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
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            return .{
                .bytes = try gpa.dupe(u8, "<html><body><p>internal mirror</p></body></html>"),
                .content_type = try gpa.dupe(u8, "text/html; charset=utf-8"),
            };
        }
    };

    var fake = FetchFake{};
    h.worker.transport = FetchFake.transport;
    h.worker.transport_ctx = &fake;

    // Screen on: cloud-metadata and loopback refuse without a transport call.
    const res = try h.caller.call("zygos::tools::web_fetch", "{\"url\":\"http://169.254.169.254/latest/meta-data\"}");
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try testing.expect(std.mem.indexOf(u8, res.ok, "PrivateHost") != null);
    try testing.expectEqual(@as(usize, 0), fake.calls);

    // Escape hatch (ZYGOS_FETCH_ALLOW_PRIVATE wiring target): rides the seam.
    h.worker.allow_private_hosts = true;
    const res2 = try h.caller.call("zygos::tools::web_fetch", "{\"url\":\"http://169.254.169.254/latest/meta-data\"}");
    defer res2.deinit(testing.allocator);
    try testing.expect(res2 == .ok);
    try testing.expect(std.mem.indexOf(u8, res2.ok, "internal mirror") != null);
    try testing.expectEqual(@as(usize, 1), fake.calls);
}

const fixture_brave =
    \\{"web":{"results":[
    \\  {"title":"Zig Programming Language","url":"https://ziglang.org/","description":"Zig is a general-purpose programming language."},
    \\  {"title":"Zig GitHub","url":"https://github.com/ziglang/zig","description":"General-purpose programming language and toolchain."}
    \\]}}
;

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

// Fetch must cross the same transport seam search already uses. A direct
// httpGet leaves `calls` at 0 and answers HttpFailed for this dead port.
test "fetch rides the transport seam" {
    var h = try Harness.init(testing.allocator, .{});
    defer h.deinit();

    const FetchFake = struct {
        calls: usize = 0,

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
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            return .{
                .bytes = try gpa.dupe(u8, "<html><body><p>Hello fetch seam</p></body></html>"),
                .content_type = try gpa.dupe(u8, "text/html; charset=utf-8"),
            };
        }
    };

    var fake = FetchFake{};
    h.worker.transport = FetchFake.transport;
    h.worker.transport_ctx = &fake;

    const res = try h.caller.call("zygos::tools::web_fetch", "{\"url\":\"https://example.com/x\"}");
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try testing.expectEqual(@as(usize, 1), fake.calls);
    try testing.expect(std.mem.indexOf(u8, res.ok, "Hello fetch seam") != null);
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
