//! OpenAI-compatible chat-completions HTTP/SSE client (U4, M2 notes in
//! GOAL.md). Lives in src/net/ under the Z-02 amendment (std.Io.Threaded
//! permitted here only). `zig build test` exercises ONLY the network-free
//! pump (`processSse`) over fixture bytes; the HTTP path is an env-gated
//! manual smoke (test/e2e/openai/run.sh, OPENAI_API_KEY) and never runs
//! in CI. "OpenAI-compatible" is deliberate: base_url points anywhere that
//! speaks the dialect.

const std = @import("std");
const json = std.json;
const sse = @import("../worker/sse.zig");
const assembler_mod = @import("../worker/openai.zig");
const channel_mod = @import("../kernel/channel.zig");
const stream_guard = @import("stream_guard.zig");

const log = std.log.scoped(.openai);

pub const StreamOptions = struct {
    api_key: []const u8,
    model: []const u8,
    system: []const u8 = "",
    /// Raw JSON array text of NEUTRAL-shaped messages (docs/specs/turn.md);
    /// translated to the chat dialect here.
    messages_json: []const u8,
    /// Raw JSON array text of NEUTRAL-shaped tool definitions ("[]" = none).
    tools_json: []const u8 = "[]",
    max_tokens: u32 = 1024,
    /// Base URL including the version segment (e.g. `…/v1` or Gemini's
    /// `…/v1beta/openai`). `chatUrl` appends only `/chat/completions`.
    base_url: []const u8 = "https://api.openai.com/v1",
    /// Emitted in the request body only when set.
    temperature: ?f64 = null,
    /// Abort the request when the socket is silent this long (0 disables).
    /// Covers receiveHead too: a provider that accepts the connection and
    /// never answers must not park the worker thread forever.
    idle_timeout_ms: u64 = stream_guard.default_idle_ms,
};

pub const StreamError = error{ OutOfMemory, HttpInvalidUrl, HttpRequestFailed, HttpSendFailed, HttpReceiveFailed, ApiError, BadStream, BadRequest };

/// Join a version-carrying base URL with the chat completions path.
/// Caller owns the result.
pub fn chatUrl(gpa: std.mem.Allocator, base_url: []const u8) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(gpa, "{s}/chat/completions", .{base_url});
}

/// Pure request-body builder (network-free). `tools_part` is either empty or
/// a preformatted `,"tools":…` fragment. Temperature is emitted only when set.
pub fn buildChatBody(
    gpa: std.mem.Allocator,
    model: []const u8,
    max_tokens: u32,
    messages_inner: []const u8,
    tools_part: []const u8,
    temperature: ?f64,
) error{OutOfMemory}![]u8 {
    if (temperature) |temp| {
        return std.fmt.allocPrint(gpa,
            \\{{"model":{f},"max_completion_tokens":{d},"stream":true,"stream_options":{{"include_usage":true}},"messages":[{s}]{s},"temperature":{d}}}
        , .{
            json.fmt(model, .{}),
            max_tokens,
            messages_inner,
            tools_part,
            temp,
        });
    }
    return std.fmt.allocPrint(gpa,
        \\{{"model":{f},"max_completion_tokens":{d},"stream":true,"stream_options":{{"include_usage":true}},"messages":[{s}]{s}}}
    , .{
        json.fmt(model, .{}),
        max_tokens,
        messages_inner,
        tools_part,
    });
}

