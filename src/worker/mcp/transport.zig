//! Line-oriented transports for MCP clients: the Transport vtable the
//! JSON-RPC client talks through, and the child-process implementation
//! (fork/exec + close-on-exec pipes under `fork_guard.lock`, libc-backed).
//! Protocol logic lives in client.zig — this file never parses JSON.

const std = @import("std");
const c = std.c;
const sync = @import("../../kernel/sync.zig");
const fork_guard = @import("../fork_guard.zig");

pub const TransportError = error{ Io, OutOfMemory };

/// Line budget for stdio reads: a runaway server streaming unterminated
/// bytes must OOM nobody. 1 MiB is far past any real JSON-RPC line.
pub const max_line_bytes = 1024 * 1024;

/// Line-oriented duplex channel to one MCP server. `readLine` returns null
/// on EOF; returned slices are gpa-owned by the caller.
pub const Transport = struct {
    ctx: *anyopaque,
    writeLineFn: *const fn (ctx: *anyopaque, line: []const u8) TransportError!void,
    readLineFn: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator) TransportError!?[]u8,

    pub fn writeLine(self: Transport, line: []const u8) TransportError!void {
        return self.writeLineFn(self.ctx, line);
    }
    pub fn readLine(self: Transport, gpa: std.mem.Allocator) TransportError!?[]u8 {
        return self.readLineFn(self.ctx, gpa);
    }
};

extern "c" fn fork() c.pid_t;
extern "c" fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
extern "c" var environ: [*:null]?[*:0]const u8;
extern "c" fn waitpid(pid: c.pid_t, status: ?*c_int, options: c_int) c.pid_t;
extern "c" fn kill(pid: c.pid_t, sig: c_int) c_int;
extern "c" fn fdopen(fd: c_int, mode: [*:0]const u8) ?*c.FILE;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn _exit(status: c_int) noreturn;
extern "c" fn fflush(stream: *c.FILE) c_int;
extern "c" fn fileno(stream: *c.FILE) c_int;

const SIGTERM: c_int = @intFromEnum(c.SIG.TERM);

fn monotonicMs() i64 {
    var ts: c.timespec = undefined;
    if (c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

/// `execvp` fallback when PATH is unset: the macOS and glibc default
/// (`confstr(_CS_PATH)` is `/usr/bin:/bin` on both), a literal so the lookup
/// needs no libc call.
const default_path = "/usr/bin:/bin";

/// Parent-side PATH search with `execvp` semantics, resolved before fork. A
/// name containing '/' is the only candidate. Otherwise each PATH entry gives
/// `dir/argv0`, and an empty entry means the current directory (`./argv0`).
/// An empty name has no candidates. Each string is NUL-terminated and
/// gpa-owned, as is the slice: release both with `freeExecCandidates`.
pub fn execCandidates(
    gpa: std.mem.Allocator,
    argv0: []const u8,
    path_env: ?[]const u8,
) error{OutOfMemory}![]const [*:0]const u8 {
    var list: std.ArrayList([*:0]const u8) = .empty;
    errdefer freeExecCandidates(gpa, list.items);
    if (argv0.len == 0) return try list.toOwnedSlice(gpa);
    if (std.mem.indexOfScalar(u8, argv0, '/') != null) {
        const one = try gpa.dupeZ(u8, argv0);
        errdefer gpa.free(one);
        try list.append(gpa, one.ptr);
        return try list.toOwnedSlice(gpa);
    }
    var dirs = std.mem.splitScalar(u8, path_env orelse default_path, ':');
    while (dirs.next()) |dir| {
        const path = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ if (dir.len == 0) "." else dir, argv0 }, 0);
        errdefer gpa.free(path);
        try list.append(gpa, path.ptr);
    }
    return try list.toOwnedSlice(gpa);
}

pub fn freeExecCandidates(gpa: std.mem.Allocator, candidates: []const [*:0]const u8) void {
    for (candidates) |cand| gpa.free(std.mem.span(cand));
    gpa.free(candidates);
}

