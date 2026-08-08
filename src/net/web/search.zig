//! Search-result normalization: engine JSON (Brave, searxng) -> neutral
//! `{title,url,snippet}[]` and its wire rendering. Pure — no HTTP.

const std = @import("std");
const json = std.json;
const jsonx = @import("../../worker/jsonx.zig");
const strField = jsonx.strField;

pub const SearchResult = struct {
    title: []const u8,
    url: []const u8,
    snippet: []const u8,
};

pub const ParseError = error{ OutOfMemory, UpstreamMalformed };

/// Brave Search API web results → neutral `{title,url,snippet}[]`.
pub fn parseBraveResults(arena: std.mem.Allocator, json_text: []const u8) ParseError![]SearchResult {
    const root = json.parseFromSliceLeaky(json.Value, arena, json_text, .{}) catch
        return error.UpstreamMalformed;
    if (root != .object) return error.UpstreamMalformed;
    const web = root.object.get("web") orelse return error.UpstreamMalformed;
    if (web != .object) return error.UpstreamMalformed;
    const results = web.object.get("results") orelse return error.UpstreamMalformed;
    if (results != .array) return error.UpstreamMalformed;
    return collectResults(arena, results.array.items, "description");
}

/// searxng JSON results → neutral `{title,url,snippet}[]`.
pub fn parseSearxngResults(arena: std.mem.Allocator, json_text: []const u8) ParseError![]SearchResult {
    const root = json.parseFromSliceLeaky(json.Value, arena, json_text, .{}) catch
        return error.UpstreamMalformed;
    if (root != .object) return error.UpstreamMalformed;
    const results = root.object.get("results") orelse return error.UpstreamMalformed;
    if (results != .array) return error.UpstreamMalformed;
    return collectResults(arena, results.array.items, "content");
}

fn collectResults(
    arena: std.mem.Allocator,
    items: []const json.Value,
    snippet_key: []const u8,
) ParseError![]SearchResult {
    var out: std.ArrayList(SearchResult) = .empty;
    errdefer out.deinit(arena);
    for (items) |item| {
        if (item != .object) return error.UpstreamMalformed;
        const title = strField(item.object, "title") orelse return error.UpstreamMalformed;
        const url = strField(item.object, "url") orelse return error.UpstreamMalformed;
        const snippet = strField(item.object, snippet_key) orelse "";
        try out.append(arena, .{
            .title = try arena.dupe(u8, title),
            .url = try arena.dupe(u8, url),
            .snippet = try arena.dupe(u8, snippet),
        });
    }
    return out.toOwnedSlice(arena);
}

pub fn renderResults(arena: std.mem.Allocator, results: []const SearchResult) error{OutOfMemory}![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    errdefer parts.deinit(arena);
    for (results) |r| {
        const item = try std.fmt.allocPrint(arena, "{{\"title\":{f},\"url\":{f},\"snippet\":{f}}}", .{
            json.fmt(r.title, .{}),
            json.fmt(r.url, .{}),
            json.fmt(r.snippet, .{}),
        });
        try parts.append(arena, item);
    }
    const joined = try std.mem.join(arena, ",", parts.items);
    return std.fmt.allocPrint(arena, "{{\"results\":[{s}]}}", .{joined});
}

const testing = std.testing;

const fixture_brave =
    \\{"web":{"results":[
    \\  {"title":"Zig Programming Language","url":"https://ziglang.org/","description":"Zig is a general-purpose programming language."},
    \\  {"title":"Zig GitHub","url":"https://github.com/ziglang/zig","description":"General-purpose programming language and toolchain."}
    \\]}}
;

const fixture_searxng =
    \\{"results":[
    \\  {"title":"Zig Programming Language","url":"https://ziglang.org/","content":"Zig is a general-purpose programming language."},
    \\  {"title":"Zig GitHub","url":"https://github.com/ziglang/zig","content":"General-purpose programming language and toolchain."}
    \\]}
;

test "parseBraveResults + parseSearxngResults: recorded fixtures → neutral shape" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const brave = try parseBraveResults(arena, fixture_brave);
    try testing.expectEqual(@as(usize, 2), brave.len);
    try testing.expectEqualStrings("Zig Programming Language", brave[0].title);
    try testing.expectEqualStrings("https://ziglang.org/", brave[0].url);
    try testing.expectEqualStrings("Zig is a general-purpose programming language.", brave[0].snippet);
    try testing.expectEqualStrings("Zig GitHub", brave[1].title);

    const searx = try parseSearxngResults(arena, fixture_searxng);
    try testing.expectEqual(@as(usize, 2), searx.len);
    try testing.expectEqualStrings("Zig Programming Language", searx[0].title);
    try testing.expectEqualStrings("https://ziglang.org/", searx[0].url);
    try testing.expectEqualStrings("Zig is a general-purpose programming language.", searx[0].snippet);
}

test "malformed upstream search JSON ⇒ error, no crash, no leak" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectError(error.UpstreamMalformed, parseBraveResults(arena, "not-json"));
    try testing.expectError(error.UpstreamMalformed, parseBraveResults(arena, "{\"web\":\"nope\"}"));
    try testing.expectError(error.UpstreamMalformed, parseBraveResults(arena, "{\"web\":{}}"));
    try testing.expectError(error.UpstreamMalformed, parseSearxngResults(arena, "[]"));
    try testing.expectError(error.UpstreamMalformed, parseSearxngResults(arena, "{\"results\":\"x\"}"));
    try testing.expectError(error.UpstreamMalformed, parseSearxngResults(arena, "{\"results\":[1]}"));
}
