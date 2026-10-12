//! Durable `.planning/` substrate (M3 V2, docs/specs/mission.md). The
//! mission record and role artifacts persist under one planning root; every
//! write goes through a tmp-file + rename(2) so a crash mid-write always
//! leaves the previous file intact. No bus code — worker/mission.zig drives
//! this. libc-backed (Zig 0.16 moved std.fs file IO behind std.Io, which
//! stays out of worker modules per Z-02).

const std = @import("std");
const jsonx = @import("jsonx.zig");
const c = std.c;
const json = std.json;
const mission_mod = @import("mission.zig");
const pipeline_mod = @import("mission/pipeline.zig");

pub const StoreError = error{ OutOfMemory, NotFound, Corrupt, BadName, Io };

/// The mission record's filename under the planning root.
pub const state_file = "mission.json";

pub const Store = struct {
    /// Absolute planning root, no trailing slash.
    root: []const u8,

    pub fn init(root: []const u8) Store {
        std.debug.assert(root.len > 1 and root[0] == '/');
        return .{ .root = std.mem.trimEnd(u8, root, "/") };
    }

    /// Persist the full mission record atomically. Creates the root.
    pub fn save(self: Store, gpa: std.mem.Allocator, m: *const mission_mod.Mission) StoreError!void {
        const bytes = try serialize(gpa, m);
        defer gpa.free(bytes);
        try self.writeAtomic(gpa, state_file, bytes);
    }

    /// Load the persisted mission record. The returned Mission owns every
    /// slice; release with `Mission.deinit(gpa)`.
    pub fn load(self: Store, gpa: std.mem.Allocator) StoreError!mission_mod.Mission {
        const bytes = try self.read(gpa, state_file);
        defer gpa.free(bytes);
        return deserialize(gpa, bytes);
    }

    /// Role artifacts are bare filenames (MISSION.md, PLAN.md, VERIFY.md) —
    /// anything path-shaped is BadName, the substrate is flat by design.
    pub fn writeArtifact(self: Store, gpa: std.mem.Allocator, name: []const u8, bytes: []const u8) StoreError!void {
        try checkName(name);
        try self.writeAtomic(gpa, name, bytes);
    }

    /// Append-only artifacts (the DECISIONS.md journal): O_APPEND, no tmp
    /// dance — appends of one write are atomic enough for a journal, and
    /// the file must never be clobbered.
    pub fn appendArtifact(self: Store, gpa: std.mem.Allocator, name: []const u8, bytes: []const u8) StoreError!void {
        try checkName(name);
        try mkdirP(gpa, self.root);
        const path_z = std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ self.root, name }, 0) catch
            return error.OutOfMemory;
        defer gpa.free(path_z);
        const fd = c.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, @as(c.mode_t, 0o644));
        if (fd < 0) return error.Io;
        defer _ = c.close(fd);
        var off: usize = 0;
        while (off < bytes.len) {
            const n = c.write(fd, bytes.ptr + off, bytes.len - off);
            if (n <= 0) return error.Io;
            off += @intCast(n);
        }
    }

    /// Remove an artifact. Already absent is success; any other unlink
    /// failure is Io, so callers can refuse rather than read stale bytes.
    pub fn removeArtifact(self: Store, gpa: std.mem.Allocator, name: []const u8) StoreError!void {
        try checkName(name);
        const path_z = std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ self.root, name }, 0) catch
            return error.OutOfMemory;
        defer gpa.free(path_z);
        if (c.unlink(path_z) != 0 and c._errno().* != @intFromEnum(c.E.NOENT)) return error.Io;
    }

    /// Returns owned bytes; missing artifact is NotFound.
    pub fn readArtifact(self: Store, gpa: std.mem.Allocator, name: []const u8) StoreError![]u8 {
        try checkName(name);
        return self.read(gpa, name);
    }

    fn checkName(name: []const u8) StoreError!void {
        if (name.len == 0 or name[0] == '.') return error.BadName;
        for (name) |ch| {
            if (ch == '/' or ch == '\\') return error.BadName;
        }
    }

    var write_seq = std.atomic.Value(u64).init(0);

    fn writeAtomic(self: Store, gpa: std.mem.Allocator, name: []const u8, bytes: []const u8) StoreError!void {
        try mkdirP(gpa, self.root);
        // Unique O_EXCL tmp per writer: two processes saving into one root
        // (cron overlap) never interleave into a shared tmp file.
        const tmp_z = std.fmt.allocPrintSentinel(gpa, "{s}/{s}.tmp.{d}.{d}", .{
            self.root,
            name,
            std.c.getpid(),
            write_seq.fetchAdd(1, .monotonic),
        }, 0) catch return error.OutOfMemory;
        defer gpa.free(tmp_z);
        const final_z = std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ self.root, name }, 0) catch
            return error.OutOfMemory;
        defer gpa.free(final_z);

        const fd = c.open(tmp_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, @as(c.mode_t, 0o644));
        if (fd < 0) return error.Io;
        // No tmp residue survives any path after a successful create.
        defer _ = c.unlink(tmp_z); // no-op after a successful rename
        var off: usize = 0;
        while (off < bytes.len) {
            const n = c.write(fd, bytes.ptr + off, bytes.len - off);
            if (n <= 0) {
                _ = c.close(fd);
                return error.Io;
            }
            off += @intCast(n);
        }
        // Durability: the final name must never resolve to an empty file
        // after a crash — data blocks hit the disk before the rename does.
        if (c.fsync(fd) != 0) {
            _ = c.close(fd);
            return error.Io;
        }
        if (c.close(fd) != 0) return error.Io;
        // rename(2) is the atomicity boundary: readers see the old file or
        // the new one, never a torn write.
        if (c.rename(tmp_z, final_z) != 0) return error.Io;
    }

    fn read(self: Store, gpa: std.mem.Allocator, name: []const u8) StoreError![]u8 {
        const path_z = std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ self.root, name }, 0) catch
            return error.OutOfMemory;
        defer gpa.free(path_z);
        const fd = c.open(path_z, .{ .ACCMODE = .RDONLY });
        if (fd < 0) return error.NotFound;
        defer _ = c.close(fd);

        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(gpa);
        var chunk: [64 * 1024]u8 = undefined;
        while (true) {
            const n = c.read(fd, &chunk, chunk.len);
            if (n < 0) return error.Io;
            if (n == 0) break;
            buf.appendSlice(gpa, chunk[0..@intCast(n)]) catch return error.OutOfMemory;
        }
        return buf.toOwnedSlice(gpa) catch return error.OutOfMemory;
    }
};

