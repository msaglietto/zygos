//! Pure pipeline rules (docs/specs/mission.md "Pipeline module"): step kinds,
//! the default four, and config validation shared by the CLI (zygos.zon
//! `.steps`) and the worker (the start request's `steps`). std-only, no I/O.
//!
//! Every refusal is a reason string naming the entry (`steps[i]: ...`); an
//! invalid list never degrades to the default pipeline.

const std = @import("std");
const Zoir = std.zig.Zoir;

pub const Kind = enum { product_owner, planner, executor, verifier, custom };

pub fn kindOf(id: []const u8) Kind {
    const known = [_]struct { id: []const u8, kind: Kind }{
        .{ .id = "product-owner", .kind = .product_owner },
        .{ .id = "planner", .kind = .planner },
        .{ .id = "executor", .kind = .executor },
        .{ .id = "verifier", .kind = .verifier },
    };
    for (known) |k| if (std.mem.eql(u8, id, k.id)) return k.kind;
    return .custom;
}

pub const Step = struct {
    id: []const u8,
    kind: Kind,
    /// Pinned definition text; null for a built-in (the driver resolves the
    /// `role-<id>.md` override or the embedded prompt later).
    system: ?[]const u8,
    /// Lowercase hex sha256 of `system`; null for a built-in.
    definition_sha256: ?[]const u8,
    tools: bool,
};

/// One configured entry before validation. The CLI fills `definition_path`
/// (the file is loaded after validation); the worker fills `system` and
/// optionally `definition_sha256` (the CLI-pinned text and its hash).
pub const Entry = struct {
    id: ?[]const u8 = null,
    definition_path: ?[]const u8 = null,
    system: ?[]const u8 = null,
    definition_sha256: ?[]const u8 = null,
    tools: ?bool = null,
    unknown_key: ?[]const u8 = null,
};

pub const Outcome = union(enum) {
    /// Allocated from the caller's arena; `id`/`system` borrow from the entries.
    ok: []Step,
    refused: []const u8,
};

/// Ids the runtime owns: `task` is the headless task step, `tessera-capture`
/// the capture worker's turn id. A pipeline step must not share their routes.
const reserved_ids = [_][]const u8{ "task", "tessera-capture" };

const max_id_len = 32;

fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > max_id_len) return false;
    for (id) |c| {
        if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-')) return false;
    }
    return true;
}

fn refuse(arena: std.mem.Allocator, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!Outcome {
    return .{ .refused = try std.fmt.allocPrint(arena, fmt, args) };
}

/// The boot-refusal table, minus the file checks (the CLI loads definitions
/// after this). A step's `system` is set only when the entry carries one;
/// `definition_path` entries stay unpinned until the loader fills them.
pub fn validate(arena: std.mem.Allocator, entries: []const Entry) error{OutOfMemory}!Outcome {
    if (entries.len == 0) return refuse(arena, "steps: empty", .{});
    const steps = try arena.alloc(Step, entries.len);
    var has_executor = false;
    for (entries, steps, 0..) |e, *out, i| {
        if (e.unknown_key) |k| return refuse(arena, "steps[{d}]: unknown key \"{s}\"", .{ i, k });
        const id = e.id orelse return refuse(arena, "steps[{d}]: missing id", .{i});
        if (!validId(id)) return refuse(arena, "steps[{d}]: bad id", .{i});
        for (reserved_ids) |r| {
            if (std.mem.eql(u8, id, r)) return refuse(arena, "steps[{d}]: reserved id", .{i});
        }
        const kind = kindOf(id);
        const tools = e.tools orelse (kind == .executor);
        if (kind == .verifier and tools) {
            return refuse(arena, "steps[{d}]: verifier cannot have tools", .{i});
        }
        const pinned_blank = if (e.system) |t| std.mem.trim(u8, t, &std.ascii.whitespace).len == 0 else false;
        const defined = (e.definition_path != null or e.system != null) and !pinned_blank;
        // A blank pinned text would silence the step's prompt, built-in or not.
        if (pinned_blank or (kind == .custom and !defined)) {
            return refuse(arena, "steps[{d}]: no definition", .{i});
        }

        var sha: ?[]const u8 = null;
        if (e.system) |text| {
            const computed = sha256Hex(text);
            if (e.definition_sha256) |declared| {
                if (!std.mem.eql(u8, declared, &computed)) {
                    return refuse(arena, "steps[{d}]: definition hash mismatch", .{i});
                }
            }
            sha = try arena.dupe(u8, &computed);
        } else if (e.definition_sha256 != null) {
            return refuse(arena, "steps[{d}]: definition hash mismatch", .{i});
        }

        if (kind == .executor) has_executor = true;
        out.* = .{ .id = id, .kind = kind, .system = e.system, .definition_sha256 = sha, .tools = tools };
    }
    if (!has_executor) return refuse(arena, "steps: no executor", .{});
    return .{ .ok = steps };
}

pub const default_pipeline = [_]Step{
    .{ .id = "product-owner", .kind = .product_owner, .system = null, .definition_sha256 = null, .tools = false },
    .{ .id = "planner", .kind = .planner, .system = null, .definition_sha256 = null, .tools = false },
    .{ .id = "executor", .kind = .executor, .system = null, .definition_sha256 = null, .tools = true },
    .{ .id = "verifier", .kind = .verifier, .system = null, .definition_sha256 = null, .tools = false },
};

pub fn defaultSteps(arena: std.mem.Allocator) error{OutOfMemory}![]Step {
    return arena.dupe(Step, &default_pipeline);
}

pub const DefinitionPathError = error{DefinitionPath};

/// Shape check only: no absolute path, no `..` component. The CLI adds the
/// realpath containment check.
pub fn checkDefinitionPath(path: []const u8) DefinitionPathError!void {
    if (path.len == 0 or path[0] == '/') return error.DefinitionPath;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return error.DefinitionPath;
    }
}

pub fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

pub const ZonSteps = union(enum) {
    /// No `.steps` key: the default pipeline.
    absent,
    entries: []Entry,
    refused: []const u8,
};

/// Strict extraction of `.steps` from the full zygos.zon text. Other
/// top-level keys are ignored. `scratch` holds the AST and is released
/// before returning; entries and their strings live in `arena`.
pub fn parseZon(scratch: std.mem.Allocator, arena: std.mem.Allocator, text: [:0]const u8) error{ OutOfMemory, ParseZon }!ZonSteps {
    var ast = try std.zig.Ast.parse(scratch, text, .zon);
    defer ast.deinit(scratch);
    const zoir = try std.zig.ZonGen.generate(scratch, ast, .{});
    defer zoir.deinit(scratch);
    if (ast.errors.len > 0 or zoir.hasCompileErrors()) return error.ParseZon;

    const root = Zoir.Node.Index.root.get(zoir);
    const fields = switch (root) {
        .struct_literal => |s| s,
        else => return .absent,
    };
    const steps_node = for (fields.names, 0..) |name, k| {
        if (std.mem.eql(u8, name.get(zoir), "steps")) break fields.vals.at(@intCast(k));
    } else return .absent;

    const items: ?Zoir.Node.Index.Range = switch (steps_node.get(zoir)) {
        .empty_literal => null,
        .array_literal => |r| r,
        else => return .{ .refused = "steps: malformed" },
    };
    const count: usize = if (items) |r| r.len else 0;
    const entries = try arena.alloc(Entry, count);
    for (entries, 0..) |*entry, i| {
        entry.* = .{};
        const node = items.?.at(@intCast(i)).get(zoir);
        const names, const vals = switch (node) {
            .empty_literal => continue,
            .struct_literal => |s| .{ s.names, s.vals },
            else => return .{ .refused = try std.fmt.allocPrint(arena, "steps[{d}]: malformed", .{i}) },
        };
        for (names, 0..) |name_nts, k| {
            const name = name_nts.get(zoir);
            const val = vals.at(@intCast(k)).get(zoir);
            if (std.mem.eql(u8, name, "id")) {
                entry.id = switch (val) {
                    .string_literal => |str| try arena.dupe(u8, str),
                    else => return .{ .refused = try std.fmt.allocPrint(arena, "steps[{d}]: bad id", .{i}) },
                };
            } else if (std.mem.eql(u8, name, "definition")) {
                entry.definition_path = switch (val) {
                    .string_literal => |str| try arena.dupe(u8, str),
                    else => return .{ .refused = try std.fmt.allocPrint(arena, "steps[{d}]: definition path", .{i}) },
                };
            } else if (std.mem.eql(u8, name, "tools")) {
                entry.tools = switch (val) {
                    .true => true,
                    .false => false,
                    else => return .{ .refused = try std.fmt.allocPrint(arena, "steps[{d}]: bad tools", .{i}) },
                };
            } else if (entry.unknown_key == null) {
                entry.unknown_key = try arena.dupe(u8, name);
            }
        }
    }
    return .{ .entries = entries };
}

