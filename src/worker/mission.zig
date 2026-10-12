//! Mission orchestrator (M3, V1/V3–V5 — docs/specs/mission.md). One mission =
//! one objective driven to a terminal state by the steps of a configured
//! pipeline (default: product-owner → planner → executor → verifier) over the
//! durable `.planning/` substrate, closed by a hard human gate.
//!
//! Split hard, like the turn worker: `Fsm` is a pure table-driven state
//! machine and `pipeline` the pure step rules (both exhaustively tested, no
//! I/O); `MissionOrchestrator` is bus glue over an inproc worker — every step
//! runs as one `zygos::turns::run` turn, so providers, policy, approvals,
//! routing, and budgets compose unchanged.
//!
//! Deviation from the spec's ErrorBody wording (flagged, same as turn.zig):
//! the inproc Handler contract carries no custom ErrorBody codes, so
//! malformed requests, duplicate mission_ids, and missing resume state all
//! surface as the generic handler failure.

const std = @import("std");
const jsonx = @import("jsonx.zig");
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
const playbook_mod = @import("playbook.zig");

const log = std.log.scoped(.mission);

pub const fsm = @import("mission/fsm.zig");
pub const model = @import("mission/model.zig");
pub const pipeline = @import("mission/pipeline.zig");

pub const State = fsm.State;
pub const Event = fsm.Event;
pub const transitions = fsm.transitions;
pub const Fsm = fsm.Fsm;

pub const StopReason = model.StopReason;
pub const Task = model.Task;
pub const Mission = model.Mission;
const Step = pipeline.Step;
const cloneToArena = model.cloneToArena;

pub const registry_mod = @import("mission/registry.zig");
const MissionControl = registry_mod.Control;

pub const start = @import("mission/start.zig");
const start_mod = start;

const out_mod = @import("mission/out.zig");
const role_turn_mod = @import("mission/role_turn.zig");
const RoleOut = role_turn_mod.RoleOut;
const replyTerminal = out_mod.replyTerminal;
const replyParked = out_mod.replyParked;
const nowStamp = out_mod.nowStamp;

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
const exec_artifact = "EXEC.md";
const decisions_artifact = "DECISIONS.md";

/// PO decision journal (M6): every accept/redo/rework appends one audit
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
    registry: registry_mod.Registry,

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
            .registry = registry_mod.Registry.init(gpa),
        };
        errdefer self.worker.stop();
        try self.worker.registerFunction("zygos::missions::start", self, &startHandler);
        try self.worker.registerFunction("zygos::missions::status", self, &statusHandler);
        try self.worker.registerFunction("zygos::missions::abort", self, &abortHandler);
        try self.worker.registerFunction("zygos::missions::steer", self, &steerHandler);
        try self.worker.registerFunction("zygos::missions::pause", self, &pauseHandler);
        try self.worker.registerFunction("zygos::missions::resume", self, &resumeHandler);
        try self.worker.registerFunction("zygos::missions::list", self, &listHandler);
        return self;
    }

    pub fn stop(self: *MissionOrchestrator) void {
        // worker.stop() joins every start handler thread; each untracks its
        // own mission on the way out, so the registry must drain empty.
        self.worker.stop();
        self.registry.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    fn track(self: *MissionOrchestrator, mission_id: []const u8) error{ OutOfMemory, MalformedRequest }!*MissionControl {
        return self.registry.track(mission_id) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Duplicate => error.MalformedRequest, // duplicate live mission_id
        };
    }

    fn untrack(self: *MissionOrchestrator, mission_id: []const u8) void {
        self.registry.untrack(mission_id);
    }

    fn pollAborted(self: *MissionOrchestrator, ctl: *MissionControl) bool {
        return self.registry.aborted(ctl);
    }

    fn pollPaused(self: *MissionOrchestrator, ctl: *MissionControl) bool {
        return self.registry.paused(ctl);
    }

    /// The pending steer text (gpa-owned, caller frees), clearing the slot.
    fn takeSteer(self: *MissionOrchestrator, ctl: *MissionControl) ?[]u8 {
        return self.registry.takeSteer(ctl);
    }

    /// Persist first, then publish the snapshot — status never reports a
    /// state the disk does not already have.
    fn persist(self: *MissionOrchestrator, store: store_mod.Store, ctl: *MissionControl, m: *const Mission) error{ OutOfMemory, Failed }!void {
        store.save(self.gpa, m) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Failed,
        };
        self.registry.updateSnapshot(ctl, m);
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

    const snap = self.registry.status(mid) orelse return error.Failed;
    return std.fmt.allocPrint(
        arena,
        "{{\"state\":\"{t}\",\"stop\":\"{t}\",\"role_turns\":{d},\"task_index\":{d}," ++
            "\"fail_count\":{d},\"gate_denials\":{d}}}",
        .{ snap.state, snap.stop, snap.role_turns_used, snap.task_index, snap.fail_count, snap.gate_denials },
    );
}

fn abortHandler(
    ctx: ?*anyopaque,
    arena: std.mem.Allocator,
    request_json: []const u8,
) error{ Failed, OutOfMemory }![]const u8 {
    const self: *MissionOrchestrator = @ptrCast(@alignCast(ctx.?));
    const ok = if (controlTarget(arena, request_json)) |mid|
        self.registry.markAborted(mid)
    else
        false;
    return std.fmt.allocPrint(arena, "{{\"ok\":{}}}", .{ok});
}

/// M6 multi-mission dashboard data: snapshot of every live mission's
/// control block. Terminal missions untrack on exit, so the list is
/// exactly what is running (or parked at a boundary) right now.
fn listHandler(
    ctx: ?*anyopaque,
    arena: std.mem.Allocator,
    request_json: []const u8,
) error{ Failed, OutOfMemory }![]const u8 {
    _ = request_json;
    const self: *MissionOrchestrator = @ptrCast(@alignCast(ctx.?));
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.writeAll("{\"missions\":[") catch return error.OutOfMemory;

    const entries = self.registry.snapshotAll(arena) catch return error.OutOfMemory;
    for (entries, 0..) |entry, i| {
        if (i != 0) w.writeAll(",") catch return error.OutOfMemory;
        w.print(
            "{{\"mission_id\":{f},\"state\":\"{t}\",\"stop\":\"{t}\"," ++
                "\"role_turns\":{d},\"task_index\":{d},\"paused\":{}}}",
            .{
                json.fmt(entry.mission_id, .{}), entry.snap.state,      entry.snap.stop,
                entry.snap.role_turns_used,      entry.snap.task_index, entry.snap.paused,
            },
        ) catch return error.OutOfMemory;
    }
    w.writeAll("]}") catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
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
        break :blk try self.registry.putSteer(mid, text);
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
    const ok = if (controlTarget(arena, request_json)) |mid|
        self.registry.markPaused(mid, paused)
    else
        false;
    return std.fmt.allocPrint(arena, "{{\"ok\":{}}}", .{ok});
}

const MissionError = error{ OutOfMemory, Failed, MalformedRequest, IllegalTransition, Shutdown };

