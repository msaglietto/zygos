//! Pure operator-facing shaping for the mission CLI: the dashboard status
//! line built from a mission.json snapshot, and the attach console's
//! line → control.Command parser. No files, no stdin — cli/mission.zig owns
//! the wiring.

const std = @import("std");
const json = std.json;
const zygos = @import("zygos");

fn strOf(v: ?json.Value) ?[]const u8 {
    const val = v orelse return null;
    return if (val == .string) val.string else null;
}

/// One dashboard line from the raw text of `<root>/mission.json`.
/// `state_path` supplies the printed planning root. Null on any malformed
/// snapshot — the dashboard skips, never crashes.
pub fn dashboardLine(arena: std.mem.Allocator, state_path: []const u8, text: []const u8) ?[]const u8 {
    const v = json.parseFromSliceLeaky(json.Value, arena, text, .{}) catch return null;
    if (v != .object) return null;
    const state = strOf(v.object.get("state")) orelse "?";
    const state_label = stateLabel(arena, v.object, state) orelse return null;
    const stop = strOf(v.object.get("stop")) orelse "?";
    const mid = strOf(v.object.get("mission_id")) orelse "?";
    var tasks: usize = 0;
    var done: usize = 0;
    if (v.object.get("tasks")) |tv| if (tv == .array) {
        tasks = tv.array.items.len;
        for (tv.array.items) |t| {
            if (t == .object) if (t.object.get("done")) |d| {
                if (d == .bool and d.bool) done += 1;
            };
        }
    };
    const turns = if (v.object.get("role_turns_used")) |n| (if (n == .integer) n.integer else 0) else 0;
    const root = if (std.mem.lastIndexOfScalar(u8, state_path, '/')) |i| state_path[0..i] else state_path;
    return std.fmt.allocPrint(
        arena,
        "{s}  {s} ({s})  tasks {d}/{d}  role_turns {d}  {s}\n",
        .{ mid, state_label, stop, done, tasks, turns, root },
    ) catch null;
}

/// "running · executor (3/4)": the state plus the step the persisted cursor
/// points at. The step ids come from the pinned `pipeline` array, else the
/// default pipeline. A cursor outside the list (gating, done) or a file with
/// no `step_index` (pre-pipeline) shows the state alone.
fn stateLabel(arena: std.mem.Allocator, obj: json.ObjectMap, state: []const u8) ?[]const u8 {
    const idx_v = obj.get("step_index") orelse return state;
    if (idx_v != .integer or idx_v.integer < 0) return state;
    const idx: usize = @intCast(idx_v.integer);

    const pinned: ?[]const json.Value = if (obj.get("pipeline")) |p|
        (if (p == .array) p.array.items else null)
    else
        null;
    const total = if (pinned) |items| items.len else zygos.mission.pipeline.default_pipeline.len;
    if (idx >= total) return state;
    const id: []const u8 = if (pinned) |items| blk: {
        if (items[idx] != .object) return state;
        break :blk strOf(items[idx].object.get("id")) orelse return state;
    } else zygos.mission.pipeline.default_pipeline[idx].id;
    return std.fmt.allocPrint(arena, "{s} · {s} ({d}/{d})", .{ state, id, idx + 1, total }) catch null;
}

/// The AG-UI thread id for a trace whose events live in `dir_path`:
/// `mission_id` from its mission.json, else `task_id` from its trial.json
/// (Harbor writes one next to the agent's events.jsonl), else the
/// directory's basename.
pub fn threadId(arena: std.mem.Allocator, dir_path: []const u8, mission_json: ?[]const u8, trial_json: ?[]const u8) []const u8 {
    return stringField(arena, mission_json, "mission_id") orelse
        stringField(arena, trial_json, "task_id") orelse
        std.fs.path.basename(dir_path);
}

fn stringField(arena: std.mem.Allocator, text: ?[]const u8, key: []const u8) ?[]const u8 {
    const v = json.parseFromSliceLeaky(json.Value, arena, text orelse return null, .{}) catch return null;
    if (v != .object) return null;
    return strOf(v.object.get(key));
}

pub const AttachParse = union(enum) {
    cmd: zygos.control.Command,
    /// Human-readable rejection for the attach console; empty input is
    /// `ignore` (no message, no queue).
    err: []const u8,
    ignore,
};

/// Parse one attach console line: `steer <text>` | `pause` | `resume` |
/// `approve <id> [y|n]`. Slices in the returned command point into `line`.
pub fn parseAttachCommand(line: []const u8) AttachParse {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return .ignore;
    if (std.mem.eql(u8, trimmed, "pause")) return .{ .cmd = .pause };
    if (std.mem.eql(u8, trimmed, "resume")) return .{ .cmd = .@"resume" };
    if (std.mem.startsWith(u8, trimmed, "steer ")) {
        const text = std.mem.trim(u8, trimmed["steer ".len..], " \t");
        if (text.len == 0) return .{ .err = "steer needs text" };
        return .{ .cmd = .{ .steer = .{ .text = text } } };
    }
    if (std.mem.startsWith(u8, trimmed, "approve ")) {
        var it = std.mem.tokenizeScalar(u8, trimmed["approve ".len..], ' ');
        const id = it.next() orelse return .{ .err = "approve needs an id" };
        const verdict = it.next() orelse "n";
        return .{ .cmd = .{ .approve = .{
            .id = id,
            .approved = verdict.len > 0 and (verdict[0] == 'y' or verdict[0] == 'Y'),
        } } };
    }
    return .{ .err = "unknown command" };
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "dashboardLine: full snapshot renders one line with task and turn counts" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const line = dashboardLine(arena, "/runs/m1/mission.json",
        \\{"mission_id":"m1","state":"gating","stop":"none","role_turns_used":4,"step_index":4,
        \\ "tasks":[{"desc":"a","done":true},{"desc":"b","done":false}]}
    ).?;
    try testing.expectEqualStrings(
        "m1  gating (none)  tasks 1/2  role_turns 4  /runs/m1\n",
        line,
    );
}

