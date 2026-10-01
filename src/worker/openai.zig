//! OpenAI-compatible chat-completions stream assembler (U4,
//! docs/specs/openai.md). Mirror of worker/anthropic.zig for the
//! chat-completions SSE dialect: chunks arrive as nameless `data: {json}`
//! events ending with `data: [DONE]`. Output is the provider-neutral message
//! shape the turn driver consumes — identical to the anthropic path and the
//! fakes. Also owns the pure neutral→chat request translation so the net
//! glue stays thin and everything here tests without a socket.
//!
//! Robustness contract mirrors anthropic.zig: unknown fields are ignored,
//! malformed JSON on a chunk is MalformedEvent and leaves the assembler
//! usable, an {"error":...} body is ApiError; input bytes never crash.

const std = @import("std");
const stream_tap = @import("stream_tap.zig");
const json = std.json;
const core = @import("assembler.zig");

// Both SSE dialects share one terminal shape and the drift-prone helpers
// (worker/assembler.zig) — a compat-endpoint quirk gets fixed once. The
// chat dialect never produces `.stop_sequence`.
pub const AssembleError = core.AssembleError;
pub const StopReason = core.StopReason;
pub const Block = core.Block;
pub const Usage = core.Usage;
pub const Message = core.Message;

const ToolAcc = struct {
    id: std.ArrayList(u8) = .empty,
    name: std.ArrayList(u8) = .empty,
    args: std.ArrayList(u8) = .empty,
};

