//! Mission orchestrator (M3, V1/V3–V5 — docs/specs/mission.md). One mission =
//! one objective driven to a terminal state by role turns (product-owner →
//! planner → executor → verifier) over the durable `.planning/` substrate,
//! closed by a hard human gate.
//!
//! Split hard, like the turn worker: `Fsm` is a pure table-driven state
//! machine (exhaustively tested, no I/O); `MissionOrchestrator` is bus glue
//! over an inproc worker — every role runs as one `zygos::turns::run` turn,
//! so providers, policy, approvals, routing, and budgets compose unchanged.
//!
//! Deviation from the spec's ErrorBody wording (flagged, same as turn.zig):
//! the inproc Handler contract carries no custom ErrorBody codes, so
//! malformed requests, duplicate mission_ids, and missing resume state all
//! surface as the generic handler failure.

const std = @import("std");
const json = std.json;
const actor_mod = @import("../kernel/actor.zig");
const inproc = @import("../kernel/inproc.zig");
const sync = @import("../kernel/sync.zig");
const store_mod = @import("mission_store.zig");
const trace_mod = @import("trace.zig");
const brief_mod = @import("brief.zig");
const context_mod = @import("context.zig");
const context_substrate = @import("context_substrate.zig");
const context_recall = @import("context_recall.zig");
const context_thread = @import("context_thread.zig");

const log = std.log.scoped(.mission);

// ---------------------------------------------------------------------------
// FSM (pure)
// ---------------------------------------------------------------------------

pub const State = enum {
    defining,
    planning,
    executing,
    verifying,
    gating,
    done,
    failed,
};

pub const Event = enum {
    objective_ready,
    plan_ready,
    task_done,
    tasks_done,
    verify_passed,
    verify_failed,
    escalate,
    gate_approved,
    gate_denied,
    gate_failed,
    role_failed,
    role_turns_exhausted,
    abort,
};

const Transition = struct { from: State, event: Event, to: State };

/// The complete legal-transition table (docs/specs/mission.md). Everything
/// not listed is IllegalTransition; terminal states accept nothing.
pub const transitions = [_]Transition{
    .{ .from = .defining, .event = .objective_ready, .to = .planning },
    .{ .from = .defining, .event = .role_failed, .to = .failed },
    .{ .from = .defining, .event = .role_turns_exhausted, .to = .failed },
    .{ .from = .defining, .event = .abort, .to = .failed },
    .{ .from = .planning, .event = .plan_ready, .to = .executing },
    .{ .from = .planning, .event = .role_failed, .to = .failed },
    .{ .from = .planning, .event = .role_turns_exhausted, .to = .failed },
    .{ .from = .planning, .event = .abort, .to = .failed },
    .{ .from = .executing, .event = .task_done, .to = .executing },
    .{ .from = .executing, .event = .tasks_done, .to = .verifying },
    // Executor step-budget exhaustion past fail_threshold (retries happen
    // without a transition — the state loops on .executing).
    .{ .from = .executing, .event = .escalate, .to = .failed },
    .{ .from = .executing, .event = .role_failed, .to = .failed },
    .{ .from = .executing, .event = .role_turns_exhausted, .to = .failed },
    .{ .from = .executing, .event = .abort, .to = .failed },
    .{ .from = .verifying, .event = .verify_passed, .to = .gating },
    .{ .from = .verifying, .event = .verify_failed, .to = .planning },
    .{ .from = .verifying, .event = .escalate, .to = .failed },
    .{ .from = .verifying, .event = .role_failed, .to = .failed },
    .{ .from = .verifying, .event = .role_turns_exhausted, .to = .failed },
    .{ .from = .verifying, .event = .abort, .to = .failed },
    .{ .from = .gating, .event = .gate_approved, .to = .done },
    .{ .from = .gating, .event = .gate_denied, .to = .planning },
    .{ .from = .gating, .event = .gate_failed, .to = .failed },
    .{ .from = .gating, .event = .abort, .to = .failed },
};

pub const Fsm = struct {
    pub fn apply(state: State, event: Event) error{IllegalTransition}!State {
        inline for (transitions) |t| {
            if (t.from == state and t.event == event) return t.to;
        }
        return error.IllegalTransition;
    }
};

// ---------------------------------------------------------------------------
// Mission (the durable record — persisted by mission_store after every apply)
// ---------------------------------------------------------------------------

pub const StopReason = enum {
    none,
    completed,
    aborted,
    escalated,
    gate_failed,
    role_failed,
    role_turns_exhausted,
};

pub const Task = struct {
    desc: []const u8,
    done: bool = false,
    /// Excerpt of the executor's answer for this task — carried into later
    /// executor turns so they stop re-discovering finished work. In-memory
    /// only (not persisted); a resumed mission sees [done] without it.
    result: []const u8 = "",
};

/// All slices are owned by whoever built the Mission: the driver builds one
/// in a handler arena (no frees); `mission_store.load` builds a gpa-owned one
/// that must be released with `deinit`.
pub const Mission = struct {
    mission_id: []const u8,
    state: State = .defining,
    stop: StopReason = .none,
    detail: []const u8 = "",
    objective: []const u8 = "",
    acceptance: []const u8 = "",
    feedback: []const u8 = "",
    /// M6 operator steer riding the next role turn. In-memory only (a
    /// parked mission does not carry a pending steer across resume).
    steer: []const u8 = "",
    tasks: []Task = &.{},
    task_index: usize = 0,
    fail_count: usize = 0,
    /// Step-budget exhaustions on the current task (executor retries);
    /// separate from fail_count so verify's "consecutive failures"
    /// escalation semantics stay untouched. Reset when a task completes.
    exec_fail_count: usize = 0,
    gate_denials: usize = 0,
    role_turns_used: usize = 0,

    /// Only for gpa-owned missions (mission_store.load).
    pub fn deinit(self: *Mission, gpa: std.mem.Allocator) void {
        gpa.free(self.mission_id);
        gpa.free(self.detail);
        gpa.free(self.objective);
        gpa.free(self.acceptance);
        gpa.free(self.feedback);
        for (self.tasks) |t| gpa.free(t.desc);
        gpa.free(self.tasks);
    }

    pub fn tasksDone(self: *const Mission) usize {
        var n: usize = 0;
        for (self.tasks) |t| {
            if (t.done) n += 1;
        }
        return n;
    }
};

// ---------------------------------------------------------------------------
// Driver
// ---------------------------------------------------------------------------

pub const Role = enum {
    product_owner,
    planner,
    executor,
    verifier,

    /// The routing key: `zygos.zon` pins each role to its own provider/model.
    fn stepId(self: Role) []const u8 {
        return switch (self) {
            .product_owner => "product-owner",
            .planner => "planner",
            .executor => "executor",
            .verifier => "verifier",
        };
    }

    fn system(self: Role) []const u8 {
        return switch (self) {
            .product_owner => "You are the product-owner of a mission. Refine the raw objective " ++
                "you are given. Reply with ONLY a JSON object: " ++
                "{\"objective\": <one precise sentence>, \"acceptance\": <how completion is judged>}.",
            .planner => "You are the planner of a mission. Break the objective into ordered, " ++
                "independently executable tasks. Prefer few substantive tasks; each task " ++
                "validates its own work, so never emit separate verify-only or " ++
                "run-the-tests-again tasks. Reply with ONLY a JSON object: " ++
                "{\"tasks\": [<task description>, ...]}.",
            .executor => "You are the executor of a mission. Complete the single task you are " ++
                "given, using the available tools when they help. The bash tool already runs " ++
                "in the mission workspace — work there with relative paths; do not create " ++
                "directories elsewhere or probe $HOME.",
            .verifier => "You are the verifier of a mission. Judge whether the executed plan " ++
                "meets the objective and its acceptance criteria. Reply with ONLY a JSON " ++
                "object: {\"passed\": true|false, \"reason\": <one sentence>}.",
        };
    }
};

/// Cross-thread control block per live mission. ALL access goes through
/// the orchestrator's ctl_mutex; the running mission updates the snapshot
/// after every persisted transition, status/abort read it.
const MissionControl = struct {
    aborted: bool = false,
    /// M6: pause parks the run durably at the next role boundary.
    paused: bool = false,
    /// M6: pending operator steer, gpa-owned, consumed at the next boundary.
    steer: ?[]u8 = null,
    state: State = .defining,
    stop: StopReason = .none,
    task_index: usize = 0,
    fail_count: usize = 0,
    gate_denials: usize = 0,
    role_turns_used: usize = 0,
};

/// Everything runMission needs, parsed once from the start request.
/// Slices point into the handler arena.
const RunConfig = struct {
    mission_id: []const u8,
    store: store_mod.Store,
    provider_function: ?[]const u8,
    router_function: ?[]const u8,
    gate_function: ?[]const u8,
    policy_function: ?[]const u8,
    approval_function: ?[]const u8,
    budget_scope: ?[]const u8,
    tools_json: ?[]const u8,
    continuity_function: ?[]const u8,
    continuity_project: ?[]const u8,
    max_role_turns: usize,
    fail_threshold: usize,
    gate_threshold: usize,
    role_max_steps: usize,
    /// events.jsonl in the planning root (fail-open — see worker/trace.zig).
    trace_path: ?[]const u8,
    /// M5 seam: every role's content is strategy-assembled under a hard
    /// token budget; the driver never hand-builds prompts.
    strategy: context_mod.ContextStrategy,
    context_budget: context_mod.TokenBudget,
    substrate: context_mod.Substrate,
};

/// context.Substrate over the planning store (artifact reads for strategies).
const StoreSubstrate = struct {
    gpa: std.mem.Allocator,
    store: store_mod.Store,

    fn read(ctx: *anyopaque, arena: std.mem.Allocator, name: []const u8) ?[]const u8 {
        const self: *StoreSubstrate = @ptrCast(@alignCast(ctx));
        const bytes = self.store.readArtifact(self.gpa, name) catch return null;
        defer self.gpa.free(bytes);
        return arena.dupe(u8, bytes) catch null;
    }

    fn substrate(self: *StoreSubstrate) context_mod.Substrate {
        return .{ .ctx = @ptrCast(self), .readFn = &read };
    }
};

const mission_artifact = "MISSION.md";
const plan_artifact = "PLAN.md";
const verify_artifact = "VERIFY.md";
const decisions_artifact = "DECISIONS.md";

/// PO decision journal (M6): every accept/redo/replan appends one audit
/// line. Fail-open — a journal write never changes a mission outcome — and
/// append-only. ThreadStrategy pins DECISIONS.md into every role's context,
/// so journaled decisions survive every step of long factory missions.
fn journal(self: *MissionOrchestrator, cfg: RunConfig, kind: []const u8, reason: []const u8) void {
    const line = std.fmt.allocPrint(self.gpa, "- {s} [{s}] {s}\n", .{ nowStamp(), kind, reason }) catch return;
    defer self.gpa.free(line);
    cfg.store.appendArtifact(self.gpa, decisions_artifact, line) catch {};
}

pub const MissionOrchestrator = struct {
    gpa: std.mem.Allocator,
    worker: *inproc.Worker,
    ctl_mutex: sync.Mutex = .{},
    live: std.StringHashMap(*MissionControl),

    pub fn start(
        gpa: std.mem.Allocator,
        actor: *actor_mod.Actor,
        registry: *inproc.Registry,
    ) !*MissionOrchestrator {
        const self = try gpa.create(MissionOrchestrator);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .worker = try inproc.Worker.spawn(gpa, actor, registry, "mission-orchestrator"),
            .live = std.StringHashMap(*MissionControl).init(gpa),
        };
        errdefer self.worker.stop();
        try self.worker.registerFunction("zygos::missions::start", self, &startHandler);
        try self.worker.registerFunction("zygos::missions::status", self, &statusHandler);
        try self.worker.registerFunction("zygos::missions::abort", self, &abortHandler);
        try self.worker.registerFunction("zygos::missions::steer", self, &steerHandler);
        try self.worker.registerFunction("zygos::missions::pause", self, &pauseHandler);
        try self.worker.registerFunction("zygos::missions::resume", self, &resumeHandler);
        return self;
    }

    pub fn stop(self: *MissionOrchestrator) void {
        // worker.stop() joins every start handler thread; each untracks its
        // own mission on the way out, so the map must drain empty.
        self.worker.stop();
        std.debug.assert(self.live.count() == 0);
        self.live.deinit();
        self.ctl_mutex.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    fn track(self: *MissionOrchestrator, mission_id: []const u8) error{ OutOfMemory, MalformedRequest }!*MissionControl {
        const ctl = try self.gpa.create(MissionControl);
        errdefer self.gpa.destroy(ctl);
        ctl.* = .{};
        const key = try self.gpa.dupe(u8, mission_id);
        errdefer self.gpa.free(key);

        self.ctl_mutex.lock();
        defer self.ctl_mutex.unlock();
        const gop = try self.live.getOrPut(key);
        if (gop.found_existing) return error.MalformedRequest; // duplicate live mission_id
        gop.value_ptr.* = ctl;
        return ctl;
    }

    fn untrack(self: *MissionOrchestrator, mission_id: []const u8) void {
        self.ctl_mutex.lock();
        defer self.ctl_mutex.unlock();
        if (self.live.fetchRemove(mission_id)) |kv| {
            if (kv.value.steer) |s| self.gpa.free(s);
            self.gpa.destroy(kv.value);
            self.gpa.free(kv.key);
        }
    }

    fn pollAborted(self: *MissionOrchestrator, ctl: *MissionControl) bool {
        self.ctl_mutex.lock();
        defer self.ctl_mutex.unlock();
        return ctl.aborted;
    }

    fn pollPaused(self: *MissionOrchestrator, ctl: *MissionControl) bool {
        self.ctl_mutex.lock();
        defer self.ctl_mutex.unlock();
        return ctl.paused;
    }

    /// The pending steer text (gpa-owned, caller frees), clearing the slot.
    fn takeSteer(self: *MissionOrchestrator, ctl: *MissionControl) ?[]u8 {
        self.ctl_mutex.lock();
        defer self.ctl_mutex.unlock();
        const s = ctl.steer;
        ctl.steer = null;
        return s;
    }

    /// Persist first, then publish the snapshot — status never reports a
    /// state the disk does not already have.
    fn persist(self: *MissionOrchestrator, store: store_mod.Store, ctl: *MissionControl, m: *const Mission) error{ OutOfMemory, Failed }!void {
        store.save(self.gpa, m) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Failed,
        };
        self.ctl_mutex.lock();
        defer self.ctl_mutex.unlock();
        ctl.state = m.state;
        ctl.stop = m.stop;
        ctl.task_index = m.task_index;
        ctl.fail_count = m.fail_count;
        ctl.gate_denials = m.gate_denials;
        ctl.role_turns_used = m.role_turns_used;
    }
};

