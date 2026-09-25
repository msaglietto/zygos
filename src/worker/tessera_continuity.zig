//! Tessera continuity worker (W3, docs/specs/tessera-continuity.md). Session
//! open/close over a config-rooted Projects/ tree: session_open is read-only
//! seam load; session_close writes SESSIONS.md (and optional PROJECT.md action
//! promotions) via atomic tmp+rename. Optional checkpoint_function is a
//! fail-closed W5 seam — any failed/unreachable checkpoint blocks the write.

const std = @import("std");
const jsonx = @import("jsonx.zig");
const fsx = @import("fsx.zig");
const readFileOrEmpty = fsx.readFileOrEmpty;
const fileExists = fsx.fileExists;
const mkdirP = fsx.mkdirP;
const writeAtomic = fsx.writeAtomic;

const c = std.c;
const json = std.json;
const actor_mod = @import("../kernel/actor.zig");
const inproc = @import("../kernel/inproc.zig");
const vault = @import("tessera/vault.zig");
const session_writer = @import("tessera/session_writer.zig");

pub const Config = struct {
    root: []const u8,
    projects_subdir: []const u8 = "Projects",
    sessions_file: []const u8 = "SESSIONS.md",
    project_file: []const u8 = "PROJECT.md",
    /// When set, invoke this bus function (`{"label":...}`) BEFORE any write;
    /// a failed/unreachable checkpoint ⇒ error.Failed, nothing written (W5 seam,
    /// fail closed). When null, write without checkpointing.
    checkpoint_function: ?[]const u8 = null,
};

