//! Output-trim filter worker (U6, decision Z-09; docs/specs/trim.md).
//! Registers `zygos::output::compress` — the seam the turn driver calls on
//! every tool result. rtk/ztk-style lossy-but-honest trimming: strip ANSI,
//! collapse blank-line runs, keep head+tail with a marker saying what was
//! dropped. Bytes saved are reported to the budget worker (cast — the tool
//! path never blocks on accounting).

const std = @import("std");
const json = std.json;
const actor_mod = @import("../kernel/actor.zig");
const sync = @import("../kernel/sync.zig");
const dispatch = @import("filter/dispatch.zig");
const cache_mod = @import("filter/cache.zig");
const inproc = @import("../kernel/inproc.zig");

pub const Limits = struct {
    max_bytes: usize = 16 * 1024,
    max_lines: usize = 256,
    head_lines: usize = 96,
    tail_lines: usize = 96,
};

/// Pure trim pass, applied in order: ANSI strip → blank-run collapse →
/// head/tail elision when over max_lines or max_bytes. Under the limits the
/// clean text passes through byte-identical.
pub fn trim(arena: std.mem.Allocator, text: []const u8, limits: Limits) error{OutOfMemory}![]const u8 {
    const stripped = try stripAnsi(arena, text);
    const collapsed = try collapseBlankRuns(arena, stripped);
    return elide(arena, collapsed, limits);
}

/// Drop CSI (ESC [ … final in 0x40-0x7e) and OSC (ESC ] … BEL | ESC \)
/// sequences; a lone ESC is dropped too.
fn stripAnsi(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]const u8 {
    if (std.mem.indexOfScalar(u8, text, 0x1b) == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] != 0x1b) {
            try out.append(arena, text[i]);
            i += 1;
            continue;
        }
        if (i + 1 < text.len and text[i + 1] == '[') {
            i += 2;
            while (i < text.len and !(text[i] >= 0x40 and text[i] <= 0x7e)) i += 1;
            if (i < text.len) i += 1; // the final byte
        } else if (i + 1 < text.len and text[i + 1] == ']') {
            i += 2;
            while (i < text.len) {
                if (text[i] == 0x07) {
                    i += 1;
                    break;
                }
                if (text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '\\') {
                    i += 2;
                    break;
                }
                i += 1;
            }
        } else {
            i += 1;
        }
    }
    return out.items;
}

/// Runs of 3+ blank lines become one; runs of 1-2 stay as they are.
fn collapseBlankRuns(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]const u8 {
    if (std.mem.indexOf(u8, text, "\n\n\n\n") == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var blanks: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, i, '\n');
        const end = nl orelse text.len;
        const line = text[i..end];
        const has_nl = nl != null;
        if (line.len == 0 and has_nl) {
            blanks += 1;
        } else {
            if (blanks > 0) {
                try out.appendNTimes(arena, '\n', if (blanks >= 3) 1 else blanks);
                blanks = 0;
            }
            try out.appendSlice(arena, line);
            if (has_nl) try out.append(arena, '\n');
        }
        i = end + @intFromBool(has_nl);
    }
    if (blanks > 0) try out.appendNTimes(arena, '\n', if (blanks >= 3) 1 else blanks);
    return out.items;
}

fn marker(arena: std.mem.Allocator, lines: usize, bytes: usize) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(arena, "[... zygos trimmed {d} lines ({d} bytes) ...]\n", .{ lines, bytes });
}

fn elide(arena: std.mem.Allocator, text: []const u8, limits: Limits) error{OutOfMemory}![]const u8 {
    const line_count = std.mem.count(u8, text, "\n") + @intFromBool(text.len > 0 and text[text.len - 1] != '\n');
    if (text.len <= limits.max_bytes and line_count <= limits.max_lines) return text;

    // Line-based head/tail elision first.
    if (line_count > limits.head_lines + limits.tail_lines) {
        var starts: std.ArrayList(usize) = .empty; // start offset of every line
        try starts.append(arena, 0);
        for (text, 0..) |b, off| {
            if (b == '\n' and off + 1 < text.len) try starts.append(arena, off + 1);
        }
        const head_end = starts.items[limits.head_lines];
        const tail_start = starts.items[starts.items.len - limits.tail_lines];
        if (head_end < tail_start) {
            const dropped_lines = starts.items.len - limits.head_lines - limits.tail_lines;
            var out: std.ArrayList(u8) = .empty;
            try out.appendSlice(arena, text[0..head_end]);
            try out.appendSlice(arena, try marker(arena, dropped_lines, tail_start - head_end));
            try out.appendSlice(arena, text[tail_start..]);
            if (out.items.len <= limits.max_bytes) return out.items;
            return byteFallback(arena, out.items, limits);
        }
    }
    return byteFallback(arena, text, limits);
}