fn startHandler(
    ctx: ?*anyopaque,
    arena: std.mem.Allocator,
    request_json: []const u8,
) error{ Failed, OutOfMemory }![]const u8 {
    const self: *MissionOrchestrator = @ptrCast(@alignCast(ctx.?));
    return runMission(self, arena, request_json) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => {
            log.warn("mission failed structurally: {t}", .{err});
            return error.Failed;
        },
    };
}

fn statusHandler(
    ctx: ?*anyopaque,
    arena: std.mem.Allocator,
    request_json: []const u8,
) error{ Failed, OutOfMemory }![]const u8 {
    const self: *MissionOrchestrator = @ptrCast(@alignCast(ctx.?));
    const mid = controlTarget(arena, request_json) orelse return error.Failed;

    self.ctl_mutex.lock();
    defer self.ctl_mutex.unlock();
    const ctl = self.live.get(mid) orelse return error.Failed;
    return std.fmt.allocPrint(
        arena,
        "{{\"state\":\"{t}\",\"stop\":\"{t}\",\"role_turns\":{d},\"task_index\":{d}," ++
            "\"fail_count\":{d},\"gate_denials\":{d}}}",
        .{ ctl.state, ctl.stop, ctl.role_turns_used, ctl.task_index, ctl.fail_count, ctl.gate_denials },
    );
}

fn abortHandler(
    ctx: ?*anyopaque,
    arena: std.mem.Allocator,
    request_json: []const u8,
) error{ Failed, OutOfMemory }![]const u8 {
    const self: *MissionOrchestrator = @ptrCast(@alignCast(ctx.?));
    const ok = blk: {
        const mid = controlTarget(arena, request_json) orelse break :blk false;
        self.ctl_mutex.lock();
        defer self.ctl_mutex.unlock();
        const ctl = self.live.get(mid) orelse break :blk false;
        ctl.aborted = true;
        break :blk true;
    };
    return std.fmt.allocPrint(arena, "{{\"ok\":{}}}", .{ok});
}

/// M6 turn-steer one level up: text lands at the next role boundary and
/// rides exactly one role turn. Last write wins while one is pending.
fn steerHandler(
    ctx: ?*anyopaque,
    arena: std.mem.Allocator,
    request_json: []const u8,
) error{ Failed, OutOfMemory }![]const u8 {
    const self: *MissionOrchestrator = @ptrCast(@alignCast(ctx.?));
    const ok = blk: {
        const root = json.parseFromSliceLeaky(json.Value, arena, request_json, .{}) catch break :blk false;
        if (root != .object) break :blk false;
        const mid = strField(root.object, "mission_id") orelse break :blk false;
        const text = strField(root.object, "text") orelse break :blk false;
        if (text.len == 0) break :blk false;
        const copy = try self.gpa.dupe(u8, text);
        self.ctl_mutex.lock();
        defer self.ctl_mutex.unlock();
        const ctl = self.live.get(mid) orelse {
            self.gpa.free(copy);
            break :blk false;
        };
        if (ctl.steer) |old| self.gpa.free(old);
        ctl.steer = copy;
        break :blk true;
    };
    return std.fmt.allocPrint(arena, "{{\"ok\":{}}}", .{ok});
}

fn pauseHandler(
    ctx: ?*anyopaque,
    arena: std.mem.Allocator,
    request_json: []const u8,
) error{ Failed, OutOfMemory }![]const u8 {
    return setPaused(ctx, arena, request_json, true);
}

fn resumeHandler(
    ctx: ?*anyopaque,
    arena: std.mem.Allocator,
    request_json: []const u8,
) error{ Failed, OutOfMemory }![]const u8 {
    return setPaused(ctx, arena, request_json, false);
}

fn setPaused(
    ctx: ?*anyopaque,
    arena: std.mem.Allocator,
    request_json: []const u8,
    paused: bool,
) error{ Failed, OutOfMemory }![]const u8 {
    const self: *MissionOrchestrator = @ptrCast(@alignCast(ctx.?));
    const ok = blk: {
        const mid = controlTarget(arena, request_json) orelse break :blk false;
        self.ctl_mutex.lock();
        defer self.ctl_mutex.unlock();
        const ctl = self.live.get(mid) orelse break :blk false;
        ctl.paused = paused;
        break :blk true;
    };
    return std.fmt.allocPrint(arena, "{{\"ok\":{}}}", .{ok});
}

const MissionError = error{ OutOfMemory, Failed, MalformedRequest, IllegalTransition, Shutdown };

fn runMission(self: *MissionOrchestrator, arena: std.mem.Allocator, request_json: []const u8) MissionError![]const u8 {
    const root = json.parseFromSliceLeaky(json.Value, arena, request_json, .{}) catch
        return error.MalformedRequest;
    const obj = if (root == .object) root.object else return error.MalformedRequest;

    const mission_id = strField(obj, "mission_id") orelse return error.MalformedRequest;
    const planning_root = strField(obj, "planning_root") orelse return error.MalformedRequest;
    if (planning_root.len < 2 or planning_root[0] != '/') return error.MalformedRequest;
    const resume_flag = if (obj.get("resume")) |v| v == .bool and v.bool else false;

    // W1 (brief validation): when a mission brief document rides the start
    // request, it is linted before anything is persisted or tracked. A
    // malformed brief refuses the mission with a structured reason and never
    // starts the FSM — fail closed. A brief-less start (raw objective, the M3
    // path) is unaffected.
    if (strField(obj, "brief")) |brief_text| {
        switch (brief_mod.lint(brief_text)) {
            .ok => {},
            .invalid => |e| return std.fmt.allocPrint(
                arena,
                "{{\"refused\":true,\"reason\":\"{s}\",\"detail\":\"brief rejected: {s}\"}}",
                .{ brief_mod.tag(e), brief_mod.tag(e) },
            ),
        }
    }

    // .context_strategy on the start request (from zygos.zon at boot):
    // {"kind":"substrate"|"recall"|"thread","max_tokens":N}. Absent ⇒
    // substrate with the default budget; an unknown kind refuses the start.
    const ctx_cfg: context_mod.Config = blk: {
        const v = obj.get("context_strategy") orelse
            break :blk .{ .kind = .substrate, .max_tokens = context_mod.default_max_tokens };
        if (v != .object) return error.MalformedRequest;
        const kind_s = strField(v.object, "kind") orelse "substrate";
        const kind = std.meta.stringToEnum(context_mod.Kind, kind_s) orelse
            return error.MalformedRequest;
        break :blk .{
            .kind = kind,
            .max_tokens = uintFieldOr(v.object, "max_tokens", context_mod.default_max_tokens),
        };
    };
    var recall_owned: ?*context_recall.RecallStrategy = null;
    defer if (recall_owned) |r| r.destroy();
    var thread_owned: ?*context_thread.ThreadStrategy = null;
    defer if (thread_owned) |t| t.destroy();
    const strategy: context_mod.ContextStrategy = switch (ctx_cfg.kind) {
        .substrate => context_substrate.strategy(),
        .recall => blk: {
            const dir = try std.fmt.allocPrint(arena, "{s}/memory", .{planning_root});
            recall_owned = context_recall.RecallStrategy.create(self.gpa, dir, .{}) catch
                return error.OutOfMemory;
            break :blk recall_owned.?.strategy();
        },
        .thread => blk: {
            // Threads + DECISIONS.md live in the planning root beside the
            // artifacts; the git digest reads the process cwd (the mission
            // workspace), fail-open when it is not a repo.
            thread_owned = context_thread.ThreadStrategy.create(
                self.gpa,
                planning_root,
                ".",
                context_thread.PopenRunner.runner(),
                .{},
            ) catch return error.OutOfMemory;
            break :blk thread_owned.?.strategy();
        },
    };
    var store_substrate = StoreSubstrate{
        .gpa = self.gpa,
        .store = store_mod.Store.init(planning_root),
    };

    const cfg: RunConfig = .{
        .mission_id = mission_id,
        .store = store_mod.Store.init(planning_root),
        .strategy = strategy,
        .context_budget = .{ .max_tokens = ctx_cfg.max_tokens },
        .substrate = store_substrate.substrate(),
        .provider_function = strField(obj, "provider_function"),
        .router_function = strField(obj, "router_function"),
        .gate_function = strField(obj, "gate_function"),
        .policy_function = strField(obj, "policy_function"),
        .approval_function = strField(obj, "approval_function"),
        .budget_scope = strField(obj, "budget_scope"),
        .continuity_function = strField(obj, "continuity_function"),
        .continuity_project = strField(obj, "continuity_project"),
        .tools_json = blk: {
            const tv = obj.get("tools") orelse break :blk null;
            if (tv != .array) return error.MalformedRequest;
            break :blk try rawJson(arena, tv);
        },
        .max_role_turns = uintFieldOr(obj, "max_role_turns", 16),
        .fail_threshold = uintFieldOr(obj, "fail_threshold", 3),
        .gate_threshold = uintFieldOr(obj, "gate_threshold", 3),
        .role_max_steps = uintFieldOr(obj, "role_max_steps", 8),
        .trace_path = strField(obj, "trace_path"),
    };
    if (cfg.provider_function == null and cfg.router_function == null)
        return error.MalformedRequest;

    var m: Mission = undefined;
    if (resume_flag) {
        var loaded = cfg.store.load(self.gpa) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Failed, // mission_not_found / corrupt state file
        };
        defer loaded.deinit(self.gpa);
        if (!std.mem.eql(u8, loaded.mission_id, mission_id)) return error.MalformedRequest;
        m = try cloneToArena(arena, &loaded);
        // Resuming a terminal mission is idempotent: report, run nothing.
        if (m.state == .done or m.state == .failed) return replyTerminal(arena, &m);
    } else {
        const objective = strField(obj, "objective") orelse return error.MalformedRequest;
        m = .{ .mission_id = mission_id, .objective = objective };
    }

    const ctl = try self.track(mission_id);
    defer self.untrack(mission_id);

    // The pre-first-turn state hits the disk too: a mission killed before
    // its first role turn still resumes.
    try self.persist(cfg.store, ctl, &m);

    var phase_log: std.ArrayList([]const u8) = .empty;
    while (m.state != .done and m.state != .failed) {
        const prev = m.state;
        // Role boundary: abort wins, then the role-turn budget (the gate
        // call is not a role turn and stays exempt).
        if (self.pollAborted(ctl)) {
            m.stop = .aborted;
            m.detail = "aborted over the bus";
            m.state = try Fsm.apply(m.state, .abort);
        } else if (self.pollPaused(ctl)) {
            // Pause parks durably at the boundary; the substrate already
            // resumes (mission start with resume:true).
            try self.persist(cfg.store, ctl, &m);
            return replyParked(arena, &m);
        } else if (m.state != .gating and m.role_turns_used >= cfg.max_role_turns) {
            m.stop = .role_turns_exhausted;
            m.detail = "max_role_turns reached";
            m.state = try Fsm.apply(m.state, .role_turns_exhausted);
        } else {
            // Steer is consumed at the boundary and rides exactly the next
            // role turn's content (turn-steer semantics one level up).
            if (self.takeSteer(ctl)) |text| {
                defer self.gpa.free(text);
                m.steer = try arena.dupe(u8, text);
                try trace_mod.emit(arena, cfg.trace_path, .{ .steer = .{
                    .text = try trace_mod.clip(arena, m.steer),
                } });
            }
            switch (m.state) {
                .defining => try roleDefine(self, arena, cfg, &m),
                .planning => try rolePlan(self, arena, cfg, &m),
                .executing => try roleExecute(self, arena, cfg, &m),
                .verifying => try roleVerify(self, arena, cfg, &m),
                .gating => try gate(self, arena, cfg, &m),
                .done, .failed => unreachable,
            }
            m.steer = "";
        }
        try self.persist(cfg.store, ctl, &m);
        if (m.state != prev) {
            log.info("mission {s}: {t} → {t} (role_turns {d}, tasks {d}/{d})", .{
                m.mission_id, prev, m.state, m.role_turns_used, m.tasksDone(), m.tasks.len,
            });
            try trace_mod.emit(arena, cfg.trace_path, .{ .mission = .{
                .from = @tagName(prev),
                .to = @tagName(m.state),
                .role_turns = @intCast(m.role_turns_used),
                .tasks_done = @intCast(m.tasksDone()),
                .tasks = @intCast(m.tasks.len),
            } });
            try phase_log.append(arena, try std.fmt.allocPrint(arena, "{t} → {t}", .{ prev, m.state }));
        }
    }

    // Continuity is observability, not a gate: a failed session close warns
    // and never changes the mission outcome (unlike gate/budget).
    closeContinuity(self, arena, cfg, &m, phase_log.items) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => log.warn("continuity close failed (mission outcome unaffected): {t}", .{err}),
    };
    writeLedger(self, arena, cfg, &m);
    return replyTerminal(arena, &m);
}