pub const ContinuityWorker = struct {
    gpa: std.mem.Allocator,
    worker: *inproc.Worker,
    config: Config,

    pub fn start(
        gpa: std.mem.Allocator,
        actor: *actor_mod.Actor,
        registry: *inproc.Registry,
        config: Config,
    ) !*ContinuityWorker {
        const self = try gpa.create(ContinuityWorker);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .worker = try inproc.Worker.spawn(gpa, actor, registry, "tessera-continuity"),
            .config = config,
        };
        errdefer self.worker.stop();
        try self.worker.registerFunction("zygos::tessera::session_open", self, &sessionOpenHandler);
        try self.worker.registerFunction("zygos::tessera::session_close", self, &sessionCloseHandler);
        return self;
    }

    pub fn stop(self: *ContinuityWorker) void {
        self.worker.stop();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    fn sessionOpenHandler(ctx: ?*anyopaque, arena: std.mem.Allocator, request_json: []const u8) error{ Failed, OutOfMemory }![]const u8 {
        const self: *ContinuityWorker = @ptrCast(@alignCast(ctx.?));
        const root = json.parseFromSliceLeaky(json.Value, arena, request_json, .{}) catch return error.Failed;
        if (root != .object) return error.Failed;
        const project = strField(root.object, "project") orelse return error.Failed;
        if (std.mem.trim(u8, project, " \t\r\n").len == 0) return error.Failed;
        if (!validProjectName(project)) return error.Failed;

        const sessions_path = try projectPath(arena, self.config, project, self.config.sessions_file);
        const sessions_text = try vault.readThroughSessions(arena, sessions_path, 1);
        const sessions = vault.parseSessions(arena, sessions_text) catch return error.OutOfMemory;

        if (sessions.len == 0) {
            return arena.dupe(u8, "{\"first_session\":true,\"context_reload\":\"First session.\",\"open_threads\":[]}");
        }

        const newest = sessions[0];
        var out: std.Io.Writer.Allocating = .init(arena);
        errdefer out.deinit();
        const w = &out.writer;
        w.print("{{\"first_session\":false,\"context_reload\":{f},\"open_threads\":", .{
            json.fmt(newest.leaving_behind, .{}),
        }) catch return error.OutOfMemory;
        try writeStringArray(w, newest.open_threads);
        w.writeAll("}") catch return error.OutOfMemory;
        return out.toOwnedSlice() catch return error.OutOfMemory;
    }

    fn sessionCloseHandler(ctx: ?*anyopaque, arena: std.mem.Allocator, request_json: []const u8) error{ Failed, OutOfMemory }![]const u8 {
        const self: *ContinuityWorker = @ptrCast(@alignCast(ctx.?));
        const root = json.parseFromSliceLeaky(json.Value, arena, request_json, .{}) catch return error.Failed;
        if (root != .object) return error.Failed;
        const obj = root.object;

        const project = strField(obj, "project") orelse return error.Failed;
        const date = strField(obj, "date") orelse return error.Failed;
        const leaving_raw = strField(obj, "leaving_behind") orelse return error.Failed;
        if (std.mem.trim(u8, project, " \t\r\n").len == 0) return error.Failed;
        if (std.mem.trim(u8, date, " \t\r\n").len == 0) return error.Failed;
        const leaving_behind = std.mem.trim(u8, leaving_raw, " \t\r\n");
        if (leaving_behind.len == 0) return error.Failed;
        if (!validProjectName(project)) return error.Failed;

        const context_reload = strField(obj, "context_reload") orelse "";
        const intention = strField(obj, "intention") orelse "";
        const accomplished = strField(obj, "accomplished") orelse "";
        const open_threads = try strArrayField(arena, obj, "open_threads");
        const log = try strArrayField(arena, obj, "log");
        const actions = try strArrayField(arena, obj, "actions");

        // Fail-closed checkpoint seam (W5): call before any write.
        if (self.config.checkpoint_function) |fn_id| {
            try self.callCheckpoint(arena, fn_id, project);
        }

        const sessions_path = try projectPath(arena, self.config, project, self.config.sessions_file);
        const project_dir = try projectDirPath(arena, self.config, project);
        try mkdirP(self.gpa, project_dir);

        const existing_sessions = try readFileOrEmpty(arena, sessions_path);
        const prior = vault.parseSessions(arena, existing_sessions) catch return error.OutOfMemory;
        const first_session = prior.len == 0;
        const file_existed = fileExists(sessions_path);

        const entry = session_writer.Entry{
            .date = date,
            .context_reload = context_reload,
            .intention = intention,
            .log = log,
            .accomplished = accomplished,
            .leaving_behind = leaving_behind,
            .open_threads = open_threads,
        };
        const block = try session_writer.renderEntry(arena, entry);
        const sessions_out = if (file_existed)
            try session_writer.prependEntry(arena, existing_sessions, block)
        else
            try session_writer.initialSessionsFile(arena, project, block);
        try writeAtomic(self.gpa, sessions_path, sessions_out);

        var promoted: usize = 0;
        if (actions.len > 0) {
            const project_path = try projectPath(arena, self.config, project, self.config.project_file);
            const project_existed = fileExists(project_path);
            const project_text = if (project_existed)
                try readFileOrEmpty(arena, project_path)
            else
                try std.fmt.allocPrint(arena, "# {s}\n\n## Actions\n", .{project});

            const before_open = vault.parseOpenActions(arena, project_text) catch return error.OutOfMemory;
            const project_out = try session_writer.promoteActions(arena, project_text, actions);
            const after_open = vault.parseOpenActions(arena, project_out) catch return error.OutOfMemory;
            promoted = after_open.len -| before_open.len;
            try writeAtomic(self.gpa, project_path, project_out);
        }

        return std.fmt.allocPrint(arena, "{{\"ok\":true,\"first_session\":{},\"promoted\":{d}}}", .{
            first_session,
            promoted,
        });
    }

    fn callCheckpoint(self: *ContinuityWorker, arena: std.mem.Allocator, fn_id: []const u8, project: []const u8) error{ Failed, OutOfMemory }!void {
        const req = std.fmt.allocPrint(arena, "{{\"label\":{f}}}", .{json.fmt(project, .{})}) catch
            return error.OutOfMemory;
        const res = self.worker.call(fn_id, req) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Shutdown => return error.Failed,
        };
        switch (res) {
            .ok => |payload| self.gpa.free(payload),
            .err => |code| {
                defer self.gpa.free(code);
                return error.Failed;
            },
        }
    }
};

fn projectPath(arena: std.mem.Allocator, cfg: Config, project: []const u8, file: []const u8) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}/{s}/{s}", .{
        cfg.root, cfg.projects_subdir, project, file,
    }) catch return error.OutOfMemory;
}

fn projectDirPath(arena: std.mem.Allocator, cfg: Config, project: []const u8) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{
        cfg.root, cfg.projects_subdir, project,
    }) catch return error.OutOfMemory;
}

fn validProjectName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |ch| {
        if (ch == '/' or ch == '\\' or ch == 0) return false;
    }
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    return true;
}

fn writeStringArray(w: *std.Io.Writer, items: []const []const u8) error{OutOfMemory}!void {
    w.writeAll("[") catch return error.OutOfMemory;
    for (items, 0..) |s, i| {
        if (i > 0) w.writeAll(",") catch return error.OutOfMemory;
        w.print("{f}", .{json.fmt(s, .{})}) catch return error.OutOfMemory;
    }
    w.writeAll("]") catch return error.OutOfMemory;
}