/// Middle-out byte cut for line-poor oversized text (one giant line, or
/// head+tail still over the cap). Cuts land on UTF-8 boundaries.
fn byteFallback(arena: std.mem.Allocator, text: []const u8, limits: Limits) error{OutOfMemory}![]const u8 {
    if (text.len <= limits.max_bytes) return text;
    const keep = limits.max_bytes / 2;
    var front_end = @min(keep, text.len);
    while (front_end > 0 and (text[front_end] & 0xC0) == 0x80) front_end -= 1;
    var back_start = text.len - @min(keep, text.len);
    while (back_start < text.len and (text[back_start] & 0xC0) == 0x80) back_start += 1;
    if (back_start <= front_end) return text;

    const middle = text[front_end..back_start];
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, text[0..front_end]);
    try out.append(arena, '\n');
    try out.appendSlice(arena, try marker(arena, std.mem.count(u8, middle, "\n"), middle.len));
    try out.appendSlice(arena, text[back_start..]);
    return out.items;
}

fn rawJson(alloc: std.mem.Allocator, value: json.Value) error{OutOfMemory}![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    json.Stringify.value(value, .{}, &out.writer) catch return error.OutOfMemory;
    return out.written();
}

/// Wall-clock ms (same contract as kernel/inproc.zig — Zig 0.16 std has no
/// io-free milliTimestamp).
fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

