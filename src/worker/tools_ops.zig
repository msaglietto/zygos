//! Pure operations behind the M1 agent tools (T5): workspace-confined file
//! read/write and bash execution. No bus code — worker/tools.zig glues these
//! onto the kernel. libc-backed (Zig 0.16 moved std.fs file IO behind
//! std.Io, which stays out of worker modules per Z-02).
//!
//! Confinement contract (M1): lexical normalization of root-joined paths —
//! "..", ".", and absolute-path escapes are rejected; symlink-based escapes
//! are M2 hardening (realpath after the policy gate exists). bash runs with
//! cwd = workspace root and no timeout of its own — the kernel's invocation
//! timeout bounds the bus call.

const std = @import("std");
const c = std.c;

// popen/pclose are not declared in std.c; libc is linked (build.zig).
extern "c" fn popen(command: [*:0]const u8, mode: [*:0]const u8) ?*c.FILE;
extern "c" fn pclose(stream: *c.FILE) c_int;
extern "c" fn realpath(path: [*:0]const u8, resolved: [*]u8) ?[*:0]u8;

pub const OpsError = error{ OutOfMemory, PathEscapesWorkspace, NotFound, AccessDenied, ExecFailed, TooLarge };

pub const read_cap = 4 * 1024 * 1024; // readFile → TooLarge beyond this
pub const output_cap = 1024 * 1024; // bash output truncated (not an error)

/// Lines in `text`. A trailing newline does not invent an extra empty line.
/// Empty input is zero. Shared by the read-file counter and the trial record
/// so both arms count the same bytes.
pub fn countLines(text: []const u8) u64 {
    if (text.len == 0) return 0;
    var n: u64 = 1;
    for (text) |byte| {
        if (byte == '\n') n += 1;
    }
    if (text[text.len - 1] == '\n') n -= 1;
    return n;
}

pub const Workspace = struct {
    /// Absolute, canonical workspace root, no trailing slash.
    root: []const u8,

    pub fn init(root: []const u8) Workspace {
        std.debug.assert(root.len > 1 and root[0] == '/');
        return .{ .root = std.mem.trimEnd(u8, root, "/") };
    }

    /// Join `rel` onto root; reject anything that lexically escapes it.
    /// Returns an owned absolute path (caller frees).
    pub fn resolve(self: Workspace, gpa: std.mem.Allocator, rel: []const u8) OpsError![]u8 {
        if (rel.len == 0 or rel[0] == '/') return error.PathEscapesWorkspace;

        const joined = std.fmt.allocPrint(gpa, "{s}/{s}", .{ self.root, rel }) catch
            return error.OutOfMemory;
        defer gpa.free(joined);

        // Lexical normalization: process "", ".", ".." components.
        var stack: std.ArrayList([]const u8) = .empty;
        defer stack.deinit(gpa);
        var it = std.mem.splitScalar(u8, joined, '/');
        while (it.next()) |comp| {
            if (comp.len == 0 or std.mem.eql(u8, comp, ".")) continue;
            if (std.mem.eql(u8, comp, "..")) {
                if (stack.items.len == 0) return error.PathEscapesWorkspace;
                _ = stack.pop();
                continue;
            }
            stack.append(gpa, comp) catch return error.OutOfMemory;
        }

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        for (stack.items) |comp| {
            out.append(gpa, '/') catch return error.OutOfMemory;
            out.appendSlice(gpa, comp) catch return error.OutOfMemory;
        }
        const resolved = out.toOwnedSlice(gpa) catch return error.OutOfMemory;

        // Must be the root itself or strictly below it.
        const inside = std.mem.startsWith(u8, resolved, self.root) and
            (resolved.len == self.root.len or resolved[self.root.len] == '/');
        if (!inside) {
            gpa.free(resolved);
            return error.PathEscapesWorkspace;
        }
        return resolved;
    }
};

/// Read a workspace file, capped at `read_cap`. Returns owned bytes.
pub fn readFile(gpa: std.mem.Allocator, ws: Workspace, rel_path: []const u8) OpsError![]u8 {
    const abs = try ws.resolve(gpa, rel_path);
    defer gpa.free(abs);
    const abs_z = gpa.dupeZ(u8, abs) catch return error.OutOfMemory;
    defer gpa.free(abs_z);

    const fd = c.open(abs_z, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return error.NotFound; // M1: read-open failures map to NotFound
    defer _ = c.close(fd);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const n = c.read(fd, &chunk, chunk.len);
        if (n < 0) return error.AccessDenied;
        if (n == 0) break;
        if (buf.items.len + @as(usize, @intCast(n)) > read_cap) return error.TooLarge;
        buf.appendSlice(gpa, chunk[0..@intCast(n)]) catch return error.OutOfMemory;
    }
    return buf.toOwnedSlice(gpa) catch return error.OutOfMemory;
}