test "dashboardLine: a running mission names the step at the cursor" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // No pipeline array: the default four ids apply.
    const dflt = dashboardLine(arena, "/runs/m1/mission.json",
        \\{"mission_id":"m1","state":"running","stop":"none","role_turns_used":4,"step_index":2,"tasks":[]}
    ).?;
    try testing.expectEqualStrings(
        "m1  running · executor (3/4) (none)  tasks 0/0  role_turns 4  /runs/m1\n",
        dflt,
    );
    // A pinned custom pipeline names the step and sets the length.
    const custom = dashboardLine(arena, "/runs/m2/mission.json",
        \\{"mission_id":"m2","state":"running","stop":"none","role_turns_used":1,"step_index":0,
        \\ "pipeline":[{"id":"architect","definition_sha256":"ab","tools":true},{"id":"executor","definition_sha256":null,"tools":true}],
        \\ "tasks":[]}
    ).?;
    try testing.expectEqualStrings(
        "m2  running · architect (1/2) (none)  tasks 0/0  role_turns 1  /runs/m2\n",
        custom,
    );
    // A failed mission keeps the step that failed.
    const failed = dashboardLine(arena, "/runs/m3/mission.json",
        \\{"mission_id":"m3","state":"failed","stop":"role_failed","role_turns_used":2,"step_index":1,"tasks":[]}
    ).?;
    try testing.expectEqualStrings(
        "m3  failed · planner (2/4) (role_failed)  tasks 0/0  role_turns 2  /runs/m3\n",
        failed,
    );
    // A cursor past the list (gating/done) or a pre-pipeline file shows the state alone.
    const past = dashboardLine(arena, "/runs/m4/mission.json",
        \\{"mission_id":"m4","state":"done","stop":"none","role_turns_used":2,"step_index":9,"tasks":[]}
    ).?;
    try testing.expectEqualStrings(
        "m4  done (none)  tasks 0/0  role_turns 2  /runs/m4\n",
        past,
    );
    const legacy = dashboardLine(arena, "/runs/m5/mission.json",
        \\{"mission_id":"m5","state":"executing","stop":"none","role_turns_used":4,"tasks":[]}
    ).?;
    try testing.expectEqualStrings(
        "m5  executing (none)  tasks 0/0  role_turns 4  /runs/m5\n",
        legacy,
    );
}

test "dashboardLine: malformed or non-object snapshots are skipped, fields default to ?" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqual(@as(?[]const u8, null), dashboardLine(arena, "p", "not json"));
    try testing.expectEqual(@as(?[]const u8, null), dashboardLine(arena, "p", "[]"));
    const line = dashboardLine(arena, "mission.json", "{}").?;
    try testing.expectEqualStrings("?  ? (?)  tasks 0/0  role_turns 0  mission.json\n", line);
}

test "threadId: mission.json wins, then trial.json, then the directory basename" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const mission =
        \\{"mission_id":"brief-radar","state":"failed"}
    ;
    const trial =
        \\{"task_id":"filter-js-from-html","variable":"trim-on"}
    ;
    try testing.expectEqualStrings("brief-radar", threadId(arena, "/runs/.planning-1", mission, trial));
    try testing.expectEqualStrings("filter-js-from-html", threadId(arena, "/jobs/t__a/agent", null, trial));
    try testing.expectEqualStrings("filter-js-from-html", threadId(arena, "/jobs/t__a/agent", "not json", trial));
    try testing.expectEqualStrings("agent", threadId(arena, "/jobs/t__a/agent", null, "{}"));
    try testing.expectEqualStrings(".planning-1", threadId(arena, ".planning-1", null, null));
}

test "parseAttachCommand: pause, resume, steer and approve verdicts" {
    try testing.expectEqual(zygos.control.Command.pause, parseAttachCommand(" pause ").cmd);
    try testing.expectEqual(zygos.control.Command.@"resume", parseAttachCommand("resume").cmd);
    const steer = parseAttachCommand("steer  focus on tests ").cmd;
    try testing.expectEqualStrings("focus on tests", steer.steer.text);
    const yes = parseAttachCommand("approve ap-1 y").cmd;
    try testing.expectEqualStrings("ap-1", yes.approve.id);
    try testing.expect(yes.approve.approved);
    const no_verdict = parseAttachCommand("approve ap-2").cmd;
    try testing.expect(!no_verdict.approve.approved);
}

test "parseAttachCommand: empty is ignored, junk and bare steer/approve are errors" {
    try testing.expectEqual(AttachParse.ignore, parseAttachCommand("   "));
    try testing.expectEqualStrings("unknown command", parseAttachCommand("dance").err);
    // Trailing whitespace is trimmed first, so bare "steer " / "approve "
    // read as unknown commands, not as missing-argument errors.
    try testing.expectEqualStrings("unknown command", parseAttachCommand("steer   ").err);
    try testing.expectEqualStrings("unknown command", parseAttachCommand("approve ").err);
}