pub const TrimWorker = struct {
    gpa: std.mem.Allocator,
    worker: *inproc.Worker,
    limits: Limits,
    budget_scope: ?[]const u8, // owned

    /// S8.4 dedup + S8.5 stats. Guarded by `mutex`: the bus may deliver
    /// concurrent invocations, and neither is safe to touch unsynchronized.
    mutex: sync.Mutex = .{},
    cache: cache_mod.Cache = .{},
    stats: Stats = .{},

    /// S8.5: compression evidence, so a mission's ratio is inspectable
    /// rather than asserted.
    pub const Stats = struct {
        calls: usize = 0,
        filtered: usize = 0,
        deduped: usize = 0,
        raw_bytes: usize = 0,
        sent_bytes: usize = 0,
    };

    pub fn start(
        gpa: std.mem.Allocator,
        actor: *actor_mod.Actor,
        registry: *inproc.Registry,
        limits: Limits,
        budget_scope: ?[]const u8,
    ) !*TrimWorker {
        const self = try gpa.create(TrimWorker);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .worker = try inproc.Worker.spawn(gpa, actor, registry, "output-trim"),
            .limits = limits,
            .budget_scope = if (budget_scope) |s| try gpa.dupe(u8, s) else null,
        };
        errdefer self.worker.stop();
        try self.worker.registerFunction("zygos::output::compress", self, &handler);
        try self.worker.registerFunction("zygos::output::stats", self, &statsHandler);
        return self;
    }

    pub fn stop(self: *TrimWorker) void {
        self.worker.stop();
        if (self.budget_scope) |s| self.gpa.free(s);
        self.mutex.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    /// Seam contract (turn driver): `{"content":..., "tool":..., "input":...}`
    /// → `{"content":...}`. `tool`/`input` are optional (S8.1): without them
    /// only the generic trim runs, which is what every pre-M8 caller gets.
    /// Malformed requests fail the handler — the driver's seam falls back
    /// to the untrimmed output on any error.
    fn handler(ctx: ?*anyopaque, arena: std.mem.Allocator, request_json: []const u8) error{ Failed, OutOfMemory }![]const u8 {
        const self: *TrimWorker = @ptrCast(@alignCast(ctx.?));

        const root = json.parseFromSliceLeaky(json.Value, arena, request_json, .{}) catch
            return error.Failed;
        if (root != .object) return error.Failed;
        const content = root.object.get("content") orelse return error.Failed;
        if (content != .string) return error.Failed;
        const raw = content.string;

        const tool = if (root.object.get("tool")) |v|
            (if (v == .string) v.string else "")
        else
            "";
        const command = if (root.object.get("input")) |v| blk: {
            if (v != .object) break :blk null;
            const c = v.object.get("command") orelse break :blk null;
            break :blk if (c == .string) c.string else null;
        } else null;

        const out = try self.compressEnvelope(arena, raw, tool, command);
        if (raw.len > out.len) self.recordSavings(arena, raw.len - out.len);
        return std.fmt.allocPrint(arena, "{{\"content\":{f}}}", .{json.fmt(out, .{})});
    }

    /// Tool replies are usually an envelope, not bare text:
    /// `zygos::tools::bash` answers `{"exit_code":N,"output":"..."}` and
    /// `web_fetch` answers `{"url":...,"text":...,"truncated":...}`.
    /// Compressing an envelope as one blob is wrong three ways over — the
    /// guard sees JSON and skips every filter (M8 was dead on the real path
    /// until test/e2e/m8 caught it), the payload inside is escaped so
    /// line-based filters see one long line, and a byte-level cut lands
    /// inside the JSON and hands the model something unparseable.
    ///
    /// So: unwrap, compress the payload, re-wrap. The model still gets the
    /// tool's declared reply shape; only the payload shrinks. Anything that
    /// is not a recognizable envelope is compressed as-is.
    fn compressEnvelope(
        self: *TrimWorker,
        arena: std.mem.Allocator,
        raw: []const u8,
        tool: []const u8,
        command: ?[]const u8,
    ) error{OutOfMemory}![]const u8 {
        if (envelopePayload(arena, raw)) |payload| {
            const compressed = try self.compress(arena, payload.text, tool, command);
            if (compressed.len >= payload.text.len) return raw;
            return std.fmt.allocPrint(arena, "{{{s}{f}:{f}}}", .{
                payload.prefix,
                json.fmt(payload.key, .{}),
                json.fmt(compressed, .{}),
            });
        }
        // Structured data with no text payload (e.g. web_search's
        // `{"results":[...]}`): a byte-level cut lands mid-JSON and hands the
        // model something unparseable. Drop whole elements instead, so what
        // arrives is always valid — shorter, but still parseable.
        if (raw.len > self.limits.max_bytes) {
            if (try truncateJsonArray(arena, raw, self.limits.max_bytes)) |shorter| {
                self.note(.{ .sent = shorter.len });
                self.mutex.lock();
                self.stats.calls += 1;
                self.stats.raw_bytes += raw.len;
                self.mutex.unlock();
                return shorter;
            }
        }
        return self.compress(arena, raw, tool, command);
    }

    /// Shrink `{"key":[...]}` by dropping trailing array elements until it
    /// fits, appending a count of what was dropped as a final string element.
    /// Null when the value is not an object holding exactly one array, in
    /// which case the caller falls back to the generic path.
    fn truncateJsonArray(
        arena: std.mem.Allocator,
        raw: []const u8,
        max_bytes: usize,
    ) error{OutOfMemory}!?[]const u8 {
        const root = json.parseFromSliceLeaky(json.Value, arena, raw, .{}) catch return null;
        if (root != .object) return null;

        var array_key: ?[]const u8 = null;
        var it = root.object.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* != .array) continue;
            if (array_key != null) return null; // ambiguous: more than one
            array_key = e.key_ptr.*;
        }
        const key = array_key orelse return null;
        const items = root.object.get(key).?.array.items;
        if (items.len == 0) return null;

        // Binary search the largest prefix that fits.
        var lo: usize = 0;
        var hi: usize = items.len;
        var best: ?[]const u8 = null;
        while (lo < hi) {
            const mid = lo + (hi - lo + 1) / 2;
            const candidate = try renderPrefix(arena, key, items, mid);
            if (candidate.len <= max_bytes) {
                best = candidate;
                lo = mid;
                if (lo == items.len) break;
            } else {
                hi = mid - 1;
            }
        }
        return best orelse try renderPrefix(arena, key, items, 0);
    }

    fn renderPrefix(
        arena: std.mem.Allocator,
        key: []const u8,
        items: []const json.Value,
        keep: usize,
    ) error{OutOfMemory}![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.print(arena, "{{{f}:[", .{json.fmt(key, .{})});
        for (items[0..keep], 0..) |item, i| {
            if (i > 0) try out.append(arena, ',');
            try out.appendSlice(arena, try rawJson(arena, item));
        }
        if (keep < items.len) {
            if (keep > 0) try out.append(arena, ',');
            try out.print(arena, "{f}", .{json.fmt(
                try std.fmt.allocPrint(arena, "[... zygos dropped {d} more entries ...]", .{items.len - keep}),
                .{},
            )});
        }
        try out.appendSlice(arena, "]}");
        return out.items;
    }

    const Envelope = struct {
        /// Preserved sibling fields, already serialized with a trailing comma.
        prefix: []const u8,
        /// Which field held the payload, so it is re-wrapped under its own name.
        key: []const u8,
        text: []const u8,
    };

    /// The field names tools use for their human-readable payload, in
    /// priority order. A reply carrying one of these is an envelope; anything
    /// else is genuine structured data the filters must never reshape.
    const payload_keys = [_][]const u8{ "output", "text", "content" };

    fn envelopePayload(arena: std.mem.Allocator, raw: []const u8) ?Envelope {
        const t = std.mem.trim(u8, raw, " \t\r\n");
        if (t.len == 0 or t[0] != '{') return null;
        const root = json.parseFromSliceLeaky(json.Value, arena, t, .{}) catch return null;
        if (root != .object) return null;

        const key = blk: {
            for (payload_keys) |k| {
                const v = root.object.get(k) orelse continue;
                if (v == .string) break :blk k;
            }
            return null;
        };
        const text = root.object.get(key).?.string;

        var prefix: std.ArrayList(u8) = .empty;
        var it = root.object.iterator();
        while (it.next()) |e| {
            if (std.mem.eql(u8, e.key_ptr.*, key)) continue;
            const rendered = rawJson(arena, e.value_ptr.*) catch return null;
            prefix.print(arena, "{f}:{s},", .{ json.fmt(e.key_ptr.*, .{}), rendered }) catch return null;
        }
        return .{ .prefix = prefix.items, .key = key, .text = text };
    }

    /// The M8 pipeline: dedup → command-aware filter → generic trim.
    ///
    /// The generic trim always runs last, even behind a filter, so a filter
    /// that under-compresses still cannot blow the budget. Every stage fails
    /// open to the stage below it.
    fn compress(
        self: *TrimWorker,
        arena: std.mem.Allocator,
        raw: []const u8,
        tool: []const u8,
        command: ?[]const u8,
    ) error{OutOfMemory}![]const u8 {
        const selection = dispatch.select(tool, command);

        self.mutex.lock();
        self.stats.calls += 1;
        self.stats.raw_bytes += raw.len;
        // The cache is consulted for anything we can classify; a mutating
        // command invalidates it even when no filter applies.
        const now_ms = nowMs();
        const unchanged_age: ?i64 = if (selection) |sel|
            self.cache.seenUnchanged(tool, command, raw, sel.family, now_ms)
        else blk: {
            if (dispatch.isMutating(tool, command)) self.cache.reset();
            break :blk null;
        };
        self.mutex.unlock();

        if (unchanged_age) |age| {
            const short = try cache_mod.unchangedMarker(arena, age);
            self.note(.{ .deduped = true, .sent = short.len });
            return short;
        }

        var text = raw;
        var did_filter = false;
        if (selection) |sel| {
            if (try sel.filter(arena, text)) |filtered| {
                text = filtered;
                did_filter = true;
            }
        }
        const final = try trim(arena, text, self.limits);
        self.note(.{ .filtered = did_filter, .sent = final.len });
        return final;
    }

    fn note(self: *TrimWorker, ev: struct { filtered: bool = false, deduped: bool = false, sent: usize }) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (ev.filtered) self.stats.filtered += 1;
        if (ev.deduped) self.stats.deduped += 1;
        self.stats.sent_bytes += ev.sent;
    }

    /// Fire-and-forget: accounting must never slow the tool path.
    fn recordSavings(self: *TrimWorker, arena: std.mem.Allocator, saved: usize) void {
        const scope = self.budget_scope orelse return;
        const rec = std.fmt.allocPrint(
            arena,
            "{{\"scope\":{f},\"kind\":\"saved_bytes\",\"amount\":{d}}}",
            .{ json.fmt(scope, .{}), saved },
        ) catch return;
        self.worker.cast("zygos::budget::record", rec) catch {};
    }

    fn statsHandler(ctx: ?*anyopaque, arena: std.mem.Allocator, _: []const u8) error{ Failed, OutOfMemory }![]const u8 {
        const self: *TrimWorker = @ptrCast(@alignCast(ctx.?));
        self.mutex.lock();
        const s = self.stats;
        self.mutex.unlock();
        return std.fmt.allocPrint(
            arena,
            "{{\"calls\":{d},\"filtered\":{d},\"deduped\":{d},\"raw_bytes\":{d},\"sent_bytes\":{d}}}",
            .{ s.calls, s.filtered, s.deduped, s.raw_bytes, s.sent_bytes },
        );
    }
};

