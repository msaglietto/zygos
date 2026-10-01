//! Anthropic Messages-API stream assembler (T3b). Consumes already-decoded
//! SSE events (name + data JSON) and produces user-visible text deltas plus
//! the assembled terminal message — stop_reason, usage, and tool_use blocks
//! with their `input_json` accumulated from partial fragments. Pure std;
//! SSE line decoding is sse.zig's job, sockets are the net layer's.
//!
//! Robustness contract: unknown event names are ignored (forward compat);
//! malformed JSON or missing fields on a KNOWN event is MalformedEvent and
//! leaves the assembler usable; nothing here ever crashes on input bytes.

const std = @import("std");
const json = std.json;
const stream_tap = @import("stream_tap.zig");
const core = @import("assembler.zig");

// Both SSE dialects share one terminal shape and the drift-prone helpers
// (worker/assembler.zig) — a compat-endpoint quirk gets fixed once.
pub const AssembleError = core.AssembleError;
pub const StopReason = core.StopReason;
pub const Block = core.Block;
pub const Usage = core.Usage;
pub const Message = core.Message;

const BlockAcc = union(enum) {
    text: std.ArrayList(u8),
    tool_use: struct {
        id: []const u8, // owned
        name: []const u8, // owned
        input: std.ArrayList(u8),
    },
};