// ===========================================================================
// Layer 2: cursor, seeds, executor rule, fix tasks, counters, prompts
// Pure functions over the pinned step list and the persisted counters; the
// driver (mission.zig) owns all I/O. Results are allocated from the caller's
// arena and never freed individually.
// ===========================================================================

const model = @import("model.zig");

pub const Task = model.Task;

// -- cursor ---------------------------------------------------------------

pub const Advance = union(enum) {
    /// The next `step_index`.
    step: usize,
    /// The cursor passed the last step: the driver fires `steps_done`.
    steps_done,
};

pub fn advance(step_count: usize, step_index: usize) Advance {
    const next = step_index +| 1;
    return if (next < step_count) .{ .step = next } else .steps_done;
}

// -- MISSION / PLAN texts ---------------------------------------------------

pub const seed_acceptance = "per the operator brief";

/// The driver seeds MISSION.md at start iff no product-owner opens the list.
pub fn needsMissionSeed(steps: []const Step) bool {
    return steps.len > 0 and steps[0].kind != .product_owner;
}

/// MISSION.md in the exact format the product-owner step writes.
pub fn missionText(arena: std.mem.Allocator, mission_id: []const u8, objective: []const u8, acceptance: []const u8) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(
        arena,
        "# Mission {s}\n\n## Objective\n\n{s}\n\n## Acceptance\n\n{s}\n",
        .{ mission_id, objective, acceptance },
    );
}

pub fn seedMissionText(arena: std.mem.Allocator, mission_id: []const u8, objective: []const u8) error{OutOfMemory}![]u8 {
    return missionText(arena, mission_id, objective, seed_acceptance);
}

/// PLAN.md in the format the planner step writes; done tasks are checked.
/// A fix task renders as a one-line summary so the file stays a flat list.
pub fn planText(arena: std.mem.Allocator, tasks: []const Task) error{OutOfMemory}![]u8 {
    var md: std.ArrayList(u8) = .empty;
    try md.appendSlice(arena, "# Plan\n\n");
    for (tasks) |t| {
        try md.appendSlice(arena, if (t.done) "- [x] " else "- [ ] ");
        try md.appendSlice(arena, try taskLabel(arena, t.desc));
        try md.append(arena, '\n');
    }
    return md.items;
}

fn taskLabel(arena: std.mem.Allocator, desc: []const u8) error{OutOfMemory}![]const u8 {
    const fix = (try parseFixTask(arena, desc)) orelse return desc;
    switch (fix) {
        .feedback => |fb| {
            const first = if (std.mem.indexOfScalar(u8, fb, '\n')) |nl| fb[0..nl] else fb;
            return std.fmt.allocPrint(arena, "fix: {s}", .{first});
        },
        .artifacts => |names| {
            var out: std.ArrayList(u8) = .empty;
            try out.appendSlice(arena, "fix: address findings in");
            for (names, 0..) |n, i| {
                try out.appendSlice(arena, if (i == 0) " " else ", ");
                try out.appendSlice(arena, n);
            }
            return out.items;
        },
    }
}

// -- artifact names and run counters ---------------------------------------

/// The single-file artifact a known kind writes; null for custom steps.
pub fn fixedArtifact(kind: Kind) ?[]const u8 {
    return switch (kind) {
        .product_owner => "MISSION.md",
        .planner => "PLAN.md",
        .executor => "EXEC.md",
        .verifier => "VERIFY.md",
        .custom => null,
    };
}

pub fn stepArtifactName(arena: std.mem.Allocator, id: []const u8, n: usize) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(arena, "step-{s}-{d}.md", .{ id, n });
}

pub const RunCount = struct { id: []const u8, count: usize };

/// id -> run count (rework re-runs included). A plain pair list so the store
/// can serialize it; ids are duplicated into the arena on first bump.
pub const StepRuns = struct {
    items: []RunCount = &.{},

    pub fn get(self: StepRuns, id: []const u8) usize {
        for (self.items) |r| if (std.mem.eql(u8, r.id, id)) return r.count;
        return 0;
    }

    /// Returns the new count, which is the `n` of this run's artifact name.
    pub fn bump(self: *StepRuns, arena: std.mem.Allocator, id: []const u8) error{OutOfMemory}!usize {
        for (self.items) |*r| {
            if (std.mem.eql(u8, r.id, id)) {
                r.count += 1;
                return r.count;
            }
        }
        const grown = try arena.alloc(RunCount, self.items.len + 1);
        @memcpy(grown[0..self.items.len], self.items);
        grown[self.items.len] = .{ .id = try arena.dupe(u8, id), .count = 1 };
        self.items = grown;
        return 1;
    }
};

pub const Versioned = enum { mission, plan };

pub const Archive = struct {
    /// Where the previous version goes: `MISSION-<n>.md` / `PLAN-<n>.md`.
    name: []const u8,
    /// The counter value to persist once the archive is written.
    versions: usize,
};

/// Names the next free archive slot from the persisted counter. The driver
/// calls this only when a previous version exists, writes it under `name`,
/// then writes the rewrite onto the live file; the counter only grows, so a
/// name is never reused.
pub fn archive(arena: std.mem.Allocator, which: Versioned, versions: usize) error{OutOfMemory}!Archive {
    const base = switch (which) {
        .mission => "MISSION",
        .plan => "PLAN",
    };
    return .{
        .name = try std.fmt.allocPrint(arena, "{s}-{d}.md", .{ base, versions + 1 }),
        .versions = versions + 1,
    };
}

// -- artifacts written so far ----------------------------------------------

fn idSeenBefore(steps: []const Step, upto: usize, id: []const u8) bool {
    for (steps[0..upto]) |s| if (std.mem.eql(u8, s.id, id)) return true;
    return false;
}

fn appendRuns(
    arena: std.mem.Allocator,
    list: *std.ArrayList([]const u8),
    step: Step,
    first_run: usize,
    last_run: usize,
) error{OutOfMemory}!void {
    if (fixedArtifact(step.kind)) |name| return list.append(arena, name);
    var n = first_run;
    while (n <= last_run) : (n += 1) try list.append(arena, try stepArtifactName(arena, step.id, n));
}