// ===========================================================================
// Tests (docs/specs/trim.md contract, RED first)
// ===========================================================================

const testing = std.testing;

const tiny: Limits = .{ .max_bytes = 200, .max_lines = 10, .head_lines = 3, .tail_lines = 2 };

test "short clean text passes through byte-identical" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const text = "line one\nline two\nline three\n";
    try testing.expectEqualStrings(text, try trim(arena.allocator(), text, .{}));
}

test "ANSI escapes are stripped (CSI colors + OSC title)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const text = "\x1b[31mred\x1b[0m plain \x1b]0;title\x07tail";
    try testing.expectEqualStrings("red plain tail", try trim(arena.allocator(), text, .{}));
}

test "blank-line runs of 3+ collapse to one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const text = "a\n\n\n\n\nb\n\nc\n";
    // 4 blank lines between a and b collapse to one; the single blank
    // between b and c stays.
    try testing.expectEqualStrings("a\n\nb\n\nc\n", try trim(arena.allocator(), text, .{}));
}

test "over max_lines keeps head+tail with a counting marker" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var lb: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        try buf.appendSlice(testing.allocator, std.fmt.bufPrint(&lb, "line-{d}\n", .{i}) catch unreachable);
    }

    const out = try trim(arena.allocator(), buf.items, tiny);
    try testing.expect(std.mem.indexOf(u8, out, "line-0\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "line-2\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "line-18\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "line-19\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "line-9\n") == null); // middle dropped
    try testing.expect(std.mem.indexOf(u8, out, "zygos trimmed 15 lines") != null);
}

test "over max_bytes with few lines still trims" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const long = "x" ** 500; // one line, 500 bytes against max_bytes=200
    const out = try trim(arena.allocator(), long, tiny);
    try testing.expect(out.len < long.len);
    try testing.expect(std.mem.indexOf(u8, out, "zygos trimmed") != null);
}

test "trimmed output respects the byte limit (with marker slack)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var lb: [40]u8 = undefined;
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        try buf.appendSlice(testing.allocator, std.fmt.bufPrint(&lb, "padding-line-{d}\n", .{i}) catch unreachable);
    }

    const out = try trim(arena.allocator(), buf.items, tiny);
    // head 3 + tail 2 short lines + marker sit well under 2x the byte cap.
    try testing.expect(out.len <= tiny.max_bytes * 2);
    try testing.expect(std.mem.indexOf(u8, out, "zygos trimmed") != null);
}

test "trim never splits a UTF-8 sequence on byte fallback" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // One giant line of 3-byte runes — every byte boundary is a hazard.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var i: usize = 0;
    while (i < 300) : (i += 1) try buf.appendSlice(testing.allocator, "€");

    const out = try trim(arena.allocator(), buf.items, tiny);
    try testing.expect(out.len < buf.items.len);
    try testing.expect(std.unicode.utf8ValidateSlice(out));
}

