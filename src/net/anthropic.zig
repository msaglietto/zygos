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

pub const StreamError = error{ OutOfMemory, HttpInvalidUrl, HttpRequestFailed, HttpSendFailed, HttpReceiveFailed, ApiError, BadStream };

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
    const uri = std.Uri.parse(url) catch |err| {
        log.warn("URL parse failed: {t}", .{err});
        return error.HttpInvalidUrl;
    };

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
        return error.HttpRequestFailed;
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
        // Consume buffered bytes before any blocking read. readSliceShort
        // fills the chunk, and readVec can read again behind a short buffer.
        const n = if (reader.bufferedLen() > 0) buffered: {
            const bytes = reader.buffered();
            const count = @min(chunk.len, bytes.len);
            @memcpy(chunk[0..count], bytes[0..count]);
            reader.toss(count);
            break :buffered count;
        } else read: {
            var buffers = [_][]u8{&chunk};
            break :read reader.readVec(&buffers) catch |err| switch (err) {
                error.EndOfStream => break :stream,
                error.ReadFailed => {
                    log.warn("stream read failed: buffered={d}, activity_updates={d}", .{
                        reader.bufferedLen(), if (guard) |g| g.pokes else 0,
                    });
                    return error.BadStream;
                },
            };
        };
        if (n == 0) continue;
        if (guard) |g| g.poke();
        decoder.feed(chunk[0..n]) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TooLarge => return error.BadStream,
        };

        while (decoder.next() catch return error.OutOfMemory) |event| {
            const name = event.event orelse continue;
            const delta = assembler.onEvent(name, event.data) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ApiError => return error.ApiError,
                error.TooLarge => return error.BadStream,
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
// Tests — fixture-driven pump only; no sockets, no network (GOAL.md M1 note).
// ===========================================================================

const testing = std.testing;

test "streamMessages distinguishes URL and request setup failures without network" {
    try testing.expectError(error.HttpInvalidUrl, streamMessages(testing.allocator, .failing, .{
        .api_key = "offline-fixture",
        .model = "fixture",
        .messages_json = "[]",
        .base_url = "invalid url",
    }, null));
    try testing.expectError(error.HttpRequestFailed, streamMessages(testing.allocator, .failing, .{
        .api_key = "offline-fixture",
        .model = "fixture",
        .messages_json = "[]",
        .base_url = "ftp://fixture.invalid",
    }, null));
}

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

test "start-event tool inputs reach the task bash read and write handlers once each" {
    const task = @import("../worker/task.zig");
    const ops = @import("../worker/tools_ops.zig");
    const trial = @import("../worker/trial.zig");
    const C = struct {
        extern "c" fn realpath(path: [*:0]const u8, resolved: [*]u8) ?[*:0]u8;
    };
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var rel_buf: [std.fs.max_path_bytes]u8 = undefined;
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rel = try std.fmt.bufPrintZ(&rel_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const root = std.mem.span(C.realpath(rel, &root_buf) orelse return error.RealpathFailed);

    // Synthetic compatibility fixtures, not a recording of the Phase 8 stream.
    const starts = [_][]const u8{
        \\{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t-bash","name":"bash","input":{"command":"seq 1 500"}}}
        ,
        \\{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t-read","name":"read_file","input":{"path":"fixture.txt"}}}
        ,
        \\{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t-write","name":"write_file","input":{"path":"note.txt","content":"non-empty start input\n"}}}
        ,
    };
    var script: [4][]const u8 = undefined;
    var made: usize = 0;
    defer for (script[0..made]) |msg| testing.allocator.free(msg);
    for (starts) |start| {
        const fixture = try std.fmt.allocPrint(
            testing.allocator,
            "event: message_start\ndata: {{\"type\":\"message_start\",\"message\":{{\"id\":\"m\",\"model\":\"fixture\"}}}}\n\n" ++
                "event: content_block_start\ndata: {s}\n\n" ++
                "event: content_block_stop\ndata: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
                "event: message_delta\ndata: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"tool_use\"}}}}\n\n" ++
                "event: message_stop\ndata: {{\"type\":\"message_stop\"}}\n\n",
            .{start},
        );
        defer testing.allocator.free(fixture);
        var reader: std.Io.Reader = .fixed(fixture);
        script[made] = try processSse(testing.allocator, &reader, null, null);
        made += 1;
    }
    var end_reader: std.Io.Reader = .fixed(fixture_text_stream);
    script[made] = try processSse(testing.allocator, &end_reader, null, null);
    made += 1;

    const result = try task.run(testing.allocator, .{
        .workspace = root,
        .instruction = "Exercise the SSE tool inputs.",
        .task_id = "offline-sse-input",
        .dataset = "offline-fixture",
        .model_id = "fixture",
        .variable = "trim-on",
        .step_cap = 4,
        .identity = .{
            .git_sha = "0123456789abcdef0123456789abcdef01234567",
            .target_triple = "fixture",
            .optimize = "Debug",
            .adapter_version = trial.adapter_version,
        },
        .script = &script,
        .seed_fixture = true,
    });
    defer result.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, result.turn_json, "handler_failed") == null);
    const written = try ops.readFile(testing.allocator, ops.Workspace.init(root), "note.txt");
    defer testing.allocator.free(written);
    try testing.expectEqualStrings("non-empty start input\n", written);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const record = try trial.parse(arena.allocator(), result.trial_json);
    try testing.expectEqual(@as(u64, 3), record.source_lines_read);
    try testing.expectEqual(@as(u64, 3), record.trim.?.calls);
    try testing.expect(record.trim.?.reduction > 0);
    const turn = try json.parseFromSliceLeaky(json.Value, arena.allocator(), result.turn_json, .{});
    try testing.expectEqualStrings("end_turn", turn.object.get("stop").?.string);
    const transcript = turn.object.get("transcript").?.array.items;
    for ([_]usize{ 2, 4, 6 }) |index| {
        const replies = transcript[index].object.get("content").?.array.items;
        try testing.expectEqual(@as(usize, 1), replies.len);
        try testing.expect(!replies[0].object.get("is_error").?.bool);
    }
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

test "processSse drains buffered terminal events without another socket read" {
    const Buffered = struct {
        reader: std.Io.Reader,
        loaded: bool,

        fn unreachableStream(_: *std.Io.Reader, _: *std.Io.Writer, _: std.Io.Limit) std.Io.Reader.StreamError!usize {
            unreachable;
        }

        fn read(r: *std.Io.Reader, _: [][]u8) std.Io.Reader.Error!usize {
            const self: *@This() = @fieldParentPtr("reader", r);
            if (self.loaded) return error.ReadFailed;
            @memcpy(r.buffer[0..fixture_text_stream.len], fixture_text_stream);
            r.end = fixture_text_stream.len;
            self.loaded = true;
            // TLS and indirect readers can buffer bytes while returning zero.
            return 0;
        }
    };
    for ([_]bool{ true, false }) |seeded| {
        var buffer: [fixture_text_stream.len]u8 = undefined;
        if (seeded) @memcpy(&buffer, fixture_text_stream);
        var input: Buffered = .{
            .reader = .{
                .vtable = &.{ .stream = Buffered.unreachableStream, .readVec = Buffered.read },
                .buffer = &buffer,
                .seek = 0,
                .end = if (seeded) buffer.len else 0,
            },
            .loaded = seeded,
        };
        var dummy: u8 = 0;
        var guard = stream_guard.StreamGuard.init(120_000, @ptrCast(&dummy), &noopFire);
        defer guard.deinit();
        const out = try processSse(testing.allocator, &input.reader, null, &guard);
        defer testing.allocator.free(out);
        var parsed = try json.parseFromSlice(json.Value, testing.allocator, out, .{});
        defer parsed.deinit();
        try testing.expectEqualStrings("end_turn", parsed.value.object.get("stop_reason").?.string);
        try testing.expectEqual(@as(u64, 1), guard.pokes);
    }
}