/// Every artifact written so far: all runs of all steps in step order, each
/// id once (at its first occurrence), including steps after the cursor that
/// ran in an earlier pass. The custom-step input.
pub fn artifactsSoFar(arena: std.mem.Allocator, steps: []const Step, runs: StepRuns) error{OutOfMemory}![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    for (steps, 0..) |s, i| {
        if (idSeenBefore(steps, i, s.id)) continue;
        const n = runs.get(s.id);
        if (n == 0) continue;
        try appendRuns(arena, &list, s, 1, n);
    }
    return list.items;
}

/// Every `step-*.md` written so far, appended to each known kind's input.
pub fn stepArtifactsSoFar(arena: std.mem.Allocator, steps: []const Step, runs: StepRuns) error{OutOfMemory}![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    for (steps, 0..) |s, i| {
        if (s.kind != .custom or idSeenBefore(steps, i, s.id)) continue;
        try appendRuns(arena, &list, s, 1, runs.get(s.id));
    }
    return list.items;
}

fn lastExecutorBefore(steps: []const Step, before: usize) ?usize {
    var i = @min(before, steps.len);
    while (i > 0) {
        i -= 1;
        if (steps[i].kind == .executor) return i;
    }
    return null;
}

/// Artifacts written since the previous executor run: the steps strictly
/// between the previous executor occurrence and the cursor that have run,
/// where an id occurring k times in that span contributes its last k runs.
/// An empty result (no previous executor, empty span, or nothing ran) falls
/// back to every artifact written so far.
pub fn fixSources(arena: std.mem.Allocator, steps: []const Step, step_index: usize, runs: StepRuns) error{OutOfMemory}![]const []const u8 {
    const cursor = @min(step_index, steps.len);
    if (lastExecutorBefore(steps, cursor)) |prev| {
        const span = steps[prev + 1 .. cursor];
        var list: std.ArrayList([]const u8) = .empty;
        for (span, 0..) |s, i| {
            if (idSeenBefore(span, i, s.id)) continue;
            const n = runs.get(s.id);
            if (n == 0) continue;
            var k: usize = 0;
            for (span) |o| {
                if (std.mem.eql(u8, o.id, s.id)) k += 1;
            }
            const first = if (n >= k) n - k + 1 else 1;
            try appendRuns(arena, &list, s, first, n);
        }
        if (list.items.len > 0) return list.items;
    }
    return artifactsSoFar(arena, steps, runs);
}

// -- fix tasks ---------------------------------------------------------------

/// A fix task is an ordinary `Task` whose desc opens with one of these header
/// lines, so no persisted field is added. A desc that merely resembles one
/// parses as null, which makes it an ordinary task.
const fix_feedback_header = "[zygos fix-task: feedback]";
const fix_artifacts_header = "[zygos fix-task: artifacts]";

pub const FixTask = union(enum) {
    /// Feedback text (verify-fail or gate-denial reason), borrowed from the desc.
    feedback: []const u8,
    /// Source artifact names, each a bare filename; borrowed from the desc.
    artifacts: []const []const u8,
};

/// desc = header, "\n", feedback verbatim.
pub fn feedbackTask(arena: std.mem.Allocator, feedback: []const u8) error{OutOfMemory}!Task {
    return .{ .desc = try std.fmt.allocPrint(arena, "{s}\n{s}", .{ fix_feedback_header, feedback }) };
}

/// desc = header, then "\n<name>" per source artifact.
pub fn artifactsTask(arena: std.mem.Allocator, names: []const []const u8) error{OutOfMemory}!Task {
    var desc: std.ArrayList(u8) = .empty;
    try desc.appendSlice(arena, fix_artifacts_header);
    for (names) |n| {
        try desc.append(arena, '\n');
        try desc.appendSlice(arena, n);
    }
    return .{ .desc = desc.items };
}

fn bareName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (c == '/' or c == '\\' or std.ascii.isWhitespace(c) or std.ascii.isControl(c)) return false;
    }
    return true;
}

pub fn parseFixTask(arena: std.mem.Allocator, desc: []const u8) error{OutOfMemory}!?FixTask {
    if (std.mem.startsWith(u8, desc, fix_feedback_header)) {
        const rest = desc[fix_feedback_header.len..];
        if (rest.len == 0 or rest[0] != '\n') return null;
        return .{ .feedback = rest[1..] };
    }
    if (std.mem.startsWith(u8, desc, fix_artifacts_header)) {
        const rest = desc[fix_artifacts_header.len..];
        if (rest.len == 0) return .{ .artifacts = &.{} };
        if (rest[0] != '\n') return null;
        var names: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, rest[1..], '\n');
        while (it.next()) |n| {
            if (!bareName(n)) return null;
            try names.append(arena, n);
        }
        return .{ .artifacts = names.items };
    }
    return null;
}

pub fn appendTask(arena: std.mem.Allocator, tasks: []const Task, task: Task) error{OutOfMemory}![]Task {
    const grown = try arena.alloc(Task, tasks.len + 1);
    @memcpy(grown[0..tasks.len], tasks);
    grown[tasks.len] = task;
    return grown;
}

// -- executor rule -------------------------------------------------------------

pub fn firstUnfinished(tasks: []const Task) ?usize {
    for (tasks, 0..) |t, i| if (!t.done) return i;
    return null;
}

pub const ExecutorEntry = enum {
    /// No tasks existed: one task equal to the objective was seeded.
    seeded,
    /// Unfinished tasks exist: run from the first.
    run_unfinished,
    /// Every task was done: one fix task from artifacts was appended.
    fix_appended,
};

pub const Arrival = struct {
    entry: ExecutorEntry,
    tasks: []Task,
    /// The task to run now.
    task_index: usize,
    /// Non-null only for `.seeded`: the PLAN.md text to write.
    plan_md: ?[]const u8,
};

/// What the cursor does on arriving at an `executor` occurrence.
pub fn arriveAtExecutor(
    arena: std.mem.Allocator,
    objective: []const u8,
    tasks: []const Task,
    steps: []const Step,
    step_index: usize,
    runs: StepRuns,
) error{OutOfMemory}!Arrival {
    if (tasks.len == 0) {
        const seeded = try arena.dupe(Task, &.{.{ .desc = objective }});
        return .{ .entry = .seeded, .tasks = seeded, .task_index = 0, .plan_md = try planText(arena, seeded) };
    }
    if (firstUnfinished(tasks)) |i| {
        return .{ .entry = .run_unfinished, .tasks = try arena.dupe(Task, tasks), .task_index = i, .plan_md = null };
    }
    const sources = try fixSources(arena, steps, step_index, runs);
    return .{
        .entry = .fix_appended,
        .tasks = try appendTask(arena, tasks, try artifactsTask(arena, sources)),
        .task_index = tasks.len,
        .plan_md = null,
    };
}

pub const AfterTask = union(enum) {
    /// Unfinished tasks remain: fire `task_done`, run this index next.
    task_done: usize,
    /// None remain: the executor step is complete.
    step_done,
};

pub fn afterTask(tasks: []const Task) AfterTask {
    return if (firstUnfinished(tasks)) |i| .{ .task_done = i } else .step_done;
}

// -- planner repeat -------------------------------------------------------------

pub const Replan = struct {
    tasks: []Task,
    /// Index of the first new task.
    task_index: usize,
};

/// A planner occurrence's tasks replace the unfinished tasks; done tasks stay
/// done (with their results), ahead of the new ones.
pub fn replaceUnfinished(arena: std.mem.Allocator, tasks: []const Task, new_descs: []const []const u8) error{OutOfMemory}!Replan {
    var out: std.ArrayList(Task) = .empty;
    for (tasks) |t| if (t.done) try out.append(arena, t);
    const first_new = out.items.len;
    for (new_descs) |d| try out.append(arena, .{ .desc = d });
    return .{ .tasks = out.items, .task_index = first_new };
}