pub const Assembler = struct {
    gpa: std.mem.Allocator,
    max_stream_bytes: usize = 16 * 1024 * 1024,
    received_bytes: usize = 0,
    id: []const u8 = "",
    model: []const u8 = "",
    stop_reason: StopReason = .unknown,
    usage: Usage = .{},
    /// choices[0].delta.content fragments, joined.
    text: std.ArrayList(u8) = .empty,
    /// tool_calls accumulators addressed by their wire `index`.
    tools: std.ArrayList(ToolAcc) = .empty,
    done: bool = false,
    delta_buf: std.ArrayList(u8) = .empty,
    materialized: ?[]Block = null,

    pub fn init(gpa: std.mem.Allocator) Assembler {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Assembler) void {
        for (self.tools.items) |*t| {
            t.id.deinit(self.gpa);
            t.name.deinit(self.gpa);
            t.args.deinit(self.gpa);
        }
        self.tools.deinit(self.gpa);
        self.text.deinit(self.gpa);
        self.delta_buf.deinit(self.gpa);
        if (self.materialized) |m| self.gpa.free(m);
        if (self.id.len > 0) self.gpa.free(self.id);
        if (self.model.len > 0) self.gpa.free(self.model);
        self.* = undefined;
    }

    /// Feed one SSE data payload (the dialect has no event names). Returns
    /// the chunk's text delta (valid until the next call) or null.
    pub fn onEvent(self: *Assembler, data_json: []const u8) AssembleError!?[]const u8 {
        if (self.received_bytes > self.max_stream_bytes or data_json.len > self.max_stream_bytes - self.received_bytes)
            return error.TooLarge;
        self.received_bytes += data_json.len;
        const payload = std.mem.trim(u8, data_json, " \t\r\n");
        if (std.mem.eql(u8, payload, "[DONE]")) {
            self.done = true;
            return null;
        }

        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const root = json.parseFromSliceLeaky(json.Value, arena.allocator(), payload, .{}) catch
            return error.MalformedEvent;
        const obj = if (root == .object) root.object else return error.MalformedEvent;

        if (obj.get("error") != null) return error.ApiError;

        if (self.id.len == 0) if (strField(obj, "id")) |id| {
            self.id = try self.gpa.dupe(u8, id);
        };
        if (self.model.len == 0) if (strField(obj, "model")) |m| {
            self.model = try self.gpa.dupe(u8, m);
        };
        if (objField(obj, "usage")) |u| core.captureUsage(&self.usage, u);

        const choices = obj.get("choices") orelse return null;
        if (choices != .array or choices.array.items.len == 0) return null;
        const choice = choices.array.items[0];
        if (choice != .object) return error.MalformedEvent;

        if (strField(choice.object, "finish_reason")) |fr| self.stop_reason = parseFinish(fr);

        const delta = objField(choice.object, "delta") orelse return null;

        if (delta.get("tool_calls")) |tcs| if (tcs == .array) for (tcs.array.items) |tcv| {
            if (tcv != .object) return error.MalformedEvent;
            const tc = tcv.object;
            const index = intField(tc, "index") orelse return error.MalformedEvent;
            // A hostile/buggy endpoint naming index:1e11 would preallocate
            // the tool list to OOM; more than 64 concurrent tool calls in
            // one delta is not a real stream.
            if (index > 63) return error.MalformedEvent;
            while (self.tools.items.len <= index) try self.tools.append(self.gpa, .{});
            const acc = &self.tools.items[@intCast(index)];
            if (strField(tc, "id")) |cid| {
                acc.id.clearRetainingCapacity();
                try acc.id.appendSlice(self.gpa, cid);
            }
            if (objField(tc, "function")) |f| {
                if (strField(f, "name")) |n| {
                    acc.name.clearRetainingCapacity();
                    try acc.name.appendSlice(self.gpa, n);
                    stream_tap.emit(.tool_name, n);
                }
                // Accumulate, never parse: arguments arrive as JSON-text
                // fragments (same rule as anthropic's partial_json).
                if (strField(f, "arguments")) |frag| {
                    try acc.args.appendSlice(self.gpa, frag);
                    stream_tap.emit(.tool_args, frag);
                }
            }
        };

        // Reasoning-model deltas (DeepSeek/GLM/Minimax dialects) are live
        // observability only — never part of the terminal message.
        if (strField(delta, "reasoning_content") orelse strField(delta, "reasoning")) |thought| {
            if (thought.len > 0) stream_tap.emit(.thinking, thought);
        }

        if (strField(delta, "content")) |text| if (text.len > 0) {
            try self.text.appendSlice(self.gpa, text);
            self.delta_buf.clearRetainingCapacity();
            try self.delta_buf.appendSlice(self.gpa, text);
            return self.delta_buf.items;
        };
        return null;
    }

    pub fn isDone(self: *const Assembler) bool {
        return self.done;
    }

    /// The assembled message; slices stay Assembler-owned. Blocks: the text
    /// block first when any text arrived, then tool_use blocks in wire
    /// index order.
    pub fn message(self: *Assembler) AssembleError!Message {
        if (!self.done) return error.Incomplete;
        if (self.materialized == null) {
            for (self.tools.items) |*t| canonicalizeDuplicateKeys(self.gpa, &t.args);
            const has_text = self.text.items.len > 0;
            const out = try self.gpa.alloc(Block, self.tools.items.len + @intFromBool(has_text));
            var i: usize = 0;
            if (has_text) {
                out[i] = .{ .text = self.text.items };
                i += 1;
            }
            for (self.tools.items) |t| {
                out[i] = .{ .tool_use = .{
                    .id = t.id.items,
                    .name = t.name.items,
                    .input_json = t.args.items,
                } };
                i += 1;
            }
            self.materialized = out;
        }
        return .{
            .id = self.id,
            .model = self.model,
            .stop_reason = self.stop_reason,
            .usage = self.usage,
            .content = self.materialized.?,
        };
    }
};

test "chat assembler caps accumulated stream bytes across events" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    const event = "{\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}";
    a.max_stream_bytes = event.len;
    try std.testing.expectEqualStrings("hi", (try a.onEvent(event)).?);
    try std.testing.expectError(error.TooLarge, a.onEvent(event));
}

test "chat assembler refuses hostile tool indexes without growing the tool list" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    try std.testing.expectError(error.MalformedEvent, a.onEvent("{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":100000000000}]}}]}"));
    try std.testing.expectError(error.MalformedEvent, a.onEvent("{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":-1}]}}]}"));
    try std.testing.expectError(error.MalformedEvent, a.onEvent("{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":64}]}}]}"));
    try std.testing.expectEqual(@as(usize, 0), a.tools.items.len);
    try std.testing.expectEqualStrings("ok", (try a.onEvent("{\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}")).?);
}