/// M7 mission-level budget ledger: the scope's spend rollup (tokens +
/// saved_bytes from the budget worker's data) written into the substrate at
/// terminal state. Fail-open — an unreachable budget worker skips the
/// ledger, never the outcome.
fn writeLedger(self: *MissionOrchestrator, arena: std.mem.Allocator, cfg: RunConfig, m: *const Mission) void {
    const scope = cfg.budget_scope orelse return;
    const req = std.fmt.allocPrint(arena, "{{\"scope\":{f}}}", .{json.fmt(scope, .{})}) catch return;
    const res = self.worker.call("zygos::budget::check", req) catch return;
    defer res.deinit(self.gpa);
    if (res != .ok) return;
    const parsed = json.parseFromSliceLeaky(json.Value, arena, res.ok, .{}) catch return;
    if (parsed != .object) return;
    const used = if (parsed.object.get("used_tokens")) |v| (if (v == .integer) v.integer else 0) else 0;
    const saved = if (parsed.object.get("saved_bytes")) |v| (if (v == .integer) v.integer else 0) else 0;
    const md = std.fmt.allocPrint(
        arena,
        "# Ledger — {s}\n\nused_tokens: {d}\nsaved_bytes: {d}\nrole_turns: {d}\nstate: {t} ({t})\n",
        .{ m.mission_id, used, saved, m.role_turns_used, m.state, m.stop },
    ) catch return;
    cfg.store.writeArtifact(self.gpa, "LEDGER.md", md) catch {};
    log.info("mission {s}: ledger — {d} tokens, {d} bytes saved, {d} role turns", .{
        m.mission_id, used, saved, m.role_turns_used,
    });
}

/// W3 seam: when a continuity function + project ride the start request, the
/// terminal mission closes a vault session over the bus — the phase log and
/// leftovers land in SESSIONS.md without any model being asked to remember.
fn closeContinuity(
    self: *MissionOrchestrator,
    arena: std.mem.Allocator,
    cfg: RunConfig,
    m: *const Mission,
    phase_log: []const []const u8,
) error{ OutOfMemory, Failed, Shutdown }!void {
    const function = cfg.continuity_function orelse return;
    const project = cfg.continuity_project orelse return;

    var req: std.Io.Writer.Allocating = .init(arena);
    errdefer req.deinit();
    const w = &req.writer;
    w.print("{{\"project\":{f},\"date\":\"{s}\",\"intention\":{f}", .{
        json.fmt(project, .{}),
        &nowStamp(),
        json.fmt(m.objective, .{}),
    }) catch return error.OutOfMemory;
    w.print(",\"accomplished\":\"{d}/{d} tasks done\"", .{ m.tasksDone(), m.tasks.len }) catch return error.OutOfMemory;
    w.print(",\"leaving_behind\":{f}", .{json.fmt(
        try std.fmt.allocPrint(arena, "mission {t} — stop: {t}; {s}", .{ m.state, m.stop, m.detail }),
        .{},
    )}) catch return error.OutOfMemory;
    w.writeAll(",\"open_threads\":[") catch return error.OutOfMemory;
    var first = true;
    for (m.tasks) |t| {
        if (t.done) continue;
        if (!first) w.writeAll(",") catch return error.OutOfMemory;
        first = false;
        w.print("{f}", .{json.fmt(t.desc, .{})}) catch return error.OutOfMemory;
    }
    w.writeAll("],\"log\":[") catch return error.OutOfMemory;
    for (phase_log, 0..) |line, i| {
        if (i > 0) w.writeAll(",") catch return error.OutOfMemory;
        w.print("{f}", .{json.fmt(line, .{})}) catch return error.OutOfMemory;
    }
    w.writeAll("]}") catch return error.OutOfMemory;

    const res = self.worker.call(function, req.written()) catch |err| return err;
    switch (res) {
        .ok => |payload| self.gpa.free(payload),
        .err => |code| {
            defer self.gpa.free(code);
            return error.Failed;
        },
    }
}

/// Wall-clock "YYYY-MM-DD HH:MM" (UTC). Continuity stamps are advisory
/// prose, not ordering keys, so UTC without a zone suffix is acceptable.
fn nowStamp() [16]u8 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    const secs: u64 = @intCast(@max(0, ts.sec));
    const ep: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const yd = ep.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = ep.getDaySeconds();
    var out: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(),
    }) catch unreachable;
    return out;
}

fn replyTerminal(arena: std.mem.Allocator, m: *const Mission) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "{{\"state\":\"{t}\",\"stop\":\"{t}\",\"detail\":{f},\"role_turns\":{d},\"tasks_done\":{d}}}",
        .{ m.state, m.stop, json.fmt(m.detail, .{}), m.role_turns_used, m.tasksDone() },
    );
}

/// Parked, not terminal: state is on disk, resume completes it.
fn replyParked(arena: std.mem.Allocator, m: *const Mission) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "{{\"state\":\"{t}\",\"stop\":\"{t}\",\"paused\":true,\"role_turns\":{d},\"tasks_done\":{d}}}",
        .{ m.state, m.stop, m.role_turns_used, m.tasksDone() },
    );
}

const RoleOut = union(enum) {
    ok: []const u8, // final assistant text, arena-owned
    failed: []const u8, // human-readable reason, arena-owned
    exhausted, // the turn stopped on its step budget (max_steps), not an error
};

/// One role = one `zygos::turns::run` turn. Counts against max_role_turns
/// whether it succeeds or not. Role boundaries bracket the turn's own events
/// in the trace, so a stalled executor is attributable at a glance.
fn runRole(
    self: *MissionOrchestrator,
    arena: std.mem.Allocator,
    cfg: RunConfig,
    m: *Mission,
    role: Role,
    content: []const u8,
    with_tools: bool,
) MissionError!RoleOut {
    try trace_mod.emit(arena, cfg.trace_path, .{ .role_start = .{
        .role = role.stepId(),
        .role_turn = @intCast(m.role_turns_used + 1),
        .tools = with_tools,
        .content = try trace_mod.clip(arena, content),
    } });
    const out = try runRoleTurn(self, arena, cfg, m, role, content, with_tools);
    switch (out) {
        .ok => try trace_mod.emit(arena, cfg.trace_path, .{ .role_end = .{
            .role = role.stepId(),
            .outcome = "ok",
        } }),
        .failed => |reason| try trace_mod.emit(arena, cfg.trace_path, .{ .role_end = .{
            .role = role.stepId(),
            .outcome = "failed",
            .reason = reason,
        } }),
        .exhausted => try trace_mod.emit(arena, cfg.trace_path, .{ .role_end = .{
            .role = role.stepId(),
            .outcome = "exhausted",
        } }),
    }
    // Strategies absorb every outcome (the view is pre-completion — the
    // driver updates task state after this returns). Absorb failures degrade
    // context, never the mission (fail-open, like the trace).
    const outcome: context_mod.Outcome = switch (out) {
        .ok => |t| .{ .role = role.stepId(), .ok = true, .text = t },
        .failed => |r| .{ .role = role.stepId(), .ok = false, .text = r },
        .exhausted => .{ .role = role.stepId(), .ok = false, .text = "max_steps" },
    };
    cfg.strategy.absorb(try stepRefFor(arena, cfg, m, role), outcome) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => log.warn("context absorb failed (mission unaffected): {t}", .{err}),
    };
    return out;
}

fn runRoleTurn(
    self: *MissionOrchestrator,
    arena: std.mem.Allocator,
    cfg: RunConfig,
    m: *Mission,
    role: Role,
    content: []const u8,
    with_tools: bool,
) MissionError!RoleOut {
    m.role_turns_used += 1;
    log.info("mission {s}: role turn {d} — {s} (tools: {})", .{
        m.mission_id, m.role_turns_used, role.stepId(), with_tools,
    });

    var req: std.Io.Writer.Allocating = .init(arena);
    errdefer req.deinit();
    const w = &req.writer;
    w.print("{{\"system\":{f},\"step_id\":{f},\"max_steps\":{d}," ++
        "\"messages\":[{{\"role\":\"user\",\"content\":{f}}}]", .{
        json.fmt(role.system(), .{}),
        json.fmt(role.stepId(), .{}),
        cfg.role_max_steps,
        json.fmt(content, .{}),
    }) catch return error.OutOfMemory;
    if (cfg.provider_function) |v|
        w.print(",\"provider_function\":{f}", .{json.fmt(v, .{})}) catch return error.OutOfMemory;
    if (cfg.router_function) |v|
        w.print(",\"router_function\":{f}", .{json.fmt(v, .{})}) catch return error.OutOfMemory;
    if (cfg.policy_function) |v|
        w.print(",\"policy_function\":{f}", .{json.fmt(v, .{})}) catch return error.OutOfMemory;
    if (cfg.approval_function) |v|
        w.print(",\"approval_function\":{f}", .{json.fmt(v, .{})}) catch return error.OutOfMemory;
    if (cfg.budget_scope) |v|
        w.print(",\"budget_scope\":{f}", .{json.fmt(v, .{})}) catch return error.OutOfMemory;
    if (with_tools) if (cfg.tools_json) |t|
        w.print(",\"tools\":{s}", .{t}) catch return error.OutOfMemory;
    if (cfg.trace_path) |v|
        w.print(",\"trace_path\":{f}", .{json.fmt(v, .{})}) catch return error.OutOfMemory;
    w.writeAll("}") catch return error.OutOfMemory;

    const res = self.worker.call("zygos::turns::run", req.written()) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Shutdown => return .{ .failed = "bus shutdown during role turn" },
    };
    switch (res) {
        .err => |code| {
            defer self.gpa.free(code);
            return .{ .failed = try std.fmt.allocPrint(arena, "{s} turn errored: {s}", .{ role.stepId(), code }) };
        },
        .ok => |payload| {
            defer self.gpa.free(payload);
            const reply = json.parseFromSliceLeaky(json.Value, arena, payload, .{}) catch
                return .{ .failed = "malformed turn reply" };
            if (reply != .object) return .{ .failed = "malformed turn reply" };
            const stop = strField(reply.object, "stop") orelse "failed";
            if (std.mem.eql(u8, stop, "max_steps")) return .exhausted;
            if (!std.mem.eql(u8, stop, "end_turn"))
                return .{ .failed = try std.fmt.allocPrint(arena, "{s} turn stopped: {s}", .{ role.stepId(), stop }) };

            const transcript = reply.object.get("transcript") orelse
                return .{ .failed = "turn reply carried no transcript" };
            if (transcript != .array) return .{ .failed = "turn reply carried no transcript" };
            var i = transcript.array.items.len;
            while (i > 0) {
                i -= 1;
                const msg = transcript.array.items[i];
                if (msg != .object) continue;
                const mrole = strField(msg.object, "role") orelse continue;
                if (!std.mem.eql(u8, mrole, "assistant")) continue;
                return .{ .ok = try assistantText(arena, msg.object) };
            }
            return .{ .failed = "no assistant message in the turn transcript" };
        },
    }
}

/// Concatenated text blocks of an assistant message, duped into the arena
/// (the parsed payload's string slices die with the payload buffer).
fn assistantText(arena: std.mem.Allocator, msg: json.ObjectMap) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const content = msg.get("content") orelse return out.toOwnedSlice(arena);
    switch (content) {
        .string => |s| try out.appendSlice(arena, s),
        .array => |blocks| for (blocks.items) |b| {
            if (b != .object) continue;
            const btype = strField(b.object, "type") orelse continue;
            if (!std.mem.eql(u8, btype, "text")) continue;
            if (strField(b.object, "text")) |t| try out.appendSlice(arena, t);
        },
        else => {},
    }
    return out.toOwnedSlice(arena);
}

/// Real providers wrap role JSON in one whole-output markdown fence.
/// Unwrapping exactly that shape is deterministic — anything else is
/// returned untouched and must still parse as strict JSON (fail closed).
fn unwrapFence(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "```")) return trimmed;
    if (!std.mem.endsWith(u8, trimmed, "```")) return trimmed;
    const open_end = std.mem.indexOfScalar(u8, trimmed, '\n') orelse return trimmed;
    if (trimmed.len < open_end + 1 + 3) return trimmed;
    return std.mem.trim(u8, trimmed[open_end + 1 .. trimmed.len - 3], " \t\r\n");
}

