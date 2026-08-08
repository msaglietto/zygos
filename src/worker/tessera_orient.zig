//! Tessera orient worker (W2, docs/specs/tessera-vault.md). Deterministic
//! vault readouts over a config-rooted Projects/ tree: lists projects, open
//! threads, stale (>STALE_DAYS) projects, and stalled-loop detects. Handlers
//! read SESSIONS.md / PROJECT.md via libc (Z-02) and call the pure parsers in
//! tessera/vault.zig. No Obsidian dependency; tests use a fixture vault only.

const std = @import("std");
const jsonx = @import("jsonx.zig");
const c = std.c;
const json = std.json;
const actor_mod = @import("../kernel/actor.zig");
const inproc = @import("../kernel/inproc.zig");
const vault = @import("tessera/vault.zig");

pub const Config = struct {
    root: []const u8,
    projects_subdir: []const u8 = "Projects",
    sessions_file: []const u8 = "SESSIONS.md",
    project_file: []const u8 = "PROJECT.md",
    today: []const u8,
};

pub const OrientWorker = struct {
    gpa: std.mem.Allocator,
    worker: *inproc.Worker,
    config: Config,

    pub fn start(
        gpa: std.mem.Allocator,
        actor: *actor_mod.Actor,
        registry: *inproc.Registry,
        config: Config,
    ) !*OrientWorker {
        const self = try gpa.create(OrientWorker);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .worker = try inproc.Worker.spawn(gpa, actor, registry, "tessera-orient"),
            .config = config,
        };
        errdefer self.worker.stop();
        try self.worker.registerFunction("zygos::tessera::project_status", self, &projectStatusHandler);
        try self.worker.registerFunction("zygos::tessera::open_threads", self, &openThreadsHandler);
        try self.worker.registerFunction("zygos::tessera::stale_projects", self, &staleProjectsHandler);
        try self.worker.registerFunction("zygos::tessera::reflect", self, &reflectHandler);
        return self;
    }

    pub fn stop(self: *OrientWorker) void {
        self.worker.stop();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    fn projectStatusHandler(ctx: ?*anyopaque, arena: std.mem.Allocator, request_json: []const u8) error{ Failed, OutOfMemory }![]const u8 {
        _ = request_json;
        const self: *OrientWorker = @ptrCast(@alignCast(ctx.?));
        const names = try listProjects(arena, self.config);

        var out: std.Io.Writer.Allocating = .init(arena);
        errdefer out.deinit();
        const w = &out.writer;
        w.writeAll("{\"projects\":[") catch return error.OutOfMemory;
        for (names, 0..) |name, i| {
            if (i > 0) w.writeAll(",") catch return error.OutOfMemory;
            const view = try loadProject(arena, self.config, name);
            try writeProjectStatus(w, name, view);
        }
        w.writeAll("]}") catch return error.OutOfMemory;
        return out.toOwnedSlice() catch return error.OutOfMemory;
    }

    fn openThreadsHandler(ctx: ?*anyopaque, arena: std.mem.Allocator, request_json: []const u8) error{ Failed, OutOfMemory }![]const u8 {
        const self: *OrientWorker = @ptrCast(@alignCast(ctx.?));
        const root = json.parseFromSliceLeaky(json.Value, arena, request_json, .{}) catch return error.Failed;
        if (root != .object) return error.Failed;
        const project = strField(root.object, "project") orelse return error.Failed;

        if (!try projectExists(arena, self.config, project)) return error.Failed;

        const view = try loadProject(arena, self.config, project);
        const threads = if (view.newest) |s| s.open_threads else &[_][]const u8{};

        var out: std.Io.Writer.Allocating = .init(arena);
        errdefer out.deinit();
        const w = &out.writer;
        w.writeAll("{\"threads\":") catch return error.OutOfMemory;
        try writeStringArray(w, threads);
        w.writeAll("}") catch return error.OutOfMemory;
        return out.toOwnedSlice() catch return error.OutOfMemory;
    }

    fn staleProjectsHandler(ctx: ?*anyopaque, arena: std.mem.Allocator, request_json: []const u8) error{ Failed, OutOfMemory }![]const u8 {
        _ = request_json;
        const self: *OrientWorker = @ptrCast(@alignCast(ctx.?));
        const names = try listProjects(arena, self.config);

        var stale: std.ArrayList([]const u8) = .empty;
        for (names) |name| {
            const view = try loadProject(arena, self.config, name);
            if (view.days) |d| {
                if (d > vault.STALE_DAYS) try stale.append(arena, name);
            }
        }

        var out: std.Io.Writer.Allocating = .init(arena);
        errdefer out.deinit();
        const w = &out.writer;
        w.writeAll("{\"stale\":") catch return error.OutOfMemory;
        try writeStringArray(w, stale.items);
        w.writeAll("}") catch return error.OutOfMemory;
        return out.toOwnedSlice() catch return error.OutOfMemory;
    }

    fn reflectHandler(ctx: ?*anyopaque, arena: std.mem.Allocator, request_json: []const u8) error{ Failed, OutOfMemory }![]const u8 {
        _ = request_json;
        const self: *OrientWorker = @ptrCast(@alignCast(ctx.?));
        const names = try listProjects(arena, self.config);

        var stalled: std.ArrayList([]const u8) = .empty;
        for (names) |name| {
            const view = try loadProject(arena, self.config, name);
            if (vault.stalledLoop(view.sessions, 3)) try stalled.append(arena, name);
        }

        var out: std.Io.Writer.Allocating = .init(arena);
        errdefer out.deinit();
        const w = &out.writer;
        w.writeAll("{\"stalled\":") catch return error.OutOfMemory;
        try writeStringArray(w, stalled.items);
        w.writeAll("}") catch return error.OutOfMemory;
        return out.toOwnedSlice() catch return error.OutOfMemory;
    }
};

