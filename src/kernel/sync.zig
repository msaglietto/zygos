//! Blocking synchronization primitives over POSIX pthread (via std.c).
//!
//! Zig 0.16 removed std.Thread.{Mutex,Condition,ResetEvent}; the replacements
//! live in std.Io and require threading an `Io` instance through every lock —
//! machinery decision Z-02 keeps out of the kernel (actor + plain OS threads).
//! These wrappers restore the classic blocking API the architecture assumes
//! ("mutex + condvar ring buffers", ARCHITECTURE.md). macOS + Linux only,
//! matching GOAL.md's no-Windows-in-v1 non-goal; requires libc (build.zig
//! links it).
//!
//! Nonzero pthread return codes indicate programmer error (EINVAL, EDEADLK)
//! for this usage — asserted, not surfaced.

const std = @import("std");
const c = std.c;

fn check(rc: c.E) void {
    std.debug.assert(rc == .SUCCESS);
}

pub const Mutex = struct {
    inner: c.pthread_mutex_t = .{},

    pub fn lock(self: *Mutex) void {
        check(c.pthread_mutex_lock(&self.inner));
    }

    pub fn unlock(self: *Mutex) void {
        check(c.pthread_mutex_unlock(&self.inner));
    }

    pub fn deinit(self: *Mutex) void {
        check(c.pthread_mutex_destroy(&self.inner));
        self.* = undefined;
    }
};

pub const Condition = struct {
    inner: c.pthread_cond_t = .{},

    /// Caller must hold `mutex`. Spurious wakeups possible — always wait in a
    /// predicate loop.
    pub fn wait(self: *Condition, mutex: *Mutex) void {
        check(c.pthread_cond_wait(&self.inner, &mutex.inner));
    }

    pub fn signal(self: *Condition) void {
        check(c.pthread_cond_signal(&self.inner));
    }

    pub fn broadcast(self: *Condition) void {
        check(c.pthread_cond_broadcast(&self.inner));
    }

    pub fn deinit(self: *Condition) void {
        check(c.pthread_cond_destroy(&self.inner));
        self.* = undefined;
    }
};

/// One-shot (resettable) event. Handoff rule for cross-thread results
/// (docs/specs/invocation.md): the completing side writes the result slot,
/// then calls `set()`; the waiting side reads only after `wait()` returns —
/// the mutex inside makes the write visible.
pub const ResetEvent = struct {
    mutex: Mutex = .{},
    cond: Condition = .{},
    is_set: bool = false,

    pub fn set(self: *ResetEvent) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.is_set = true;
        self.cond.broadcast();
    }

    pub fn wait(self: *ResetEvent) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (!self.is_set) self.cond.wait(&self.mutex);
    }

    pub fn isSet(self: *ResetEvent) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.is_set;
    }

    pub fn reset(self: *ResetEvent) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.is_set = false;
    }

    pub fn deinit(self: *ResetEvent) void {
        self.cond.deinit();
        self.mutex.deinit();
        self.* = undefined;
    }
};

// ===========================================================================
// Tests — no sleep-based synchronization anywhere; joins bound every wait.
// ===========================================================================

const testing = std.testing;

test "mutex serializes critical sections across threads" {
    const Shared = struct {
        mutex: Mutex = .{},
        counter: usize = 0,

        fn worker(self: *@This()) void {
            var i: usize = 0;
            while (i < 10_000) : (i += 1) {
                self.mutex.lock();
                self.counter += 1;
                self.mutex.unlock();
            }
        }
    };
    var shared: Shared = .{};
    defer shared.mutex.deinit();

    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Shared.worker, .{&shared});
    for (threads) |t| t.join();

    try testing.expectEqual(@as(usize, 40_000), shared.counter);
}

test "reset event: set before wait returns immediately" {
    var ev: ResetEvent = .{};
    defer ev.deinit();
    ev.set();
    ev.wait(); // must not block
    try testing.expect(ev.isSet());
}

test "reset event: waiter blocks until another thread sets" {
    const Ctx = struct {
        ev: ResetEvent = .{},
        observed: bool = false,

        fn waiter(self: *@This()) void {
            self.ev.wait();
            // Handoff rule: reads after wait() see writes made before set().
            self.observed = true;
        }
    };
    var ctx: Ctx = .{};
    defer ctx.ev.deinit();

    const t = try std.Thread.spawn(.{}, Ctx.waiter, .{&ctx});
    ctx.ev.set();
    t.join();
    try testing.expect(ctx.observed);
}

test "reset event: reset makes the next wait block again until set" {
    var ev: ResetEvent = .{};
    defer ev.deinit();
    ev.set();
    ev.reset();
    try testing.expect(!ev.isSet());

    const Setter = struct {
        fn run(e: *ResetEvent) void {
            e.set();
        }
    };
    const t = try std.Thread.spawn(.{}, Setter.run, .{&ev});
    ev.wait();
    t.join();
    try testing.expect(ev.isSet());
}

test "condition: signal wakes a predicate waiter" {
    const Ctx = struct {
        mutex: Mutex = .{},
        cond: Condition = .{},
        ready: bool = false,

        fn producer(self: *@This()) void {
            self.mutex.lock();
            self.ready = true;
            self.cond.signal();
            self.mutex.unlock();
        }
    };
    var ctx: Ctx = .{};
    defer {
        ctx.cond.deinit();
        ctx.mutex.deinit();
    }

    const t = try std.Thread.spawn(.{}, Ctx.producer, .{&ctx});
    ctx.mutex.lock();
    while (!ctx.ready) ctx.cond.wait(&ctx.mutex);
    ctx.mutex.unlock();
    t.join();
    try testing.expect(ctx.ready);
}

test "condition: broadcast wakes all waiters" {
    const Ctx = struct {
        mutex: Mutex = .{},
        cond: Condition = .{},
        released: bool = false,
        woke: usize = 0,

        fn waiter(self: *@This()) void {
            self.mutex.lock();
            while (!self.released) self.cond.wait(&self.mutex);
            self.woke += 1;
            self.mutex.unlock();
        }
    };
    var ctx: Ctx = .{};
    defer {
        ctx.cond.deinit();
        ctx.mutex.deinit();
    }

    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Ctx.waiter, .{&ctx});

    ctx.mutex.lock();
    ctx.released = true;
    ctx.cond.broadcast();
    ctx.mutex.unlock();

    for (threads) |t| t.join();
    try testing.expectEqual(@as(usize, 4), ctx.woke);
}