// -- Worker over the bus -----------------------------------------------------

const budget_mod = @import("budget.zig");

const Harness = struct {
    registry: inproc.Registry,
    actor: actor_mod.Actor,
    kernel: std.Thread,
    caller: *inproc.Worker,

    fn init(gpa: std.mem.Allocator) !*Harness {
        const self = try gpa.create(Harness);
        self.registry = inproc.Registry.init(gpa, null);
        self.actor = try actor_mod.Actor.init(gpa, .{}, self.registry.outbound());
        self.kernel = try std.Thread.spawn(.{}, actor_mod.Actor.run, .{&self.actor});
        self.caller = try inproc.Worker.spawn(gpa, &self.actor, &self.registry, "test-caller");
        return self;
    }

    fn deinit(self: *Harness) void {
        const gpa = self.actor.gpa;
        self.caller.stop();
        self.actor.post(.shutdown);
        self.kernel.join();
        self.actor.deinit();
        self.registry.deinit();
        gpa.destroy(self);
    }
};

test "worker trims oversized content and records savings to the budget scope" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const bw = try budget_mod.BudgetWorker.start(testing.allocator, &h.actor, &h.registry);
    defer bw.stop();
    const tw = try TrimWorker.start(testing.allocator, &h.actor, &h.registry, tiny, "z-scope");
    defer tw.stop();

    // Build {"content":"line-0\nline-1\n...\n"} oversized for `tiny`.
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(testing.allocator);
    var lb: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        try content.appendSlice(testing.allocator, std.fmt.bufPrint(&lb, "line-{d}\\n", .{i}) catch unreachable);
    }
    const req = try std.fmt.allocPrint(testing.allocator, "{{\"content\":\"{s}\"}}", .{content.items});
    defer testing.allocator.free(req);

    const res = try h.caller.call("zygos::output::compress", req);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try testing.expect(std.mem.indexOf(u8, res.ok, "zygos trimmed") != null);

    // The savings record is a cast; poll the budget (bounded, no sleeps).
    var spins: usize = 0;
    var saved: bool = false;
    while (spins < 10_000 and !saved) : (spins += 1) {
        const c = try h.caller.call("zygos::budget::check", "{\"scope\":\"z-scope\"}");
        defer c.deinit(testing.allocator);
        saved = std.mem.indexOf(u8, c.ok, "\"saved_bytes\":0") == null;
    }
    try testing.expect(saved);
}

test "worker passes short content through and fails on malformed requests" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const tw = try TrimWorker.start(testing.allocator, &h.actor, &h.registry, .{}, null);
    defer tw.stop();

    const ok = try h.caller.call("zygos::output::compress", "{\"content\":\"hi\"}");
    defer ok.deinit(testing.allocator);
    try testing.expect(ok == .ok);
    try testing.expect(std.mem.indexOf(u8, ok.ok, "\"content\":\"hi\"") != null);

    const bad = try h.caller.call("zygos::output::compress", "{\"nope\":1}");
    defer bad.deinit(testing.allocator);
    try testing.expect(bad == .err);
    try testing.expectEqualStrings("handler_failed", bad.err);
}

test "no leaks under trim loops" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        _ = try trim(arena_state.allocator(), "some \x1b[32mtext\x1b[0m\n\n\n\n\nend\n", .{});
    }
}

// ===========================================================================
// M8 integration: the seam end-to-end (docs/specs/filter.md S8.3-S8.5).
// The filter modules own their own unit contracts; these pin the wiring.
// ===========================================================================

/// A real `git diff` shape, big enough that the generic trim alone would
/// have to cut into the middle of it.
const e2e_diff = blk: {
    var s: []const u8 =
        \\diff --git a/src/worker/turn.zig b/src/worker/turn.zig
        \\index 1a2b3c4..5d6e7f8 100644
        \\--- a/src/worker/turn.zig
        \\+++ b/src/worker/turn.zig
        \\@@ -406,10 +406,20 @@ fn compressSeam(
        \\
    ;
    // Padding context, of the sort a real diff carries and the model cannot act on.
    for (0..40) |_| s = s ++ "     const untouched_context_line_here = 0;\n";
    s = s ++ "-    const request = old_shape;\n";
    s = s ++ "+    const request = new_shape_with_context;\n";
    for (0..40) |_| s = s ++ "     const more_untouched_context = 1;\n";
    break :blk s;
};

fn compressReq(gpa: std.mem.Allocator, content: []const u8, tool: []const u8, command: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        gpa,
        "{{\"content\":{f},\"tool\":{f},\"input\":{{\"command\":{f}}}}}",
        .{ json.fmt(content, .{}), json.fmt(tool, .{}), json.fmt(command, .{}) },
    );
}