// -- rework targets -------------------------------------------------------------

/// `verify_failed` at `verifier_index`: the last executor before it, else the
/// first executor in the list. Null (no executor) must fail closed.
pub fn verifyReworkTarget(steps: []const Step, verifier_index: usize) ?usize {
    if (lastExecutorBefore(steps, verifier_index)) |i| return i;
    for (steps, 0..) |s, i| if (s.kind == .executor) return i;
    return null;
}

/// `gate_denied`: the last executor in the list.
pub fn gateReworkTarget(steps: []const Step) ?usize {
    return lastExecutorBefore(steps, steps.len);
}

// -- system prompts --------------------------------------------------------------

const ws = &std.ascii.whitespace;

const builtin_product_owner = std.mem.trim(u8, @embedFile("agents/product-owner.md"), ws);
const builtin_planner = std.mem.trim(u8, @embedFile("agents/planner.md"), ws);
const builtin_executor = std.mem.trim(u8, @embedFile("agents/executor.md"), ws);
const builtin_verifier = std.mem.trim(u8, @embedFile("agents/verifier.md"), ws);

/// Behaviour text only; null for custom kinds.
pub fn builtInPrompt(kind: Kind) ?[]const u8 {
    return switch (kind) {
        .product_owner => builtin_product_owner,
        .planner => builtin_planner,
        .executor => builtin_executor,
        .verifier => builtin_verifier,
        .custom => null,
    };
}

/// The reply-format sentence the driver appends after whichever prompt won;
/// null for executor and custom kinds.
pub fn replyContract(kind: Kind) ?[]const u8 {
    return switch (kind) {
        .product_owner => "Reply with ONLY a JSON object: " ++
            "{\"objective\": <one precise sentence>, \"acceptance\": <how completion is judged>}.",
        .planner => "Reply with ONLY a JSON object: {\"tasks\": [<task description>, ...]}.",
        .verifier => "Reply with ONLY a JSON object: {\"passed\": true|false, \"reason\": <one sentence>}.",
        .executor, .custom => null,
    };
}

fn nonBlank(text: ?[]const u8) ?[]const u8 {
    const t = std.mem.trim(u8, text orelse return null, ws);
    return if (t.len == 0) null else t;
}

/// Pinned `step.system` > non-blank `role_override` (the caller's
/// `role-<id>.md`) > built-in, then the kind's reply contract. Null when a
/// custom step has neither a pinned text nor an override (fail closed).
/// May borrow from its inputs when no contract is appended.
pub fn systemPrompt(arena: std.mem.Allocator, step: Step, role_override: ?[]const u8) error{OutOfMemory}!?[]const u8 {
    const base = nonBlank(step.system) orelse nonBlank(role_override) orelse builtInPrompt(step.kind) orelse return null;
    const contract = replyContract(step.kind) orelse return base;
    return try std.fmt.allocPrint(arena, "{s} {s}", .{ base, contract });
}

// ===========================================================================
// Tests (docs/specs/mission.md test contract 4-6, RED first)
// ===========================================================================

const testing = std.testing;

fn expectRefusal(entries: []const Entry, want: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    switch (try validate(arena_state.allocator(), entries)) {
        .ok => return error.TestExpectedRefusal,
        .refused => |reason| try testing.expectEqualStrings(want, reason),
    }
}

fn expectOk(arena: std.mem.Allocator, entries: []const Entry) ![]Step {
    switch (try validate(arena, entries)) {
        .ok => |steps| return steps,
        .refused => |reason| {
            std.debug.print("unexpected refusal: {s}\n", .{reason});
            return error.TestUnexpectedRefusal;
        },
    }
}

test "kindOf: the four known ids, everything else custom" {
    try testing.expectEqual(Kind.product_owner, kindOf("product-owner"));
    try testing.expectEqual(Kind.planner, kindOf("planner"));
    try testing.expectEqual(Kind.executor, kindOf("executor"));
    try testing.expectEqual(Kind.verifier, kindOf("verifier"));
    try testing.expectEqual(Kind.custom, kindOf("architect"));
    try testing.expectEqual(Kind.custom, kindOf("Executor"));
    try testing.expectEqual(Kind.custom, kindOf(""));
}

test "absent steps is the default four with executor-only tools" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try parseZon(testing.allocator, arena,
        \\.{ .default = .{}, .routes = .{}, .context_strategy = .{ .kind = "recall" } }
    );
    try testing.expect(parsed == .absent);

    const steps = try defaultSteps(arena);
    const want_ids = [_][]const u8{ "product-owner", "planner", "executor", "verifier" };
    const want_kinds = [_]Kind{ .product_owner, .planner, .executor, .verifier };
    const want_tools = [_]bool{ false, false, true, false };
    try testing.expectEqual(@as(usize, 4), steps.len);
    for (steps, 0..) |s, i| {
        try testing.expectEqualStrings(want_ids[i], s.id);
        try testing.expectEqual(want_kinds[i], s.kind);
        try testing.expectEqual(want_tools[i], s.tools);
        try testing.expect(s.system == null);
        try testing.expect(s.definition_sha256 == null);
    }
}

test "the default four validates as an explicit list" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const steps = try expectOk(arena, &.{
        .{ .id = "product-owner" }, .{ .id = "planner" }, .{ .id = "executor" }, .{ .id = "verifier" },
    });
    for (steps, &default_pipeline) |got, want| {
        try testing.expectEqualStrings(want.id, got.id);
        try testing.expectEqual(want.kind, got.kind);
        try testing.expectEqual(want.tools, got.tools);
    }
}

test "boot refusal: empty list" {
    try expectRefusal(&.{}, "steps: empty");
}

test "boot refusal: unknown key" {
    try expectRefusal(&.{
        .{ .id = "executor" },
        .{ .id = "verifier", .unknown_key = "model" },
    }, "steps[1]: unknown key \"model\"");
}

test "boot refusal: missing id" {
    try expectRefusal(&.{ .{ .id = "executor" }, .{} }, "steps[1]: missing id");
}

test "boot refusal: bad id" {
    const bad = [_][]const u8{
        "",        "Executor", "my_step", "has space", "dot.id",
        "ünï",
        "a" ** 33,
    };
    for (bad) |id| {
        try expectRefusal(&.{ .{ .id = "executor" }, .{ .id = id } }, "steps[1]: bad id");
    }
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    _ = try expectOk(arena_state.allocator(), &.{
        .{ .id = "executor" },
        .{ .id = "a", .system = "x" },
        .{ .id = "a-1-" ++ "z" ** 28, .system = "x" },
    });
}

test "boot refusal: reserved id" {
    try expectRefusal(&.{ .{ .id = "executor" }, .{ .id = "task", .system = "x" } }, "steps[1]: reserved id");
    try expectRefusal(&.{ .{ .id = "tessera-capture", .system = "x" }, .{ .id = "executor" } }, "steps[0]: reserved id");
}

test "boot refusal: no executor" {
    try expectRefusal(&.{ .{ .id = "planner" }, .{ .id = "verifier" } }, "steps: no executor");
}

test "boot refusal: verifier with tools" {
    try expectRefusal(&.{
        .{ .id = "executor" },
        .{ .id = "verifier", .tools = true },
    }, "steps[1]: verifier cannot have tools");
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const steps = try expectOk(arena_state.allocator(), &.{
        .{ .id = "executor" },
        .{ .id = "verifier", .tools = false },
    });
    try testing.expect(!steps[1].tools);
}

