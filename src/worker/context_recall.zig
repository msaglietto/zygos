//! RecallStrategy (M5): high-recall / low-depth context for the radar
//! workload. A rolling source index over absorbed role outcomes and prior
//! briefs (`memory/*.jsonl`-compatible lines), lexically scored against the
//! step's query, per-source freshness TTL, dedup by id (last wins), and many
//! small ranked excerpts packed to the budget — never whole documents.
//!
//! Composition: the substrate base (objective/plan/task framing) stays the
//! prompt spine; ranked excerpts append under it within the remaining
//! budget. Compaction lands INSIDE the strategy (summarize-and-pin): when
//! the index outgrows `max_sources`, the dropped tail merges into one pinned
//! digest entry — raw role output stays on disk in the planning artifacts
//! and trace. Persistence is one JSONL file (`sources.jsonl`) via libc IO
//! (Z-02: no std.Io in workers); malformed lines are skipped, not fatal.

const std = @import("std");
const jsonx = @import("jsonx.zig");
const json = std.json;
const context = @import("context.zig");
const substrate_mod = @import("context_substrate.zig");

pub const Options = struct {
    ttl_ms: i64 = 7 * 24 * 3600 * 1000,
    per_source_bytes: usize = 1024,
    max_sources: usize = 256,
    /// Injected clock for tests; wall clock in production.
    now_fn: *const fn () i64 = &wallNow,
};

pub const Source = struct {
    id: []const u8,
    title: []const u8,
    text: []const u8,
    stamp_ms: i64,
    pinned: bool = false,
};

// ---------------------------------------------------------------------------
// Pure index
// ---------------------------------------------------------------------------