const ProjectView = struct {
    sessions: []const vault.Session,
    newest: ?vault.Session,
    days: ?i64,
    open_actions: []const []const u8,
};

fn loadProject(arena: std.mem.Allocator, cfg: Config, name: []const u8) error{ Failed, OutOfMemory }!ProjectView {
    const sessions_path = std.fmt.allocPrint(arena, "{s}/{s}/{s}/{s}", .{
        cfg.root, cfg.projects_subdir, name, cfg.sessions_file,
    }) catch return error.OutOfMemory;
    const project_path = std.fmt.allocPrint(arena, "{s}/{s}/{s}/{s}", .{
        cfg.root, cfg.projects_subdir, name, cfg.project_file,
    }) catch return error.OutOfMemory;

    const sessions_text = try readFileOrEmpty(arena, sessions_path);
    const project_text = try readFileOrEmpty(arena, project_path);

    const sessions = vault.parseSessions(arena, sessions_text) catch return error.OutOfMemory;
    const open_actions = vault.parseOpenActions(arena, project_text) catch return error.OutOfMemory;

    const newest: ?vault.Session = if (sessions.len > 0) sessions[0] else null;
    const days: ?i64 = if (newest) |s| vault.daysBetween(s.date, cfg.today) else null;
    return .{
        .sessions = sessions,
        .newest = newest,
        .days = days,
        .open_actions = open_actions,
    };
}

fn writeProjectStatus(w: *std.Io.Writer, name: []const u8, view: ProjectView) error{OutOfMemory}!void {
    const leaving: []const u8 = if (view.newest) |s| s.leaving_behind else "";
    const threads: []const []const u8 = if (view.newest) |s| s.open_threads else &[_][]const u8{};
    const stale = if (view.days) |d| d > vault.STALE_DAYS else false;

    w.print("{{\"name\":{f},", .{json.fmt(name, .{})}) catch return error.OutOfMemory;
    if (view.newest) |s| {
        w.print("\"last_session\":{f},\"days\":{d},", .{ json.fmt(s.date, .{}), view.days.? }) catch return error.OutOfMemory;
    } else {
        w.writeAll("\"last_session\":null,\"days\":null,") catch return error.OutOfMemory;
    }
    w.print("\"stale\":{},\"leaving_behind\":{f},\"open_threads\":", .{ stale, json.fmt(leaving, .{}) }) catch return error.OutOfMemory;
    try writeStringArray(w, threads);
    w.writeAll(",\"open_actions\":") catch return error.OutOfMemory;
    try writeStringArray(w, view.open_actions);
    w.writeAll("}") catch return error.OutOfMemory;
}