/// Neutral strategy view of the mission (TaskView slice arena-built).
fn stepRefFor(
    arena: std.mem.Allocator,
    cfg: RunConfig,
    m: *const Mission,
    role: Role,
) error{OutOfMemory}!context_mod.StepRef {
    const tasks = try arena.alloc(context_mod.TaskView, m.tasks.len);
    for (m.tasks, 0..) |t, i| tasks[i] = .{ .desc = t.desc, .done = t.done, .result = t.result };
    return .{
        .role = role.stepId(),
        .mission = .{
            .mission_id = m.mission_id,
            .objective = m.objective,
            .acceptance = m.acceptance,
            .feedback = m.feedback,
            .tasks = tasks,
            .task_index = m.task_index,
        },
        .substrate = cfg.substrate,
    };
}

/// Strategy-assembled role content. Null means the mission already moved to
/// failed (with the strategy's exact diagnostic as detail) — callers return.
fn assembleContent(
    arena: std.mem.Allocator,
    cfg: RunConfig,
    m: *Mission,
    role: Role,
) MissionError!?[]const u8 {
    var diag: context_mod.Diag = .{};
    const step = try stepRefFor(arena, cfg, m, role);
    const out = cfg.strategy.assemble(arena, step, cfg.context_budget, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BudgetExceeded => {
            try failRole(m, try std.fmt.allocPrint(
                arena,
                "context budget exceeded assembling {s} content ({d} tokens max)",
                .{ role.stepId(), cfg.context_budget.max_tokens },
            ));
            return null;
        },
        error.Failed => {
            try failRole(m, if (diag.message.len > 0)
                try arena.dupe(u8, diag.message)
            else
                "context assembly failed");
            return null;
        },
    };
    // Operator steer appends after strategy assembly — operator text is
    // sovereign and never dropped by a strategy's packing.
    if (m.steer.len > 0) {
        return try std.fmt.allocPrint(arena, "{s}\n\nOperator steer:\n{s}\n", .{ out.content, m.steer });
    }
    return out.content;
}

fn failRole(m: *Mission, reason: []const u8) error{IllegalTransition}!void {
    m.stop = .role_failed;
    m.detail = reason;
    m.state = try Fsm.apply(m.state, .role_failed);
}

/// Fail-closed rejection of role output, with the raw text persisted to the
/// planning root first — unattended runs have no console, so a rejection
/// that discards the text is undiagnosable.
fn rejectRole(
    self: *MissionOrchestrator,
    arena: std.mem.Allocator,
    cfg: RunConfig,
    m: *Mission,
    role: Role,
    text: []const u8,
    reason: []const u8,
) MissionError!void {
    const name = try std.fmt.allocPrint(arena, "REJECTED-{s}.md", .{role.stepId()});
    try putArtifact(self, cfg, name, text);
    try failRole(m, reason);
}

fn roleDefine(self: *MissionOrchestrator, arena: std.mem.Allocator, cfg: RunConfig, m: *Mission) MissionError!void {
    const content = (try assembleContent(arena, cfg, m, .product_owner)) orelse return;
    switch (try runRole(self, arena, cfg, m, .product_owner, content, false)) {
        .failed => |reason| try failRole(m, reason),
        .exhausted => try failRole(m, "product-owner turn stopped: max_steps"),
        .ok => |text| {
            const parsed = json.parseFromSliceLeaky(json.Value, arena, unwrapFence(text), .{}) catch
                return rejectRole(self, arena, cfg, m, .product_owner, text, "product-owner output is not JSON");
            if (parsed != .object)
                return rejectRole(self, arena, cfg, m, .product_owner, text, "product-owner output is not an object");
            const objective = strField(parsed.object, "objective") orelse
                return rejectRole(self, arena, cfg, m, .product_owner, text, "product-owner output lacks objective");
            const acceptance = strField(parsed.object, "acceptance") orelse
                return rejectRole(self, arena, cfg, m, .product_owner, text, "product-owner output lacks acceptance");
            m.objective = objective;
            m.acceptance = acceptance;
            const md = try std.fmt.allocPrint(
                arena,
                "# Mission {s}\n\n## Objective\n\n{s}\n\n## Acceptance\n\n{s}\n",
                .{ m.mission_id, objective, acceptance },
            );
            try putArtifact(self, cfg, mission_artifact, md);
            m.state = try Fsm.apply(m.state, .objective_ready);
        },
    }
}

fn rolePlan(self: *MissionOrchestrator, arena: std.mem.Allocator, cfg: RunConfig, m: *Mission) MissionError!void {
    const content = (try assembleContent(arena, cfg, m, .planner)) orelse return;
    switch (try runRole(self, arena, cfg, m, .planner, content, false)) {
        .failed => |reason| try failRole(m, reason),
        .exhausted => try failRole(m, "planner turn stopped: max_steps"),
        .ok => |text| {
            const parsed = json.parseFromSliceLeaky(json.Value, arena, unwrapFence(text), .{}) catch
                return rejectRole(self, arena, cfg, m, .planner, text, "planner output is not JSON");
            if (parsed != .object)
                return rejectRole(self, arena, cfg, m, .planner, text, "planner output is not an object");
            const tasks_val = parsed.object.get("tasks") orelse
                return rejectRole(self, arena, cfg, m, .planner, text, "planner output lacks tasks");
            if (tasks_val != .array or tasks_val.array.items.len == 0 or tasks_val.array.items.len > 32)
                return rejectRole(self, arena, cfg, m, .planner, text, "planner tasks must be 1..32 entries");

            const tasks = try arena.alloc(Task, tasks_val.array.items.len);
            var md: std.ArrayList(u8) = .empty;
            try md.appendSlice(arena, "# Plan\n\n");
            for (tasks_val.array.items, 0..) |tv, i| {
                if (tv != .string or tv.string.len == 0)
                    return rejectRole(self, arena, cfg, m, .planner, text, "planner tasks must be non-empty strings");
                tasks[i] = .{ .desc = tv.string };
                try md.appendSlice(arena, "- [ ] ");
                try md.appendSlice(arena, tv.string);
                try md.append(arena, '\n');
            }
            try putArtifact(self, cfg, plan_artifact, md.items);
            m.tasks = tasks;
            m.task_index = 0;
            m.feedback = "";
            m.state = try Fsm.apply(m.state, .plan_ready);
        },
    }
}

/// First `max` bytes of a role answer, cut back to a space (and never inside
/// a UTF-8 sequence) — enough context for the next turn, not a transcript.
fn outcomeExcerpt(arena: std.mem.Allocator, text: []const u8, max: usize) error{OutOfMemory}![]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len <= max) return arena.dupe(u8, trimmed);
    var end = max;
    while (end > 0 and (trimmed[end] & 0xC0) == 0x80) end -= 1;
    if (std.mem.lastIndexOfScalar(u8, trimmed[0..end], ' ')) |sp| {
        if (sp > max / 2) end = sp;
    }
    return std.fmt.allocPrint(arena, "{s}…", .{std.mem.trimEnd(u8, trimmed[0..end], " \t\r\n")});
}

fn roleExecute(self: *MissionOrchestrator, arena: std.mem.Allocator, cfg: RunConfig, m: *Mission) MissionError!void {
    std.debug.assert(m.task_index < m.tasks.len);
    const content = (try assembleContent(arena, cfg, m, .executor)) orelse return;

    // Task edges are trace-only (fail-open, not protocol frames): the TUI
    // keys its live current-task line off start/done pairs.
    try trace_mod.emit(arena, cfg.trace_path, .{ .task_start = .{
        .index = @intCast(m.task_index + 1),
        .total = @intCast(m.tasks.len),
        .desc = try trace_mod.clip(arena, m.tasks[m.task_index].desc),
    } });

    switch (try runRole(self, arena, cfg, m, .executor, content, true)) {
        .failed => |reason| try failRole(m, reason),
        // A step-budget stop is exhaustion, not malfunction: retry the same
        // task with feedback, counted against the same escalation threshold
        // as verify failures — never an instant mission failure.
        .exhausted => {
            m.exec_fail_count += 1;
            if (m.exec_fail_count >= cfg.fail_threshold) {
                m.stop = .escalated;
                m.detail = try std.fmt.allocPrint(
                    arena,
                    "executor step budget exhausted {d} times on task {d}",
                    .{ m.exec_fail_count, m.task_index + 1 },
                );
                m.state = try Fsm.apply(m.state, .escalate);
            } else {
                m.feedback = "the previous attempt ran out of steps (max_steps); " ++
                    "finish this task with fewer, more decisive tool calls and then stop";
                // state stays .executing — the loop re-runs this task.
            }
        },
        .ok => |text| {
            m.feedback = "";
            m.exec_fail_count = 0;
            m.tasks[m.task_index].done = true;
            m.tasks[m.task_index].result = try outcomeExcerpt(arena, text, 600);
            try trace_mod.emit(arena, cfg.trace_path, .{ .task_done = .{
                .index = @intCast(m.task_index + 1),
                .total = @intCast(m.tasks.len),
                .desc = try trace_mod.clip(arena, m.tasks[m.task_index].desc),
            } });
            m.task_index += 1;
            m.state = try Fsm.apply(m.state, if (m.task_index == m.tasks.len) .tasks_done else .task_done);
        },
    }
}

fn roleVerify(self: *MissionOrchestrator, arena: std.mem.Allocator, cfg: RunConfig, m: *Mission) MissionError!void {
    const content = (try assembleContent(arena, cfg, m, .verifier)) orelse return;
    switch (try runRole(self, arena, cfg, m, .verifier, content, false)) {
        .failed => |reason| try failRole(m, reason),
        .exhausted => try failRole(m, "verifier turn stopped: max_steps"),
        .ok => |text| {
            const parsed = json.parseFromSliceLeaky(json.Value, arena, unwrapFence(text), .{}) catch
                return rejectRole(self, arena, cfg, m, .verifier, text, "verifier output is not JSON");
            if (parsed != .object)
                return rejectRole(self, arena, cfg, m, .verifier, text, "verifier output is not an object");
            const passed_val = parsed.object.get("passed") orelse
                return rejectRole(self, arena, cfg, m, .verifier, text, "verifier output lacks passed");
            if (passed_val != .bool)
                return rejectRole(self, arena, cfg, m, .verifier, text, "verifier passed must be a bool");
            const passed = passed_val.bool;
            const reason = strField(parsed.object, "reason") orelse "";

            const md = try std.fmt.allocPrint(arena, "# Verify\n\npassed: {}\n\n{s}\n", .{ passed, reason });
            try putArtifact(self, cfg, verify_artifact, md);

            if (passed) {
                m.fail_count = 0;
                m.state = try Fsm.apply(m.state, .verify_passed);
            } else {
                journal(self, cfg, "replan", reason);
                m.fail_count += 1;
                if (m.fail_count >= cfg.fail_threshold) {
                    m.stop = .escalated;
                    m.detail = try std.fmt.allocPrint(
                        arena,
                        "verify failed {d} consecutive times; last: {s}",
                        .{ m.fail_count, reason },
                    );
                    m.state = try Fsm.apply(m.state, .escalate);
                } else {
                    m.feedback = reason;
                    m.state = try Fsm.apply(m.state, .verify_failed);
                }
            }
        },
    }
}

/// V5 — the hard gate. Reaching done REQUIRES an affirmative reply from a
/// real gate function; every other outcome (no function configured, bus
/// error, malformed reply) is gate_failed. Fail closed, no exceptions.
fn gate(self: *MissionOrchestrator, arena: std.mem.Allocator, cfg: RunConfig, m: *Mission) MissionError!void {
    const gate_fn = cfg.gate_function orelse
        return gateFail(m, "no gate_function: a mission cannot complete ungated");

    const req = try std.fmt.allocPrint(
        arena,
        "{{\"turn_id\":{f},\"tool\":\"mission::complete\",\"reason\":{f},\"summary\":{f}}}",
        .{ json.fmt(m.mission_id, .{}), json.fmt(m.objective, .{}), json.fmt(m.objective, .{}) },
    );
    const res = self.worker.call(gate_fn, req) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Shutdown => return gateFail(m, "gate unreachable: bus shutdown"),
    };
    switch (res) {
        .err => |code| {
            defer self.gpa.free(code);
            return gateFail(m, try std.fmt.allocPrint(arena, "gate unreachable: {s}", .{code}));
        },
        .ok => |payload| {
            defer self.gpa.free(payload);
            const parsed = json.parseFromSliceLeaky(json.Value, arena, payload, .{}) catch
                return gateFail(m, "malformed gate reply");
            if (parsed != .object) return gateFail(m, "malformed gate reply");
            const approved_val = parsed.object.get("approved") orelse
                return gateFail(m, "malformed gate reply");
            if (approved_val != .bool) return gateFail(m, "malformed gate reply");

            if (approved_val.bool) {
                journal(self, cfg, "accept", m.objective);
                m.stop = .completed;
                m.detail = "";
                m.state = try Fsm.apply(m.state, .gate_approved);
                return;
            }
            const reason = try arena.dupe(u8, strField(parsed.object, "reason") orelse "gate denied");
            journal(self, cfg, "redo", reason);
            m.gate_denials += 1;
            if (m.gate_denials >= cfg.gate_threshold) {
                return gateFail(m, reason);
            }
            m.feedback = reason;
            m.state = try Fsm.apply(m.state, .gate_denied);
        },
    }
}

fn gateFail(m: *Mission, reason: []const u8) error{IllegalTransition}!void {
    m.stop = .gate_failed;
    m.detail = reason;
    m.state = try Fsm.apply(m.state, .gate_failed);
}

fn putArtifact(self: *MissionOrchestrator, cfg: RunConfig, name: []const u8, bytes: []const u8) MissionError!void {
    cfg.store.writeArtifact(self.gpa, name, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Failed,
    };
}