/// mkdir -p over every prefix of an absolute path (EEXIST is fine).
fn mkdirP(gpa: std.mem.Allocator, abs: []const u8) StoreError!void {
    var end: usize = 1;
    while (end <= abs.len) : (end += 1) {
        if (end == abs.len or abs[end] == '/') {
            const dir_z = gpa.dupeZ(u8, abs[0..end]) catch return error.OutOfMemory;
            defer gpa.free(dir_z);
            _ = c.mkdir(dir_z, 0o755);
        }
    }
}

fn serialize(gpa: std.mem.Allocator, m: *const mission_mod.Mission) StoreError![]u8 {
    var task_parts: std.ArrayList([]const u8) = .empty;
    defer {
        for (task_parts.items) |p| gpa.free(p);
        task_parts.deinit(gpa);
    }
    for (m.tasks) |t| {
        const part = std.fmt.allocPrint(gpa, "{{\"desc\":{f},\"done\":{}}}", .{
            json.fmt(t.desc, .{}), t.done,
        }) catch return error.OutOfMemory;
        errdefer gpa.free(part);
        task_parts.append(gpa, part) catch return error.OutOfMemory;
    }
    const tasks_json = std.mem.join(gpa, ",", task_parts.items) catch return error.OutOfMemory;
    defer gpa.free(tasks_json);

    var runs: std.Io.Writer.Allocating = .init(gpa);
    defer runs.deinit();
    for (m.step_runs.items, 0..) |r, i| {
        runs.writer.print("{s}{{\"id\":{f},\"count\":{d}}}", .{
            if (i == 0) "" else ",", json.fmt(r.id, .{}), r.count,
        }) catch return error.OutOfMemory;
    }

    return std.fmt.allocPrint(gpa, "{{\"mission_id\":{f},\"state\":\"{t}\",\"stop\":\"{t}\"," ++
        "\"detail\":{f},\"objective\":{f},\"acceptance\":{f},\"feedback\":{f}," ++
        "\"tasks\":[{s}],\"task_index\":{d},\"fail_count\":{d},\"exec_fail_count\":{d}," ++
        "\"gate_denials\":{d},\"role_turns_used\":{d},\"step_index\":{d}," ++
        "\"step_runs\":[{s}],\"mission_versions\":{d},\"plan_versions\":{d}}}", .{
        json.fmt(m.mission_id, .{}), m.state,                    m.stop,
        json.fmt(m.detail, .{}),     json.fmt(m.objective, .{}), json.fmt(m.acceptance, .{}),
        json.fmt(m.feedback, .{}),   tasks_json,                 m.task_index,
        m.fail_count,                m.exec_fail_count,          m.gate_denials,
        m.role_turns_used,           m.step_index,               runs.written(),
        m.mission_versions,          m.plan_versions,
    }) catch return error.OutOfMemory;
}

