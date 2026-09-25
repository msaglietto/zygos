//! ThreadStrategy (M5): narrow / deep context for the factory workload.
//! Durable per-task threads (the executor transcript carry, generalized):
//! every executor outcome appends to `<dir>/threads/task-<n>.jsonl`; the
//! next attempt on that task sees the recent entries verbatim and the older
//! ones summarized (compaction inside the strategy — the raw entries stay
//! on disk until the thread itself compacts, and the full text always
//! remains in the trace). Pinned decisions (`DECISIONS.md` in the strategy
//! dir) survive every step of every role. A codebase-state digest (file
//! map + recent history via shell-out `git`) rides executor steps through
//! an injected CmdRunner vtable — tests never fork.

const std = @import("std");
const jsonx = @import("jsonx.zig");
const fsx = @import("fsx.zig");
const mkdirQuiet = fsx.mkdirQuiet;
const readWholeFile = fsx.readWholeFile;

const json = std.json;
const context = @import("context.zig");
const substrate_mod = @import("context_substrate.zig");

pub const CmdRunner = struct {
    ctx: *anyopaque,
    /// Run `argv`, return stdout (arena-owned) or null on any failure —
    /// digest assembly is fail-open, a broken git never fails a step.
    /// `limit` caps stdout bytes; null reads until EOF. A capped child that
    /// dies on SIGPIPE still returns the bytes already read.
    runFn: *const fn (ctx: *anyopaque, arena: std.mem.Allocator, argv: []const []const u8, limit: ?usize) ?[]const u8,

    pub fn run(self: CmdRunner, arena: std.mem.Allocator, argv: []const []const u8, limit: ?usize) ?[]const u8 {
        return self.runFn(self.ctx, arena, argv, limit);
    }
};

pub const Options = struct {
    /// Thread entries kept verbatim; older ones summarize.
    keep_verbatim: usize = 6,
    per_entry_bytes: usize = 2048,
    digest_bytes: usize = 2048,
    decisions_bytes: usize = 4096,
    now_fn: *const fn () i64 = &wallNow,
};

pub const Entry = struct {
    role: []const u8,
    ok: bool,
    text: []const u8,
    stamp_ms: i64,
};

/// One entry as a JSONL line (no trailing newline).
pub fn entryLine(arena: std.mem.Allocator, e: Entry) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "{{\"role\":{f},\"ok\":{},\"text\":{f},\"ts\":{d}}}",
        .{ json.fmt(e.role, .{}), e.ok, json.fmt(e.text, .{}), e.stamp_ms },
    );
}

/// Tolerant: null for malformed lines (skipped, never fatal).
pub fn parseEntryLine(arena: std.mem.Allocator, line: []const u8) ?Entry {
    const v = json.parseFromSliceLeaky(json.Value, arena, line, .{}) catch return null;
    if (v != .object) return null;
    const role = strField(v.object, "role") orelse return null;
    const text = strField(v.object, "text") orelse return null;
    const ok = if (v.object.get("ok")) |b| b == .bool and b.bool else false;
    const ts = intField(v.object, "ts") orelse 0;
    return .{ .role = role, .ok = ok, .text = text, .stamp_ms = ts };
}