fn writeStringArray(w: *std.Io.Writer, items: []const []const u8) error{OutOfMemory}!void {
    w.writeAll("[") catch return error.OutOfMemory;
    for (items, 0..) |s, i| {
        if (i > 0) w.writeAll(",") catch return error.OutOfMemory;
        w.print("{f}", .{json.fmt(s, .{})}) catch return error.OutOfMemory;
    }
    w.writeAll("]") catch return error.OutOfMemory;
}

fn listProjects(arena: std.mem.Allocator, cfg: Config) error{ Failed, OutOfMemory }![]const []const u8 {
    const path_z = std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ cfg.root, cfg.projects_subdir }, 0) catch
        return error.OutOfMemory;
    const dir = c.opendir(path_z) orelse return &[_][]const u8{};
    defer _ = c.closedir(dir);

    var names: std.ArrayList([]const u8) = .empty;
    while (c.readdir(dir)) |ent| {
        if (ent.type != c.DT.DIR and ent.type != c.DT.UNKNOWN) continue;
        const name = direntName(ent);
        if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        // Skip non-dirs when type was UNKNOWN: probe with opendir.
        if (ent.type == c.DT.UNKNOWN) {
            const probe_z = std.fmt.allocPrintSentinel(arena, "{s}/{s}/{s}", .{
                cfg.root, cfg.projects_subdir, name,
            }, 0) catch return error.OutOfMemory;
            const probe = c.opendir(probe_z) orelse continue;
            _ = c.closedir(probe);
        }
        const owned = arena.dupe(u8, name) catch return error.OutOfMemory;
        try names.append(arena, owned);
    }
    return names.toOwnedSlice(arena);
}

fn projectExists(arena: std.mem.Allocator, cfg: Config, name: []const u8) error{OutOfMemory}!bool {
    // Reject path-shaped names so "../" cannot escape the projects tree.
    if (name.len == 0) return false;
    for (name) |ch| {
        if (ch == '/' or ch == '\\' or ch == 0) return false;
    }
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;

    const path_z = std.fmt.allocPrintSentinel(arena, "{s}/{s}/{s}", .{
        cfg.root, cfg.projects_subdir, name,
    }, 0) catch return error.OutOfMemory;
    const dir = c.opendir(path_z) orelse return false;
    _ = c.closedir(dir);
    return true;
}

fn direntName(ent: *const c.dirent) []const u8 {
    const name_z: [*:0]const u8 = @ptrCast(&ent.name);
    return std.mem.span(name_z);
}