const StateCursor = struct { state: mission_mod.State, step_index: usize };

/// New state names, or a pre-pipeline state mapped onto the default
/// pipeline's cursor (docs/specs/mission.md "Legacy state files").
fn parseState(name: []const u8) ?StateCursor {
    if (std.meta.stringToEnum(mission_mod.State, name)) |state| return .{ .state = state, .step_index = 0 };
    const legacy = [_]struct { name: []const u8, step_index: usize }{
        .{ .name = "defining", .step_index = 0 },
        .{ .name = "planning", .step_index = 1 },
        .{ .name = "executing", .step_index = 2 },
        .{ .name = "verifying", .step_index = 3 },
    };
    for (legacy) |l| {
        if (std.mem.eql(u8, name, l.name)) return .{ .state = .running, .step_index = l.step_index };
    }
    return null;
}

fn optUintField(obj: json.ObjectMap, key: []const u8) StoreError!usize {
    if (obj.get(key) == null) return 0;
    return uintField(obj, key);
}

fn deserialize(gpa: std.mem.Allocator, bytes: []const u8) StoreError!mission_mod.Mission {
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const root = json.parseFromSliceLeaky(json.Value, arena, bytes, .{}) catch return error.Corrupt;
    if (root != .object) return error.Corrupt;
    const obj = root.object;

    const cursor = parseState(strField(obj, "state") orelse return error.Corrupt) orelse
        return error.Corrupt;
    const state = cursor.state;
    const is_legacy_state = obj.get("step_index") == null;
    const step_index = if (is_legacy_state) cursor.step_index else try uintField(obj, "step_index");
    const runs_val = obj.get("step_runs");
    if (runs_val) |rv| {
        if (rv != .array) return error.Corrupt;
        for (rv.array.items) |item| {
            if (item != .object) return error.Corrupt;
            if (strField(item.object, "id") == null) return error.Corrupt;
            _ = try uintField(item.object, "count");
        }
    }
    const stop = std.meta.stringToEnum(mission_mod.StopReason, strField(obj, "stop") orelse
        return error.Corrupt) orelse return error.Corrupt;
    const tasks_val = obj.get("tasks") orelse return error.Corrupt;
    if (tasks_val != .array) return error.Corrupt;
    for (tasks_val.array.items) |tv| {
        if (tv != .object) return error.Corrupt;
        if (strField(tv.object, "desc") == null) return error.Corrupt;
        const done = tv.object.get("done") orelse return error.Corrupt;
        if (done != .bool) return error.Corrupt;
    }

    const mission_id = gpa.dupe(u8, strField(obj, "mission_id") orelse return error.Corrupt) catch
        return error.OutOfMemory;
    errdefer gpa.free(mission_id);
    const detail = gpa.dupe(u8, strField(obj, "detail") orelse return error.Corrupt) catch
        return error.OutOfMemory;
    errdefer gpa.free(detail);
    const objective = gpa.dupe(u8, strField(obj, "objective") orelse return error.Corrupt) catch
        return error.OutOfMemory;
    errdefer gpa.free(objective);
    const acceptance = gpa.dupe(u8, strField(obj, "acceptance") orelse return error.Corrupt) catch
        return error.OutOfMemory;
    errdefer gpa.free(acceptance);
    const feedback = gpa.dupe(u8, strField(obj, "feedback") orelse return error.Corrupt) catch
        return error.OutOfMemory;
    errdefer gpa.free(feedback);

    const tasks = gpa.alloc(mission_mod.Task, tasks_val.array.items.len) catch
        return error.OutOfMemory;
    var built: usize = 0;
    errdefer {
        for (tasks[0..built]) |t| gpa.free(t.desc);
        gpa.free(tasks);
    }
    for (tasks_val.array.items, 0..) |tv, i| {
        tasks[i] = .{
            .desc = gpa.dupe(u8, strField(tv.object, "desc").?) catch return error.OutOfMemory,
            .done = tv.object.get("done").?.bool,
        };
        built += 1;
    }

    const run_items = gpa.alloc(pipeline_mod.RunCount, if (runs_val) |rv| rv.array.items.len else 0) catch
        return error.OutOfMemory;
    var runs_built: usize = 0;
    errdefer {
        for (run_items[0..runs_built]) |r| gpa.free(r.id);
        gpa.free(run_items);
    }
    if (runs_val) |rv| {
        for (rv.array.items, run_items) |item, *out| {
            out.* = .{
                .id = gpa.dupe(u8, strField(item.object, "id").?) catch return error.OutOfMemory,
                .count = try uintField(item.object, "count"),
            };
            runs_built += 1;
        }
    }

    return .{
        .mission_id = mission_id,
        .state = state,
        .step_index = step_index,
        .step_runs = .{ .items = run_items },
        .mission_versions = try optUintField(obj, "mission_versions"),
        .plan_versions = try optUintField(obj, "plan_versions"),
        .stop = stop,
        .detail = detail,
        .objective = objective,
        .acceptance = acceptance,
        .feedback = feedback,
        .tasks = tasks,
        .task_index = try uintField(obj, "task_index"),
        .fail_count = try uintField(obj, "fail_count"),
        // Absent in substrates written before the executor-retry change —
        // default 0, never Corrupt (resume compatibility).
        .exec_fail_count = uintField(obj, "exec_fail_count") catch 0,
        .gate_denials = try uintField(obj, "gate_denials"),
        .role_turns_used = try uintField(obj, "role_turns_used"),
    };
}