test "M8: a git diff is filtered, not blindly truncated" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const tw = try TrimWorker.start(testing.allocator, &h.actor, &h.registry, .{}, null);
    defer tw.stop();

    const req = try compressReq(testing.allocator, e2e_diff, "bash", "git diff HEAD~1");
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::output::compress", req);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);

    // The change survived; the metadata and far context did not.
    try testing.expect(std.mem.indexOf(u8, res.ok, "new_shape_with_context") != null);
    try testing.expect(std.mem.indexOf(u8, res.ok, "old_shape") != null);
    try testing.expect(std.mem.indexOf(u8, res.ok, "index 1a2b3c4") == null);
    try testing.expect(std.mem.indexOf(u8, res.ok, "zygos diff:") != null);
    try testing.expect(res.ok.len < req.len / 2);
}

test "M8: an unknown command still gets the generic trim (back-compat)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const tw = try TrimWorker.start(testing.allocator, &h.actor, &h.registry, tiny, null);
    defer tw.stop();

    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(testing.allocator);
    for (0..40) |_| try big.appendSlice(testing.allocator, "unrecognized output line\n");

    const req = try compressReq(testing.allocator, big.items, "bash", "some-unknown-tool --flag");
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::output::compress", req);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try testing.expect(std.mem.indexOf(u8, res.ok, "zygos trimmed") != null);
}

test "M8: a piped command is never filtered (fail open)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const tw = try TrimWorker.start(testing.allocator, &h.actor, &h.registry, .{}, null);
    defer tw.stop();

    const req = try compressReq(testing.allocator, e2e_diff, "bash", "git diff | head -50");
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::output::compress", req);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    // Untouched by the git filter: the metadata is still there.
    try testing.expect(std.mem.indexOf(u8, res.ok, "index 1a2b3c4") != null);
}

test "M8: repeating an unchanged command collapses to one line" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const tw = try TrimWorker.start(testing.allocator, &h.actor, &h.registry, .{}, null);
    defer tw.stop();

    const status_out =
        "On branch master\nYour branch is up to date with 'origin/master'.\n" ++
        "\nChanges not staged for commit:\n  (use \"git add <file>...\" to update)\n" ++
        "  modified:   src/worker/trim.zig\n\nno changes added to commit\n";

    const req = try compressReq(testing.allocator, status_out, "bash", "git status");
    defer testing.allocator.free(req);

    const first = try h.caller.call("zygos::output::compress", req);
    defer first.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, first.ok, "src/worker/trim.zig") != null);

    const second = try h.caller.call("zygos::output::compress", req);
    defer second.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, second.ok, "output unchanged since") != null);
    try testing.expect(second.ok.len < first.ok.len);
}

test "M8: a mutating command invalidates the dedup cache" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const tw = try TrimWorker.start(testing.allocator, &h.actor, &h.registry, .{}, null);
    defer tw.stop();

    const status_out = "On branch master\n  modified:   a.zig\n  modified:   b.zig\n" ++
        "  modified:   c.zig\n  modified:   d.zig\nno changes added to commit\n";
    const req = try compressReq(testing.allocator, status_out, "bash", "git status");
    defer testing.allocator.free(req);

    const r1 = try h.caller.call("zygos::output::compress", req);
    defer r1.deinit(testing.allocator);
    const r2 = try h.caller.call("zygos::output::compress", req);
    defer r2.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, r2.ok, "output unchanged since") != null);

    // `git add` clears the cache; the next identical status is full again.
    const mut = try compressReq(testing.allocator, "", "bash", "git add -A");
    defer testing.allocator.free(mut);
    const rm = try h.caller.call("zygos::output::compress", mut);
    defer rm.deinit(testing.allocator);

    const r3 = try h.caller.call("zygos::output::compress", req);
    defer r3.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, r3.ok, "output unchanged since") == null);
    try testing.expect(std.mem.indexOf(u8, r3.ok, "a.zig") != null);
}

test "M8: output::stats reports the compression ratio (S8.5 exit floor)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const tw = try TrimWorker.start(testing.allocator, &h.actor, &h.registry, .{}, null);
    defer tw.stop();

    // A small corpus in the shape of a real executor turn.
    const green_tests =
        "   Compiling zygos v0.1.0\n    Finished test target(s) in 2.3s\nrunning 4 tests\n" ++
        "test a::b ... ok\ntest c::d ... ok\ntest e::f ... ok\ntest g::h ... ok\n" ++
        "test result: ok. 4 passed; 0 failed\n";
    const ls_out =
        "total 96\n" ++
        "-rw-r--r--   1 msaglietto  staff   1024 Aug  5 12:00 actor.zig\n" ++
        "-rw-r--r--   1 msaglietto  staff   2048 Aug  5 12:00 catalog.zig\n" ++
        "-rw-r--r--   1 msaglietto  staff   4096 Aug  5 12:00 protocol.zig\n" ++
        "-rw-r--r--   1 msaglietto  staff   8192 Aug  5 12:00 invocation.zig\n";

    const corpus = [_]struct { out: []const u8, cmd: []const u8 }{
        .{ .out = e2e_diff, .cmd = "git diff HEAD~1" },
        .{ .out = green_tests, .cmd = "cargo test" },
        .{ .out = ls_out, .cmd = "ls -la src/kernel" },
    };
    for (corpus) |c| {
        const req = try compressReq(testing.allocator, c.out, "bash", c.cmd);
        defer testing.allocator.free(req);
        const res = try h.caller.call("zygos::output::compress", req);
        defer res.deinit(testing.allocator);
        try testing.expect(res == .ok);
    }

    const s = try h.caller.call("zygos::output::stats", "{}");
    defer s.deinit(testing.allocator);
    try testing.expect(s == .ok);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const root = try json.parseFromSliceLeaky(json.Value, arena_state.allocator(), s.ok, .{});
    const raw_bytes: usize = @intCast(root.object.get("raw_bytes").?.integer);
    const sent_bytes: usize = @intCast(root.object.get("sent_bytes").?.integer);
    try testing.expectEqual(@as(i64, 3), root.object.get("calls").?.integer);
    try testing.expectEqual(@as(i64, 3), root.object.get("filtered").?.integer);

    // S8-exit: ≥60% fewer bytes reach the model over the fixture corpus.
    // Reported on failure so a regression shows the real ratio, not just red.
    if (sent_bytes * 100 >= raw_bytes * 40) {
        std.debug.print("\nM8 ratio regressed: {d} -> {d} bytes\n", .{ raw_bytes, sent_bytes });
    }
    try testing.expect(sent_bytes * 100 < raw_bytes * 40);
}

