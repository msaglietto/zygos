//! Fork-site support shared by every code path that forks and execs
//! (`tools_ops.bash`, `mcp/transport.ChildProcess.spawn`).
//!
//! A forked child inherits every open descriptor. Handlers run on detached
//! threads, so one call's fork can land between another call's `pipe()` and
//! its parent-side `close()` and leave that pipe's write end open in an
//! unrelated child; the reader then waits for EOF until that child exits.
//! Pipes are therefore close-on-exec, created and forked under `lock`.

const std = @import("std");
const c = std.c;
const sync = @import("../kernel/sync.zig");

extern "c" fn fork() c.pid_t;
extern "c" fn pipe(fds: *[2]c.fd_t) c_int;
extern "c" fn dup2(old: c.fd_t, new: c.fd_t) c_int;
extern "c" fn close(fd: c.fd_t) c_int;
extern "c" fn waitpid(pid: c.pid_t, status: *c_int, options: c_int) c.pid_t;
extern "c" fn _exit(code: c_int) noreturn;

const fd_cloexec: c_int = c.FD_CLOEXEC;

fn monotonicMs() i64 {
    var ts: c.timespec = undefined;
    if (c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

/// Process-wide. Held from pipe creation through `fork()` by every fork site
/// in the process, and released by the parent right after fork returns. macOS
/// has no `pipe2`, so "create a pipe" and "mark it FD_CLOEXEC" are two steps;
/// a fork elsewhere in that window would inherit the still-inheritable ends.
/// Every code path that forks must take this lock around its pipe creation
/// and its fork. The child never touches it.
pub var lock: sync.Mutex = .{};

/// `pipe()` with FD_CLOEXEC set on both ends. On failure nothing is left open.
/// Caller holds `lock`.
pub fn cloexecPipe(fds: *[2]c.fd_t) error{PipeFailed}!void {
    if (pipe(fds) != 0) return error.PipeFailed;
    for (fds) |fd| {
        if (c.fcntl(fd, c.F.SETFD, fd_cloexec) != 0) {
            _ = close(fds[0]);
            _ = close(fds[1]);
            return error.PipeFailed;
        }
    }
}

/// Child side, between fork and exec; async-signal-safe (fcntl, dup2 only).
/// Makes `target` a copy of `src` that survives exec. `dup2(fd, fd)` is a
/// no-op that would leave FD_CLOEXEC set, so that case clears the flag
/// instead. Closes nothing: the original `src` stays close-on-exec and goes
/// away at exec, unless `src == target`, where it is the new descriptor.
pub fn moveFd(src: c.fd_t, target: c.fd_t) bool {
    if (src == target) return c.fcntl(src, c.F.SETFD, @as(c_int, 0)) == 0;
    return dup2(src, target) >= 0;
}

/// Test support. Fork a child that closes `closed`, runs `body`, and exits 0
/// if it returned true, 1 otherwise; the child never returns into the test
/// runner. The parent waits at most 5 s (SIGKILL and reap on timeout) and
/// returns true only for exit status 0. Under `zig build test` fd 1 is the
/// runner's protocol pipe, so fds 0-2 are only ever closed inside a child.
/// Bodies allocate from `std.heap.page_allocator`, never `testing.allocator`.
/// The fork happens under `lock`, and parent, child and the failure path all
/// unlock it afterwards (the pthread_atfork pattern): the child is the forking
/// thread's copy and owns the locked mutex, so it unlocks its copy, because
/// `body` may reach a fork site that takes it.
pub fn runInChildWithClosed(closed: []const c.fd_t, body: *const fn () bool) bool {
    lock.lock();
    const pid = fork();
    lock.unlock();
    if (pid < 0) return false;
    if (pid == 0) {
        for (closed) |fd| _ = close(fd);
        _exit(if (body()) 0 else 1);
    }
    const deadline = monotonicMs() + 5000;
    var status: c_int = 0;
    while (true) {
        const got = waitpid(pid, &status, 1); // WNOHANG
        if (got == pid) break;
        const failed = got < 0 and c._errno().* != @intFromEnum(c.E.INTR);
        if (failed or monotonicMs() >= deadline) {
            _ = c.kill(pid, c.SIG.KILL);
            while (waitpid(pid, &status, 0) < 0 and c._errno().* == @intFromEnum(c.E.INTR)) {}
            return false;
        }
        var no_fds: [0]c.pollfd = .{};
        _ = c.poll(&no_fds, 0, 5);
    }
    return (status & 0x7f) == 0 and ((status >> 8) & 0xff) == 0;
}

// ===========================================================================
// Tests (descriptors >= 3 only: fds 0-2 belong to the test runner)
// ===========================================================================

const testing = std.testing;

fn hasCloexec(fd: c.fd_t) bool {
    return (c.fcntl(fd, c.F.GETFD) & fd_cloexec) != 0;
}

test "cloexecPipe: both ends are close-on-exec" {
    lock.lock();
    defer lock.unlock();
    var fds: [2]c.fd_t = undefined;
    try cloexecPipe(&fds);
    defer _ = close(fds[0]);
    defer _ = close(fds[1]);
    try testing.expect(fds[0] > 2 and fds[1] > 2);
    try testing.expect(hasCloexec(fds[0]));
    try testing.expect(hasCloexec(fds[1]));
}

test "moveFd: src == target clears close-on-exec; src != target installs a descriptor without it" {
    lock.lock();
    defer lock.unlock();
    var fds: [2]c.fd_t = undefined;
    try cloexecPipe(&fds);
    defer _ = close(fds[0]);
    defer _ = close(fds[1]);

    try testing.expect(hasCloexec(fds[0]));
    try testing.expect(moveFd(fds[0], fds[0]));
    try testing.expect(!hasCloexec(fds[0]));

    // fds[0] is now inheritable; copy the still-CLOEXEC fds[1] onto a spare slot.
    const spare = c.dup(fds[0]);
    try testing.expect(spare > 2);
    defer _ = close(spare);
    try testing.expect(moveFd(fds[1], spare));
    try testing.expect(!hasCloexec(spare));
    try testing.expect(hasCloexec(fds[1]));
}