const strField = jsonx.strField;

fn uintField(obj: json.ObjectMap, key: []const u8) StoreError!usize {
    const v = obj.get(key) orelse return error.Corrupt;
    if (v != .integer or v.integer < 0) return error.Corrupt;
    return @intCast(v.integer);
}

// ===========================================================================
// Tests (docs/specs/mission.md contract, RED first)
// ===========================================================================

const testing = std.testing;

extern "c" fn realpath(path: [*:0]const u8, resolved: [*]u8) ?[*:0]u8;

const TestRoot = struct {
    tmp: std.testing.TmpDir,
    root_buf: [std.fs.max_path_bytes]u8 = undefined,

    fn init() TestRoot {
        return .{ .tmp = std.testing.tmpDir(.{}) };
    }

    /// Canonical absolute path of `.zig-cache/tmp/<name>` via libc realpath.
    fn path(self: *TestRoot) ![]const u8 {
        var rel_buf: [std.fs.max_path_bytes]u8 = undefined;
        const rel = try std.fmt.bufPrintZ(&rel_buf, ".zig-cache/tmp/{s}", .{self.tmp.sub_path});
        const resolved = realpath(rel, &self.root_buf) orelse return error.RealpathFailed;
        return std.mem.span(resolved);
    }

    fn deinit(self: *TestRoot) void {
        self.tmp.cleanup();
    }
};

