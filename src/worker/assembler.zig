//! Shared assembler core (M4.7 roadmap: "Shared assembler core"). One
//! `Message/Usage/Block` + the drift-prone helpers behind BOTH SSE dialects
//! (worker/anthropic.zig, worker/openai.zig), so a compat-endpoint quirk is
//! fixed once: usage-key spellings and duplicate-key tool args have each
//! already bitten twice (GLM). The dialect files keep the event-shape logic;
//! everything provider-neutral lives here.

const std = @import("std");
const jsonx = @import("jsonx.zig");
const json = std.json;

pub const AssembleError = error{ OutOfMemory, MalformedEvent, ApiError, Incomplete };

/// Superset of both dialects' terminal reasons; chat-completions never
/// produces `.stop_sequence`.
pub const StopReason = enum { end_turn, tool_use, max_tokens, stop_sequence, unknown };

pub const Block = union(enum) {
    text: []const u8,
    tool_use: struct { id: []const u8, name: []const u8, input_json: []const u8 },
};

pub const Usage = struct { input_tokens: u64 = 0, output_tokens: u64 = 0 };

/// The provider-neutral terminal message the turn driver consumes —
/// identical across the anthropic path, the chat path, and the fakes.
pub const Message = struct {
    id: []const u8,
    model: []const u8,
    stop_reason: StopReason,
    usage: Usage,
    content: []const Block,
};

/// Anthropic messages-API stop_reason strings.
pub fn parseStopReason(s: []const u8) StopReason {
    if (std.mem.eql(u8, s, "end_turn")) return .end_turn;
    if (std.mem.eql(u8, s, "tool_use")) return .tool_use;
    if (std.mem.eql(u8, s, "max_tokens")) return .max_tokens;
    if (std.mem.eql(u8, s, "stop_sequence")) return .stop_sequence;
    return .unknown;
}

/// Chat-completions finish_reason strings.
pub fn parseFinish(s: []const u8) StopReason {
    if (std.mem.eql(u8, s, "stop")) return .end_turn;
    if (std.mem.eql(u8, s, "tool_calls")) return .tool_use;
    if (std.mem.eql(u8, s, "length")) return .max_tokens;
    return .unknown;
}

/// Take whatever token counts a usage object carries, accepting BOTH key
/// spellings: compat endpoints mix dialects (GLM's anthropic dialect reported
/// input tokens as prompt_tokens, and in message_delta rather than
/// message_start — missing either read as 0↑ live).
pub fn captureUsage(usage: *Usage, u: json.ObjectMap) void {
    if (intField(u, "input_tokens") orelse intField(u, "prompt_tokens")) |n|
        usage.input_tokens = n;
    if (intField(u, "output_tokens") orelse intField(u, "completion_tokens")) |n|
        usage.output_tokens = n;
}

/// Some providers stream tool-args fragments that concatenate into an object
/// with a repeated key (observed: GLM). Strict std.json downstream rejects
/// the whole result frame (DuplicateField), so rewrite exactly that case
/// last-wins (JS JSON.parse semantics). Anything else — valid JSON or
/// garbage — passes through untouched; best-effort, never fails the stream.
pub fn canonicalizeDuplicateKeys(gpa: std.mem.Allocator, input: *std.ArrayList(u8)) void {
    if (std.json.parseFromSlice(std.json.Value, gpa, input.items, .{})) |ok| {
        ok.deinit();
        return;
    } else |err| if (err != error.DuplicateField) return;

    const parsed = std.json.parseFromSlice(std.json.Value, gpa, input.items, .{
        .duplicate_field_behavior = .use_last,
    }) catch return;
    defer parsed.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var ws: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    ws.write(parsed.value) catch return;
    input.clearRetainingCapacity();
    input.appendSlice(gpa, out.written()) catch {};
}

// ---------------------------------------------------------------------------
// JSON field helpers (tolerant: wrong type reads as absent)
// ---------------------------------------------------------------------------

pub const objField = jsonx.objField;
pub const strField = jsonx.strField;
pub const intField = jsonx.uintField;
pub const rawJson = jsonx.rawJson;

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

fn usageFrom(arena: std.mem.Allocator, text: []const u8) !json.ObjectMap {
    const root = try json.parseFromSliceLeaky(json.Value, arena, text, .{});
    return root.object;
}

test "captureUsage: anthropic spellings set both counts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var u: Usage = .{};
    captureUsage(&u, try usageFrom(arena.allocator(), "{\"input_tokens\":11,\"output_tokens\":9}"));
    try testing.expectEqual(@as(u64, 11), u.input_tokens);
    try testing.expectEqual(@as(u64, 9), u.output_tokens);
}

test "captureUsage: openai spellings count too (GLM drift, fixed once here)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var u: Usage = .{};
    captureUsage(&u, try usageFrom(arena.allocator(), "{\"prompt_tokens\":42,\"completion_tokens\":8}"));
    try testing.expectEqual(@as(u64, 42), u.input_tokens);
    try testing.expectEqual(@as(u64, 8), u.output_tokens);
}

test "captureUsage: partial usage leaves the other count untouched" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var u: Usage = .{ .input_tokens = 5 };
    captureUsage(&u, try usageFrom(arena.allocator(), "{\"output_tokens\":3}"));
    try testing.expectEqual(@as(u64, 5), u.input_tokens);
    try testing.expectEqual(@as(u64, 3), u.output_tokens);
}

test "parseStopReason and parseFinish map both dialects onto one enum" {
    try testing.expectEqual(StopReason.end_turn, parseStopReason("end_turn"));
    try testing.expectEqual(StopReason.tool_use, parseStopReason("tool_use"));
    try testing.expectEqual(StopReason.max_tokens, parseStopReason("max_tokens"));
    try testing.expectEqual(StopReason.stop_sequence, parseStopReason("stop_sequence"));
    try testing.expectEqual(StopReason.unknown, parseStopReason("novel"));
    try testing.expectEqual(StopReason.end_turn, parseFinish("stop"));
    try testing.expectEqual(StopReason.tool_use, parseFinish("tool_calls"));
    try testing.expectEqual(StopReason.max_tokens, parseFinish("length"));
    try testing.expectEqual(StopReason.unknown, parseFinish("content_filter"));
}

test "canonicalizeDuplicateKeys: repeated key rewrites last-wins" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try buf.appendSlice(testing.allocator, "{\"command\":\"long one\",\"command\":\"ls -la\"}");
    canonicalizeDuplicateKeys(testing.allocator, &buf);
    try testing.expectEqualStrings("{\"command\":\"ls -la\"}", buf.items);
}

test "canonicalizeDuplicateKeys: valid JSON and garbage pass through untouched" {
    var ok: std.ArrayList(u8) = .empty;
    defer ok.deinit(testing.allocator);
    try ok.appendSlice(testing.allocator, "{\"a\":1}");
    canonicalizeDuplicateKeys(testing.allocator, &ok);
    try testing.expectEqualStrings("{\"a\":1}", ok.items);

    var bad: std.ArrayList(u8) = .empty;
    defer bad.deinit(testing.allocator);
    try bad.appendSlice(testing.allocator, "{not json");
    canonicalizeDuplicateKeys(testing.allocator, &bad);
    try testing.expectEqualStrings("{not json", bad.items);
}
