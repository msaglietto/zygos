//! Session dedup cache (S8.4, docs/specs/filter.md; decision Z-09).
//!
//! An agent re-runs `git status` and `zig build test` constantly. When
//! nothing changed, the second and third full outputs are pure waste — the
//! model already has that information in its transcript. This replaces the
//! repeat with one honest line.
//!
//! Correctness over hit rate: any mutating command clears everything. A
//! stale "unchanged" claim is a lie the agent would act on, which is far
//! worse than a cache miss.

const std = @import("std");
const dispatch = @import("dispatch.zig");

const capacity: usize = 64;

const Entry = struct {
    key: u64, // hash(tool ++ command)
    output: u64, // hash(raw output)
    stamp_ms: i64,
    ttl_ms: i64,
    used_at: u64, // LRU tick
};

pub const Cache = struct {
    entries: [capacity]Entry = undefined,
    len: usize = 0,
    tick: u64 = 0,

    pub fn reset(self: *Cache) void {
        self.len = 0;
    }

    /// Returns the age of the previous identical result when this exact
    /// command produced this exact output within its TTL — i.e. the caller
    /// may answer with the short form, and can say how old it is. Null means
    /// "not a repeat"; the observation is recorded either way.
    ///
    /// `now_ms` is injected rather than read from the clock so the TTL rules
    /// are testable without sleeping.
    pub fn seenUnchanged(
        self: *Cache,
        tool: []const u8,
        command: ?[]const u8,
        output: []const u8,
        family: dispatch.Family,
        now_ms: i64,
    ) ?i64 {
        if (dispatch.isMutating(tool, command)) {
            self.reset();
            return null;
        }
        const key = hashKey(tool, command);
        const out_hash = std.hash.Wyhash.hash(0, output);
        const ttl = family.ttlMs();
        self.tick += 1;

        for (self.entries[0..self.len]) |*e| {
            if (e.key != key) continue;
            const age = now_ms - e.stamp_ms;
            const fresh = age <= e.ttl_ms;
            const same = e.output == out_hash;
            e.output = out_hash;
            e.stamp_ms = now_ms;
            e.ttl_ms = ttl;
            e.used_at = self.tick;
            return if (fresh and same) age else null;
        }

        const slot = if (self.len < capacity) blk: {
            self.len += 1;
            break :blk &self.entries[self.len - 1];
        } else self.lruSlot();
        slot.* = .{
            .key = key,
            .output = out_hash,
            .stamp_ms = now_ms,
            .ttl_ms = ttl,
            .used_at = self.tick,
        };
        return null;
    }

    fn lruSlot(self: *Cache) *Entry {
        var oldest: *Entry = &self.entries[0];
        for (self.entries[0..self.len]) |*e| {
            if (e.used_at < oldest.used_at) oldest = e;
        }
        return oldest;
    }
};

fn hashKey(tool: []const u8, command: ?[]const u8) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(tool);
    h.update("\x00");
    if (command) |c| h.update(c);
    return h.final();
}

/// The short form an unchanged repeat collapses to.
pub fn unchangedMarker(arena: std.mem.Allocator, age_ms: i64) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "[... zygos: output unchanged since {d}s ago; see the earlier result ...]\n",
        .{@divTrunc(age_ms, 1000)},
    );
}

// ===========================================================================
// Tests (docs/specs/filter.md S8.4 contract)
// ===========================================================================

const testing = std.testing;

test "S8.4: identical repeat within TTL reports unchanged" {
    var c: Cache = .{};
    const out = "On branch master\nnothing to report\n";
    try testing.expect(null == c.seenUnchanged("bash", "git status", out, .git_status, 1000));
    try testing.expect(null != c.seenUnchanged("bash", "git status", out, .git_status, 5000));
    try testing.expect(null != c.seenUnchanged("bash", "git status", out, .git_status, 20000));
}

test "S8.4: changed output is never reported unchanged" {
    var c: Cache = .{};
    try testing.expect(null == c.seenUnchanged("bash", "git status", "clean", .git_status, 1000));
    try testing.expect(null == c.seenUnchanged("bash", "git status", "dirty", .git_status, 2000));
    // The new output is what is now remembered.
    try testing.expect(null != c.seenUnchanged("bash", "git status", "dirty", .git_status, 3000));
}

test "S8.4: an expired entry is a miss even when the output matches" {
    var c: Cache = .{};
    const out = "same output every time";
    try testing.expect(null == c.seenUnchanged("bash", "git status", out, .git_status, 0));
    // git_status TTL is 30s.
    try testing.expect(null != c.seenUnchanged("bash", "git status", out, .git_status, 29_000));
    try testing.expect(null == c.seenUnchanged("bash", "git status", out, .git_status, 90_000));
}