const canonicalizeDuplicateKeys = core.canonicalizeDuplicateKeys;
const parseFinish = core.parseFinish;
const objField = core.objField;
const strField = core.strField;
const intField = core.intField;
const rawJson = core.rawJson;

// ---------------------------------------------------------------------------
// Neutral → chat-completions request translation (pure)
// ---------------------------------------------------------------------------

pub const TranslateError = error{ OutOfMemory, MalformedMessage };

/// Neutral transcript messages (docs/specs/turn.md shapes) → chat messages:
/// - user string content passes through
/// - user tool_result blocks become role:"tool" messages (one each); text
///   blocks in the same array become a trailing user message
/// - assistant text+tool_use blocks become one assistant message with
///   content + tool_calls (arguments as a JSON-encoded string)
pub fn translateMessages(arena: std.mem.Allocator, messages_json: []const u8) TranslateError![]const u8 {
    const root = json.parseFromSliceLeaky(json.Value, arena, messages_json, .{}) catch
        return error.MalformedMessage;
    if (root != .array) return error.MalformedMessage;

    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '[');
    var first = true;

    for (root.array.items) |mv| {
        if (mv != .object) return error.MalformedMessage;
        const role = strField(mv.object, "role") orelse return error.MalformedMessage;
        const content = mv.object.get("content") orelse return error.MalformedMessage;

        if (content == .string) {
            try appendMsg(&out, arena, &first, try std.fmt.allocPrint(
                arena,
                "{{\"role\":{f},\"content\":{f}}}",
                .{ json.fmt(role, .{}), json.fmt(content.string, .{}) },
            ));
            continue;
        }
        if (content != .array) return error.MalformedMessage;

        if (std.mem.eql(u8, role, "assistant")) {
            var text: std.ArrayList(u8) = .empty;
            var calls: std.ArrayList(u8) = .empty;
            for (content.array.items) |bv| {
                if (bv != .object) continue;
                const btype = strField(bv.object, "type") orelse continue;
                if (std.mem.eql(u8, btype, "text")) {
                    if (strField(bv.object, "text")) |t| try text.appendSlice(arena, t);
                } else if (std.mem.eql(u8, btype, "tool_use")) {
                    const cid = strField(bv.object, "id") orelse return error.MalformedMessage;
                    const cname = strField(bv.object, "name") orelse return error.MalformedMessage;
                    const input = bv.object.get("input") orelse json.Value.null;
                    if (calls.items.len > 0) try calls.append(arena, ',');
                    try calls.appendSlice(arena, try std.fmt.allocPrint(
                        arena,
                        "{{\"id\":{f},\"type\":\"function\",\"function\":{{\"name\":{f},\"arguments\":{f}}}}}",
                        .{ json.fmt(cid, .{}), json.fmt(cname, .{}), json.fmt(try rawJson(arena, input), .{}) },
                    ));
                }
            }
            const content_part: []const u8 = if (text.items.len > 0)
                try std.fmt.allocPrint(arena, "{f}", .{json.fmt(text.items, .{})})
            else
                "null";
            const calls_part: []const u8 = if (calls.items.len > 0)
                try std.fmt.allocPrint(arena, ",\"tool_calls\":[{s}]", .{calls.items})
            else
                "";
            try appendMsg(&out, arena, &first, try std.fmt.allocPrint(
                arena,
                "{{\"role\":\"assistant\",\"content\":{s}{s}}}",
                .{ content_part, calls_part },
            ));
        } else {
            // tool_result blocks become role:"tool" messages, one each;
            // text blocks in the same array become one trailing user msg.
            var texts: std.ArrayList(u8) = .empty;
            for (content.array.items) |bv| {
                if (bv != .object) continue;
                const btype = strField(bv.object, "type") orelse continue;
                if (std.mem.eql(u8, btype, "tool_result")) {
                    const tid = strField(bv.object, "tool_use_id") orelse return error.MalformedMessage;
                    const c = bv.object.get("content") orelse json.Value{ .string = "" };
                    const ctext = if (c == .string) c.string else try rawJson(arena, c);
                    try appendMsg(&out, arena, &first, try std.fmt.allocPrint(
                        arena,
                        "{{\"role\":\"tool\",\"tool_call_id\":{f},\"content\":{f}}}",
                        .{ json.fmt(tid, .{}), json.fmt(ctext, .{}) },
                    ));
                } else if (std.mem.eql(u8, btype, "text")) {
                    if (strField(bv.object, "text")) |t| try texts.appendSlice(arena, t);
                }
            }
            if (texts.items.len > 0) {
                try appendMsg(&out, arena, &first, try std.fmt.allocPrint(
                    arena,
                    "{{\"role\":{f},\"content\":{f}}}",
                    .{ json.fmt(role, .{}), json.fmt(texts.items, .{}) },
                ));
            }
        }
    }
    try out.append(arena, ']');
    return out.items;
}

