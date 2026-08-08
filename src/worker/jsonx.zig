//! Canonical JSON field accessors shared across worker/ and net/ modules.
//! Every helper is total: absent keys and wrong-typed values yield null (or
//! the caller's default), never an error — wire payloads are untrusted.

const std = @import("std");
const json = std.json;

pub fn strField(obj: json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

pub fn objField(obj: json.ObjectMap, key: []const u8) ?json.ObjectMap {
    const v = obj.get(key) orelse return null;
    return if (v == .object) v.object else null;
}

pub fn intField(obj: json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return if (v == .integer) v.integer else null;
}

pub fn intFieldOr(obj: json.ObjectMap, key: []const u8, default: i64) i64 {
    return intField(obj, key) orelse default;
}

pub fn uintField(obj: json.ObjectMap, key: []const u8) ?u64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |n| if (n >= 0) @intCast(n) else null,
        else => null,
    };
}

/// Non-positive integers fall back to the default: sizes and budgets on the
/// wire are meaningful only when strictly positive.
pub fn uintFieldOr(obj: json.ObjectMap, key: []const u8, default: usize) usize {
    const v = obj.get(key) orelse return default;
    if (v != .integer or v.integer <= 0) return default;
    return @intCast(v.integer);
}

/// Minified serialization of a JSON value. Caller owns the returned bytes.
pub fn rawJson(alloc: std.mem.Allocator, value: json.Value) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var ws: json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    ws.write(value) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

/// Parse a request body and read one top-level string field — the shape every
/// control handler uses to find its target id ("mission_id", "turn_id", ...).
pub fn topStrField(arena: std.mem.Allocator, request_json: []const u8, key: []const u8) ?[]const u8 {
    const root = json.parseFromSliceLeaky(json.Value, arena, request_json, .{}) catch return null;
    if (root != .object) return null;
    return strField(root.object, key);
}

const testing = std.testing;

fn parseObj(arena: std.mem.Allocator, src: []const u8) json.ObjectMap {
    const root = json.parseFromSliceLeaky(json.Value, arena, src, .{}) catch unreachable;
    return root.object;
}

test "strField: present string, wrong type, and absent key" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const obj = parseObj(arena_state.allocator(), "{\"a\":\"x\",\"b\":3}");
    try testing.expectEqualStrings("x", strField(obj, "a").?);
    try testing.expectEqual(@as(?[]const u8, null), strField(obj, "b"));
    try testing.expectEqual(@as(?[]const u8, null), strField(obj, "missing"));
}

test "objField: object, non-object, absent" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const obj = parseObj(arena_state.allocator(), "{\"o\":{\"k\":1},\"s\":\"x\"}");
    try testing.expect(objField(obj, "o") != null);
    try testing.expect(objField(obj, "s") == null);
    try testing.expect(objField(obj, "missing") == null);
}

test "intField and intFieldOr: integer, wrong type, absent" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const obj = parseObj(arena_state.allocator(), "{\"n\":-7,\"s\":\"x\"}");
    try testing.expectEqual(@as(?i64, -7), intField(obj, "n"));
    try testing.expectEqual(@as(?i64, null), intField(obj, "s"));
    try testing.expectEqual(@as(i64, -7), intFieldOr(obj, "n", 9));
    try testing.expectEqual(@as(i64, 9), intFieldOr(obj, "missing", 9));
    try testing.expectEqual(@as(i64, 9), intFieldOr(obj, "s", 9));
}

test "uintField: negative integers are not unsigned values" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const obj = parseObj(arena_state.allocator(), "{\"n\":42,\"neg\":-1,\"s\":\"x\"}");
    try testing.expectEqual(@as(?u64, 42), uintField(obj, "n"));
    try testing.expectEqual(@as(?u64, null), uintField(obj, "neg"));
    try testing.expectEqual(@as(?u64, null), uintField(obj, "s"));
}

test "uintFieldOr: zero and negative fall back to the default" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const obj = parseObj(arena_state.allocator(), "{\"n\":5,\"zero\":0,\"neg\":-3}");
    try testing.expectEqual(@as(usize, 5), uintFieldOr(obj, "n", 8));
    try testing.expectEqual(@as(usize, 8), uintFieldOr(obj, "zero", 8));
    try testing.expectEqual(@as(usize, 8), uintFieldOr(obj, "neg", 8));
    try testing.expectEqual(@as(usize, 8), uintFieldOr(obj, "missing", 8));
}

test "rawJson: minified round-trip, caller owns bytes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = json.parseFromSliceLeaky(json.Value, arena, "{ \"a\" : [1, 2] }", .{}) catch unreachable;
    const out = try rawJson(testing.allocator, root);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{\"a\":[1,2]}", out);
}

test "topStrField: reads a top-level string; malformed and non-object inputs yield null" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("m-1", topStrField(arena, "{\"mission_id\":\"m-1\"}", "mission_id").?);
    try testing.expectEqual(@as(?[]const u8, null), topStrField(arena, "not json", "mission_id"));
    try testing.expectEqual(@as(?[]const u8, null), topStrField(arena, "[1,2]", "mission_id"));
    try testing.expectEqual(@as(?[]const u8, null), topStrField(arena, "{\"other\":\"x\"}", "mission_id"));
}