pub const ThreadStrategy = struct {
    gpa: std.mem.Allocator,
    dir: []u8,
    workspace: []u8,
    opts: Options,
    runner: ?CmdRunner,

    pub fn create(
        gpa: std.mem.Allocator,
        dir: []const u8,
        workspace: []const u8,
        runner: ?CmdRunner,
        opts: Options,
    ) error{OutOfMemory}!*ThreadStrategy {
        const self = try gpa.create(ThreadStrategy);
        errdefer gpa.destroy(self);
        const dir_copy = try gpa.dupe(u8, dir);
        errdefer gpa.free(dir_copy);
        self.* = .{
            .gpa = gpa,
            .dir = dir_copy,
            .workspace = try gpa.dupe(u8, workspace),
            .opts = opts,
            .runner = runner,
        };
        mkdirQuiet(gpa, dir);
        const threads = std.fmt.allocPrint(gpa, "{s}/threads", .{dir}) catch return error.OutOfMemory;
        defer gpa.free(threads);
        mkdirQuiet(gpa, threads);
        return self;
    }

    pub fn destroy(self: *ThreadStrategy) void {
        self.gpa.free(self.dir);
        self.gpa.free(self.workspace);
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    pub fn strategy(self: *ThreadStrategy) context.ContextStrategy {
        return .{ .ctx = @ptrCast(self), .assembleFn = &assembleImpl, .absorbFn = &absorbImpl };
    }

    fn assembleImpl(
        ctx: *anyopaque,
        arena: std.mem.Allocator,
        step: context.StepRef,
        budget: context.TokenBudget,
        diag: *context.Diag,
    ) context.Error!context.Assembled {
        const self: *ThreadStrategy = @ptrCast(@alignCast(ctx));
        const base = try substrate_mod.assembleContent(arena, step, diag);

        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(arena, base.content);
        const max = budget.max_tokens;
        const is_executor = std.mem.eql(u8, step.role, "executor");

        // Priority under budget pressure: pinned decisions, then the task
        // thread, then the codebase digest — the base spine always survives.
        if (try self.decisionsBlock(arena)) |block| appendIfFits(arena, &out, block, max);
        if (is_executor and step.mission.task_index < step.mission.tasks.len) {
            if (try self.threadBlock(arena, step.mission.task_index)) |block|
                appendIfFits(arena, &out, block, max);
        }
        if (is_executor) {
            if (self.digestBlock(arena)) |block| appendIfFits(arena, &out, block, max);
        }
        return .{ .content = out.items };
    }

    fn absorbImpl(ctx: *anyopaque, step: context.StepRef, outcome: context.Outcome) context.Error!void {
        const self: *ThreadStrategy = @ptrCast(@alignCast(ctx));
        // Per-task threads are the executor carry; other roles' state lives
        // in the planning artifacts already.
        if (!std.mem.eql(u8, outcome.role, "executor")) return;
        const m = step.mission;
        if (m.task_index >= m.tasks.len) return;

        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const path = try std.fmt.allocPrint(arena, "{s}/threads/task-{d}.jsonl", .{ self.dir, m.task_index });
        const line = try entryLine(arena, .{
            .role = outcome.role,
            .ok = outcome.ok,
            .text = try capUtf8(arena, outcome.text, self.opts.per_entry_bytes),
            .stamp_ms = self.opts.now_fn(),
        });
        // Append-only: the raw entries stay on disk; assemble summarizes the
        // old tail at read time (deterministic, resume-parity-safe).
        appendLine(self.gpa, path, line);
    }

    fn decisionsBlock(self: *ThreadStrategy, arena: std.mem.Allocator) error{OutOfMemory}!?[]const u8 {
        const path = try std.fmt.allocPrint(arena, "{s}/DECISIONS.md", .{self.dir});
        const text = readWholeFile(arena, path) orelse return null;
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) return null;
        return try std.fmt.allocPrint(arena, "\nPinned decisions:\n{s}\n", .{
            try capUtf8(arena, trimmed, self.opts.decisions_bytes),
        });
    }

    fn threadBlock(self: *ThreadStrategy, arena: std.mem.Allocator, task_index: usize) error{OutOfMemory}!?[]const u8 {
        const path = try std.fmt.allocPrint(arena, "{s}/threads/task-{d}.jsonl", .{ self.dir, task_index });
        const text = readWholeFile(arena, path) orelse return null;
        var entries: std.ArrayList(Entry) = .empty;
        var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const e = parseEntryLine(arena, line) orelse continue;
            try entries.append(arena, e);
        }
        if (entries.items.len == 0) return null;

        var w: std.Io.Writer.Allocating = .init(arena);
        w.writer.writeAll("\nTask thread (previous work on this task):\n") catch return error.OutOfMemory;
        const keep = self.opts.keep_verbatim;
        const older = if (entries.items.len > keep) entries.items[0 .. entries.items.len - keep] else &[_]Entry{};
        const recent = entries.items[entries.items.len - @min(keep, entries.items.len) ..];
        if (older.len > 0) {
            w.writer.writeAll("Earlier attempts (summarized):\n") catch return error.OutOfMemory;
            for (older) |e| {
                w.writer.print("- [{s}] {s}\n", .{
                    if (e.ok) "ok" else "failed",
                    try headline(arena, e.text, 120),
                }) catch return error.OutOfMemory;
            }
        }
        for (recent) |e| {
            w.writer.print("[attempt {s}]\n{s}\n", .{
                if (e.ok) "ok" else "failed",
                try capUtf8(arena, e.text, self.opts.per_entry_bytes),
            }) catch return error.OutOfMemory;
        }
        return w.written();
    }

    /// File map + recent history via the injected runner; any failure omits
    /// the whole block (fail-open — a broken git never fails a step).
    fn digestBlock(self: *ThreadStrategy, arena: std.mem.Allocator) ?[]const u8 {
        const r = self.runner orelse return null;
        const files = r.run(arena, &.{ "git", "-C", self.workspace, "ls-files" }, self.opts.digest_bytes) orelse return null;
        const history = r.run(arena, &.{ "git", "-C", self.workspace, "log", "--oneline", "-5" }, self.opts.digest_bytes);
        var w: std.Io.Writer.Allocating = .init(arena);
        w.writer.writeAll("\nCodebase state:\nFiles:\n") catch return null;
        w.writer.writeAll(capUtf8(arena, std.mem.trimEnd(u8, files, "\n"), self.opts.digest_bytes) catch return null) catch return null;
        w.writer.writeAll("\n") catch return null;
        if (history) |h| {
            w.writer.writeAll("Recent commits:\n") catch return null;
            w.writer.writeAll(capUtf8(arena, std.mem.trimEnd(u8, h, "\n"), self.opts.digest_bytes) catch return null) catch return null;
            w.writer.writeAll("\n") catch return null;
        }
        return w.written();
    }
};