test "boot refusal: custom without definition" {
    try expectRefusal(&.{ .{ .id = "architect" }, .{ .id = "executor" } }, "steps[0]: no definition");
    // A whitespace-only pinned text is no definition either.
    try expectRefusal(&.{ .{ .id = "architect", .system = " \n\t" }, .{ .id = "executor" } }, "steps[0]: no definition");
    try expectRefusal(&.{.{ .id = "executor", .system = "" }}, "steps[0]: no definition");
}

test "boot refusal: definition path absolute" {
    try testing.expectError(error.DefinitionPath, checkDefinitionPath("/etc/passwd"));
    try testing.expectError(error.DefinitionPath, checkDefinitionPath("/"));
    try checkDefinitionPath("agents/architect.md");
    try checkDefinitionPath("architect.md");
}

test "boot refusal: definition path with .." {
    try testing.expectError(error.DefinitionPath, checkDefinitionPath(".."));
    try testing.expectError(error.DefinitionPath, checkDefinitionPath("../a.md"));
    try testing.expectError(error.DefinitionPath, checkDefinitionPath("a/../b.md"));
    try testing.expectError(error.DefinitionPath, checkDefinitionPath("a/.."));
    try testing.expectError(error.DefinitionPath, checkDefinitionPath(""));
    // `..` inside a component name is not a parent reference.
    try checkDefinitionPath("a..b/c..md");
    try checkDefinitionPath("..hidden.md");
}

test "tools=true is allowed on product-owner, planner and custom steps" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const steps = try expectOk(arena_state.allocator(), &.{
        .{ .id = "product-owner", .tools = true },
        .{ .id = "planner", .tools = true },
        .{ .id = "architect", .system = "design it", .tools = true },
        .{ .id = "executor", .tools = false },
    });
    try testing.expect(steps[0].tools);
    try testing.expect(steps[1].tools);
    try testing.expect(steps[2].tools);
    try testing.expect(!steps[3].tools);
    try testing.expectEqual(Kind.custom, steps[2].kind);
}

test "duplicate ids are accepted and each occurrence keeps its own definition and tools" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const steps = try expectOk(arena_state.allocator(), &.{
        .{ .id = "executor", .system = "first", .tools = true },
        .{ .id = "reviewer", .system = "review" },
        .{ .id = "executor", .system = "second", .tools = false },
        .{ .id = "verifier" },
    });
    try testing.expectEqual(@as(usize, 4), steps.len);
    try testing.expectEqualStrings("first", steps[0].system.?);
    try testing.expect(steps[0].tools);
    try testing.expectEqualStrings("second", steps[2].system.?);
    try testing.expect(!steps[2].tools);
    try testing.expect(!std.mem.eql(u8, steps[0].definition_sha256.?, steps[2].definition_sha256.?));
}

test "a pinned definition without a hash gets one; a matching hash passes; a wrong or orphan hash refuses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const want = sha256Hex("design it");

    const computed = try expectOk(arena, &.{
        .{ .id = "architect", .system = "design it" },
        .{ .id = "executor" },
    });
    try testing.expectEqualStrings(&want, computed[0].definition_sha256.?);
    try testing.expect(computed[1].definition_sha256 == null);

    const declared = try expectOk(arena, &.{
        .{ .id = "architect", .system = "design it", .definition_sha256 = &want },
        .{ .id = "executor" },
    });
    try testing.expectEqualStrings(&want, declared[0].definition_sha256.?);

    try expectRefusal(&.{
        .{ .id = "architect", .system = "design it changed", .definition_sha256 = &want },
        .{ .id = "executor" },
    }, "steps[0]: definition hash mismatch");
    try expectRefusal(&.{
        .{ .id = "executor", .definition_sha256 = &want },
    }, "steps[0]: definition hash mismatch");
}

test "a definition path counts as a definition before the file is loaded" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const steps = try expectOk(arena_state.allocator(), &.{
        .{ .id = "architect", .definition_path = "agents/architect.md" },
        .{ .id = "executor" },
    });
    try testing.expect(steps[0].system == null);
}

test "refusals report the first offending entry in list order" {
    try expectRefusal(&.{
        .{ .id = "architect", .system = "x" },
        .{ .id = "BAD" },
        .{ .unknown_key = "k" },
    }, "steps[1]: bad id");
}

// -- .steps zon parser --------------------------------------------------------

test "zon steps: entries carry id, definition and tools; other top-level keys are ignored" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const out = try parseZon(testing.allocator, arena,
        \\.{
        \\    .default = .{ .{ .provider_function = "zygos::providers::x", .model = "m" } },
        \\    .routes = .{},
        \\    .mcp_servers = .{},
        \\    .steps = .{
        \\        .{ .id = "architect", .definition = "agents/architect.md", .tools = true },
        \\        .{ .id = "executor" },
        \\        .{ .id = "verifier", .tools = false },
        \\    },
        \\}
    );
    const entries = out.entries;
    try testing.expectEqual(@as(usize, 3), entries.len);
    try testing.expectEqualStrings("architect", entries[0].id.?);
    try testing.expectEqualStrings("agents/architect.md", entries[0].definition_path.?);
    try testing.expectEqual(@as(?bool, true), entries[0].tools);
    try testing.expectEqualStrings("executor", entries[1].id.?);
    try testing.expect(entries[1].definition_path == null);
    try testing.expect(entries[1].tools == null);
    try testing.expectEqual(@as(?bool, false), entries[2].tools);
    for (entries) |e| try testing.expect(e.unknown_key == null);
}

test "zon steps: a single-entry list and escaped strings parse" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const out = try parseZon(testing.allocator, arena_state.allocator(),
        \\.{ .steps = .{ .{ .id = "executor", .definition = "a\\b.md" } } }
    );
    try testing.expectEqual(@as(usize, 1), out.entries.len);
    try testing.expectEqualStrings("a\\b.md", out.entries[0].definition_path.?);
}

test "zon steps: an empty list parses and then refuses as empty" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const out = try parseZon(testing.allocator, arena, ".{ .steps = .{} }");
    try testing.expectEqual(@as(usize, 0), out.entries.len);
    switch (try validate(arena, out.entries)) {
        .ok => return error.TestExpectedRefusal,
        .refused => |r| try testing.expectEqualStrings("steps: empty", r),
    }
}

test "zon steps: an unknown entry key and a missing id surface through validate" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const unknown = try parseZon(testing.allocator, arena,
        \\.{ .steps = .{ .{ .id = "executor" }, .{ .id = "verifier", .model = "x" } } }
    );
    switch (try validate(arena, unknown.entries)) {
        .ok => return error.TestExpectedRefusal,
        .refused => |r| try testing.expectEqualStrings("steps[1]: unknown key \"model\"", r),
    }

    const no_id = try parseZon(testing.allocator, arena, ".{ .steps = .{ .{ .id = \"executor\" }, .{} } }");
    switch (try validate(arena, no_id.entries)) {
        .ok => return error.TestExpectedRefusal,
        .refused => |r| try testing.expectEqualStrings("steps[1]: missing id", r),
    }
}

test "zon steps: wrongly typed values refuse with a reason naming the entry" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_]struct { zon: [:0]const u8, want: []const u8 }{
        .{ .zon = ".{ .steps = 5 }", .want = "steps: malformed" },
        .{ .zon = ".{ .steps = .{ .id = \"executor\" } }", .want = "steps: malformed" },
        .{ .zon = ".{ .steps = null }", .want = "steps: malformed" },
        .{ .zon = ".{ .steps = .{ \"executor\" } }", .want = "steps[0]: malformed" },
        .{ .zon = ".{ .steps = .{ .{ .id = 5 } } }", .want = "steps[0]: bad id" },
        .{ .zon = ".{ .steps = .{ .{ .id = \"executor\" }, .{ .id = \"x\", .tools = \"yes\" } } }", .want = "steps[1]: bad tools" },
        .{ .zon = ".{ .steps = .{ .{ .id = \"x\", .definition = 7 } } }", .want = "steps[0]: definition path" },
    };
    for (cases) |c| {
        const out = try parseZon(testing.allocator, arena, c.zon);
        try testing.expectEqualStrings(c.want, out.refused);
    }
}

