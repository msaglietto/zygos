//! Canonical libc file helpers shared across worker/ and cli/ (the fs twin
//! of jsonx.zig). One definition each for read-whole-file, read-or-empty,
//! mkdir -p, and atomic tmp+rename writes — previously copied per module.
//! mission_store.zig keeps its own Store-scoped variants (distinct error
//! mapping); everything else points here.

const std = @import("std");
const c = std.c;

/// Whole file contents, caller-owned; null on any open/read failure.
pub fn readWholeFile(alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    const path_z = std.fmt.allocPrintSentinel(alloc, "{s}", .{path}, 0) catch return null;
    defer alloc.free(path_z);
    const f = c.fopen(path_z.ptr, "r") orelse return null;
    defer _ = c.fclose(f);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = c.fread(&chunk, 1, chunk.len, f);
        if (n == 0) break;
        buf.appendSlice(alloc, chunk[0..n]) catch return null;
    }
    return buf.toOwnedSlice(alloc) catch null;
}

/// `readWholeFile` with a 0 sentinel (zon parsing wants [:0]const u8).
pub fn readWholeFileZ(alloc: std.mem.Allocator, path: []const u8) ?[:0]u8 {
    const bytes = readWholeFile(alloc, path) orelse return null;
    defer alloc.free(bytes);
    return alloc.dupeZ(u8, bytes) catch null;
}

/// Whole file contents, or "" when the file is missing/unreadable — for
/// append-style flows where an absent file is an empty document.
pub fn readFileOrEmpty(alloc: std.mem.Allocator, path: []const u8) error{OutOfMemory}![]const u8 {
    return readWholeFile(alloc, path) orelse try alloc.dupe(u8, "");
}

pub fn fileExists(path: []const u8) bool {
    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= path_buf.len) return false;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const fd = c.open(@ptrCast(path_buf[0..path.len :0]), .{ .ACCMODE = .RDONLY });
    if (fd < 0) return false;
    _ = c.close(fd);
    return true;
}

/// Single mkdir, all failures ignored (EEXIST is the expected one).
pub fn mkdirQuiet(gpa: std.mem.Allocator, path: []const u8) void {
    const path_z = std.fmt.allocPrintSentinel(gpa, "{s}", .{path}, 0) catch return;
    defer gpa.free(path_z);
    _ = c.mkdir(path_z.ptr, 0o755);
}

/// mkdir -p over every prefix of an absolute path (EEXIST is fine).
pub fn mkdirP(gpa: std.mem.Allocator, abs: []const u8) error{OutOfMemory}!void {
    var end: usize = 1;
    while (end <= abs.len) : (end += 1) {
        if (end == abs.len or abs[end] == '/') {
            const dir_z = gpa.dupeZ(u8, abs[0..end]) catch return error.OutOfMemory;
            defer gpa.free(dir_z);
            _ = c.mkdir(dir_z, 0o755);
        }
    }
}

/// Atomic tmp+rename write (mission_store idiom). Creates parent
/// directories. Each writer owns a unique O_EXCL tmp file (pid + counter):
/// concurrent writers never interleave into one tmp, and rename(2) remains
/// the atomicity boundary — readers see the old file or the new one, never a
/// torn write. fsync before rename keeps the final name from ever pointing
/// at an empty file across a power loss.
var tmp_seq = std.atomic.Value(u64).init(0);

pub fn writeAtomic(gpa: std.mem.Allocator, path: []const u8, bytes: []const u8) error{ Failed, OutOfMemory }!void {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
        try mkdirP(gpa, path[0..slash]);
    }

    const tmp_z = std.fmt.allocPrintSentinel(gpa, "{s}.tmp.{d}.{d}", .{
        path,
        std.c.getpid(),
        tmp_seq.fetchAdd(1, .monotonic),
    }, 0) catch return error.OutOfMemory;
    defer gpa.free(tmp_z);
    const final_z = gpa.dupeZ(u8, path) catch return error.OutOfMemory;
    defer gpa.free(final_z);

    const fd = c.open(tmp_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, @as(c.mode_t, 0o644));
    if (fd < 0) return error.Failed;
    // Whatever happens after a successful create, no tmp residue survives.
    defer _ = c.unlink(tmp_z); // no-op after a successful rename
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(fd, bytes.ptr + off, bytes.len - off);
        if (n <= 0) {
            _ = c.close(fd);
            return error.Failed;
        }
        off += @intCast(n);
    }
    if (c.fsync(fd) != 0) {
        _ = c.close(fd);
        return error.Failed;
    }
    if (c.close(fd) != 0) return error.Failed;
    if (c.rename(tmp_z, final_z) != 0) return error.Failed;
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