pub const Index = struct {
    gpa: std.mem.Allocator,
    entries: std.ArrayList(Source) = .empty,

    pub fn init(gpa: std.mem.Allocator) Index {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Index) void {
        for (self.entries.items) |s| freeSource(self.gpa, s);
        self.entries.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn len(self: *const Index) usize {
        return self.entries.items.len;
    }

    /// Dedup by id, last wins (the newer capture replaces the older one,
    /// keeping its slot so ordering stays stable).
    pub fn add(self: *Index, s: Source) error{OutOfMemory}!void {
        const copy = try dupeSource(self.gpa, s);
        errdefer freeSource(self.gpa, copy);
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.id, s.id)) {
                freeSource(self.gpa, e.*);
                e.* = copy;
                return;
            }
        }
        try self.entries.append(self.gpa, copy);
    }

    /// Merge everything past the freshest `max` non-pinned entries into one
    /// pinned digest entry (titles only) — summarize-and-pin.
    pub fn compact(self: *Index, max: usize) error{OutOfMemory}!void {
        var non_pinned: usize = 0;
        for (self.entries.items) |s| {
            if (!s.pinned) non_pinned += 1;
        }
        if (non_pinned <= max) return;

        // Freshest `max` non-pinned entries survive verbatim; the rest merge
        // into one pinned digest (titles only — the raw output is still on
        // disk in the planning artifacts and trace).
        const ByStamp = struct { idx: usize, stamp: i64 };
        var order: std.ArrayList(ByStamp) = .empty;
        defer order.deinit(self.gpa);
        for (self.entries.items, 0..) |s, i| {
            if (!s.pinned) try order.append(self.gpa, .{ .idx = i, .stamp = s.stamp_ms });
        }
        std.sort.pdq(ByStamp, order.items, {}, struct {
            fn lt(_: void, a: ByStamp, b: ByStamp) bool {
                if (a.stamp != b.stamp) return a.stamp > b.stamp;
                return a.idx < b.idx;
            }
        }.lt);

        var keep = std.AutoHashMap(usize, void).init(self.gpa);
        defer keep.deinit();
        for (order.items[0..max]) |o| try keep.put(o.idx, {});

        var digest: std.ArrayList(u8) = .empty;
        defer digest.deinit(self.gpa);
        var digest_stamp: i64 = 0;
        var kept: std.ArrayList(Source) = .empty;
        defer kept.deinit(self.gpa);
        var old_digest_text: ?[]u8 = null;
        defer if (old_digest_text) |t| self.gpa.free(t);

        for (self.entries.items, 0..) |s, i| {
            if (s.pinned and std.mem.eql(u8, s.id, digest_id)) {
                // An earlier digest folds into the new one.
                old_digest_text = try self.gpa.dupe(u8, s.text);
                digest_stamp = @max(digest_stamp, s.stamp_ms);
                freeSource(self.gpa, s);
                continue;
            }
            if (s.pinned or keep.contains(i)) {
                try kept.append(self.gpa, s);
                continue;
            }
            if (digest.items.len > 0) try digest.appendSlice(self.gpa, "; ");
            try digest.appendSlice(self.gpa, s.title);
            digest_stamp = @max(digest_stamp, s.stamp_ms);
            freeSource(self.gpa, s);
        }

        self.entries.clearRetainingCapacity();
        try self.entries.appendSlice(self.gpa, kept.items);

        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(self.gpa);
        if (old_digest_text) |t| {
            try text.appendSlice(self.gpa, t);
            if (digest.items.len > 0) try text.appendSlice(self.gpa, "; ");
        }
        try text.appendSlice(self.gpa, digest.items);
        try self.add(.{
            .id = digest_id,
            .title = "Earlier sources (compacted)",
            .text = text.items,
            .stamp_ms = digest_stamp,
            .pinned = true,
        });
    }

    /// Ranked excerpts packed to `budget_tokens` minus `base_tokens`.
    /// Expired sources (unless pinned) never appear; each excerpt caps at
    /// `per_source_bytes` on a UTF-8 boundary. Returns "" when nothing fits.
    pub fn pack(
        self: *const Index,
        arena: std.mem.Allocator,
        query: []const u8,
        now_ms: i64,
        opts: Options,
        budget_tokens: usize,
        base_tokens: usize,
    ) error{OutOfMemory}![]const u8 {
        if (budget_tokens <= base_tokens) return "";
        const remaining = budget_tokens - base_tokens;

        var qset = try tokenSet(arena, query);

        const Ranked = struct { idx: usize, score: usize, stamp: i64 };
        var ranked: std.ArrayList(Ranked) = .empty;
        for (self.entries.items, 0..) |s, i| {
            if (!s.pinned and now_ms - s.stamp_ms > opts.ttl_ms) continue; // expired
            try ranked.append(arena, .{ .idx = i, .score = try overlap(arena, &qset, s), .stamp = s.stamp_ms });
        }
        std.sort.pdq(Ranked, ranked.items, {}, struct {
            fn lt(_: void, a: Ranked, b: Ranked) bool {
                if (a.score != b.score) return a.score > b.score;
                if (a.stamp != b.stamp) return a.stamp > b.stamp;
                return a.idx < b.idx;
            }
        }.lt);

        const header = "\nRelevant sources (ranked):\n";
        var out: std.ArrayList(u8) = .empty;
        for (ranked.items) |r| {
            const s = self.entries.items[r.idx];
            const entry = try std.fmt.allocPrint(arena, "- {s} ({s})\n  {s}\n", .{
                s.title, s.id, try excerpt(arena, s.text, opts.per_source_bytes),
            });
            const prospective = (if (out.items.len == 0) header.len else out.items.len) + entry.len;
            if ((prospective + 3) / 4 > remaining) continue; // smaller entries may still fit
            if (out.items.len == 0) try out.appendSlice(arena, header);
            try out.appendSlice(arena, entry);
        }
        return out.items;
    }
};

const digest_id = "digest:compacted";

/// Lowercased word set (length ≥ 3) — the lexical scoring vocabulary.
fn tokenSet(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}!std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(arena);
    var start: ?usize = null;
    for (text, 0..) |ch, i| {
        if (std.ascii.isAlphanumeric(ch)) {
            if (start == null) start = i;
            continue;
        }
        if (start) |s0| {
            if (i - s0 >= 3) try set.put(try std.ascii.allocLowerString(arena, text[s0..i]), {});
            start = null;
        }
    }
    if (start) |s0| if (text.len - s0 >= 3) try set.put(try std.ascii.allocLowerString(arena, text[s0..]), {});
    return set;
}