/// Create/overwrite a workspace file, creating parent dirs inside the root.
pub fn writeFile(gpa: std.mem.Allocator, ws: Workspace, rel_path: []const u8, content: []const u8) OpsError!void {
    const abs = try ws.resolve(gpa, rel_path);
    defer gpa.free(abs);

    // mkdir -p for every parent below root.
    var end: usize = ws.root.len + 1;
    while (std.mem.indexOfScalarPos(u8, abs, end, '/')) |slash| : (end = slash + 1) {
        const dir_z = gpa.dupeZ(u8, abs[0..slash]) catch return error.OutOfMemory;
        defer gpa.free(dir_z);
        _ = c.mkdir(dir_z, 0o755); // EEXIST is fine
    }

    const abs_z = gpa.dupeZ(u8, abs) catch return error.OutOfMemory;
    defer gpa.free(abs_z);
    const fd = c.open(abs_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c.mode_t, 0o644));
    if (fd < 0) return error.AccessDenied;
    defer _ = c.close(fd);

    var off: usize = 0;
    while (off < content.len) {
        const n = c.write(fd, content.ptr + off, content.len - off);
        if (n <= 0) return error.AccessDenied;
        off += @intCast(n);
    }
}

pub const BashResult = struct {
    exit_code: i32,
    /// Combined stdout+stderr, truncated at `output_cap`. Owned.
    output: []u8,
};

/// Run `sh -c command` with cwd = workspace root, stderr folded into stdout.
pub fn bash(gpa: std.mem.Allocator, ws: Workspace, command: []const u8) OpsError!BashResult {
    const quoted_root = try shQuote(gpa, ws.root);
    defer gpa.free(quoted_root);
    const full = std.fmt.allocPrint(gpa, "cd {s} && ( {s} ) 2>&1", .{ quoted_root, command }) catch
        return error.OutOfMemory;
    defer gpa.free(full);
    const full_z = gpa.dupeZ(u8, full) catch return error.OutOfMemory;
    defer gpa.free(full_z);

    const stream = popen(full_z, "r") orelse return error.ExecFailed;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var chunk: [16 * 1024]u8 = undefined;
    while (true) {
        const n = c.fread(&chunk, 1, chunk.len, stream);
        if (n == 0) break;
        if (out.items.len < output_cap) {
            const take = @min(n, output_cap - out.items.len);
            out.appendSlice(gpa, chunk[0..take]) catch return error.OutOfMemory;
        }
        // Past the cap we keep draining so the child never blocks on a full pipe.
    }

    const status = pclose(stream);
    if (status < 0) return error.ExecFailed;
    const exit_code: i32 = if ((status & 0x7f) == 0)
        (status >> 8) & 0xff // WIFEXITED → WEXITSTATUS
    else
        128 + (status & 0x7f); // signaled

    return .{
        .exit_code = exit_code,
        .output = out.toOwnedSlice(gpa) catch return error.OutOfMemory,
    };
}

/// POSIX single-quoting: wrap in ', embedded ' becomes '\''.
fn shQuote(gpa: std.mem.Allocator, s: []const u8) OpsError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    out.append(gpa, '\'') catch return error.OutOfMemory;
    for (s) |ch| {
        if (ch == '\'') {
            out.appendSlice(gpa, "'\\''") catch return error.OutOfMemory;
        } else {
            out.append(gpa, ch) catch return error.OutOfMemory;
        }
    }
    out.append(gpa, '\'') catch return error.OutOfMemory;
    return out.toOwnedSlice(gpa) catch return error.OutOfMemory;
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

const TestWs = struct {
    tmp: std.testing.TmpDir,
    root_buf: [std.fs.max_path_bytes]u8 = undefined,
    ws: Workspace = undefined,

    fn init() !TestWs {
        return .{ .tmp = std.testing.tmpDir(.{}) };
    }

    fn workspace(self: *TestWs) !Workspace {
        // Canonicalize `.zig-cache/tmp/<name>` via libc realpath (io-free).
        var rel_buf: [std.fs.max_path_bytes]u8 = undefined;
        const rel = try std.fmt.bufPrintZ(&rel_buf, ".zig-cache/tmp/{s}", .{self.tmp.sub_path});
        const resolved = realpath(rel, &self.root_buf) orelse return error.RealpathFailed;
        self.ws = Workspace.init(std.mem.span(resolved));
        return self.ws;
    }

    fn deinit(self: *TestWs) void {
        self.tmp.cleanup();
    }
};

