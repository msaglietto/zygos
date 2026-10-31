//! Web-tools worker (Y1/Y2, docs/specs/web-tools.md).
//!
//! Registers `zygos::tools::{web_search,web_fetch}` on the bus. Lives in
//! `src/net/` because handlers hold `std.Io` for HTTP (Z-02). The pure layer
//! (html/URL/JSON) is fixture-tested; the HTTP leg compiles but is never
//! exercised by `zig build test` — bus tests fail closed on invalid input
//! before any socket opens.
//!
//! `web_fetch` screens the URL, every redirect hop (followed here, never by
//! std.http) and every address a host name resolves to, then dials only the
//! addresses it screened.

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
    /// SSRF screen escape hatch (ZYGOS_FETCH_ALLOW_PRIVATE=1): bypasses the
    /// whole screen (literal, DNS answers, redirect hops) — localhost stubs,
    /// self-hosted mirrors.
    allow_private_hosts: bool = false,
    /// Redirects web_fetch follows by hand; each hop is screened like the
    /// original URL. One more refuses with TooManyRedirects.
    max_redirects: usize = 3,
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

/// https/http only. Rejects file:, ftp:, and anything Uri.parse rejects. Every
/// hop and both screen modes pass through here, so the host bound lives here:
/// `std.Uri.getHost` treats an encoded host longer than `HostName.max_len` as
/// unreachable and aborts the process, and Uri.parse does not bound it.
pub fn validateUrl(url: []const u8) ValidateError!void {
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    if (!(std.ascii.eqlIgnoreCase(uri.scheme, "http") or std.ascii.eqlIgnoreCase(uri.scheme, "https")))
        return error.InvalidUrl;
    // A fetchable URL needs a host; bare "http:" / scheme-only garbage fails.
    const host = uri.host orelse return error.InvalidUrl;
    // The decoded host is never longer than its encoded text.
    const text = switch (host) {
        .raw => |s| s,
        .percent_encoded => |s| s,
    };
    if (text.len > std.Io.net.HostName.max_len) return error.InvalidUrl;
}

// ---------------------------------------------------------------------------
// SSRF screen (fetch-time; validateUrl above is scheme admission only)
// ---------------------------------------------------------------------------

/// Literal screen on the URL's host text. Default-refused classes: loopback
/// (name and literal), link-local, private ranges, unspecified, multicast, the
/// RFC 6598 shared range, `192.0.0.0/24` and `198.18.0.0/15`, and their IPv6
/// forms (v4-mapped, NAT64 `64:ff9b::/96` and 6to4 `2002::/16` included), plus
/// IPv6 `0000::/8`, local-use NAT64 `64:ff9b:1::/48` and discard `100::/64`.
/// Prompt-injected content must not aim
/// web_fetch at internal services or cloud metadata. A DNS name other than
/// localhost passes here: `fetchHandler` resolves it and screens every answer
/// with `addressBlocked`, and the connection dials the screened addresses, so
/// a second DNS answer cannot redirect it.
pub fn hostBlocked(host_text: []const u8) bool {
    // IPv6 literals arrive bracketed in the authority: [::1], [fe80::1].
    if (unbracket(host_text)) |inner| return v6Blocked(inner);
    if (parseIpv4(host_text)) |b| return isBlockedV4(b[0], b[1], b[2], b[3]);
    return isLocalName(host_text);
}

/// The one classifier for resolved answers and literals alike. IPv6 embeds
/// IPv4 in several forms, each screened as the embedded address: v4-mapped
/// `::ffff:0:0/96`, NAT64 `64:ff9b::/96` and 6to4 `2002::/16`.
pub fn addressBlocked(addr: std.Io.net.IpAddress) bool {
    return switch (addr) {
        .ip4 => |a| isBlockedV4(a.bytes[0], a.bytes[1], a.bytes[2], a.bytes[3]),
        .ip6 => |a| v6BytesBlocked(a.bytes),
    };
}

/// The address inside a bracketed IPv6 authority host (`[::1]`), else null.
fn unbracket(host: []const u8) ?[]const u8 {
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') return host[1 .. host.len - 1];
    return null;
}

/// Port a URL without an explicit one connects to.
fn defaultPort(scheme: []const u8) u16 {
    return if (std.ascii.eqlIgnoreCase(scheme, "https")) 443 else 80;
}

fn isLocalName(name: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(name, "localhost")) return true;
    return name.len > ".localhost".len and
        std.ascii.endsWithIgnoreCase(name, ".localhost");
}