pub const Assembler = struct {
    gpa: std.mem.Allocator,
    max_stream_bytes: usize = 16 * 1024 * 1024,
    received_bytes: usize = 0,
    id: []const u8 = "",
    model: []const u8 = "",
    stop_reason: StopReason = .unknown,
    usage: Usage = .{},
    blocks: std.ArrayList(BlockAcc) = .empty,
    done: bool = false,
    /// The delta slice returned by onEvent lives here until the next call.
    delta_buf: std.ArrayList(u8) = .empty,
    /// message() materializes into this; freed on deinit.
    materialized: ?[]Block = null,

    pub fn init(gpa: std.mem.Allocator) Assembler {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Assembler) void {
        for (self.blocks.items) |*b| switch (b.*) {
            .text => |*t| t.deinit(self.gpa),
            .tool_use => |*tu| {
                self.gpa.free(tu.id);
                self.gpa.free(tu.name);
                tu.input.deinit(self.gpa);
            },
        };
        self.blocks.deinit(self.gpa);
        self.delta_buf.deinit(self.gpa);
        if (self.materialized) |m| self.gpa.free(m);
        if (self.id.len > 0) self.gpa.free(self.id);
        if (self.model.len > 0) self.gpa.free(self.model);
        self.* = undefined;
    }

    /// Feed one SSE event. Returns this event's text delta (valid until the
    /// next onEvent call) or null when it carries no user-visible text.
    pub fn onEvent(
        self: *Assembler,
        event_name: []const u8,
        data_json: []const u8,
    ) AssembleError!?[]const u8 {
        if (self.received_bytes > self.max_stream_bytes or data_json.len > self.max_stream_bytes - self.received_bytes)
            return error.TooLarge;
        self.received_bytes += data_json.len;
        const Kind = enum {
            message_start,
            content_block_start,
            content_block_delta,
            content_block_stop,
            message_delta,
            message_stop,
            ping,
            err,
            other,
        };
        const kind: Kind = if (std.mem.eql(u8, event_name, "message_start"))
            .message_start
        else if (std.mem.eql(u8, event_name, "content_block_start"))
            .content_block_start
        else if (std.mem.eql(u8, event_name, "content_block_delta"))
            .content_block_delta
        else if (std.mem.eql(u8, event_name, "content_block_stop"))
            .content_block_stop
        else if (std.mem.eql(u8, event_name, "message_delta"))
            .message_delta
        else if (std.mem.eql(u8, event_name, "message_stop"))
            .message_stop
        else if (std.mem.eql(u8, event_name, "ping"))
            .ping
        else if (std.mem.eql(u8, event_name, "error"))
            .err
        else
            .other;

        if (kind == .ping or kind == .other) return null;
        if (kind == .message_stop) {
            self.done = true;
            return null;
        }

        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const root = json.parseFromSliceLeaky(json.Value, arena.allocator(), data_json, .{}) catch
            return error.MalformedEvent;
        const obj = if (root == .object) root.object else return error.MalformedEvent;

        switch (kind) {
            .err => return error.ApiError,
            .message_start => {
                const msg = objField(obj, "message") orelse return error.MalformedEvent;
                const id = strField(msg, "id") orelse return error.MalformedEvent;
                const model = strField(msg, "model") orelse return error.MalformedEvent;
                if (self.id.len > 0) self.gpa.free(self.id);
                if (self.model.len > 0) self.gpa.free(self.model);
                self.id = try self.gpa.dupe(u8, id);
                self.model = try self.gpa.dupe(u8, model);
                if (objField(msg, "usage")) |u| self.captureUsage(u);
                return null;
            },
            .content_block_start => {
                const index = intField(obj, "index") orelse return error.MalformedEvent;
                if (index != self.blocks.items.len) return error.MalformedEvent; // gap
                const cb = objField(obj, "content_block") orelse return error.MalformedEvent;
                const cb_type = strField(cb, "type") orelse return error.MalformedEvent;
                if (std.mem.eql(u8, cb_type, "text")) {
                    try self.blocks.append(self.gpa, .{ .text = .empty });
                } else if (std.mem.eql(u8, cb_type, "tool_use")) {
                    const id = try self.gpa.dupe(u8, strField(cb, "id") orelse return error.MalformedEvent);
                    errdefer self.gpa.free(id);
                    const name = try self.gpa.dupe(u8, strField(cb, "name") orelse return error.MalformedEvent);
                    errdefer self.gpa.free(name);
                    // The start's "input" value is ignored by contract; the
                    // real input is the concatenated partial_json fragments.
                    try self.blocks.append(self.gpa, .{ .tool_use = .{ .id = id, .name = name, .input = .empty } });
                    stream_tap.emit(.tool_name, name);
                } else {
                    // Unknown block kind: keep indexes aligned with a text acc.
                    try self.blocks.append(self.gpa, .{ .text = .empty });
                }
                return null;
            },
            .content_block_delta => {
                const index = intField(obj, "index") orelse return error.MalformedEvent;
                if (index >= self.blocks.items.len) return error.MalformedEvent;
                const delta = objField(obj, "delta") orelse return error.MalformedEvent;
                const dtype = strField(delta, "type") orelse return error.MalformedEvent;
                if (std.mem.eql(u8, dtype, "text_delta")) {
                    const text = strField(delta, "text") orelse return error.MalformedEvent;
                    switch (self.blocks.items[@intCast(index)]) {
                        .text => |*t| try t.appendSlice(self.gpa, text),
                        .tool_use => return error.MalformedEvent,
                    }
                    self.delta_buf.clearRetainingCapacity();
                    try self.delta_buf.appendSlice(self.gpa, text);
                    return self.delta_buf.items;
                } else if (std.mem.eql(u8, dtype, "input_json_delta")) {
                    const fragment = strField(delta, "partial_json") orelse return error.MalformedEvent;
                    switch (self.blocks.items[@intCast(index)]) {
                        .tool_use => |*tu| try tu.input.appendSlice(self.gpa, fragment),
                        .text => return error.MalformedEvent,
                    }
                    stream_tap.emit(.tool_args, fragment);
                    return null;
                } else if (std.mem.eql(u8, dtype, "thinking_delta")) {
                    // Extended-thinking text: live observability only, never
                    // part of the terminal message (the block acc at this
                    // index is the unknown-kind text placeholder — untouched).
                    if (strField(delta, "thinking")) |thought| {
                        if (thought.len > 0) stream_tap.emit(.thinking, thought);
                    }
                    return null;
                }
                return null; // unknown delta kinds skipped (forward compat)
            },
            .content_block_stop => return null,
            .message_delta => {
                if (objField(obj, "delta")) |d| {
                    if (strField(d, "stop_reason")) |sr| self.stop_reason = parseStopReason(sr);
                }
                if (objField(obj, "usage")) |u| self.captureUsage(u);
                return null;
            },
            else => unreachable,
        }
    }

    fn captureUsage(self: *Assembler, u: json.ObjectMap) void {
        core.captureUsage(&self.usage, u);
    }

    pub fn isDone(self: *const Assembler) bool {
        return self.done;
    }

    /// The assembled message; slices remain Assembler-owned.
    pub fn message(self: *Assembler) AssembleError!Message {
        if (!self.done) return error.Incomplete;
        if (self.materialized == null) {
            for (self.blocks.items) |*b| switch (b.*) {
                .tool_use => |*tu| canonicalizeDuplicateKeys(self.gpa, &tu.input),
                else => {},
            };
            const out = try self.gpa.alloc(Block, self.blocks.items.len);
            for (self.blocks.items, 0..) |b, i| {
                out[i] = switch (b) {
                    .text => |t| .{ .text = t.items },
                    .tool_use => |tu| .{ .tool_use = .{
                        .id = tu.id,
                        .name = tu.name,
                        .input_json = tu.input.items,
                    } },
                };
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

test "anthropic assembler caps accumulated stream bytes across events" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    a.max_stream_bytes = 2;
    try std.testing.expectEqual(@as(?[]const u8, null), try a.onEvent("ping", "{}"));
    try std.testing.expectError(error.TooLarge, a.onEvent("ping", "{}"));
}

const canonicalizeDuplicateKeys = core.canonicalizeDuplicateKeys;
const parseStopReason = core.parseStopReason;
const objField = core.objField;
const strField = core.strField;
const intField = core.intField;

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

const start_ev =
    \\{"type":"message_start","message":{"id":"msg_1","model":"claude-x","role":"assistant","content":[],"usage":{"input_tokens":11,"output_tokens":1}}}
;

fn feedTextStream(a: *Assembler) !void {
    _ = try a.onEvent("message_start", start_ev);
    _ = try a.onEvent("content_block_start",
        \\{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
    );
    _ = try a.onEvent("content_block_delta",
        \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello, "}}
    );
    _ = try a.onEvent("content_block_delta",
        \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"world"}}
    );
    _ = try a.onEvent("content_block_stop",
        \\{"type":"content_block_stop","index":0}
    );
    _ = try a.onEvent("message_delta",
        \\{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":9}}
    );
    _ = try a.onEvent("message_stop",
        \\{"type":"message_stop"}
    );
}

test "text-only stream assembles with ordered deltas and joined final text" {
    var a = Assembler.init(testing.allocator);
    defer a.deinit();

    _ = try a.onEvent("message_start", start_ev);
    _ = try a.onEvent("content_block_start",
        \\{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
    );
    const d1 = try a.onEvent("content_block_delta",
        \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello, "}}
    );
    try testing.expectEqualStrings("Hello, ", d1.?);
    const d2 = try a.onEvent("content_block_delta",
        \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"world"}}
    );
    try testing.expectEqualStrings("world", d2.?);
    _ = try a.onEvent("message_delta",
        \\{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":9}}
    );
    _ = try a.onEvent("message_stop", "{\"type\":\"message_stop\"}");

    const msg = try a.message();
    try testing.expectEqualStrings("msg_1", msg.id);
    try testing.expectEqualStrings("claude-x", msg.model);
    try testing.expectEqual(StopReason.end_turn, msg.stop_reason);
    try testing.expectEqual(@as(usize, 1), msg.content.len);
    try testing.expectEqualStrings("Hello, world", msg.content[0].text);
}

test "tool_use stream accumulates partial_json fragments into input_json" {
    var a = Assembler.init(testing.allocator);
    defer a.deinit();

    _ = try a.onEvent("message_start", start_ev);
    _ = try a.onEvent("content_block_start",
        \\{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"bash","input":{}}}
    );
    try testing.expect((try a.onEvent("content_block_delta",
        \\{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"comm"}}
    )) == null);
    _ = try a.onEvent("content_block_delta",
        \\{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"and\":\"ls\"}"}}
    );
    _ = try a.onEvent("content_block_stop", "{\"type\":\"content_block_stop\",\"index\":0}");
    _ = try a.onEvent("message_delta",
        \\{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":5}}
    );
    _ = try a.onEvent("message_stop", "{\"type\":\"message_stop\"}");

    const msg = try a.message();
    try testing.expectEqual(StopReason.tool_use, msg.stop_reason);
    try testing.expectEqualStrings("toolu_1", msg.content[0].tool_use.id);
    try testing.expectEqualStrings("bash", msg.content[0].tool_use.name);
    try testing.expectEqualStrings("{\"command\":\"ls\"}", msg.content[0].tool_use.input_json);
}

test "duplicate keys in streamed tool input canonicalize last-wins" {
    var a = Assembler.init(testing.allocator);
    defer a.deinit();

    // GLM's anthropic dialect has been observed streaming fragments that
    // concatenate into {"command":"...","command":"..."} — strict std.json
    // downstream rejects the whole result frame (DuplicateField).
    _ = try a.onEvent("message_start", start_ev);
    _ = try a.onEvent("content_block_start",
        \\{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"bash","input":{}}}
    );
    _ = try a.onEvent("content_block_delta",
        \\{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"command\":\"long one\","}}
    );
    _ = try a.onEvent("content_block_delta",
        \\{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\"command\":\"ls -la\"}"}}
    );
    _ = try a.onEvent("content_block_stop", "{\"type\":\"content_block_stop\",\"index\":0}");
    _ = try a.onEvent("message_delta",
        \\{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":5}}
    );
    _ = try a.onEvent("message_stop", "{\"type\":\"message_stop\"}");

    const msg = try a.message();
    try testing.expectEqualStrings("{\"command\":\"ls -la\"}", msg.content[0].tool_use.input_json);
}