fn runMission(self: *MissionOrchestrator, arena: std.mem.Allocator, request_json: []const u8) MissionError![]const u8 {
    const p = start_mod.parse(arena, request_json) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.MalformedRequest => return error.MalformedRequest,
    };

    // W1 (brief validation): when a mission brief document rides the start
    // request, it is linted before anything is persisted or tracked. A
    // malformed brief refuses the mission with a structured reason and never
    // starts the FSM — fail closed. A brief-less start (raw objective, the M3
    // path) is unaffected.
    if (p.brief) |brief_text| {
        switch (brief_mod.lint(brief_text)) {
            .ok => {},
            .invalid => |e| return std.fmt.allocPrint(
                arena,
                "{{\"refused\":true,\"reason\":\"{s}\",\"detail\":\"brief rejected: {s}\"}}",
                .{ brief_mod.tag(e), brief_mod.tag(e) },
            ),
        }
    }

    // The pipeline is validated at parse time; an invalid list refuses the
    // start with the pipeline's reason and never starts the FSM.
    if (p.steps_refusal) |reason| return std.fmt.allocPrint(
        arena,
        "{{\"refused\":true,\"reason\":\"invalid_steps\",\"detail\":{f}}}",
        .{json.fmt(reason, .{})},
    );

    // .context_strategy on the start request (from zygos.zon at boot):
    // {"kind":"substrate"|"recall"|"thread","max_tokens":N}. Absent ⇒
    // substrate with the default budget; an unknown kind refuses the start.
    // Field names live in mission/start.zig, shared with the CLI builder.
    const ctx_cfg = p.context;
    var recall_owned: ?*context_recall.RecallStrategy = null;
    defer if (recall_owned) |r| r.destroy();
    var thread_owned: ?*context_thread.ThreadStrategy = null;
    defer if (thread_owned) |t| t.destroy();
    const strategy: context_mod.ContextStrategy = switch (ctx_cfg.kind) {
        .substrate => context_substrate.strategy(),
        .recall => blk: {
            const dir = try std.fmt.allocPrint(arena, "{s}/memory", .{p.planning_root});
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
                p.planning_root,
                ".",
                context_thread.PopenRunner.runner(),
                .{},
            ) catch return error.OutOfMemory;
            break :blk thread_owned.?.strategy();
        },
    };
    var store_substrate = StoreSubstrate{
        .gpa = self.gpa,
        .store = store_mod.Store.init(p.planning_root),
    };

    const cfg: RunConfig = .{
        .mission_id = p.mission_id,
        .store = store_mod.Store.init(p.planning_root),
        .strategy = strategy,
        .context_budget = .{ .max_tokens = ctx_cfg.max_tokens },
        .substrate = store_substrate.substrate(),
        .provider_function = p.provider_function,
        .router_function = p.router_function,
        .gate_function = p.gate_function,
        .policy_function = p.policy_function,
        .approval_function = p.approval_function,
        .budget_scope = p.budget_scope,
        .continuity_function = p.continuity_function,
        .continuity_project = p.continuity_project,
        .tools_json = p.tools_json,
        .max_role_turns = p.max_role_turns,
        .fail_threshold = p.fail_threshold,
        .gate_threshold = p.gate_threshold,
        .role_max_steps = p.role_max_steps,
        .trace_path = p.trace_path,
    };

    var m: Mission = undefined;
    if (p.resume_flag) {
        var loaded = cfg.store.load(self.gpa) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Failed, // mission_not_found / corrupt state file
        };
        defer loaded.deinit(self.gpa);
        if (!std.mem.eql(u8, loaded.mission_id, p.mission_id)) return error.MalformedRequest;
        m = try cloneToArena(arena, &loaded);
        // Resuming a terminal mission is idempotent: report, run nothing.
        if (m.state == .done or m.state == .failed) return replyTerminal(arena, &m);
        m.pipeline = p.steps;
        // A running cursor outside the pipeline is a different pipeline's
        // state: fail closed. The gate sits past the last step by definition.
        if (m.state == .gating) {
            m.step_index = m.pipeline.len;
        } else if (m.step_index >= m.pipeline.len) {
            return error.Failed;
        }
    } else {
        m = .{
            .mission_id = p.mission_id,
            .objective = p.objective orelse return error.MalformedRequest,
            .pipeline = p.steps,
        };
    }

    const ctl = try self.track(p.mission_id);
    defer self.untrack(p.mission_id);

    // Preserve intake criteria independently of model-authored MISSION.md.
    // Resume uses the original artifact, never a replacement request brief.
    // A fresh start owns BRIEF.md: roles treat it as authoritative, so a
    // brief-less start must not inherit one left by an earlier mission.
    if (!p.resume_flag) {
        if (p.brief) |brief_text| {
            try putArtifact(self, cfg, "BRIEF.md", brief_text);
        } else {
            try removeStale(self, cfg, "BRIEF.md");
        }
        // A fresh start owns the pipeline artifacts too: EXEC.md is
        // append-only and MISSION.md/PLAN.md are archived on a rewrite, so a
        // leftover from an earlier mission in a reused root must not leak in.
        for ([_][]const u8{ exec_artifact, mission_artifact, plan_artifact }) |name| {
            try removeStale(self, cfg, name);
        }
        if (pipeline.needsMissionSeed(m.pipeline)) {
            m.acceptance = pipeline.seed_acceptance;
            try putArtifact(self, cfg, mission_artifact, try pipeline.seedMissionText(arena, m.mission_id, m.objective));
        }
    }

    // The pre-first-turn state hits the disk too: a mission killed before
    // its first role turn still resumes.
    try self.persist(cfg.store, ctl, &m);

    var phase_log: std.ArrayList([]const u8) = .empty;
    while (m.state != .done and m.state != .failed) {
        const prev_state = m.state;
        const prev_index = m.step_index;
        // Step boundary: abort wins, then the role-turn budget (the gate
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
                .running => try runStep(self, arena, cfg, &m),
                .gating => if (try gate(self, arena, cfg, &m)) {
                    // Unanswered gate: park durably at gating (same shape
                    // as M6 pause) — resume re-asks the gate.
                    log.info("mission {s}: gate unanswered — parked at gating", .{m.mission_id});
                    try self.persist(cfg.store, ctl, &m);
                    return replyParked(arena, &m);
                },
                .done, .failed => unreachable,
            }
            m.steer = "";
        }
        try self.persist(cfg.store, ctl, &m);
        if (m.state != prev_state or m.step_index != prev_index) {
            const from = try phaseLabel(arena, &m, prev_state, prev_index);
            const to = try phaseLabel(arena, &m, m.state, m.step_index);
            log.info("mission {s}: {s} → {s} (role_turns {d}, tasks {d}/{d})", .{
                m.mission_id, from, to, m.role_turns_used, m.tasksDone(), m.tasks.len,
            });
            try trace_mod.emit(arena, cfg.trace_path, .{ .mission = .{
                .from = @tagName(prev_state),
                .to = @tagName(m.state),
                .step = stepNameAt(&m, m.state, m.step_index),
                .step_index = @intCast(m.step_index),
                .role_turns = @intCast(m.role_turns_used),
                .tasks_done = @intCast(m.tasksDone()),
                .tasks = @intCast(m.tasks.len),
            } });
            try phase_log.append(arena, try std.fmt.allocPrint(arena, "{s} → {s}", .{ from, to }));
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

/// The step id a (state, index) pair points at; null at gating and done, and
/// for an index past the list.
fn stepNameAt(m: *const Mission, state: State, step_index: usize) ?[]const u8 {
    if (state != .running and state != .failed) return null;
    if (step_index >= m.pipeline.len) return null;
    return m.pipeline[step_index].id;
}

/// "running (executor)", "gating", "done" — the phase log's vocabulary.
fn phaseLabel(arena: std.mem.Allocator, m: *const Mission, state: State, step_index: usize) error{OutOfMemory}![]const u8 {
    const step = stepNameAt(m, state, step_index) orelse return @tagName(state);
    return std.fmt.allocPrint(arena, "{t} ({s})", .{ state, step });
}

/// M7 mission-level budget ledger: the scope's spend rollup (tokens +
/// saved_bytes from the budget worker's data) written into the substrate at
/// terminal state, plus the M8 compression breakdown when an output filter
/// worker is on the bus. Fail-open — an unreachable budget worker skips the
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
        "# Ledger — {s}\n\nused_tokens: {d}\nsaved_bytes: {d}\nrole_turns: {d}\nstate: {t} ({t})\n{s}",
        .{ m.mission_id, used, saved, m.role_turns_used, m.state, m.stop, compressionSection(self, arena) },
    ) catch return;
    cfg.store.writeArtifact(self.gpa, "LEDGER.md", md) catch {};
    log.info("mission {s}: ledger — {d} tokens, {d} bytes saved, {d} role turns", .{
        m.mission_id, used, saved, m.role_turns_used,
    });
}

