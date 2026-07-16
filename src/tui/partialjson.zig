//! Extract a display string from INCOMPLETE streamed JSON (zot's
//! partialjson pattern). Tool arguments arrive as fragments — `{"command":"ls
//! -` — and the live tool box wants the human field (command, path, …) while
//! it is still being composed. This is a tolerant scanner, not a parser: it
//! finds the key, decodes the string value up to wherever the fragment ends,
//! and never fails on truncation.

const std = @import("std");

/// Preference order for the field a live tool box should headline.
pub const display_keys = [_][]const u8{
    "command", "file_path", "path", "content", "query", "url", "pattern", "name",
};

/// Decode the string value of `key` out of possibly-truncated JSON text.
/// Standard escapes are unescaped (\n, \t, \", \\, \uXXXX as best-effort);
/// an unterminated value yields everything up to the fragment end. Returns
/// null when the key (with a string value) is not present yet.
pub fn extractStringField(
    arena: std.mem.Allocator,
    partial: []const u8,
    key: []const u8,
) error{OutOfMemory}!?[]u8 {
    var needle_buf: [64]u8 = undefined;
    if (key.len + 2 > needle_buf.len) return null;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;

    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, partial, search_from, needle)) |at| {
        var i = at + needle.len;
        // Skip whitespace, require a colon, skip whitespace, require a quote.
        while (i < partial.len and (partial[i] == ' ' or partial[i] == '\t' or partial[i] == '\n' or partial[i] == '\r')) i += 1;
        if (i >= partial.len or partial[i] != ':') {
            search_from = at + needle.len;
            continue;
        }
        i += 1;
        while (i < partial.len and (partial[i] == ' ' or partial[i] == '\t' or partial[i] == '\n' or partial[i] == '\r')) i += 1;
        if (i >= partial.len) return try arena.dupe(u8, ""); // value not started yet
        if (partial[i] != '"') {
            search_from = at + needle.len;
            continue; // non-string value (or key matched inside another string)
        }
        return try decodeStringBody(arena, partial[i + 1 ..]);
    }
    return null;
}

/// First display_keys hit, in preference order.
pub fn extractDisplayField(
    arena: std.mem.Allocator,
    partial: []const u8,
) error{OutOfMemory}!?[]u8 {
    for (display_keys) |key| {
        if (try extractStringField(arena, partial, key)) |v| return v;
    }
    return null;
}

/// Unescape a JSON string body that may end mid-value (or mid-escape).
fn decodeStringBody(arena: std.mem.Allocator, body: []const u8) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    var i: usize = 0;
    while (i < body.len) {
        const ch = body[i];
        if (ch == '"') break; // value terminated
        if (ch != '\\') {
            try out.append(arena, ch);
            i += 1;
            continue;
        }
        if (i + 1 >= body.len) break; // fragment ends mid-escape
        i += 1;
        switch (body[i]) {
            'n' => try out.append(arena, '\n'),
            't' => try out.append(arena, '\t'),
            'r' => try out.append(arena, '\r'),
            '"' => try out.append(arena, '"'),
            '\\' => try out.append(arena, '\\'),
            '/' => try out.append(arena, '/'),
            'b', 'f' => try out.append(arena, ' '),
            'u' => {
                if (i + 4 < body.len) {
                    const cp = std.fmt.parseInt(u21, body[i + 1 .. i + 5], 16) catch 0xFFFD;
                    var utf8: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &utf8) catch blk: {
                        utf8[0] = '?';
                        break :blk 1;
                    };
                    try out.appendSlice(arena, utf8[0..n]);
                    i += 4;
                } else {
                    i = body.len; // truncated \uXX…: drop the tail
                    break;
                }
            },
            else => try out.append(arena, body[i]),
        }
        i += 1;
    }
    return out.toOwnedSlice(arena);
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

fn expectExtract(expected: ?[]const u8, partial: []const u8, key: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const got = try extractStringField(arena_state.allocator(), partial, key);
    if (expected) |e| {
        try testing.expectEqualStrings(e, got orelse return error.ExpectedValue);
    } else {
        try testing.expectEqual(@as(?[]u8, null), got);
    }
}

test "complete field extracts fully" {
    try expectExtract("ls -la", "{\"command\":\"ls -la\"}", "command");
}

test "unterminated value yields the streamed prefix" {
    try expectExtract("cat src/ker", "{\"command\":\"cat src/ker", "command");
}

test "value not started yet yields empty, missing key yields null" {
    try expectExtract("", "{\"command\":", "command");
    try expectExtract(null, "{\"comm", "command");
    try expectExtract(null, "{\"query\":\"zig\"}", "command");
}

test "escapes decode; fragment ending mid-escape is safe" {
    try expectExtract("say \"hi\"\nnow", "{\"command\":\"say \\\"hi\\\"\\nnow\"}", "command");
    try expectExtract("tail", "{\"command\":\"tail\\", "command");
    try expectExtract("A", "{\"command\":\"\\u0041\"}", "command");
    try expectExtract("x", "{\"command\":\"x\\u00", "command");
}

test "whitespace around the colon is tolerated" {
    try expectExtract("pwd", "{ \"command\" : \"pwd\" }", "command");
}

test "non-string values and key text inside other strings are skipped" {
    try expectExtract(null, "{\"command\":42}", "command");
    // "command" appears inside another string value first; the real key wins.
    try expectExtract("pwd", "{\"note\":\"the \\\"command\\\" is\",\"command\":\"pwd\"}", "command");
}

test "display preference picks command over content" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const got = try extractDisplayField(
        arena_state.allocator(),
        "{\"content\":\"body\",\"command\":\"make\"}",
    );
    try testing.expectEqualStrings("make", got.?);
}