/// Blocking call: POST /v1/chat/completions with stream:true, push text
/// deltas into `sender` (closed on return), return the assembled terminal
/// message as JSON text in the provider-neutral wire shape (caller frees).
pub fn streamChat(
    gpa: std.mem.Allocator,
    io: std.Io,
    opts: StreamOptions,
    sender: ?*channel_mod.Sender,
) StreamError![]u8 {
    defer if (sender) |s| s.close();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const chat_messages = assembler_mod.translateMessages(arena, opts.messages_json) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.MalformedMessage => return error.BadRequest,
    };
    const chat_tools = assembler_mod.translateTools(arena, opts.tools_json) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.MalformedMessage => return error.BadRequest,
    };

    // The system prompt rides as the leading system-role message.
    const items = chat_messages[1 .. chat_messages.len - 1];
    const system_msg: []const u8 = if (opts.system.len > 0)
        std.fmt.allocPrint(arena, "{{\"role\":\"system\",\"content\":{f}}}", .{json.fmt(opts.system, .{})}) catch
            return error.OutOfMemory
    else
        "";
    const joined: []const u8 = if (system_msg.len > 0 and items.len > 0)
        std.fmt.allocPrint(arena, "{s},{s}", .{ system_msg, items }) catch return error.OutOfMemory
    else if (system_msg.len > 0)
        system_msg
    else
        items;
    const tools_part: []const u8 = if (!std.mem.eql(u8, chat_tools, "[]"))
        std.fmt.allocPrint(arena, ",\"tools\":{s}", .{chat_tools}) catch return error.OutOfMemory
    else
        "";

    const body = buildChatBody(gpa, opts.model, opts.max_tokens, joined, tools_part, opts.temperature) catch
        return error.OutOfMemory;
    defer gpa.free(body);

    const url = chatUrl(gpa, opts.base_url) catch return error.OutOfMemory;
    defer gpa.free(url);
    const uri = std.Uri.parse(url) catch |err| {
        log.warn("URL parse failed: {t}", .{err});
        return error.HttpInvalidUrl;
    };

    const auth = std.fmt.allocPrint(gpa, "Bearer {s}", .{opts.api_key}) catch
        return error.OutOfMemory;
    defer gpa.free(auth);

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var dns_retries: u8 = 0;
    var req = setup: while (true) {
        const request = client.request(.POST, uri, .{
            .extra_headers = &.{
                .{ .name = "authorization", .value = auth },
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "accept", .value = "text/event-stream" },
            },
        }) catch |err| {
            // DNS fails before any HTTP body can be sent. Never replay a POST.
            if (err == error.NameServerFailure and dns_retries < 2) {
                dns_retries += 1;
                log.warn("DNS lookup failed; retrying request setup ({d}/2)", .{dns_retries});
                io.sleep(.fromSeconds(1), .awake) catch {
                    log.warn("DNS backoff canceled", .{});
                    return error.HttpRequestFailed;
                };
                continue :setup;
            }
            log.warn("request setup failed: {t}", .{err});
            return error.HttpRequestFailed;
        };
        break :setup request;
    };
    defer req.deinit();

    // Declared after req so its deinit (stop + join) runs BEFORE req.deinit:
    // the guard must never shut down a socket that has been freed.
    var shutdown_ctx: ShutdownCtx = undefined;
    var guard: ?stream_guard.StreamGuard = null;
    defer if (guard) |*g| g.deinit();
    if (opts.idle_timeout_ms > 0) {
        if (req.connection) |conn| {
            shutdown_ctx = .{ .stream = conn.stream_reader.stream, .io = io };
            guard = stream_guard.StreamGuard.init(
                opts.idle_timeout_ms,
                @ptrCast(&shutdown_ctx),
                &ShutdownCtx.fire,
            );
            // A guard that fails to spawn degrades to the old unguarded
            // behavior rather than failing the request.
            guard.?.start() catch {
                guard.?.deinit();
                guard = null;
            };
        }
    }

    req.transfer_encoding = .{ .content_length = body.len };
    req.sendBodyComplete(body) catch |err| {
        log.warn("request send failed: {t}", .{err});
        return error.HttpSendFailed;
    };

    var redirect_buf: [1024]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch |err| {
        log.warn("response head failed: {t}", .{err});
        return error.HttpReceiveFailed;
    };
    if (guard) |*g| g.poke();
    if (response.head.status != .ok) {
        log.warn("{s} model {s}: endpoint answered {d}", .{
            opts.base_url, opts.model, @intFromEnum(response.head.status),
        });
        return error.ApiError;
    }

    var transfer_buf: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buf);
    return processSse(gpa, reader, sender, if (guard) |*g| g else null);
}

/// Fire target for the idle guard: erroring the blocked socket read is the
/// only way to unpark a silent-but-open provider connection.
const ShutdownCtx = struct {
    stream: std.Io.net.Stream,
    io: std.Io,

    fn fire(ctx: *anyopaque) void {
        const self: *ShutdownCtx = @ptrCast(@alignCast(ctx));
        log.warn("stream idle timeout: shutting down provider socket", .{});
        self.stream.shutdown(self.io, .both) catch {};
    }
};