fn appendMsg(out: *std.ArrayList(u8), arena: std.mem.Allocator, first: *bool, msg: []const u8) error{OutOfMemory}!void {
    if (!first.*) try out.append(arena, ',');
    first.* = false;
    try out.appendSlice(arena, msg);
}

/// Neutral tools ({name,description,input_schema}) → chat tools
/// ({"type":"function","function":{name,description,parameters}}).
pub fn translateTools(arena: std.mem.Allocator, tools_json: []const u8) TranslateError![]const u8 {
    const root = json.parseFromSliceLeaky(json.Value, arena, tools_json, .{}) catch
        return error.MalformedMessage;
    if (root != .array) return error.MalformedMessage;

    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '[');
    for (root.array.items, 0..) |tv, i| {
        if (tv != .object) return error.MalformedMessage;
        const name = strField(tv.object, "name") orelse return error.MalformedMessage;
        const description = strField(tv.object, "description") orelse "";
        const schema_raw: []const u8 = if (tv.object.get("input_schema")) |s| try rawJson(arena, s) else "{}";
        if (i != 0) try out.append(arena, ',');
        try out.appendSlice(arena, try std.fmt.allocPrint(
            arena,
            "{{\"type\":\"function\",\"function\":{{\"name\":{f},\"description\":{f},\"parameters\":{s}}}}}",
            .{ json.fmt(name, .{}), json.fmt(description, .{}), schema_raw },
        ));
    }
    try out.append(arena, ']');
    return out.items;
}

// ===========================================================================
// Tests (docs/specs/openai.md contract, RED first)
// ===========================================================================

const testing = std.testing;

const first_chunk =
    \\{"id":"chatcmpl-1","model":"gpt-x","choices":[{"index":0,"delta":{"role":"assistant","content":"Hel"},"finish_reason":null}]}
;