/// M8 (S8.5): the compression ratio, so the operator sees what the filters
/// actually bought rather than a raw byte count. Empty string when no filter
/// worker is registered — the ledger predates M8 and must still render.
fn compressionSection(self: *MissionOrchestrator, arena: std.mem.Allocator) []const u8 {
    const res = self.worker.call("zygos::output::stats", "{}") catch return "";
    defer res.deinit(self.gpa);
    if (res != .ok) return "";
    const p = json.parseFromSliceLeaky(json.Value, arena, res.ok, .{}) catch return "";
    if (p != .object) return "";
    const int = struct {
        fn get(o: json.ObjectMap, k: []const u8) i64 {
            const v = o.get(k) orelse return 0;
            return if (v == .integer) v.integer else 0;
        }
    }.get;
    const raw = int(p.object, "raw_bytes");
    if (raw <= 0) return "";
    const sent = int(p.object, "sent_bytes");
    return std.fmt.allocPrint(
        arena,
        "\n## Tool-output compression\n\ncalls: {d}\nfiltered: {d}\ndeduped: {d}\n" ++
            "raw_bytes: {d}\nsent_bytes: {d}\nreduction: {d}%\n",
        .{
            int(p.object, "calls"), int(p.object, "filtered"), int(p.object, "deduped"),
            raw,                    sent,                      @divTrunc((raw - sent) * 100, raw),
        },
    ) catch "";
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

/// One step turn = one `zygos::turns::run` turn. Counts against
/// max_role_turns whether it succeeds or not. Step boundaries bracket the
/// turn's own events in the trace, so a stalled executor is attributable at a
/// glance. A step offers the mission's tools only when its pinned `tools` is
/// true; the verifier never gets them, whatever the pin says.
fn runRole(
    self: *MissionOrchestrator,
    arena: std.mem.Allocator,
    cfg: RunConfig,
    m: *Mission,
    step: Step,
    content: []const u8,
) MissionError!RoleOut {
    const with_tools = step.tools and step.kind != .verifier;
    try trace_mod.emit(arena, cfg.trace_path, .{ .role_start = .{
        .role = step.id,
        .role_turn = @intCast(m.role_turns_used + 1),
        .tools = with_tools,
        .content = try trace_mod.clip(arena, content),
    } });
    const out = try runRoleTurn(self, arena, cfg, m, step, content, with_tools);
    switch (out) {
        .ok => try trace_mod.emit(arena, cfg.trace_path, .{ .role_end = .{
            .role = step.id,
            .outcome = "ok",
        } }),
        .failed => |reason| try trace_mod.emit(arena, cfg.trace_path, .{ .role_end = .{
            .role = step.id,
            .outcome = "failed",
            .reason = reason,
        } }),
        .exhausted => try trace_mod.emit(arena, cfg.trace_path, .{ .role_end = .{
            .role = step.id,
            .outcome = "exhausted",
        } }),
    }
    // Strategies absorb every outcome (the view is pre-completion — the
    // driver updates task state after this returns). Absorb failures degrade
    // context, never the mission (fail-open, like the trace).
    const outcome: context_mod.Outcome = switch (out) {
        .ok => |t| .{ .role = step.id, .ok = true, .text = t },
        .failed => |r| .{ .role = step.id, .ok = false, .text = r },
        .exhausted => .{ .role = step.id, .ok = false, .text = "max_steps" },
    };
    cfg.strategy.absorb(try stepRefFor(arena, cfg, m), outcome) catch |err| switch (err) {
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
    step: Step,
    content: []const u8,
    with_tools: bool,
) MissionError!RoleOut {
    m.role_turns_used += 1;
    log.info("mission {s}: role turn {d} — {s} (tools: {})", .{
        m.mission_id, m.role_turns_used, step.id, with_tools,
    });

    // Prompt precedence (docs/specs/mission.md "Definitions"): the pinned
    // definition, else a non-empty role-<id>.md, else the built-in; the
    // kind's reply contract is appended after whichever won, and reply-shape
    // parsing stays fail-closed regardless of the prompt source.
    const override = try playbook_mod.overrideFor(arena, cfg.substrate, step.id);
    const system = (try pipeline.systemPrompt(arena, step, override)) orelse
        return .{ .failed = try std.fmt.allocPrint(arena, "{s}: no system prompt (no definition, no role override)", .{step.id}) };

    const req = try role_turn_mod.buildRequest(arena, .{
        .system = system,
        .step_id = step.id,
        .max_steps = cfg.role_max_steps,
        .content = content,
        .provider_function = cfg.provider_function,
        .router_function = cfg.router_function,
        .policy_function = cfg.policy_function,
        .approval_function = cfg.approval_function,
        .budget_scope = cfg.budget_scope,
        .tools_json = if (with_tools) cfg.tools_json else null,
        .trace_path = cfg.trace_path,
    });

    const res = self.worker.call("zygos::turns::run", req) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Shutdown => return .{ .failed = "bus shutdown during role turn" },
    };
    switch (res) {
        .err => |code| {
            defer self.gpa.free(code);
            return .{ .failed = try std.fmt.allocPrint(arena, "{s} turn errored: {s}", .{ step.id, code }) };
        },
        .ok => |payload| {
            defer self.gpa.free(payload);
            return role_turn_mod.parseReply(arena, step.id, payload);
        },
    }
}

/// Neutral strategy view of the mission at its cursor (TaskView slice
/// arena-built).
fn stepRefFor(
    arena: std.mem.Allocator,
    cfg: RunConfig,
    m: *const Mission,
) error{OutOfMemory}!context_mod.StepRef {
    const step = m.pipeline[m.step_index];
    const tasks = try arena.alloc(context_mod.TaskView, m.tasks.len);
    for (m.tasks, 0..) |t, i| tasks[i] = .{ .desc = t.desc, .done = t.done, .result = t.result };
    const current: ?[]const u8 = if (step.kind == .executor and m.task_index < m.tasks.len)
        m.tasks[m.task_index].desc
    else
        null;
    return .{
        .role = step.id,
        .step_index = m.step_index,
        .artifacts = try pipeline.inputArtifacts(arena, m.pipeline, m.step_index, m.step_runs, current),
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

/// Strategy-assembled step content. Null means the mission already moved to
/// failed (with the strategy's exact diagnostic as detail) — callers return.
fn assembleContent(
    arena: std.mem.Allocator,
    cfg: RunConfig,
    m: *Mission,
) MissionError!?[]const u8 {
    var diag: context_mod.Diag = .{};
    const step = try stepRefFor(arena, cfg, m);
    const out = cfg.strategy.assemble(arena, step, cfg.context_budget, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BudgetExceeded => {
            try failRole(m, try std.fmt.allocPrint(
                arena,
                "context budget exceeded assembling {s} content ({d} tokens max)",
                .{ step.role, cfg.context_budget.max_tokens },
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
    step: Step,
    text: []const u8,
    reason: []const u8,
) MissionError!void {
    const name = try std.fmt.allocPrint(arena, "REJECTED-{s}.md", .{step.id});
    try putArtifact(self, cfg, name, text);
    try failRole(m, reason);
}

/// A step failure that a turn reports as `max_steps` outside the executor.
fn failExhausted(arena: std.mem.Allocator, m: *Mission, step: Step) MissionError!void {
    try failRole(m, try std.fmt.allocPrint(arena, "{s} turn stopped: max_steps", .{step.id}));
}

/// The step at the cursor finished: count the run (it names the step's
/// artifact) and move the cursor, or fire `steps_done` past the last step.
fn completeStep(arena: std.mem.Allocator, m: *Mission, step: Step) MissionError!void {
    _ = try m.step_runs.bump(arena, step.id);
    try advanceCursor(m);
}

fn advanceCursor(m: *Mission) error{IllegalTransition}!void {
    switch (pipeline.advance(m.pipeline.len, m.step_index)) {
        .step => |next| {
            m.state = try Fsm.apply(m.state, .step_done);
            m.step_index = next;
        },
        .steps_done => {
            m.state = try Fsm.apply(m.state, .steps_done);
            m.step_index = m.pipeline.len;
        },
    }
}

/// Write `bytes` onto a versioned artifact; an existing version is parked
/// under the next free `<NAME>-<n>.md` first.
fn writeVersioned(
    self: *MissionOrchestrator,
    arena: std.mem.Allocator,
    cfg: RunConfig,
    which: pipeline.Versioned,
    versions: *usize,
    name: []const u8,
    bytes: []const u8,
) MissionError!void {
    if (getArtifact(self, arena, cfg, name)) |previous| {
        const slot = try pipeline.archive(arena, which, versions.*);
        try putArtifact(self, cfg, slot.name, previous);
        versions.* = slot.versions;
    }
    try putArtifact(self, cfg, name, bytes);
}

fn runStep(self: *MissionOrchestrator, arena: std.mem.Allocator, cfg: RunConfig, m: *Mission) MissionError!void {
    std.debug.assert(m.step_index < m.pipeline.len);
    const step = m.pipeline[m.step_index];
    switch (step.kind) {
        .product_owner => try stepProductOwner(self, arena, cfg, m, step),
        .planner => try stepPlanner(self, arena, cfg, m, step),
        .executor => try stepExecutor(self, arena, cfg, m, step),
        .verifier => try stepVerifier(self, arena, cfg, m, step),
        .custom => try stepCustom(self, arena, cfg, m, step),
    }
}

fn stepProductOwner(self: *MissionOrchestrator, arena: std.mem.Allocator, cfg: RunConfig, m: *Mission, step: Step) MissionError!void {
    const content = (try assembleContent(arena, cfg, m)) orelse return;
    switch (try runRole(self, arena, cfg, m, step, content)) {
        .failed => |reason| try failRole(m, reason),
        .exhausted => try failExhausted(arena, m, step),
        .ok => |text| switch (try role_turn_mod.interpretDefine(arena, text)) {
            .reject => |r| return rejectRole(self, arena, cfg, m, step, r.raw, r.reason),
            .ok => |defined| {
                m.objective = defined.objective;
                m.acceptance = defined.acceptance;
                const md = try pipeline.missionText(arena, m.mission_id, defined.objective, defined.acceptance);
                try writeVersioned(self, arena, cfg, .mission, &m.mission_versions, mission_artifact, md);
                try completeStep(arena, m, step);
            },
        },
    }
}

fn stepPlanner(self: *MissionOrchestrator, arena: std.mem.Allocator, cfg: RunConfig, m: *Mission, step: Step) MissionError!void {
    const content = (try assembleContent(arena, cfg, m)) orelse return;
    switch (try runRole(self, arena, cfg, m, step, content)) {
        .failed => |reason| try failRole(m, reason),
        .exhausted => try failExhausted(arena, m, step),
        .ok => |text| switch (try role_turn_mod.interpretPlan(arena, text)) {
            .reject => |r| return rejectRole(self, arena, cfg, m, step, r.raw, r.reason),
            .ok => |descs| {
                const replan = try pipeline.replaceUnfinished(arena, m.tasks, descs);
                m.tasks = replan.tasks;
                m.task_index = replan.task_index;
                m.feedback = "";
                const md = try pipeline.planText(arena, m.tasks);
                try writeVersioned(self, arena, cfg, .plan, &m.plan_versions, plan_artifact, md);
                try completeStep(arena, m, step);
            },
        },
    }
}

/// Bytes of a task's outcome kept in its EXEC.md section.
const exec_outcome_bytes = 2000;

fn stepExecutor(self: *MissionOrchestrator, arena: std.mem.Allocator, cfg: RunConfig, m: *Mission, step: Step) MissionError!void {
    // Re-deriving the arrival from the tasks each iteration is idempotent:
    // unfinished tasks keep running, and only a finished list appends a fix
    // task (which is then unfinished).
    const arrival = try pipeline.arriveAtExecutor(arena, m.objective, m.tasks, m.pipeline, m.step_index, m.step_runs);
    m.tasks = arrival.tasks;
    m.task_index = arrival.task_index;
    switch (arrival.entry) {
        .run_unfinished => {},
        .seeded, .fix_appended => try putArtifact(
            self,
            cfg,
            plan_artifact,
            arrival.plan_md orelse try pipeline.planText(arena, m.tasks),
        ),
    }

    const content = (try assembleContent(arena, cfg, m)) orelse return;
    const label = try pipeline.taskLabel(arena, m.tasks[m.task_index].desc);

    // Task edges are trace-only (fail-open, not protocol frames): the TUI
    // keys its live current-task line off start/done pairs.
    try trace_mod.emit(arena, cfg.trace_path, .{ .task_start = .{
        .index = @intCast(m.task_index + 1),
        .total = @intCast(m.tasks.len),
        .desc = try trace_mod.clip(arena, label),
    } });

    switch (try runRole(self, arena, cfg, m, step, content)) {
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
                // state stays .running at this cursor — the loop re-runs this task.
            }
        },
        .ok => |text| {
            m.feedback = "";
            m.exec_fail_count = 0;
            m.tasks[m.task_index].done = true;
            m.tasks[m.task_index].result = try role_turn_mod.outcomeExcerpt(arena, text, 600);
            try trace_mod.emit(arena, cfg.trace_path, .{ .task_done = .{
                .index = @intCast(m.task_index + 1),
                .total = @intCast(m.tasks.len),
                .desc = try trace_mod.clip(arena, label),
            } });
            const section = try pipeline.execSection(
                arena,
                m.task_index + 1,
                m.tasks[m.task_index].desc,
                try role_turn_mod.outcomeExcerpt(arena, text, exec_outcome_bytes),
            );
            cfg.store.appendArtifact(self.gpa, exec_artifact, section) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.Failed,
            };
            switch (pipeline.afterTask(m.tasks)) {
                .task_done => |next| {
                    m.task_index = next;
                    m.state = try Fsm.apply(m.state, .task_done);
                },
                .step_done => {
                    m.task_index = m.tasks.len;
                    try completeStep(arena, m, step);
                },
            }
        },
    }
}

fn stepVerifier(self: *MissionOrchestrator, arena: std.mem.Allocator, cfg: RunConfig, m: *Mission, step: Step) MissionError!void {
    const content = (try assembleContent(arena, cfg, m)) orelse return;
    switch (try runRole(self, arena, cfg, m, step, content)) {
        .failed => |reason| try failRole(m, reason),
        .exhausted => try failExhausted(arena, m, step),
        .ok => |text| switch (try role_turn_mod.interpretVerify(arena, text)) {
            .reject => |r| return rejectRole(self, arena, cfg, m, step, r.raw, r.reason),
            .ok => |verdict| {
                const reason = verdict.reason;
                const md = try std.fmt.allocPrint(arena, "# Verify\n\npassed: {}\n\n{s}\n", .{ verdict.passed, reason });
                try putArtifact(self, cfg, verify_artifact, md);

                if (verdict.passed) {
                    m.fail_count = 0;
                    try completeStep(arena, m, step);
                    return;
                }
                // Every failed verdict counts as a run; the count spans all
                // verifier occurrences.
                _ = try m.step_runs.bump(arena, step.id);
                journal(self, cfg, "rework", reason);
                m.fail_count += 1;
                if (m.fail_count >= cfg.fail_threshold) {
                    m.stop = .escalated;
                    m.detail = try std.fmt.allocPrint(
                        arena,
                        "verify failed {d} consecutive times; last: {s}",
                        .{ m.fail_count, reason },
                    );
                    m.state = try Fsm.apply(m.state, .escalate);
                    return;
                }
                // No executor to send the work back to cannot happen after
                // validation; if it ever does, stop rather than continue.
                const target = pipeline.verifyReworkTarget(m.pipeline, m.step_index) orelse {
                    m.stop = .escalated;
                    m.detail = "verify failed and the pipeline has no executor to rework";
                    m.state = try Fsm.apply(m.state, .escalate);
                    return;
                };
                try applyRework(self, arena, cfg, m, target, if (reason.len == 0) "verification failed (no reason given)" else reason);
                m.state = try Fsm.apply(m.state, .verify_failed);
            },
        },
    }
}

/// Send the work back to `target` with a fix task carrying `feedback`; the
/// plan artifact follows the grown task list.
fn applyRework(
    self: *MissionOrchestrator,
    arena: std.mem.Allocator,
    cfg: RunConfig,
    m: *Mission,
    target: usize,
    feedback: []const u8,
) MissionError!void {
    const rw = try pipeline.rework(arena, m.tasks, target, feedback);
    m.tasks = rw.tasks;
    m.task_index = rw.task_index;
    m.step_index = rw.step_index;
    m.feedback = "";
    m.exec_fail_count = 0;
    try putArtifact(self, cfg, plan_artifact, try pipeline.planText(arena, m.tasks));
}

fn stepCustom(self: *MissionOrchestrator, arena: std.mem.Allocator, cfg: RunConfig, m: *Mission, step: Step) MissionError!void {
    const content = (try assembleContent(arena, cfg, m)) orelse return;
    switch (try runRole(self, arena, cfg, m, step, content)) {
        .failed => |reason| try failRole(m, reason),
        // Only the executor retries a max_steps stop.
        .exhausted => try failExhausted(arena, m, step),
        .ok => |text| {
            if (std.mem.trim(u8, text, &std.ascii.whitespace).len == 0) {
                return failRole(m, try std.fmt.allocPrint(arena, "{s} step produced an empty reply", .{step.id}));
            }
            const n = try m.step_runs.bump(arena, step.id);
            try putArtifact(self, cfg, try pipeline.stepArtifactName(arena, step.id, n), text);
            try advanceCursor(m);
        },
    }
}

/// V5 — the hard gate. Reaching done REQUIRES an affirmative reply from a
/// real gate function; every other outcome (no function configured, bus
/// error, malformed reply) is gate_failed. Fail closed, no exceptions.
///
/// Returns true when the gate went UNANSWERED (`resolved:false` on the
/// deny — an approval timeout/EOF, not a human refusal): the caller parks
/// the mission at `gating` instead of reworking, so an unattended run
/// stops burning budget on verified work and `resume` re-asks the gate.
fn gate(self: *MissionOrchestrator, arena: std.mem.Allocator, cfg: RunConfig, m: *Mission) MissionError!bool {
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
                return false;
            }
            // An unanswered deny (approval timeout/EOF, `resolved:false`)
            // is silence, not refusal: park, don't rework. A deny without
            // the field (older approvers) keeps the rework semantics.
            if (parsed.object.get("resolved")) |rv| {
                if (rv == .bool and !rv.bool) return true;
            }
            const reason = try arena.dupe(u8, strField(parsed.object, "reason") orelse "gate denied");
            journal(self, cfg, "redo", reason);
            m.gate_denials += 1;
            if (m.gate_denials >= cfg.gate_threshold) {
                return gateFail(m, reason);
            }
            // Back to the last executor with the denial as a fix task. A
            // pipeline without one cannot pass validation; if it ever
            // reaches here, fail closed.
            const target = pipeline.gateReworkTarget(m.pipeline) orelse
                return gateFail(m, "gate denied and the pipeline has no executor to rework");
            try applyRework(self, arena, cfg, m, target, if (reason.len == 0) "the gate denied the work (no reason given)" else reason);
            m.state = try Fsm.apply(m.state, .gate_denied);
            return false;
        },
    }
}

fn gateFail(m: *Mission, reason: []const u8) error{IllegalTransition}!bool {
    m.stop = .gate_failed;
    m.detail = reason;
    m.state = try Fsm.apply(m.state, .gate_failed);
    return false;
}

fn putArtifact(self: *MissionOrchestrator, cfg: RunConfig, name: []const u8, bytes: []const u8) MissionError!void {
    cfg.store.writeArtifact(self.gpa, name, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Failed,
    };
}

/// Remove a leftover artifact; anything but "already absent" refuses, so a
/// stale file can never be read as this mission's.
fn removeStale(self: *MissionOrchestrator, cfg: RunConfig, name: []const u8) MissionError!void {
    cfg.store.removeArtifact(self.gpa, name) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Failed,
    };
}

