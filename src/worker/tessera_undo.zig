//! Tessera undo worker (W5, docs/specs/tessera-undo.md). Shadow-git
//! checkpoint/undo over a config-rooted vault: one mutex-serialized pair of
//! bus handlers shell out to system `git` via tools_ops.bash. The shadow repo
//! lives at `<root>/.zygos-shadow` so the vault never gains a visible `.git`.

const std = @import("std");
const json = std.json;
const actor_mod = @import("../kernel/actor.zig");
const inproc = @import("../kernel/inproc.zig");
const sync = @import("../kernel/sync.zig");
const ops = @import("tools_ops.zig");

pub const Config = struct {
    root: []const u8,
    /// Deadline for each git call. A call past it fails the handler (fail
    /// closed, never success). Missions call with a 1 h bus timeout, so the
    /// default stays at the shell's own 120 s.
    git_timeout_ms: u32 = 120_000,
};

pub const UndoWorker = struct {
    gpa: std.mem.Allocator,
    worker: *inproc.Worker,
    config: Config,
    ws: ops.Workspace,
    mutex: sync.Mutex = .{},

    pub fn start(
        gpa: std.mem.Allocator,
        actor: *actor_mod.Actor,
        registry: *inproc.Registry,
        config: Config,
    ) !*UndoWorker {
        const self = try gpa.create(UndoWorker);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .worker = try inproc.Worker.spawn(gpa, actor, registry, "tessera-undo"),
            .config = config,
            .ws = ops.Workspace.init(config.root),
        };
        self.ws.shell_timeout_ms = config.git_timeout_ms;
        errdefer self.worker.stop();
        try self.worker.registerFunction("zygos::tessera::checkpoint", self, &checkpointHandler);
        try self.worker.registerFunction("zygos::tessera::undo", self, &undoHandler);
        return self;
    }

    pub fn stop(self: *UndoWorker) void {
        self.worker.stop();
        self.mutex.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    fn checkpointHandler(ctx: ?*anyopaque, arena: std.mem.Allocator, request_json: []const u8) error{ Failed, OutOfMemory }![]const u8 {
        const self: *UndoWorker = @ptrCast(@alignCast(ctx.?));
        const label = try parseLabel(arena, request_json);

        self.mutex.lock();
        defer self.mutex.unlock();

        try self.ensureShadow();
        try self.gitOk("add -A");
        // -c flags must precede the subcommand; label is already shell-safe.
        const commit_args = std.fmt.allocPrint(
            self.gpa,
            "-c user.name=zygos -c user.email=zygos@local commit --allow-empty -m '{s}'",
            .{label},
        ) catch return error.OutOfMemory;
        defer self.gpa.free(commit_args);
        try self.gitOk(commit_args);

        const sha = try self.gitOut(arena, "rev-parse HEAD");
        return std.fmt.allocPrint(arena, "{{\"checkpoint_id\":{f}}}", .{json.fmt(sha, .{})});
    }

    fn undoHandler(ctx: ?*anyopaque, arena: std.mem.Allocator, request_json: []const u8) error{ Failed, OutOfMemory }![]const u8 {
        _ = request_json;
        const self: *UndoWorker = @ptrCast(@alignCast(ctx.?));

        self.mutex.lock();
        defer self.mutex.unlock();

        // No shadow / no commits → structured Failed, never a crash.
        if (!self.shadowExists()) return error.Failed;
        try self.gitOk("rev-parse --verify HEAD");
        const sha = try self.gitOut(arena, "rev-parse HEAD");
        try self.gitOk("checkout HEAD -- .");
        try self.gitOk("clean -fd");
        return std.fmt.allocPrint(arena, "{{\"restored\":{f}}}", .{json.fmt(sha, .{})});
    }

    fn ensureShadow(self: *UndoWorker) error{ Failed, OutOfMemory }!void {
        if (self.shadowExists()) return;
        try self.gitOk("init");
        // Exclude the shadow dir so add/clean never touch it.
        ops.writeFile(self.gpa, self.ws, ".zygos-shadow/info/exclude", ".zygos-shadow/\n") catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return error.Failed;
        };
    }

    fn shadowExists(self: *UndoWorker) bool {
        const r = self.shell("test -d .zygos-shadow") catch return false;
        defer self.gpa.free(r.output);
        return r.exit_code == 0;
    }

    fn gitOk(self: *UndoWorker, args: []const u8) error{ Failed, OutOfMemory }!void {
        const cmd = try gitCommand(self.gpa, args);
        defer self.gpa.free(cmd);
        try self.shellOk(cmd);
    }

    fn gitOut(self: *UndoWorker, arena: std.mem.Allocator, args: []const u8) error{ Failed, OutOfMemory }![]const u8 {
        const cmd = try gitCommand(self.gpa, args);
        defer self.gpa.free(cmd);
        const r = try self.shell(cmd);
        defer self.gpa.free(r.output);
        if (r.exit_code != 0) return error.Failed;
        return arena.dupe(u8, trimTrailingWs(r.output));
    }

    fn shellOk(self: *UndoWorker, command: []const u8) error{ Failed, OutOfMemory }!void {
        const r = try self.shell(command);
        defer self.gpa.free(r.output);
        if (r.exit_code != 0) return error.Failed;
    }

    fn shell(self: *UndoWorker, command: []const u8) error{ Failed, OutOfMemory }!ops.BashResult {
        return ops.bash(self.gpa, self.ws, command) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => {
                std.log.scoped(.tessera_undo).warn(
                    "git call failed to run or exceeded its {d} ms deadline: {s}",
                    .{ self.ws.shell_timeout_ms, command },
                );
                return error.Failed;
            },
        };
    }
};