test "text-only stream: ordered deltas, joined final text, stop end_turn" {
    var a = Assembler.init(testing.allocator);
    defer a.deinit();

    const d1 = try a.onEvent(first_chunk);
    try testing.expectEqualStrings("Hel", d1.?);
    const d2 = try a.onEvent(
        \\{"id":"chatcmpl-1","model":"gpt-x","choices":[{"index":0,"delta":{"content":"lo"},"finish_reason":null}]}
    );
    try testing.expectEqualStrings("lo", d2.?);
    _ = try a.onEvent(
        \\{"id":"chatcmpl-1","model":"gpt-x","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}
    );
    _ = try a.onEvent("[DONE]");

    const msg = try a.message();
    try testing.expectEqualStrings("chatcmpl-1", msg.id);
    try testing.expectEqualStrings("gpt-x", msg.model);
    try testing.expectEqual(StopReason.end_turn, msg.stop_reason);
    try testing.expectEqual(@as(usize, 1), msg.content.len);
    try testing.expectEqualStrings("Hello", msg.content[0].text);
}

const TapCapture = struct {
    gpa: std.mem.Allocator,
    kinds: std.ArrayList(stream_tap.Kind) = .empty,
    chunks: std.ArrayList([]u8) = .empty,

    fn onDelta(ctx: *anyopaque, kind: stream_tap.Kind, bytes: []const u8) void {
        const self: *TapCapture = @ptrCast(@alignCast(ctx));
        const copy = self.gpa.dupe(u8, bytes) catch return;
        self.chunks.append(self.gpa, copy) catch {
            self.gpa.free(copy);
            return;
        };
        self.kinds.append(self.gpa, kind) catch {};
    }

    fn tap(self: *TapCapture) stream_tap.Tap {
        return .{ .ctx = @ptrCast(self), .onDelta = &onDelta };
    }

    fn deinit(self: *TapCapture) void {
        for (self.chunks.items) |c| self.gpa.free(c);
        self.chunks.deinit(self.gpa);
        self.kinds.deinit(self.gpa);
    }
};

test "reasoning_content deltas reach the stream tap, never the final message" {
    var cap = TapCapture{ .gpa = testing.allocator };
    defer cap.deinit();
    const token = stream_tap.register(cap.tap()) orelse return error.NoSlot;
    defer stream_tap.unregister(token);

    var a = Assembler.init(testing.allocator);
    defer a.deinit();
    const d1 = try a.onEvent(
        \\{"id":"c","model":"deepseek-v4","choices":[{"index":0,"delta":{"reasoning_content":"let me think about "},"finish_reason":null}]}
    );
    try testing.expectEqual(@as(?[]const u8, null), d1); // not a text delta
    _ = try a.onEvent(
        \\{"id":"c","model":"deepseek-v4","choices":[{"index":0,"delta":{"reasoning":"allocators"},"finish_reason":null}]}
    );
    _ = try a.onEvent(
        \\{"id":"c","model":"deepseek-v4","choices":[{"index":0,"delta":{"content":"Answer."},"finish_reason":"stop"}]}
    );
    _ = try a.onEvent("[DONE]");

    try testing.expectEqual(@as(usize, 2), cap.chunks.items.len);
    try testing.expectEqual(stream_tap.Kind.thinking, cap.kinds.items[0]);
    try testing.expectEqualStrings("let me think about ", cap.chunks.items[0]);
    try testing.expectEqualStrings("allocators", cap.chunks.items[1]);

    // The terminal message holds only the answer text.
    const msg = try a.message();
    try testing.expectEqual(@as(usize, 1), msg.content.len);
    try testing.expectEqualStrings("Answer.", msg.content[0].text);
}

test "tool_calls stream taps the name and each arguments fragment live" {
    var cap = TapCapture{ .gpa = testing.allocator };
    defer cap.deinit();
    const token = stream_tap.register(cap.tap()) orelse return error.NoSlot;
    defer stream_tap.unregister(token);

    var a = Assembler.init(testing.allocator);
    defer a.deinit();
    _ = try a.onEvent(
        \\{"id":"c","model":"m","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"bash","arguments":"{\"comm"}}]},"finish_reason":null}]}
    );
    _ = try a.onEvent(
        \\{"id":"c","model":"m","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"and\":\"ls\"}"}}]},"finish_reason":"tool_calls"}]}
    );

    try testing.expectEqual(@as(usize, 3), cap.chunks.items.len);
    try testing.expectEqual(stream_tap.Kind.tool_name, cap.kinds.items[0]);
    try testing.expectEqualStrings("bash", cap.chunks.items[0]);
    try testing.expectEqual(stream_tap.Kind.tool_args, cap.kinds.items[1]);
    try testing.expectEqualStrings("{\"comm", cap.chunks.items[1]);
    try testing.expectEqualStrings("and\":\"ls\"}", cap.chunks.items[2]);
}

test "duplicate keys in streamed tool arguments canonicalize last-wins" {
    var a = Assembler.init(testing.allocator);
    defer a.deinit();
    _ = try a.onEvent(
        \\{"id":"c","model":"m","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"bash","arguments":"{\"command\":\"long one\","}}]},"finish_reason":null}]}
    );
    _ = try a.onEvent(
        \\{"id":"c","model":"m","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"command\":\"ls -la\"}"}}]},"finish_reason":"tool_calls"}]}
    );
    _ = try a.onEvent("[DONE]");

    const msg = try a.message();
    try testing.expectEqualStrings("{\"command\":\"ls -la\"}", msg.content[0].tool_use.input_json);
}