test "resolve: plain relative path lands under root" {
    var t = try TestWs.init();
    defer t.deinit();
    const ws = try t.workspace();

    const p = try ws.resolve(testing.allocator, "a/b.txt");
    defer testing.allocator.free(p);
    try testing.expect(std.mem.startsWith(u8, p, ws.root));
    try testing.expect(std.mem.endsWith(u8, p, "/a/b.txt"));
}

test "resolve: dotdot escaping root rejected; inside-root dotdot fine" {
    var t = try TestWs.init();
    defer t.deinit();
    const ws = try t.workspace();

    try testing.expectError(error.PathEscapesWorkspace, ws.resolve(testing.allocator, "../oops"));
    try testing.expectError(error.PathEscapesWorkspace, ws.resolve(testing.allocator, "a/../../../etc/passwd"));

    const ok = try ws.resolve(testing.allocator, "a/../b.txt");
    defer testing.allocator.free(ok);
    try testing.expect(std.mem.endsWith(u8, ok, "/b.txt"));
}

test "resolve: absolute rel path rejected" {
    var t = try TestWs.init();
    defer t.deinit();
    const ws = try t.workspace();
    try testing.expectError(error.PathEscapesWorkspace, ws.resolve(testing.allocator, "/etc/passwd"));
}

test "write then read round-trips; parent dirs auto-created" {
    var t = try TestWs.init();
    defer t.deinit();
    const ws = try t.workspace();

    try writeFile(testing.allocator, ws, "deep/nested/dir/f.txt", "round trip!");
    const got = try readFile(testing.allocator, ws, "deep/nested/dir/f.txt");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("round trip!", got);
}

test "read missing file is NotFound" {
    var t = try TestWs.init();
    defer t.deinit();
    const ws = try t.workspace();
    try testing.expectError(error.NotFound, readFile(testing.allocator, ws, "nope.txt"));
}

test "read over the cap is TooLarge" {
    var t = try TestWs.init();
    defer t.deinit();
    const ws = try t.workspace();

    const big = try testing.allocator.alloc(u8, read_cap + 1);
    defer testing.allocator.free(big);
    @memset(big, 'x');
    try writeFile(testing.allocator, ws, "big.bin", big);
    try testing.expectError(error.TooLarge, readFile(testing.allocator, ws, "big.bin"));
}

test "bash: echo, exit codes, stderr capture" {
    var t = try TestWs.init();
    defer t.deinit();
    const ws = try t.workspace();

    const hi = try bash(testing.allocator, ws, "echo hi");
    defer testing.allocator.free(hi.output);
    try testing.expectEqual(@as(i32, 0), hi.exit_code);
    try testing.expectEqualStrings("hi\n", hi.output);

    const three = try bash(testing.allocator, ws, "exit 3");
    defer testing.allocator.free(three.output);
    try testing.expectEqual(@as(i32, 3), three.exit_code);

    const err = try bash(testing.allocator, ws, "echo oops 1>&2");
    defer testing.allocator.free(err.output);
    try testing.expectEqualStrings("oops\n", err.output);
}

test "bash: cwd is the workspace root, including roots with spaces and quotes" {
    var t = try TestWs.init();
    defer t.deinit();
    const base = try t.workspace();

    // Nested dir with a space AND a single quote in the name.
    try writeFile(testing.allocator, base, "we ird'dir/.keep", "");
    const nested_rel = try base.resolve(testing.allocator, "we ird'dir");
    defer testing.allocator.free(nested_rel);
    const nested = Workspace.init(nested_rel);

    const pwd = try bash(testing.allocator, nested, "pwd");
    defer testing.allocator.free(pwd.output);
    try testing.expectEqual(@as(i32, 0), pwd.exit_code);
    const trimmed = std.mem.trimEnd(u8, pwd.output, "\n");
    try testing.expectEqualStrings(nested.root, trimmed);
}

test "no leaks under repeated op loops" {
    var t = try TestWs.init();
    defer t.deinit();
    const ws = try t.workspace();

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        try writeFile(testing.allocator, ws, "loop.txt", "data");
        const got = try readFile(testing.allocator, ws, "loop.txt");
        testing.allocator.free(got);
        const r = try bash(testing.allocator, ws, "true");
        testing.allocator.free(r.output);
    }
}

test "countLines: empty is zero, a trailing newline is not an extra line" {
    try testing.expectEqual(@as(u64, 0), countLines(""));
    try testing.expectEqual(@as(u64, 1), countLines("alpha"));
    try testing.expectEqual(@as(u64, 3), countLines("alpha\nbeta\ngamma\n"));
    try testing.expectEqual(@as(u64, 3), countLines("alpha\nbeta\ngamma"));
}