/// The network-free pump: read SSE bytes, decode `data:` events (the chat
/// dialect has no event names), assemble, push text deltas into `sender`,
/// return the terminal message JSON in the neutral shape (caller frees).
pub fn processSse(
    gpa: std.mem.Allocator,
    reader: *std.Io.Reader,
    sender: ?*channel_mod.Sender,
    guard: ?*stream_guard.StreamGuard,
) StreamError![]u8 {
    var decoder = sse.Decoder.init(gpa);
    defer decoder.deinit();
    var assembler = assembler_mod.Assembler.init(gpa);
    defer assembler.deinit();

    var chunk: [4096]u8 = undefined;
    stream: while (true) {
        // readSliceShort fills the entire chunk, hiding short reads from the
        // watchdog and SSE decoder. Process each available read immediately.
        var buffers = [_][]u8{&chunk};
        const n = reader.readVec(&buffers) catch |err| switch (err) {
            error.EndOfStream => break :stream,
            error.ReadFailed => return error.BadStream,
        };
        if (n == 0) continue;
        if (guard) |g| g.poke();
        decoder.feed(chunk[0..n]) catch return error.OutOfMemory;

        while (decoder.next() catch return error.OutOfMemory) |event| {
            const delta = assembler.onEvent(event.data) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ApiError => return error.ApiError,
                error.MalformedEvent => {
                    log.warn("malformed stream chunk skipped", .{});
                    continue;
                },
                error.Incomplete => unreachable,
            };
            if (delta) |text| pushDelta(sender, text);
            if (assembler.isDone()) break :stream;
        }
    }

    const msg = assembler.message() catch return error.BadStream;
    return renderMessage(gpa, msg) catch return error.OutOfMemory;
}

fn pushDelta(sender: ?*channel_mod.Sender, text: []const u8) void {
    const s = sender orelse return;
    // Best-effort telemetry: a full/closed pipe must never stall the stream.
    var mutable: [4096]u8 = undefined;
    const n = @min(text.len, mutable.len);
    @memcpy(mutable[0..n], text[0..n]);
    s.tryPush(.{ .text = mutable[0..n] }) catch {};
}

/// Serialize into the provider-neutral wire shape shared with the anthropic
/// path and the fakes (docs/specs/turn.md).
fn renderMessage(gpa: std.mem.Allocator, msg: assembler_mod.Message) error{OutOfMemory}![]u8 {
    var blocks: std.ArrayList(u8) = .empty;
    defer blocks.deinit(gpa);

    for (msg.content, 0..) |block, i| {
        if (i != 0) blocks.append(gpa, ',') catch return error.OutOfMemory;
        const rendered = switch (block) {
            .text => |t| std.fmt.allocPrint(gpa, "{{\"type\":\"text\",\"text\":{f}}}", .{json.fmt(t, .{})}),
            .tool_use => |tu| std.fmt.allocPrint(
                gpa,
                "{{\"type\":\"tool_use\",\"id\":{f},\"name\":{f},\"input\":{s}}}",
                .{ json.fmt(tu.id, .{}), json.fmt(tu.name, .{}), if (tu.input_json.len > 0) tu.input_json else "{}" },
            ),
        } catch return error.OutOfMemory;
        defer gpa.free(rendered);
        blocks.appendSlice(gpa, rendered) catch return error.OutOfMemory;
    }

    return std.fmt.allocPrint(gpa,
        \\{{"id":{f},"model":{f},"stop_reason":"{t}","usage":{f},"content":[{s}]}}
    , .{
        json.fmt(msg.id, .{}),
        json.fmt(msg.model, .{}),
        msg.stop_reason,
        json.fmt(msg.usage, .{ .emit_null_optional_fields = false }),
        blocks.items,
    });
}

// ===========================================================================
// Tests — fixture-driven pump only; no sockets, no network (GOAL.md M2 note).
// ===========================================================================

const testing = std.testing;

test "processSse omits unreported cache counts" {
    var reader: std.Io.Reader = .fixed(fixture_text_stream);
    const out = try processSse(testing.allocator, &reader, null, null);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "cache") == null);
}

