//! Mission control channel (M6, docs/specs/mission-attach.md). `zygos
//! mission attach` needs to reach a RUNNING (or crashed) mission from
//! another process; the channel is an append-only `control.jsonl` in the
//! planning root rather than a socket: libc file IO works in workers
//! (Z-02), survives a crashed mission (commands park until resume), and
//! needs no listener. The running mission CLI tails the file and dispatches
//! each command onto its bus; attach just appends lines.
//!
//! Tolerant by contract: malformed lines are skipped, never fatal; a
//! partial trailing line (mid-append) is not consumed until its newline
//! arrives.

const std = @import("std");
const jsonx = @import("jsonx.zig");
const fsx = @import("fsx.zig");
const readWholeFile = fsx.readWholeFile;

const json = std.json;

pub const file_name = "control.jsonl";

pub const Command = union(enum) {
    steer: struct { text: []const u8 },
    pause,
    @"resume",
    approve: struct { id: []const u8, approved: bool },
};

/// One command as a JSONL line (no trailing newline).
pub fn commandLine(arena: std.mem.Allocator, cmd: Command) error{OutOfMemory}![]const u8 {
    return switch (cmd) {
        .steer => |s| std.fmt.allocPrint(arena, "{{\"cmd\":\"steer\",\"text\":{f}}}", .{json.fmt(s.text, .{})}),
        .pause => arena.dupe(u8, "{\"cmd\":\"pause\"}"),
        .@"resume" => arena.dupe(u8, "{\"cmd\":\"resume\"}"),
        .approve => |a| std.fmt.allocPrint(
            arena,
            "{{\"cmd\":\"approve\",\"id\":{f},\"approved\":{}}}",
            .{ json.fmt(a.id, .{}), a.approved },
        ),
    };
}

/// Tolerant: null for anything malformed or unknown (skipped, never fatal).
pub fn parseCommandLine(arena: std.mem.Allocator, line: []const u8) ?Command {
    const v = json.parseFromSliceLeaky(json.Value, arena, line, .{}) catch return null;
    if (v != .object) return null;
    const cmd = strField(v.object, "cmd") orelse return null;
    if (std.mem.eql(u8, cmd, "steer")) {
        const text = strField(v.object, "text") orelse return null;
        if (text.len == 0) return null;
        return .{ .steer = .{ .text = text } };
    }
    if (std.mem.eql(u8, cmd, "pause")) return .pause;
    if (std.mem.eql(u8, cmd, "resume")) return .@"resume";
    if (std.mem.eql(u8, cmd, "approve")) {
        const id = strField(v.object, "id") orelse return null;
        const approved = v.object.get("approved") orelse return null;
        if (approved != .bool) return null;
        return .{ .approve = .{ .id = id, .approved = approved.bool } };
    }
    return null;
}

/// The bus call a command maps to (pure — the CLI owns the actual call).
pub const Request = struct {
    function: []const u8,
    body: []const u8,
};

pub fn requestFor(
    arena: std.mem.Allocator,
    mission_id: []const u8,
    cmd: Command,
) error{OutOfMemory}!Request {
    return switch (cmd) {
        .steer => |s| .{
            .function = "zygos::missions::steer",
            .body = try std.fmt.allocPrint(arena, "{{\"mission_id\":{f},\"text\":{f}}}", .{
                json.fmt(mission_id, .{}), json.fmt(s.text, .{}),
            }),
        },
        .pause => .{
            .function = "zygos::missions::pause",
            .body = try std.fmt.allocPrint(arena, "{{\"mission_id\":{f}}}", .{json.fmt(mission_id, .{})}),
        },
        .@"resume" => .{
            .function = "zygos::missions::resume",
            .body = try std.fmt.allocPrint(arena, "{{\"mission_id\":{f}}}", .{json.fmt(mission_id, .{})}),
        },
        .approve => |a| .{
            .function = "zygos::approvals::resolve",
            .body = try std.fmt.allocPrint(arena, "{{\"id\":{f},\"approved\":{}}}", .{
                json.fmt(a.id, .{}), a.approved,
            }),
        },
    };
}

/// Incremental reader over an append-only file: `poll` returns the complete
/// lines appended since the previous call. A missing file is an empty poll.
pub const Tail = struct {
    offset: usize = 0,

    pub fn poll(
        self: *Tail,
        arena: std.mem.Allocator,
        path: []const u8,
    ) error{OutOfMemory}![]const []const u8 {
        const text = readWholeFile(arena, path) orelse return &.{};
        if (text.len <= self.offset) return &.{};
        const fresh = text[self.offset..];
        // Only up to the last newline: a mid-append tail waits for its line.
        const consumable = std.mem.lastIndexOfScalar(u8, fresh, '\n') orelse return &.{};
        var out: std.ArrayList([]const u8) = .empty;
        var lines = std.mem.splitScalar(u8, fresh[0..consumable], '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            try out.append(arena, line);
        }
        self.offset += consumable + 1;
        return out.items;
    }
};