fn tmpPath(buf: []u8, comptime name: []const u8) []const u8 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(.REALTIME, &ts);
    return std.fmt.bufPrint(buf, "/tmp/zygos-fsx-{d}-{d}/" ++ name, .{ ts.sec, ts.nsec }) catch unreachable;
}

test "writeAtomic creates parents; readWholeFile round-trips; fileExists agrees" {
    var buf: [128]u8 = undefined;
    const path = tmpPath(&buf, "a/b/file.txt");
    try testing.expect(!fileExists(path));
    try writeAtomic(testing.allocator, path, "payload");
    try testing.expect(fileExists(path));
    const back = readWholeFile(testing.allocator, path).?;
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("payload", back);
}

test "readWholeFile null on missing; readFileOrEmpty empty on missing" {
    try testing.expectEqual(@as(?[]u8, null), readWholeFile(testing.allocator, "/nonexistent/zygos-fsx"));
    const empty = try readFileOrEmpty(testing.allocator, "/nonexistent/zygos-fsx");
    defer testing.allocator.free(empty);
    try testing.expectEqualStrings("", empty);
}

test "readWholeFileZ carries the sentinel" {
    var buf: [128]u8 = undefined;
    const path = tmpPath(&buf, "z.txt");
    try writeAtomic(testing.allocator, path, "zon");
    const back = readWholeFileZ(testing.allocator, path).?;
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("zon", back);
    try testing.expectEqual(@as(u8, 0), back[back.len]);
}

test "writeAtomic overwrites atomically (old content fully replaced)" {
    var buf: [128]u8 = undefined;
    const path = tmpPath(&buf, "swap.txt");
    try writeAtomic(testing.allocator, path, "first version, longer");
    try writeAtomic(testing.allocator, path, "second");
    const back = readWholeFile(testing.allocator, path).?;
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("second", back);
}

test "writeAtomic concurrent writers publish exactly one writer's bytes, no tmp residue" {
    var buf: [128]u8 = undefined;
    const path = tmpPath(&buf, "concurrent.txt");

    const filler = struct {
        fn run(p: []const u8, ch: u8) void {
            var payload: [64 * 1024]u8 = undefined;
            @memset(&payload, ch);
            var i: usize = 0;
            while (i < 40) : (i += 1) {
                writeAtomic(testing.allocator, p, &payload) catch unreachable;
            }
        }
    };

    var a = try std.Thread.spawn(.{}, filler.run, .{ path, 'a' });
    var b = try std.Thread.spawn(.{}, filler.run, .{ path, 'b' });
    a.join();
    b.join();

    // The published file is exactly one writer's pattern — never a mix of
    // 'a' and 'b' bytes from two writers sharing one tmp file.
    const back = readWholeFile(testing.allocator, path).?;
    defer testing.allocator.free(back);
    try testing.expectEqual(@as(usize, 64 * 1024), back.len);
    const first = back[0];
    for (back) |ch| try testing.expectEqual(first, ch);

    // Success paths leave no .tmp siblings behind (libc readdir — std.fs
    // iteration lives behind std.Io, out of worker modules per Z-02).
    var dbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_z = try std.fmt.bufPrintZ(&dbuf, "{s}", .{std.fs.path.dirname(path).?});
    const dir = std.c.opendir(dir_z.ptr) orelse return error.TestUnexpectedResult;
    defer _ = std.c.closedir(dir);
    while (std.c.readdir(dir)) |e| {
        const name = std.mem.sliceTo(&e.name, 0);
        try testing.expect(!std.mem.startsWith(u8, name, "concurrent.txt.tmp"));
    }
}