/// Missing file ⇒ empty owned text. Other open failures also empty (treat as no data).
fn readFileOrEmpty(allocator: std.mem.Allocator, path: []const u8) error{OutOfMemory}![]const u8 {
    const path_z = std.fmt.allocPrintSentinel(allocator, "{s}", .{path}, 0) catch return error.OutOfMemory;
    const fd = c.open(path_z, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return try allocator.dupe(u8, "");
    defer _ = c.close(fd);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const n = c.read(fd, &chunk, chunk.len);
        if (n < 0) {
            buf.deinit(allocator);
            return try allocator.dupe(u8, "");
        }
        if (n == 0) break;
        buf.appendSlice(allocator, chunk[0..@intCast(n)]) catch return error.OutOfMemory;
    }
    return buf.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

const strField = jsonx.strField;

// ===========================================================================
// Tests (docs/specs/tessera-vault.md worker layer, RED first)
// ===========================================================================

const testing = std.testing;

extern "c" fn realpath(path: [*:0]const u8, resolved: [*]u8) ?[*:0]u8;

const Harness = struct {
    registry: inproc.Registry,
    actor: actor_mod.Actor,
    kernel: std.Thread,
    orient: *OrientWorker,
    caller: *inproc.Worker,
    tmp: std.testing.TmpDir,
    root_buf: [std.fs.max_path_bytes]u8 = undefined,
    root: []const u8 = undefined,

    fn init(gpa: std.mem.Allocator, today: []const u8) !*Harness {
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
        self.orient = try OrientWorker.start(gpa, &self.actor, &self.registry, .{
            .root = self.root,
            .today = today,
        });
        self.caller = try inproc.Worker.spawn(gpa, &self.actor, &self.registry, "test-caller");
        return self;
    }

    fn deinit(self: *Harness) void {
        const gpa = self.actor.gpa;
        self.caller.stop();
        self.orient.stop();
        self.actor.post(.shutdown);
        self.kernel.join();
        self.actor.deinit();
        self.registry.deinit();
        self.tmp.cleanup();
        gpa.destroy(self);
    }
};

/// Two projects under <root>/Projects:
/// - `fresh`  — session 4 days ago, threads + open actions, not stale/stalled
/// - `stale_stalled` — 31 days ago, same leaving-behind ×3 → stale + stalled
fn buildFixture(gpa: std.mem.Allocator, root: []const u8) !void {
    try mkdirP(gpa, root);

    const fresh_sessions =
        \\## Session — 2024-03-28 10:00
        \\
        \\### 📌 Leaving behind
        \\
        \\Wiring the orient worker.
        \\
        \\### 🧵 Open threads
        \\
        \\- ship project_status
        \\- cover stale_projects
        \\
    ;
    const fresh_project =
        \\# fresh
        \\
        \\## Actions
        \\
        \\- [ ] write orient tests
        \\- [x] already done
        \\- [ ] document handlers
        \\
    ;
    try writeAbs(gpa, root, "Projects/fresh/SESSIONS.md", fresh_sessions);
    try writeAbs(gpa, root, "Projects/fresh/PROJECT.md", fresh_project);

    const stalled_sessions =
        \\## Session — 2024-03-01 09:00
        \\
        \\### Leaving behind
        \\
        \\still stuck on Y
        \\
        \\### Open threads
        \\
        \\- unblock Y
        \\
        \\## Session — 2024-02-20 09:00
        \\
        \\### Leaving behind
        \\
        \\still stuck on Y
        \\
        \\### Open threads
        \\
        \\- unblock Y
        \\
        \\## Session — 2024-02-10 09:00
        \\
        \\### Leaving behind
        \\
        \\still stuck on Y
        \\
        \\### Open threads
        \\
        \\- start Y
        \\
    ;
    try writeAbs(gpa, root, "Projects/stale_stalled/SESSIONS.md", stalled_sessions);
    try writeAbs(gpa, root, "Projects/stale_stalled/PROJECT.md", "# stale_stalled\n");
}

fn mkdirP(gpa: std.mem.Allocator, abs: []const u8) !void {
    var end: usize = 1;
    while (end <= abs.len) : (end += 1) {
        if (end == abs.len or abs[end] == '/') {
            const dir_z = try gpa.dupeZ(u8, abs[0..end]);
            defer gpa.free(dir_z);
            _ = c.mkdir(dir_z, 0o755);
        }
    }
}

fn writeAbs(gpa: std.mem.Allocator, root: []const u8, rel: []const u8, bytes: []const u8) !void {
    const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, rel });
    defer gpa.free(path);

    // mkdir -p parents
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

fn projectByName(projects: json.Value, name: []const u8) !json.ObjectMap {
    try testing.expect(projects == .array);
    for (projects.array.items) |item| {
        try testing.expect(item == .object);
        const n = item.object.get("name") orelse continue;
        if (n == .string and std.mem.eql(u8, n.string, name)) return item.object;
    }
    return error.ProjectNotFound;
}