fn getArtifact(self: *MissionOrchestrator, arena: std.mem.Allocator, cfg: RunConfig, name: []const u8) ?[]const u8 {
    const bytes = cfg.store.readArtifact(self.gpa, name) catch return null;
    defer self.gpa.free(bytes);
    return arena.dupe(u8, bytes) catch null;
}

fn cloneToArena(arena: std.mem.Allocator, m: *const Mission) error{OutOfMemory}!Mission {
    const tasks = try arena.alloc(Task, m.tasks.len);
    for (m.tasks, 0..) |t, i| {
        tasks[i] = .{ .desc = try arena.dupe(u8, t.desc), .done = t.done };
    }
    return .{
        .mission_id = try arena.dupe(u8, m.mission_id),
        .state = m.state,
        .stop = m.stop,
        .detail = try arena.dupe(u8, m.detail),
        .objective = try arena.dupe(u8, m.objective),
        .acceptance = try arena.dupe(u8, m.acceptance),
        .feedback = try arena.dupe(u8, m.feedback),
        .tasks = tasks,
        .task_index = m.task_index,
        .fail_count = m.fail_count,
        .exec_fail_count = m.exec_fail_count,
        .gate_denials = m.gate_denials,
        .role_turns_used = m.role_turns_used,
    };
}

fn strField(obj: json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn uintFieldOr(obj: json.ObjectMap, key: []const u8, default: usize) usize {
    const v = obj.get(key) orelse return default;
    if (v != .integer or v.integer <= 0) return default;
    return @intCast(v.integer);
}

fn controlTarget(arena: std.mem.Allocator, request_json: []const u8) ?[]const u8 {
    const root = json.parseFromSliceLeaky(json.Value, arena, request_json, .{}) catch return null;
    if (root != .object) return null;
    return strField(root.object, "mission_id");
}

fn rawJson(arena: std.mem.Allocator, value: json.Value) error{OutOfMemory}![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    errdefer out.deinit();
    var ws: json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    ws.write(value) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

// ===========================================================================
// Tests (docs/specs/mission.md contract, RED first)
// ===========================================================================

const testing = std.testing;

// -- FSM: exhaustive ---------------------------------------------------------

test "every legal transition maps to the spec table" {
    for (transitions) |t| {
        try testing.expectEqual(t.to, try Fsm.apply(t.from, t.event));
    }
}

test "every state-event pair not in the table is IllegalTransition" {
    inline for (@typeInfo(State).@"enum".fields) |sf| {
        inline for (@typeInfo(Event).@"enum".fields) |ef| {
            const s: State = @enumFromInt(sf.value);
            const e: Event = @enumFromInt(ef.value);
            var legal = false;
            for (transitions) |t| {
                if (t.from == s and t.event == e) legal = true;
            }
            if (!legal) {
                try testing.expectError(error.IllegalTransition, Fsm.apply(s, e));
            }
        }
    }
}

test "terminal states reject all events" {
    inline for (@typeInfo(Event).@"enum".fields) |ef| {
        const e: Event = @enumFromInt(ef.value);
        try testing.expectError(error.IllegalTransition, Fsm.apply(.done, e));
        try testing.expectError(error.IllegalTransition, Fsm.apply(.failed, e));
    }
}

test "the happy chain walks defining to done" {
    var s: State = .defining;
    s = try Fsm.apply(s, .objective_ready);
    try testing.expectEqual(State.planning, s);
    s = try Fsm.apply(s, .plan_ready);
    try testing.expectEqual(State.executing, s);
    s = try Fsm.apply(s, .task_done);
    try testing.expectEqual(State.executing, s);
    s = try Fsm.apply(s, .tasks_done);
    try testing.expectEqual(State.verifying, s);
    s = try Fsm.apply(s, .verify_passed);
    try testing.expectEqual(State.gating, s);
    s = try Fsm.apply(s, .gate_approved);
    try testing.expectEqual(State.done, s);
}

test "rework loops re-enter planning" {
    try testing.expectEqual(State.planning, try Fsm.apply(.verifying, .verify_failed));
    try testing.expectEqual(State.planning, try Fsm.apply(.gating, .gate_denied));
}

// -- Driver: scripted providers over the real bus -----------------------------

const turn_mod = @import("turn.zig");
const approval_mod = @import("approval.zig");
const router_mod = @import("router.zig");

extern "c" fn realpath(path: [*:0]const u8, resolved: [*]u8) ?[*:0]u8;

/// JSON-escape a comptime string for embedding as a JSON string value.
fn escJson(comptime s: []const u8) []const u8 {
    comptime var out: []const u8 = "";
    inline for (s) |ch| {
        out = out ++ switch (ch) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            else => &[_]u8{ch},
        };
    }
    return out;
}

/// A provider terminal message whose single text block is `inner`.
fn roleText(comptime inner: []const u8) []const u8 {
    return "{\"stop_reason\":\"end_turn\",\"content\":[{\"type\":\"text\",\"text\":\"" ++
        comptime escJson(inner) ++ "\"}]}";
}

const po_ok = roleText("{\"objective\":\"Ship the gizmo\",\"acceptance\":\"the gizmo ships\"}");
const plan2 = roleText("{\"tasks\":[\"build the gizmo\",\"test the gizmo\"]}");
const plan1 = roleText("{\"tasks\":[\"polish the gizmo\"]}");
const exec_ok = roleText("task complete");
const verify_pass = roleText("{\"passed\":true,\"reason\":\"acceptance met\"}");
const verify_fail = roleText("{\"passed\":false,\"reason\":\"missing tests\"}");

/// Scripted provider that records every request. Call N returns script[N]
/// (last entry repeats); the literal "ERR" fails the call; an empty script
/// fails every call. Can park one call for abort/status races.
const RecProvider = struct {
    gpa: std.mem.Allocator,
    worker: *inproc.Worker,
    mutex: sync.Mutex = .{},
    script: []const []const u8,
    calls: usize = 0,
    requests: std.ArrayList([]u8) = .empty,
    park_at: ?usize = null,
    entered: sync.ResetEvent = .{},
    release: sync.ResetEvent = .{},

    fn start(gpa: std.mem.Allocator, actor: *actor_mod.Actor, registry: *inproc.Registry, script: []const []const u8) !*RecProvider {
        const self = try gpa.create(RecProvider);
        self.* = .{
            .gpa = gpa,
            .worker = try inproc.Worker.spawn(gpa, actor, registry, "rec-provider"),
            .script = script,
        };
        try self.worker.registerFunction("zygos::provider::rec::messages", self, &handler);
        return self;
    }

    fn stop(self: *RecProvider) void {
        self.worker.stop();
        for (self.requests.items) |r| self.gpa.free(r);
        self.requests.deinit(self.gpa);
        self.entered.deinit();
        self.release.deinit();
        self.mutex.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    fn callCount(self: *RecProvider) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.calls;
    }

    fn handler(ctx: ?*anyopaque, arena: std.mem.Allocator, request_json: []const u8) error{ Failed, OutOfMemory }![]const u8 {
        const self: *RecProvider = @ptrCast(@alignCast(ctx.?));
        const n = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            const dup = try self.gpa.dupe(u8, request_json);
            self.requests.append(self.gpa, dup) catch return error.OutOfMemory;
            const n = self.calls;
            self.calls += 1;
            break :blk n;
        };
        if (self.park_at) |p| if (p == n) {
            self.entered.set();
            self.release.wait();
        };
        if (self.script.len == 0) return error.Failed;
        const msg = self.script[@min(n, self.script.len - 1)];
        if (std.mem.eql(u8, msg, "ERR")) return error.Failed;
        return arena.dupe(u8, msg);
    }
};

/// Scripted gate on `test::gate::request` (last entry repeats).
const FakeGate = struct {
    gpa: std.mem.Allocator,
    worker: *inproc.Worker,
    mutex: sync.Mutex = .{},
    script: []const []const u8,
    calls: usize = 0,

    fn start(gpa: std.mem.Allocator, actor: *actor_mod.Actor, registry: *inproc.Registry, script: []const []const u8) !*FakeGate {
        const self = try gpa.create(FakeGate);
        self.* = .{
            .gpa = gpa,
            .worker = try inproc.Worker.spawn(gpa, actor, registry, "fake-gate"),
            .script = script,
        };
        try self.worker.registerFunction("test::gate::request", self, &handler);
        return self;
    }

    fn stop(self: *FakeGate) void {
        self.worker.stop();
        self.mutex.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    fn handler(ctx: ?*anyopaque, arena: std.mem.Allocator, request_json: []const u8) error{ Failed, OutOfMemory }![]const u8 {
        _ = request_json;
        const self: *FakeGate = @ptrCast(@alignCast(ctx.?));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.script.len == 0) return error.Failed;
        const msg = self.script[@min(self.calls, self.script.len - 1)];
        self.calls += 1;
        return arena.dupe(u8, msg);
    }
};

const Harness = struct {
    registry: inproc.Registry,
    actor: actor_mod.Actor,
    kernel: std.Thread,
    turns: *turn_mod.TurnOrchestrator,
    orch: *MissionOrchestrator,
    provider: *RecProvider,
    caller: *inproc.Worker,
    tmp: std.testing.TmpDir,
    root_buf: [std.fs.max_path_bytes]u8 = undefined,
    root: []const u8 = undefined,

    fn init(gpa: std.mem.Allocator, script: []const []const u8) !*Harness {
        const self = try gpa.create(Harness);
        self.tmp = std.testing.tmpDir(.{});
        var rel_buf: [std.fs.max_path_bytes]u8 = undefined;
        const rel = try std.fmt.bufPrintZ(&rel_buf, ".zig-cache/tmp/{s}", .{self.tmp.sub_path});
        const resolved = realpath(rel, &self.root_buf) orelse return error.RealpathFailed;
        self.root = std.mem.span(resolved);

        self.registry = inproc.Registry.init(gpa, null);
        self.actor = try actor_mod.Actor.init(gpa, .{}, self.registry.outbound());
        self.kernel = try std.Thread.spawn(.{}, actor_mod.Actor.run, .{&self.actor});
        self.turns = try turn_mod.TurnOrchestrator.start(gpa, &self.actor, &self.registry);
        self.orch = try MissionOrchestrator.start(gpa, &self.actor, &self.registry);
        self.provider = try RecProvider.start(gpa, &self.actor, &self.registry, script);
        self.caller = try inproc.Worker.spawn(gpa, &self.actor, &self.registry, "test-caller");
        return self;
    }

    fn deinit(self: *Harness) void {
        const gpa = self.actor.gpa;
        self.caller.stop();
        self.provider.stop();
        self.orch.stop();
        self.turns.stop();
        self.actor.post(.shutdown);
        self.kernel.join();
        self.actor.deinit();
        self.registry.deinit();
        self.tmp.cleanup();
        gpa.destroy(self);
    }

    /// Start request against this harness's planning root; `extra` rides
    /// verbatim after the provider function (objective, gate, thresholds…).
    fn startReq(self: *Harness, gpa: std.mem.Allocator, extra: []const u8) ![]u8 {
        return std.fmt.allocPrint(
            gpa,
            "{{\"mission_id\":\"m-1\",\"planning_root\":{f}," ++
                "\"provider_function\":\"zygos::provider::rec::messages\"{s}}}",
            .{ json.fmt(self.root, .{}), extra },
        );
    }

    fn store(self: *Harness) store_mod.Store {
        return store_mod.Store.init(self.root);
    }
};

const seed_and_gate = ",\"objective\":\"seed: gizmo\",\"gate_function\":\"zygos::approvals::request\"";

fn expectTerminal(payload: []const u8, state: []const u8, stop: []const u8) !void {
    var p = try json.parseFromSlice(json.Value, testing.allocator, payload, .{});
    defer p.deinit();
    try testing.expectEqualStrings(state, p.value.object.get("state").?.string);
    try testing.expectEqualStrings(stop, p.value.object.get("stop").?.string);
}

test "context_strategy: a tiny max_tokens budget fails the mission with a budget detail" {
    var h = try Harness.init(testing.allocator, &.{po_ok});
    defer h.deinit();

    // "seed: gizmo" is 3 tokens; a 1-token budget must refuse the assembly
    // before any provider turn runs.
    const req = try h.startReq(
        testing.allocator,
        ",\"objective\":\"seed: gizmo\",\"context_strategy\":{\"kind\":\"substrate\",\"max_tokens\":1}",
    );
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::missions::start", req);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try expectTerminal(res.ok, "failed", "role_failed");
    try testing.expect(std.mem.indexOf(u8, res.ok, "context budget exceeded") != null);
}

test "context_strategy: kind recall runs the pipeline and persists a source index" {
    var h = try Harness.init(testing.allocator, &.{ po_ok, plan1, exec_ok, verify_pass });
    defer h.deinit();
    const approvals = try approval_mod.ApprovalWorker.start(testing.allocator, &h.actor, &h.registry, .auto_approve);
    defer approvals.stop();

    const req = try h.startReq(
        testing.allocator,
        seed_and_gate ++ ",\"context_strategy\":{\"kind\":\"recall\"}",
    );
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::missions::start", req);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try expectTerminal(res.ok, "done", "completed");

    // Absorbed role outcomes landed in the rolling index on disk.
    const spath = try std.fmt.allocPrint(testing.allocator, "{s}/memory/sources.jsonl", .{h.root});
    defer testing.allocator.free(spath);
    const text = trace_mod.readFile(testing.allocator, spath) orelse return error.ReadFailed;
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "\"id\":\"outcome:executor:0\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"id\":\"outcome:verifier:") != null);
}