/// One shell line for every shadow-repo git call. bash scrubs the env, so the
/// no-prompt switch rides the command string; --no-pager keeps output direct.
fn gitCommand(gpa: std.mem.Allocator, args: []const u8) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "GIT_TERMINAL_PROMPT=0 git --no-pager --git-dir=.zygos-shadow --work-tree=. {s}",
        .{args},
    );
}

/// Label rides a shell command line: keep only [A-Za-z0-9 ._-], cap 80.
/// Empty/absent input ⇒ "checkpoint".
fn parseLabel(arena: std.mem.Allocator, request_json: []const u8) error{ Failed, OutOfMemory }![]const u8 {
    const root = json.parseFromSliceLeaky(json.Value, arena, request_json, .{}) catch return error.Failed;
    if (root != .object) return error.Failed;

    const raw: []const u8 = blk: {
        const v = root.object.get("label") orelse break :blk "";
        break :blk if (v == .string) v.string else "";
    };

    var buf: [80]u8 = undefined;
    var n: usize = 0;
    for (raw) |ch| {
        if (n >= 80) break;
        const ok = (ch >= 'A' and ch <= 'Z') or
            (ch >= 'a' and ch <= 'z') or
            (ch >= '0' and ch <= '9') or
            ch == ' ' or ch == '.' or ch == '_' or ch == '-';
        if (ok) {
            buf[n] = ch;
            n += 1;
        }
    }
    if (n == 0) return "checkpoint";
    return arena.dupe(u8, buf[0..n]);
}

fn trimTrailingWs(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0) {
        const ch = s[end - 1];
        if (ch != '\n' and ch != '\r' and ch != ' ' and ch != '\t') break;
        end -= 1;
    }
    return s[0..end];
}

// ===========================================================================
// Tests (docs/specs/tessera-undo.md — Test contract, RED first)
// ===========================================================================

const testing = std.testing;

extern "c" fn realpath(path: [*:0]const u8, resolved: [*]u8) ?[*:0]u8;

fn monotonicNs() i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

const Harness = struct {
    registry: inproc.Registry,
    actor: actor_mod.Actor,
    kernel: std.Thread,
    undo: *UndoWorker,
    caller: *inproc.Worker,
    tmp: std.testing.TmpDir,
    root_buf: [std.fs.max_path_bytes]u8 = undefined,
    root: []const u8 = undefined,
    ws: ops.Workspace = undefined,

    fn init(gpa: std.mem.Allocator) !*Harness {
        const self = try gpa.create(Harness);
        errdefer gpa.destroy(self);
        self.tmp = std.testing.tmpDir(.{});
        var rel_buf: [std.fs.max_path_bytes]u8 = undefined;
        const rel = try std.fmt.bufPrintZ(&rel_buf, ".zig-cache/tmp/{s}", .{self.tmp.sub_path});
        const resolved = realpath(rel, &self.root_buf) orelse return error.RealpathFailed;
        self.root = std.mem.span(resolved);
        self.ws = ops.Workspace.init(self.root);

        // Minimal vault content so first add/commit has something real.
        try ops.writeFile(gpa, self.ws, "note.txt", "original\n");

        self.registry = inproc.Registry.init(gpa, null);
        self.actor = try actor_mod.Actor.init(gpa, .{}, self.registry.outbound());
        self.kernel = try std.Thread.spawn(.{}, actor_mod.Actor.run, .{&self.actor});
        self.undo = try UndoWorker.start(gpa, &self.actor, &self.registry, .{
            .root = self.root,
            // The stall in #15 was 9 tests times the 120 s default deadline; a
            // recurrence must fail in seconds.
            .git_timeout_ms = 10_000,
        });
        self.caller = try inproc.Worker.spawn(gpa, &self.actor, &self.registry, "test-caller");
        return self;
    }

    fn deinit(self: *Harness) void {
        const gpa = self.actor.gpa;
        self.caller.stop();
        self.undo.stop();
        self.actor.post(.shutdown);
        self.kernel.join();
        self.actor.deinit();
        self.registry.deinit();
        self.tmp.cleanup();
        gpa.destroy(self);
    }

    fn checkpoint(self: *Harness, body: []const u8) !inproc.CallResult {
        return self.caller.call("zygos::tessera::checkpoint", body);
    }

    fn undoCall(self: *Harness) !inproc.CallResult {
        return self.caller.call("zygos::tessera::undo", "{}");
    }

    fn readNote(self: *Harness) ![]u8 {
        return ops.readFile(testing.allocator, self.ws, "note.txt");
    }

    fn writeNote(self: *Harness, bytes: []const u8) !void {
        try ops.writeFile(testing.allocator, self.ws, "note.txt", bytes);
    }

    fn bash(self: *Harness, cmd: []const u8) !ops.BashResult {
        return ops.bash(testing.allocator, self.ws, cmd);
    }

    /// Run a shadow-repo git call the way the worker builds it.
    fn git(self: *Harness, args: []const u8) !ops.BashResult {
        const cmd = try gitCommand(testing.allocator, args);
        defer testing.allocator.free(cmd);
        return self.bash(cmd);
    }
};