const strField = jsonx.strField;

fn strArrayField(arena: std.mem.Allocator, obj: json.ObjectMap, key: []const u8) error{ Failed, OutOfMemory }![]const []const u8 {
    const v = obj.get(key) orelse return &[_][]const u8{};
    if (v != .array) return error.Failed;
    var out: std.ArrayList([]const u8) = .empty;
    for (v.array.items) |item| {
        if (item != .string) return error.Failed;
        try out.append(arena, item.string);
    }
    return out.toOwnedSlice(arena);
}

/// Missing file ⇒ empty owned text. Other open failures also empty (treat as no data).
// ===========================================================================
// Tests (docs/specs/tessera-continuity.md Worker layer, RED first)
// ===========================================================================

const testing = std.testing;

extern "c" fn realpath(path: [*:0]const u8, resolved: [*]u8) ?[*:0]u8;

const Harness = struct {
    registry: inproc.Registry,
    actor: actor_mod.Actor,
    kernel: std.Thread,
    continuity: *ContinuityWorker,
    caller: *inproc.Worker,
    tmp: std.testing.TmpDir,
    root_buf: [std.fs.max_path_bytes]u8 = undefined,
    root: []const u8 = undefined,

    fn init(gpa: std.mem.Allocator, checkpoint_function: ?[]const u8) !*Harness {
        const self = try gpa.create(Harness);
        errdefer gpa.destroy(self);
        self.tmp = std.testing.tmpDir(.{});
        var rel_buf: [std.fs.max_path_bytes]u8 = undefined;
        const rel = try std.fmt.bufPrintZ(&rel_buf, ".zig-cache/tmp/{s}", .{self.tmp.sub_path});
        const resolved = realpath(rel, &self.root_buf) orelse return error.RealpathFailed;
        self.root = std.mem.span(resolved);

        try buildFixture(gpa, self.root);

        self.registry = inproc.Registry.init(gpa, null);
        self.actor = try actor_mod.Actor.init(gpa, .{}, self.registry.outbound());
        self.kernel = try std.Thread.spawn(.{}, actor_mod.Actor.run, .{&self.actor});
        self.continuity = try ContinuityWorker.start(gpa, &self.actor, &self.registry, .{
            .root = self.root,
            .checkpoint_function = checkpoint_function,
        });
        self.caller = try inproc.Worker.spawn(gpa, &self.actor, &self.registry, "test-caller");
        return self;
    }

    fn deinit(self: *Harness) void {
        const gpa = self.actor.gpa;
        self.caller.stop();
        self.continuity.stop();
        self.actor.post(.shutdown);
        self.kernel.join();
        self.actor.deinit();
        self.registry.deinit();
        self.tmp.cleanup();
        gpa.destroy(self);
    }

    fn sessionsPath(self: *Harness, project: []const u8) ![]u8 {
        return std.fmt.allocPrint(testing.allocator, "{s}/Projects/{s}/SESSIONS.md", .{ self.root, project });
    }

    fn projectPathAbs(self: *Harness, project: []const u8) ![]u8 {
        return std.fmt.allocPrint(testing.allocator, "{s}/Projects/{s}/PROJECT.md", .{ self.root, project });
    }

    fn readAbs(self: *Harness, abs: []const u8) ![]u8 {
        _ = self;
        var a = std.heap.ArenaAllocator.init(testing.allocator);
        defer a.deinit();
        const text = try readFileOrEmpty(a.allocator(), abs);
        return testing.allocator.dupe(u8, text);
    }
};

/// One project `known` with a single session; `empty_proj` dir without SESSIONS.md.
fn buildFixture(gpa: std.mem.Allocator, root: []const u8) !void {
    try mkdirP(gpa, root);

    const sessions =
        \\---
        \\title: Sessions — known
        \\tags: [sessions, project]
        \\---
        \\---
        \\## Session — 2024-03-28 10:00
        \\
        \\### 🔮 Leaving behind
        \\
        \\Wiring the continuity worker.
        \\
        \\### 🧵 Open threads
        \\
        \\- ship session_open
        \\- cover session_close
        \\
        \\---
        \\
    ;
    try writeAbs(gpa, root, "Projects/known/SESSIONS.md", sessions);
    try writeAbs(gpa, root, "Projects/known/PROJECT.md", "# known\n\n## Actions\n\n- [ ] existing open\n- [x] already done\n");
    const empty_dir = try std.fmt.allocPrint(gpa, "{s}/Projects/empty_proj", .{root});
    defer gpa.free(empty_dir);
    try mkdirP(gpa, empty_dir);
}