test "context_strategy: kind thread runs the pipeline and persists per-task threads" {
    var h = try Harness.init(testing.allocator, &.{ po_ok, plan1, exec_ok, verify_pass });
    defer h.deinit();
    const approvals = try approval_mod.ApprovalWorker.start(testing.allocator, &h.actor, &h.registry, .auto_approve);
    defer approvals.stop();

    const req = try h.startReq(
        testing.allocator,
        seed_and_gate ++ ",\"context_strategy\":{\"kind\":\"thread\"}",
    );
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::missions::start", req);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try expectTerminal(res.ok, "done", "completed");

    const tpath = try std.fmt.allocPrint(testing.allocator, "{s}/threads/task-0.jsonl", .{h.root});
    defer testing.allocator.free(tpath);
    const text = trace_mod.readFile(testing.allocator, tpath) orelse return error.ReadFailed;
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "\"role\":\"executor\"") != null);
}

test "context_strategy: an unknown kind refuses the start (fail closed)" {
    var h = try Harness.init(testing.allocator, &.{po_ok});
    defer h.deinit();
    for ([_][]const u8{"transcript-dump"}) |kind| {
        const extra = try std.fmt.allocPrint(
            testing.allocator,
            ",\"objective\":\"seed: gizmo\",\"context_strategy\":{{\"kind\":\"{s}\"}}",
            .{kind},
        );
        defer testing.allocator.free(extra);
        const req = try h.startReq(testing.allocator, extra);
        defer testing.allocator.free(req);
        const res = try h.caller.call("zygos::missions::start", req);
        defer res.deinit(testing.allocator);
        try testing.expect(res == .err);
    }
}

test "trace_path threads through role turns: role, mission and turn events land in one events.jsonl" {
    var h = try Harness.init(testing.allocator, &.{ po_ok, plan1, exec_ok, verify_pass });
    defer h.deinit();
    const approvals = try approval_mod.ApprovalWorker.start(testing.allocator, &h.actor, &h.registry, .auto_approve);
    defer approvals.stop();

    const tpath = try std.fmt.allocPrint(testing.allocator, "{s}/events.jsonl", .{h.root});
    defer testing.allocator.free(tpath);
    const extra = try std.fmt.allocPrint(
        testing.allocator,
        seed_and_gate ++ ",\"trace_path\":{f}",
        .{json.fmt(tpath, .{})},
    );
    defer testing.allocator.free(extra);

    const req = try h.startReq(testing.allocator, extra);
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::missions::start", req);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try expectTerminal(res.ok, "done", "completed");

    const text = trace_mod.readFile(testing.allocator, tpath) orelse return error.ReadFailed;
    defer testing.allocator.free(text);

    // Role boundaries for all four roles, both edges.
    try testing.expect(std.mem.indexOf(u8, text, "\"event\":\"role_start\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"event\":\"role_end\"") != null);
    for ([_][]const u8{ "product-owner", "planner", "executor", "verifier" }) |role| {
        const needle = try std.fmt.allocPrint(testing.allocator, "\"role\":\"{s}\"", .{role});
        defer testing.allocator.free(needle);
        try testing.expect(std.mem.indexOf(u8, text, needle) != null);
    }
    // Mission transitions.
    try testing.expect(std.mem.indexOf(u8, text, "\"event\":\"mission\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"from\":\"defining\",\"to\":\"planning\"") != null);
    // trace_path reached the turn driver: per-step provider events interleave.
    try testing.expect(std.mem.indexOf(u8, text, "\"event\":\"step\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"event\":\"turn_end\"") != null);

    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    while (lines.next()) |line| {
        var p = try json.parseFromSlice(json.Value, testing.allocator, line, .{});
        defer p.deinit();
        try testing.expect(p.value == .object);
    }
}

test "executor emits task_start and task_done with index, total and desc" {
    var h = try Harness.init(testing.allocator, &.{ po_ok, plan2, exec_ok, exec_ok, verify_pass });
    defer h.deinit();
    const approvals = try approval_mod.ApprovalWorker.start(testing.allocator, &h.actor, &h.registry, .auto_approve);
    defer approvals.stop();

    const tpath = try std.fmt.allocPrint(testing.allocator, "{s}/events.jsonl", .{h.root});
    defer testing.allocator.free(tpath);
    const extra = try std.fmt.allocPrint(
        testing.allocator,
        seed_and_gate ++ ",\"trace_path\":{f}",
        .{json.fmt(tpath, .{})},
    );
    defer testing.allocator.free(extra);
    const req = try h.startReq(testing.allocator, extra);
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::missions::start", req);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try expectTerminal(res.ok, "done", "completed");

    const text = trace_mod.readFile(testing.allocator, tpath) orelse return error.ReadFailed;
    defer testing.allocator.free(text);

    // Both edges for both tasks: 1-based index, total, and the task desc.
    for ([_][]const u8{
        "\"event\":\"task_start\",\"index\":1,\"total\":2,\"desc\":\"build the gizmo\"",
        "\"event\":\"task_done\",\"index\":1,\"total\":2,\"desc\":\"build the gizmo\"",
        "\"event\":\"task_start\",\"index\":2,\"total\":2,\"desc\":\"test the gizmo\"",
        "\"event\":\"task_done\",\"index\":2,\"total\":2,\"desc\":\"test the gizmo\"",
    }) |needle| {
        try testing.expect(std.mem.indexOf(u8, text, needle) != null);
    }
    // The first task closes before the second opens: the TUI hand-off moment.
    const done1 = std.mem.indexOf(u8, text, "\"event\":\"task_done\",\"index\":1").?;
    const start2 = std.mem.indexOf(u8, text, "\"event\":\"task_start\",\"index\":2").?;
    try testing.expect(done1 < start2);
}

test "happy path: define, plan, execute x2, verify, gate approve; artifacts + terminal state on disk" {
    var h = try Harness.init(testing.allocator, &.{ po_ok, plan2, exec_ok, exec_ok, verify_pass });
    defer h.deinit();
    const approvals = try approval_mod.ApprovalWorker.start(testing.allocator, &h.actor, &h.registry, .auto_approve);
    defer approvals.stop();

    // Per-role step_ids proven through real routing: only the four role
    // step_ids resolve; any other routing key would fail the mission.
    const zon =
        \\.{ .routes = .{
        \\    .{ .step_id = "product-owner", .attempts = .{ .{ .provider_function = "zygos::provider::rec::messages", .model = "po-m" } } },
        \\    .{ .step_id = "planner", .attempts = .{ .{ .provider_function = "zygos::provider::rec::messages", .model = "plan-m" } } },
        \\    .{ .step_id = "executor", .attempts = .{ .{ .provider_function = "zygos::provider::rec::messages", .model = "exec-m" } } },
        \\    .{ .step_id = "verifier", .attempts = .{ .{ .provider_function = "zygos::provider::rec::messages", .model = "verify-m" } } },
        \\} }
    ;
    const rcfg = try router_mod.Config.parse(testing.allocator, zon);
    const router = try router_mod.RouterWorker.start(testing.allocator, &h.actor, &h.registry, rcfg);
    defer router.stop();

    const req = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"mission_id\":\"m-1\",\"planning_root\":{f},\"objective\":\"seed: gizmo\"," ++
            "\"router_function\":\"zygos::models::resolve\"," ++
            "\"gate_function\":\"zygos::approvals::request\"}}",
        .{json.fmt(h.root, .{})},
    );
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::missions::start", req);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try expectTerminal(res.ok, "done", "completed");

    var p = try json.parseFromSlice(json.Value, testing.allocator, res.ok, .{});
    defer p.deinit();
    try testing.expectEqual(@as(i64, 5), p.value.object.get("role_turns").?.integer);
    try testing.expectEqual(@as(i64, 2), p.value.object.get("tasks_done").?.integer);

    // The substrate holds the artifacts and the terminal record.
    const brief = try h.store().readArtifact(testing.allocator, "MISSION.md");
    defer testing.allocator.free(brief);
    try testing.expect(std.mem.indexOf(u8, brief, "Ship the gizmo") != null);
    const plan = try h.store().readArtifact(testing.allocator, "PLAN.md");
    defer testing.allocator.free(plan);
    try testing.expect(std.mem.indexOf(u8, plan, "- [ ] build the gizmo") != null);
    const verdict = try h.store().readArtifact(testing.allocator, "VERIFY.md");
    defer testing.allocator.free(verdict);
    try testing.expect(std.mem.indexOf(u8, verdict, "acceptance met") != null);

    var m = try h.store().load(testing.allocator);
    defer m.deinit(testing.allocator);
    try testing.expectEqual(State.done, m.state);
    try testing.expectEqual(StopReason.completed, m.stop);
    try testing.expectEqual(@as(usize, 2), m.tasksDone());
}

// An executor step that always wants another tool round: with role_max_steps
// pinned low, the turn stops as max_steps instead of end_turn.
const exec_toolspin =
    \\{"stop_reason":"tool_use","content":[{"type":"tool_use","id":"t1","name":"noop","input":{}}]}
;

test "executor turns carry completed-task outcomes forward" {
    const exec_one = roleText("built the gizmo at ./gizmo");
    var h = try Harness.init(testing.allocator, &.{ po_ok, plan2, exec_one, exec_ok, verify_pass });
    defer h.deinit();
    const approvals = try approval_mod.ApprovalWorker.start(testing.allocator, &h.actor, &h.registry, .auto_approve);
    defer approvals.stop();

    const req = try h.startReq(testing.allocator, seed_and_gate);
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::missions::start", req);
    defer res.deinit(testing.allocator);
    try expectTerminal(res.ok, "done", "completed");

    // Call order: po, planner, executor(task 1), executor(task 2), verifier.
    const first_exec = h.provider.requests.items[2];
    const second_exec = h.provider.requests.items[3];

    // Task 1 starts with nothing done — no completed outcomes to carry.
    try testing.expect(std.mem.indexOf(u8, first_exec, "[done]") == null);
    try testing.expect(std.mem.indexOf(u8, first_exec, "build the gizmo") != null);

    // Task 2 must see task 1 marked done WITH its outcome, so it stops
    // re-discovering and re-verifying finished work every turn.
    try testing.expect(std.mem.indexOf(u8, second_exec, "[done] build the gizmo") != null);
    try testing.expect(std.mem.indexOf(u8, second_exec, "built the gizmo at ./gizmo") != null);
    try testing.expect(std.mem.indexOf(u8, second_exec, "[current] test the gizmo") != null);
}

test "executor max_steps retries the task with feedback instead of failing the mission" {
    var h = try Harness.init(testing.allocator, &.{
        po_ok, plan1, exec_toolspin, exec_ok, verify_pass,
    });
    defer h.deinit();
    const approvals = try approval_mod.ApprovalWorker.start(testing.allocator, &h.actor, &h.registry, .auto_approve);
    defer approvals.stop();

    const req = try h.startReq(testing.allocator, seed_and_gate ++ ",\"role_max_steps\":1");
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::missions::start", req);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try expectTerminal(res.ok, "done", "completed");

    // The retry executor turn (call 3, 0-based) carried step-budget feedback.
    h.provider.mutex.lock();
    const retry_req = h.provider.requests.items[3];
    try testing.expect(std.mem.indexOf(u8, retry_req, "ran out of steps") != null);
    h.provider.mutex.unlock();

    var m = try h.store().load(testing.allocator);
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), m.fail_count); // reset on verify pass
}

test "executor exhausting its step budget fail_threshold times escalates to failed" {
    var h = try Harness.init(testing.allocator, &.{ po_ok, plan1, exec_toolspin });
    defer h.deinit();

    const req = try h.startReq(
        testing.allocator,
        seed_and_gate ++ ",\"role_max_steps\":1,\"fail_threshold\":2",
    );
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::missions::start", req);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try expectTerminal(res.ok, "failed", "escalated");

    var p = try json.parseFromSlice(json.Value, testing.allocator, res.ok, .{});
    defer p.deinit();
    try testing.expect(std.mem.indexOf(u8, p.value.object.get("detail").?.string, "step budget") != null);
    // 2 setup turns + exactly fail_threshold executor attempts.
    try testing.expectEqual(@as(i64, 4), p.value.object.get("role_turns").?.integer);
}

test "non-executor role hitting max_steps still fails the mission (no retry loop)" {
    var h = try Harness.init(testing.allocator, &.{
        \\{"stop_reason":"tool_use","content":[{"type":"tool_use","id":"t1","name":"noop","input":{}}]}
    });
    defer h.deinit();

    const req = try h.startReq(testing.allocator, seed_and_gate ++ ",\"role_max_steps\":1");
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::missions::start", req);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try expectTerminal(res.ok, "failed", "role_failed");
}

test "verify fail replans with the verdict as feedback, then passes" {
    var h = try Harness.init(testing.allocator, &.{
        po_ok, plan2, exec_ok, exec_ok, verify_fail, plan1, exec_ok, verify_pass,
    });
    defer h.deinit();
    const approvals = try approval_mod.ApprovalWorker.start(testing.allocator, &h.actor, &h.registry, .auto_approve);
    defer approvals.stop();

    const req = try h.startReq(testing.allocator, seed_and_gate);
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::missions::start", req);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try expectTerminal(res.ok, "done", "completed");

    // Call 5 (0-based) is the replanning planner turn — the verifier's
    // reason must ride in its request.
    try testing.expect(std.mem.indexOf(u8, h.provider.requests.items[5], "missing tests") != null);
    var m = try h.store().load(testing.allocator);
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), m.fail_count); // reset on pass
}

