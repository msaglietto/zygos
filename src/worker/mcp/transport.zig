//! Line-oriented transports for MCP clients: the Transport vtable the
//! JSON-RPC client talks through, and the child-process implementation
//! (fork/exec + pipes; libc like tools_ops' popen). Protocol logic lives in
//! client.zig — this file never parses JSON.

const std = @import("std");
const c = std.c;
const sync = @import("../../kernel/sync.zig");

pub const TransportError = error{ Io, OutOfMemory };

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
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn dup2(old_fd: c_int, new_fd: c_int) c_int;
extern "c" fn pipe(fds: *[2]c_int) c_int;
extern "c" fn waitpid(pid: c.pid_t, status: ?*c_int, options: c_int) c.pid_t;
extern "c" fn kill(pid: c.pid_t, sig: c_int) c_int;
extern "c" fn fdopen(fd: c_int, mode: [*:0]const u8) ?*c.FILE;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn _exit(status: c_int) noreturn;
extern "c" fn fflush(stream: *c.FILE) c_int;
extern "c" fn fgets(buf: [*]u8, size: c_int, stream: *c.FILE) ?[*:0]u8;

const SIGTERM: c_int = @intFromEnum(c.SIG.TERM);

pub const ChildProcess = struct {
    gpa: std.mem.Allocator,
    pid: c.pid_t,
    to_child: *c.FILE, // requests out
    from_child: *c.FILE, // replies in
    write_mutex: sync.Mutex = .{},

    /// Spawn `argv` with its stdin/stdout piped here; stderr passes through
    /// to ours (server logs stay visible).
    pub fn spawn(gpa: std.mem.Allocator, argv: []const []const u8) error{ OutOfMemory, SpawnFailed }!*ChildProcess {
        std.debug.assert(argv.len > 0);
        var in_pipe: [2]c_int = undefined; // us → child stdin
        var out_pipe: [2]c_int = undefined; // child stdout → us
        if (pipe(&in_pipe) != 0) return error.SpawnFailed;
        if (pipe(&out_pipe) != 0) {
            _ = close(in_pipe[0]);
            _ = close(in_pipe[1]);
            return error.SpawnFailed;
        }

        const argz = try gpa.alloc(?[*:0]const u8, argv.len + 1);
        defer gpa.free(argz);
        var owned: usize = 0;
        defer for (argz[0..owned]) |a| gpa.free(std.mem.span(a.?));
        for (argv, 0..) |a, i| {
            argz[i] = (try gpa.dupeZ(u8, a)).ptr;
            owned += 1;
        }
        argz[argv.len] = null;

        const pid = fork();
        if (pid < 0) {
            _ = close(in_pipe[0]);
            _ = close(in_pipe[1]);
            _ = close(out_pipe[0]);
            _ = close(out_pipe[1]);
            return error.SpawnFailed;
        }
        if (pid == 0) {
            // Child: only async-signal-safe calls until exec.
            _ = dup2(in_pipe[0], 0);
            _ = dup2(out_pipe[1], 1);
            _ = close(in_pipe[0]);
            _ = close(in_pipe[1]);
            _ = close(out_pipe[0]);
            _ = close(out_pipe[1]);
            _ = execvp(argz[0].?, @ptrCast(argz.ptr));
            _exit(127);
        }
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
        _ = waitpid(self.pid, null, 0);
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
        var chunk: [1024]u8 = undefined;
        while (true) {
            if (fgets(&chunk, chunk.len, self.from_child) == null) {
                if (buf.items.len == 0) {
                    buf.deinit(gpa);
                    return null; // clean EOF
                }
                break; // EOF mid-line: hand over what we have
            }
            const got = std.mem.sliceTo(&chunk, 0);
            try buf.appendSlice(gpa, got);
            if (got.len > 0 and got[got.len - 1] == '\n') {
                _ = buf.pop();
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