/// Count of query tokens present in the source's title+text vocabulary.
fn overlap(arena: std.mem.Allocator, qset: *std.StringHashMap(void), s: Source) error{OutOfMemory}!usize {
    const joined = try std.fmt.allocPrint(arena, "{s} {s}", .{ s.title, s.text });
    var sset = try tokenSet(arena, joined);
    var n: usize = 0;
    var it = qset.keyIterator();
    while (it.next()) |k| {
        if (sset.contains(k.*)) n += 1;
    }
    return n;
}

/// Newlines flattened, capped at `cap` bytes on a UTF-8 boundary — an
/// excerpt, never the whole document.
fn excerpt(arena: std.mem.Allocator, text: []const u8, cap: usize) error{OutOfMemory}![]const u8 {
    const flat = try arena.dupe(u8, text);
    for (flat) |*ch| {
        if (ch.* == '\n' or ch.* == '\r') ch.* = ' ';
    }
    if (flat.len <= cap) return flat;
    var end = cap;
    while (end > 0 and (flat[end] & 0xC0) == 0x80) end -= 1;
    return std.fmt.allocPrint(arena, "{s}…", .{flat[0..end]});
}

fn dupeSource(gpa: std.mem.Allocator, s: Source) error{OutOfMemory}!Source {
    const id = try gpa.dupe(u8, s.id);
    errdefer gpa.free(id);
    const title = try gpa.dupe(u8, s.title);
    errdefer gpa.free(title);
    const text = try gpa.dupe(u8, s.text);
    return .{ .id = id, .title = title, .text = text, .stamp_ms = s.stamp_ms, .pinned = s.pinned };
}

fn freeSource(gpa: std.mem.Allocator, s: Source) void {
    gpa.free(s.id);
    gpa.free(s.title);
    gpa.free(s.text);
}

fn wallNow() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

// ---------------------------------------------------------------------------
// JSONL persistence (memory/*.jsonl-compatible)
// ---------------------------------------------------------------------------

pub const source_file = "sources.jsonl";

/// One source as a JSONL line (no trailing newline).
pub fn sourceLine(arena: std.mem.Allocator, s: Source) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "{{\"id\":{f},\"title\":{f},\"text\":{f},\"ts\":{d},\"pinned\":{}}}",
        .{ json.fmt(s.id, .{}), json.fmt(s.title, .{}), json.fmt(s.text, .{}), s.stamp_ms, s.pinned },
    );
}

/// Tolerant line parse: null for anything malformed (skipped, never fatal).
pub fn parseSourceLine(arena: std.mem.Allocator, line: []const u8) ?Source {
    const v = json.parseFromSliceLeaky(json.Value, arena, line, .{}) catch return null;
    if (v != .object) return null;
    const id = strField(v.object, "id") orelse return null;
    const title = strField(v.object, "title") orelse "";
    const text = strField(v.object, "text") orelse "";
    const ts = intField(v.object, "ts") orelse return null;
    const pinned = if (v.object.get("pinned")) |p| p == .bool and p.bool else false;
    return .{ .id = id, .title = title, .text = text, .stamp_ms = ts, .pinned = pinned };
}

const strField = jsonx.strField;

const intField = jsonx.intField;

// ---------------------------------------------------------------------------
// Strategy
// ---------------------------------------------------------------------------