/// Append `block` only when the whole result still fits the token budget.
fn appendIfFits(arena: std.mem.Allocator, out: *std.ArrayList(u8), block: []const u8, max_tokens: usize) void {
    if ((out.items.len + block.len + 3) / 4 > max_tokens) return;
    out.appendSlice(arena, block) catch {};
}

/// First line, capped — the summarized headline of an old thread entry.
fn headline(arena: std.mem.Allocator, text: []const u8, cap: usize) error{OutOfMemory}![]const u8 {
    const first = if (std.mem.indexOfScalar(u8, text, '\n')) |nl| text[0..nl] else text;
    return capUtf8(arena, first, cap);
}

/// Cap at `cap` bytes on a UTF-8 boundary with an ellipsis marker.
fn capUtf8(arena: std.mem.Allocator, text: []const u8, cap: usize) error{OutOfMemory}![]const u8 {
    if (text.len <= cap) return text;
    var end = cap;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return std.fmt.allocPrint(arena, "{s}…", .{text[0..end]});
}

// ---------------------------------------------------------------------------
// libc plumbing (Z-02: no std.Io in workers)
// ---------------------------------------------------------------------------

fn wallNow() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn appendLine(gpa: std.mem.Allocator, path: []const u8, line: []const u8) void {
    const path_z = std.fmt.allocPrintSentinel(gpa, "{s}", .{path}, 0) catch return;
    defer gpa.free(path_z);
    const f = std.c.fopen(path_z.ptr, "a") orelse return;
    defer _ = std.c.fclose(f);
    _ = std.c.fwrite(line.ptr, 1, line.len, f);
    _ = std.c.fwrite("\n", 1, 1, f);
}

