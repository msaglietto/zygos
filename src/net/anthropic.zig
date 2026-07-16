//! Anthropic Messages HTTP/SSE client (M1 notes in GOAL.md). Lives in
//! src/net/ under the Z-02 amendment (std.Io.Threaded permitted here only).
//! `zig build test` exercises ONLY the network-free pump (`processSse`) over
//! fixture bytes; the HTTP path is an env-gated manual smoke
//! (test/e2e/anthropic/run.sh, ANTHROPIC_API_KEY) and never runs in CI.

const std = @import("std");
const json = std.json;
const sse = @import("../worker/sse.zig");
const assembler_mod = @import("../worker/anthropic.zig");
const channel_mod = @import("../kernel/channel.zig");
const stream_guard = @import("stream_guard.zig");

const log = std.log.scoped(.anthropic);

pub const StreamOptions = struct {
    api_key: []const u8,
    model: []const u8,
    system: []const u8 = "",
    /// Raw JSON array text of Anthropic-shaped messages.
    messages_json: []const u8,
    /// Raw JSON array text of Anthropic-shaped tool definitions ("[]" = none).
    tools_json: []const u8 = "[]",
    max_tokens: u32 = 1024,
    temperature: ?f64 = null,
    base_url: []const u8 = "https://api.anthropic.com",
    anthropic_version: []const u8 = "2023-06-01",
    /// Abort the request when the socket is silent this long (0 disables).
    /// Mirrors the openai client: a silent-but-open connection must not
    /// park the worker thread forever.
    idle_timeout_ms: u64 = stream_guard.default_idle_ms,
};

pub const StreamError = error{ OutOfMemory, HttpFailed, ApiError, BadStream };