fn writeAbs(gpa: std.mem.Allocator, root: []const u8, rel: []const u8, bytes: []const u8) !void {
    const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, rel });
    defer gpa.free(path);

    var end: usize = 1;
    while (end < path.len) : (end += 1) {
        if (path[end] == '/') {
            const dir_z = try gpa.dupeZ(u8, path[0..end]);
            defer gpa.free(dir_z);
            _ = c.mkdir(dir_z, 0o755);
        }
    }

    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);
    const fd = c.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c.mode_t, 0o644));
    if (fd < 0) return error.Io;
    defer _ = c.close(fd);
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(fd, bytes.ptr + off, bytes.len - off);
        if (n <= 0) return error.Io;
        off += @intCast(n);
    }
}

const Parsed = struct {
    parsed: json.Parsed(json.Value),
    fn deinit(self: *Parsed) void {
        self.parsed.deinit();
    }
    fn root(self: *Parsed) json.Value {
        return self.parsed.value;
    }
};

fn parseOk(payload: []const u8) !Parsed {
    return .{ .parsed = try json.parseFromSlice(json.Value, testing.allocator, payload, .{}) };
}

/// In-test fake for the checkpoint seam. `fail` ⇒ handler returns error.Failed.
const FakeCheckpoint = struct {
    gpa: std.mem.Allocator,
    worker: *inproc.Worker,
    fail: bool,
    calls: usize = 0,

    fn start(gpa: std.mem.Allocator, actor: *actor_mod.Actor, registry: *inproc.Registry, fail: bool) !*FakeCheckpoint {
        const self = try gpa.create(FakeCheckpoint);
        self.* = .{
            .gpa = gpa,
            .worker = try inproc.Worker.spawn(gpa, actor, registry, if (fail) "fake-cp-fail" else "fake-cp-ok"),
            .fail = fail,
        };
        try self.worker.registerFunction("test::checkpoint", self, &handler);
        return self;
    }

    fn stop(self: *FakeCheckpoint) void {
        self.worker.stop();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    fn handler(ctx: ?*anyopaque, arena: std.mem.Allocator, request_json: []const u8) error{ Failed, OutOfMemory }![]const u8 {
        const self: *FakeCheckpoint = @ptrCast(@alignCast(ctx.?));
        _ = request_json;
        self.calls += 1;
        if (self.fail) return error.Failed;
        return arena.dupe(u8, "{\"checkpoint_id\":\"fake\"}");
    }
};

test "session_open on missing SESSIONS.md reports first_session" {
    var h = try Harness.init(testing.allocator, null);
    defer h.deinit();

    const res = try h.caller.call("zygos::tessera::session_open", "{\"project\":\"empty_proj\"}");
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);

    var p = try parseOk(res.ok);
    defer p.deinit();
    try testing.expectEqual(true, p.root().object.get("first_session").?.bool);
    try testing.expectEqualStrings("First session.", p.root().object.get("context_reload").?.string);
    try testing.expectEqual(@as(usize, 0), p.root().object.get("open_threads").?.array.items.len);
}

test "session_open returns newest leaving-behind + threads; does not write" {
    var h = try Harness.init(testing.allocator, null);
    defer h.deinit();

    const path = try h.sessionsPath("known");
    defer testing.allocator.free(path);
    const before = try h.readAbs(path);
    defer testing.allocator.free(before);

    const res = try h.caller.call("zygos::tessera::session_open", "{\"project\":\"known\"}");
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);

    var p = try parseOk(res.ok);
    defer p.deinit();
    try testing.expectEqual(false, p.root().object.get("first_session").?.bool);
    try testing.expectEqualStrings("Wiring the continuity worker.", p.root().object.get("context_reload").?.string);
    const threads = p.root().object.get("open_threads").?.array.items;
    try testing.expectEqual(@as(usize, 2), threads.len);
    try testing.expectEqualStrings("ship session_open", threads[0].string);
    try testing.expectEqualStrings("cover session_close", threads[1].string);

    const after = try h.readAbs(path);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
}