test "tool_calls stream: arguments fragments accumulate into input JSON" {
    var a = Assembler.init(testing.allocator);
    defer a.deinit();

    _ = try a.onEvent(
        \\{"id":"c2","model":"gpt-x","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_9","type":"function","function":{"name":"bash","arguments":""}}]},"finish_reason":null}]}
    );
    _ = try a.onEvent(
        \\{"id":"c2","model":"gpt-x","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"comm"}}]},"finish_reason":null}]}
    );
    _ = try a.onEvent(
        \\{"id":"c2","model":"gpt-x","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"and\":\"ls\"}"}}]},"finish_reason":null}]}
    );
    _ = try a.onEvent(
        \\{"id":"c2","model":"gpt-x","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}
    );
    _ = try a.onEvent("[DONE]");

    const msg = try a.message();
    try testing.expectEqual(StopReason.tool_use, msg.stop_reason);
    try testing.expectEqual(@as(usize, 1), msg.content.len);
    try testing.expectEqualStrings("call_9", msg.content[0].tool_use.id);
    try testing.expectEqualStrings("bash", msg.content[0].tool_use.name);
    try testing.expectEqualStrings("{\"command\":\"ls\"}", msg.content[0].tool_use.input_json);
}

test "two parallel tool_calls stay separate and ordered by index" {
    var a = Assembler.init(testing.allocator);
    defer a.deinit();

    _ = try a.onEvent(
        \\{"id":"c3","model":"gpt-x","choices":[{"index":0,"delta":{"tool_calls":[
        \\ {"index":0,"id":"call_a","function":{"name":"read","arguments":"{}"}},
        \\ {"index":1,"id":"call_b","function":{"name":"bash","arguments":""}}]},"finish_reason":null}]}
    );
    _ = try a.onEvent(
        \\{"id":"c3","model":"gpt-x","choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"function":{"arguments":"{\"command\":\"id\"}"}}]},"finish_reason":"tool_calls"}]}
    );
    _ = try a.onEvent("[DONE]");

    const msg = try a.message();
    try testing.expectEqual(@as(usize, 2), msg.content.len);
    try testing.expectEqualStrings("call_a", msg.content[0].tool_use.id);
    try testing.expectEqualStrings("read", msg.content[0].tool_use.name);
    try testing.expectEqualStrings("call_b", msg.content[1].tool_use.id);
    try testing.expectEqualStrings("{\"command\":\"id\"}", msg.content[1].tool_use.input_json);
}