test "fail_threshold consecutive verify failures escalate to failed" {
    var h = try Harness.init(testing.allocator, &.{
        po_ok, plan2, exec_ok, exec_ok, verify_fail, plan1, exec_ok, verify_fail,
    });
    defer h.deinit();

    const req = try h.startReq(testing.allocator, seed_and_gate ++ ",\"fail_threshold\":2");
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::missions::start", req);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try expectTerminal(res.ok, "failed", "escalated");
}

test "gate denial replans with the denial as feedback; second gate approves" {
    var h = try Harness.init(testing.allocator, &.{
        po_ok, plan1, exec_ok, verify_pass, plan1, exec_ok, verify_pass,
    });
    defer h.deinit();
    const gate_worker = try FakeGate.start(testing.allocator, &h.actor, &h.registry, &.{
        "{\"approved\":false,\"reason\":\"needs polish\"}",
        "{\"approved\":true}",
    });
    defer gate_worker.stop();

    const req = try h.startReq(
        testing.allocator,
        ",\"objective\":\"seed: gizmo\",\"gate_function\":\"test::gate::request\"",
    );
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::missions::start", req);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try expectTerminal(res.ok, "done", "completed");
    try testing.expectEqual(@as(usize, 2), gate_worker.calls);
    // Call 4 (0-based) replans after the denial.
    try testing.expect(std.mem.indexOf(u8, h.provider.requests.items[4], "needs polish") != null);
}

test "gate_threshold denials fail the mission as gate_failed" {
    var h = try Harness.init(testing.allocator, &.{ po_ok, plan1, exec_ok, verify_pass });
    defer h.deinit();
    const gate_worker = try FakeGate.start(testing.allocator, &h.actor, &h.registry, &.{
        "{\"approved\":false,\"reason\":\"not good enough\"}",
    });
    defer gate_worker.stop();

    const req = try h.startReq(
        testing.allocator,
        ",\"objective\":\"seed: gizmo\",\"gate_function\":\"test::gate::request\",\"gate_threshold\":1",
    );
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::missions::start", req);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try expectTerminal(res.ok, "failed", "gate_failed");
    try testing.expect(std.mem.indexOf(u8, res.ok, "not good enough") != null);
}

test "no gate_function: mission can never complete (fail closed)" {
    var h = try Harness.init(testing.allocator, &.{ po_ok, plan1, exec_ok, verify_pass });
    defer h.deinit();

    const req = try h.startReq(testing.allocator, ",\"objective\":\"seed: gizmo\"");
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::missions::start", req);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try expectTerminal(res.ok, "failed", "gate_failed");
    try testing.expect(std.mem.indexOf(u8, res.ok, "ungated") != null);
}

test "unreachable gate function fails the mission as gate_failed" {
    var h = try Harness.init(testing.allocator, &.{ po_ok, plan1, exec_ok, verify_pass });
    defer h.deinit();

    const req = try h.startReq(
        testing.allocator,
        ",\"objective\":\"seed: gizmo\",\"gate_function\":\"test::gate::nowhere\"",
    );
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::missions::start", req);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try expectTerminal(res.ok, "failed", "gate_failed");
    try testing.expect(std.mem.indexOf(u8, res.ok, "gate unreachable") != null);
}

test "malformed planner output fails the mission as role_failed" {
    var h = try Harness.init(testing.allocator, &.{ po_ok, roleText("not json at all") });
    defer h.deinit();

    const req = try h.startReq(testing.allocator, seed_and_gate);
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::missions::start", req);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try expectTerminal(res.ok, "failed", "role_failed");
    try testing.expect(std.mem.indexOf(u8, res.ok, "planner") != null);
}

test "rejected role output lands in the planning root for diagnosis" {
    // Unattended runs (Y5) have no console: the raw text a fail-closed
    // parse rejected must survive on disk or the failure is undiagnosable.
    var h = try Harness.init(testing.allocator, &.{
        roleText("I refined the objective for you:\n\nobjective: x\nacceptance: y"),
    });
    defer h.deinit();

    const req = try h.startReq(testing.allocator, seed_and_gate);
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::missions::start", req);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try expectTerminal(res.ok, "failed", "role_failed");

    const rejected = try h.store().readArtifact(testing.allocator, "REJECTED-product-owner.md");
    defer testing.allocator.free(rejected);
    try testing.expect(std.mem.indexOf(u8, rejected, "I refined the objective") != null);
}

test "fenced role JSON is unwrapped deterministically" {
    // Real models wrap role JSON in markdown code fences (observed on the
    // first Y5 run). Unwrapping one whole-output fence is deterministic —
    // the content must still parse as strict JSON or the mission fails.
    var h = try Harness.init(testing.allocator, &.{
        roleText("```json\n" ++
            "{\"objective\": \"Ship the gizmo\", \"acceptance\": \"greeting written and count run\"}\n" ++
            "```"),
        roleText("```\n{\"tasks\": [\"build the gizmo\"]}\n```"),
        exec_ok,
        roleText("```json\n{\"passed\": true, \"reason\": \"acceptance met\"}\n```"),
    });
    defer h.deinit();
    const approvals = try approval_mod.ApprovalWorker.start(testing.allocator, &h.actor, &h.registry, .auto_approve);
    defer approvals.stop();

    const req = try h.startReq(testing.allocator, seed_and_gate);
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::missions::start", req);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try expectTerminal(res.ok, "done", "completed");
}

test "provider error mid-role fails the mission as role_failed" {
    var h = try Harness.init(testing.allocator, &.{ po_ok, "ERR" });
    defer h.deinit();

    const req = try h.startReq(testing.allocator, seed_and_gate);
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::missions::start", req);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try expectTerminal(res.ok, "failed", "role_failed");
}

// -- W1: brief validation (driver side) --------------------------------------

const good_brief =
    "---\nbudget:\n  x: 1\ngates:\n  y: human\n---\n\n" ++
    "# Mission\n\n## Success criteria\n\n" ++
    "| # | Criterion | Verified by |\n|---|---|---|\n| 1 | it works | a test |\n\n" ++
    "## Non-goals\n\n- not this\n";

fn briefStartReq(h: *Harness, gpa: std.mem.Allocator, brief: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "{{\"mission_id\":\"m-1\",\"planning_root\":{f}," ++
            "\"provider_function\":\"zygos::provider::rec::messages\"," ++
            "\"objective\":\"seed\",\"gate_function\":\"test::gate::request\"," ++
            "\"brief\":{f}}}",
        .{ json.fmt(h.root, .{}), json.fmt(brief, .{}) },
    );
}

test "a malformed brief refuses the mission without starting the FSM" {
    var h = try Harness.init(testing.allocator, &.{});
    defer h.deinit();

    // No frontmatter at all — the very first lint check fails.
    const req = try briefStartReq(h, testing.allocator, "# just a heading\n\nno frontmatter here\n");
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::missions::start", req);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try testing.expect(std.mem.indexOf(u8, res.ok, "\"refused\":true") != null);
    try testing.expect(std.mem.indexOf(u8, res.ok, "no_frontmatter") != null);

    // Fail closed: no mission record was persisted.
    try testing.expectError(error.NotFound, h.store().load(testing.allocator));
    // No provider turn ever ran.
    try testing.expectEqual(@as(usize, 0), h.provider.callCount());
}

test "a well-formed brief starts the mission normally" {
    var h = try Harness.init(testing.allocator, &.{ po_ok, plan1, exec_ok, verify_pass });
    defer h.deinit();
    const gate_worker = try FakeGate.start(testing.allocator, &h.actor, &h.registry, &.{"{\"approved\":true}"});
    defer gate_worker.stop();

    const req = try briefStartReq(h, testing.allocator, good_brief);
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::missions::start", req);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try testing.expect(std.mem.indexOf(u8, res.ok, "refused") == null);
    try expectTerminal(res.ok, "done", "completed");
}

const StartCtx = struct {
    h: *Harness,
    req: []const u8,
    res: inproc.CallResult = undefined,

    fn run(self: *StartCtx) void {
        self.res = self.h.caller.call("zygos::missions::start", self.req) catch unreachable;
    }
};

test "abort mid-mission stops durably with aborted" {
    var h = try Harness.init(testing.allocator, &.{ po_ok, plan2, exec_ok, exec_ok, verify_pass });
    defer h.deinit();
    h.provider.park_at = 2; // park the first executor turn
    const ctl_worker = try inproc.Worker.spawn(testing.allocator, &h.actor, &h.registry, "test-control");
    defer ctl_worker.stop();

    const req = try h.startReq(testing.allocator, seed_and_gate);
    defer testing.allocator.free(req);
    var ctx: StartCtx = .{ .h = h, .req = req };
    const t = try std.Thread.spawn(.{}, StartCtx.run, .{&ctx});

    h.provider.entered.wait();
    const ares = try ctl_worker.call("zygos::missions::abort", "{\"mission_id\":\"m-1\"}");
    defer ares.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, ares.ok, "true") != null);
    h.provider.release.set();
    t.join();

    defer ctx.res.deinit(testing.allocator);
    try testing.expect(ctx.res == .ok);
    try expectTerminal(ctx.res.ok, "failed", "aborted");

    var m = try h.store().load(testing.allocator);
    defer m.deinit(testing.allocator);
    try testing.expectEqual(StopReason.aborted, m.stop);
}

test "steer text is consumed at the next role boundary and rides exactly one role turn" {
    var h = try Harness.init(testing.allocator, &.{ po_ok, plan2, exec_ok, exec_ok, verify_pass });
    defer h.deinit();
    const approvals = try approval_mod.ApprovalWorker.start(testing.allocator, &h.actor, &h.registry, .auto_approve);
    defer approvals.stop();
    h.provider.park_at = 2; // park the first executor turn
    const ctl_worker = try inproc.Worker.spawn(testing.allocator, &h.actor, &h.registry, "test-control");
    defer ctl_worker.stop();

    const req = try h.startReq(testing.allocator, seed_and_gate);
    defer testing.allocator.free(req);
    var ctx: StartCtx = .{ .h = h, .req = req };
    const t = try std.Thread.spawn(.{}, StartCtx.run, .{&ctx});

    h.provider.entered.wait();
    const sres = try ctl_worker.call(
        "zygos::missions::steer",
        "{\"mission_id\":\"m-1\",\"text\":\"focus on the gizmo docs\"}",
    );
    defer sres.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, sres.ok, "true") != null);
    h.provider.release.set();
    t.join();
    defer ctx.res.deinit(testing.allocator);
    try expectTerminal(ctx.res.ok, "done", "completed");

    h.provider.mutex.lock();
    defer h.provider.mutex.unlock();
    // The role turn after the boundary (second executor, call 3) carries it…
    try testing.expect(std.mem.indexOf(u8, h.provider.requests.items[3], "Operator steer:") != null);
    try testing.expect(std.mem.indexOf(u8, h.provider.requests.items[3], "focus on the gizmo docs") != null);
    // …and exactly once: the verifier turn after it does not.
    try testing.expect(std.mem.indexOf(u8, h.provider.requests.items[4], "Operator steer:") == null);
}

test "steer for an unknown mission replies ok:false" {
    var h = try Harness.init(testing.allocator, &.{});
    defer h.deinit();
    const res = try h.caller.call("zygos::missions::steer", "{\"mission_id\":\"ghost\",\"text\":\"x\"}");
    defer res.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, res.ok, "false") != null);
}

test "pause parks durably at a role boundary; the substrate resumes to done" {
    var h = try Harness.init(testing.allocator, &.{ po_ok, plan2, exec_ok, exec_ok, verify_pass });
    defer h.deinit();
    const approvals = try approval_mod.ApprovalWorker.start(testing.allocator, &h.actor, &h.registry, .auto_approve);
    defer approvals.stop();
    h.provider.park_at = 2;
    const ctl_worker = try inproc.Worker.spawn(testing.allocator, &h.actor, &h.registry, "test-control");
    defer ctl_worker.stop();

    const req = try h.startReq(testing.allocator, seed_and_gate);
    defer testing.allocator.free(req);
    var ctx: StartCtx = .{ .h = h, .req = req };
    const t = try std.Thread.spawn(.{}, StartCtx.run, .{&ctx});

    h.provider.entered.wait();
    const pres = try ctl_worker.call("zygos::missions::pause", "{\"mission_id\":\"m-1\"}");
    defer pres.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, pres.ok, "true") != null);
    h.provider.release.set();
    t.join();
    defer ctx.res.deinit(testing.allocator);

    // Parked, not terminal: the in-flight executor turn finished, then the
    // boundary parked the run with the state persisted.
    try testing.expect(ctx.res == .ok);
    try testing.expect(std.mem.indexOf(u8, ctx.res.ok, "\"paused\":true") != null);
    try testing.expect(std.mem.indexOf(u8, ctx.res.ok, "\"state\":\"executing\"") != null);
    var parked = try h.store().load(testing.allocator);
    defer parked.deinit(testing.allocator);
    try testing.expectEqual(State.executing, parked.state);

    // The substrate already resumes: a resume start completes the mission.
    const rreq = try h.startReq(testing.allocator, seed_and_gate ++ ",\"resume\":true");
    defer testing.allocator.free(rreq);
    const rres = try h.caller.call("zygos::missions::start", rreq);
    defer rres.deinit(testing.allocator);
    try testing.expect(rres == .ok);
    try expectTerminal(rres.ok, "done", "completed");
}