test "session_close first creation: frontmatter-safe file; parseSessions sees 1 entry" {
    var h = try Harness.init(testing.allocator, null);
    defer h.deinit();

    const body =
        \\{"project":"brand_new","date":"2024-06-01 14:00","leaving_behind":"First seam.",
        \\ "accomplished":"Bootstrapped.","open_threads":["next step"],"log":["14:00 — opened"],
        \\ "intention":"Start.","context_reload":""}
    ;
    const res = try h.caller.call("zygos::tessera::session_close", body);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);

    var p = try parseOk(res.ok);
    defer p.deinit();
    try testing.expectEqual(true, p.root().object.get("ok").?.bool);
    try testing.expectEqual(true, p.root().object.get("first_session").?.bool);

    const path = try h.sessionsPath("brand_new");
    defer testing.allocator.free(path);
    const text = try h.readAbs(path);
    defer testing.allocator.free(text);

    // Frontmatter first (title line), then entry.
    try testing.expect(std.mem.startsWith(u8, text, "---\ntitle: Sessions — brand_new\n"));
    try testing.expect(std.mem.indexOf(u8, text, "tags: [sessions, project]") != null);

    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const sessions = try vault.parseSessions(a.allocator(), text);
    try testing.expectEqual(@as(usize, 1), sessions.len);
    try testing.expectEqualStrings("First seam.", sessions[0].leaving_behind);
}

test "session_close prepends; newest-first order preserved across two closes" {
    var h = try Harness.init(testing.allocator, null);
    defer h.deinit();

    const first =
        \\{"project":"known","date":"2024-06-01 10:00","leaving_behind":"After first close.",
        \\ "open_threads":["t1"],"log":[],"accomplished":"A","intention":"","context_reload":""}
    ;
    const r1 = try h.caller.call("zygos::tessera::session_close", first);
    defer r1.deinit(testing.allocator);
    try testing.expect(r1 == .ok);

    const second =
        \\{"project":"known","date":"2024-06-02 11:00","leaving_behind":"After second close.",
        \\ "open_threads":["t2"],"log":[],"accomplished":"B","intention":"","context_reload":""}
    ;
    const r2 = try h.caller.call("zygos::tessera::session_close", second);
    defer r2.deinit(testing.allocator);
    try testing.expect(r2 == .ok);

    var p2 = try parseOk(r2.ok);
    defer p2.deinit();
    try testing.expectEqual(false, p2.root().object.get("first_session").?.bool);

    const path = try h.sessionsPath("known");
    defer testing.allocator.free(path);
    const text = try h.readAbs(path);
    defer testing.allocator.free(text);

    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const sessions = try vault.parseSessions(a.allocator(), text);
    try testing.expect(sessions.len >= 3);
    try testing.expectEqualStrings("After second close.", sessions[0].leaving_behind);
    try testing.expectEqualStrings("After first close.", sessions[1].leaving_behind);
    try testing.expectEqualStrings("Wiring the continuity worker.", sessions[2].leaving_behind);
}

test "blank leaving_behind refused; vault untouched" {
    var h = try Harness.init(testing.allocator, null);
    defer h.deinit();

    const path = try h.sessionsPath("known");
    defer testing.allocator.free(path);
    const before = try h.readAbs(path);
    defer testing.allocator.free(before);

    const body =
        \\{"project":"known","date":"2024-06-01 10:00","leaving_behind":"   ",
        \\ "open_threads":[],"log":[]}
    ;
    const res = try h.caller.call("zygos::tessera::session_close", body);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .err);

    const after = try h.readAbs(path);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
}