fn parseOk(payload: []const u8) !struct {
    parsed: json.Parsed(json.Value),
    fn deinit(self: *@This()) void {
        self.parsed.deinit();
    }
    fn root(self: *@This()) json.Value {
        return self.parsed.value;
    }
} {
    return .{ .parsed = try json.parseFromSlice(json.Value, testing.allocator, payload, .{}) };
}

fn expectSha(s: []const u8) !void {
    try testing.expect(s.len >= 7);
    for (s) |ch| {
        const hex = (ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F');
        try testing.expect(hex);
    }
}

test "first checkpoint initializes the shadow repo and returns a sha" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const res = try h.checkpoint("{}");
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);

    var p = try parseOk(res.ok);
    defer p.deinit();
    const sha = p.root().object.get("checkpoint_id").?.string;
    try expectSha(sha);

    const check = try h.bash("test -d .zygos-shadow");
    defer testing.allocator.free(check.output);
    try testing.expectEqual(@as(i32, 0), check.exit_code);
}

test "checkpoint → modify a file → undo restores the original bytes" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const cp = try h.checkpoint("{}");
    defer cp.deinit(testing.allocator);
    try testing.expect(cp == .ok);

    try h.writeNote("mutated\n");
    const mid = try h.readNote();
    defer testing.allocator.free(mid);
    try testing.expectEqualStrings("mutated\n", mid);

    const und = try h.undoCall();
    defer und.deinit(testing.allocator);
    try testing.expect(und == .ok);

    const got = try h.readNote();
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("original\n", got);
}

test "checkpoint → create a new file → undo removes it" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const cp = try h.checkpoint("{}");
    defer cp.deinit(testing.allocator);
    try testing.expect(cp == .ok);

    try ops.writeFile(testing.allocator, h.ws, "extra.txt", "new\n");

    const und = try h.undoCall();
    defer und.deinit(testing.allocator);
    try testing.expect(und == .ok);

    const gone = ops.readFile(testing.allocator, h.ws, "extra.txt");
    try testing.expectError(error.NotFound, gone);
}

test "checkpoint → delete a file → undo brings it back" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const cp = try h.checkpoint("{}");
    defer cp.deinit(testing.allocator);
    try testing.expect(cp == .ok);

    // Remove tracked note via shell (tools_ops has no delete).
    const rm = try h.bash("rm -f note.txt");
    defer testing.allocator.free(rm.output);
    try testing.expectEqual(@as(i32, 0), rm.exit_code);

    const und = try h.undoCall();
    defer und.deinit(testing.allocator);
    try testing.expect(und == .ok);

    const got = try h.readNote();
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("original\n", got);
}

test "undo with no shadow repo is error.Failed (structured, no crash)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const und = try h.undoCall();
    defer und.deinit(testing.allocator);
    try testing.expect(und == .err);
    try testing.expectEqualStrings("handler_failed", und.err);
}

test "two checkpoints then undo restores the SECOND (most recent) state" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const c1 = try h.checkpoint("{\"label\":\"first\"}");
    defer c1.deinit(testing.allocator);
    try testing.expect(c1 == .ok);

    try h.writeNote("second\n");
    const c2 = try h.checkpoint("{\"label\":\"second\"}");
    defer c2.deinit(testing.allocator);
    try testing.expect(c2 == .ok);

    try h.writeNote("third\n");

    const und = try h.undoCall();
    defer und.deinit(testing.allocator);
    try testing.expect(und == .ok);

    const got = try h.readNote();
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("second\n", got);

    var p = try parseOk(und.ok);
    defer p.deinit();
    var p2 = try parseOk(c2.ok);
    defer p2.deinit();
    try testing.expectEqualStrings(
        p2.root().object.get("checkpoint_id").?.string,
        p.root().object.get("restored").?.string,
    );
}