fn getArtifact(self: *MissionOrchestrator, arena: std.mem.Allocator, cfg: RunConfig, name: []const u8) ?[]const u8 {
    const bytes = cfg.store.readArtifact(self.gpa, name) catch return null;
    defer self.gpa.free(bytes);
    return arena.dupe(u8, bytes) catch null;
}

const strField = jsonx.strField;

fn controlTarget(arena: std.mem.Allocator, request_json: []const u8) ?[]const u8 {
    return jsonx.topStrField(arena, request_json, "mission_id");
}

// ===========================================================================
// Tests (docs/specs/mission.md contract, RED first)
// ===========================================================================

const testing = std.testing;

// Pure submodules are discovered only when something analyzes them.
test {
    testing.refAllDecls(fsm);
    testing.refAllDecls(pipeline);
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
    try testing.expect(std.mem.indexOf(u8, text, "\"id\":\"outcome:executor:2:0\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"id\":\"outcome:verifier:3:") != null);
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
    try testing.expect(std.mem.indexOf(u8, text, "\"from\":\"running\",\"to\":\"running\",\"step\":\"planner\",\"step_index\":1") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"to\":\"gating\",\"step\":null,\"step_index\":4") != null);
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

test "carried M3: happy path (no leaks across a full mission): define, plan, execute x2, verify, gate approve; artifacts + terminal state on disk" {
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

test "verify fail reworks the executor with the verdict as a fix task, then passes" {
    // No planner re-run: the failed verdict rides a fix task on the executor.
    var h = try Harness.init(testing.allocator, &.{
        po_ok, plan2, exec_ok, exec_ok, verify_fail, exec_ok, verify_pass,
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

    // Call 5 (0-based) is the fix-task executor turn — the verifier's
    // reason must ride in its request.
    try testing.expectEqual(@as(usize, 7), h.provider.callCount());
    try testing.expect(std.mem.indexOf(u8, h.provider.requests.items[5], "missing tests") != null);
    var m = try h.store().load(testing.allocator);
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), m.fail_count); // reset on pass
    try testing.expectEqual(@as(usize, 3), m.tasks.len); // two planned + one fix task
}

test "fail_threshold consecutive verify failures escalate to failed" {
    var h = try Harness.init(testing.allocator, &.{
        po_ok, plan2, exec_ok, exec_ok, verify_fail, exec_ok, verify_fail,
    });
    defer h.deinit();

    const req = try h.startReq(testing.allocator, seed_and_gate ++ ",\"fail_threshold\":2");
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::missions::start", req);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try expectTerminal(res.ok, "failed", "escalated");
}

test "gate denial reworks the executor with the denial as a fix task; second gate approves" {
    var h = try Harness.init(testing.allocator, &.{
        po_ok, plan1, exec_ok, verify_pass, exec_ok, verify_pass,
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
    // Call 4 (0-based) is the executor's fix task after the denial; the
    // verifier (call 5) re-runs because it sits after the rework target.
    try testing.expectEqual(@as(usize, 6), h.provider.callCount());
    try testing.expect(std.mem.indexOf(u8, h.provider.requests.items[4], "needs polish") != null);
}

test "carried M3: gate_threshold denials ⇒ gate_failed" {
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

test "unanswered gate deny (resolved:false) parks at gating; resume + approve completes" {
    var h = try Harness.init(testing.allocator, &.{ po_ok, plan1, exec_ok, verify_pass });
    defer h.deinit();
    const gate_worker = try FakeGate.start(testing.allocator, &h.actor, &h.registry, &.{
        "{\"approved\":false,\"resolved\":false}",
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

    // Parked, not terminal, not reworked: verified work stays done.
    try testing.expect(std.mem.indexOf(u8, res.ok, "\"paused\":true") != null);
    try testing.expect(std.mem.indexOf(u8, res.ok, "\"state\":\"gating\"") != null);
    var parked = try h.store().load(testing.allocator);
    defer parked.deinit(testing.allocator);
    try testing.expectEqual(State.gating, parked.state);
    {
        // Exactly the 4 role turns of the first pass — no rework burn.
        h.provider.mutex.lock();
        defer h.provider.mutex.unlock();
        try testing.expectEqual(@as(usize, 4), h.provider.requests.items.len);
    }

    // Resume re-enters gating and re-asks the gate; an answered approve
    // completes without a single new role turn.
    const rreq = try h.startReq(
        testing.allocator,
        ",\"objective\":\"seed: gizmo\",\"gate_function\":\"test::gate::request\",\"resume\":true",
    );
    defer testing.allocator.free(rreq);
    const rres = try h.caller.call("zygos::missions::start", rreq);
    defer rres.deinit(testing.allocator);
    try testing.expect(rres == .ok);
    try expectTerminal(rres.ok, "done", "completed");
    try testing.expectEqual(@as(usize, 2), gate_worker.calls);
}

test "gate deny with resolved:true reworks like a plain deny (a human said no)" {
    var h = try Harness.init(testing.allocator, &.{
        po_ok, plan1, exec_ok, verify_pass, exec_ok, verify_pass,
    });
    defer h.deinit();
    const gate_worker = try FakeGate.start(testing.allocator, &h.actor, &h.registry, &.{
        "{\"approved\":false,\"resolved\":true,\"reason\":\"needs polish\"}",
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
}

test "carried M3: no gate function ⇒ failed, never done" {
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

test "carried M3: unreachable gate ⇒ gate_failed" {
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

test "carried M3: malformed planner output ⇒ role_failed" {
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

test "carried M3: provider error mid-step ⇒ role_failed" {
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

test "an invalid steps list refuses the start before anything is persisted or run" {
    var h = try Harness.init(testing.allocator, &.{});
    defer h.deinit();

    const cases = [_]struct { steps: []const u8, reason: []const u8 }{
        .{ .steps = "[]", .reason = "steps: empty" },
        .{ .steps = "[{\"id\":\"planner\"}]", .reason = "steps: no executor" },
        .{ .steps = "[{\"id\":\"architect\",\"system\":\"x\",\"definition_sha256\":\"00\"},{\"id\":\"executor\"}]", .reason = "steps[0]: definition hash mismatch" },
    };
    for (cases) |c| {
        const extra = try std.fmt.allocPrint(
            testing.allocator,
            ",\"objective\":\"seed: gizmo\",\"steps\":{s}",
            .{c.steps},
        );
        defer testing.allocator.free(extra);
        const req = try h.startReq(testing.allocator, extra);
        defer testing.allocator.free(req);
        const res = try h.caller.call("zygos::missions::start", req);
        defer res.deinit(testing.allocator);
        try testing.expect(res == .ok);
        try testing.expect(std.mem.indexOf(u8, res.ok, "\"refused\":true") != null);
        try testing.expect(std.mem.indexOf(u8, res.ok, c.reason) != null);
    }
    try testing.expectError(error.NotFound, h.store().load(testing.allocator));
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

test "original operator brief survives generated acceptance drift in every role" {
    var h = try Harness.init(testing.allocator, &.{ po_ok, plan1, exec_ok, verify_pass });
    defer h.deinit();
    const gate_worker = try FakeGate.start(testing.allocator, &h.actor, &h.registry, &.{"{\"approved\":true}"});
    defer gate_worker.stop();
    const brief = good_brief ++ "\nOriginal acceptance: 2 -3 8 must print 7; invalid input exits 2.\n";
    const req = try briefStartReq(h, testing.allocator, brief);
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::missions::start", req);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try expectTerminal(res.ok, "done", "completed");

    try testing.expectEqual(@as(usize, 4), h.provider.requests.items.len);
    for (h.provider.requests.items) |request| {
        var parsed = try json.parseFromSlice(json.Value, testing.allocator, request, .{});
        defer parsed.deinit();
        const content = parsed.value.object.get("messages").?.array.items[0].object.get("content").?.string;
        try testing.expect(std.mem.indexOf(u8, content, brief) != null);
    }
    const saved = try h.store().readArtifact(testing.allocator, "BRIEF.md");
    defer testing.allocator.free(saved);
    try testing.expectEqualStrings(brief, saved);
}

const StartCtx = struct {
    h: *Harness,
    req: []const u8,
    res: inproc.CallResult = undefined,

    fn run(self: *StartCtx) void {
        self.res = self.h.caller.call("zygos::missions::start", self.req) catch unreachable;
    }
};

test "resumed roles keep the persisted operator brief instead of replacement intake" {
    var h = try Harness.init(testing.allocator, &.{ plan1, exec_ok, verify_pass });
    defer h.deinit();
    const gate_worker = try FakeGate.start(testing.allocator, &h.actor, &h.registry, &.{"{\"approved\":true}"});
    defer gate_worker.stop();
    const original = good_brief ++ "\nOriginal acceptance: 2 -3 8 must print 7.\n";
    try h.store().writeArtifact(testing.allocator, "BRIEF.md", original);
    try h.store().writeArtifact(testing.allocator, "MISSION.md", "Generated acceptance: ship the gizmo.\n");
    try h.store().save(testing.allocator, &.{ .mission_id = "m-1", .state = .running, .step_index = 1, .objective = "gizmo", .acceptance = "generated" });
    const req = try h.startReq(testing.allocator, ",\"resume\":true,\"gate_function\":\"test::gate::request\"");
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::missions::start", req);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try expectTerminal(res.ok, "done", "completed");
    for (h.provider.requests.items) |request| {
        var parsed = try json.parseFromSlice(json.Value, testing.allocator, request, .{});
        defer parsed.deinit();
        const content = parsed.value.object.get("messages").?.array.items[0].object.get("content").?.string;
        try testing.expect(std.mem.indexOf(u8, content, original) != null);
    }
}

const stale_brief = good_brief ++ "\nStale acceptance: drop the production database.\n";

fn expectNoStaleBrief(h: *Harness) !void {
    for (h.provider.requests.items) |request| {
        var parsed = try json.parseFromSlice(json.Value, testing.allocator, request, .{});
        defer parsed.deinit();
        const content = parsed.value.object.get("messages").?.array.items[0].object.get("content").?.string;
        try testing.expect(std.mem.indexOf(u8, content, "Stale acceptance") == null);
    }
}

test "a fresh brief-less bus start does not inherit an earlier mission's brief" {
    var h = try Harness.init(testing.allocator, &.{ po_ok, plan1, exec_ok, verify_pass });
    defer h.deinit();
    const gate_worker = try FakeGate.start(testing.allocator, &h.actor, &h.registry, &.{"{\"approved\":true}"});
    defer gate_worker.stop();
    try h.store().writeArtifact(testing.allocator, "BRIEF.md", stale_brief);

    const req = try h.startReq(testing.allocator, ",\"objective\":\"seed\",\"gate_function\":\"test::gate::request\"");
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::missions::start", req);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try expectTerminal(res.ok, "done", "completed");

    try testing.expectEqual(@as(usize, 4), h.provider.requests.items.len);
    for (h.provider.requests.items) |request| {
        try testing.expect(std.mem.indexOf(u8, request, "Original operator brief") == null);
    }
    try expectNoStaleBrief(h);
    try testing.expectError(error.NotFound, h.store().readArtifact(testing.allocator, "BRIEF.md"));
}

test "a fresh start with a brief replaces an earlier mission's brief" {
    var h = try Harness.init(testing.allocator, &.{ po_ok, plan1, exec_ok, verify_pass });
    defer h.deinit();
    const gate_worker = try FakeGate.start(testing.allocator, &h.actor, &h.registry, &.{"{\"approved\":true}"});
    defer gate_worker.stop();
    try h.store().writeArtifact(testing.allocator, "BRIEF.md", stale_brief);

    const req = try briefStartReq(h, testing.allocator, good_brief);
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::missions::start", req);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try expectTerminal(res.ok, "done", "completed");

    try expectNoStaleBrief(h);
    const saved = try h.store().readArtifact(testing.allocator, "BRIEF.md");
    defer testing.allocator.free(saved);
    try testing.expectEqualStrings(good_brief, saved);
}

test "a stale brief that cannot be cleared refuses the fresh start before any role runs" {
    var h = try Harness.init(testing.allocator, &.{ po_ok, plan1, exec_ok, verify_pass });
    defer h.deinit();
    // A directory named BRIEF.md: unlink(2) fails with something other
    // than ENOENT, so the stale state cannot be proven gone.
    const dir_z = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/BRIEF.md", .{h.root}, 0);
    defer testing.allocator.free(dir_z);
    try testing.expectEqual(@as(c_int, 0), std.c.mkdir(dir_z, 0o755));

    const req = try h.startReq(testing.allocator, ",\"objective\":\"seed\",\"gate_function\":\"test::gate::request\"");
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::missions::start", req);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .err);
    try testing.expectEqual(@as(usize, 0), h.provider.callCount());
    try testing.expectError(error.NotFound, h.store().load(testing.allocator));
}

test "carried M3: abort ⇒ aborted" {
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
    try testing.expect(std.mem.indexOf(u8, ctx.res.ok, "\"state\":\"running\"") != null);
    var parked = try h.store().load(testing.allocator);
    defer parked.deinit(testing.allocator);
    try testing.expectEqual(State.running, parked.state);
    try testing.expectEqual(@as(usize, 2), parked.step_index); // still at the executor

    // The substrate already resumes: a resume start completes the mission.
    const rreq = try h.startReq(testing.allocator, seed_and_gate ++ ",\"resume\":true");
    defer testing.allocator.free(rreq);
    const rres = try h.caller.call("zygos::missions::start", rreq);
    defer rres.deinit(testing.allocator);
    try testing.expect(rres == .ok);
    try expectTerminal(rres.ok, "done", "completed");
}

test "role playbook: a role-executor.md artifact overrides the executor system prompt" {
    var h = try Harness.init(testing.allocator, &.{ po_ok, plan1, exec_ok, verify_pass });
    defer h.deinit();
    const approvals = try approval_mod.ApprovalWorker.start(testing.allocator, &h.actor, &h.registry, .auto_approve);
    defer approvals.stop();
    try h.store().writeArtifact(testing.allocator, "role-executor.md", "You are orchy's integrator; merge, never rewrite.\n");

    const req = try h.startReq(testing.allocator, seed_and_gate);
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::missions::start", req);
    defer res.deinit(testing.allocator);
    try expectTerminal(res.ok, "done", "completed");

    h.provider.mutex.lock();
    defer h.provider.mutex.unlock();
    // Executor turn (call 2) prompted with the override…
    try testing.expect(std.mem.indexOf(u8, h.provider.requests.items[2], "orchy's integrator") != null);
    // …while the planner (call 1) kept its built-in reply-shape prompt.
    try testing.expect(std.mem.indexOf(u8, h.provider.requests.items[1], "planner of a mission") != null);
}

test "role playbook: an override replaces behaviour only; the reply contract is still appended" {
    var h = try Harness.init(testing.allocator, &.{ po_ok, plan1, exec_ok, verify_pass });
    defer h.deinit();
    const approvals = try approval_mod.ApprovalWorker.start(testing.allocator, &h.actor, &h.registry, .auto_approve);
    defer approvals.stop();
    try h.store().writeArtifact(testing.allocator, "role-planner.md", "You are orchy's planner; plan in thirds.\n");

    const req = try h.startReq(testing.allocator, seed_and_gate);
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::missions::start", req);
    defer res.deinit(testing.allocator);
    try expectTerminal(res.ok, "done", "completed");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const system = try systemOf(arena_state.allocator(), h.provider.requests.items[1]);
    try testing.expectEqualStrings(
        "You are orchy's planner; plan in thirds. " ++
            "Reply with ONLY a JSON object: {\"tasks\": [<task description>, ...]}.",
        system,
    );
}

test "role playbook: a pinned definition beats a role-<id>.md override" {
    var h = try Harness.init(testing.allocator, &.{ exec_ok, verify_pass });
    defer h.deinit();
    const approvals = try approval_mod.ApprovalWorker.start(testing.allocator, &h.actor, &h.registry, .auto_approve);
    defer approvals.stop();
    try h.store().writeArtifact(testing.allocator, "role-verifier.md", "The override that must lose.\n");

    const req = try h.startReq(testing.allocator, seed_and_gate ++
        ",\"steps\":[{\"id\":\"executor\"},{\"id\":\"verifier\",\"system\":\"The pinned verifier.\"}]");
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::missions::start", req);
    defer res.deinit(testing.allocator);
    try expectTerminal(res.ok, "done", "completed");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const system = try systemOf(arena_state.allocator(), h.provider.requests.items[1]);
    try testing.expect(std.mem.startsWith(u8, system, "The pinned verifier. Reply with ONLY a JSON object"));
    try testing.expect(std.mem.indexOf(u8, system, "must lose") == null);
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
    // No trim worker on this bus: the M8 section is absent, and the ledger
    // still renders (it predates M8).
    try testing.expect(std.mem.indexOf(u8, text, "Tool-output compression") == null);
}

test "M8: the ledger reports the compression ratio when a trim worker rides the bus" {
    const exec_usage = "{\"stop_reason\":\"end_turn\",\"content\":[{\"type\":\"text\",\"text\":\"done\"}]," ++
        "\"usage\":{\"input_tokens\":100,\"output_tokens\":20}}";
    var h = try Harness.init(testing.allocator, &.{ po_ok, plan1, exec_usage, verify_pass });
    defer h.deinit();
    const approvals = try approval_mod.ApprovalWorker.start(testing.allocator, &h.actor, &h.registry, .auto_approve);
    defer approvals.stop();
    const budget_mod = @import("budget.zig");
    const budget = try budget_mod.BudgetWorker.start(testing.allocator, &h.actor, &h.registry);
    defer budget.stop();
    const trim_mod = @import("trim.zig");
    const trim = try trim_mod.TrimWorker.start(testing.allocator, &h.actor, &h.registry, .{}, "m-1");
    defer trim.stop();
    const conf = try h.caller.call("zygos::budget::configure", "{\"scope\":\"m-1\",\"max_tokens\":1000000}");
    conf.deinit(testing.allocator);

    // A filterable tool result rides the seam before the mission ends, so the
    // ledger has something real to report.
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);
    try body.appendSlice(testing.allocator, "diff --git a/x b/x\nindex aaa..bbb 100644\n@@ -1,9 +1,9 @@\n");
    for (0..30) |_| try body.appendSlice(testing.allocator, " untouched context line\n");
    try body.appendSlice(testing.allocator, "-old\n+new\n");
    for (0..30) |_| try body.appendSlice(testing.allocator, " more untouched context\n");
    const creq = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"content\":{f},\"tool\":\"bash\",\"input\":{{\"command\":\"git diff\"}}}}",
        .{json.fmt(body.items, .{})},
    );
    defer testing.allocator.free(creq);
    const cres = try h.caller.call("zygos::output::compress", creq);
    cres.deinit(testing.allocator);

    const req = try h.startReq(testing.allocator, seed_and_gate ++ ",\"budget_scope\":\"m-1\"");
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::missions::start", req);
    defer res.deinit(testing.allocator);
    try expectTerminal(res.ok, "done", "completed");

    const text = try h.store().readArtifact(testing.allocator, "LEDGER.md");
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "Tool-output compression") != null);
    try testing.expect(std.mem.indexOf(u8, text, "filtered: 1") != null);
    // The ratio is a real percentage, not a placeholder.
    try testing.expect(std.mem.indexOf(u8, text, "reduction: 0%") == null);
    try testing.expect(std.mem.indexOf(u8, text, "reduction: ") != null);
}

test "PO decision journal: gate denial, verify failure, and acceptance land in DECISIONS.md" {
    // verify fails once (rework), gate denies once (redo), then both pass.
    var h = try Harness.init(testing.allocator, &.{
        po_ok, plan1, exec_ok, verify_fail, // → rework
        exec_ok, verify_pass, // → gating (denied)
        exec_ok, verify_pass, // → gating (approved)
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
    // Append-only audit trail, in order: rework → redo → accept.
    const rework = std.mem.indexOf(u8, text, "[rework] missing tests") orelse return error.Missing;
    const redo = std.mem.indexOf(u8, text, "[redo] brief contradiction: scope creep") orelse return error.Missing;
    const accept = std.mem.indexOf(u8, text, "[accept]") orelse return error.Missing;
    try testing.expect(rework < redo and redo < accept);
}

test "carried M3: max_role_turns ⇒ role_turns_exhausted" {
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

test "missions::list snapshots every live mission and empties at terminal state" {
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
    const lres = try ctl_worker.call("zygos::missions::list", "{}");
    defer lres.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, lres.ok, "\"mission_id\":\"m-1\"") != null);
    try testing.expect(std.mem.indexOf(u8, lres.ok, "\"state\":\"running\"") != null);
    h.provider.release.set();
    t.join();
    ctx.res.deinit(testing.allocator);

    const after = try ctl_worker.call("zygos::missions::list", "{}");
    defer after.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, after.ok, "\"missions\":[]") != null);
}

test "carried M3: status reflects a live mission; unknown mission_id errors" {
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
    try testing.expectEqualStrings("running", sp.value.object.get("state").?.string);
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
    // running at the executor, task 2 of 2 pending, three role turns spent.
    var tasks = [_]Task{
        .{ .desc = "build the gizmo", .done = true },
        .{ .desc = "test the gizmo", .done = false },
    };
    const seeded: Mission = .{
        .mission_id = "m-1",
        .state = .running,
        .step_index = 2,
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

test "carried M3: terminal resume runs no turn" {
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
    // phase log covers first and last transitions, in order, in the new
    // vocabulary: the cursor's step rides each running phase.
    const log_arr = obj.get("log").?.array.items;
    try testing.expect(log_arr.len >= 2);
    try testing.expectEqualStrings("running (product-owner) → running (planner)", log_arr[0].string);
    try testing.expectEqualStrings("gating → done", log_arr[log_arr.len - 1].string);
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

// -- Configurable pipeline (docs/specs/mission.md test contract 19-28) --------

/// The `system` field of a recorded provider request.
fn systemOf(arena: std.mem.Allocator, request: []const u8) ![]const u8 {
    const parsed = try json.parseFromSliceLeaky(json.Value, arena, request, .{});
    return parsed.object.get("system").?.string;
}

/// The `field` of every `event` line in an events.jsonl, in order. Strings
/// as-is, `null` as "null", booleans as "true"/"false", integers printed.
fn traceField(arena: std.mem.Allocator, text: []const u8, event: []const u8, field: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const v = try json.parseFromSliceLeaky(json.Value, arena, line, .{});
        if (v != .object) continue;
        const ev = v.object.get("event") orelse continue;
        if (ev != .string or !std.mem.eql(u8, ev.string, event)) continue;
        const f = v.object.get(field) orelse continue;
        try out.append(arena, switch (f) {
            .string => |x| x,
            .null => "null",
            .bool => |b| if (b) "true" else "false",
            .integer => |n| try std.fmt.allocPrint(arena, "{d}", .{n}),
            else => "?",
        });
    }
    return out.items;
}

fn expectSeq(want: []const []const u8, got: []const []const u8) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

/// Run one mission in `h` with a trace file; the caller owns neither.
const Traced = struct {
    res: inproc.CallResult,
    trace: []u8,
    tpath: []u8,

    fn deinit(self: *Traced) void {
        self.res.deinit(testing.allocator);
        testing.allocator.free(self.trace);
        testing.allocator.free(self.tpath);
    }
};

fn runTraced(h: *Harness, extra: []const u8) !Traced {
    const tpath = try std.fmt.allocPrint(testing.allocator, "{s}/events.jsonl", .{h.root});
    errdefer testing.allocator.free(tpath);
    const full = try std.fmt.allocPrint(testing.allocator, "{s},\"trace_path\":{f}", .{ extra, json.fmt(tpath, .{}) });
    defer testing.allocator.free(full);
    const req = try h.startReq(testing.allocator, full);
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::missions::start", req);
    errdefer res.deinit(testing.allocator);
    const trace = trace_mod.readFile(testing.allocator, tpath) orelse return error.ReadFailed;
    return .{ .res = res, .trace = trace, .tpath = tpath };
}

test "default pipeline: same turn order and step_ids as M3; states read running → gating → done" {
    var h = try Harness.init(testing.allocator, &.{ po_ok, plan1, exec_ok, verify_pass });
    defer h.deinit();
    const approvals = try approval_mod.ApprovalWorker.start(testing.allocator, &h.actor, &h.registry, .auto_approve);
    defer approvals.stop();

    // Real routing proves the step_ids: each id resolves to its own model.
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

    var tr = try runTraced(h, ",\"objective\":\"seed: gizmo\",\"router_function\":\"zygos::models::resolve\"," ++
        "\"gate_function\":\"zygos::approvals::request\"");
    defer tr.deinit();
    try expectTerminal(tr.res.ok, "done", "completed");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try expectSeq(&.{ "product-owner", "planner", "executor", "verifier" }, try traceField(arena, tr.trace, "role_start", "role"));
    for ([_][]const u8{ "po-m", "plan-m", "exec-m", "verify-m" }, h.provider.requests.items) |route_model, request| {
        const needle = try std.fmt.allocPrint(arena, "\"model\":\"{s}\"", .{route_model});
        try testing.expect(std.mem.indexOf(u8, request, needle) != null);
    }
    try expectSeq(&.{ "running", "running", "running", "gating", "done" }, try traceField(arena, tr.trace, "mission", "to"));
    try expectSeq(&.{ "planner", "executor", "verifier", "null", "null" }, try traceField(arena, tr.trace, "mission", "step"));
    try expectSeq(&.{ "1", "2", "3", "4", "4" }, try traceField(arena, tr.trace, "mission", "step_index"));
    for ([_][]const u8{ "defining", "planning", "executing", "verifying" }) |legacy| {
        try testing.expect(std.mem.indexOf(u8, tr.trace, legacy) == null);
    }
}

test "executor → verifier: MISSION and PLAN seeded, no product-owner or planner turn" {
    var h = try Harness.init(testing.allocator, &.{ exec_ok, verify_pass });
    defer h.deinit();
    const approvals = try approval_mod.ApprovalWorker.start(testing.allocator, &h.actor, &h.registry, .auto_approve);
    defer approvals.stop();

    var tr = try runTraced(h, seed_and_gate ++ ",\"steps\":[{\"id\":\"executor\"},{\"id\":\"verifier\"}]");
    defer tr.deinit();
    try expectTerminal(tr.res.ok, "done", "completed");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try expectSeq(&.{ "executor", "verifier" }, try traceField(arena_state.allocator(), tr.trace, "role_start", "role"));
    try testing.expectEqual(@as(usize, 2), h.provider.callCount());

    const mission_md = try h.store().readArtifact(testing.allocator, "MISSION.md");
    defer testing.allocator.free(mission_md);
    try testing.expect(std.mem.indexOf(u8, mission_md, "seed: gizmo") != null);
    try testing.expect(std.mem.indexOf(u8, mission_md, "per the operator brief") != null);
    const plan_md = try h.store().readArtifact(testing.allocator, "PLAN.md");
    defer testing.allocator.free(plan_md);
    try testing.expect(std.mem.indexOf(u8, plan_md, "- [ ] seed: gizmo") != null);
    // The verifier saw both seeds and the executor's EXEC.md section.
    try testing.expect(std.mem.indexOf(u8, h.provider.requests.items[1], "per the operator brief") != null);
    try testing.expect(std.mem.indexOf(u8, h.provider.requests.items[1], "task complete") != null);
}

test "architect → executor → verifier: the architect's text lands in step-architect-1.md and in the executor and verifier prompts" {
    const design = roleText("DESIGN: use a ring buffer of 64 slots");
    var h = try Harness.init(testing.allocator, &.{ design, exec_ok, verify_pass });
    defer h.deinit();
    const approvals = try approval_mod.ApprovalWorker.start(testing.allocator, &h.actor, &h.registry, .auto_approve);
    defer approvals.stop();

    var tr = try runTraced(h, seed_and_gate ++ ",\"steps\":[" ++
        "{\"id\":\"architect\",\"system\":\"You are the architect. Design before building.\"}," ++
        "{\"id\":\"executor\"},{\"id\":\"verifier\"}]");
    defer tr.deinit();
    try expectTerminal(tr.res.ok, "done", "completed");

    const note = try h.store().readArtifact(testing.allocator, "step-architect-1.md");
    defer testing.allocator.free(note);
    try testing.expectEqualStrings("DESIGN: use a ring buffer of 64 slots", note);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("You are the architect. Design before building.", try systemOf(arena, h.provider.requests.items[0]));
    for (h.provider.requests.items[1..3]) |request| {
        try testing.expect(std.mem.indexOf(u8, request, "DESIGN: use a ring buffer of 64 slots") != null);
        try testing.expect(std.mem.indexOf(u8, request, "step-architect-1.md") != null);
    }
    // The architect itself saw only the brief, not its own output.
    try testing.expect(std.mem.indexOf(u8, h.provider.requests.items[0], "ring buffer") == null);
    var m = try h.store().load(testing.allocator);
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), m.step_runs.get("architect"));
}

test "a pipeline with no verifier goes from its last step to the gate" {
    var h = try Harness.init(testing.allocator, &.{exec_ok});
    defer h.deinit();
    const gate_worker = try FakeGate.start(testing.allocator, &h.actor, &h.registry, &.{"{\"approved\":true}"});
    defer gate_worker.stop();

    var tr = try runTraced(h, ",\"objective\":\"seed: gizmo\",\"gate_function\":\"test::gate::request\"," ++
        "\"steps\":[{\"id\":\"executor\"}]");
    defer tr.deinit();
    try expectTerminal(tr.res.ok, "done", "completed");
    try testing.expectEqual(@as(usize, 1), gate_worker.calls);
    try testing.expectEqual(@as(usize, 1), h.provider.callCount());

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try expectSeq(&.{"executor"}, try traceField(arena, tr.trace, "role_start", "role"));
    try expectSeq(&.{ "gating", "done" }, try traceField(arena, tr.trace, "mission", "to"));
    try expectSeq(&.{ "1", "1" }, try traceField(arena, tr.trace, "mission", "step_index"));
}

test "verify fail ⇒ fix task on the last executor before the verifier; later steps re-run; fail_count resets on pass" {
    const summary = roleText("SUMMARY: the gizmo ships");
    var h = try Harness.init(testing.allocator, &.{
        exec_ok, verify_fail, roleText("added the missing tests"), verify_pass, summary,
    });
    defer h.deinit();
    const approvals = try approval_mod.ApprovalWorker.start(testing.allocator, &h.actor, &h.registry, .auto_approve);
    defer approvals.stop();

    var tr = try runTraced(h, seed_and_gate ++ ",\"steps\":[{\"id\":\"executor\"},{\"id\":\"verifier\"}," ++
        "{\"id\":\"summarizer\",\"system\":\"Summarize the verified work.\"}]");
    defer tr.deinit();
    try expectTerminal(tr.res.ok, "done", "completed");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The summarizer sits after the verifier, so it runs once, on the pass.
    try expectSeq(
        &.{ "executor", "verifier", "executor", "verifier", "summarizer" },
        try traceField(arena, tr.trace, "role_start", "role"),
    );
    // Call 2 is the fix-task executor turn carrying the verdict.
    try testing.expect(std.mem.indexOf(u8, h.provider.requests.items[2], "missing tests") != null);
    try testing.expect(std.mem.indexOf(u8, h.provider.requests.items[2], "Address this feedback") != null);
    // The rework moved the cursor back to the executor (index 0).
    try testing.expect(std.mem.indexOf(u8, tr.trace, "\"to\":\"running\",\"step\":\"executor\",\"step_index\":0") != null);

    var m = try h.store().load(testing.allocator);
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), m.fail_count);
    try testing.expectEqual(@as(usize, 2), m.step_runs.get("executor"));
    try testing.expectEqual(@as(usize, 2), m.step_runs.get("verifier"));
    try testing.expectEqual(@as(usize, 1), m.step_runs.get("summarizer"));
    try testing.expectEqual(@as(usize, 2), m.tasks.len);
    try testing.expectEqual(@as(usize, 2), m.tasksDone());
    const out = try h.store().readArtifact(testing.allocator, "step-summarizer-1.md");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("SUMMARY: the gizmo ships", out);
}

test "gate denial ⇒ fix task on the last executor in the list" {
    var h = try Harness.init(testing.allocator, &.{ exec_ok, verify_pass, exec_ok, exec_ok });
    defer h.deinit();
    const gate_worker = try FakeGate.start(testing.allocator, &h.actor, &h.registry, &.{
        "{\"approved\":false,\"reason\":\"needs polish\"}",
        "{\"approved\":true}",
    });
    defer gate_worker.stop();

    var tr = try runTraced(h, ",\"objective\":\"seed: gizmo\",\"gate_function\":\"test::gate::request\"," ++
        "\"steps\":[{\"id\":\"executor\"},{\"id\":\"verifier\"},{\"id\":\"executor\"}]");
    defer tr.deinit();
    try expectTerminal(tr.res.ok, "done", "completed");
    try testing.expectEqual(@as(usize, 2), gate_worker.calls);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    // The denial returns to the LAST executor (index 2), not the first: no
    // verifier or first-executor turn follows it.
    try expectSeq(
        &.{ "executor", "verifier", "executor", "executor" },
        try traceField(arena_state.allocator(), tr.trace, "role_start", "role"),
    );
    try testing.expect(std.mem.indexOf(u8, h.provider.requests.items[3], "needs polish") != null);
    // The second executor's own arrival fixed up the verifier's artifact.
    try testing.expect(std.mem.indexOf(u8, h.provider.requests.items[2], "acceptance met") != null);
    var m = try h.store().load(testing.allocator);
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), m.tasks.len);
    try testing.expectEqual(@as(usize, 1), m.gate_denials);
}

test "executor → reviewer → executor: the second executor runs one fix task built from the reviewer output" {
    var h = try Harness.init(testing.allocator, &.{
        roleText("implemented foo"), roleText("REVIEW: rename foo to bar"), roleText("renamed foo to bar"),
    });
    defer h.deinit();
    const approvals = try approval_mod.ApprovalWorker.start(testing.allocator, &h.actor, &h.registry, .auto_approve);
    defer approvals.stop();

    var tr = try runTraced(h, seed_and_gate ++ ",\"steps\":[{\"id\":\"executor\"}," ++
        "{\"id\":\"reviewer\",\"system\":\"You review the work.\"},{\"id\":\"executor\"}]");
    defer tr.deinit();
    try expectTerminal(tr.res.ok, "done", "completed");

    // Exactly one turn for the second executor: the single fix task.
    try testing.expectEqual(@as(usize, 3), h.provider.callCount());
    // The reviewer read the first executor's EXEC.md section.
    try testing.expect(std.mem.indexOf(u8, h.provider.requests.items[1], "implemented foo") != null);
    // The fix task points at the reviewer artifact and carries its contents.
    const fix_req = h.provider.requests.items[2];
    try testing.expect(std.mem.indexOf(u8, fix_req, "Address the findings in these artifacts") != null);
    try testing.expect(std.mem.indexOf(u8, fix_req, "step-reviewer-1.md") != null);
    try testing.expect(std.mem.indexOf(u8, fix_req, "REVIEW: rename foo to bar") != null);

    var m = try h.store().load(testing.allocator);
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), m.tasks.len);
    try testing.expectEqual(@as(usize, 2), m.tasksDone());
    const exec_md = try h.store().readArtifact(testing.allocator, "EXEC.md");
    defer testing.allocator.free(exec_md);
    try testing.expect(std.mem.indexOf(u8, exec_md, "## Task 1: seed: gizmo") != null);
    try testing.expect(std.mem.indexOf(u8, exec_md, "## Task 2: fix: address findings in step-reviewer-1.md") != null);
    try testing.expect(std.mem.indexOf(u8, exec_md, "renamed foo to bar") != null);
}

test "fail_threshold verify failures across two verifier occurrences ⇒ failed, stop escalated" {
    // The first verifier passes (count 0), the second fails (1), the rework
    // re-runs the first, which now fails (2): one mission-level counter.
    var h = try Harness.init(testing.allocator, &.{
        exec_ok, verify_pass, verify_fail, exec_ok, verify_fail,
    });
    defer h.deinit();

    var tr = try runTraced(h, seed_and_gate ++ ",\"fail_threshold\":2," ++
        "\"steps\":[{\"id\":\"executor\"},{\"id\":\"verifier\"},{\"id\":\"verifier\"}]");
    defer tr.deinit();
    try expectTerminal(tr.res.ok, "failed", "escalated");
    try testing.expect(std.mem.indexOf(u8, tr.res.ok, "verify failed 2 consecutive times") != null);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try expectSeq(
        &.{ "executor", "verifier", "verifier", "executor", "verifier" },
        try traceField(arena_state.allocator(), tr.trace, "role_start", "role"),
    );
}

test "a custom step's empty reply ⇒ role_failed; a custom step's max_steps stop ⇒ role_failed" {
    const steps = ",\"steps\":[{\"id\":\"reviewer\",\"system\":\"You review.\"},{\"id\":\"executor\"}]";
    {
        var h = try Harness.init(testing.allocator, &.{roleText("")});
        defer h.deinit();
        const req = try h.startReq(testing.allocator, seed_and_gate ++ steps);
        defer testing.allocator.free(req);
        const res = try h.caller.call("zygos::missions::start", req);
        defer res.deinit(testing.allocator);
        try testing.expect(res == .ok);
        try expectTerminal(res.ok, "failed", "role_failed");
        try testing.expect(std.mem.indexOf(u8, res.ok, "empty reply") != null);
        try testing.expectError(error.NotFound, h.store().readArtifact(testing.allocator, "step-reviewer-1.md"));
        try testing.expectEqual(@as(usize, 1), h.provider.callCount());
    }
    {
        // The executor alone retries a max_steps stop; a custom step must not.
        var h = try Harness.init(testing.allocator, &.{exec_toolspin});
        defer h.deinit();
        const req = try h.startReq(testing.allocator, seed_and_gate ++ steps ++ ",\"role_max_steps\":1");
        defer testing.allocator.free(req);
        const res = try h.caller.call("zygos::missions::start", req);
        defer res.deinit(testing.allocator);
        try testing.expect(res == .ok);
        try expectTerminal(res.ok, "failed", "role_failed");
        try testing.expect(std.mem.indexOf(u8, res.ok, "reviewer turn stopped: max_steps") != null);
        try testing.expectEqual(@as(usize, 1), h.provider.callCount());
    }
}

test "only steps with tools:true receive tools; the verifier never does" {
    var h = try Harness.init(testing.allocator, &.{
        roleText("design done"), roleText("notes written"), exec_ok, verify_pass,
    });
    defer h.deinit();
    const approvals = try approval_mod.ApprovalWorker.start(testing.allocator, &h.actor, &h.registry, .auto_approve);
    defer approvals.stop();

    const tools = ",\"tools\":[{\"name\":\"bash\",\"function_id\":\"zygos::tools::bash\"," ++
        "\"input_schema\":{\"type\":\"object\"}}]";
    var tr = try runTraced(h, seed_and_gate ++ tools ++ ",\"steps\":[" ++
        "{\"id\":\"architect\",\"system\":\"You design.\",\"tools\":true}," ++
        "{\"id\":\"scribe\",\"system\":\"You write.\"}," ++
        "{\"id\":\"executor\"},{\"id\":\"verifier\"}]");
    defer tr.deinit();
    try expectTerminal(tr.res.ok, "done", "completed");

    // Architect (opted in) and executor (default) get the tool; the scribe
    // (default off) and the verifier do not.
    const has_tool = "\"name\":\"bash\"";
    try testing.expect(std.mem.indexOf(u8, h.provider.requests.items[0], has_tool) != null);
    try testing.expect(std.mem.indexOf(u8, h.provider.requests.items[1], has_tool) == null);
    try testing.expect(std.mem.indexOf(u8, h.provider.requests.items[2], has_tool) != null);
    try testing.expect(std.mem.indexOf(u8, h.provider.requests.items[3], has_tool) == null);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try expectSeq(
        &.{ "true", "false", "true", "false" },
        try traceField(arena_state.allocator(), tr.trace, "role_start", "tools"),
    );

    // A verifier pinned with tools never starts: the start is refused.
    const bad = try h.startReq(testing.allocator, ",\"objective\":\"x\"" ++ tools ++
        ",\"steps\":[{\"id\":\"executor\"},{\"id\":\"verifier\",\"tools\":true}]");
    defer testing.allocator.free(bad);
    const refused = try h.caller.call("zygos::missions::start", bad);
    defer refused.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, refused.ok, "steps[1]: verifier cannot have tools") != null);
}