test "zon steps: syntactically broken zon is a ParseZon error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(error.ParseZon, parseZon(testing.allocator, arena_state.allocator(), ".{ .steps = .{ "));
}

test "zon steps: the parser releases its scratch allocations" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    _ = try parseZon(testing.allocator, arena_state.allocator(), ".{ .steps = .{ .{ .id = \"executor\" } } }");
    _ = try parseZon(testing.allocator, arena_state.allocator(), ".{ .steps = 5 }");
    try testing.expectError(error.ParseZon, parseZon(testing.allocator, arena_state.allocator(), ".{ .steps = "));
}

// ===========================================================================
// Layer 2: cursor, seeds, executor rule, fix tasks, counters, prompts
// ===========================================================================

fn mk(id: []const u8) Step {
    return .{ .id = id, .kind = kindOf(id), .system = null, .definition_sha256 = null, .tools = kindOf(id) == .executor };
}

fn expectNames(want: []const []const u8, got: []const []const u8) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

fn runsOf(arena: std.mem.Allocator, pairs: []const RunCount) !StepRuns {
    return .{ .items = try arena.dupe(RunCount, pairs) };
}

test "advance moves one step and reports steps_done past the end" {
    try testing.expectEqual(Advance{ .step = 1 }, advance(4, 0));
    try testing.expectEqual(Advance{ .step = 3 }, advance(4, 2));
    try testing.expectEqual(Advance.steps_done, advance(4, 3));
    try testing.expectEqual(Advance.steps_done, advance(1, 0));
    try testing.expectEqual(Advance.steps_done, advance(4, 9));
}

test "MISSION seed iff step 0 is not product-owner" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expect(!needsMissionSeed(&.{ mk("product-owner"), mk("executor") }));
    try testing.expect(needsMissionSeed(&.{ mk("executor"), mk("verifier") }));
    try testing.expect(needsMissionSeed(&.{ mk("architect"), mk("product-owner"), mk("executor") }));
    try testing.expect(needsMissionSeed(&.{ mk("planner"), mk("executor") }));
    try testing.expect(!needsMissionSeed(&.{}));

    // Byte-identical to what roleDefine writes today, with the operator-brief acceptance.
    const seed = try seedMissionText(arena, "m-1", "build X");
    try testing.expectEqualStrings(
        "# Mission m-1\n\n## Objective\n\nbuild X\n\n## Acceptance\n\nper the operator brief\n",
        seed,
    );
    const defined = try missionText(arena, "m-1", "build X precisely", "tests pass");
    try testing.expectEqualStrings(
        "# Mission m-1\n\n## Objective\n\nbuild X precisely\n\n## Acceptance\n\ntests pass\n",
        defined,
    );
}

test "planText renders the rolePlan format; done tasks are checked" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = try planText(arena, &.{ .{ .desc = "a", .done = true }, .{ .desc = "b" } });
    try testing.expectEqualStrings("# Plan\n\n- [x] a\n- [ ] b\n", text);

    const fixes = [_]Task{
        .{ .desc = "a", .done = true },
        try feedbackTask(arena, "tests fail\nsecond line"),
        try artifactsTask(arena, &.{ "MISSION.md", "step-x-1.md" }),
    };
    try testing.expectEqualStrings(
        "# Plan\n\n- [x] a\n- [ ] fix: tests fail\n- [ ] fix: address findings in MISSION.md, step-x-1.md\n",
        try planText(arena, &fixes),
    );
}

test "fix-task desc round-trips and an ordinary desc that looks similar is not a fix task" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const fb = try feedbackTask(arena, "tests fail:\n- case 3\n");
    try testing.expect(!fb.done);
    const fb_back = (try parseFixTask(arena, fb.desc)).?;
    try testing.expectEqualStrings("tests fail:\n- case 3\n", fb_back.feedback);
    const empty_fb = (try parseFixTask(arena, (try feedbackTask(arena, "")).desc)).?;
    try testing.expectEqualStrings("", empty_fb.feedback);

    const names = [_][]const u8{ "MISSION.md", "step-reviewer-2.md", "EXEC.md" };
    const art = try artifactsTask(arena, &names);
    const art_back = (try parseFixTask(arena, art.desc)).?;
    try expectNames(&names, art_back.artifacts);
    const none = (try parseFixTask(arena, (try artifactsTask(arena, &.{})).desc)).?;
    try testing.expectEqual(@as(usize, 0), none.artifacts.len);

    const lookalikes = [_][]const u8{
        "",
        "fix the bug",
        "Fix task: address the reviewer notes",
        "[zygos fix-task: feedback]", // header without the newline separator
        "[zygos fix-task: artifacts] EXEC.md",
        "[zygos fix-task: artifacts]\nnot/bare.md",
        "[zygos fix-task: artifacts]\nhas space.md",
        "[zygos fix-task: artifacts]\nA.md\n\nB.md",
        "[zygos fix-task: other]\nx",
        " [zygos fix-task: feedback]\nx",
        "1. [zygos fix-task: feedback]\nx",
    };
    for (lookalikes) |desc| try testing.expect((try parseFixTask(arena, desc)) == null);
}

test "run counters name step-<id>-<n> and MISSION-<n>/PLAN-<n> without overwriting" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var runs: StepRuns = .{};
    try testing.expectEqual(@as(usize, 0), runs.get("architect"));
    try testing.expectEqual(@as(usize, 1), try runs.bump(arena, "architect"));
    try testing.expectEqual(@as(usize, 1), try runs.bump(arena, "executor"));
    try testing.expectEqual(@as(usize, 2), try runs.bump(arena, "architect"));
    try testing.expectEqual(@as(usize, 2), runs.get("architect"));
    try testing.expectEqual(@as(usize, 1), runs.get("executor"));
    try testing.expectEqual(@as(usize, 0), runs.get("verifier"));
    try testing.expectEqual(@as(usize, 2), runs.items.len);

    try testing.expectEqualStrings("step-architect-1.md", try stepArtifactName(arena, "architect", 1));
    try testing.expectEqualStrings("step-architect-2.md", try stepArtifactName(arena, "architect", runs.get("architect")));

    // Each rewrite parks the previous version under the next free number.
    var mission_versions: usize = 0;
    var plan_versions: usize = 0;
    var seen: std.ArrayList([]const u8) = .empty;
    try seen.appendSlice(arena, &.{ "MISSION.md", "PLAN.md" });
    for (0..3) |i| {
        const m = try archive(arena, .mission, mission_versions);
        mission_versions = m.versions;
        try testing.expectEqual(i + 1, mission_versions);
        try testing.expectEqualStrings(try std.fmt.allocPrint(arena, "MISSION-{d}.md", .{i + 1}), m.name);
        for (seen.items) |s| try testing.expect(!std.mem.eql(u8, s, m.name));
        try seen.append(arena, m.name);
    }
    const p = try archive(arena, .plan, plan_versions);
    plan_versions = p.versions;
    try testing.expectEqualStrings("PLAN-1.md", p.name);
    try testing.expectEqual(@as(usize, 1), plan_versions);
    try testing.expectEqual(@as(usize, 3), mission_versions);
    for (seen.items) |s| try testing.expect(!std.mem.eql(u8, s, p.name));
}