test "budget ledger: terminal mission writes LEDGER.md with the scope rollup" {
    const exec_usage = "{\"stop_reason\":\"end_turn\",\"content\":[{\"type\":\"text\",\"text\":\"done\"}]," ++
        "\"usage\":{\"input_tokens\":100,\"output_tokens\":20}}";
    var h = try Harness.init(testing.allocator, &.{ po_ok, plan1, exec_usage, verify_pass });
    defer h.deinit();
    const approvals = try approval_mod.ApprovalWorker.start(testing.allocator, &h.actor, &h.registry, .auto_approve);
    defer approvals.stop();
    const budget_mod = @import("budget.zig");
    const budget = try budget_mod.BudgetWorker.start(testing.allocator, &h.actor, &h.registry);
    defer budget.stop();
    const conf = try h.caller.call("zygos::budget::configure", "{\"scope\":\"m-1\",\"max_tokens\":1000000}");
    conf.deinit(testing.allocator);

    const req = try h.startReq(testing.allocator, seed_and_gate ++ ",\"budget_scope\":\"m-1\"");
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::missions::start", req);
    defer res.deinit(testing.allocator);
    try expectTerminal(res.ok, "done", "completed");

    const text = try h.store().readArtifact(testing.allocator, "LEDGER.md");
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "used_tokens: 120") != null);
    try testing.expect(std.mem.indexOf(u8, text, "saved_bytes:") != null);
    try testing.expect(std.mem.indexOf(u8, text, "state: done (completed)") != null);
}

test "PO decision journal: gate denial, verify failure, and acceptance land in DECISIONS.md" {
    // verify fails once (replan), gate denies once (redo), then both pass.
    var h = try Harness.init(testing.allocator, &.{
        po_ok, plan1, exec_ok, verify_fail, // → replanning
        plan1, exec_ok, verify_pass, // → gating (denied)
        plan1, exec_ok, verify_pass, // → gating (approved)
    });
    defer h.deinit();
    const gate_worker = try FakeGate.start(testing.allocator, &h.actor, &h.registry, &.{
        "{\"approved\":false,\"reason\":\"brief contradiction: scope creep\"}",
        "{\"approved\":true}",
    });
    defer gate_worker.stop();

    const req = try h.startReq(
        testing.allocator,
        ",\"objective\":\"seed: gizmo\",\"gate_function\":\"test::gate::request\"",
    );
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::missions::start", req);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try expectTerminal(res.ok, "done", "completed");

    const text = try h.store().readArtifact(testing.allocator, "DECISIONS.md");
    defer testing.allocator.free(text);
    // Append-only audit trail, in order: replan → redo → accept.
    const replan = std.mem.indexOf(u8, text, "[replan] missing tests") orelse return error.Missing;
    const redo = std.mem.indexOf(u8, text, "[redo] brief contradiction: scope creep") orelse return error.Missing;
    const accept = std.mem.indexOf(u8, text, "[accept]") orelse return error.Missing;
    try testing.expect(replan < redo and redo < accept);
}

test "max_role_turns exhausts at a role boundary" {
    var h = try Harness.init(testing.allocator, &.{ po_ok, plan2, exec_ok });
    defer h.deinit();

    const req = try h.startReq(testing.allocator, seed_and_gate ++ ",\"max_role_turns\":2");
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::missions::start", req);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try expectTerminal(res.ok, "failed", "role_turns_exhausted");
    var p = try json.parseFromSlice(json.Value, testing.allocator, res.ok, .{});
    defer p.deinit();
    try testing.expectEqual(@as(i64, 2), p.value.object.get("role_turns").?.integer);
}

test "status reflects a live mission; unknown mission_id errors" {
    var h = try Harness.init(testing.allocator, &.{ po_ok, plan2, exec_ok, exec_ok, verify_pass });
    defer h.deinit();
    const approvals = try approval_mod.ApprovalWorker.start(testing.allocator, &h.actor, &h.registry, .auto_approve);
    defer approvals.stop();
    h.provider.park_at = 2; // park the first executor turn
    const ctl_worker = try inproc.Worker.spawn(testing.allocator, &h.actor, &h.registry, "test-control");
    defer ctl_worker.stop();

    const req = try h.startReq(testing.allocator, seed_and_gate);
    defer testing.allocator.free(req);
    var ctx: StartCtx = .{ .h = h, .req = req };
    const t = try std.Thread.spawn(.{}, StartCtx.run, .{&ctx});

    h.provider.entered.wait();
    const sres = try ctl_worker.call("zygos::missions::status", "{\"mission_id\":\"m-1\"}");
    defer sres.deinit(testing.allocator);
    try testing.expect(sres == .ok);
    var sp = try json.parseFromSlice(json.Value, testing.allocator, sres.ok, .{});
    defer sp.deinit();
    try testing.expectEqualStrings("executing", sp.value.object.get("state").?.string);
    try testing.expectEqual(@as(i64, 2), sp.value.object.get("role_turns").?.integer);

    h.provider.release.set();
    t.join();
    defer ctx.res.deinit(testing.allocator);
    try expectTerminal(ctx.res.ok, "done", "completed");

    // Finished missions are untracked; unknown ids error.
    const gone = try ctl_worker.call("zygos::missions::status", "{\"mission_id\":\"m-1\"}");
    defer gone.deinit(testing.allocator);
    try testing.expect(gone == .err);
    const abort_gone = try ctl_worker.call("zygos::missions::abort", "{\"mission_id\":\"nope\"}");
    defer abort_gone.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, abort_gone.ok, "false") != null);
}

test "resume mid-flight runs only the remaining roles" {
    var h = try Harness.init(testing.allocator, &.{ exec_ok, verify_pass });
    defer h.deinit();
    const approvals = try approval_mod.ApprovalWorker.start(testing.allocator, &h.actor, &h.registry, .auto_approve);
    defer approvals.stop();

    // Seed the substrate exactly as a killed mission would have left it:
    // executing, task 2 of 2 pending, three role turns spent.
    var tasks = [_]Task{
        .{ .desc = "build the gizmo", .done = true },
        .{ .desc = "test the gizmo", .done = false },
    };
    const seeded: Mission = .{
        .mission_id = "m-1",
        .state = .executing,
        .objective = "Ship the gizmo",
        .acceptance = "the gizmo ships",
        .tasks = &tasks,
        .task_index = 1,
        .role_turns_used = 3,
    };
    try h.store().save(testing.allocator, &seeded);
    try h.store().writeArtifact(testing.allocator, "MISSION.md", "# Mission\n\nShip the gizmo\n");
    try h.store().writeArtifact(testing.allocator, "PLAN.md", "# Plan\n\n- [x] build\n- [ ] test\n");

    const req = try h.startReq(
        testing.allocator,
        ",\"resume\":true,\"gate_function\":\"zygos::approvals::request\"",
    );
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::missions::start", req);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try expectTerminal(res.ok, "done", "completed");

    // Only executor + verifier ran: the earlier roles were not re-run.
    try testing.expectEqual(@as(usize, 2), h.provider.callCount());
    var p = try json.parseFromSlice(json.Value, testing.allocator, res.ok, .{});
    defer p.deinit();
    try testing.expectEqual(@as(i64, 5), p.value.object.get("role_turns").?.integer);
    try testing.expectEqual(@as(i64, 2), p.value.object.get("tasks_done").?.integer);
}

test "resume of a terminal mission replies without running any role turn" {
    var h = try Harness.init(testing.allocator, &.{});
    defer h.deinit();

    const seeded: Mission = .{
        .mission_id = "m-1",
        .state = .done,
        .stop = .completed,
        .objective = "Ship the gizmo",
        .role_turns_used = 7,
    };
    try h.store().save(testing.allocator, &seeded);

    const req = try h.startReq(testing.allocator, ",\"resume\":true");
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::missions::start", req);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try expectTerminal(res.ok, "done", "completed");
    try testing.expectEqual(@as(usize, 0), h.provider.callCount());
}

test "malformed start requests error without side effects" {
    var h = try Harness.init(testing.allocator, &.{});
    defer h.deinit();

    // No objective on a fresh mission.
    const no_obj = try h.startReq(testing.allocator, "");
    defer testing.allocator.free(no_obj);
    const r1 = try h.caller.call("zygos::missions::start", no_obj);
    defer r1.deinit(testing.allocator);
    try testing.expect(r1 == .err);

    // Relative planning root.
    const rel = try h.caller.call(
        "zygos::missions::start",
        "{\"mission_id\":\"m-1\",\"planning_root\":\"rel/path\",\"objective\":\"x\"," ++
            "\"provider_function\":\"zygos::provider::rec::messages\"}",
    );
    defer rel.deinit(testing.allocator);
    try testing.expect(rel == .err);

    // Neither provider_function nor router_function.
    const noprov = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"mission_id\":\"m-1\",\"planning_root\":{f},\"objective\":\"x\"}}",
        .{json.fmt(h.root, .{})},
    );
    defer testing.allocator.free(noprov);
    const r3 = try h.caller.call("zygos::missions::start", noprov);
    defer r3.deinit(testing.allocator);
    try testing.expect(r3 == .err);

    // Resume with no persisted state.
    const res_req = try h.startReq(testing.allocator, ",\"resume\":true");
    defer testing.allocator.free(res_req);
    const r4 = try h.caller.call("zygos::missions::start", res_req);
    defer r4.deinit(testing.allocator);
    try testing.expect(r4 == .err);
}

/// Records session_close calls on `test::continuity::close` (W3 seam).
const RecContinuity = struct {
    gpa: std.mem.Allocator,
    worker: *inproc.Worker,
    mutex: sync.Mutex = .{},
    calls: usize = 0,
    last_request: ?[]u8 = null,

    fn start(gpa: std.mem.Allocator, actor: *actor_mod.Actor, registry: *inproc.Registry) !*RecContinuity {
        const self = try gpa.create(RecContinuity);
        self.* = .{
            .gpa = gpa,
            .worker = try inproc.Worker.spawn(gpa, actor, registry, "rec-continuity"),
        };
        try self.worker.registerFunction("test::continuity::close", self, &handler);
        return self;
    }

    fn stop(self: *RecContinuity) void {
        self.worker.stop();
        if (self.last_request) |r| self.gpa.free(r);
        self.mutex.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    fn handler(ctx: ?*anyopaque, arena: std.mem.Allocator, request_json: []const u8) error{ Failed, OutOfMemory }![]const u8 {
        const self: *RecContinuity = @ptrCast(@alignCast(ctx.?));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.calls += 1;
        if (self.last_request) |r| self.gpa.free(r);
        self.last_request = try self.gpa.dupe(u8, request_json);
        return arena.dupe(u8, "{\"ok\":true}");
    }
};

test "continuity seam: terminal mission session-closes once with the phase log" {
    var h = try Harness.init(testing.allocator, &.{ po_ok, plan1, exec_ok, verify_pass });
    defer h.deinit();
    const approvals = try approval_mod.ApprovalWorker.start(testing.allocator, &h.actor, &h.registry, .auto_approve);
    defer approvals.stop();
    const cont = try RecContinuity.start(testing.allocator, &h.actor, &h.registry);
    defer cont.stop();

    const req = try h.startReq(testing.allocator, seed_and_gate ++
        ",\"continuity_function\":\"test::continuity::close\",\"continuity_project\":\"zygos\"");
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::missions::start", req);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try expectTerminal(res.ok, "done", "completed");

    cont.mutex.lock();
    defer cont.mutex.unlock();
    try testing.expectEqual(@as(usize, 1), cont.calls);
    var p = try json.parseFromSlice(json.Value, testing.allocator, cont.last_request.?, .{});
    defer p.deinit();
    const obj = p.value.object;
    try testing.expectEqualStrings("zygos", obj.get("project").?.string);
    // date "YYYY-MM-DD HH:MM"
    try testing.expectEqual(@as(usize, 16), obj.get("date").?.string.len);
    // leaving_behind never blank, names the terminal state
    try testing.expect(std.mem.indexOf(u8, obj.get("leaving_behind").?.string, "done") != null);
    try testing.expect(std.mem.indexOf(u8, obj.get("accomplished").?.string, "1/1") != null);
    // phase log covers first and last transitions, in order
    const log_arr = obj.get("log").?.array.items;
    try testing.expect(log_arr.len >= 2);
    try testing.expect(std.mem.indexOf(u8, log_arr[0].string, "defining") != null);
    try testing.expect(std.mem.indexOf(u8, log_arr[log_arr.len - 1].string, "done") != null);
    // no unfinished tasks => no open threads
    try testing.expectEqual(@as(usize, 0), obj.get("open_threads").?.array.items.len);
}

test "continuity seam: unreachable continuity function does not change the mission outcome" {
    var h = try Harness.init(testing.allocator, &.{ po_ok, plan1, exec_ok, verify_pass });
    defer h.deinit();
    const approvals = try approval_mod.ApprovalWorker.start(testing.allocator, &h.actor, &h.registry, .auto_approve);
    defer approvals.stop();

    const req = try h.startReq(testing.allocator, seed_and_gate ++
        ",\"continuity_function\":\"test::continuity::missing\",\"continuity_project\":\"zygos\"");
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::missions::start", req);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try expectTerminal(res.ok, "done", "completed");
}