pub const ChildProcess = struct {
    gpa: std.mem.Allocator,
    pid: c.pid_t,
    to_child: *c.FILE, // requests out
    from_child: *c.FILE, // replies in
    write_mutex: sync.Mutex = .{},
    read_timeout_ms: u32 = 120_000,
    read_buf: [4096]u8 = undefined,
    read_pos: usize = 0,
    read_end: usize = 0,

    /// Spawn `argv` with its stdin/stdout piped here; stderr passes through
    /// to ours (server logs stay visible). The command is looked up like
    /// `execvp` does (see `execCandidates`), but in the parent: the child only
    /// runs `execve` over the prepared candidates, because libc `execvp` is not
    /// async-signal-safe and handler threads may hold libc locks at fork time.
    /// The ENOEXEC `/bin/sh` fallback of `execvp` is not emulated: shebang
    /// scripts run through `execve`; a script with no shebang fails (exit 127).
    pub fn spawn(gpa: std.mem.Allocator, argv: []const []const u8) error{ OutOfMemory, SpawnFailed }!*ChildProcess {
        std.debug.assert(argv.len > 0);
        const argz = try gpa.alloc(?[*:0]const u8, argv.len + 1);
        defer gpa.free(argz);
        var owned: usize = 0;
        defer for (argz[0..owned]) |a| gpa.free(std.mem.span(a.?));
        for (argv, 0..) |a, i| {
            argz[i] = (try gpa.dupeZ(u8, a)).ptr;
            owned += 1;
        }
        argz[argv.len] = null;
        // Everything the child touches is built here: no unwrap, no
        // allocation after fork.
        const candidates = try execCandidates(gpa, argv[0], if (std.c.getenv("PATH")) |p| std.mem.span(p) else null);
        defer freeExecCandidates(gpa, candidates);
        const child_argv: [*:null]const ?[*:0]const u8 = @ptrCast(argz.ptr);

        // Both pipes are close-on-exec and created and forked under the
        // process-wide fork lock: our ends never leak into a bash command or
        // another server, and theirs never leak into this one.
        var in_pipe: [2]c_int = undefined; // us → child stdin
        var out_pipe: [2]c_int = undefined; // child stdout → us
        fork_guard.lock.lock();
        fork_guard.cloexecPipe(&in_pipe) catch {
            fork_guard.lock.unlock();
            return error.SpawnFailed;
        };
        fork_guard.cloexecPipe(&out_pipe) catch {
            fork_guard.lock.unlock();
            _ = close(in_pipe[0]);
            _ = close(in_pipe[1]);
            return error.SpawnFailed;
        };

        const pid = fork();
        if (pid < 0) {
            fork_guard.lock.unlock();
            _ = close(in_pipe[0]);
            _ = close(in_pipe[1]);
            _ = close(out_pipe[0]);
            _ = close(out_pipe[1]);
            return error.SpawnFailed;
        }
        if (pid == 0) {
            // Child: only async-signal-safe calls until exec, and it never
            // touches the fork lock. Stdin first: the pipes may sit on fds
            // 0-3 when we were started with stdio closed. No closes after:
            // every pipe end is close-on-exec, and closing one could close
            // the stream just installed.
            if (!fork_guard.moveFd(in_pipe[0], 0)) _exit(127);
            if (!fork_guard.moveFd(out_pipe[1], 1)) _exit(127);
            // The whole post-fork path: execve, errno read, _exit (plus
            // moveFd above: fcntl, dup2). No allocation, unwrap, formatting
            // or std.debug. Keep it that way; this list is the audit.
            // Like execvp: keep going on ENOENT, ENOTDIR and EACCES; any other
            // error stops the search. Exit 127 (not found / not runnable)
            // throughout; 126 is not used, so the parent sees one code.
            for (candidates) |cand| {
                _ = execve(cand, child_argv, environ);
                const err = c._errno().*;
                if (err != @intFromEnum(c.E.NOENT) and err != @intFromEnum(c.E.NOTDIR) and err != @intFromEnum(c.E.ACCES)) break;
            }
            _exit(127);
        }
        fork_guard.lock.unlock();
        _ = close(in_pipe[0]);
        _ = close(out_pipe[1]);

        const to_child = fdopen(in_pipe[1], "w") orelse {
            _ = close(in_pipe[1]);
            _ = close(out_pipe[0]);
            _ = kill(pid, SIGTERM);
            _ = waitpid(pid, null, 0);
            return error.SpawnFailed;
        };
        const from_child = fdopen(out_pipe[0], "r") orelse {
            _ = c.fclose(to_child);
            _ = close(out_pipe[0]);
            _ = kill(pid, SIGTERM);
            _ = waitpid(pid, null, 0);
            return error.SpawnFailed;
        };

        const self = try gpa.create(ChildProcess);
        self.* = .{ .gpa = gpa, .pid = pid, .to_child = to_child, .from_child = from_child };
        return self;
    }

    /// Close the pipes (EOF lets well-behaved servers exit), then TERM +
    /// reap — never leaves a zombie.
    pub fn stop(self: *ChildProcess) void {
        _ = c.fclose(self.to_child);
        _ = c.fclose(self.from_child);
        _ = kill(self.pid, SIGTERM);
        const deadline = monotonicMs() + 250;
        while (true) {
            const reaped = waitpid(self.pid, null, 1); // WNOHANG
            if (reaped == self.pid or (reaped < 0 and c._errno().* == @intFromEnum(c.E.CHILD))) break;
            if (monotonicMs() >= deadline) {
                _ = kill(self.pid, @intFromEnum(c.SIG.KILL));
                while (waitpid(self.pid, null, 0) < 0 and c._errno().* == @intFromEnum(c.E.INTR)) {}
                break;
            }
            var no_fds: [0]c.pollfd = .{};
            _ = c.poll(&no_fds, 0, 5);
        }
        self.write_mutex.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    pub fn transport(self: *ChildProcess) Transport {
        return .{ .ctx = self, .writeLineFn = &writeLine, .readLineFn = &readLine };
    }

    fn writeLine(ctx: *anyopaque, line: []const u8) TransportError!void {
        const self: *ChildProcess = @ptrCast(@alignCast(ctx));
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        if (c.fwrite(line.ptr, 1, line.len, self.to_child) != line.len) return error.Io;
        if (c.fwrite("\n", 1, 1, self.to_child) != 1) return error.Io;
        if (fflush(self.to_child) != 0) return error.Io;
    }

    fn readLine(ctx: *anyopaque, gpa: std.mem.Allocator) TransportError!?[]u8 {
        const self: *ChildProcess = @ptrCast(@alignCast(ctx));
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(gpa);
        const deadline = monotonicMs() + self.read_timeout_ms;
        while (true) {
            if (self.read_pos == self.read_end) {
                const left = deadline - monotonicMs();
                if (left <= 0) return error.Io;
                var fds = [_]c.pollfd{.{ .fd = fileno(self.from_child), .events = c.POLL.IN, .revents = 0 }};
                const ready = c.poll(&fds, 1, @intCast(@min(left, std.math.maxInt(c_int))));
                if (ready < 0 and c._errno().* == @intFromEnum(c.E.INTR)) continue;
                if (ready <= 0) return error.Io;
                const n = c.read(fds[0].fd, &self.read_buf, self.read_buf.len);
                if (n < 0 and c._errno().* == @intFromEnum(c.E.INTR)) continue;
                if (n < 0) return error.Io;
                if (n == 0) {
                    if (buf.items.len == 0) {
                        buf.deinit(gpa);
                        return null;
                    }
                    break;
                }
                self.read_pos = 0;
                self.read_end = @intCast(n);
            }
            const pending = self.read_buf[self.read_pos..self.read_end];
            const newline = std.mem.indexOfScalar(u8, pending, '\n');
            const take = if (newline) |i| i else pending.len;
            const part = pending[0..take];
            // JSON-RPC is text: embedded NUL must not hide bytes from the cap.
            if (std.mem.indexOfScalar(u8, part, 0) != null or part.len > max_line_bytes - buf.items.len) return error.Io;
            try buf.appendSlice(gpa, part);
            self.read_pos += take;
            if (newline != null) {
                self.read_pos += 1;
                break;
            }
        }
        return try buf.toOwnedSlice(gpa);
    }
};

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "child-process transport: line round-trip through cat, newline stripped" {
    const child = try ChildProcess.spawn(testing.allocator, &.{"cat"});
    defer child.stop();
    const t = child.transport();
    try t.writeLine("hello mcp");
    const line = (try t.readLine(testing.allocator)).?;
    defer testing.allocator.free(line);
    try testing.expectEqualStrings("hello mcp", line);
}

test "child-process transport: EOF from an exiting child reads as null" {
    const child = try ChildProcess.spawn(testing.allocator, &.{ "sh", "-c", "exit 0" });
    defer child.stop();
    const t = child.transport();
    try testing.expectEqual(@as(?[]u8, null), try t.readLine(testing.allocator));
}

test "child-process transport: a silent server reaches a read deadline" {
    const child = try ChildProcess.spawn(testing.allocator, &.{ "/bin/sh", "-c", "exec sleep 0.2" });
    defer child.stop();
    child.read_timeout_ms = 20;
    try testing.expectError(error.Io, child.transport().readLine(testing.allocator));
}

test "child-process transport: line cap refuses oversized input" {
    const command = try std.fmt.allocPrint(testing.allocator, "head -c {d} /dev/zero | tr '\\000' x", .{max_line_bytes + 1});
    defer testing.allocator.free(command);
    const child = try ChildProcess.spawn(testing.allocator, &.{ "/bin/sh", "-c", command });
    defer child.stop();
    try testing.expectError(error.Io, child.transport().readLine(testing.allocator));
}

test "child-process transport: exact-cap line and read-ahead preserve the next line" {
    const command = try std.fmt.allocPrint(testing.allocator, "head -c {d} /dev/zero | tr '\\000' x; printf '\\nnext\\n'", .{max_line_bytes});
    defer testing.allocator.free(command);
    const child = try ChildProcess.spawn(testing.allocator, &.{ "/bin/sh", "-c", command });
    defer child.stop();
    const t = child.transport();
    const first = (try t.readLine(testing.allocator)).?;
    defer testing.allocator.free(first);
    try testing.expectEqual(max_line_bytes, first.len);
    const second = (try t.readLine(testing.allocator)).?;
    defer testing.allocator.free(second);
    try testing.expectEqualStrings("next", second);
}

test "child-process transport: NUL cannot evade the line cap" {
    const child = try ChildProcess.spawn(testing.allocator, &.{ "/bin/sh", "-c", "printf '\\000hidden\\n'" });
    defer child.stop();
    try testing.expectError(error.Io, child.transport().readLine(testing.allocator));
}

test "child-process transport: parent pipe ends are close-on-exec" {
    const child = try ChildProcess.spawn(testing.allocator, &.{"cat"});
    defer child.stop();
    const want: c_int = c.FD_CLOEXEC;
    try testing.expectEqual(want, c.fcntl(fileno(child.to_child), c.F.GETFD) & want);
    try testing.expectEqual(want, c.fcntl(fileno(child.from_child), c.F.GETFD) & want);
}

fn stdinOnFdZeroBody() bool {
    const gpa = std.heap.page_allocator;
    const child = ChildProcess.spawn(gpa, &.{"cat"}) catch return false;
    child.read_timeout_ms = 3000;
    const t = child.transport();
    defer child.stop();
    t.writeLine("ping") catch return false;
    const line = (t.readLine(gpa) catch return false) orelse return false;
    defer gpa.free(line);
    return std.mem.eql(u8, line, "ping");
}

test "child-process transport: stdin pipe landing on fd 0 survives into the child" {
    try testing.expect(fork_guard.runInChildWithClosed(&.{ 0, 1 }, &stdinOnFdZeroBody));
}

fn expectCandidates(argv0: []const u8, path_env: ?[]const u8, want: []const []const u8) !void {
    const got = try execCandidates(testing.allocator, argv0, path_env);
    defer freeExecCandidates(testing.allocator, got);
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, std.mem.span(g));
}