test "M8: no leaks across many filtered calls" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const tw = try TrimWorker.start(testing.allocator, &h.actor, &h.registry, .{}, "leak-scope");
    defer tw.stop();

    for (0..40) |i| {
        var cb: [64]u8 = undefined;
        const cmd = try std.fmt.bufPrint(&cb, "git diff HEAD~{d}", .{i});
        const req = try compressReq(testing.allocator, e2e_diff, "bash", cmd);
        defer testing.allocator.free(req);
        const res = try h.caller.call("zygos::output::compress", req);
        defer res.deinit(testing.allocator);
        try testing.expect(res == .ok);
    }
}

test "M8: the bash tool's JSON envelope does not defeat the filters" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const tw = try TrimWorker.start(testing.allocator, &h.actor, &h.registry, .{}, null);
    defer tw.stop();

    // What `zygos::tools::bash` actually replies with: the output wrapped in
    // an envelope. Without unwrapping, `looksStructured` skips every filter
    // and M8 is dead on the real path (caught by test/e2e/m8).
    const envelope = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"exit_code\":0,\"output\":{f}}}",
        .{json.fmt(e2e_diff, .{})},
    );
    defer testing.allocator.free(envelope);

    const req = try compressReq(testing.allocator, envelope, "bash", "git diff HEAD~1");
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::output::compress", req);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);

    // Filtered...
    try testing.expect(std.mem.indexOf(u8, res.ok, "zygos diff:") != null);
    try testing.expect(std.mem.indexOf(u8, res.ok, "new_shape_with_context") != null);
    try testing.expect(std.mem.indexOf(u8, res.ok, "index 1a2b3c4") == null);
    // ...while the envelope itself survives: the driver's contract with the
    // model is the tool's reply shape, not our compression detail.
    try testing.expect(std.mem.indexOf(u8, res.ok, "exit_code") != null);
    try testing.expect(res.ok.len < req.len / 2);
}

test "M8: a non-envelope JSON tool result is still left alone" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const tw = try TrimWorker.start(testing.allocator, &h.actor, &h.registry, .{}, null);
    defer tw.stop();

    // No "output" string field ⇒ genuine structured data ⇒ untouched.
    const payload = "{\"results\":[{\"url\":\"https://example.com\",\"title\":\"" ++ "t" ** 120 ++ "\"}]}";
    const req = try compressReq(testing.allocator, payload, "bash", "git diff");
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::output::compress", req);
    defer res.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, res.ok, "example.com") != null);
    try testing.expect(std.mem.indexOf(u8, res.ok, "zygos diff:") == null);
}

test "M8: web_fetch's text envelope is unwrapped too (RADAR profile)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const tw = try TrimWorker.start(testing.allocator, &h.actor, &h.registry, tiny, null);
    defer tw.stop();

    // `zygos::tools::web_fetch` replies {"url":...,"text":...,"truncated":...}.
    // Without unwrapping, the whole reply is one escaped line and the generic
    // trim can only cut it mid-token.
    var article: std.ArrayList(u8) = .empty;
    defer article.deinit(testing.allocator);
    for (0..60) |i| {
        var lb: [64]u8 = undefined;
        try article.appendSlice(testing.allocator, try std.fmt.bufPrint(&lb, "paragraph line {d}\n", .{i}));
    }
    const envelope = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"url\":\"https://example.com\",\"text\":{f},\"truncated\":false}}",
        .{json.fmt(article.items, .{})},
    );
    defer testing.allocator.free(envelope);

    const req = try compressReq(testing.allocator, envelope, "web_fetch", "");
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::output::compress", req);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);

    // The URL and shape survive; the body was trimmed line-wise, not
    // byte-sliced through the middle of the JSON.
    try testing.expect(std.mem.indexOf(u8, res.ok, "https://example.com") != null);
    try testing.expect(std.mem.indexOf(u8, res.ok, "truncated") != null);
    try testing.expect(std.mem.indexOf(u8, res.ok, "zygos trimmed") != null);
    try testing.expect(std.mem.indexOf(u8, res.ok, "paragraph line 0") != null);
    try testing.expect(res.ok.len < req.len);

    // The real requirement: what reaches the model is still parseable. A
    // generic byte-slice through an escaped envelope satisfies every
    // assertion above while handing the model broken JSON.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try json.parseFromSliceLeaky(json.Value, arena, res.ok, .{});
    const content = root.object.get("content").?.string;
    const inner = json.parseFromSliceLeaky(json.Value, arena, content, .{}) catch
        return error.TrimmedEnvelopeIsNotValidJson;
    try testing.expect(inner == .object);
    try testing.expectEqualStrings("https://example.com", inner.object.get("url").?.string);
    try testing.expect(inner.object.get("text").? == .string);
}