pub const RecallStrategy = struct {
    gpa: std.mem.Allocator,
    dir: []u8,
    opts: Options,
    index: Index,

    /// Loads `<dir>/sources.jsonl` when present (prior briefs land there in
    /// the same line shape). The directory is created if missing.
    pub fn create(gpa: std.mem.Allocator, dir: []const u8, opts: Options) error{OutOfMemory}!*RecallStrategy {
        const self = try gpa.create(RecallStrategy);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .dir = try gpa.dupe(u8, dir),
            .opts = opts,
            .index = Index.init(gpa),
        };
        mkdirQuiet(gpa, dir);
        try self.load();
        return self;
    }

    pub fn destroy(self: *RecallStrategy) void {
        self.index.deinit();
        self.gpa.free(self.dir);
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    pub fn strategy(self: *RecallStrategy) context.ContextStrategy {
        return .{ .ctx = @ptrCast(self), .assembleFn = &assembleImpl, .absorbFn = &absorbImpl };
    }

    fn load(self: *RecallStrategy) error{OutOfMemory}!void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ self.dir, source_file });
        const text = readWholeFile(arena, path) orelse return;
        var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const s = parseSourceLine(arena, line) orelse continue;
            try self.index.add(s);
        }
    }

    fn assembleImpl(
        ctx: *anyopaque,
        arena: std.mem.Allocator,
        step: context.StepRef,
        budget: context.TokenBudget,
        diag: *context.Diag,
    ) context.Error!context.Assembled {
        const self: *RecallStrategy = @ptrCast(@alignCast(ctx));
        // The substrate base stays the prompt spine; ranked excerpts append
        // under it within the remaining budget.
        const base = try substrate_mod.assembleContent(arena, step, diag);
        const base_tokens = context.estTokens(base.content);
        if (base_tokens >= budget.max_tokens) return base; // seam wrapper refuses

        const m = step.mission;
        const query = if (std.mem.eql(u8, step.role, "executor") and m.task_index < m.tasks.len)
            try std.fmt.allocPrint(arena, "{s} {s}", .{ m.objective, m.tasks[m.task_index].desc })
        else
            m.objective;
        const block = try self.index.pack(
            arena,
            query,
            self.opts.now_fn(),
            self.opts,
            budget.max_tokens,
            base_tokens,
        );
        if (block.len == 0) return base;
        return .{ .content = try std.fmt.allocPrint(arena, "{s}{s}", .{ base.content, block }) };
    }

    fn absorbImpl(ctx: *anyopaque, step: context.StepRef, outcome: context.Outcome) context.Error!void {
        const self: *RecallStrategy = @ptrCast(@alignCast(ctx));
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const m = step.mission;
        // Per role+task id: a retried task's newer outcome replaces the old
        // one (Index.add last-wins) instead of piling up near-duplicates.
        const id = try std.fmt.allocPrint(arena, "outcome:{s}:{d}", .{ outcome.role, m.task_index });
        const title = if (std.mem.eql(u8, outcome.role, "executor") and m.task_index < m.tasks.len)
            m.tasks[m.task_index].desc
        else
            outcome.role;
        const src: Source = .{
            .id = id,
            .title = title,
            .text = try excerpt(arena, outcome.text, self.opts.per_source_bytes),
            .stamp_ms = self.opts.now_fn(),
        };
        try self.index.add(src);

        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ self.dir, source_file });
        if (self.index.len() > self.opts.max_sources) {
            try self.index.compact(self.opts.max_sources);
            self.rewrite(arena, path) catch {}; // persistence is best-effort
        } else {
            appendLine(self.gpa, path, sourceLine(arena, src) catch return error.OutOfMemory);
        }
    }

    /// Full rewrite after compaction so the file mirrors the compacted index
    /// (reopen parity); the pre-compaction raw output lives on in the
    /// planning artifacts and trace.
    fn rewrite(self: *RecallStrategy, arena: std.mem.Allocator, path: []const u8) error{OutOfMemory}!void {
        const path_z = try std.fmt.allocPrintSentinel(arena, "{s}", .{path}, 0);
        const f = std.c.fopen(path_z.ptr, "w") orelse return;
        defer _ = std.c.fclose(f);
        for (self.index.entries.items) |s| {
            const line = try sourceLine(arena, s);
            _ = std.c.fwrite(line.ptr, 1, line.len, f);
            _ = std.c.fwrite("\n", 1, 1, f);
        }
    }
};

fn mkdirQuiet(gpa: std.mem.Allocator, path: []const u8) void {
    const path_z = std.fmt.allocPrintSentinel(gpa, "{s}", .{path}, 0) catch return;
    defer gpa.free(path_z);
    _ = std.c.mkdir(path_z.ptr, 0o755);
}