extern "c" fn popen(command: [*:0]const u8, mode: [*:0]const u8) ?*std.c.FILE;
extern "c" fn pclose(stream: *std.c.FILE) c_int;

/// Default runner: /bin/sh -c via popen. argv joins with spaces — callers
/// pass fixed git invocations, never user input.
pub const PopenRunner = struct {
    pub fn run(ctx: *anyopaque, arena: std.mem.Allocator, argv: []const []const u8, limit: ?usize) ?[]const u8 {
        _ = ctx;
        var cmd: std.ArrayList(u8) = .empty;
        for (argv, 0..) |a, i| {
            if (i > 0) cmd.append(arena, ' ') catch return null;
            cmd.appendSlice(arena, a) catch return null;
        }
        cmd.appendSlice(arena, " 2>/dev/null") catch return null;
        const cmd_z = std.fmt.allocPrintSentinel(arena, "{s}", .{cmd.items}, 0) catch return null;
        const f = popen(cmd_z.ptr, "r") orelse return null;
        var buf: std.ArrayList(u8) = .empty;
        var chunk: [4096]u8 = undefined;
        const cap = limit orelse std.math.maxInt(usize);
        while (buf.items.len < cap) {
            const room = cap - buf.items.len;
            const want = @min(chunk.len, room);
            const n = std.c.fread(&chunk, 1, want, f);
            if (n == 0) break;
            buf.appendSlice(arena, chunk[0..n]) catch break;
        }
        const hit_cap = limit != null and buf.items.len >= limit.?;
        const status = pclose(f);
        // A cap closes the pipe early; the child may die with SIGPIPE.
        // That is the stop, not a failed command. A real failure with no
        // capped bytes is still a failure.
        if (!hit_cap and status != 0) return null;
        return buf.items;
    }

    pub fn runner() CmdRunner {
        return .{ .ctx = @ptrCast(@constCast(&{})), .runFn = &run };
    }
};

const strField = jsonx.strField;

const intField = jsonx.intField;

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

fn fixedNow() i64 {
    return 1_000_000_000;
}

const test_opts: Options = .{
    .keep_verbatim = 2,
    .per_entry_bytes = 256,
    .digest_bytes = 512,
    .decisions_bytes = 512,
    .now_fn = &fixedNow,
};

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

fn nullRead(ctx: *anyopaque, arena: std.mem.Allocator, name: []const u8) ?[]const u8 {
    _ = ctx;
    _ = arena;
    _ = name;
    return null;
}

const exec_tasks = struct {
    var tasks = [_]context.TaskView{
        .{ .desc = "wire the parser" },
        .{ .desc = "wire the emitter" },
    };
};

fn executorStep(task_index: usize) context.StepRef {
    return .{
        .role = "executor",
        .mission = .{
            .mission_id = "factory",
            .objective = "build the compiler",
            .tasks = &exec_tasks.tasks,
            .task_index = task_index,
        },
        .substrate = .{ .ctx = @ptrCast(@constCast(&{})), .readFn = &nullRead },
    };
}

const FakeGit = struct {
    fail: bool = false,
    calls: usize = 0,

    fn run(ctx: *anyopaque, arena: std.mem.Allocator, argv: []const []const u8, limit: ?usize) ?[]const u8 {
        _ = limit;
        const self: *FakeGit = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (self.fail) return null;
        if (std.mem.indexOf(u8, argv[argv.len - 1], "ls-files") != null or
            containsArg(argv, "ls-files"))
            return arena.dupe(u8, "src/main.zig\nsrc/parser.zig\n") catch null;
        return arena.dupe(u8, "abc1234 feat: wire lexer\n") catch null;
    }

    fn containsArg(argv: []const []const u8, needle: []const u8) bool {
        for (argv) |a| if (std.mem.eql(u8, a, needle)) return true;
        return false;
    }

    fn runner(self: *FakeGit) CmdRunner {
        return .{ .ctx = @ptrCast(self), .runFn = &run };
    }
};