test "a fresh start clears leftovers of an earlier mission; EXEC.md holds this mission's sections only" {
    var h = try Harness.init(testing.allocator, &.{ exec_ok, verify_pass });
    defer h.deinit();
    const approvals = try approval_mod.ApprovalWorker.start(testing.allocator, &h.actor, &h.registry, .auto_approve);
    defer approvals.stop();
    try h.store().writeArtifact(testing.allocator, "EXEC.md", "## Task 9: STALE\n\nold run\n\n");
    try h.store().writeArtifact(testing.allocator, "PLAN.md", "# Plan\n\n- [x] STALE\n");

    const req = try h.startReq(testing.allocator, seed_and_gate ++ ",\"steps\":[{\"id\":\"executor\"},{\"id\":\"verifier\"}]");
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::missions::start", req);
    defer res.deinit(testing.allocator);
    try expectTerminal(res.ok, "done", "completed");

    const exec_md = try h.store().readArtifact(testing.allocator, "EXEC.md");
    defer testing.allocator.free(exec_md);
    try testing.expect(std.mem.indexOf(u8, exec_md, "STALE") == null);
    try testing.expect(std.mem.indexOf(u8, exec_md, "## Task 1: seed: gizmo") != null);
    try testing.expectError(error.NotFound, h.store().readArtifact(testing.allocator, "PLAN-1.md"));
}