test "finish_reason mapping: length is max_tokens, novelty is unknown" {
    inline for (.{
        .{ "length", StopReason.max_tokens },
        .{ "content_filter", StopReason.unknown },
    }) |case| {
        var a = Assembler.init(testing.allocator);
        defer a.deinit();
        _ = try a.onEvent(first_chunk);
        _ = try a.onEvent(
            \\{"id":"chatcmpl-1","model":"gpt-x","choices":[{"index":0,"delta":{},"finish_reason":"
        ++ case[0] ++
            \\"}]}
        );
        _ = try a.onEvent("[DONE]");
        try testing.expectEqual(case[1], (try a.message()).stop_reason);
    }
}

test "usage captured from the final usage chunk" {
    var a = Assembler.init(testing.allocator);
    defer a.deinit();

    _ = try a.onEvent(first_chunk);
    _ = try a.onEvent(
        \\{"id":"chatcmpl-1","model":"gpt-x","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}
    );
    _ = try a.onEvent(
        \\{"id":"chatcmpl-1","model":"gpt-x","choices":[],"usage":{"prompt_tokens":21,"completion_tokens":8}}
    );
    _ = try a.onEvent("[DONE]");

    const msg = try a.message();
    try testing.expectEqual(@as(u64, 21), msg.usage.input_tokens);
    try testing.expectEqual(@as(u64, 8), msg.usage.output_tokens);
}

test "[DONE] flips isDone; message before it is Incomplete" {
    var a = Assembler.init(testing.allocator);
    defer a.deinit();

    _ = try a.onEvent(first_chunk);
    try testing.expect(!a.isDone());
    try testing.expectError(error.Incomplete, a.message());
    _ = try a.onEvent("[DONE]");
    try testing.expect(a.isDone());
    _ = try a.message();
}

test "error body is ApiError; malformed chunk is MalformedEvent, still usable" {
    var a = Assembler.init(testing.allocator);
    defer a.deinit();

    try testing.expectError(error.ApiError, a.onEvent(
        \\{"error":{"message":"rate limited","type":"rate_limit_error"}}
    ));
    try testing.expectError(error.MalformedEvent, a.onEvent("{nope"));

    _ = try a.onEvent(first_chunk);
    _ = try a.onEvent(
        \\{"id":"chatcmpl-1","model":"gpt-x","choices":[{"index":0,"delta":{"content":"lo"},"finish_reason":"stop"}]}
    );
    _ = try a.onEvent("[DONE]");
    try testing.expectEqualStrings("Hello", (try a.message()).content[0].text);
}

test "no leaks assembling 100 streams" {
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var a = Assembler.init(testing.allocator);
        _ = try a.onEvent(first_chunk);
        _ = try a.onEvent(
            \\{"id":"chatcmpl-1","model":"gpt-x","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c","function":{"name":"f","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}
        );
        _ = try a.onEvent("[DONE]");
        _ = try a.message();
        a.deinit();
    }
}

// -- translation -------------------------------------------------------------

test "translateMessages: user string, assistant tool_use, tool_result rounds" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const neutral =
        \\[{"role":"user","content":"run pwd"},
        \\ {"role":"assistant","content":[{"type":"text","text":"running"},
        \\   {"type":"tool_use","id":"call_1","name":"bash","input":{"command":"pwd"}}]},
        \\ {"role":"user","content":[{"type":"tool_result","tool_use_id":"call_1","content":"/tmp","is_error":false},
        \\   {"type":"text","text":"carry on"}]}]
    ;
    const out = try translateMessages(arena.allocator(), neutral);

    var p = try json.parseFromSlice(json.Value, testing.allocator, out, .{});
    defer p.deinit();
    const msgs = p.value.array.items;
    try testing.expectEqual(@as(usize, 4), msgs.len);

    try testing.expectEqualStrings("user", msgs[0].object.get("role").?.string);
    try testing.expectEqualStrings("run pwd", msgs[0].object.get("content").?.string);

    const asst = msgs[1].object;
    try testing.expectEqualStrings("assistant", asst.get("role").?.string);
    try testing.expectEqualStrings("running", asst.get("content").?.string);
    const call = asst.get("tool_calls").?.array.items[0].object;
    try testing.expectEqualStrings("call_1", call.get("id").?.string);
    try testing.expectEqualStrings("bash", call.get("function").?.object.get("name").?.string);
    // arguments is a STRING of JSON, not an object.
    try testing.expect(call.get("function").?.object.get("arguments").? == .string);

    const tool = msgs[2].object;
    try testing.expectEqualStrings("tool", tool.get("role").?.string);
    try testing.expectEqualStrings("call_1", tool.get("tool_call_id").?.string);
    try testing.expectEqualStrings("/tmp", tool.get("content").?.string);

    try testing.expectEqualStrings("user", msgs[3].object.get("role").?.string);
    try testing.expectEqualStrings("carry on", msgs[3].object.get("content").?.string);
}

test "translateTools wraps neutral tools as function tools" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const neutral =
        \\[{"name":"bash","description":"run a command","input_schema":{"type":"object"}}]
    ;
    const out = try translateTools(arena.allocator(), neutral);

    var p = try json.parseFromSlice(json.Value, testing.allocator, out, .{});
    defer p.deinit();
    const t = p.value.array.items[0].object;
    try testing.expectEqualStrings("function", t.get("type").?.string);
    const f = t.get("function").?.object;
    try testing.expectEqualStrings("bash", f.get("name").?.string);
    try testing.expectEqualStrings("run a command", f.get("description").?.string);
    try testing.expect(f.get("parameters").? == .object);
}

test "translateMessages rejects non-array input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.MalformedMessage, translateMessages(arena.allocator(), "{\"nope\":1}"));
}