test "executor rule: no tasks seeds one objective task; unfinished tasks run; all done appends one fix task from artifacts since the previous executor, else everything" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // (1) no tasks: PLAN.md seeded with one task equal to the objective.
    {
        const steps = [_]Step{ mk("executor"), mk("verifier") };
        const a = try arriveAtExecutor(arena, "ship it", &.{}, &steps, 0, .{});
        try testing.expectEqual(ExecutorEntry.seeded, a.entry);
        try testing.expectEqual(@as(usize, 1), a.tasks.len);
        try testing.expectEqualStrings("ship it", a.tasks[0].desc);
        try testing.expect(!a.tasks[0].done);
        try testing.expectEqual(@as(usize, 0), a.task_index);
        try testing.expectEqualStrings("# Plan\n\n- [ ] ship it\n", a.plan_md.?);
    }

    // (2) unfinished tasks: run from the first unfinished, nothing appended.
    {
        const tasks = [_]Task{ .{ .desc = "a", .done = true }, .{ .desc = "b" }, .{ .desc = "c" } };
        const steps = [_]Step{ mk("planner"), mk("executor") };
        const a = try arriveAtExecutor(arena, "ship it", &tasks, &steps, 1, .{});
        try testing.expectEqual(ExecutorEntry.run_unfinished, a.entry);
        try testing.expectEqual(@as(usize, 3), a.tasks.len);
        try testing.expectEqual(@as(usize, 1), a.task_index);
        try testing.expect(a.plan_md == null);
    }

    // (3) all done, previous executor with a span: the span's artifacts only.
    {
        const tasks = [_]Task{.{ .desc = "a", .done = true }};
        const steps = [_]Step{ mk("executor"), mk("reviewer"), mk("executor") };
        const runs = try runsOf(arena, &.{ .{ .id = "executor", .count = 1 }, .{ .id = "reviewer", .count = 1 } });
        const a = try arriveAtExecutor(arena, "ship it", &tasks, &steps, 2, runs);
        try testing.expectEqual(ExecutorEntry.fix_appended, a.entry);
        try testing.expectEqual(@as(usize, 2), a.tasks.len);
        try testing.expectEqual(@as(usize, 1), a.task_index);
        try testing.expect(a.tasks[0].done);
        try testing.expect(!a.tasks[1].done);
        try expectNames(&.{"step-reviewer-1.md"}, (try parseFixTask(arena, a.tasks[1].desc)).?.artifacts);
        try testing.expect(a.plan_md == null);
    }

    // (3) all done, empty span (adjacent executors): everything written so far.
    {
        const tasks = [_]Task{.{ .desc = "a", .done = true }};
        const steps = [_]Step{ mk("product-owner"), mk("executor"), mk("executor") };
        const runs = try runsOf(arena, &.{ .{ .id = "product-owner", .count = 1 }, .{ .id = "executor", .count = 1 } });
        const a = try arriveAtExecutor(arena, "ship it", &tasks, &steps, 2, runs);
        try testing.expectEqual(ExecutorEntry.fix_appended, a.entry);
        try expectNames(&.{ "MISSION.md", "EXEC.md" }, (try parseFixTask(arena, a.tasks[1].desc)).?.artifacts);
    }

    // (3) all done, no previous executor (executor re-entered after a loop): everything.
    {
        const tasks = [_]Task{.{ .desc = "a", .done = true }};
        const steps = [_]Step{ mk("architect"), mk("executor") };
        const runs = try runsOf(arena, &.{ .{ .id = "architect", .count = 2 }, .{ .id = "executor", .count = 1 } });
        const a = try arriveAtExecutor(arena, "ship it", &tasks, &steps, 1, runs);
        try expectNames(
            &.{ "step-architect-1.md", "step-architect-2.md", "EXEC.md" },
            (try parseFixTask(arena, a.tasks[1].desc)).?.artifacts,
        );
    }

    // after a task completes
    {
        const mid = [_]Task{ .{ .desc = "a", .done = true }, .{ .desc = "b" } };
        try testing.expectEqual(AfterTask{ .task_done = 1 }, afterTask(&mid));
        const last = [_]Task{ .{ .desc = "a", .done = true }, .{ .desc = "b", .done = true } };
        try testing.expectEqual(AfterTask.step_done, afterTask(&last));
    }
}

test "fix sources: the last k runs of an id seen k times in the span; unrun steps contribute nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const steps = [_]Step{ mk("executor"), mk("a"), mk("b"), mk("a"), mk("verifier"), mk("executor") };
    const runs = try runsOf(arena, &.{
        .{ .id = "executor", .count = 1 }, .{ .id = "a", .count = 3 },
        .{ .id = "b", .count = 1 },        .{ .id = "verifier", .count = 2 },
    });
    try expectNames(
        &.{ "step-a-2.md", "step-a-3.md", "step-b-1.md", "VERIFY.md" },
        try fixSources(arena, &steps, 5, runs),
    );

    // Nothing in the span has run: fall back to everything written so far.
    const idle = try runsOf(arena, &.{ .{ .id = "executor", .count = 1 }, .{ .id = "a", .count = 1 } });
    try expectNames(
        &.{"EXEC.md"},
        try fixSources(arena, &[_]Step{ mk("executor"), mk("b"), mk("executor") }, 2, idle),
    );
    // A span step that ran contributes only itself, not the older artifacts.
    try expectNames(
        &.{"step-a-1.md"},
        try fixSources(arena, &[_]Step{ mk("executor"), mk("a"), mk("b"), mk("executor") }, 3, idle),
    );
    // Run only before the previous executor does not count as "since".
    try expectNames(
        &.{ "step-a-1.md", "EXEC.md" },
        try fixSources(arena, &[_]Step{ mk("a"), mk("executor"), mk("b"), mk("executor") }, 3, idle),
    );
}

test "artifacts so far: step order, deduped ids, all runs; step-* only for the appended set" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const steps = [_]Step{
        mk("product-owner"), mk("architect"), mk("planner"),  mk("executor"),
        mk("reviewer"),      mk("architect"), mk("verifier"),
    };
    const runs = try runsOf(arena, &.{
        .{ .id = "product-owner", .count = 1 }, .{ .id = "architect", .count = 2 },
        .{ .id = "planner", .count = 1 },       .{ .id = "executor", .count = 3 },
        .{ .id = "reviewer", .count = 1 },
    });
    try expectNames(
        &.{ "MISSION.md", "step-architect-1.md", "step-architect-2.md", "PLAN.md", "EXEC.md", "step-reviewer-1.md" },
        try artifactsSoFar(arena, &steps, runs),
    );
    try expectNames(
        &.{ "step-architect-1.md", "step-architect-2.md", "step-reviewer-1.md" },
        try stepArtifactsSoFar(arena, &steps, runs),
    );
    try expectNames(&.{}, try artifactsSoFar(arena, &steps, .{}));
    try expectNames(&.{}, try stepArtifactsSoFar(arena, &steps, .{}));
}

