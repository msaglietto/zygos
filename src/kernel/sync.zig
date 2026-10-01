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

    /// Caller must hold `mutex`. Returns false on timeout, true on wake
    /// (spurious wakeups possible — always re-check the predicate).
    pub fn timedWait(self: *Condition, mutex: *Mutex, abstime: *const c.timespec) bool {
        const rc = c.pthread_cond_timedwait(&self.inner, &mutex.inner, abstime);
        if (rc == .TIMEDOUT) return false;
        check(rc);
        return true;
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

    /// Wait at most `timeout_ms`; true iff the event was set in time.
    /// REALTIME-based (matches pthread_cond_timedwait's default clock) —
    /// wall-clock jumps can stretch or shrink the wait; acceptable for the
    /// human-scale timeouts (approvals) this serves.
    pub fn timedWait(self: *ResetEvent, timeout_ms: u64) bool {
        var ts: c.timespec = undefined;
        _ = c.clock_gettime(.REALTIME, &ts);
        const ns = @as(u64, @intCast(ts.nsec)) + (timeout_ms % 1000) * std.time.ns_per_ms;
        ts.sec += @intCast(timeout_ms / 1000 + ns / std.time.ns_per_s);
        ts.nsec = @intCast(ns % std.time.ns_per_s);

        self.mutex.lock();
        defer self.mutex.unlock();
        while (!self.is_set) {
            if (!self.cond.timedWait(&self.mutex, &ts)) break;
        }
        return self.is_set;
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

/// Lifetime gate for pointers handed out under a foreign lock (an outbound
/// frame target, a registry entry): acquirers hold a counted reference;
/// `retire()` closes the gate to new acquirers and blocks until every
/// in-flight holder has released. The owner may free the guarded object only
/// after `retire()` returns — the release side needs no lock of its own.
pub const RetireGate = struct {
    mutex: Mutex = .{},
    done: Condition = .{},
    count: usize = 0,
    retired: bool = false,

    /// True = counted hold (pair with `release`). False = gate is retired;
    /// the caller must not touch the guarded object.
    pub fn acquire(self: *RetireGate) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.retired) return false;
        self.count += 1;
        return true;
    }

    pub fn release(self: *RetireGate) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.count -= 1;
        if (self.retired and self.count == 0) self.done.broadcast();
    }

    /// Close the gate and wait for all in-flight holders to release.
    pub fn retire(self: *RetireGate) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.retired = true;
        while (self.count > 0) self.done.wait(&self.mutex);
    }

    pub fn deinit(self: *RetireGate) void {
        self.done.deinit();
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

test "reset event: timedWait returns false on timeout, true when set" {
    var ev: ResetEvent = .{};
    defer ev.deinit();

    // Never set: must time out and report false.
    try testing.expect(!ev.timedWait(10));

    // Set before the deadline (from another thread): reports true.
    const Setter = struct {
        fn run(e: *ResetEvent) void {
            e.set();
        }
    };
    const t = try std.Thread.spawn(.{}, Setter.run, .{&ev});
    try testing.expect(ev.timedWait(60_000)); // bounded by the join below
    t.join();

    // Already-set event returns true immediately.
    try testing.expect(ev.timedWait(0));
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

test "retire gate: acquire succeeds until retire, fails after" {
    var gate: RetireGate = .{};
    defer gate.deinit();

    try testing.expect(gate.acquire());
    gate.release();
    gate.retire();
    try testing.expect(!gate.acquire());
}

test "retire gate: retire returns only via the holder's release, and the gate is closed after" {
    var gate: RetireGate = .{};
    defer gate.deinit();

    try testing.expect(gate.acquire()); // in-flight holder, held by this thread

    const Ctx = struct {
        gate: *RetireGate,
        done: ResetEvent = .{},

        fn retirer(self: *@This()) void {
            self.gate.retire();
            self.done.set();
        }
    };
    var ctx: Ctx = .{ .gate = &gate };
    defer ctx.done.deinit();

    const t = try std.Thread.spawn(.{}, Ctx.retirer, .{&ctx});
    gate.release(); // last holder → retire unblocks, done sets
    ctx.done.wait(); // bounded by the release; join below bounds the thread
    t.join();
    try testing.expect(ctx.done.isSet());
    // After retire has run, the gate is closed to new holders.
    try testing.expect(!gate.acquire());
}

test "retire gate: retire waits for every holder (two acquires, two releases)" {
    const Ctx = struct {
        gate: RetireGate = .{},
        mutex: Mutex = .{},
        cond: Condition = .{},
        holder_ready: bool = false,
        release_now: bool = false,
        holder_acquired: bool = false,

        fn holder(self: *@This()) void {
            if (self.gate.acquire()) self.holder_acquired = true;
            self.mutex.lock();
            self.holder_ready = true;
            self.cond.signal();
            while (!self.release_now) self.cond.wait(&self.mutex);
            self.mutex.unlock();
            self.gate.release();
        }

        fn releaser(self: *@This()) void {
            // Holder may or may not be waiting yet: broadcast covers both.
            self.mutex.lock();
            self.release_now = true;
            self.cond.broadcast();
            self.mutex.unlock();
        }
    };
    var ctx: Ctx = .{};
    defer {
        ctx.cond.deinit();
        ctx.mutex.deinit();
        ctx.gate.deinit();
    }

    try testing.expect(ctx.gate.acquire()); // first holder: this thread
    const holder = try std.Thread.spawn(.{}, Ctx.holder, .{&ctx}); // second holder
    ctx.mutex.lock();
    while (!ctx.holder_ready) ctx.cond.wait(&ctx.mutex);
    ctx.mutex.unlock();
    try testing.expect(ctx.holder_acquired);

    const releaser = try std.Thread.spawn(.{}, Ctx.releaser, .{&ctx});
    ctx.gate.release(); // this thread's hold
    ctx.gate.retire(); // returns only once the holder thread released too
    holder.join();
    releaser.join();
    try testing.expect(!ctx.gate.acquire());
}