test "label with shell metacharacters is sanitized (commit succeeds, message stripped)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const res = try h.checkpoint("{\"label\":\"evil; rm -rf / #boom\"}");
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);

    const log = try h.git("log -1 --format=%s");
    defer testing.allocator.free(log.output);
    try testing.expectEqual(@as(i32, 0), log.exit_code);
    const msg = trimTrailingWs(log.output);
    // Metacharacters stripped; alphanumerics + spaces remain.
    try testing.expectEqualStrings("evil rm -rf  boom", msg);
    try testing.expect(std.mem.indexOfScalar(u8, msg, ';') == null);
    try testing.expect(std.mem.indexOfScalar(u8, msg, '#') == null);
}

test ".zygos-shadow/ itself is never tracked nor cleaned" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const cp = try h.checkpoint("{}");
    defer cp.deinit(testing.allocator);
    try testing.expect(cp == .ok);

    const ls = try h.git("ls-files");
    defer testing.allocator.free(ls.output);
    try testing.expectEqual(@as(i32, 0), ls.exit_code);
    try testing.expect(std.mem.indexOf(u8, ls.output, ".zygos-shadow") == null);

    try ops.writeFile(testing.allocator, h.ws, "ephemeral.txt", "x\n");
    const und = try h.undoCall();
    defer und.deinit(testing.allocator);
    try testing.expect(und == .ok);

    const still = try h.bash("test -d .zygos-shadow && test -f .zygos-shadow/HEAD");
    defer testing.allocator.free(still.output);
    try testing.expectEqual(@as(i32, 0), still.exit_code);
}

test "no leaks" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const cp = try h.checkpoint("{}");
        cp.deinit(testing.allocator);
        try h.writeNote("loop\n");
        const und = try h.undoCall();
        und.deinit(testing.allocator);
    }
}

test "gitCommand: every git call disables terminal prompts and the pager" {
    const cmd = try gitCommand(testing.allocator, "ls-files");
    defer testing.allocator.free(cmd);
    try testing.expect(std.mem.startsWith(u8, cmd, "GIT_TERMINAL_PROMPT=0 git --no-pager "));
    try testing.expect(std.mem.endsWith(u8, cmd, "ls-files"));
}

test "a git hook that reads stdin cannot stall checkpoint" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const first = try h.checkpoint("{}");
    defer first.deinit(testing.allocator);
    try testing.expect(first == .ok);

    // Git hands pre-commit and friends /dev/null; the fsmonitor hook is run
    // with whatever stdin git itself has, so it is the one that can block.
    try ops.writeFile(testing.allocator, h.ws, ".zygos-shadow/fsmonitor.sh", "#!/bin/sh\ncat >/dev/null\n");
    const config = try h.git("config core.fsmonitor 'sh .zygos-shadow/fsmonitor.sh'");
    defer testing.allocator.free(config.output);
    try testing.expectEqual(@as(i32, 0), config.exit_code);

    const held = try ops.HeldStdin.begin();
    defer held.end();

    const second = try h.checkpoint("{}");
    defer second.deinit(testing.allocator);
    if (second != .ok) {
        std.debug.print("checkpoint failed: a git hook blocked on stdin until the {d} ms deadline\n", .{h.undo.ws.shell_timeout_ms});
    }
    try testing.expect(second == .ok);
}

test "a git call past its deadline fails the handler (fail closed)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const first = try h.checkpoint("{}");
    defer first.deinit(testing.allocator);
    try testing.expect(first == .ok);
    // Shrink the deadline only now: the first checkpoint needs the full 10 s.
    h.undo.ws.shell_timeout_ms = 300;

    try ops.writeFile(testing.allocator, h.ws, ".zygos-shadow/hooks/pre-commit", "#!/bin/sh\nsleep 30\n");
    const chmod = try h.bash("chmod +x .zygos-shadow/hooks/pre-commit");
    defer testing.allocator.free(chmod.output);
    try testing.expectEqual(@as(i32, 0), chmod.exit_code);

    const started = monotonicNs();
    const second = try h.checkpoint("{}");
    defer second.deinit(testing.allocator);
    const elapsed_ns = monotonicNs() - started;

    try testing.expect(second == .err);
    try testing.expectEqualStrings("handler_failed", second.err);
    try testing.expect(elapsed_ns < 10 * std.time.ns_per_s);
}