test "a product-owner after a seeded MISSION.md archives it as MISSION-1.md; a repeated planner archives PLAN-1.md and keeps done tasks" {
    const po2 = roleText("{\"objective\":\"Ship the gizmo v2\",\"acceptance\":\"v2 ships\"}");
    var h = try Harness.init(testing.allocator, &.{
        plan1, exec_ok, po2, roleText("{\"tasks\":[\"polish v2\"]}"), exec_ok, verify_pass,
    });
    defer h.deinit();
    const approvals = try approval_mod.ApprovalWorker.start(testing.allocator, &h.actor, &h.registry, .auto_approve);
    defer approvals.stop();

    // [planner, executor, product-owner, planner, executor, verifier]: step 0
    // is not a product-owner, so MISSION.md is seeded; the later PO rewrites it.
    const req = try h.startReq(testing.allocator, seed_and_gate ++ ",\"steps\":[{\"id\":\"planner\"},{\"id\":\"executor\"}," ++
        "{\"id\":\"product-owner\"},{\"id\":\"planner\"},{\"id\":\"executor\"},{\"id\":\"verifier\"}]");
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::missions::start", req);
    defer res.deinit(testing.allocator);
    try expectTerminal(res.ok, "done", "completed");

    const archived = try h.store().readArtifact(testing.allocator, "MISSION-1.md");
    defer testing.allocator.free(archived);
    try testing.expect(std.mem.indexOf(u8, archived, "per the operator brief") != null);
    const live = try h.store().readArtifact(testing.allocator, "MISSION.md");
    defer testing.allocator.free(live);
    try testing.expect(std.mem.indexOf(u8, live, "Ship the gizmo v2") != null);

    const old_plan = try h.store().readArtifact(testing.allocator, "PLAN-1.md");
    defer testing.allocator.free(old_plan);
    try testing.expect(std.mem.indexOf(u8, old_plan, "polish the gizmo") != null);
    const plan = try h.store().readArtifact(testing.allocator, "PLAN.md");
    defer testing.allocator.free(plan);
    try testing.expect(std.mem.indexOf(u8, plan, "- [x] polish the gizmo") != null);
    try testing.expect(std.mem.indexOf(u8, plan, "- [ ] polish v2") != null);

    var m = try h.store().load(testing.allocator);
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), m.mission_versions);
    try testing.expectEqual(@as(usize, 1), m.plan_versions);
    try testing.expectEqual(@as(usize, 2), m.tasks.len);
}