fn sampleMission() mission_mod.Mission {
    return .{
        .mission_id = "m-rt",
        .state = .running,
        .step_index = 2,
        .step_runs = .{ .items = @constCast(&sample_runs) },
        .mission_versions = 3,
        .plan_versions = 1,
        .stop = .none,
        .detail = "in flight",
        .objective = "ship the \"gizmo\"",
        .acceptance = "gizmo ships",
        .feedback = "tighten the specs\nline two",
        .tasks = @constCast(&sample_tasks),
        .task_index = 1,
        .fail_count = 2,
        .exec_fail_count = 1,
        .gate_denials = 1,
        .role_turns_used = 5,
    };
}
const sample_runs = [_]pipeline_mod.RunCount{
    .{ .id = "product-owner", .count = 2 },
    .{ .id = "architect", .count = 1 },
};
const sample_tasks = [_]mission_mod.Task{
    .{ .desc = "build it", .done = true },
    .{ .desc = "test it", .done = false },
};

test "save then load round-trips every Mission field" {
    var t = TestRoot.init();
    defer t.deinit();
    const store = Store.init(try t.path());

    const m = sampleMission();
    try store.save(testing.allocator, &m);
    var got = try store.load(testing.allocator);
    defer got.deinit(testing.allocator);

    try testing.expectEqualStrings(m.mission_id, got.mission_id);
    try testing.expectEqual(m.state, got.state);
    try testing.expectEqual(m.stop, got.stop);
    try testing.expectEqualStrings(m.detail, got.detail);
    try testing.expectEqualStrings(m.objective, got.objective);
    try testing.expectEqualStrings(m.acceptance, got.acceptance);
    try testing.expectEqualStrings(m.feedback, got.feedback);
    try testing.expectEqual(m.tasks.len, got.tasks.len);
    for (m.tasks, got.tasks) |want, have| {
        try testing.expectEqualStrings(want.desc, have.desc);
        try testing.expectEqual(want.done, have.done);
    }
    try testing.expectEqual(m.task_index, got.task_index);
    try testing.expectEqual(m.fail_count, got.fail_count);
    try testing.expectEqual(m.exec_fail_count, got.exec_fail_count);
    try testing.expectEqual(m.gate_denials, got.gate_denials);
    try testing.expectEqual(m.role_turns_used, got.role_turns_used);
    try testing.expectEqual(m.step_index, got.step_index);
    try testing.expectEqual(m.mission_versions, got.mission_versions);
    try testing.expectEqual(m.plan_versions, got.plan_versions);
    try testing.expectEqual(m.step_runs.items.len, got.step_runs.items.len);
    for (m.step_runs.items) |want| try testing.expectEqual(want.count, got.step_runs.get(want.id));
}

test "legacy state names load as running with the default pipeline's cursor" {
    var t = TestRoot.init();
    defer t.deinit();
    const store = Store.init(try t.path());

    const cases = [_]struct { name: []const u8, state: mission_mod.State, step_index: usize }{
        .{ .name = "defining", .state = .running, .step_index = 0 },
        .{ .name = "planning", .state = .running, .step_index = 1 },
        .{ .name = "executing", .state = .running, .step_index = 2 },
        .{ .name = "verifying", .state = .running, .step_index = 3 },
        .{ .name = "gating", .state = .gating, .step_index = 0 },
        .{ .name = "done", .state = .done, .step_index = 0 },
        .{ .name = "failed", .state = .failed, .step_index = 0 },
    };
    for (cases) |case| {
        const text = try std.fmt.allocPrint(testing.allocator,
            \\{{"mission_id":"m-old","state":"{s}","stop":"none","detail":"",
            \\ "objective":"x","acceptance":"","feedback":"","tasks":[],
            \\ "task_index":0,"fail_count":0,"gate_denials":0,"role_turns_used":0}}
        , .{case.name});
        defer testing.allocator.free(text);
        try store.writeArtifact(testing.allocator, state_file, text);
        var got = try store.load(testing.allocator);
        defer got.deinit(testing.allocator);
        try testing.expectEqual(case.state, got.state);
        try testing.expectEqual(case.step_index, got.step_index);
        try testing.expectEqual(@as(usize, 0), got.step_runs.items.len);
        try testing.expectEqual(@as(usize, 0), got.mission_versions);
        try testing.expectEqual(@as(usize, 0), got.plan_versions);
    }
}