test "processSse preserves OpenRouter cache counts without subtracting prompt usage" {
    const fixture =
        "data: {\"id\":\"cache\",\"model\":\"fixture\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"done\"},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":100,\"completion_tokens\":7,\"prompt_tokens_details\":{\"cached_tokens\":80,\"cache_write_tokens\":0}}}\n\n" ++
        "data: [DONE]\n\n";
    var reader: std.Io.Reader = .fixed(fixture);
    const out = try processSse(testing.allocator, &reader, null, null);
    defer testing.allocator.free(out);
    var p = try json.parseFromSlice(json.Value, testing.allocator, out, .{});
    defer p.deinit();
    const usage = p.value.object.get("usage").?.object;
    try testing.expect(usage.contains("cache_read_tokens"));
    try testing.expectEqual(@as(i64, 80), usage.get("cache_read_tokens").?.integer);
    try testing.expectEqual(@as(i64, 0), usage.get("cache_creation_tokens").?.integer);
    try testing.expectEqual(@as(i64, 100), usage.get("input_tokens").?.integer);
    try testing.expectEqual(@as(i64, 7), usage.get("output_tokens").?.integer);
}

test "streamChat distinguishes URL and request setup failures without network" {
    try testing.expectError(error.HttpInvalidUrl, streamChat(testing.allocator, .failing, .{
        .api_key = "offline-fixture",
        .model = "fixture",
        .messages_json = "[]",
        .base_url = "invalid url",
    }, null));
    try testing.expectError(error.HttpRequestFailed, streamChat(testing.allocator, .failing, .{
        .api_key = "offline-fixture",
        .model = "fixture",
        .messages_json = "[]",
        .base_url = "ftp://fixture.invalid",
    }, null));
}

const DnsFailureFixture = struct {
    io: std.Io = undefined,
    lookup_calls: usize = 0,
    sleeps: usize = 0,
    transient_failures: usize,
    cancel_sleep: bool = false,

    fn lookup(ctx: ?*anyopaque, _: std.Io.net.HostName, results: *std.Io.Queue(std.Io.net.HostName.LookupResult), _: std.Io.net.HostName.LookupOptions) std.Io.net.HostName.LookupError!void {
        const self: *DnsFailureFixture = @ptrCast(@alignCast(ctx.?));
        defer results.close(self.io);
        self.lookup_calls += 1;
        if (self.lookup_calls <= self.transient_failures) return error.NameServerFailure;
        return error.NetworkDown;
    }

    fn sleep(ctx: ?*anyopaque, _: std.Io.Timeout) std.Io.Cancelable!void {
        const self: *DnsFailureFixture = @ptrCast(@alignCast(ctx.?));
        self.sleeps += 1;
        if (self.cancel_sleep) return error.Canceled;
    }

    fn run(self: *DnsFailureFixture) StreamError![]u8 {
        var vtable = std.Io.failing.vtable.*;
        vtable.netLookup = lookup;
        vtable.sleep = sleep;
        self.io = .{ .userdata = self, .vtable = &vtable };
        return streamChat(testing.allocator, self.io, .{
            .api_key = "offline-fixture",
            .model = "fixture",
            .messages_json = "[]",
            .base_url = "http://fixture.invalid",
        }, null);
    }
};

test "streamChat retries transient DNS setup errors before any HTTP body" {
    var fixture: DnsFailureFixture = .{ .transient_failures = 2 };
    try testing.expectError(error.HttpRequestFailed, fixture.run());
    try testing.expectEqual(@as(usize, 3), fixture.lookup_calls);
    try testing.expectEqual(@as(usize, 2), fixture.sleeps);
}

test "streamChat stops after bounded DNS attempts and does not retry permanent errors" {
    var persistent: DnsFailureFixture = .{ .transient_failures = 10 };
    try testing.expectError(error.HttpRequestFailed, persistent.run());
    try testing.expectEqual(@as(usize, 3), persistent.lookup_calls);
    try testing.expectEqual(@as(usize, 2), persistent.sleeps);
    var permanent: DnsFailureFixture = .{ .transient_failures = 0 };
    try testing.expectError(error.HttpRequestFailed, permanent.run());
    try testing.expectEqual(@as(usize, 1), permanent.lookup_calls);
    try testing.expectEqual(@as(usize, 0), permanent.sleeps);
}

