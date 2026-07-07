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
    base_url: []const u8 = "https://api.openai.com",
};

pub const StreamError = error{ OutOfMemory, HttpFailed, ApiError, BadStream, BadRequest };

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

    const body = std.fmt.allocPrint(gpa,
        \\{{"model":{f},"max_completion_tokens":{d},"stream":true,"stream_options":{{"include_usage":true}},"messages":[{s}]{s}}}
    , .{
        json.fmt(opts.model, .{}),
        opts.max_tokens,
        joined,
        tools_part,
    }) catch return error.OutOfMemory;
    defer gpa.free(body);

    const url = std.fmt.allocPrint(gpa, "{s}/v1/chat/completions", .{opts.base_url}) catch
        return error.OutOfMemory;
    defer gpa.free(url);
    const uri = std.Uri.parse(url) catch return error.HttpFailed;

    const auth = std.fmt.allocPrint(gpa, "Bearer {s}", .{opts.api_key}) catch
        return error.OutOfMemory;
    defer gpa.free(auth);

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var req = client.request(.POST, uri, .{
        .extra_headers = &.{
            .{ .name = "authorization", .value = auth },
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "accept", .value = "text/event-stream" },
        },
    }) catch |err| {
        log.warn("request setup failed: {t}", .{err});
        return error.HttpFailed;
    };
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = body.len };
    req.sendBodyComplete(body) catch return error.HttpFailed;

    var redirect_buf: [1024]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch return error.HttpFailed;
    if (response.head.status != .ok) {
        log.warn("openai-compat endpoint answered {d}", .{@intFromEnum(response.head.status)});
        return error.ApiError;
    }

    var transfer_buf: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buf);
    return processSse(gpa, reader, sender);
}

/// The network-free pump: read SSE bytes, decode `data:` events (the chat
/// dialect has no event names), assemble, push text deltas into `sender`,
/// return the terminal message JSON in the neutral shape (caller frees).
pub fn processSse(
    gpa: std.mem.Allocator,
    reader: *std.Io.Reader,
    sender: ?*channel_mod.Sender,
) StreamError![]u8 {
    var decoder = sse.Decoder.init(gpa);
    defer decoder.deinit();
    var assembler = assembler_mod.Assembler.init(gpa);
    defer assembler.deinit();

    var chunk: [4096]u8 = undefined;
    stream: while (true) {
        const n = reader.readSliceShort(&chunk) catch return error.BadStream;
        if (n == 0) break :stream;
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
// Tests — fixture-driven pump only; no sockets, no network (GOAL.md M2 note).
// ===========================================================================

const testing = std.testing;

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

    const out = try processSse(testing.allocator, &reader, &sender);
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

    const out = try processSse(testing.allocator, &reader, null);
    defer testing.allocator.free(out);

    var p = try json.parseFromSlice(json.Value, testing.allocator, out, .{});
    defer p.deinit();
    try testing.expectEqualStrings("tool_use", p.value.object.get("stop_reason").?.string);
    const block = p.value.object.get("content").?.array.items[0].object;
    try testing.expectEqualStrings("call_z", block.get("id").?.string);
    try testing.expectEqualStrings("bash", block.get("name").?.string);
    try testing.expectEqualStrings("pwd", block.get("input").?.object.get("command").?.string);
}

test "processSse surfaces API error bodies" {
    const fixture =
        "data: {\"error\":{\"message\":\"rate limited\",\"type\":\"rate_limit_error\"}}\n\n";
    var reader: std.Io.Reader = .fixed(fixture);
    try testing.expectError(error.ApiError, processSse(testing.allocator, &reader, null));
}

test "truncated chat stream (no [DONE]) is BadStream, not a crash" {
    const fixture =
        "data: {\"id\":\"cc-3\",\"model\":\"gpt-x\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hi\"},\"finish_reason\":null}]}\n\n";
    var reader: std.Io.Reader = .fixed(fixture);
    try testing.expectError(error.BadStream, processSse(testing.allocator, &reader, null));
}