test "actions promoted to PROJECT.md as - [ ]; duplicates skipped; PROJECT.md created if absent" {
    var h = try Harness.init(testing.allocator, null);
    defer h.deinit();

    // Promote into existing PROJECT.md — skip "existing open", add "new action".
    const body_known =
        \\{"project":"known","date":"2024-06-01 12:00","leaving_behind":"Promoted.",
        \\ "actions":["existing open","new action","  existing open  "],
        \\ "open_threads":[],"log":[]}
    ;
    const r1 = try h.caller.call("zygos::tessera::session_close", body_known);
    defer r1.deinit(testing.allocator);
    try testing.expect(r1 == .ok);
    var p1 = try parseOk(r1.ok);
    defer p1.deinit();
    try testing.expectEqual(@as(i64, 1), p1.root().object.get("promoted").?.integer);

    const known_proj = try h.projectPathAbs("known");
    defer testing.allocator.free(known_proj);
    const known_text = try h.readAbs(known_proj);
    defer testing.allocator.free(known_text);
    try testing.expect(std.mem.indexOf(u8, known_text, "- [ ] existing open") != null);
    try testing.expect(std.mem.indexOf(u8, known_text, "- [ ] new action") != null);
    try testing.expect(std.mem.indexOf(u8, known_text, "- [x] already done") != null);
    // Duplicate not double-added.
    var count_existing: usize = 0;
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, known_text, search, "- [ ] existing open")) |idx| {
        count_existing += 1;
        search = idx + 1;
    }
    try testing.expectEqual(@as(usize, 1), count_existing);

    // Create PROJECT.md for a brand-new project that only gets a close with actions.
    const body_new =
        \\{"project":"actions_only","date":"2024-06-01 13:00","leaving_behind":"Created project.",
        \\ "actions":["first todo","second todo"],"open_threads":[],"log":[]}
    ;
    const r2 = try h.caller.call("zygos::tessera::session_close", body_new);
    defer r2.deinit(testing.allocator);
    try testing.expect(r2 == .ok);
    var p2 = try parseOk(r2.ok);
    defer p2.deinit();
    try testing.expectEqual(@as(i64, 2), p2.root().object.get("promoted").?.integer);

    const new_proj = try h.projectPathAbs("actions_only");
    defer testing.allocator.free(new_proj);
    const new_text = try h.readAbs(new_proj);
    defer testing.allocator.free(new_text);
    try testing.expect(std.mem.startsWith(u8, new_text, "# actions_only\n"));
    try testing.expect(std.mem.indexOf(u8, new_text, "## Actions") != null);
    try testing.expect(std.mem.indexOf(u8, new_text, "- [ ] first todo") != null);
    try testing.expect(std.mem.indexOf(u8, new_text, "- [ ] second todo") != null);
}

test "configured checkpoint_function is called before the write; its failure blocks the write (fail closed)" {
    // Success path: checkpoint ok, write proceeds, fake was called once.
    {
        var h = try Harness.init(testing.allocator, "test::checkpoint");
        defer h.deinit();
        const fake = try FakeCheckpoint.start(testing.allocator, &h.actor, &h.registry, false);
        defer fake.stop();

        const body =
            \\{"project":"known","date":"2024-06-03 09:00","leaving_behind":"After checkpoint.",
            \\ "open_threads":[],"log":[]}
        ;
        const res = try h.caller.call("zygos::tessera::session_close", body);
        defer res.deinit(testing.allocator);
        try testing.expect(res == .ok);
        try testing.expectEqual(@as(usize, 1), fake.calls);

        const path = try h.sessionsPath("known");
        defer testing.allocator.free(path);
        const text = try h.readAbs(path);
        defer testing.allocator.free(text);
        try testing.expect(std.mem.indexOf(u8, text, "After checkpoint.") != null);
    }

    // Fail-closed: checkpoint fails ⇒ no write.
    {
        var h = try Harness.init(testing.allocator, "test::checkpoint");
        defer h.deinit();
        const fake = try FakeCheckpoint.start(testing.allocator, &h.actor, &h.registry, true);
        defer fake.stop();

        const path = try h.sessionsPath("known");
        defer testing.allocator.free(path);
        const before = try h.readAbs(path);
        defer testing.allocator.free(before);

        const body =
            \\{"project":"known","date":"2024-06-03 10:00","leaving_behind":"Should not appear.",
            \\ "open_threads":[],"log":[]}
        ;
        const res = try h.caller.call("zygos::tessera::session_close", body);
        defer res.deinit(testing.allocator);
        try testing.expect(res == .err);
        try testing.expectEqual(@as(usize, 1), fake.calls);

        const after = try h.readAbs(path);
        defer testing.allocator.free(after);
        try testing.expectEqualStrings(before, after);
        try testing.expect(std.mem.indexOf(u8, after, "Should not appear.") == null);
    }
}

test "no leaks" {
    var h = try Harness.init(testing.allocator, null);
    defer h.deinit();

    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const open = try h.caller.call("zygos::tessera::session_open", "{\"project\":\"known\"}");
        open.deinit(testing.allocator);
        const open2 = try h.caller.call("zygos::tessera::session_open", "{\"project\":\"empty_proj\"}");
        open2.deinit(testing.allocator);
        const close = try h.caller.call(
            "zygos::tessera::session_close",
            \\{"project":"known","date":"2024-06-01 15:00","leaving_behind":"Loop seam.",
            \\ "open_threads":["x"],"log":["tick"],"actions":["loop item"]}
            ,
        );
        close.deinit(testing.allocator);
    }
}