test "streamChat cancels during DNS backoff without another request" {
    var fixture: DnsFailureFixture = .{ .transient_failures = 10, .cancel_sleep = true };
    try testing.expectError(error.HttpRequestFailed, fixture.run());
    try testing.expectEqual(@as(usize, 1), fixture.lookup_calls);
    try testing.expectEqual(@as(usize, 1), fixture.sleeps);
}

const fixture_text_stream =
    "data: {\"id\":\"cc-1\",\"model\":\"gpt-x\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"Hi \"},\"finish_reason\":null}]}\n\n" ++
    "data: {\"id\":\"cc-1\",\"model\":\"gpt-x\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"there\"},\"finish_reason\":null}]}\n\n" ++
    "data: {\"id\":\"cc-1\",\"model\":\"gpt-x\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
    "data: {\"id\":\"cc-1\",\"model\":\"gpt-x\",\"choices\":[],\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":2}}\n\n" ++
    "data: [DONE]\n\n";

test "processSse pumps a chat fixture into deltas and the neutral terminal message" {
    var reader: std.Io.Reader = .fixed(fixture_text_stream);

    var channels = channel_mod.Channels.init(testing.allocator, 300_000);
    defer channels.deinit();
    const refs = try channels.create(16, [_]u8{1} ** 16, 0);
    var sender = try channels.takeSender(refs.writer.channel_id, refs.writer.access_key, 0);
    var receiver = try channels.takeReceiver(refs.reader.channel_id, refs.reader.access_key, 0);
    defer receiver.deinit();

    const out = try processSse(testing.allocator, &reader, &sender, null);
    defer testing.allocator.free(out);
    sender.deinit();

    var p = try json.parseFromSlice(json.Value, testing.allocator, out, .{});
    defer p.deinit();
    try testing.expectEqualStrings("cc-1", p.value.object.get("id").?.string);
    try testing.expectEqualStrings("end_turn", p.value.object.get("stop_reason").?.string);
    try testing.expectEqualStrings("Hi there", p.value.object.get("content").?.array.items[0].object.get("text").?.string);
    try testing.expectEqual(@as(i64, 5), p.value.object.get("usage").?.object.get("input_tokens").?.integer);
    try testing.expectEqual(@as(i64, 2), p.value.object.get("usage").?.object.get("output_tokens").?.integer);

    const d1 = try receiver.pop();
    try testing.expectEqualStrings("Hi ", d1.bytes());
    d1.deinit(testing.allocator);
    const d2 = try receiver.pop();
    try testing.expectEqualStrings("there", d2.bytes());
    d2.deinit(testing.allocator);
    try testing.expectError(error.EndOfStream, receiver.pop());
}

test "processSse renders tool_calls with accumulated arguments, no sender" {
    const fixture =
        "data: {\"id\":\"cc-2\",\"model\":\"gpt-x\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_z\",\"function\":{\"name\":\"bash\",\"arguments\":\"\"}}]},\"finish_reason\":null}]}\n\n" ++
        "data: {\"id\":\"cc-2\",\"model\":\"gpt-x\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"command\\\":\\\"pwd\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}]}\n\n" ++
        "data: [DONE]\n\n";
    var reader: std.Io.Reader = .fixed(fixture);

    const out = try processSse(testing.allocator, &reader, null, null);
    defer testing.allocator.free(out);

    var p = try json.parseFromSlice(json.Value, testing.allocator, out, .{});
    defer p.deinit();
    try testing.expectEqualStrings("tool_use", p.value.object.get("stop_reason").?.string);
    const block = p.value.object.get("content").?.array.items[0].object;
    try testing.expectEqualStrings("call_z", block.get("id").?.string);
    try testing.expectEqualStrings("bash", block.get("name").?.string);
    try testing.expectEqualStrings("pwd", block.get("input").?.object.get("command").?.string);
}

test "processSse pokes the stream guard on every read so idle detection sees activity" {
    var reader: std.Io.Reader = .fixed(fixture_text_stream);
    var dummy: u8 = 0;
    // Not started: poke() works without the watcher thread; only the
    // activity contract is under test here.
    var guard = stream_guard.StreamGuard.init(60_000, @ptrCast(&dummy), &noopFire);
    defer guard.deinit();

    const out = try processSse(testing.allocator, &reader, null, &guard);
    defer testing.allocator.free(out);
    try testing.expect(guard.pokes > 0);
}