test "entryLine/parseEntryLine round-trip; malformed lines are null" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const e: Entry = .{ .role = "executor", .ok = true, .text = "did the thing\n\"quoted\"", .stamp_ms = 7 };
    const line = try entryLine(arena, e);
    const back = parseEntryLine(arena, line) orelse return error.ParseFailed;
    try testing.expectEqualStrings(e.role, back.role);
    try testing.expectEqualStrings(e.text, back.text);
    try testing.expect(back.ok);
    try testing.expectEqual(e.stamp_ms, back.stamp_ms);
    try testing.expect(parseEntryLine(arena, "garbage") == null);
}

test "absorb appends to the per-task thread; the next attempt sees it verbatim" {
    var tmp = try TmpDir.init();
    defer tmp.cleanup();
    const dir = try tmp.path();
    const ts = try ThreadStrategy.create(testing.allocator, dir, ".", null, test_opts);
    defer ts.destroy();

    try ts.strategy().absorb(executorStep(0), .{
        .role = "executor",
        .ok = false,
        .text = "parser half-wired; token stream stalls on EOF",
    });

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diag: context.Diag = .{};
    const out = try ts.strategy().assemble(arena_state.allocator(), executorStep(0), .{ .max_tokens = 10_000 }, &diag);
    try testing.expect(std.mem.startsWith(u8, out.content, "Objective:\nbuild the compiler\n"));
    try testing.expect(std.mem.indexOf(u8, out.content, "Task thread") != null);
    try testing.expect(std.mem.indexOf(u8, out.content, "token stream stalls on EOF") != null);

    // A different task's thread stays empty — narrow, per-task.
    const other = try ts.strategy().assemble(arena_state.allocator(), executorStep(1), .{ .max_tokens = 10_000 }, &diag);
    try testing.expect(std.mem.indexOf(u8, other.content, "token stream stalls") == null);
}

test "older thread entries summarize; the working set stays verbatim" {
    var tmp = try TmpDir.init();
    defer tmp.cleanup();
    const dir = try tmp.path();
    const ts = try ThreadStrategy.create(testing.allocator, dir, ".", null, test_opts);
    defer ts.destroy();

    for ([_][]const u8{ "attempt one detail", "attempt two detail", "attempt three detail", "attempt four detail" }) |text| {
        try ts.strategy().absorb(executorStep(0), .{ .role = "executor", .ok = false, .text = text });
    }

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diag: context.Diag = .{};
    const out = try ts.strategy().assemble(arena_state.allocator(), executorStep(0), .{ .max_tokens = 10_000 }, &diag);
    // keep_verbatim=2: three and four verbatim, one and two summarized.
    try testing.expect(std.mem.indexOf(u8, out.content, "attempt three detail") != null);
    try testing.expect(std.mem.indexOf(u8, out.content, "attempt four detail") != null);
    try testing.expect(std.mem.indexOf(u8, out.content, "summarized") != null);
    try testing.expect(std.mem.indexOf(u8, out.content, "attempt one") != null); // headline survives
}

test "pinned DECISIONS.md rides every role's assembly" {
    var tmp = try TmpDir.init();
    defer tmp.cleanup();
    const dir = try tmp.path();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dpath = try std.fmt.allocPrint(arena, "{s}/DECISIONS.md", .{dir});
    appendLine(testing.allocator, dpath, "- 2026-07-21: parser stays recursive-descent");

    const ts = try ThreadStrategy.create(testing.allocator, dir, ".", null, test_opts);
    defer ts.destroy();
    var diag: context.Diag = .{};
    const out = try ts.strategy().assemble(arena, executorStep(0), .{ .max_tokens = 10_000 }, &diag);
    try testing.expect(std.mem.indexOf(u8, out.content, "Pinned decisions") != null);
    try testing.expect(std.mem.indexOf(u8, out.content, "recursive-descent") != null);
}