test "an unknown state name or a malformed step_runs is Corrupt" {
    var t = TestRoot.init();
    defer t.deinit();
    const store = Store.init(try t.path());
    const head =
        \\{"mission_id":"m","state":"running","stop":"none","detail":"","objective":"x",
        \\ "acceptance":"","feedback":"","tasks":[],"task_index":0,"fail_count":0,
        \\ "gate_denials":0,"role_turns_used":0
    ;
    for ([_][]const u8{ ",\"step_runs\":{}}", ",\"step_runs\":[{\"id\":\"a\"}]}", ",\"step_index\":-1}" }) |tail| {
        const text = try std.mem.concat(testing.allocator, u8, &.{ head, tail });
        defer testing.allocator.free(text);
        try store.writeArtifact(testing.allocator, state_file, text);
        try testing.expectError(error.Corrupt, store.load(testing.allocator));
    }
    try store.writeArtifact(testing.allocator, state_file,
        \\{"mission_id":"m","state":"paused","stop":"none","detail":"","objective":"x",
        \\ "acceptance":"","feedback":"","tasks":[],"task_index":0,"fail_count":0,
        \\ "gate_denials":0,"role_turns_used":0}
    );
    try testing.expectError(error.Corrupt, store.load(testing.allocator));
}

test "load defaults exec_fail_count to 0 for pre-retry substrates" {
    var t = TestRoot.init();
    defer t.deinit();
    const store = Store.init(try t.path());

    // A state file written before the executor-retry change: no
    // exec_fail_count key. Loading must default it, never reject.
    const legacy =
        \\{"mission_id":"m-old","state":"executing","stop":"none","detail":"",
        \\ "objective":"x","acceptance":"","feedback":"","tasks":[],
        \\ "task_index":0,"fail_count":1,"gate_denials":0,"role_turns_used":2}
    ;
    try store.writeArtifact(testing.allocator, state_file, legacy);
    var got = try store.load(testing.allocator);
    defer got.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), got.exec_fail_count);
    try testing.expectEqual(@as(usize, 1), got.fail_count);
}

test "save is atomic: no tmp residue, overwrite replaces cleanly" {
    var t = TestRoot.init();
    defer t.deinit();
    const root = try t.path();
    const store = Store.init(root);

    var m = sampleMission();
    try store.save(testing.allocator, &m);
    m.state = .done;
    m.stop = .completed;
    try store.save(testing.allocator, &m);

    var got = try store.load(testing.allocator);
    defer got.deinit(testing.allocator);
    try testing.expectEqual(mission_mod.State.done, got.state);
    try testing.expectEqual(mission_mod.StopReason.completed, got.stop);

    // No tmp residue under ANY writer-unique name (pid.seq suffixes).
    var dbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_z = try std.fmt.bufPrintZ(&dbuf, "{s}", .{root});
    const dir = c.opendir(dir_z.ptr) orelse return error.TestUnexpectedResult;
    defer _ = c.closedir(dir);
    while (c.readdir(dir)) |e| {
        const name = std.mem.sliceTo(&e.name, 0);
        try std.testing.expect(!std.mem.startsWith(u8, name, state_file ++ ".tmp"));
    }
}

test "concurrent writeAtomic to one root publish exactly one writer's bytes" {
    var t = TestRoot.init();
    defer t.deinit();
    const root = try t.path();
    const store = Store.init(root);

    const Writer = struct {
        fn run(s: Store, name: []const u8, ch: u8) void {
            var payload: [32 * 1024]u8 = undefined;
            @memset(&payload, ch);
            var i: usize = 0;
            while (i < 40) : (i += 1) {
                s.writeAtomic(std.testing.allocator, name, &payload) catch unreachable;
            }
        }
    };

    var a = try std.Thread.spawn(.{}, Writer.run, .{ store, "mission.json", 'a' });
    var b = try std.Thread.spawn(.{}, Writer.run, .{ store, "mission.json", 'b' });
    a.join();
    b.join();

    const bytes = try store.read(std.testing.allocator, "mission.json");
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 32 * 1024), bytes.len);
    const first = bytes[0];
    for (bytes) |ch| try std.testing.expectEqual(first, ch);
}