test "mixed text and tool_use blocks preserve order and indexes" {
    var a = Assembler.init(testing.allocator);
    defer a.deinit();

    _ = try a.onEvent("message_start", start_ev);
    _ = try a.onEvent("content_block_start",
        \\{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
    );
    _ = try a.onEvent("content_block_delta",
        \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"checking"}}
    );
    _ = try a.onEvent("content_block_stop", "{\"type\":\"content_block_stop\",\"index\":0}");
    _ = try a.onEvent("content_block_start",
        \\{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"t2","name":"read","input":{}}}
    );
    _ = try a.onEvent("content_block_delta",
        \\{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{}"}}
    );
    _ = try a.onEvent("message_stop", "{\"type\":\"message_stop\"}");

    const msg = try a.message();
    try testing.expectEqual(@as(usize, 2), msg.content.len);
    try testing.expectEqualStrings("checking", msg.content[0].text);
    try testing.expectEqualStrings("read", msg.content[1].tool_use.name);
}

test "usage captured from message_start and message_delta" {
    var a = Assembler.init(testing.allocator);
    defer a.deinit();
    try feedTextStream(&a);
    const msg = try a.message();
    try testing.expectEqual(@as(u64, 11), msg.usage.input_tokens);
    try testing.expectEqual(@as(u64, 9), msg.usage.output_tokens);
}