fn noopFire(_: *anyopaque) void {}

test "processSse surfaces API error bodies" {
    const fixture =
        "data: {\"error\":{\"message\":\"rate limited\",\"type\":\"rate_limit_error\"}}\n\n";
    var reader: std.Io.Reader = .fixed(fixture);
    try testing.expectError(error.ApiError, processSse(testing.allocator, &reader, null, null));
}

test "truncated chat stream (no [DONE]) is BadStream, not a crash" {
    const fixture =
        "data: {\"id\":\"cc-3\",\"model\":\"gpt-x\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hi\"},\"finish_reason\":null}]}\n\n";
    var reader: std.Io.Reader = .fixed(fixture);
    try testing.expectError(error.BadStream, processSse(testing.allocator, &reader, null, null));
}

test "chatUrl: version-carrying base joins to <base>/chat/completions" {
    const cases = [_]struct { base: []const u8, want: []const u8 }{
        .{ .base = "https://api.openai.com/v1", .want = "https://api.openai.com/v1/chat/completions" },
        .{ .base = "https://openrouter.ai/api/v1", .want = "https://openrouter.ai/api/v1/chat/completions" },
        .{ .base = "https://generativelanguage.googleapis.com/v1beta/openai", .want = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions" },
        .{ .base = "http://localhost:11434/v1", .want = "http://localhost:11434/v1/chat/completions" },
    };
    for (cases) |case| {
        const url = try chatUrl(testing.allocator, case.base);
        defer testing.allocator.free(url);
        try testing.expectEqualStrings(case.want, url);
    }
}

test "buildChatBody: temperature emitted only when set" {
    const no_temp = try buildChatBody(testing.allocator, "gpt-x", 128, "", "", null);
    defer testing.allocator.free(no_temp);
    try testing.expect(std.mem.indexOf(u8, no_temp, "temperature") == null);
    try testing.expect(std.mem.indexOf(u8, no_temp, "\"model\":\"gpt-x\"") != null);

    const with_temp = try buildChatBody(testing.allocator, "gpt-x", 128, "", "", 0.7);
    defer testing.allocator.free(with_temp);
    try testing.expect(std.mem.indexOf(u8, with_temp, "\"temperature\":") != null);
    try testing.expect(std.mem.indexOf(u8, with_temp, "0.7") != null);
}

test "processSse processes each short read before requesting more bytes" {
    const Fragmented = struct {
        reader: std.Io.Reader = .{
            .vtable = &.{ .stream = unreachableStream, .readVec = read },
            .buffer = &.{},
            .seek = 0,
            .end = 0,
        },
        guard: *stream_guard.StreamGuard,
        offset: usize = 0,
        reads: u64 = 0,

        fn unreachableStream(_: *std.Io.Reader, _: *std.Io.Writer, _: std.Io.Limit) std.Io.Reader.StreamError!usize {
            unreachable;
        }

        fn read(r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
            const self: *@This() = @fieldParentPtr("reader", r);
            // A socket may deliver tiny chunks and stay open after the terminal
            // event. No second blocking read is safe until activity is poked.
            if (self.guard.pokes != self.reads or self.offset == fixture_text_stream.len)
                return error.ReadFailed;
            const n = @min(17, @min(data[0].len, fixture_text_stream.len - self.offset));
            @memcpy(data[0][0..n], fixture_text_stream[self.offset..][0..n]);
            self.offset += n;
            self.reads += 1;
            return n;
        }
    };
    var dummy: u8 = 0;
    var guard = stream_guard.StreamGuard.init(120_000, @ptrCast(&dummy), &noopFire);
    defer guard.deinit();
    var input: Fragmented = .{ .guard = &guard };
    const out = try processSse(testing.allocator, &input.reader, null, &guard);
    defer testing.allocator.free(out);
    var parsed = try json.parseFromSlice(json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("end_turn", parsed.value.object.get("stop_reason").?.string);
    try testing.expect(input.reads > 1);
    try testing.expectEqual(input.reads, guard.pokes);
}