test "artifacts land under the planning root; root auto-created; separators rejected" {
    var t = TestRoot.init();
    defer t.deinit();
    // A planning root that does not exist yet — save/write must create it.
    var nested_buf: [std.fs.max_path_bytes]u8 = undefined;
    const nested = try std.fmt.bufPrint(&nested_buf, "{s}/deep/.planning", .{try t.path()});
    const store = Store.init(nested);

    try store.writeArtifact(testing.allocator, "MISSION.md", "# Mission\n\nship it\n");
    const got = try store.readArtifact(testing.allocator, "MISSION.md");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("# Mission\n\nship it\n", got);

    try testing.expectError(error.BadName, store.writeArtifact(testing.allocator, "a/b.md", "x"));
    try testing.expectError(error.BadName, store.writeArtifact(testing.allocator, "..", "x"));
    try testing.expectError(error.BadName, store.writeArtifact(testing.allocator, "", "x"));
    try testing.expectError(error.NotFound, store.readArtifact(testing.allocator, "PLAN.md"));
}

test "appendArtifact grows a file append-only; name rules apply" {
    var t = TestRoot.init();
    defer t.deinit();
    const store = Store.init(try t.path());

    try store.appendArtifact(testing.allocator, "DECISIONS.md", "- one\n");
    try store.appendArtifact(testing.allocator, "DECISIONS.md", "- two\n");
    const got = try store.readArtifact(testing.allocator, "DECISIONS.md");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("- one\n- two\n", got);

    try testing.expectError(error.BadName, store.appendArtifact(testing.allocator, "a/b.md", "x"));
}

test "removeArtifact deletes, treats absent as success, and reports other failures" {
    var t = TestRoot.init();
    defer t.deinit();
    const root = try t.path();
    const store = Store.init(root);

    try store.writeArtifact(testing.allocator, "BRIEF.md", "old\n");
    try store.removeArtifact(testing.allocator, "BRIEF.md");
    try testing.expectError(error.NotFound, store.readArtifact(testing.allocator, "BRIEF.md"));
    try store.removeArtifact(testing.allocator, "BRIEF.md");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_z = try std.fmt.bufPrintZ(&buf, "{s}/PLAN.md", .{root});
    try testing.expectEqual(@as(c_int, 0), c.mkdir(dir_z, 0o755));
    try testing.expectError(error.Io, store.removeArtifact(testing.allocator, "PLAN.md"));
    try testing.expectError(error.BadName, store.removeArtifact(testing.allocator, "../BRIEF.md"));
}

test "load without a state file is NotFound; garbage is Corrupt" {
    var t = TestRoot.init();
    defer t.deinit();
    const store = Store.init(try t.path());

    try testing.expectError(error.NotFound, store.load(testing.allocator));

    try store.writeArtifact(testing.allocator, state_file, "not json at all");
    try testing.expectError(error.Corrupt, store.load(testing.allocator));

    // Structurally valid JSON with a bogus enum is Corrupt too.
    try store.writeArtifact(testing.allocator, state_file,
        \\{"mission_id":"m","state":"warp","stop":"none","detail":"","objective":"",
        \\ "acceptance":"","feedback":"","tasks":[],"task_index":0,"fail_count":0,
        \\ "gate_denials":0,"role_turns_used":0}
    );
    try testing.expectError(error.Corrupt, store.load(testing.allocator));
}

test "no leaks under repeated save/load loops" {
    var t = TestRoot.init();
    defer t.deinit();
    const store = Store.init(try t.path());

    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const m = sampleMission();
        try store.save(testing.allocator, &m);
        var got = try store.load(testing.allocator);
        got.deinit(testing.allocator);
    }
}