test "usage arriving late or under openai-style keys still counts (GLM anthropic dialect)" {
    // GLM's anthropic-compat endpoint reports input tokens in message_delta
    // (not message_start) and has been seen using prompt_tokens spelling —
    // a mission showed 0↑ while output climbed.
    var a = Assembler.init(testing.allocator);
    defer a.deinit();
    _ = try a.onEvent("message_start",
        \\{"type":"message_start","message":{"id":"m","model":"glm-5.2","content":[],"usage":{"output_tokens":0}}}
    );
    _ = try a.onEvent("content_block_start",
        \\{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
    );
    _ = try a.onEvent("content_block_stop",
        \\{"type":"content_block_stop","index":0}
    );
    _ = try a.onEvent("message_delta",
        \\{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"prompt_tokens":42,"output_tokens":9}}
    );
    _ = try a.onEvent("message_stop", "{\"type\":\"message_stop\"}");
    const msg = try a.message();
    try testing.expectEqual(@as(u64, 42), msg.usage.input_tokens);
    try testing.expectEqual(@as(u64, 9), msg.usage.output_tokens);
}

test "ping and unknown events return null and change nothing" {
    var a = Assembler.init(testing.allocator);
    defer a.deinit();
    try testing.expect((try a.onEvent("ping", "{\"type\":\"ping\"}")) == null);
    try testing.expect((try a.onEvent("future_event", "{\"whatever\":1}")) == null);
    try testing.expect(!a.isDone());
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

test "thinking_delta reaches the stream tap and never the final message" {
    var cap = TapCapture{ .gpa = testing.allocator };
    defer cap.deinit();
    const token = stream_tap.register(cap.tap()) orelse return error.NoSlot;
    defer stream_tap.unregister(token);

    var a = Assembler.init(testing.allocator);
    defer a.deinit();
    _ = try a.onEvent("message_start", start_ev);
    _ = try a.onEvent("content_block_start",
        \\{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}
    );
    _ = try a.onEvent("content_block_delta",
        \\{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"weighing the options"}}
    );
    _ = try a.onEvent("content_block_stop",
        \\{"type":"content_block_stop","index":0}
    );
    _ = try a.onEvent("content_block_start",
        \\{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}
    );
    _ = try a.onEvent("content_block_delta",
        \\{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Answer."}}
    );
    _ = try a.onEvent("message_delta",
        \\{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":9}}
    );
    _ = try a.onEvent("message_stop",
        \\{"type":"message_stop"}
    );

    try testing.expectEqual(@as(usize, 1), cap.chunks.items.len);
    try testing.expectEqual(stream_tap.Kind.thinking, cap.kinds.items[0]);
    try testing.expectEqualStrings("weighing the options", cap.chunks.items[0]);

    const msg = try a.message();
    // Thinking placeholder block stays empty; the answer text is intact.
    try testing.expectEqualStrings("", msg.content[0].text);
    try testing.expectEqualStrings("Answer.", msg.content[1].text);
}

test "tool_use start and input_json_delta fragments reach the stream tap" {
    var cap = TapCapture{ .gpa = testing.allocator };
    defer cap.deinit();
    const token = stream_tap.register(cap.tap()) orelse return error.NoSlot;
    defer stream_tap.unregister(token);

    var a = Assembler.init(testing.allocator);
    defer a.deinit();
    _ = try a.onEvent("message_start", start_ev);
    _ = try a.onEvent("content_block_start",
        \\{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tu_1","name":"bash","input":{}}}
    );
    _ = try a.onEvent("content_block_delta",
        \\{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"command\":"}}
    );
    _ = try a.onEvent("content_block_delta",
        \\{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\"pwd\"}"}}
    );

    try testing.expectEqual(@as(usize, 3), cap.chunks.items.len);
    try testing.expectEqual(stream_tap.Kind.tool_name, cap.kinds.items[0]);
    try testing.expectEqualStrings("bash", cap.chunks.items[0]);
    try testing.expectEqual(stream_tap.Kind.tool_args, cap.kinds.items[1]);
    try testing.expectEqualStrings("{\"command\":", cap.chunks.items[1]);
    try testing.expectEqualStrings("\"pwd\"}", cap.chunks.items[2]);
}

test "error event returns ApiError" {
    var a = Assembler.init(testing.allocator);
    defer a.deinit();
    try testing.expectError(error.ApiError, a.onEvent("error",
        \\{"type":"error","error":{"type":"overloaded_error","message":"try later"}}
    ));
}

test "message before message_stop returns Incomplete" {
    var a = Assembler.init(testing.allocator);
    defer a.deinit();
    _ = try a.onEvent("message_start", start_ev);
    try testing.expectError(error.Incomplete, a.message());
}

test "malformed JSON on known event returns MalformedEvent; assembler still usable" {
    var a = Assembler.init(testing.allocator);
    defer a.deinit();
    try testing.expectError(error.MalformedEvent, a.onEvent("message_start", "{nope"));
    try testing.expectError(error.MalformedEvent, a.onEvent("content_block_start", "{\"type\":\"content_block_start\"}"));
    // Still assembles a full stream afterwards.
    try feedTextStream(&a);
    const msg = try a.message();
    try testing.expectEqualStrings("Hello, world", msg.content[0].text);
}

test "unknown stop_reason maps to .unknown" {
    var a = Assembler.init(testing.allocator);
    defer a.deinit();
    _ = try a.onEvent("message_start", start_ev);
    _ = try a.onEvent("message_delta",
        \\{"type":"message_delta","delta":{"stop_reason":"brand_new_reason"}}
    );
    _ = try a.onEvent("message_stop", "{\"type\":\"message_stop\"}");
    try testing.expectEqual(StopReason.unknown, (try a.message()).stop_reason);
}

test "no leaks assembling 100 messages in a loop" {
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var a = Assembler.init(testing.allocator);
        try feedTextStream(&a);
        _ = try a.message();
        a.deinit();
    }
}