/// Append one line (with newline) — the attach side of the channel.
/// Best-effort: an unwritable path is the operator's to notice.
pub fn appendCommand(gpa: std.mem.Allocator, dir: []const u8, cmd: Command) error{OutOfMemory}!void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, file_name });
    const line = try commandLine(arena, cmd);
    const path_z = try std.fmt.allocPrintSentinel(arena, "{s}", .{path}, 0);
    const f = std.c.fopen(path_z.ptr, "a") orelse return;
    defer _ = std.c.fclose(f);
    _ = std.c.fwrite(line.ptr, 1, line.len, f);
    _ = std.c.fwrite("\n", 1, 1, f);
}

const strField = jsonx.strField;

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "commandLine/parseCommandLine round-trip for every command" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_]Command{
        .{ .steer = .{ .text = "focus on the docs" } },
        .pause,
        .@"resume",
        .{ .approve = .{ .id = "ask-1", .approved = true } },
        .{ .approve = .{ .id = "ask-2", .approved = false } },
    };
    for (cases) |cmd| {
        const line = try commandLine(arena, cmd);
        const back = parseCommandLine(arena, line) orelse return error.ParseFailed;
        try testing.expectEqualDeep(cmd, back);
    }
}

test "parseCommandLine: malformed and unknown lines are null" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expect(parseCommandLine(arena, "garbage") == null);
    try testing.expect(parseCommandLine(arena, "{\"cmd\":\"detonate\"}") == null);
    try testing.expect(parseCommandLine(arena, "{\"cmd\":\"steer\"}") == null); // no text
    try testing.expect(parseCommandLine(arena, "{\"cmd\":\"approve\",\"id\":\"x\"}") == null); // no verdict
}

test "requestFor maps commands onto the right bus functions" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const steer = try requestFor(arena, "m-1", .{ .steer = .{ .text = "go" } });
    try testing.expectEqualStrings("zygos::missions::steer", steer.function);
    try testing.expectEqualStrings("{\"mission_id\":\"m-1\",\"text\":\"go\"}", steer.body);

    const pause = try requestFor(arena, "m-1", .pause);
    try testing.expectEqualStrings("zygos::missions::pause", pause.function);
    try testing.expectEqualStrings("{\"mission_id\":\"m-1\"}", pause.body);

    const res = try requestFor(arena, "m-1", .@"resume");
    try testing.expectEqualStrings("zygos::missions::resume", res.function);

    const appr = try requestFor(arena, "m-1", .{ .approve = .{ .id = "ask-9", .approved = true } });
    try testing.expectEqualStrings("zygos::approvals::resolve", appr.function);
    try testing.expectEqualStrings("{\"id\":\"ask-9\",\"approved\":true}", appr.body);
}

extern "c" fn realpath(path: [*:0]const u8, resolved: [*]u8) ?[*:0]u8;

test "Tail.poll returns only complete new lines, incrementally" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    var rel_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rel = try std.fmt.bufPrintZ(&rel_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const dir = std.mem.span(realpath(rel, &dir_buf) orelse return error.RealpathFailed);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, file_name });

    var tail = Tail{};
    // Missing file: empty poll.
    try testing.expectEqual(@as(usize, 0), (try tail.poll(arena, path)).len);

    try appendCommand(testing.allocator, dir, .pause);
    try appendCommand(testing.allocator, dir, .@"resume");
    const first = try tail.poll(arena, path);
    try testing.expectEqual(@as(usize, 2), first.len);
    try testing.expect(std.mem.indexOf(u8, first[0], "pause") != null);

    // Nothing new: empty poll.
    try testing.expectEqual(@as(usize, 0), (try tail.poll(arena, path)).len);

    // A partial trailing line is not consumed until its newline arrives.
    {
        const path_z = try std.fmt.allocPrintSentinel(arena, "{s}", .{path}, 0);
        const f = std.c.fopen(path_z.ptr, "a") orelse return error.OpenFailed;
        const partial = "{\"cmd\":\"pau";
        _ = std.c.fwrite(partial.ptr, 1, partial.len, f);
        _ = std.c.fclose(f);
    }
    try testing.expectEqual(@as(usize, 0), (try tail.poll(arena, path)).len);
    {
        const path_z = try std.fmt.allocPrintSentinel(arena, "{s}", .{path}, 0);
        const f = std.c.fopen(path_z.ptr, "a") orelse return error.OpenFailed;
        const restt = "se\"}\n";
        _ = std.c.fwrite(restt.ptr, 1, restt.len, f);
        _ = std.c.fclose(f);
    }
    const third = try tail.poll(arena, path);
    try testing.expectEqual(@as(usize, 1), third.len);
    try testing.expect(parseCommandLine(arena, third[0]) != null);
}