test "planner repeat replaces only unfinished tasks" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tasks = [_]Task{
        .{ .desc = "done 1", .done = true, .result = "r1" },
        .{ .desc = "done 2", .done = true, .result = "r2" },
        .{ .desc = "old 3" },
        .{ .desc = "old 4" },
    };
    const r = try replaceUnfinished(arena, &tasks, &.{ "new A", "new B", "new C" });
    try testing.expectEqual(@as(usize, 5), r.tasks.len);
    try testing.expectEqual(@as(usize, 2), r.task_index);
    try testing.expectEqualStrings("done 1", r.tasks[0].desc);
    try testing.expect(r.tasks[0].done);
    try testing.expectEqualStrings("r2", r.tasks[1].result);
    for (r.tasks[2..], [_][]const u8{ "new A", "new B", "new C" }) |t, want| {
        try testing.expectEqualStrings(want, t.desc);
        try testing.expect(!t.done);
    }
    // Input untouched.
    try testing.expectEqualStrings("old 3", tasks[2].desc);

    // No tasks yet: a plain plan; all done: new tasks follow the done ones.
    const fresh = try replaceUnfinished(arena, &.{}, &.{"only"});
    try testing.expectEqual(@as(usize, 0), fresh.task_index);
    try testing.expectEqual(@as(usize, 1), fresh.tasks.len);
    const all_done = [_]Task{.{ .desc = "x", .done = true }};
    const after = try replaceUnfinished(arena, &all_done, &.{"y"});
    try testing.expectEqual(@as(usize, 1), after.task_index);
    try testing.expectEqual(@as(usize, 2), after.tasks.len);
}

test "appendTask leaves earlier tasks intact" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tasks = [_]Task{.{ .desc = "a", .done = true }};
    const grown = try appendTask(arena, &tasks, try feedbackTask(arena, "boom"));
    try testing.expectEqual(@as(usize, 2), grown.len);
    try testing.expect(grown[0].done);
    try testing.expectEqualStrings("boom", (try parseFixTask(arena, grown[1].desc)).?.feedback);
}

test "rework target: last executor before the failing verifier, else the first executor; gate denial targets the last executor" {
    // [po, planner, executor, verifier]
    const dflt = [_]Step{ mk("product-owner"), mk("planner"), mk("executor"), mk("verifier") };
    try testing.expectEqual(@as(?usize, 2), verifyReworkTarget(&dflt, 3));
    try testing.expectEqual(@as(?usize, 2), gateReworkTarget(&dflt));

    // [executor, reviewer, executor, verifier, executor]
    const multi = [_]Step{ mk("executor"), mk("reviewer"), mk("executor"), mk("verifier"), mk("executor") };
    try testing.expectEqual(@as(?usize, 2), verifyReworkTarget(&multi, 3));
    try testing.expectEqual(@as(?usize, 4), gateReworkTarget(&multi));

    // Verifier before every executor: the first executor in the list.
    const early = [_]Step{ mk("verifier"), mk("architect"), mk("executor"), mk("executor") };
    try testing.expectEqual(@as(?usize, 2), verifyReworkTarget(&early, 0));
    try testing.expectEqual(@as(?usize, 3), gateReworkTarget(&early));

    // Two verifiers: each returns to the last executor before itself.
    const two = [_]Step{ mk("executor"), mk("verifier"), mk("executor"), mk("verifier") };
    try testing.expectEqual(@as(?usize, 0), verifyReworkTarget(&two, 1));
    try testing.expectEqual(@as(?usize, 2), verifyReworkTarget(&two, 3));

    // No executor: fail closed (validate refuses such lists, so this is defensive).
    const none = [_]Step{ mk("planner"), mk("verifier") };
    try testing.expectEqual(@as(?usize, null), verifyReworkTarget(&none, 1));
    try testing.expectEqual(@as(?usize, null), gateReworkTarget(&none));
}

// Frozen copies of the pre-pipeline playbook.defaultSystem texts.
const legacy_product_owner = "You are the product-owner of a mission. Refine the raw objective " ++
    "you are given. Reply with ONLY a JSON object: " ++
    "{\"objective\": <one precise sentence>, \"acceptance\": <how completion is judged>}.";
const legacy_planner = "You are the planner of a mission. Break the objective into ordered, " ++
    "independently executable tasks. Prefer few substantive tasks; each task " ++
    "validates its own work, so never emit separate verify-only or " ++
    "run-the-tests-again tasks. Reply with ONLY a JSON object: " ++
    "{\"tasks\": [<task description>, ...]}.";
const legacy_executor = "You are the executor of a mission. Complete the single task you are " ++
    "given, using the available tools when they help. The bash tool already runs " ++
    "in the mission workspace — work there with relative paths; do not create " ++
    "directories elsewhere or probe $HOME.";
const legacy_verifier = "You are the verifier of a mission. Judge whether the executed plan " ++
    "meets the objective and its acceptance criteria. Reply with ONLY a JSON " ++
    "object: {\"passed\": true|false, \"reason\": <one sentence>}.";

test "built-in file + appended contract equals the legacy defaultSystem text byte-for-byte" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_]struct { id: []const u8, want: []const u8 }{
        .{ .id = "product-owner", .want = legacy_product_owner },
        .{ .id = "planner", .want = legacy_planner },
        .{ .id = "executor", .want = legacy_executor },
        .{ .id = "verifier", .want = legacy_verifier },
    };
    for (cases) |c| {
        const got = (try systemPrompt(arena, mk(c.id), null)).?;
        try testing.expectEqualStrings(c.want, got);
    }
}

test "prompt precedence: pinned definition > role-<id>.md > built-in; the contract is appended for structured kinds" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const planner_contract = "Reply with ONLY a JSON object: {\"tasks\": [<task description>, ...]}.";
    const verifier_contract = "Reply with ONLY a JSON object: {\"passed\": true|false, \"reason\": <one sentence>}.";
    const po_contract = "Reply with ONLY a JSON object: " ++
        "{\"objective\": <one precise sentence>, \"acceptance\": <how completion is judged>}.";

    // Pinned beats override beats built-in; text is trimmed, contract follows.
    var planner = mk("planner");
    planner.system = "\n  Pinned planner.  \n";
    try testing.expectEqualStrings(
        "Pinned planner. " ++ planner_contract,
        (try systemPrompt(arena, planner, "Override planner.")).?,
    );
    try testing.expectEqualStrings(
        "Override planner. " ++ planner_contract,
        (try systemPrompt(arena, mk("planner"), "\tOverride planner.\n")).?,
    );
    try testing.expectEqualStrings(
        legacy_planner,
        (try systemPrompt(arena, mk("planner"), null)).?,
    );
    // A blank override or blank pinned text does not blank the prompt.
    try testing.expectEqualStrings(legacy_planner, (try systemPrompt(arena, mk("planner"), " \n\t")).?);
    var blank = mk("planner");
    blank.system = "  ";
    try testing.expectEqualStrings(
        "Override planner. " ++ planner_contract,
        (try systemPrompt(arena, blank, "Override planner.")).?,
    );

    var verifier = mk("verifier");
    verifier.system = "Pinned verifier.";
    try testing.expectEqualStrings("Pinned verifier. " ++ verifier_contract, (try systemPrompt(arena, verifier, null)).?);
    var po = mk("product-owner");
    po.system = "Pinned po.";
    try testing.expectEqualStrings("Pinned po. " ++ po_contract, (try systemPrompt(arena, po, null)).?);

    // Executor and custom kinds never get a contract.
    var executor = mk("executor");
    executor.system = "Pinned executor.";
    try testing.expectEqualStrings("Pinned executor.", (try systemPrompt(arena, executor, "Override.")).?);
    try testing.expectEqualStrings("Override.", (try systemPrompt(arena, mk("executor"), "Override.")).?);
    var architect = mk("architect");
    architect.system = "Design it.";
    try testing.expectEqualStrings("Design it.", (try systemPrompt(arena, architect, "Override.")).?);
    // A custom step with no pinned text may still take a role-<id>.md override; with neither, null.
    try testing.expectEqualStrings("Override.", (try systemPrompt(arena, mk("architect"), "Override.")).?);
    try testing.expect((try systemPrompt(arena, mk("architect"), null)) == null);
}