test "M8: oversized structured JSON is never cut into invalid JSON" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const tw = try TrimWorker.start(testing.allocator, &h.actor, &h.registry, tiny, null);
    defer tw.stop();

    // `zygos::tools::web_search` replies {"results":[{title,url,snippet}...]}
    // — structured, with no output/text/content field to unwrap. The generic
    // trim would byte-slice it and hand the model unparseable JSON.
    var results: std.ArrayList(u8) = .empty;
    defer results.deinit(testing.allocator);
    try results.appendSlice(testing.allocator, "{\"results\":[");
    for (0..40) |i| {
        var lb: [256]u8 = undefined;
        const item = try std.fmt.bufPrint(
            &lb,
            "{s}{{\"title\":\"Result number {d}\",\"url\":\"https://example.com/{d}\"," ++
                "\"snippet\":\"A snippet of text for result {d} with some padding.\"}}",
            .{ if (i == 0) "" else ",", i, i, i },
        );
        try results.appendSlice(testing.allocator, item);
    }
    try results.appendSlice(testing.allocator, "]}");

    const req = try compressReq(testing.allocator, results.items, "web_search", "");
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::output::compress", req);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try json.parseFromSliceLeaky(json.Value, arena, res.ok, .{});
    const content = root.object.get("content").?.string;
    const inner = json.parseFromSliceLeaky(json.Value, arena, content, .{}) catch
        return error.StructuredJsonWasCutIntoInvalidJson;
    try testing.expect(inner == .object);
    try testing.expect(inner.object.get("results").? == .array);
}

test "M8: structured-JSON truncation keeps entries whole and counts the rest" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const tw = try TrimWorker.start(testing.allocator, &h.actor, &h.registry, tiny, null);
    defer tw.stop();

    var results: std.ArrayList(u8) = .empty;
    defer results.deinit(testing.allocator);
    try results.appendSlice(testing.allocator, "{\"results\":[");
    for (0..30) |i| {
        var lb: [128]u8 = undefined;
        try results.appendSlice(testing.allocator, try std.fmt.bufPrint(
            &lb,
            "{s}{{\"url\":\"https://example.com/{d}\",\"title\":\"Entry {d}\"}}",
            .{ if (i == 0) "" else ",", i, i },
        ));
    }
    try results.appendSlice(testing.allocator, "]}");

    const req = try compressReq(testing.allocator, results.items, "web_search", "");
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::output::compress", req);
    defer res.deinit(testing.allocator);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const content = (try json.parseFromSliceLeaky(json.Value, arena, res.ok, .{}))
        .object.get("content").?.string;
    const inner = try json.parseFromSliceLeaky(json.Value, arena, content, .{});
    const items = inner.object.get("results").?.array.items;

    // Kept entries are whole objects, never half-serialized fragments.
    try testing.expect(items.len >= 2);
    try testing.expect(items[0] == .object);
    try testing.expect(items[0].object.get("url").? == .string);
    // The tail is an honest count, not silence.
    const last = items[items.len - 1];
    try testing.expect(last == .string);
    try testing.expect(std.mem.indexOf(u8, last.string, "zygos dropped") != null);
    try testing.expect(content.len <= tiny.max_bytes);
}

test "M8: structured JSON under the limit is byte-identical" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const tw = try TrimWorker.start(testing.allocator, &h.actor, &h.registry, .{}, null);
    defer tw.stop();

    const small = "{\"results\":[{\"url\":\"https://example.com\",\"title\":\"Only one\"}]}";
    const req = try compressReq(testing.allocator, small, "web_search", "");
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::output::compress", req);
    defer res.deinit(testing.allocator);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const content = (try json.parseFromSliceLeaky(json.Value, arena_state.allocator(), res.ok, .{}))
        .object.get("content").?.string;
    try testing.expectEqualStrings(small, content);
}

test "M8: multi-array JSON falls back rather than guessing which to cut" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Two arrays: which one is the payload is ambiguous, so structured
    // truncation declines and the generic path takes over.
    const two = "{\"a\":[1,2,3],\"b\":[4,5,6]}";
    try testing.expect(try TrimWorker.truncateJsonArray(arena, two, 10) == null);
    // A single array is handled.
    const one = "{\"a\":[1,2,3,4,5,6,7,8,9,10]}";
    try testing.expect(try TrimWorker.truncateJsonArray(arena, one, 20) != null);
}