fn readWholeFile(arena: std.mem.Allocator, path: []const u8) ?[]u8 {
    const path_z = std.fmt.allocPrintSentinel(arena, "{s}", .{path}, 0) catch return null;
    const f = std.c.fopen(path_z.ptr, "r") orelse return null;
    defer _ = std.c.fclose(f);
    var buf: std.ArrayList(u8) = .empty;
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = std.c.fread(&chunk, 1, chunk.len, f);
        if (n == 0) break;
        buf.appendSlice(arena, chunk[0..n]) catch return null;
    }
    return buf.items;
}

fn appendLine(gpa: std.mem.Allocator, path: []const u8, line: []const u8) void {
    const path_z = std.fmt.allocPrintSentinel(gpa, "{s}", .{path}, 0) catch return;
    defer gpa.free(path_z);
    const f = std.c.fopen(path_z.ptr, "a") orelse return;
    defer _ = std.c.fclose(f);
    _ = std.c.fwrite(line.ptr, 1, line.len, f);
    _ = std.c.fwrite("\n", 1, 1, f);
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

fn fixedNow() i64 {
    return 1_000_000_000;
}

const test_opts: Options = .{
    .ttl_ms = 1000,
    .per_source_bytes = 64,
    .max_sources = 4,
    .now_fn = &fixedNow,
};

test "Index.add dedups by id, last wins" {
    var idx = Index.init(testing.allocator);
    defer idx.deinit();
    try idx.add(.{ .id = "u1", .title = "old", .text = "old text", .stamp_ms = 1 });
    try idx.add(.{ .id = "u2", .title = "other", .text = "t", .stamp_ms = 2 });
    try idx.add(.{ .id = "u1", .title = "new", .text = "new text", .stamp_ms = 3 });
    try testing.expectEqual(@as(usize, 2), idx.len());
    try testing.expectEqualStrings("new", idx.entries.items[0].title);
    try testing.expectEqual(@as(i64, 3), idx.entries.items[0].stamp_ms);
}

test "pack ranks lexically relevant sources first" {
    var idx = Index.init(testing.allocator);
    defer idx.deinit();
    try idx.add(.{ .id = "a", .title = "cooking pasta", .text = "boil water add salt", .stamp_ms = fixedNow() });
    try idx.add(.{ .id = "b", .title = "zig allocators", .text = "arena allocator patterns in zig", .stamp_ms = fixedNow() });
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const out = try idx.pack(arena_state.allocator(), "zig allocator strategy", fixedNow(), test_opts, 10_000, 0);
    const zig_pos = std.mem.indexOf(u8, out, "zig allocators") orelse return error.Missing;
    const pasta_pos = std.mem.indexOf(u8, out, "cooking pasta") orelse return error.Missing;
    try testing.expect(zig_pos < pasta_pos);
}

test "pack drops expired sources; pinned survive expiry" {
    var idx = Index.init(testing.allocator);
    defer idx.deinit();
    try idx.add(.{ .id = "stale", .title = "stale news", .text = "zig", .stamp_ms = fixedNow() - 10_000 });
    try idx.add(.{ .id = "pin", .title = "pinned digest", .text = "zig", .stamp_ms = fixedNow() - 10_000, .pinned = true });
    try idx.add(.{ .id = "fresh", .title = "fresh news", .text = "zig", .stamp_ms = fixedNow() });
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const out = try idx.pack(arena_state.allocator(), "zig", fixedNow(), test_opts, 10_000, 0);
    try testing.expect(std.mem.indexOf(u8, out, "stale news") == null);
    try testing.expect(std.mem.indexOf(u8, out, "pinned digest") != null);
    try testing.expect(std.mem.indexOf(u8, out, "fresh news") != null);
}

test "pack excerpts cap at per_source_bytes on a UTF-8 boundary — never whole documents" {
    var idx = Index.init(testing.allocator);
    defer idx.deinit();
    var big: [200]u8 = undefined;
    @memset(&big, 'z');
    try idx.add(.{ .id = "big", .title = "big doc", .text = &big, .stamp_ms = fixedNow() });
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const out = try idx.pack(arena_state.allocator(), "zzz", fixedNow(), test_opts, 10_000, 0);
    // 64-byte cap: the 200-byte body must not appear whole.
    try testing.expect(std.mem.indexOf(u8, out, big[0..65]) == null);
    try testing.expect(std.mem.indexOf(u8, out, "…") != null);
}

test "pack respects the remaining budget and returns empty when nothing fits" {
    var idx = Index.init(testing.allocator);
    defer idx.deinit();
    try idx.add(.{ .id = "a", .title = "zig one", .text = "zig zig zig", .stamp_ms = fixedNow() });
    try idx.add(.{ .id = "b", .title = "zig two", .text = "zig zig zig", .stamp_ms = fixedNow() });
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const all = try idx.pack(arena, "zig", fixedNow(), test_opts, 10_000, 0);
    try testing.expect(std.mem.indexOf(u8, all, "zig one") != null);
    try testing.expect(std.mem.indexOf(u8, all, "zig two") != null);

    // Base already consumes almost everything: nothing fits.
    const none = try idx.pack(arena, "zig", fixedNow(), test_opts, 100, 99);
    try testing.expectEqualStrings("", none);

    // Room for roughly one entry: the pack must stay within budget.
    const one = try idx.pack(arena, "zig", fixedNow(), test_opts, 20, 0);
    try testing.expect(context.estTokens(one) <= 20);
}

test "compact merges the dropped tail into one pinned digest" {
    var idx = Index.init(testing.allocator);
    defer idx.deinit();
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        const id = try std.fmt.allocPrint(testing.allocator, "s{d}", .{i});
        defer testing.allocator.free(id);
        const title = try std.fmt.allocPrint(testing.allocator, "title-{d}", .{i});
        defer testing.allocator.free(title);
        try idx.add(.{ .id = id, .title = title, .text = "body", .stamp_ms = @intCast(i) });
    }
    try idx.compact(3);
    try testing.expect(idx.len() <= 4); // 3 kept + 1 pinned digest
    var found_digest = false;
    for (idx.entries.items) |s| {
        if (s.pinned) {
            found_digest = true;
            // The freshest entries survive verbatim; the digest names the dropped.
            try testing.expect(std.mem.indexOf(u8, s.text, "title-0") != null);
        }
    }
    try testing.expect(found_digest);
    // Freshest (highest stamp) entries kept.
    var kept_5 = false;
    for (idx.entries.items) |s| if (std.mem.eql(u8, s.title, "title-5")) {
        kept_5 = true;
    };
    try testing.expect(kept_5);
}