test "project_status lists projects with correct days/stale" {
    // today = 2024-04-01 → fresh last=2024-03-28 (4d, not stale);
    // stale_stalled last=2024-03-01 (31d, stale)
    var h = try Harness.init(testing.allocator, "2024-04-01");
    defer h.deinit();

    const res = try h.caller.call("zygos::tessera::project_status", "{}");
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);

    var p = try parseOk(res.ok);
    defer p.deinit();
    const projects = p.root().object.get("projects").?;
    try testing.expectEqual(@as(usize, 2), projects.array.items.len);

    const fresh = try projectByName(projects, "fresh");
    try testing.expectEqualStrings("2024-03-28", fresh.get("last_session").?.string);
    try testing.expectEqual(@as(i64, 4), fresh.get("days").?.integer);
    try testing.expectEqual(false, fresh.get("stale").?.bool);
    try testing.expectEqualStrings("Wiring the orient worker.", fresh.get("leaving_behind").?.string);
    try testing.expectEqual(@as(usize, 2), fresh.get("open_threads").?.array.items.len);
    try testing.expectEqualStrings("ship project_status", fresh.get("open_threads").?.array.items[0].string);
    try testing.expectEqual(@as(usize, 2), fresh.get("open_actions").?.array.items.len);
    try testing.expectEqualStrings("write orient tests", fresh.get("open_actions").?.array.items[0].string);

    const stalled = try projectByName(projects, "stale_stalled");
    try testing.expectEqualStrings("2024-03-01", stalled.get("last_session").?.string);
    try testing.expectEqual(@as(i64, 31), stalled.get("days").?.integer);
    try testing.expectEqual(true, stalled.get("stale").?.bool);
}

test "open_threads returns a project's threads and errors on unknown" {
    var h = try Harness.init(testing.allocator, "2024-04-01");
    defer h.deinit();

    const ok = try h.caller.call("zygos::tessera::open_threads", "{\"project\":\"fresh\"}");
    defer ok.deinit(testing.allocator);
    try testing.expect(ok == .ok);

    var p = try parseOk(ok.ok);
    defer p.deinit();
    const threads = p.root().object.get("threads").?;
    try testing.expectEqual(@as(usize, 2), threads.array.items.len);
    try testing.expectEqualStrings("ship project_status", threads.array.items[0].string);
    try testing.expectEqualStrings("cover stale_projects", threads.array.items[1].string);

    const bad = try h.caller.call("zygos::tessera::open_threads", "{\"project\":\"nope\"}");
    defer bad.deinit(testing.allocator);
    try testing.expect(bad == .err);
    try testing.expectEqualStrings("handler_failed", bad.err);
}

test "stale_projects flags the >14d one" {
    var h = try Harness.init(testing.allocator, "2024-04-01");
    defer h.deinit();

    const res = try h.caller.call("zygos::tessera::stale_projects", "{}");
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);

    var p = try parseOk(res.ok);
    defer p.deinit();
    const stale = p.root().object.get("stale").?;
    try testing.expectEqual(@as(usize, 1), stale.array.items.len);
    try testing.expectEqualStrings("stale_stalled", stale.array.items[0].string);
}

test "reflect flags a stalled-loop project" {
    var h = try Harness.init(testing.allocator, "2024-04-01");
    defer h.deinit();

    const res = try h.caller.call("zygos::tessera::reflect", "{}");
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);

    var p = try parseOk(res.ok);
    defer p.deinit();
    const stalled = p.root().object.get("stalled").?;
    try testing.expectEqual(@as(usize, 1), stalled.array.items.len);
    try testing.expectEqualStrings("stale_stalled", stalled.array.items[0].string);
}

test "no leaks under orient loops" {
    var h = try Harness.init(testing.allocator, "2024-04-01");
    defer h.deinit();

    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const a = try h.caller.call("zygos::tessera::project_status", "{}");
        a.deinit(testing.allocator);
        const b = try h.caller.call("zygos::tessera::stale_projects", "{}");
        b.deinit(testing.allocator);
        const c_res = try h.caller.call("zygos::tessera::reflect", "{}");
        c_res.deinit(testing.allocator);
        const d = try h.caller.call("zygos::tessera::open_threads", "{\"project\":\"fresh\"}");
        d.deinit(testing.allocator);
    }
}