test "a mission resumed from a legacy state file continues from the mapped cursor" {
    var h = try Harness.init(testing.allocator, &.{verify_pass});
    defer h.deinit();
    const approvals = try approval_mod.ApprovalWorker.start(testing.allocator, &h.actor, &h.registry, .auto_approve);
    defer approvals.stop();
    try h.store().writeArtifact(testing.allocator, "MISSION.md", "# Mission m-1\n\nShip the gizmo\n");
    try h.store().writeArtifact(testing.allocator, "PLAN.md", "# Plan\n\n- [ ] build\n");
    try h.store().writeArtifact(testing.allocator, "mission.json",
        \\{"mission_id":"m-1","state":"verifying","stop":"none","detail":"","objective":"Ship the gizmo",
        \\ "acceptance":"ships","feedback":"","tasks":[{"desc":"build","done":true}],
        \\ "task_index":1,"fail_count":0,"gate_denials":0,"role_turns_used":4}
    );

    const req = try h.startReq(testing.allocator, seed_and_gate ++ ",\"resume\":true");
    defer testing.allocator.free(req);
    const res = try h.caller.call("zygos::missions::start", req);
    defer res.deinit(testing.allocator);
    try expectTerminal(res.ok, "done", "completed");
    // Only the verifier ran: the legacy `verifying` state maps to step 3,
    // and a missing EXEC.md does not stop it.
    try testing.expectEqual(@as(usize, 1), h.provider.callCount());
}