test "sourceLine/parseSourceLine round-trip; malformed lines are null" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s: Source = .{ .id = "https://x", .title = "T \"q\"", .text = "body\nline", .stamp_ms = 42, .pinned = true };
    const line = try sourceLine(arena, s);
    const back = parseSourceLine(arena, line) orelse return error.ParseFailed;
    try testing.expectEqualStrings(s.id, back.id);
    try testing.expectEqualStrings(s.title, back.title);
    try testing.expectEqualStrings(s.text, back.text);
    try testing.expectEqual(s.stamp_ms, back.stamp_ms);
    try testing.expect(back.pinned);
    try testing.expect(parseSourceLine(arena, "not json") == null);
    try testing.expect(parseSourceLine(arena, "{\"title\":\"no id\"}") == null);
}

extern "c" fn realpath(path: [*:0]const u8, resolved: [*]u8) ?[*:0]u8;

const TmpDir = struct {
    tmp: std.testing.TmpDir,
    path_buf: [std.fs.max_path_bytes]u8 = undefined,

    fn init() !TmpDir {
        return .{ .tmp = std.testing.tmpDir(.{}) };
    }
    fn path(self: *TmpDir) ![]const u8 {
        var rel_buf: [std.fs.max_path_bytes]u8 = undefined;
        const rel = try std.fmt.bufPrintZ(&rel_buf, ".zig-cache/tmp/{s}", .{self.tmp.sub_path});
        return std.mem.span(realpath(rel, &self.path_buf) orelse return error.RealpathFailed);
    }
    fn cleanup(self: *TmpDir) void {
        self.tmp.cleanup();
    }
};