test "execCandidates: a name with a slash is the only candidate, PATH ignored" {
    try expectCandidates("/usr/bin/env", "/a:/b", &.{"/usr/bin/env"});
    try expectCandidates("./tools/srv", "/a:/b", &.{"./tools/srv"});
    try expectCandidates("sub/srv", null, &.{"sub/srv"});
}

test "execCandidates: a bare name tries each PATH entry in order" {
    try expectCandidates("npx", "/opt/bin:/usr/bin:/bin", &.{ "/opt/bin/npx", "/usr/bin/npx", "/bin/npx" });
}

test "execCandidates: an empty PATH entry means the current directory" {
    try expectCandidates("uvx", ":/usr/bin", &.{ "./uvx", "/usr/bin/uvx" });
    try expectCandidates("uvx", "/usr/bin::/bin", &.{ "/usr/bin/uvx", "./uvx", "/bin/uvx" });
    try expectCandidates("uvx", "/usr/bin:", &.{ "/usr/bin/uvx", "./uvx" });
    try expectCandidates("uvx", "", &.{"./uvx"});
}

test "execCandidates: unset PATH falls back to the default search path" {
    try expectCandidates("cat", null, &.{ "/usr/bin/cat", "/bin/cat" });
}

test "execCandidates: an empty name has no candidate" {
    try expectCandidates("", "/usr/bin", &.{});
}

test "child-process transport: a bare name resolves through PATH, a missing one exits 127" {
    const child = try ChildProcess.spawn(testing.allocator, &.{ "cat", "-u" });
    defer child.stop();
    const t = child.transport();
    try t.writeLine("via path");
    const line = (try t.readLine(testing.allocator)).?;
    defer testing.allocator.free(line);
    try testing.expectEqualStrings("via path", line);

    const missing = try ChildProcess.spawn(testing.allocator, &.{"zygos-no-such-mcp-server"});
    defer missing.stop();
    try testing.expectEqual(@as(?[]u8, null), try missing.transport().readLine(testing.allocator));
}