test "codebase digest rides executor steps via the injected runner; a broken git is fail-open" {
    var tmp = try TmpDir.init();
    defer tmp.cleanup();
    const dir = try tmp.path();
    var git = FakeGit{};
    const ts = try ThreadStrategy.create(testing.allocator, dir, "/repo", git.runner(), test_opts);
    defer ts.destroy();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diag: context.Diag = .{};
    const out = try ts.strategy().assemble(arena_state.allocator(), executorStep(0), .{ .max_tokens = 10_000 }, &diag);
    try testing.expect(std.mem.indexOf(u8, out.content, "Codebase state") != null);
    try testing.expect(std.mem.indexOf(u8, out.content, "src/parser.zig") != null);
    try testing.expect(std.mem.indexOf(u8, out.content, "abc1234") != null);

    var broken = FakeGit{ .fail = true };
    const ts2 = try ThreadStrategy.create(testing.allocator, dir, "/repo", broken.runner(), test_opts);
    defer ts2.destroy();
    const out2 = try ts2.strategy().assemble(arena_state.allocator(), executorStep(0), .{ .max_tokens = 10_000 }, &diag);
    try testing.expect(std.mem.indexOf(u8, out2.content, "Codebase state") == null);
    try testing.expect(std.mem.startsWith(u8, out2.content, "Objective:\n"));
}

test "blocks drop under budget pressure but the base spine always survives" {
    var tmp = try TmpDir.init();
    defer tmp.cleanup();
    const dir = try tmp.path();
    var git = FakeGit{};
    const ts = try ThreadStrategy.create(testing.allocator, dir, "/repo", git.runner(), test_opts);
    defer ts.destroy();
    try ts.strategy().absorb(executorStep(0), .{ .role = "executor", .ok = false, .text = "attempt detail" });

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diag: context.Diag = .{};
    // Base is ~30 tokens; leave just a little headroom so extras can't fit.
    const out = try ts.strategy().assemble(arena_state.allocator(), executorStep(0), .{ .max_tokens = 40 }, &diag);
    try testing.expect(std.mem.startsWith(u8, out.content, "Objective:\n"));
    try testing.expect(context.estTokens(out.content) <= 40);
}

const ReopenCtx = struct {
    gpa: std.mem.Allocator,
    dir: []const u8,
    reopened: ?*ThreadStrategy = null,

    fn reopen(ctx: *anyopaque) context.Error!context.ContextStrategy {
        const self: *ReopenCtx = @ptrCast(@alignCast(ctx));
        if (self.reopened) |old| old.destroy();
        self.reopened = try ThreadStrategy.create(self.gpa, self.dir, ".", null, test_opts);
        return self.reopened.?.strategy();
    }
};

test "ThreadStrategy passes the conformance harness with resume-from-disk parity" {
    const conformance = @import("context_conformance.zig");
    var tmp = try TmpDir.init();
    defer tmp.cleanup();
    const dir = try tmp.path();

    const ts = try ThreadStrategy.create(testing.allocator, dir, ".", null, test_opts);
    defer ts.destroy();
    var reopen_ctx = ReopenCtx{ .gpa = testing.allocator, .dir = dir };
    defer if (reopen_ctx.reopened) |r| r.destroy();

    try conformance.conform(testing.allocator, .{
        .strategy = ts.strategy(),
        .reopenFn = &ReopenCtx.reopen,
        .reopen_ctx = @ptrCast(&reopen_ctx),
    }, executorStep(0));
}

test "PopenRunner stops at the read cap and still returns those bytes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var dummy: u8 = 0;
    const capped = PopenRunner.run(@ptrCast(&dummy), arena, &.{ "dd", "if=/dev/zero", "bs=8000", "count=1" }, 100);
    const got = capped orelse return error.NoOutput;
    try testing.expectEqual(@as(usize, 100), got.len);

    const failed = PopenRunner.run(@ptrCast(&dummy), arena, &.{"false"}, null);
    try testing.expect(failed == null);
}