test "S8.4: TTL is per family" {
    var c: Cache = .{};
    const out = "unchanged";
    // testrun TTL is 120s, so 60s later is still fresh.
    try testing.expect(null == c.seenUnchanged("bash", "zig build test", out, .testrun, 0));
    try testing.expect(null != c.seenUnchanged("bash", "zig build test", out, .testrun, 60_000));
    // The same gap would have expired a listing (30s).
    try testing.expect(null == c.seenUnchanged("bash", "ls -la", out, .listing, 0));
    try testing.expect(null == c.seenUnchanged("bash", "ls -la", out, .listing, 60_000));
}

test "S8.4: different commands do not collide" {
    var c: Cache = .{};
    const out = "identical bytes";
    try testing.expect(null == c.seenUnchanged("bash", "git status", out, .git_status, 0));
    try testing.expect(null == c.seenUnchanged("bash", "ls -la", out, .listing, 0));
    try testing.expect(null != c.seenUnchanged("bash", "git status", out, .git_status, 1000));
}

test "S8.4: a mutating command invalidates everything" {
    var c: Cache = .{};
    const out = "On branch master";
    try testing.expect(null == c.seenUnchanged("bash", "git status", out, .git_status, 0));
    try testing.expect(null != c.seenUnchanged("bash", "git status", out, .git_status, 1000));

    // `git add` clears the cache; the next status is a miss even though the
    // bytes happen to match.
    try testing.expect(null == c.seenUnchanged("bash", "git add -A", "", .git_status, 1500));
    try testing.expect(null == c.seenUnchanged("bash", "git status", out, .git_status, 2000));
}

test "S8.4: bounded at 64 entries with LRU eviction" {
    var c: Cache = .{};
    var buf: [64]u8 = undefined;
    for (0..capacity) |i| {
        const cmd = try std.fmt.bufPrint(&buf, "ls dir_{d}", .{i});
        _ = c.seenUnchanged("bash", cmd, "same", .listing, 0);
    }
    try testing.expectEqual(capacity, c.len);

    // Keep entry 0 hot, then overflow — entry 1 (coldest) must be the victim.
    _ = c.seenUnchanged("bash", "ls dir_0", "same", .listing, 100);
    _ = c.seenUnchanged("bash", "ls overflow", "same", .listing, 200);
    try testing.expectEqual(capacity, c.len);
    try testing.expect(null != c.seenUnchanged("bash", "ls dir_0", "same", .listing, 300));
    try testing.expect(null == c.seenUnchanged("bash", "ls dir_1", "same", .listing, 400));
}

test "S8.4: marker reports age in seconds" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const m = try unchangedMarker(arena_state.allocator(), 12_400);
    try testing.expect(std.mem.indexOf(u8, m, "unchanged since 12s ago") != null);
}

// --- Reality checks: the cache is the one feature that can actively lie ---

test "S8.4: a mutation via any recognized command clears the cache" {
    // Every mutating verb must invalidate. A stale 'unchanged' reply after a
    // real edit would send the agent down a false path.
    const mutations = [_][]const u8{
        "git add -A",         "git commit -m x",   "git checkout main",
        "git switch feature", "git merge main",    "git rebase main",
        "git reset --hard",   "git stash",         "git pull",
        "git apply p.patch",  "git restore f.zig", "git rm f.zig",
        "git mv a b",         "rm -rf build",      "mv a b",
        "cp a b",             "touch f",           "mkdir d",
    };
    for (mutations) |m| {
        var c: Cache = .{};
        const out = "On branch master";
        try testing.expect(null == c.seenUnchanged("bash", "git status", out, .git_status, 0));
        try testing.expect(null != c.seenUnchanged("bash", "git status", out, .git_status, 100));
        _ = c.seenUnchanged("bash", m, "", .git_status, 200);
        // After the mutation the identical output must NOT be called unchanged.
        try testing.expect(null == c.seenUnchanged("bash", "git status", out, .git_status, 300));
    }
}

test "S8.4: a one-byte difference is never reported as unchanged" {
    var c: Cache = .{};
    const a = "On branch master\n  modified:   a.zig\n";
    const b = "On branch master\n  modified:   b.zig\n";
    try testing.expect(null == c.seenUnchanged("bash", "git status", a, .git_status, 0));
    try testing.expect(null == c.seenUnchanged("bash", "git status", b, .git_status, 100));
}

test "S8.4: write_file invalidates even without a command string" {
    var c: Cache = .{};
    const out = "On branch master";
    try testing.expect(null == c.seenUnchanged("bash", "git status", out, .git_status, 0));
    try testing.expect(null != c.seenUnchanged("bash", "git status", out, .git_status, 100));
    _ = c.seenUnchanged("write_file", null, "", .git_status, 200);
    try testing.expect(null == c.seenUnchanged("bash", "git status", out, .git_status, 300));
}