/// Blocking call: POST /v1/messages with stream:true, push text deltas into
/// `sender` (closed on return), return the assembled terminal message as
/// JSON text in the provider wire shape (caller frees with gpa):
///   {"id","model","stop_reason","usage":{...},"content":[blocks]}
pub fn streamMessages(
    gpa: std.mem.Allocator,
    io: std.Io,
    opts: StreamOptions,
    sender: ?*channel_mod.Sender,
) StreamError![]u8 {
    defer if (sender) |s| s.close();

    // temperature is emitted only when set (mirrors the openai client).
    const temp_fragment = if (opts.temperature) |temp|
        std.fmt.allocPrint(gpa, ",\"temperature\":{d}", .{temp}) catch return error.OutOfMemory
    else
        gpa.dupe(u8, "") catch return error.OutOfMemory;
    defer gpa.free(temp_fragment);

    const body = std.fmt.allocPrint(gpa,
        \\{{"model":{f},"system":{f},"max_tokens":{d},"stream":true,"messages":{s},"tools":{s}{s}}}
    , .{
        json.fmt(opts.model, .{}),
        json.fmt(opts.system, .{}),
        opts.max_tokens,
        opts.messages_json,
        opts.tools_json,
        temp_fragment,
    }) catch return error.OutOfMemory;
    defer gpa.free(body);

    const url = std.fmt.allocPrint(gpa, "{s}/v1/messages", .{opts.base_url}) catch
        return error.OutOfMemory;
    defer gpa.free(url);
    const uri = std.Uri.parse(url) catch return error.HttpFailed;

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var req = client.request(.POST, uri, .{
        .extra_headers = &.{
            .{ .name = "x-api-key", .value = opts.api_key },
            .{ .name = "anthropic-version", .value = opts.anthropic_version },
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "accept", .value = "text/event-stream" },
        },
    }) catch |err| {
        log.warn("request setup failed: {t}", .{err});
        return error.HttpFailed;
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
    req.sendBodyComplete(body) catch return error.HttpFailed;

    var redirect_buf: [1024]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch return error.HttpFailed;
    if (guard) |*g| g.poke();
    if (response.head.status != .ok) {
        log.warn("anthropic answered {d}", .{@intFromEnum(response.head.status)});
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

/// The network-free pump: read SSE bytes, decode events, assemble, push text
/// deltas into `sender`, return the terminal message JSON (caller frees).
/// Factored out so fixtures can drive it in tests.
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
        const n = reader.readSliceShort(&chunk) catch return error.BadStream;
        if (n == 0) break :stream;
        if (guard) |g| g.poke();
        decoder.feed(chunk[0..n]) catch return error.OutOfMemory;

        while (decoder.next() catch return error.OutOfMemory) |event| {
            const name = event.event orelse continue;
            const delta = assembler.onEvent(name, event.data) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ApiError => return error.ApiError,
                error.MalformedEvent => {
                    log.warn("malformed stream event '{s}' skipped", .{name});
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
    // Pushed slices are duped by the pipe; a full/closed pipe must never
    // stall or fail the model stream — deltas are best-effort telemetry for
    // the caller, the terminal message is the contract.
    var mutable: [4096]u8 = undefined;
    const n = @min(text.len, mutable.len);
    @memcpy(mutable[0..n], text[0..n]);
    s.tryPush(.{ .text = mutable[0..n] }) catch {};
}

/// Serialize the assembled message into the provider wire shape shared with
/// the fake provider (docs/specs/turn.md).
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
        \\{{"id":{f},"model":{f},"stop_reason":"{t}","usage":{{"input_tokens":{d},"output_tokens":{d}}},"content":[{s}]}}
    , .{
        json.fmt(msg.id, .{}),
        json.fmt(msg.model, .{}),
        msg.stop_reason,
        msg.usage.input_tokens,
        msg.usage.output_tokens,
        blocks.items,
    });
}

// ===========================================================================
// Tests — fixture-driven pump only; no sockets, no network (GOAL.md M1 note).
// ===========================================================================

const testing = std.testing;

const fixture_text_stream =
    "event: message_start\n" ++
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_9\",\"model\":\"claude-x\",\"usage\":{\"input_tokens\":3}}}\n\n" ++
    "event: content_block_start\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "event: content_block_delta\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hi \"}}\n\n" ++
    "event: ping\ndata: {}\n\n" ++
    "event: content_block_delta\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"there\"}}\n\n" ++
    "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "event: message_delta\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":7}}\n\n" ++
    "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n";

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

test "processSse pumps a text fixture into deltas and the terminal message" {
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

    // Terminal message in the provider wire shape.
    var p = try json.parseFromSlice(json.Value, testing.allocator, out, .{});
    defer p.deinit();
    try testing.expectEqualStrings("msg_9", p.value.object.get("id").?.string);
    try testing.expectEqualStrings("end_turn", p.value.object.get("stop_reason").?.string);
    try testing.expectEqualStrings("Hi there", p.value.object.get("content").?.array.items[0].object.get("text").?.string);
    try testing.expectEqual(@as(i64, 7), p.value.object.get("usage").?.object.get("output_tokens").?.integer);

    // Deltas rode the channel in order.
    const d1 = try receiver.pop();
    try testing.expectEqualStrings("Hi ", d1.bytes());
    d1.deinit(testing.allocator);
    const d2 = try receiver.pop();
    try testing.expectEqualStrings("there", d2.bytes());
    d2.deinit(testing.allocator);
    try testing.expectError(error.EndOfStream, receiver.pop());
}

test "processSse renders tool_use with accumulated input and works without a sender" {
    const fixture =
        "event: message_start\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_t\",\"model\":\"claude-x\",\"usage\":{\"input_tokens\":1}}}\n\n" ++
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_7\",\"name\":\"bash\",\"input\":{}}}\n\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"command\\\":\"}}\n\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"\\\"pwd\\\"}\"}}\n\n" ++
        "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"}}\n\n" ++
        "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n";
    var reader: std.Io.Reader = .fixed(fixture);

    const out = try processSse(testing.allocator, &reader, null, null);
    defer testing.allocator.free(out);

    var p = try json.parseFromSlice(json.Value, testing.allocator, out, .{});
    defer p.deinit();
    try testing.expectEqualStrings("tool_use", p.value.object.get("stop_reason").?.string);
    const block = p.value.object.get("content").?.array.items[0].object;
    try testing.expectEqualStrings("bash", block.get("name").?.string);
    try testing.expectEqualStrings("pwd", block.get("input").?.object.get("command").?.string);
}

test "processSse surfaces API error events" {
    const fixture =
        "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"later\"}}\n\n";
    var reader: std.Io.Reader = .fixed(fixture);
    try testing.expectError(error.ApiError, processSse(testing.allocator, &reader, null, null));
}

test "truncated stream (no message_stop) is BadStream, not a crash" {
    const fixture =
        "event: message_start\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"model\":\"c\",\"usage\":{}}}\n\n";
    var reader: std.Io.Reader = .fixed(fixture);
    try testing.expectError(error.BadStream, processSse(testing.allocator, &reader, null, null));
}