fn executorStep(sub: *anyopaque, readFn: *const fn (*anyopaque, std.mem.Allocator, []const u8) ?[]const u8) context.StepRef {
    const tasks_static = struct {
        var tasks = [_]context.TaskView{.{ .desc = "survey zig allocator articles" }};
    };
    return .{
        .role = "executor",
        .mission = .{
            .mission_id = "radar",
            .objective = "weekly zig ecosystem brief",
            .tasks = &tasks_static.tasks,
        },
        .substrate = .{ .ctx = sub, .readFn = readFn },
    };
}

fn nullRead(ctx: *anyopaque, arena: std.mem.Allocator, name: []const u8) ?[]const u8 {
    _ = ctx;
    _ = arena;
    _ = name;
    return null;
}

test "absorb → assemble: an absorbed outcome surfaces as a ranked source under the base" {
    var tmp = try TmpDir.init();
    defer tmp.cleanup();
    const dir = try tmp.path();

    const rs = try RecallStrategy.create(testing.allocator, dir, test_opts);
    defer rs.destroy();

    const step = executorStep(@ptrCast(@constCast(&{})), &nullRead);
    try rs.strategy().absorb(step, .{
        .role = "executor",
        .ok = true,
        .text = "found three zig allocator articles worth citing",
    });

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diag: context.Diag = .{};
    const out = try rs.strategy().assemble(arena_state.allocator(), step, .{ .max_tokens = 10_000 }, &diag);
    // Base spine first, recall block after.
    try testing.expect(std.mem.startsWith(u8, out.content, "Objective:\nweekly zig ecosystem brief\n"));
    try testing.expect(std.mem.indexOf(u8, out.content, "Relevant sources") != null);
    try testing.expect(std.mem.indexOf(u8, out.content, "found three zig allocator articles") != null);
}

test "prior-brief jsonl lines in sources.jsonl load at create" {
    var tmp = try TmpDir.init();
    defer tmp.cleanup();
    const dir = try tmp.path();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fpath = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, source_file });
    appendLine(testing.allocator, fpath, try sourceLine(arena, .{
        .id = "brief-2026-07-14",
        .title = "prior weekly brief",
        .text = "zig 0.16 shipped std.Io changes",
        .stamp_ms = fixedNow(),
    }));
    appendLine(testing.allocator, fpath, "garbage line that must be skipped");

    const rs = try RecallStrategy.create(testing.allocator, dir, test_opts);
    defer rs.destroy();
    try testing.expectEqual(@as(usize, 1), rs.index.len());

    var diag: context.Diag = .{};
    const step = executorStep(@ptrCast(@constCast(&{})), &nullRead);
    const out = try rs.strategy().assemble(arena, step, .{ .max_tokens = 10_000 }, &diag);
    try testing.expect(std.mem.indexOf(u8, out.content, "prior weekly brief") != null);
}

const ReopenCtx = struct {
    gpa: std.mem.Allocator,
    dir: []const u8,
    reopened: ?*RecallStrategy = null,

    fn reopen(ctx: *anyopaque) context.Error!context.ContextStrategy {
        const self: *ReopenCtx = @ptrCast(@alignCast(ctx));
        if (self.reopened) |old| old.destroy();
        self.reopened = try RecallStrategy.create(self.gpa, self.dir, test_opts);
        return self.reopened.?.strategy();
    }
};

test "RecallStrategy passes the conformance harness with resume-from-disk parity" {
    const conformance = @import("context_conformance.zig");
    var tmp = try TmpDir.init();
    defer tmp.cleanup();
    const dir = try tmp.path();

    const rs = try RecallStrategy.create(testing.allocator, dir, test_opts);
    defer rs.destroy();
    var reopen_ctx = ReopenCtx{ .gpa = testing.allocator, .dir = dir };
    defer if (reopen_ctx.reopened) |r| r.destroy();

    try conformance.conform(testing.allocator, .{
        .strategy = rs.strategy(),
        .reopenFn = &ReopenCtx.reopen,
        .reopen_ctx = @ptrCast(&reopen_ctx),
    }, executorStep(@ptrCast(@constCast(&{})), &nullRead));
}