fn isBlockedV4(a: u8, b: u8, c: u8, d: u8) bool {
    _ = d;
    return switch (a) {
        0, 10, 127 => true, // this-network, private, loopback
        169 => b == 254, // link-local 169.254.0.0/16 (incl. metadata 169.254.169.254)
        172 => b >= 16 and b <= 31, // private 172.16.0.0/12
        192 => b == 168 or (b == 0 and c == 0), // private 192.168.0.0/16, IETF protocol 192.0.0.0/24
        198 => b == 18 or b == 19, // benchmarking 198.18.0.0/15
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
    const addr = std.Io.net.Ip6Address.parse(s, 0) catch return true; // unparseable: fail closed
    return v6BytesBlocked(addr.bytes);
}

fn v6BytesBlocked(b: [16]u8) bool {
    const embedded = struct {
        fn blocked(v4: *const [4]u8) bool {
            return isBlockedV4(v4[0], v4[1], v4[2], v4[3]);
        }
    }.blocked;
    // ::ffff:0:0/96 v4-mapped.
    if (std.mem.allEqual(u8, b[0..10], 0) and b[10] == 0xff and b[11] == 0xff)
        return embedded(b[12..16]);
    // 64:ff9b::/96 NAT64 well-known prefix. Both embedded forms come before
    // the 0000::/8 refusal below, which would otherwise take a public embedded
    // address along with them.
    if (b[0] == 0x00 and b[1] == 0x64 and b[2] == 0xff and b[3] == 0x9b and
        std.mem.allEqual(u8, b[4..12], 0)) return embedded(b[12..16]);
    // 64:ff9b:1::/48 local-use NAT64 (RFC 8215): operator-chosen embedding.
    if (b[0] == 0x00 and b[1] == 0x64 and b[2] == 0xff and b[3] == 0x9b and
        b[4] == 0x00 and b[5] == 0x01) return true;
    // 0000::/8: unspecified, loopback, v4-compatible, SIIT ::ffff:0:0:0/96 and
    // every other literal that opens with a zero byte.
    if (b[0] == 0x00) return true;
    // 100::/64 discard-only.
    if (b[0] == 0x01 and b[1] == 0x00 and std.mem.allEqual(u8, b[2..8], 0)) return true;
    // 2002::/16 6to4.
    if (b[0] == 0x20 and b[1] == 0x02) return embedded(b[2..6]);
    if (b[0] == 0xfe and (b[1] & 0xc0) == 0x80) return true; // fe80::/10 link-local
    if (b[0] == 0xfe and (b[1] & 0xc0) == 0xc0) return true; // fec0::/10 site-local
    if ((b[0] & 0xfe) == 0xfc) return true; // fc00::/7 unique-local
    if (b[0] == 0xff) return true; // ff00::/8 multicast
    return false;
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

const ScreenError = error{ PrivateHost, ResolveFailed };

/// Most addresses one host may resolve to; a longer answer is refused rather
/// than truncated, because a dropped address is an unscreened one.
const dial_max = 32;

const max_location_bytes = 8 * 1024;

/// Resolves a raw `Location` against the hop that issued it and returns the
/// next URL without its fragment. The result is not yet admitted: the hop loop
/// runs `validateUrl` and the screen on it like on the original URL.
fn resolveRedirect(
    arena: std.mem.Allocator,
    base_url: []const u8,
    location: []const u8,
) error{ OutOfMemory, InvalidRedirect }![]const u8 {
    if (location.len == 0 or location.len > max_location_bytes) return error.InvalidRedirect;
    // resolveInPlace falls back to reading a malformed absolute URI such as
    // "http://" as a relative path; a scheme-prefixed Location must parse whole.
    if (hasScheme(location)) _ = std.Uri.parse(location) catch return error.InvalidRedirect;
    const base = std.Uri.parse(base_url) catch return error.InvalidRedirect;
    // resolveInPlace copies nothing itself: the Location sits at the front of
    // the buffer and a merged path is built after it.
    const buf = try arena.alloc(u8, location.len * 2 + base_url.len + 8);
    @memcpy(buf[0..location.len], location);
    var aux: []u8 = buf;
    const next = base.resolveInPlace(location.len, &aux) catch return error.InvalidRedirect;
    return std.fmt.allocPrint(arena, "{f}", .{next.fmt(.{
        .scheme = true,
        .authentication = true,
        .authority = true,
        .path = true,
        .query = true,
    })});
}

fn hasScheme(s: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, s, ':') orelse return false;
    if (colon == 0 or !std.ascii.isAlphabetic(s[0])) return false;
    for (s[1..colon]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.')) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Worker
// ---------------------------------------------------------------------------

pub const TransportRequest = struct {
    url: []const u8,
    headers: []const std.http.Header = &.{},
    max_bytes: usize,
    /// Screened addresses to dial, in order. Empty: std.http resolves the host
    /// itself. The URL's host name still drives TLS verification and `Host`.
    dial: []const std.Io.net.IpAddress = &.{},
    /// false: a 3xx comes back as `HttpBody.redirect` instead of being followed.
    follow_redirects: bool = true,
};

/// Injection seam for the HTTP leg: unit tests swap in a socket-free fake to
/// exercise the retry and redirect paths; real runs use `defaultTransport`
/// (httpGet).
pub const Transport = *const fn (
    ctx: ?*anyopaque,
    gpa: std.mem.Allocator,
    io: std.Io,
    req: TransportRequest,
) HttpGetError!HttpBody;

fn defaultTransport(
    ctx: ?*anyopaque,
    gpa: std.mem.Allocator,
    io: std.Io,
    req: TransportRequest,
) HttpGetError!HttpBody {
    _ = ctx;
    return httpGet(gpa, io, req);
}

pub const ResolveError = error{ResolveFailed};

/// Injection seam for name resolution: writes the answer into `out` and
/// returns how many entries it wrote. Every answer must be returned or the
/// call must fail; silently dropping one would let it escape the screen.
pub const Resolver = *const fn (
    ctx: ?*anyopaque,
    io: std.Io,
    host: []const u8,
    port: u16,
    out: []std.Io.net.IpAddress,
) ResolveError!usize;

fn defaultResolver(
    ctx: ?*anyopaque,
    io: std.Io,
    host: []const u8,
    port: u16,
    out: []std.Io.net.IpAddress,
) ResolveError!usize {
    _ = ctx;
    const HostName = std.Io.net.HostName;
    const name = HostName.init(host) catch return error.ResolveFailed;
    var buf: [dial_max]HostName.LookupResult = undefined;
    var queue: std.Io.Queue(HostName.LookupResult) = .init(&buf);
    // `async` may run the lookup inline, and a lookup that puts more answers
    // than the queue holds then blocks with no consumer. The drain loop below
    // has to run beside it, so an Io that cannot is a failed resolve.
    var lookup = io.concurrent(HostName.lookup, .{ name, io, &queue, HostName.LookupOptions{ .port = port } }) catch
        return error.ResolveFailed;
    var n: usize = 0;
    var overflow = false;
    while (queue.getOne(io)) |result| switch (result) {
        .address => |addr| {
            if (n < out.len) {
                out[n] = addr;
                n += 1;
            } else overflow = true;
        },
        .canonical_name => {},
    } else |err| switch (err) {
        error.Canceled => {
            lookup.cancel(io) catch {};
            // The failure is ours to report, but the caller's cancelation
            // request must still be seen at its next cancelation point.
            io.recancel();
            return error.ResolveFailed;
        },
        error.Closed => {},
    }
    lookup.await(io) catch return error.ResolveFailed;
    if (overflow or n == 0) return error.ResolveFailed;
    return n;
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
    resolver: Resolver = defaultResolver,
    resolver_ctx: ?*anyopaque = null,
    max_redirects: usize,
    /// SSRF screen escape hatch (ZYGOS_FETCH_ALLOW_PRIVATE=1): bypasses the
    /// whole screen (literal, DNS answers, redirect hops) — localhost stubs,
    /// self-hosted mirrors. Default is screen-on.
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
            .max_redirects = opts.max_redirects,
            .allow_private_hosts = opts.allow_private_hosts,
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

        // Each hop is screened like the original URL and fetched with the
        // transport's own redirect handling off, so std.http never follows a
        // Location this worker has not seen. The escape hatch
        // (ZYGOS_FETCH_ALLOW_PRIVATE=1) skips the screen but still hand-follows
        // under the same cap.
        var current: []const u8 = url;
        var redirects: usize = 0;
        const body = while (true) {
            validateUrl(current) catch |err| switch (err) {
                error.InvalidUrl => {
                    if (redirects > 0) log.warn("web_fetch {s}: invalid redirect target", .{current});
                    return errorReply(arena, if (redirects == 0) "InvalidUrl" else "InvalidRedirect");
                },
            };

            var dial_buf: [dial_max]std.Io.net.IpAddress = undefined;
            const dial: []const std.Io.net.IpAddress = if (self.allow_private_hosts)
                &.{}
            else
                self.screenDial(current, &dial_buf) catch |err| {
                    log.warn("web_fetch {s}: refused ({s}) at redirect {d}", .{ current, @errorName(err), redirects });
                    return errorReply(arena, @errorName(err));
                };

            const hop_reply = self.transport(self.transport_ctx, self.gpa, self.io, .{
                .url = current,
                .max_bytes = self.max_fetch_bytes,
                .dial = dial,
                .follow_redirects = false,
            }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.HttpFailed => {
                    log.warn("web_fetch {s}: transport failure", .{current});
                    return errorReply(arena, "HttpFailed");
                },
                error.NonTextContent => return errorReply(arena, "NonTextContent"),
                error.HttpStatus => {
                    log.warn("web_fetch {s}: HTTP {d}", .{ current, last_http_status });
                    return statusReply(arena);
                },
            };
            const location = hop_reply.redirect orelse break hop_reply;
            defer self.freeBody(hop_reply);

            if (redirects >= self.max_redirects) {
                log.warn("web_fetch {s}: redirect limit {d} exceeded", .{ current, self.max_redirects });
                return errorReply(arena, "TooManyRedirects");
            }
            current = resolveRedirect(arena, current, location) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidRedirect => {
                    log.warn("web_fetch {s}: unusable redirect Location", .{current});
                    return errorReply(arena, "InvalidRedirect");
                },
            };
            redirects += 1;
        };
        defer self.freeBody(body);

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

    fn freeBody(self: *WebToolsWorker, body: HttpBody) void {
        self.gpa.free(body.bytes);
        self.gpa.free(body.content_type);
        if (body.redirect) |r| self.gpa.free(r);
    }

    /// Addresses the transport may dial for `url`: the literal itself, or every
    /// resolved answer. Any blocked address refuses the whole URL, and a name
    /// that does not resolve refuses too, so nothing is left for std.http to
    /// resolve again.
    fn screenDial(
        self: *WebToolsWorker,
        url: []const u8,
        out: *[dial_max]std.Io.net.IpAddress,
    ) ScreenError![]const std.Io.net.IpAddress {
        if (fetchHostBlocked(url)) return error.PrivateHost;
        const uri = std.Uri.parse(url) catch return error.PrivateHost;
        const port: u16 = uri.port orelse defaultPort(uri.scheme);
        var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
        // The decoded host is the one std.http connects to; `%31%32%37.0.0.1`
        // is 127.0.0.1 only after decoding, so it is screened again here.
        const host = (uri.getHost(&host_buf) catch return error.ResolveFailed).bytes;
        if (hostBlocked(host)) return error.PrivateHost;

        var n: usize = 1;
        if (unbracket(host)) |inner| {
            out[0] = std.Io.net.IpAddress.parseIp6(inner, port) catch return error.PrivateHost;
        } else if (parseIpv4(host)) |b| {
            out[0] = .{ .ip4 = .{ .bytes = b, .port = port } };
        } else {
            n = self.resolver(self.resolver_ctx, self.io, host, port, out) catch return error.ResolveFailed;
            if (n == 0 or n > out.len) return error.ResolveFailed;
        }
        for (out[0..n]) |addr| {
            if (addressBlocked(addr)) return error.PrivateHost;
        }
        return out[0..n];
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
            break self.transport(self.transport_ctx, self.gpa, self.io, .{ .url = url, .headers = headers, .max_bytes = self.max_fetch_bytes }) catch |err| switch (err) {
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
        defer self.freeBody(body);

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
    /// Raw `Location` of a 3xx the transport did not follow (empty when the
    /// response carried none). Set only when `follow_redirects` was false; then
    /// `bytes` and `content_type` are empty. All three are gpa-owned.
    redirect: ?[]u8 = null,
};

/// Sentinel: `error.HttpStatus` is raised with the numeric code stashed in
/// threadlocal so handlers can name it in the structured reply. Unit tests
/// never open a socket, so this path is only for real runs / future e2e.
threadlocal var last_http_status: u16 = 0;

fn httpGet(
    gpa: std.mem.Allocator,
    io: std.Io,
    request: TransportRequest,
) HttpGetError!HttpBody {
    const uri = std.Uri.parse(request.url) catch return error.HttpFailed;

    // Pooled connections (pinned or not) are released by `http_req.deinit` and
    // destroyed by `client.deinit`.
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const pinned: ?*std.http.Client.Connection = if (request.dial.len == 0)
        null
    else
        try dialPinned(&client, io, uri, request.dial);

    const redirect_behavior: std.http.Client.Request.RedirectBehavior =
        if (request.follow_redirects) @enumFromInt(3) else .unhandled;
    var http_req = client.request(.GET, uri, .{
        .extra_headers = request.headers,
        .redirect_behavior = redirect_behavior,
        .connection = pinned,
    }) catch {
        if (pinned) |c| {
            c.closing = true;
            client.connection_pool.release(c, io);
        }
        return error.HttpFailed;
    };
    defer http_req.deinit();
    http_req.accept_encoding = accepted_encodings;

    http_req.sendBodiless() catch return error.HttpFailed;

    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = http_req.receiveHead(&redirect_buf) catch return error.HttpFailed;

    // Same classification std.http uses when it follows: 3xx except 304.
    if (!request.follow_redirects and response.head.status.class() == .redirect and
        response.head.status != .not_modified)
    {
        const location = try gpa.dupe(u8, response.head.location orelse "");
        errdefer gpa.free(location);
        const bytes = try gpa.alloc(u8, 0);
        errdefer gpa.free(bytes);
        const ct = try gpa.alloc(u8, 0);
        // The redirect body is never read; closing keeps `deinit` from draining it.
        http_req.connection.?.closing = true;
        return .{ .bytes = bytes, .content_type = ct, .redirect = location };
    }

    if (response.head.status.class() != .success) {
        last_http_status = @intFromEnum(response.head.status);
        return error.HttpStatus;
    }

    const ct_raw = response.head.content_type orelse "application/octet-stream";
    const ct = gpa.dupe(u8, ct_raw) catch return error.OutOfMemory;
    errdefer gpa.free(ct);

    // Decode what the server sent: `reader` would hand back gzip bytes as text.
    // The window buffer exists only for a compressed body.
    const window = switch (response.head.content_encoding) {
        .identity => try gpa.alloc(u8, 0),
        .gzip, .deflate => try gpa.alloc(u8, std.compress.flate.max_window_len),
        // `accepted_encodings` never offers these and std refuses them in
        // `receiveHead`; stay closed if that ever changes.
        .zstd, .compress => return error.HttpFailed,
    };
    defer gpa.free(window);
    var transfer_buf: [16 * 1024]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buf, &decompress, window);

    const read = try readCapped(gpa, reader, request.max_bytes);
    errdefer gpa.free(read.bytes);
    // std's inflater reads the gzip CRC32 / zlib Adler-32 trailer but never
    // checks it, so a corrupted body that still inflates would pass. Check it
    // here when the whole body was read. A body cut at the cap is not checked.
    if (read.complete and !trailerMatches(&decompress, response.head.content_encoding, read.bytes))
        return error.HttpFailed;

    return .{ .bytes = read.bytes, .content_type = ct };
}

/// Does the checksum trailer `decompress` read match the decoded `bytes`?
/// gzip: CRC32 and length mod 2^32. deflate (zlib): Adler-32. Valid only after
/// the inflater consumed the whole stream.
fn trailerMatches(
    decompress: *const std.http.Decompress,
    encoding: std.http.ContentEncoding,
    bytes: []const u8,
) bool {
    return switch (encoding) {
        .gzip => blk: {
            const m = decompress.flate.container_metadata.gzip;
            break :blk m.crc == std.hash.Crc32.hash(bytes) and m.count == @as(u32, @truncate(bytes.len));
        },
        .deflate => decompress.flate.container_metadata.zlib.adler == std.hash.Adler32.hash(bytes),
        else => true,
    };
}

/// The content codings `httpGet` advertises and decodes. Anything else a
/// server sends is refused by std in `receiveHead`.
const accepted_encodings: @TypeOf(std.http.Client.Request.default_accept_encoding) = b: {
    var set: @TypeOf(std.http.Client.Request.default_accept_encoding) = @splat(false);
    set[@intFromEnum(std.http.ContentEncoding.gzip)] = true;
    set[@intFromEnum(std.http.ContentEncoding.deflate)] = true;
    set[@intFromEnum(std.http.ContentEncoding.identity)] = true;
    break :b set;
};

const CappedRead = struct {
    bytes: []u8,
    /// The reader hit its end before the cap, so `bytes` is the whole body.
    complete: bool,
};

/// Reads `reader` to its end, keeping at most `max_bytes`. `reader` yields
/// decoded bytes, so the cap bounds the decoded output: reading stops at the
/// cap and a small compressed body cannot expand past it. A failed read
/// (corrupt or truncated compressed data, broken transport) is
/// `error.HttpFailed`; the bytes read so far are never returned.
fn readCapped(
    gpa: std.mem.Allocator,
    reader: *std.Io.Reader,
    max_bytes: usize,
) error{ OutOfMemory, HttpFailed }!CappedRead {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    var chunk: [8 * 1024]u8 = undefined;
    var complete = true;
    while (true) {
        const n = reader.readSliceShort(&chunk) catch return error.HttpFailed;
        if (n == 0) break;
        const take = @min(n, max_bytes -| list.items.len);
        if (take > 0) list.appendSlice(gpa, chunk[0..take]) catch return error.OutOfMemory;
        // Past the cap we stop reading further bytes into the buffer; the
        // connection is dropped on req.deinit.
        if (list.items.len >= max_bytes) {
            complete = false;
            break;
        }
    }
    return .{
        .bytes = list.toOwnedSlice(gpa) catch return error.OutOfMemory,
        .complete = complete,
    };
}

/// Opens the connection to the first of `dial` that accepts. std.http would
/// otherwise resolve the URL's host again at connect time, which lets a second
/// DNS answer bypass the screen. The URL's own host stays the TLS server name,
/// certificate subject and pool key. `dial` entries are numeric, so the lookup
/// std runs on them is a parse, not a DNS query.
fn dialPinned(
    client: *std.http.Client,
    io: std.Io,
    uri: std.Uri,
    dial: []const std.Io.net.IpAddress,
) error{ HttpFailed, OutOfMemory }!*std.http.Client.Connection {
    const HostName = std.Io.net.HostName;
    const protocol = std.http.Client.Protocol.fromUri(uri) orelse return error.HttpFailed;
    var host_buf: [HostName.max_len]u8 = undefined;
    const url_host = uri.getHost(&host_buf) catch return error.HttpFailed;
    const port: u16 = uri.port orelse defaultPort(uri.scheme);
    // A bracketed IPv6 literal verifies as the bare address.
    const tls_name = unbracket(url_host.bytes) orelse url_host.bytes;

    if (protocol == .tls) try primeCaBundle(client, io);

    for (dial) |addr| {
        var text_buf: [48]u8 = undefined;
        const text = ipText(&text_buf, addr);
        return client.connectTcpOptions(.{
            .host = .{ .bytes = text },
            .port = port,
            .protocol = protocol,
            .proxied_host = .{ .bytes = tls_name },
            .proxied_port = port,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => {
                // Fail closed, but re-arm the caller's cancelation request.
                io.recancel();
                return error.HttpFailed;
            },
            else => continue,
        };
    }
    return error.HttpFailed;
}

/// `Client.request` loads the CA bundle and stamps `client.now` only when it
/// opens the connection itself. A pre-opened connection needs both first: TLS
/// setup asserts `now` and reads the bundle.
fn primeCaBundle(client: *std.http.Client, io: std.Io) error{HttpFailed}!void {
    if (comptime std.http.Client.disable_tls) return error.HttpFailed;
    var bundle: std.crypto.Certificate.Bundle = .empty;
    defer bundle.deinit(client.allocator);
    const now = std.Io.Clock.real.now(io);
    bundle.rescan(client.allocator, io, now) catch return error.HttpFailed;
    client.ca_bundle_lock.lock(io) catch return error.HttpFailed;
    defer client.ca_bundle_lock.unlock(io);
    client.now = now;
    std.mem.swap(std.crypto.Certificate.Bundle, &client.ca_bundle, &bundle);
}

/// Canonical numeric text without a port; IPv6 as eight hex groups.
fn ipText(buf: *[48]u8, addr: std.Io.net.IpAddress) []const u8 {
    return switch (addr) {
        .ip4 => |a| std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ a.bytes[0], a.bytes[1], a.bytes[2], a.bytes[3] }) catch unreachable,
        .ip6 => |a| blk: {
            var g: [8]u16 = undefined;
            for (&g, 0..) |*w, i| w.* = std.mem.readInt(u16, a.bytes[i * 2 ..][0..2], .big);
            break :blk std.fmt.bufPrint(buf, "{x}:{x}:{x}:{x}:{x}:{x}:{x}:{x}", .{ g[0], g[1], g[2], g[3], g[4], g[5], g[6], g[7] }) catch unreachable;
        },
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
            req: TransportRequest,
        ) HttpGetError!HttpBody {
            _ = io;
            _ = req;
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

fn offlineResolver(
    ctx: ?*anyopaque,
    io: std.Io,
    host: []const u8,
    port: u16,
    out: []std.Io.net.IpAddress,
) ResolveError!usize {
    _ = ctx;
    _ = io;
    _ = host;
    out[0] = .{ .ip4 = .{ .bytes = .{ 93, 184, 216, 34 }, .port = port } };
    return 1;
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
        // No test may reach real DNS: every name answers with one public address.
        self.worker.resolver = offlineResolver;
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
        req: TransportRequest,
    ) HttpGetError!HttpBody {
        _ = io;
        _ = req;
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
            req: TransportRequest,
        ) HttpGetError!HttpBody {
            _ = io;
            _ = req;
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

// ---------------------------------------------------------------------------
// Redirect-hop and DNS screen tests (scripted transport + resolver; no sockets)
// ---------------------------------------------------------------------------

const IpAddress = std.Io.net.IpAddress;

fn testIp(text: []const u8) IpAddress {
    return IpAddress.parse(text, 0) catch unreachable;
}

fn withPort(addr: IpAddress, port: u16) IpAddress {
    var c = addr;
    switch (c) {
        .ip4 => |*a| a.port = port,
        .ip6 => |*a| a.port = port,
    }
    return c;
}

/// Replays per-call steps and records what each call was asked to fetch.
const HopFake = struct {
    steps: []const Step,
    calls: usize = 0,
    url_buf: [max_rec][160]u8 = undefined,
    url_len: [max_rec]usize = @splat(0),
    dial_first: [max_rec]?IpAddress = @splat(null),
    dial_len: [max_rec]usize = @splat(0),
    follow: [max_rec]bool = @splat(true),

    const max_rec = 8;
    const Step = union(enum) { redirect: []const u8, body: []const u8 };

    fn url(self: *const HopFake, i: usize) []const u8 {
        return self.url_buf[i][0..self.url_len[i]];
    }

    fn transport(
        ctx: ?*anyopaque,
        gpa: std.mem.Allocator,
        io: std.Io,
        req: TransportRequest,
    ) HttpGetError!HttpBody {
        _ = io;
        const self: *HopFake = @ptrCast(@alignCast(ctx.?));
        const i = self.calls;
        self.calls += 1;
        if (i < max_rec) {
            const n = @min(req.url.len, self.url_buf[i].len);
            @memcpy(self.url_buf[i][0..n], req.url[0..n]);
            self.url_len[i] = n;
            self.dial_len[i] = req.dial.len;
            self.dial_first[i] = if (req.dial.len > 0) req.dial[0] else null;
            self.follow[i] = req.follow_redirects;
        }
        switch (self.steps[@min(i, self.steps.len - 1)]) {
            .redirect => |loc| {
                const location = try gpa.dupe(u8, loc);
                errdefer gpa.free(location);
                const bytes = try gpa.alloc(u8, 0);
                errdefer gpa.free(bytes);
                const ct = try gpa.alloc(u8, 0);
                return .{ .bytes = bytes, .content_type = ct, .redirect = location };
            },
            .body => |b| {
                const bytes = try gpa.dupe(u8, b);
                errdefer gpa.free(bytes);
                const ct = try gpa.dupe(u8, "text/html; charset=utf-8");
                return .{ .bytes = bytes, .content_type = ct };
            },
        }
    }
};

/// Scripted resolver: host name to answer or failure; unknown names fail.
const FakeDns = struct {
    entries: []const Entry,
    calls: usize = 0,

    const Entry = struct {
        host: []const u8,
        addrs: []const IpAddress = &.{},
        fail: bool = false,
    };

    fn resolve(
        ctx: ?*anyopaque,
        io: std.Io,
        host: []const u8,
        port: u16,
        out: []IpAddress,
    ) ResolveError!usize {
        _ = io;
        const self: *FakeDns = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        for (self.entries) |e| {
            if (!std.ascii.eqlIgnoreCase(e.host, host)) continue;
            if (e.fail or e.addrs.len > out.len) return error.ResolveFailed;
            for (e.addrs, 0..) |a, i| out[i] = withPort(a, port);
            return e.addrs.len;
        }
        return error.ResolveFailed;
    }
};

const public_example = [_]IpAddress{.{ .ip4 = .{ .bytes = .{ 93, 184, 216, 34 }, .port = 0 } }};
const public_other = [_]IpAddress{.{ .ip4 = .{ .bytes = .{ 203, 0, 114, 7 }, .port = 0 } }};
const private_10 = [_]IpAddress{.{ .ip4 = .{ .bytes = .{ 10, 0, 0, 1 }, .port = 0 } }};

fn expectReplyHas(res: anytype, needle: []const u8) !void {
    try testing.expect(res == .ok);
    if (std.mem.indexOf(u8, res.ok, needle) == null) {
        std.debug.print("reply {s} lacks {s}\n", .{ res.ok, needle });
        return error.TestExpectedEqual;
    }
}

test "web_fetch: public → 302 → 169.254.169.254 refuses PrivateHost at the hop" {
    var h = try Harness.init(testing.allocator, .{});
    defer h.deinit();
    var fake = HopFake{ .steps = &.{
        .{ .redirect = "http://169.254.169.254/latest/meta-data" },
        .{ .body = "<p>metadata</p>" },
    } };
    h.worker.transport = HopFake.transport;
    h.worker.transport_ctx = &fake;

    const res = try h.caller.call("zygos::tools::web_fetch", "{\"url\":\"https://example.com/\"}");
    defer res.deinit(testing.allocator);
    try expectReplyHas(res, "PrivateHost");
    try testing.expectEqual(@as(usize, 1), fake.calls);
}

test "web_fetch: public → 302 → name resolving private refuses PrivateHost at the hop" {
    var h = try Harness.init(testing.allocator, .{});
    defer h.deinit();
    var fake = HopFake{ .steps = &.{
        .{ .redirect = "http://rebind.example/" },
        .{ .body = "<p>internal</p>" },
    } };
    var dns = FakeDns{ .entries = &.{
        .{ .host = "example.com", .addrs = &public_example },
        .{ .host = "rebind.example", .addrs = &private_10 },
    } };
    h.worker.transport = HopFake.transport;
    h.worker.transport_ctx = &fake;
    h.worker.resolver = FakeDns.resolve;
    h.worker.resolver_ctx = &dns;

    const res = try h.caller.call("zygos::tools::web_fetch", "{\"url\":\"https://example.com/\"}");
    defer res.deinit(testing.allocator);
    try expectReplyHas(res, "PrivateHost");
    try testing.expectEqual(@as(usize, 1), fake.calls);
    try testing.expectEqual(@as(usize, 2), dns.calls);
}

test "web_fetch: public → 302 → public is followed and every hop is dialed at its screened address" {
    var h = try Harness.init(testing.allocator, .{});
    defer h.deinit();
    var dns = FakeDns{ .entries = &.{
        .{ .host = "example.com", .addrs = &public_example },
        .{ .host = "other.example", .addrs = &public_other },
    } };
    h.worker.transport = HopFake.transport;
    h.worker.resolver = FakeDns.resolve;
    h.worker.resolver_ctx = &dns;

    // Relative Location resolves against the hop that issued it.
    var rel = HopFake{ .steps = &.{
        .{ .redirect = "/next" },
        .{ .body = "<html><body><p>relative landing</p></body></html>" },
    } };
    h.worker.transport_ctx = &rel;
    const res = try h.caller.call("zygos::tools::web_fetch", "{\"url\":\"https://example.com/start\"}");
    defer res.deinit(testing.allocator);
    try expectReplyHas(res, "relative landing");
    try expectReplyHas(res, "\"url\":\"https://example.com/start\"");
    try testing.expectEqual(@as(usize, 2), rel.calls);
    try testing.expectEqualStrings("https://example.com/start", rel.url(0));
    try testing.expectEqualStrings("https://example.com/next", rel.url(1));
    for (0..2) |i| {
        try testing.expect(!rel.follow[i]);
        try testing.expectEqual(@as(usize, 1), rel.dial_len[i]);
        try testing.expectEqualSlices(u8, &.{ 93, 184, 216, 34 }, &rel.dial_first[i].?.ip4.bytes);
        try testing.expectEqual(@as(u16, 443), rel.dial_first[i].?.ip4.port);
    }

    // Absolute Location to another host: that host's own answer is dialed.
    var abs = HopFake{ .steps = &.{
        .{ .redirect = "http://other.example:8080/abs?q=1#frag" },
        .{ .body = "<html><body><p>absolute landing</p></body></html>" },
    } };
    h.worker.transport_ctx = &abs;
    const res2 = try h.caller.call("zygos::tools::web_fetch", "{\"url\":\"https://example.com/\"}");
    defer res2.deinit(testing.allocator);
    try expectReplyHas(res2, "absolute landing");
    try testing.expectEqualStrings("http://other.example:8080/abs?q=1", abs.url(1));
    try testing.expectEqualSlices(u8, &.{ 203, 0, 114, 7 }, &abs.dial_first[1].?.ip4.bytes);
    try testing.expectEqual(@as(u16, 8080), abs.dial_first[1].?.ip4.port);
}

test "web_fetch: exactly max_redirects hops succeed; one more refuses TooManyRedirects" {
    var h = try Harness.init(testing.allocator, .{});
    defer h.deinit();

    var forever = HopFake{ .steps = &.{.{ .redirect = "/loop" }} };
    h.worker.transport = HopFake.transport;
    h.worker.transport_ctx = &forever;
    const res = try h.caller.call("zygos::tools::web_fetch", "{\"url\":\"https://example.com/\"}");
    defer res.deinit(testing.allocator);
    try expectReplyHas(res, "TooManyRedirects");
    try testing.expectEqual(@as(usize, 4), forever.calls); // original + 3 followed

    var chain = HopFake{ .steps = &.{
        .{ .redirect = "/a" },
        .{ .redirect = "/b" },
        .{ .redirect = "/c" },
        .{ .body = "<html><body><p>end of chain</p></body></html>" },
    } };
    h.worker.transport_ctx = &chain;
    const res2 = try h.caller.call("zygos::tools::web_fetch", "{\"url\":\"https://example.com/\"}");
    defer res2.deinit(testing.allocator);
    try expectReplyHas(res2, "end of chain");
    try testing.expectEqual(@as(usize, 4), chain.calls);

    // The cap is the worker's setting, not a constant.
    h.worker.max_redirects = 1;
    var two = HopFake{ .steps = &.{.{ .redirect = "/loop" }} };
    h.worker.transport_ctx = &two;
    const res3 = try h.caller.call("zygos::tools::web_fetch", "{\"url\":\"https://example.com/\"}");
    defer res3.deinit(testing.allocator);
    try expectReplyHas(res3, "TooManyRedirects");
    try testing.expectEqual(@as(usize, 2), two.calls);
}

test "web_fetch: missing, non-http(s), or unresolvable Location refuses InvalidRedirect" {
    var h = try Harness.init(testing.allocator, .{});
    defer h.deinit();
    h.worker.transport = HopFake.transport;

    const locations = [_][]const u8{
        "",
        "file:///etc/passwd",
        "ftp://x/",
        "javascript:alert(1)",
        "http://",
        "http:///nohost",
    };
    for (locations) |loc| {
        var fake = HopFake{ .steps = &.{ .{ .redirect = loc }, .{ .body = "<p>unreached</p>" } } };
        h.worker.transport_ctx = &fake;
        const res = try h.caller.call("zygos::tools::web_fetch", "{\"url\":\"https://example.com/\"}");
        defer res.deinit(testing.allocator);
        expectReplyHas(res, "InvalidRedirect") catch |err| {
            std.debug.print("Location {s}\n", .{loc});
            return err;
        };
        try testing.expectEqual(@as(usize, 1), fake.calls);
    }

    // An oversized Location never reaches the parser.
    const huge = "/" ++ "a" ** 9000;
    var fake = HopFake{ .steps = &.{ .{ .redirect = huge }, .{ .body = "<p>unreached</p>" } } };
    h.worker.transport_ctx = &fake;
    const res = try h.caller.call("zygos::tools::web_fetch", "{\"url\":\"https://example.com/\"}");
    defer res.deinit(testing.allocator);
    try expectReplyHas(res, "InvalidRedirect");
    try testing.expectEqual(@as(usize, 1), fake.calls);
}

test "web_fetch: name resolving to a blocked class refuses PrivateHost before the transport" {
    var h = try Harness.init(testing.allocator, .{});
    defer h.deinit();
    h.worker.transport = HopFake.transport;
    h.worker.resolver = FakeDns.resolve;

    const blocked = [_][]const u8{
        "10.0.0.1",
        "::1",
        "fe80::1",
        "64:ff9b::a9fe:a9fe", // NAT64 of 169.254.169.254
        "64:ff9b::",
        "2002:a9fe:a9fe::", // 6to4 of 169.254.169.254
        "::ffff:127.0.0.1",
    };
    for (blocked) |text| {
        const addrs = [_]IpAddress{testIp(text)};
        var dns = FakeDns{ .entries = &.{.{ .host = "blocked.example", .addrs = &addrs }} };
        var fake = HopFake{ .steps = &.{.{ .body = "<p>internal</p>" }} };
        h.worker.resolver_ctx = &dns;
        h.worker.transport_ctx = &fake;
        const res = try h.caller.call("zygos::tools::web_fetch", "{\"url\":\"https://blocked.example/\"}");
        defer res.deinit(testing.allocator);
        expectReplyHas(res, "PrivateHost") catch |err| {
            std.debug.print("answer {s}\n", .{text});
            return err;
        };
        try testing.expectEqual(@as(usize, 0), fake.calls);
        try testing.expectEqual(@as(usize, 1), dns.calls);
    }
}

test "web_fetch: a name with one public and one private address refuses PrivateHost" {
    var h = try Harness.init(testing.allocator, .{});
    defer h.deinit();
    const mixed = [_]IpAddress{ testIp("93.184.216.34"), testIp("10.0.0.1") };
    var dns = FakeDns{ .entries = &.{.{ .host = "mixed.example", .addrs = &mixed }} };
    var fake = HopFake{ .steps = &.{.{ .body = "<p>internal</p>" }} };
    h.worker.transport = HopFake.transport;
    h.worker.transport_ctx = &fake;
    h.worker.resolver = FakeDns.resolve;
    h.worker.resolver_ctx = &dns;

    const res = try h.caller.call("zygos::tools::web_fetch", "{\"url\":\"https://mixed.example/\"}");
    defer res.deinit(testing.allocator);
    try expectReplyHas(res, "PrivateHost");
    try testing.expectEqual(@as(usize, 0), fake.calls);
}

test "web_fetch: resolver error or empty answer refuses ResolveFailed and never fetches" {
    var h = try Harness.init(testing.allocator, .{});
    defer h.deinit();
    var dns = FakeDns{ .entries = &.{
        .{ .host = "broken.example", .fail = true },
        .{ .host = "empty.example", .addrs = &.{} },
    } };
    var fake = HopFake{ .steps = &.{.{ .body = "<p>unreached</p>" }} };
    h.worker.transport = HopFake.transport;
    h.worker.transport_ctx = &fake;
    h.worker.resolver = FakeDns.resolve;
    h.worker.resolver_ctx = &dns;

    for ([_][]const u8{
        "{\"url\":\"https://broken.example/\"}",
        "{\"url\":\"https://empty.example/\"}",
        "{\"url\":\"https://unknown.example/\"}",
    }) |request| {
        const res = try h.caller.call("zygos::tools::web_fetch", request);
        defer res.deinit(testing.allocator);
        try expectReplyHas(res, "ResolveFailed");
    }
    try testing.expectEqual(@as(usize, 0), fake.calls);
    try testing.expectEqual(@as(usize, 3), dns.calls);
}

test "web_fetch: ZYGOS_FETCH_ALLOW_PRIVATE bypasses hop and DNS screens" {
    var h = try Harness.init(testing.allocator, .{ .allow_private_hosts = true });
    defer h.deinit();
    var dns = FakeDns{ .entries = &.{.{ .host = "private.example", .addrs = &private_10 }} };
    h.worker.transport = HopFake.transport;
    h.worker.resolver = FakeDns.resolve;
    h.worker.resolver_ctx = &dns;

    // A private-resolving name fetches; std resolves it (empty dial).
    var direct = HopFake{ .steps = &.{.{ .body = "<html><body><p>mirror</p></body></html>" }} };
    h.worker.transport_ctx = &direct;
    const res = try h.caller.call("zygos::tools::web_fetch", "{\"url\":\"http://private.example/\"}");
    defer res.deinit(testing.allocator);
    try expectReplyHas(res, "mirror");
    try testing.expectEqual(@as(usize, 0), dns.calls);
    try testing.expectEqual(@as(usize, 0), direct.dial_len[0]);
    try testing.expect(!direct.follow[0]);

    // A redirect to the metadata address is hand-followed.
    var hop = HopFake{ .steps = &.{
        .{ .redirect = "http://169.254.169.254/latest" },
        .{ .body = "<html><body><p>metadata</p></body></html>" },
    } };
    h.worker.transport_ctx = &hop;
    const res2 = try h.caller.call("zygos::tools::web_fetch", "{\"url\":\"https://example.com/\"}");
    defer res2.deinit(testing.allocator);
    try expectReplyHas(res2, "metadata");
    try testing.expectEqual(@as(usize, 2), hop.calls);
    try testing.expectEqualStrings("http://169.254.169.254/latest", hop.url(1));
    try testing.expectEqual(@as(usize, 0), hop.dial_len[1]);
    try testing.expectEqual(@as(usize, 0), dns.calls);

    // The hop cap still applies.
    var forever = HopFake{ .steps = &.{.{ .redirect = "http://10.0.0.1/loop" }} };
    h.worker.transport_ctx = &forever;
    const res3 = try h.caller.call("zygos::tools::web_fetch", "{\"url\":\"https://example.com/\"}");
    defer res3.deinit(testing.allocator);
    try expectReplyHas(res3, "TooManyRedirects");
    try testing.expectEqual(@as(usize, 4), forever.calls);
}

test "web_fetch: public literal hosts dial themselves and skip the resolver" {
    var h = try Harness.init(testing.allocator, .{});
    defer h.deinit();
    var dns = FakeDns{ .entries = &.{} };
    h.worker.transport = HopFake.transport;
    h.worker.resolver = FakeDns.resolve;
    h.worker.resolver_ctx = &dns;

    var v4 = HopFake{ .steps = &.{.{ .body = "<p>v4</p>" }} };
    h.worker.transport_ctx = &v4;
    const res = try h.caller.call("zygos::tools::web_fetch", "{\"url\":\"http://8.8.8.8/x\"}");
    defer res.deinit(testing.allocator);
    try expectReplyHas(res, "v4");
    try testing.expectEqualSlices(u8, &.{ 8, 8, 8, 8 }, &v4.dial_first[0].?.ip4.bytes);
    try testing.expectEqual(@as(u16, 80), v4.dial_first[0].?.ip4.port);

    var v6 = HopFake{ .steps = &.{.{ .body = "<p>v6</p>" }} };
    h.worker.transport_ctx = &v6;
    const res2 = try h.caller.call("zygos::tools::web_fetch", "{\"url\":\"https://[2606:4700::6810:85e5]/x\"}");
    defer res2.deinit(testing.allocator);
    try expectReplyHas(res2, "v6");
    const want = testIp("2606:4700::6810:85e5");
    try testing.expectEqualSlices(u8, &want.ip6.bytes, &v6.dial_first[0].?.ip6.bytes);
    try testing.expectEqual(@as(u16, 443), v6.dial_first[0].?.ip6.port);
    try testing.expectEqual(@as(usize, 0), dns.calls);
}

test "web_fetch: percent-encoded private host refuses PrivateHost before the transport" {
    var h = try Harness.init(testing.allocator, .{});
    defer h.deinit();
    var fake = HopFake{ .steps = &.{.{ .body = "<p>internal</p>" }} };
    h.worker.transport = HopFake.transport;
    h.worker.transport_ctx = &fake;

    for ([_][]const u8{
        "{\"url\":\"http://%31%32%37.0.0.1/\"}",
        "{\"url\":\"http://%6Cocalhost/\"}",
    }) |request| {
        const res = try h.caller.call("zygos::tools::web_fetch", request);
        defer res.deinit(testing.allocator);
        try expectReplyHas(res, "PrivateHost");
    }
    try testing.expectEqual(@as(usize, 0), fake.calls);
}

test "addressBlocked: v4, v6, v4-mapped, NAT64 and 6to4 embedded private classes; public pass" {
    const blocked = [_][]const u8{
        "0.0.0.0",                "10.0.0.1",           "127.0.0.1",       "169.254.169.254",
        "172.16.0.1",             "192.168.1.1",        "100.64.0.1",      "224.0.0.1",
        "255.255.255.255",        "::",                 "::1",             "::102:304",
        "fe80::1",                "febf::1",            "fec0::1",         "fc00::1",
        "fd12:3456::1",           "ff02::1",            "::ffff:10.0.0.1", "::ffff:127.0.0.1",
        "::ffff:169.254.169.254", "64:ff9b::a9fe:a9fe", "64:ff9b::a00:1",  "64:ff9b::",
        "2002:a9fe:a9fe::",       "2002:7f00:1::",      "2002:a00:1::1",
    };
    for (blocked) |text| {
        testing.expect(addressBlocked(testIp(text))) catch |err| {
            std.debug.print("expected blocked: {s}\n", .{text});
            return err;
        };
    }
    const public = [_][]const u8{
        "8.8.8.8",          "93.184.216.34",  "172.32.0.1",     "2606:4700::6810:85e5",
        "64:ff9b::808:808", "2002:808:808::", "::ffff:8.8.8.8", "2001:4860:4860::8888",
    };
    for (public) |text| {
        testing.expect(!addressBlocked(testIp(text))) catch |err| {
            std.debug.print("expected public: {s}\n", .{text});
            return err;
        };
    }
}

test "SSRF screen literals: NAT64, 6to4 and expanded loopback forms are blocked" {
    try testing.expect(fetchHostBlocked("http://[64:ff9b::a9fe:a9fe]/x"));
    try testing.expect(fetchHostBlocked("http://[2002:a9fe:a9fe::1]/x"));
    try testing.expect(fetchHostBlocked("http://[0:0:0:0:0:0:0:1]/x"));
    try testing.expect(fetchHostBlocked("http://[0:0:0:0:0:ffff:7f00:1]/x"));
    try testing.expect(fetchHostBlocked("http://[::FFFF:10.0.0.1]/x"));
    try testing.expect(fetchHostBlocked("http://[not:an:address]/x")); // unparseable: fail closed
    try testing.expect(!fetchHostBlocked("http://[64:ff9b::808:808]/x"));
    try testing.expect(!fetchHostBlocked("http://[2002:808:808::1]/x"));
}

test "validateUrl: a host longer than HostName.max_len is refused; a 255-byte host passes" {
    const max = std.Io.net.HostName.max_len;
    // Raw and percent-encoded forms: the encoded text is what Uri keeps, and
    // std.Uri.getHost asserts it fits a max_len buffer once decoded.
    try testing.expectError(error.InvalidUrl, validateUrl("http://%61" ++ "a" ** 300 ++ "/"));
    try testing.expectError(error.InvalidUrl, validateUrl("http://" ++ "a" ** (max + 1) ++ "/"));
    try testing.expectError(error.InvalidUrl, validateUrl("https://[" ++ "1" ** (max + 1) ++ "]/"));
    try validateUrl("http://" ++ "a" ** max ++ "/");
    try validateUrl("http://" ++ "%61" ** (max / 3) ++ "/");
}

test "web_fetch: over-long host refuses InvalidUrl without crashing, screen on and off" {
    var h = try Harness.init(testing.allocator, .{});
    defer h.deinit();
    var fake = HopFake{ .steps = &.{.{ .body = "<p>unreached</p>" }} };
    h.worker.transport = HopFake.transport;
    h.worker.transport_ctx = &fake;

    const request = "{\"url\":\"http://%61" ++ "a" ** 300 ++ "/\"}";
    const res = try h.caller.call("zygos::tools::web_fetch", request);
    defer res.deinit(testing.allocator);
    try expectReplyHas(res, "InvalidUrl");

    h.worker.allow_private_hosts = true;
    const res2 = try h.caller.call("zygos::tools::web_fetch", request);
    defer res2.deinit(testing.allocator);
    try expectReplyHas(res2, "InvalidUrl");
    try testing.expectEqual(@as(usize, 0), fake.calls);
}

// Pins `resolveRedirect` refusing a `Location` whose host is over-long. std's
// `resolveInPlace` already rejects such a host, so the redirect path never
// reached the crash that `validateUrl` guards on the request URL.
test "web_fetch: a redirect to an over-long host refuses InvalidRedirect, screen on and off" {
    var h = try Harness.init(testing.allocator, .{});
    defer h.deinit();
    h.worker.transport = HopFake.transport;

    const loc = "http://%61" ++ "a" ** 300 ++ "/";
    for ([_]bool{ false, true }) |allow| {
        h.worker.allow_private_hosts = allow;
        var fake = HopFake{ .steps = &.{ .{ .redirect = loc }, .{ .body = "<p>unreached</p>" } } };
        h.worker.transport_ctx = &fake;
        const res = try h.caller.call("zygos::tools::web_fetch", "{\"url\":\"https://example.com/\"}");
        defer res.deinit(testing.allocator);
        try expectReplyHas(res, "InvalidRedirect");
        try testing.expectEqual(@as(usize, 1), fake.calls);
    }
}

test "addressBlocked: 0000::/8, local-use NAT64, discard and benchmark ranges blocked" {
    // A literal whose first byte is zero, but not in ::/96.
    try testing.expect(fetchHostBlocked("http://[::1:0:0:1]/x"));
    const blocked = [_][]const u8{
        "::1:0:0:1", "0:0:0:0:ffff:0:7f00:1", // SIIT ::ffff:0:0:0/96
        "64:ff9b:1::a9fe:a9fe", "64:ff9b:1:ffff::1", // local-use NAT64 64:ff9b:1::/48
        "100::1", "100::ffff:ffff:ffff:ffff", // discard 100::/64
        "198.18.0.1", "198.19.255.255", // benchmarking 198.18.0.0/15
        "192.0.0.170", "192.0.0.0", // IETF protocol assignments 192.0.0.0/24
    };
    for (blocked) |text| {
        testing.expect(addressBlocked(testIp(text))) catch |err| {
            std.debug.print("expected blocked: {s}\n", .{text});
            return err;
        };
    }
    const public = [_][]const u8{
        "198.20.0.1", "198.17.255.255", "192.0.1.1", "64:ff9b::808:808", "100:0:0:1::1",
    };
    for (public) |text| {
        testing.expect(!addressBlocked(testIp(text))) catch |err| {
            std.debug.print("expected public: {s}\n", .{text});
            return err;
        };
    }
}

test "defaultResolver: an Io without concurrency refuses ResolveFailed instead of looking up inline" {
    var out: [dial_max]IpAddress = undefined;
    try testing.expectError(error.ResolveFailed, defaultResolver(null, std.Io.failing, "example.com", 80, &out));
}

test "defaultResolver: an address literal resolves through the concurrent lookup" {
    var backing = std.Io.Threaded.init(testing.allocator, .{});
    defer backing.deinit();
    var out: [dial_max]IpAddress = undefined;
    const n = try defaultResolver(null, backing.io(), "127.0.0.1", 8080, &out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, &out[0].ip4.bytes);
    try testing.expectEqual(@as(u16, 8080), out[0].ip4.port);
}

// ---------------------------------------------------------------------------
// Real transport over loopback (issue #23): `httpGet` against a one-shot
// listener on 127.0.0.1 that sends canned bytes. This is the only code path
// that reads `Content-Encoding`; the transport seam above bypasses it.
// ---------------------------------------------------------------------------

const gz_hello_html = "<html><body><p>Hello gzip world</p></body></html>";
const gz_hello = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\xb3\xc9\x28\xc9\xcd\xb1\xb3\x49\xca\x4f\xa9\xb4\xb3\x29\xb0\xf3\x48\xcd\xc9\xc9\x57\x48\xaf\xca\x2c\x50\x28\xcf\x2f\xca\x49\xb1\xd1\x2f\xb0\xb3\xd1\x87\xc8\xea\x83\x95\x02\x00\x2e\xeb\x8a\x82\x31\x00\x00\x00";
/// zlib (`deflate`) wrapping of `gz_hello_html`.
const zlib_hello = "\x78\xda\xb3\xc9\x28\xc9\xcd\xb1\xb3\x49\xca\x4f\xa9\xb4\xb3\x29\xb0\xf3\x48\xcd\xc9\xc9\x57\x48\xaf\xca\x2c\x50\x28\xcf\x2f\xca\x49\xb1\xd1\x2f\xb0\xb3\xd1\x87\xc8\xea\x83\x95\x02\x00\xb1\xdf\x11\x26";
/// 333 bytes that decode to `gz_zeros_len` zero bytes.
const gz_zeros_len = 300 * 1024;
const gz_zeros = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\xed\xc1\x01\x0d\x00\x00\x00\xc2\xa0\xf7\x4f\x6d\x0e\x37\xa0" ++
    ("\x00" ** 297) ++ "\xe0\xcf\x00\x96\xc0\xec\x82\x00\xb0\x04\x00";

const LoopbackServer = struct {
    io: std.Io,
    server: std.Io.net.Server,
    response: []const u8,
    thread: std.Thread = undefined,
    request: [2048]u8 = undefined,
    request_len: usize = 0,

    fn start(gpa: std.mem.Allocator, io: std.Io, response: []const u8) !*LoopbackServer {
        const self = try gpa.create(LoopbackServer);
        errdefer gpa.destroy(self);
        var addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        self.* = .{ .io = io, .server = try addr.listen(io, .{}), .response = response };
        errdefer self.server.deinit(io);
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
        return self;
    }

    fn finish(self: *LoopbackServer, gpa: std.mem.Allocator) void {
        self.thread.join();
        self.server.deinit(self.io);
        gpa.destroy(self);
    }

    fn url(self: *const LoopbackServer, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}/", .{self.server.socket.address.getPort()}) catch unreachable;
    }

    fn requestText(self: *const LoopbackServer) []const u8 {
        return self.request[0..self.request_len];
    }

    fn serve(self: *LoopbackServer) void {
        const stream = self.server.accept(self.io) catch return;
        defer stream.close(self.io);
        var rbuf: [1024]u8 = undefined;
        var sr = stream.reader(self.io, &rbuf);
        while (true) {
            const line = sr.interface.takeDelimiterInclusive('\n') catch break;
            const room = self.request.len - self.request_len;
            const n = @min(line.len, room);
            @memcpy(self.request[self.request_len..][0..n], line[0..n]);
            self.request_len += n;
            if (line.len <= 2) break; // blank line: end of the request head
        }
        var wbuf: [1024]u8 = undefined;
        var sw = stream.writer(self.io, &wbuf);
        sw.interface.writeAll(self.response) catch return;
        sw.interface.flush() catch return;
    }
};

fn flipped(comptime bytes: []const u8, comptime at: []const usize) []const u8 {
    var out: [bytes.len]u8 = undefined;
    @memcpy(&out, bytes);
    for (at) |i| out[i] ^= 0xff;
    const final = out;
    return &final;
}

/// `Connection: close` response with a `Content-Length` body.
fn cannedResponse(comptime encoding: ?[]const u8, comptime body: []const u8) []const u8 {
    return "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n" ++
        (if (encoding) |e| "Content-Encoding: " ++ e ++ "\r\n" else "") ++
        std.fmt.comptimePrint("Content-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len}) ++ body;
}

fn loopbackGet(
    gpa: std.mem.Allocator,
    response: []const u8,
    headers: []const std.http.Header,
    max_bytes: usize,
    request_out: ?*[2048]u8,
) HttpGetError!HttpBody {
    var backing = std.Io.Threaded.init(gpa, .{});
    defer backing.deinit();
    const io = backing.io();
    const srv = LoopbackServer.start(gpa, io, response) catch return error.HttpFailed;
    defer srv.finish(gpa);
    var url_buf: [64]u8 = undefined;
    const result = httpGet(gpa, io, .{ .url = srv.url(&url_buf), .headers = headers, .max_bytes = max_bytes });
    if (request_out) |out| out.* = srv.request;
    return result;
}

fn expectBody(result: HttpGetError!HttpBody, expected: []const u8) !void {
    const body = try result;
    defer {
        testing.allocator.free(body.bytes);
        testing.allocator.free(body.content_type);
    }
    try testing.expectEqualStrings(expected, body.bytes);
}

test "httpGet decodes a gzip body to the caller's text (#23)" {
    try expectBody(loopbackGet(testing.allocator, cannedResponse("gzip", gz_hello), &.{}, 1 << 20, null), gz_hello_html);
}

test "httpGet decodes an x-gzip body" {
    try expectBody(loopbackGet(testing.allocator, cannedResponse("x-gzip", gz_hello), &.{}, 1 << 20, null), gz_hello_html);
}

test "httpGet decodes a deflate body" {
    try expectBody(loopbackGet(testing.allocator, cannedResponse("deflate", zlib_hello), &.{}, 1 << 20, null), gz_hello_html);
}

test "httpGet decodes a chunked gzip body" {
    const chunked = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Encoding: gzip\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" ++
        "10\r\n" ++ gz_hello[0..16] ++ "\r\n" ++
        std.fmt.comptimePrint("{x}\r\n", .{gz_hello.len - 16}) ++ gz_hello[16..] ++ "\r\n0\r\n\r\n";
    try expectBody(loopbackGet(testing.allocator, chunked, &.{}, 1 << 20, null), gz_hello_html);
}

test "httpGet decodes a gzip body that ends with the connection" {
    const until_close = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Encoding: gzip\r\nConnection: close\r\n\r\n" ++ gz_hello;
    try expectBody(loopbackGet(testing.allocator, until_close, &.{}, 1 << 20, null), gz_hello_html);
}

test "httpGet leaves an identity body unchanged" {
    try expectBody(loopbackGet(testing.allocator, cannedResponse(null, gz_hello_html), &.{}, 1 << 20, null), gz_hello_html);
    try expectBody(loopbackGet(testing.allocator, cannedResponse("identity", gz_hello_html), &.{}, 1 << 20, null), gz_hello_html);
}

test "httpGet caps the decoded gzip output at max_bytes" {
    const body = try loopbackGet(testing.allocator, cannedResponse("gzip", gz_zeros), &.{}, 1000, null);
    defer {
        testing.allocator.free(body.bytes);
        testing.allocator.free(body.content_type);
    }
    try testing.expectEqual(@as(usize, 1000), body.bytes.len);
    for (body.bytes) |b| try testing.expectEqual(@as(u8, 0), b);
}

test "httpGet returns the whole decoded body when it fits under max_bytes" {
    const body = try loopbackGet(testing.allocator, cannedResponse("gzip", gz_zeros), &.{}, gz_zeros_len + 1, null);
    defer {
        testing.allocator.free(body.bytes);
        testing.allocator.free(body.content_type);
    }
    try testing.expectEqual(@as(usize, gz_zeros_len), body.bytes.len);
}

test "httpGet errors on a corrupt gzip body instead of returning raw bytes" {
    // Bit-flips inside the deflate stream: invalid block / bad CRC.
    const corrupt = comptime flipped(gz_hello, &.{ 14, 20 });
    try testing.expectError(error.HttpFailed, loopbackGet(testing.allocator, cannedResponse("gzip", corrupt), &.{}, 1 << 20, null));
}

test "httpGet errors on a gzip body whose checksum does not match" {
    const bad_crc = comptime flipped(gz_hello, &.{gz_hello.len - 8}); // CRC32 field of the trailer
    try testing.expectError(error.HttpFailed, loopbackGet(testing.allocator, cannedResponse("gzip", bad_crc), &.{}, 1 << 20, null));
}

test "httpGet errors on a body labelled gzip that is not gzip" {
    try testing.expectError(error.HttpFailed, loopbackGet(testing.allocator, cannedResponse("gzip", gz_hello_html), &.{}, 1 << 20, null));
}

test "httpGet errors on a truncated gzip stream" {
    // Whole HTTP framing, but the gzip data stops before the end of the deflate stream.
    try testing.expectError(error.HttpFailed, loopbackGet(testing.allocator, cannedResponse("gzip", gz_hello[0 .. gz_hello.len / 2]), &.{}, 1 << 20, null));
}

test "httpGet errors on a gzip stream missing its trailer" {
    try testing.expectError(error.HttpFailed, loopbackGet(testing.allocator, cannedResponse("gzip", gz_hello[0 .. gz_hello.len - 8]), &.{}, 1 << 20, null));
}

test "httpGet errors on an encoding it cannot decode" {
    try testing.expectError(error.HttpFailed, loopbackGet(testing.allocator, cannedResponse("br", gz_hello), &.{}, 1 << 20, null));
    try testing.expectError(error.HttpFailed, loopbackGet(testing.allocator, cannedResponse("zstd", gz_hello), &.{}, 1 << 20, null));
    try testing.expectError(error.HttpFailed, loopbackGet(testing.allocator, cannedResponse("compress", gz_hello), &.{}, 1 << 20, null));
    try testing.expectError(error.HttpFailed, loopbackGet(testing.allocator, cannedResponse("gzip, br", gz_hello), &.{}, 1 << 20, null));
}

test "httpGet advertises only the encodings it decodes" {
    var req: [2048]u8 = undefined;
    try expectBody(loopbackGet(testing.allocator, cannedResponse("gzip", gz_hello), &.{}, 1 << 20, &req), gz_hello_html);
    const head = std.mem.sliceTo(&req, 0);
    var it = std.mem.splitSequence(u8, head, "\r\n");
    var seen = false;
    while (it.next()) |line| {
        if (!std.ascii.startsWithIgnoreCase(line, "accept-encoding:")) continue;
        seen = true;
        try testing.expect(std.ascii.indexOfIgnoreCase(line, "gzip") != null);
        try testing.expect(std.ascii.indexOfIgnoreCase(line, "deflate") != null);
        try testing.expect(std.ascii.indexOfIgnoreCase(line, "zstd") == null);
        try testing.expect(std.ascii.indexOfIgnoreCase(line, "br") == null);
    }
    try testing.expect(seen);
}

test "httpGet with a caller Accept-Encoding never returns a compressed body as text" {
    const hdrs = [_]std.http.Header{.{ .name = "Accept-Encoding", .value = "zstd, br, gzip" }};
    // A server that honours the caller's header and sends zstd or br: refuse.
    try testing.expectError(error.HttpFailed, loopbackGet(testing.allocator, cannedResponse("zstd", gz_hello), &hdrs, 1 << 20, null));
    try testing.expectError(error.HttpFailed, loopbackGet(testing.allocator, cannedResponse("br", gz_hello), &hdrs, 1 << 20, null));
    // gzip is still decoded.
    try expectBody(loopbackGet(testing.allocator, cannedResponse("gzip", gz_hello), &hdrs, 1 << 20, null), gz_hello_html);
}

test "httpGet errors on a gzip body whose length field does not match" {
    const bad_len = comptime flipped(gz_hello, &.{gz_hello.len - 4}); // ISIZE field of the trailer
    try testing.expectError(error.HttpFailed, loopbackGet(testing.allocator, cannedResponse("gzip", bad_len), &.{}, 1 << 20, null));
}

test "httpGet errors on a deflate body whose Adler-32 does not match" {
    const bad_adler = comptime flipped(zlib_hello, &.{zlib_hello.len - 1});
    try testing.expectError(error.HttpFailed, loopbackGet(testing.allocator, cannedResponse("deflate", bad_adler), &.{}, 1 << 20, null));
}

test "readCapped stops reading and allocating at the cap of a highly compressible body" {
    var src: std.Io.Reader = .fixed(gz_zeros);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var inflate: std.compress.flate.Decompress = .init(&src, .gzip, &window);
    // 300 KiB of output, but the allocator only has room for the cap.
    var fba_buf: [8 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
    const read = try readCapped(fba.allocator(), &inflate.reader, 1000);
    try testing.expectEqual(@as(usize, 1000), read.bytes.len);
    try testing.expect(!read.complete);
    for (read.bytes) |b| try testing.expectEqual(@as(u8, 0), b);
}

test "readCapped marks a body read to its end complete" {
    var src: std.Io.Reader = .fixed(gz_hello);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var inflate: std.compress.flate.Decompress = .init(&src, .gzip, &window);
    const read = try readCapped(testing.allocator, &inflate.reader, 1 << 20);
    defer testing.allocator.free(read.bytes);
    try testing.expect(read.complete);
    try testing.expectEqualStrings(gz_hello_html, read.bytes);
}

test "readCapped fails on a truncated gzip stream" {
    var src: std.Io.Reader = .fixed(gz_hello[0 .. gz_hello.len - 8]);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var inflate: std.compress.flate.Decompress = .init(&src, .gzip, &window);
    try testing.expectError(error.HttpFailed, readCapped(testing.allocator, &inflate.reader, 1 << 20));
}
