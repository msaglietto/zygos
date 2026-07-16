//! Turn orchestrator (T2, T4 — docs/specs/turn.md). One turn = one agentic
//! loop: assemble context → stream a model response → dispatch tool calls →
//! repeat until the model stops or the step budget runs out.
//!
//! Split hard: `Fsm` is a pure table-driven state machine (exhaustively
//! tested, no I/O); `TurnOrchestrator` is bus glue over an inproc worker —
//! provider and tools are ordinary bus functions named in the request, so
//! fakes and the real provider are interchangeable peers.
//!
//! Deviation from the spec's failure line (flagged): turn failures reply as
//! `{"stop":"failed",...}` result payloads — the inproc Handler contract
//! carries no custom ErrorBody codes, and callers want the transcript anyway.

const std = @import("std");
const json = std.json;
const actor_mod = @import("../kernel/actor.zig");
const inproc = @import("../kernel/inproc.zig");
const sync = @import("../kernel/sync.zig");
const channel_mod = @import("../kernel/channel.zig");
const trace_mod = @import("trace.zig");

const log = std.log.scoped(.turn);

// ---------------------------------------------------------------------------
// FSM (pure)
// ---------------------------------------------------------------------------

pub const State = enum {
    provisioning,
    streaming,
    dispatching,
    awaiting_approval,
    steering,
    stopped,
    failed,
};

pub const Event = enum {
    provider_started,
    provider_end_turn,
    provider_tool_use,
    provider_error,
    tools_done,
    needs_approval,
    approved,
    denied,
    steer,
    steer_applied,
    abort,
    step_budget_exhausted,
    provider_retry,
    budget_exhausted,
};

const Transition = struct { from: State, event: Event, to: State };

/// The complete legal-transition table (docs/specs/turn.md). Everything not
/// listed is IllegalTransition; terminal states accept nothing.
pub const transitions = [_]Transition{
    .{ .from = .provisioning, .event = .provider_started, .to = .streaming },
    // Provisioning that cannot resolve a provider (routes exhausted, router
    // down) is a provider_error before any stream exists.
    .{ .from = .provisioning, .event = .provider_error, .to = .failed },
    .{ .from = .provisioning, .event = .step_budget_exhausted, .to = .stopped },
    .{ .from = .provisioning, .event = .budget_exhausted, .to = .stopped },
    .{ .from = .provisioning, .event = .abort, .to = .stopped },
    .{ .from = .streaming, .event = .provider_end_turn, .to = .stopped },
    .{ .from = .streaming, .event = .provider_tool_use, .to = .dispatching },
    .{ .from = .streaming, .event = .provider_error, .to = .failed },
    .{ .from = .streaming, .event = .provider_retry, .to = .provisioning },
    .{ .from = .streaming, .event = .steer, .to = .steering },
    .{ .from = .streaming, .event = .abort, .to = .stopped },
    .{ .from = .dispatching, .event = .needs_approval, .to = .awaiting_approval },
    .{ .from = .dispatching, .event = .tools_done, .to = .provisioning },
    .{ .from = .dispatching, .event = .steer, .to = .steering },
    .{ .from = .dispatching, .event = .abort, .to = .stopped },
    .{ .from = .awaiting_approval, .event = .approved, .to = .dispatching },
    .{ .from = .awaiting_approval, .event = .denied, .to = .dispatching },
    .{ .from = .awaiting_approval, .event = .abort, .to = .stopped },
    .{ .from = .steering, .event = .steer_applied, .to = .provisioning },
    .{ .from = .steering, .event = .abort, .to = .stopped },
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
// Driver
// ---------------------------------------------------------------------------

/// Cross-thread controls for one running turn (U2): `zygos::turns::abort`
/// flips the flag, `zygos::turns::steer` queues text; the driver polls at
/// step boundaries. ALL fields are guarded by the orchestrator's ctl_mutex —
/// a per-control mutex would dangle when the owning turn untracks between a
/// handler's map lookup and its lock.
const TurnControl = struct {
    aborted: bool = false,
    steer_text: std.ArrayList(u8) = .empty,
};

/// In-process observer of streamed text deltas (e.g. the mission TUI).
/// Called on the per-step drain thread; `bytes` are valid only for the
/// duration of the call — observers copy, never retain.
pub const DeltaObserver = struct {
    ctx: *anyopaque,
    onDelta: *const fn (ctx: *anyopaque, turn_id: []const u8, bytes: []const u8) void,
};

pub const TurnOrchestrator = struct {
    gpa: std.mem.Allocator,
    actor: *actor_mod.Actor,
    worker: *inproc.Worker,
    ctl_mutex: sync.Mutex = .{},
    controls: std.StringHashMap(*TurnControl),
    /// Set before any turn runs (unsynchronized: turns snapshot it at start).
    delta_observer: ?DeltaObserver = null,

    pub fn start(
        gpa: std.mem.Allocator,
        actor: *actor_mod.Actor,
        registry: *inproc.Registry,
    ) !*TurnOrchestrator {
        const self = try gpa.create(TurnOrchestrator);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .actor = actor,
            .worker = try inproc.Worker.spawn(gpa, actor, registry, "turn-orchestrator"),
            .controls = std.StringHashMap(*TurnControl).init(gpa),
        };
        errdefer self.worker.stop();
        try self.worker.registerFunction("zygos::turns::run", self, &runTurnHandler);
        try self.worker.registerFunction("zygos::turns::abort", self, &abortHandler);
        try self.worker.registerFunction("zygos::turns::steer", self, &steerHandler);
        return self;
    }

    /// Install the live-delta observer. Call before any turn runs; runTurn
    /// snapshots the field once at turn start.
    pub fn setDeltaObserver(self: *TurnOrchestrator, obs: ?DeltaObserver) void {
        self.delta_observer = obs;
    }

    pub fn stop(self: *TurnOrchestrator) void {
        // worker.stop() joins every runTurn handler thread; each untracks
        // its own control on the way out, so the map must drain to empty.
        self.worker.stop();
        std.debug.assert(self.controls.count() == 0);
        self.controls.deinit();
        self.ctl_mutex.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    fn trackTurn(self: *TurnOrchestrator, turn_id: []const u8) error{ OutOfMemory, MalformedRequest }!*TurnControl {
        const ctl = try self.gpa.create(TurnControl);
        errdefer self.gpa.destroy(ctl);
        ctl.* = .{};
        const key = try self.gpa.dupe(u8, turn_id);
        errdefer self.gpa.free(key);

        self.ctl_mutex.lock();
        defer self.ctl_mutex.unlock();
        const gop = try self.controls.getOrPut(key);
        if (gop.found_existing) return error.MalformedRequest; // duplicate live turn_id
        gop.value_ptr.* = ctl;
        return ctl;
    }

    fn untrackTurn(self: *TurnOrchestrator, turn_id: []const u8) void {
        const kv = blk: {
            self.ctl_mutex.lock();
            defer self.ctl_mutex.unlock();
            break :blk self.controls.fetchRemove(turn_id) orelse return;
        };
        kv.value.steer_text.deinit(self.gpa);
        self.gpa.destroy(kv.value);
        self.gpa.free(kv.key);
    }

    /// Both control handlers: look up the turn by id and act while STILL
    /// holding ctl_mutex, reply {"ok":bool}. Unknown/finished turns are
    /// ok:false, not errors.
    fn abortHandler(ctx: ?*anyopaque, arena: std.mem.Allocator, request_json: []const u8) error{ Failed, OutOfMemory }![]const u8 {
        const self: *TurnOrchestrator = @ptrCast(@alignCast(ctx.?));
        const tid = controlTarget(arena, request_json);
        const ok = blk: {
            self.ctl_mutex.lock();
            defer self.ctl_mutex.unlock();
            const ctl = self.controls.get(tid orelse break :blk false) orelse break :blk false;
            ctl.aborted = true;
            break :blk true;
        };
        return std.fmt.allocPrint(arena, "{{\"ok\":{}}}", .{ok});
    }

    fn steerHandler(ctx: ?*anyopaque, arena: std.mem.Allocator, request_json: []const u8) error{ Failed, OutOfMemory }![]const u8 {
        const self: *TurnOrchestrator = @ptrCast(@alignCast(ctx.?));
        const root = json.parseFromSliceLeaky(json.Value, arena, request_json, .{}) catch null;
        const ok = blk: {
            const obj = root orelse break :blk false;
            if (obj != .object) break :blk false;
            const tid = strField(obj.object, "turn_id") orelse break :blk false;
            const text = strField(obj.object, "text") orelse break :blk false;
            self.ctl_mutex.lock();
            defer self.ctl_mutex.unlock();
            const ctl = self.controls.get(tid) orelse break :blk false;
            try ctl.steer_text.appendSlice(self.gpa, text);
            break :blk true;
        };
        return std.fmt.allocPrint(arena, "{{\"ok\":{}}}", .{ok});
    }

    fn pollAborted(self: *TurnOrchestrator, ctl: ?*TurnControl) bool {
        const c = ctl orelse return false;
        self.ctl_mutex.lock();
        defer self.ctl_mutex.unlock();
        return c.aborted;
    }

    /// Drain-and-clear queued steer text (duped into the turn's arena so the
    /// control can keep mutating). Distinct from pollAborted so an abort
    /// check never silently discards queued steering.
    fn drainSteer(self: *TurnOrchestrator, ctl: ?*TurnControl, arena: std.mem.Allocator) error{OutOfMemory}!?[]const u8 {
        const c = ctl orelse return null;
        self.ctl_mutex.lock();
        defer self.ctl_mutex.unlock();
        if (c.steer_text.items.len == 0) return null;
        const copy = try arena.dupe(u8, c.steer_text.items);
        c.steer_text.clearRetainingCapacity();
        return copy;
    }

    const Resolved = struct { provider_function: []const u8, model: []const u8 };

    /// U3 — null means this turn has no more routes (ladder exhausted,
    /// router down, malformed reply); the caller fails the turn.
    fn resolveRoute(
        self: *TurnOrchestrator,
        arena: std.mem.Allocator,
        router_fn: []const u8,
        step_id: []const u8,
        attempt: usize,
    ) error{OutOfMemory}!?Resolved {
        const rreq = try std.fmt.allocPrint(arena, "{{\"step_id\":{f},\"attempt\":{d}}}", .{
            json.fmt(step_id, .{}), attempt,
        });
        const res = self.worker.call(router_fn, rreq) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Shutdown => return null,
        };
        switch (res) {
            .err => |code| {
                self.gpa.free(code);
                return null;
            },
            .ok => |payload| {
                defer self.gpa.free(payload);
                const root = json.parseFromSliceLeaky(json.Value, arena, payload, .{}) catch return null;
                if (root != .object) return null;
                const pf = strField(root.object, "provider_function") orelse return null;
                const m = strField(root.object, "model") orelse return null;
                return .{
                    .provider_function = try arena.dupe(u8, pf),
                    .model = try arena.dupe(u8, m),
                };
            },
        }
    }

    /// U5 — fail closed: a bus error, malformed reply, or missing worker is
    /// indistinguishable from "over budget" on purpose.
    fn checkBudget(
        self: *TurnOrchestrator,
        arena: std.mem.Allocator,
        budget_fn: []const u8,
        scope: []const u8,
    ) error{OutOfMemory}!bool {
        const req = try std.fmt.allocPrint(arena, "{{\"scope\":{f}}}", .{json.fmt(scope, .{})});
        const res = self.worker.call(budget_fn, req) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Shutdown => return false,
        };
        switch (res) {
            .err => |code| {
                self.gpa.free(code);
                return false;
            },
            .ok => |payload| {
                defer self.gpa.free(payload);
                const root = json.parseFromSliceLeaky(json.Value, arena, payload, .{}) catch return false;
                if (root != .object) return false;
                const v = root.object.get("ok") orelse return false;
                return v == .bool and v.bool;
            },
        }
    }

    /// Recording failures are ignored (accounting, not control flow) — the
    /// fail-closed side lives in checkBudget.
    fn recordUsage(
        self: *TurnOrchestrator,
        arena: std.mem.Allocator,
        scope: []const u8,
        usage: json.ObjectMap,
    ) error{OutOfMemory}!void {
        inline for (.{ "input_tokens", "output_tokens" }) |kind| {
            if (usage.get(kind)) |v| if (v == .integer and v.integer > 0) {
                const req = try std.fmt.allocPrint(
                    arena,
                    "{{\"scope\":{f},\"kind\":\"" ++ kind ++ "\",\"amount\":{d}}}",
                    .{ json.fmt(scope, .{}), v.integer },
                );
                const res = self.worker.call("zygos::budget::record", req) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.Shutdown => return,
                };
                res.deinit(self.gpa);
            };
        }
    }

    const PolicyDecision = union(enum) { allow, ask, deny: []const u8 };

    /// U1 — fail closed: any bus error, malformed reply, or unknown verdict
    /// is a deny carrying the failure as its reason.
    fn checkPolicy(
        self: *TurnOrchestrator,
        arena: std.mem.Allocator,
        policy_fn: []const u8,
        tool_name: []const u8,
        function_id: []const u8,
        input: json.Value,
    ) error{OutOfMemory}!PolicyDecision {
        const preq = try std.fmt.allocPrint(arena, "{{\"tool\":{f},\"function_id\":{f},\"input\":{s}}}", .{
            json.fmt(tool_name, .{}),
            json.fmt(function_id, .{}),
            try rawJson(arena, input),
        });
        const res = self.worker.call(policy_fn, preq) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Shutdown => return .{ .deny = "policy unreachable" },
        };
        switch (res) {
            .err => |code| {
                defer self.gpa.free(code);
                return .{ .deny = try arena.dupe(u8, code) };
            },
            .ok => |payload| {
                defer self.gpa.free(payload);
                const root = json.parseFromSliceLeaky(json.Value, arena, payload, .{}) catch
                    return .{ .deny = "malformed policy verdict" };
                if (root != .object) return .{ .deny = "malformed policy verdict" };
                const verdict = strField(root.object, "verdict") orelse
                    return .{ .deny = "malformed policy verdict" };
                if (std.mem.eql(u8, verdict, "allow")) return .allow;
                if (std.mem.eql(u8, verdict, "ask")) return .ask;
                if (std.mem.eql(u8, verdict, "deny")) {
                    const reason = strField(root.object, "reason") orelse "";
                    return .{ .deny = try arena.dupe(u8, reason) };
                }
                return .{ .deny = "malformed policy verdict" };
            },
        }
    }

    /// U2 — no approval_function preserves M1 auto-approve (tested legacy);
    /// with one, only an explicit {"approved":true} dispatches (fail closed).
    fn requestApproval(
        self: *TurnOrchestrator,
        arena: std.mem.Allocator,
        approval_fn: ?[]const u8,
        tool_name: []const u8,
        input: json.Value,
    ) error{OutOfMemory}!bool {
        const af = approval_fn orelse return true;
        const areq = try std.fmt.allocPrint(arena, "{{\"tool\":{f},\"input\":{s},\"reason\":\"turn tool dispatch\"}}", .{
            json.fmt(tool_name, .{}),
            try rawJson(arena, input),
        });
        const res = self.worker.call(af, areq) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Shutdown => return false,
        };
        switch (res) {
            .err => |code| {
                self.gpa.free(code);
                return false;
            },
            .ok => |payload| {
                defer self.gpa.free(payload);
                const root = json.parseFromSliceLeaky(json.Value, arena, payload, .{}) catch return false;
                if (root != .object) return false;
                const v = root.object.get("approved") orelse return false;
                return v == .bool and v.bool;
            },
        }
    }

    /// The `output::compress` seam (ARCHITECTURE.md M1 line): every ok tool
    /// output is offered to `zygos::output::compress` on the bus —
    /// `{"content":<str>}` in, `{"content":<str>}` out. Nothing registered
    /// (function_not_found) or any malformed reply = pass-through. The real
    /// output-trim filters land in M2 (decision Z-09).
    fn compressSeam(
        self: *TurnOrchestrator,
        arena: std.mem.Allocator,
        out: []const u8,
    ) error{OutOfMemory}![]const u8 {
        const request = try std.fmt.allocPrint(arena, "{{\"content\":{f}}}", .{json.fmt(out, .{})});
        const res = self.worker.call("zygos::output::compress", request) catch
            return arena.dupe(u8, out);
        switch (res) {
            .err => |code| {
                self.gpa.free(code);
                return arena.dupe(u8, out);
            },
            .ok => |payload| {
                defer self.gpa.free(payload);
                const root = json.parseFromSliceLeaky(json.Value, arena, payload, .{}) catch
                    return arena.dupe(u8, out);
                if (root == .object) if (root.object.get("content")) |v| if (v == .string)
                    return v.string;
                return arena.dupe(u8, out);
            },
        }
    }
};

/// Per-turn tool table entry, resolved from the request's `tools` array.
const ToolRoute = struct {
    function_id: []const u8,
    requires_approval: bool,
};

/// Collects streamed deltas across the turn; the drain thread appends while
/// the driver blocks on the provider call. gpa-backed on purpose: the turn
/// arena is NOT thread-safe and must never be touched from the drain thread;
/// pipe items were duped with the registry gpa and are freed with it.
const DeltaLog = struct {
    mutex: sync.Mutex = .{},
    buf: std.ArrayList(u8) = .empty,
    /// Snapshot of the orchestrator's observer at turn start. `turn_id`
    /// points into the request arena — safe because every drain thread is
    /// joined before runTurn returns (the arena outlives the thread).
    observer: ?DeltaObserver = null,
    turn_id: []const u8 = "",

    fn drain(self: *DeltaLog, gpa: std.mem.Allocator, receiver: *channel_mod.Receiver) void {
        while (receiver.pop()) |item| {
            defer item.deinit(gpa);
            {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.buf.appendSlice(gpa, item.bytes()) catch {};
            }
            // Outside the DeltaLog mutex: the observer takes its own locks
            // (TUI model), and holding both invites ordering deadlocks.
            if (self.observer) |o| o.onDelta(o.ctx, self.turn_id, item.bytes());
        } else |_| {} // EndOfStream
    }
};

fn runTurnHandler(
    ctx: ?*anyopaque,
    arena: std.mem.Allocator,
    request_json: []const u8,
) error{ Failed, OutOfMemory }![]const u8 {
    const self: *TurnOrchestrator = @ptrCast(@alignCast(ctx.?));
    return runTurn(self, arena, request_json) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => {
            log.warn("turn failed structurally: {t}", .{err});
            return error.Failed;
        },
    };
}

const TurnError = error{ OutOfMemory, Failed, MalformedRequest, IllegalTransition, Shutdown };

fn runTurn(self: *TurnOrchestrator, arena: std.mem.Allocator, request_json: []const u8) TurnError![]const u8 {
    const root = json.parseFromSliceLeaky(json.Value, arena, request_json, .{}) catch
        return error.MalformedRequest;
    const obj = if (root == .object) root.object else return error.MalformedRequest;

    const model = strField(obj, "model") orelse "unknown";
    const system = strField(obj, "system") orelse "";
    const max_steps: usize = if (obj.get("max_steps")) |v|
        (if (v == .integer and v.integer > 0) @intCast(v.integer) else 8)
    else
        8;
    const static_provider = strField(obj, "provider_function");
    const router_fn = strField(obj, "router_function");
    const step_id = strField(obj, "step_id") orelse "";
    if (static_provider == null and router_fn == null) return error.MalformedRequest;
    const policy_fn = strField(obj, "policy_function");
    const approval_fn = strField(obj, "approval_function");
    const turn_id = strField(obj, "turn_id");
    const budget_scope = strField(obj, "budget_scope");
    const budget_fn = strField(obj, "budget_function") orelse "zygos::budget::check";
    const trace_path = strField(obj, "trace_path");

    // Tool routing table: name → {function_id, requires_approval}.
    var routes = std.StringHashMap(ToolRoute).init(arena);
    const tools_json = blk: {
        const tools_val = obj.get("tools") orelse break :blk "[]";
        if (tools_val != .array) return error.MalformedRequest;
        for (tools_val.array.items) |tv| {
            if (tv != .object) return error.MalformedRequest;
            const name = strField(tv.object, "name") orelse return error.MalformedRequest;
            const fid = strField(tv.object, "function_id") orelse return error.MalformedRequest;
            const approval = if (tv.object.get("requires_approval")) |a| a == .bool and a.bool else false;
            try routes.put(name, .{ .function_id = fid, .requires_approval = approval });
        }
        break :blk try rawJson(arena, tools_val);
    };

    // Transcript: raw message JSON texts, in order.
    var transcript: std.ArrayList([]const u8) = .empty;
    if (obj.get("messages")) |msgs| {
        if (msgs != .array) return error.MalformedRequest;
        for (msgs.array.items) |m| try transcript.append(arena, try rawJson(arena, m));
    }

    var deltas: DeltaLog = .{
        .observer = self.delta_observer,
        .turn_id = turn_id orelse "",
    };
    defer {
        deltas.buf.deinit(self.gpa);
        deltas.mutex.deinit();
    }

    // Turns carrying an id are abortable/steerable over the bus (U2).
    const ctl: ?*TurnControl = if (turn_id) |tid| try self.trackTurn(tid) else null;
    defer if (turn_id) |tid| self.untrackTurn(tid);

    var state: State = .provisioning;
    var steps: usize = 0;
    var attempt: usize = 0; // provider failures so far (U3 escalation ladder)
    var stop: []const u8 = "end_turn";

    turn: while (true) {
        std.debug.assert(state == .provisioning);
        if (self.pollAborted(ctl)) {
            state = try Fsm.apply(state, .abort); // → stopped
            stop = "aborted";
            break :turn;
        }
        if (steps == max_steps) {
            state = try Fsm.apply(state, .step_budget_exhausted);
            stop = "max_steps";
            break :turn;
        }

        // U5 budget gate — fail closed: an unanswerable check is "over".
        if (budget_scope) |scope| {
            if (!try self.checkBudget(arena, budget_fn, scope)) {
                state = try Fsm.apply(state, .budget_exhausted); // → stopped
                stop = "budget_exhausted";
                break :turn;
            }
        }

        // U3 routing: resolve this step's provider; without a router the
        // request's static provider_function/model stand.
        var step_provider = static_provider orelse "";
        var step_model = model;
        if (router_fn) |rf| {
            if (try self.resolveRoute(arena, rf, step_id, attempt)) |r| {
                step_provider = r.provider_function;
                step_model = r.model;
            } else {
                state = try Fsm.apply(state, .provider_error); // → failed
                try trace_mod.event(
                    arena,
                    trace_path,
                    "\"event\":\"turn_end\",\"turn_id\":{f},\"stop\":\"failed\",\"steps\":{d},\"error\":\"route_exhausted\"",
                    .{ json.fmt(turn_id orelse "", .{}), steps },
                );
                return try std.fmt.allocPrint(
                    arena,
                    "{{\"stop\":\"failed\",\"steps\":{d},\"error\":\"route_exhausted\"}}",
                    .{steps},
                );
            }
        }

        // Stream channel for this step: driver keeps the receiver, the
        // writer ref rides in the provider request (PROTOCOL.md sub-types).
        const ch = self.actor.channelCreate(64, self.worker.id, 0) catch return error.Failed;
        var receiver = self.actor.channelTakeReceiver(
            ch.reader.channel_id,
            ch.reader.access_key,
            0,
        ) catch return error.Failed;

        const provider_request = try std.fmt.allocPrint(arena,
            \\{{"model":{f},"system":{f},"messages":[{s}],"tools":{s},
            \\ "stream_channel":{{"channel_id":{f},"access_key":{f},"direction":"write"}}}}
        , .{
            json.fmt(step_model, .{}),
            json.fmt(system, .{}),
            try joinComma(arena, transcript.items),
            tools_json,
            json.fmt(ch.writer.channel_id, .{}),
            json.fmt(ch.writer.access_key, .{}),
        });

        log.info("turn {s} step {d}: {s} model {s} (attempt {d})", .{
            turn_id orelse "?", steps + 1, step_provider, step_model, attempt,
        });
        try trace_mod.event(
            arena,
            trace_path,
            "\"event\":\"step\",\"turn_id\":{f},\"step\":{d},\"provider\":{f},\"model\":{f},\"attempt\":{d}",
            .{ json.fmt(turn_id orelse "", .{}), steps + 1, json.fmt(step_provider, .{}), json.fmt(step_model, .{}), attempt },
        );
        state = try Fsm.apply(state, .provider_started); // → streaming
        const drain_thread = std.Thread.spawn(.{}, DeltaLog.drain, .{ &deltas, self.gpa, &receiver }) catch
            return error.Failed;

        const res = self.worker.call(step_provider, provider_request) catch |err| {
            receiver.close();
            drain_thread.join();
            receiver.deinit();
            return err;
        };
        // Unblock the drain even if the provider never took the sender.
        receiver.close();
        drain_thread.join();
        receiver.deinit();

        switch (res) {
            .err => |code| {
                // With a router, a failed provider escalates to the next
                // ladder attempt instead of failing the turn; the failed
                // call does not count as a step.
                if (router_fn != null) {
                    self.gpa.free(code);
                    attempt += 1;
                    state = try Fsm.apply(state, .provider_retry); // → provisioning
                    continue :turn;
                }
                defer self.gpa.free(code);
                state = try Fsm.apply(state, .provider_error); // → failed
                try trace_mod.event(
                    arena,
                    trace_path,
                    "\"event\":\"turn_end\",\"turn_id\":{f},\"stop\":\"failed\",\"steps\":{d},\"error\":{f}",
                    .{ json.fmt(turn_id orelse "", .{}), steps, json.fmt(code, .{}) },
                );
                return try std.fmt.allocPrint(
                    arena,
                    "{{\"stop\":\"failed\",\"steps\":{d},\"error\":{f}}}",
                    .{ steps, json.fmt(code, .{}) },
                );
            },
            .ok => |payload| {
                defer self.gpa.free(payload);
                steps += 1;
                const msg = json.parseFromSliceLeaky(json.Value, arena, payload, .{}) catch
                    return error.Failed;
                if (msg != .object) return error.Failed;
                const stop_reason = strField(msg.object, "stop_reason") orelse "end_turn";

                // U5 accounting — synchronous so the next provisioning
                // check observes this step's usage. The usage trace event is
                // independent of budgeting: token totals are observability.
                if (msg.object.get("usage")) |u| if (u == .object) {
                    if (budget_scope) |scope| try self.recordUsage(arena, scope, u.object);
                    try trace_mod.event(
                        arena,
                        trace_path,
                        "\"event\":\"usage\",\"turn_id\":{f},\"step\":{d},\"input_tokens\":{d},\"output_tokens\":{d}",
                        .{
                            json.fmt(turn_id orelse "", .{}),   steps,
                            intField(u.object, "input_tokens"), intField(u.object, "output_tokens"),
                        },
                    );
                };
                const content = msg.object.get("content") orelse json.Value{ .array = .init(arena) };

                // Assistant message joins the transcript either way.
                try transcript.append(arena, try std.fmt.allocPrint(
                    arena,
                    "{{\"role\":\"assistant\",\"content\":{s}}}",
                    .{try rawJson(arena, content)},
                ));

                if (!std.mem.eql(u8, stop_reason, "tool_use")) {
                    state = try Fsm.apply(state, .provider_end_turn); // → stopped
                    stop = stop_reason;
                    break :turn;
                }

                state = try Fsm.apply(state, .provider_tool_use); // → dispatching

                // Dispatch every tool_use block over the bus.
                var results: std.ArrayList([]const u8) = .empty;
                if (content == .array) for (content.array.items) |block| {
                    if (block != .object) continue;
                    const btype = strField(block.object, "type") orelse continue;
                    if (!std.mem.eql(u8, btype, "tool_use")) continue;
                    const tool_id = strField(block.object, "id") orelse "unknown";
                    const tool_name = strField(block.object, "name") orelse "";
                    const input = block.object.get("input") orelse json.Value.null;
                    log.info("turn {s} step {d}: tool {s}", .{ turn_id orelse "?", steps, tool_name });
                    try trace_mod.event(
                        arena,
                        trace_path,
                        "\"event\":\"tool_call\",\"turn_id\":{f},\"step\":{d},\"tool\":{f},\"input\":{f}",
                        .{
                            json.fmt(turn_id orelse "", .{}),                                    steps, json.fmt(tool_name, .{}),
                            json.fmt(try trace_mod.clip(arena, try rawJson(arena, input)), .{}),
                        },
                    );

                    if (self.pollAborted(ctl)) {
                        state = try Fsm.apply(state, .abort); // dispatching → stopped
                        stop = "aborted";
                        break :turn;
                    }

                    const route = routes.get(tool_name) orelse {
                        try traceToolResult(arena, trace_path, steps, tool_name, "unknown tool", true);
                        try results.append(arena, try toolResult(arena, tool_id, "unknown tool", true));
                        continue;
                    };

                    // U1 policy gate — only an explicit verdict dispatches.
                    var ask = route.requires_approval;
                    if (policy_fn) |pf| {
                        switch (try self.checkPolicy(arena, pf, tool_name, route.function_id, input)) {
                            .allow => {},
                            .ask => ask = true,
                            .deny => |reason| {
                                const denied = try std.fmt.allocPrint(arena, "policy_denied: {s}", .{reason});
                                try traceToolResult(arena, trace_path, steps, tool_name, denied, true);
                                try results.append(arena, try toolResult(arena, tool_id, denied, true));
                                continue;
                            },
                        }
                    }

                    if (ask) {
                        state = try Fsm.apply(state, .needs_approval); // → awaiting_approval
                        if (try self.requestApproval(arena, approval_fn, tool_name, input)) {
                            state = try Fsm.apply(state, .approved); // → dispatching
                        } else {
                            state = try Fsm.apply(state, .denied); // → dispatching
                            try traceToolResult(arena, trace_path, steps, tool_name, "approval_denied", true);
                            try results.append(arena, try toolResult(arena, tool_id, "approval_denied", true));
                            continue;
                        }
                    }

                    const tool_res = self.worker.call(route.function_id, try rawJson(arena, input)) catch |err|
                        return err;
                    switch (tool_res) {
                        .ok => |out| {
                            defer self.gpa.free(out);
                            const final = try self.compressSeam(arena, out);
                            try traceToolResult(arena, trace_path, steps, tool_name, final, false);
                            try results.append(arena, try toolResult(arena, tool_id, final, false));
                        },
                        .err => |code| {
                            defer self.gpa.free(code);
                            try traceToolResult(arena, trace_path, steps, tool_name, code, true);
                            try results.append(arena, try toolResult(arena, tool_id, code, true));
                        },
                    }
                };

                // U2 steering: text queued during this step joins the next
                // user message through the FSM's steering path.
                if (try self.drainSteer(ctl, arena)) |stext| {
                    state = try Fsm.apply(state, .steer); // → steering
                    try results.append(arena, try std.fmt.allocPrint(
                        arena,
                        "{{\"type\":\"text\",\"text\":{f}}}",
                        .{json.fmt(stext, .{})},
                    ));
                    state = try Fsm.apply(state, .steer_applied); // → provisioning
                } else {
                    state = try Fsm.apply(state, .tools_done); // → provisioning
                }
                try transcript.append(arena, try std.fmt.allocPrint(
                    arena,
                    "{{\"role\":\"user\",\"content\":[{s}]}}",
                    .{try joinComma(arena, results.items)},
                ));
            },
        }
    }

    std.debug.assert(state == .stopped);
    try trace_mod.event(
        arena,
        trace_path,
        "\"event\":\"turn_end\",\"turn_id\":{f},\"stop\":{f},\"steps\":{d}",
        .{ json.fmt(turn_id orelse "", .{}), json.fmt(stop, .{}), steps },
    );
    deltas.mutex.lock();
    const delta_text = deltas.buf.items;
    deltas.mutex.unlock();
    return try std.fmt.allocPrint(
        arena,
        "{{\"stop\":{f},\"steps\":{d},\"deltas\":{f},\"transcript\":[{s}]}}",
        .{ json.fmt(stop, .{}), steps, json.fmt(delta_text, .{}), try joinComma(arena, transcript.items) },
    );
}

/// Trace twin of `toolResult`: what the model will see (post-compress),
/// clipped for the event line, with the full size alongside.
fn traceToolResult(
    arena: std.mem.Allocator,
    trace_path: ?[]const u8,
    step: usize,
    tool_name: []const u8,
    content: []const u8,
    is_error: bool,
) error{OutOfMemory}!void {
    try trace_mod.event(
        arena,
        trace_path,
        "\"event\":\"tool_result\",\"step\":{d},\"tool\":{f},\"is_error\":{},\"bytes\":{d},\"output\":{f}",
        .{
            step,                                              json.fmt(tool_name, .{}), is_error, content.len,
            json.fmt(try trace_mod.clip(arena, content), .{}),
        },
    );
}

fn toolResult(arena: std.mem.Allocator, tool_use_id: []const u8, content: []const u8, is_error: bool) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "{{\"type\":\"tool_result\",\"tool_use_id\":{f},\"content\":{f},\"is_error\":{}}}",
        .{ json.fmt(tool_use_id, .{}), json.fmt(content, .{}), is_error },
    );
}

fn strField(obj: json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn intField(obj: json.ObjectMap, key: []const u8) i64 {
    const v = obj.get(key) orelse return 0;
    return if (v == .integer) v.integer else 0;
}

fn controlTarget(arena: std.mem.Allocator, request_json: []const u8) ?[]const u8 {
    const root = json.parseFromSliceLeaky(json.Value, arena, request_json, .{}) catch return null;
    if (root != .object) return null;
    return strField(root.object, "turn_id");
}

fn joinComma(arena: std.mem.Allocator, items: []const []const u8) error{OutOfMemory}![]const u8 {
    return std.mem.join(arena, ",", items);
}

fn rawJson(arena: std.mem.Allocator, value: json.Value) error{OutOfMemory}![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    errdefer out.deinit();
    var ws: json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    ws.write(value) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

// ===========================================================================
// Tests (docs/specs/turn.md contract)
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
        try testing.expectError(error.IllegalTransition, Fsm.apply(.stopped, e));
        try testing.expectError(error.IllegalTransition, Fsm.apply(.failed, e));
    }
}

test "step budget: provisioning + step_budget_exhausted stops" {
    try testing.expectEqual(State.stopped, try Fsm.apply(.provisioning, .step_budget_exhausted));
}

// -- Driver: fake provider + fake tool over the real bus ----------------------

const Harness = struct {
    registry: inproc.Registry,
    actor: actor_mod.Actor,
    kernel: std.Thread,
    orch: *TurnOrchestrator,
    provider: *FakeProvider,
    tool: *FakeTool,
    caller: *inproc.Worker,

    fn init(gpa: std.mem.Allocator, script: []const []const u8) !*Harness {
        const self = try gpa.create(Harness);
        self.registry = inproc.Registry.init(gpa, null);
        self.actor = try actor_mod.Actor.init(gpa, .{}, self.registry.outbound());
        self.kernel = try std.Thread.spawn(.{}, actor_mod.Actor.run, .{&self.actor});
        self.orch = try TurnOrchestrator.start(gpa, &self.actor, &self.registry);
        self.provider = try FakeProvider.start(gpa, &self.actor, &self.registry, script);
        self.tool = try FakeTool.start(gpa, &self.actor, &self.registry);
        self.caller = try inproc.Worker.spawn(gpa, &self.actor, &self.registry, "test-caller");
        return self;
    }

    fn deinit(self: *Harness) void {
        const gpa = self.actor.gpa;
        self.caller.stop();
        self.tool.stop();
        self.provider.stop();
        self.orch.stop();
        self.actor.post(.shutdown);
        self.kernel.join();
        self.actor.deinit();
        self.registry.deinit();
        gpa.destroy(self);
    }

    fn runTurnCall(self: *Harness, request: []const u8) !inproc.CallResult {
        return self.caller.call("zygos::turns::run", request);
    }
};

/// Scripted provider: call N returns script[N] (last entry repeats). Streams
/// two deltas into the request's channel before answering.
const FakeProvider = struct {
    gpa: std.mem.Allocator,
    actor: *actor_mod.Actor,
    worker: *inproc.Worker,
    script: []const []const u8,
    mutex: sync.Mutex = .{},
    calls: usize = 0,
    last_request: ?[]u8 = null,

    fn start(gpa: std.mem.Allocator, actor: *actor_mod.Actor, registry: *inproc.Registry, script: []const []const u8) !*FakeProvider {
        const self = try gpa.create(FakeProvider);
        self.* = .{
            .gpa = gpa,
            .actor = actor,
            .worker = try inproc.Worker.spawn(gpa, actor, registry, "fake-provider"),
            .script = script,
        };
        try self.worker.registerFunction("zygos::provider::fake::messages", self, &handler);
        return self;
    }

    fn stop(self: *FakeProvider) void {
        self.worker.stop();
        if (self.last_request) |r| self.gpa.free(r);
        self.mutex.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    fn handler(ctx: ?*anyopaque, arena: std.mem.Allocator, request_json: []const u8) error{ Failed, OutOfMemory }![]const u8 {
        const self: *FakeProvider = @ptrCast(@alignCast(ctx.?));

        const n = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.last_request) |r| self.gpa.free(r);
            self.last_request = self.gpa.dupe(u8, request_json) catch null;
            const n = self.calls;
            self.calls += 1;
            break :blk n;
        };

        // Stream two deltas over the caller-provided channel.
        const root = json.parseFromSliceLeaky(json.Value, arena, request_json, .{}) catch return error.Failed;
        const chan = root.object.get("stream_channel").?.object;
        var sender = self.actor.channelTakeSender(
            chan.get("channel_id").?.string,
            chan.get("access_key").?.string,
            0,
        ) catch return error.Failed;
        var d1 = "hello ".*;
        var d2 = "world".*;
        sender.push(.{ .text = &d1 }) catch {};
        sender.push(.{ .text = &d2 }) catch {};
        sender.deinit();

        const idx = @min(n, self.script.len - 1);
        return arena.dupe(u8, self.script[idx]);
    }
};

/// Records the last input it was called with; replies {"output":"ran"}.
const FakeTool = struct {
    gpa: std.mem.Allocator,
    worker: *inproc.Worker,
    mutex: sync.Mutex = .{},
    calls: usize = 0,
    last_input: ?[]u8 = null,

    fn start(gpa: std.mem.Allocator, actor: *actor_mod.Actor, registry: *inproc.Registry) !*FakeTool {
        const self = try gpa.create(FakeTool);
        self.* = .{
            .gpa = gpa,
            .worker = try inproc.Worker.spawn(gpa, actor, registry, "fake-tool"),
        };
        try self.worker.registerFunction("test::tool::run", self, &handler);
        return self;
    }

    fn stop(self: *FakeTool) void {
        self.worker.stop();
        if (self.last_input) |r| self.gpa.free(r);
        self.mutex.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    fn handler(ctx: ?*anyopaque, arena: std.mem.Allocator, request_json: []const u8) error{ Failed, OutOfMemory }![]const u8 {
        const self: *FakeTool = @ptrCast(@alignCast(ctx.?));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.last_input) |r| self.gpa.free(r);
        self.last_input = self.gpa.dupe(u8, request_json) catch null;
        self.calls += 1;
        return arena.dupe(u8, "{\"output\":\"ran\"}");
    }
};

const end_turn_msg =
    \\{"stop_reason":"end_turn","content":[{"type":"text","text":"done"}]}
;
const tool_use_msg =
    \\{"stop_reason":"tool_use","content":[{"type":"text","text":"checking"},
    \\ {"type":"tool_use","id":"toolu_1","name":"runner","input":{"command":"echo hi"}}]}
;

fn baseRequest(comptime tools_extra: []const u8) []const u8 {
    return
    \\{"model":"fake-1","system":"you are a test","max_steps":4,
    \\ "provider_function":"zygos::provider::fake::messages",
    \\ "messages":[{"role":"user","content":"go"}],
    \\ "tools":[{"name":"runner","function_id":"test::tool::run"
    ++ tools_extra ++
        \\}]}
    ;
}

test "text-only turn: one step, stops end_turn, transcript has assistant text" {
    var h = try Harness.init(testing.allocator, &.{end_turn_msg});
    defer h.deinit();

    const res = try h.runTurnCall(baseRequest(""));
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);

    var p = try json.parseFromSlice(json.Value, testing.allocator, res.ok, .{});
    defer p.deinit();
    try testing.expectEqualStrings("end_turn", p.value.object.get("stop").?.string);
    try testing.expectEqual(@as(i64, 1), p.value.object.get("steps").?.integer);
    const transcript = p.value.object.get("transcript").?.array.items;
    try testing.expectEqual(@as(usize, 2), transcript.len); // user + assistant
    try testing.expectEqualStrings("assistant", transcript[1].object.get("role").?.string);
}

test "tool-use turn: tool dispatched over the bus, tool_result in next request, ends end_turn on step 2" {
    var h = try Harness.init(testing.allocator, &.{ tool_use_msg, end_turn_msg });
    defer h.deinit();

    const res = try h.runTurnCall(baseRequest(""));
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);

    var p = try json.parseFromSlice(json.Value, testing.allocator, res.ok, .{});
    defer p.deinit();
    try testing.expectEqualStrings("end_turn", p.value.object.get("stop").?.string);
    try testing.expectEqual(@as(i64, 2), p.value.object.get("steps").?.integer);

    // The tool ran with the model's input.
    h.tool.mutex.lock();
    try testing.expectEqual(@as(usize, 1), h.tool.calls);
    try testing.expect(std.mem.indexOf(u8, h.tool.last_input.?, "echo hi") != null);
    h.tool.mutex.unlock();

    // The second provider request carried the tool_result (T4 core).
    h.provider.mutex.lock();
    const second_req = h.provider.last_request.?;
    try testing.expect(std.mem.indexOf(u8, second_req, "tool_result") != null);
    try testing.expect(std.mem.indexOf(u8, second_req, "toolu_1") != null);
    try testing.expect(std.mem.indexOf(u8, second_req, "\"is_error\":false") != null);
    h.provider.mutex.unlock();
}

test "unknown tool name yields is_error tool_result and the turn continues" {
    const bad_tool_msg =
        \\{"stop_reason":"tool_use","content":[
        \\ {"type":"tool_use","id":"toolu_9","name":"nonexistent","input":{}}]}
    ;
    var h = try Harness.init(testing.allocator, &.{ bad_tool_msg, end_turn_msg });
    defer h.deinit();

    const res = try h.runTurnCall(baseRequest(""));
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);

    var p = try json.parseFromSlice(json.Value, testing.allocator, res.ok, .{});
    defer p.deinit();
    try testing.expectEqualStrings("end_turn", p.value.object.get("stop").?.string);

    h.provider.mutex.lock();
    try testing.expect(std.mem.indexOf(u8, h.provider.last_request.?, "\"is_error\":true") != null);
    h.provider.mutex.unlock();
}

test "tool marked requires_approval routes through awaiting_approval and still dispatches" {
    var h = try Harness.init(testing.allocator, &.{ tool_use_msg, end_turn_msg });
    defer h.deinit();

    const res = try h.runTurnCall(baseRequest(",\"requires_approval\":true"));
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);

    h.tool.mutex.lock();
    try testing.expectEqual(@as(usize, 1), h.tool.calls); // auto-approved through the states
    h.tool.mutex.unlock();
}

test "provider error fails the turn with a failed stop" {
    var h = try Harness.init(testing.allocator, &.{end_turn_msg});
    defer h.deinit();

    const req =
        \\{"model":"fake-1","provider_function":"zygos::provider::missing",
        \\ "messages":[{"role":"user","content":"go"}]}
    ;
    const res = try h.runTurnCall(req);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);

    var p = try json.parseFromSlice(json.Value, testing.allocator, res.ok, .{});
    defer p.deinit();
    try testing.expectEqualStrings("failed", p.value.object.get("stop").?.string);
    try testing.expectEqualStrings("function_not_found", p.value.object.get("error").?.string);
}

test "max_steps exhausts cleanly" {
    // Provider always wants tools → the budget is the only way out.
    var h = try Harness.init(testing.allocator, &.{tool_use_msg});
    defer h.deinit();

    const res = try h.runTurnCall(baseRequest(""));
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);

    var p = try json.parseFromSlice(json.Value, testing.allocator, res.ok, .{});
    defer p.deinit();
    try testing.expectEqualStrings("max_steps", p.value.object.get("stop").?.string);
    try testing.expectEqual(@as(i64, 4), p.value.object.get("steps").?.integer);
}

test "deltas streamed over the kernel channel are captured in order" {
    var h = try Harness.init(testing.allocator, &.{end_turn_msg});
    defer h.deinit();

    const res = try h.runTurnCall(baseRequest(""));
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);

    var p = try json.parseFromSlice(json.Value, testing.allocator, res.ok, .{});
    defer p.deinit();
    try testing.expectEqualStrings("hello world", p.value.object.get("deltas").?.string);
}

const DeltaCapture = struct {
    gpa: std.mem.Allocator,
    mutex: sync.Mutex = .{},
    turn_ids: std.ArrayList([]u8) = .empty,
    chunks: std.ArrayList([]u8) = .empty,

    fn onDelta(ctx: *anyopaque, turn_id: []const u8, bytes: []const u8) void {
        const self: *DeltaCapture = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        // Copies only: the observer contract forbids retaining the slices.
        const tid = self.gpa.dupe(u8, turn_id) catch return;
        const chunk = self.gpa.dupe(u8, bytes) catch {
            self.gpa.free(tid);
            return;
        };
        self.turn_ids.append(self.gpa, tid) catch self.gpa.free(tid);
        self.chunks.append(self.gpa, chunk) catch self.gpa.free(chunk);
    }

    fn observer(self: *DeltaCapture) DeltaObserver {
        return .{ .ctx = @ptrCast(self), .onDelta = &onDelta };
    }

    fn deinit(self: *DeltaCapture) void {
        for (self.turn_ids.items) |t| self.gpa.free(t);
        self.turn_ids.deinit(self.gpa);
        for (self.chunks.items) |c| self.gpa.free(c);
        self.chunks.deinit(self.gpa);
        self.mutex.deinit();
    }
};

test "delta observer sees every delta in order with the turn id" {
    var h = try Harness.init(testing.allocator, &.{end_turn_msg});
    defer h.deinit();
    var cap = DeltaCapture{ .gpa = testing.allocator };
    defer cap.deinit();
    h.orch.setDeltaObserver(cap.observer());

    const res = try h.runTurnCall(
        \\{"model":"fake-1","system":"s","max_steps":4,"turn_id":"t-obs",
        \\ "provider_function":"zygos::provider::fake::messages",
        \\ "messages":[{"role":"user","content":"go"}]}
    );
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);

    try testing.expectEqual(@as(usize, 2), cap.chunks.items.len);
    try testing.expectEqualStrings("hello ", cap.chunks.items[0]);
    try testing.expectEqualStrings("world", cap.chunks.items[1]);
    for (cap.turn_ids.items) |tid| try testing.expectEqualStrings("t-obs", tid);
}

test "usage trace event is emitted per step even without a budget scope" {
    var h = try Harness.init(testing.allocator, &.{usage_end_msg});
    defer h.deinit();

    const UsageSink = struct {
        gpa: std.mem.Allocator,
        mutex: sync.Mutex = .{},
        lines: std.ArrayList([]u8) = .empty,

        fn onEvent(ctx: *anyopaque, line: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (std.mem.indexOf(u8, line, "\"event\":\"usage\"") == null) return;
            self.mutex.lock();
            defer self.mutex.unlock();
            const copy = self.gpa.dupe(u8, line) catch return;
            self.lines.append(self.gpa, copy) catch self.gpa.free(copy);
        }
    };
    var cap = UsageSink{ .gpa = testing.allocator };
    defer {
        for (cap.lines.items) |l| testing.allocator.free(l);
        cap.lines.deinit(testing.allocator);
        cap.mutex.deinit();
    }
    const token = trace_mod.registerSink(.{ .ctx = @ptrCast(&cap), .onEvent = &UsageSink.onEvent }) orelse
        return error.NoSlot;
    defer trace_mod.unregisterSink(token);

    // No trace_path and no budget_scope in the request: usage still traces.
    const res = try h.runTurnCall(baseRequest(""));
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);

    try testing.expectEqual(@as(usize, 1), cap.lines.items.len);
    try testing.expect(std.mem.indexOf(u8, cap.lines.items[0], "\"input_tokens\":7") != null);
    try testing.expect(std.mem.indexOf(u8, cap.lines.items[0], "\"output_tokens\":3") != null);
    try testing.expect(std.mem.indexOf(u8, cap.lines.items[0], "\"step\":1") != null);
}

fn shoutCompressor(_: ?*anyopaque, arena: std.mem.Allocator, request_json: []const u8) error{ Failed, OutOfMemory }![]const u8 {
    const root = json.parseFromSliceLeaky(json.Value, arena, request_json, .{}) catch return error.Failed;
    const content = root.object.get("content").?.string;
    const upper = try arena.dupe(u8, content);
    for (upper) |*ch| ch.* = std.ascii.toUpper(ch.*);
    return std.fmt.allocPrint(arena, "{{\"content\":{f}}}", .{json.fmt(upper, .{})});
}

test "output::compress seam transforms tool_results when registered; pass-through otherwise" {
    var h = try Harness.init(testing.allocator, &.{ tool_use_msg, end_turn_msg });
    defer h.deinit();

    // Pass-through is pinned by the other tool tests (no compressor there).
    const compressor = try inproc.Worker.spawn(testing.allocator, &h.actor, &h.registry, "compressor");
    defer compressor.stop();
    try compressor.registerFunction("zygos::output::compress", null, &shoutCompressor);

    const res = try h.runTurnCall(baseRequest(""));
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);

    // The fake tool replies {"output":"ran"}; the seam uppercased it before
    // it entered the transcript's tool_result.
    h.provider.mutex.lock();
    defer h.provider.mutex.unlock();
    try testing.expect(std.mem.indexOf(u8, h.provider.last_request.?, "OUTPUT") != null);
    try testing.expect(std.mem.indexOf(u8, h.provider.last_request.?, "RAN") != null);
}

extern "c" fn realpath(path: [*:0]const u8, resolved: [*]u8) ?[*:0]u8;

test "trace_path captures step, tool call/result and turn end as JSONL events" {
    var h = try Harness.init(testing.allocator, &.{ tool_use_msg, end_turn_msg });
    defer h.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var rel_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rel = try std.fmt.bufPrintZ(&rel_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = std.mem.span(realpath(rel, &dir_buf) orelse return error.RealpathFailed);
    const tpath = try std.fmt.allocPrint(testing.allocator, "{s}/events.jsonl", .{dir});
    defer testing.allocator.free(tpath);

    const req = try std.fmt.allocPrint(testing.allocator,
        \\{{"model":"fake-1","system":"t","max_steps":4,"turn_id":"tr-1",
        \\ "provider_function":"zygos::provider::fake::messages",
        \\ "trace_path":{f},
        \\ "messages":[{{"role":"user","content":"go"}}],
        \\ "tools":[{{"name":"runner","function_id":"test::tool::run"}}]}}
    , .{json.fmt(tpath, .{})});
    defer testing.allocator.free(req);

    const res = try h.runTurnCall(req);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);

    const text = trace_mod.readFile(testing.allocator, tpath) orelse return error.ReadFailed;
    defer testing.allocator.free(text);

    // Every event kind fired, each line parses, payloads are visible.
    try testing.expect(std.mem.indexOf(u8, text, "\"event\":\"step\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"event\":\"tool_call\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "echo hi") != null); // tool input
    try testing.expect(std.mem.indexOf(u8, text, "\"event\":\"tool_result\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "ran") != null); // tool output
    try testing.expect(std.mem.indexOf(u8, text, "\"event\":\"turn_end\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"stop\":\"end_turn\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"turn_id\":\"tr-1\"") != null);

    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    while (lines.next()) |line| {
        var p = try json.parseFromSlice(json.Value, testing.allocator, line, .{});
        defer p.deinit();
        try testing.expect(p.value == .object);
    }
}

test "no leaks under a multi-step turn" {
    var h = try Harness.init(testing.allocator, &.{ tool_use_msg, tool_use_msg, end_turn_msg });
    defer h.deinit();

    const res = try h.runTurnCall(baseRequest(""));
    res.deinit(testing.allocator);
}

// -- M2 driver: policy gate + approval + abort/steer (spec contract 13-25) ----

const policy_mod = @import("policy.zig");
const approval_mod = @import("approval.zig");

/// baseRequest with extra top-level fields spliced in.
fn requestWith(comptime top_extra: []const u8) []const u8 {
    return
    \\{"model":"fake-1","system":"you are a test","max_steps":4,
    \\ "provider_function":"zygos::provider::fake::messages",
    ++ top_extra ++
        \\ "messages":[{"role":"user","content":"go"}],
        \\ "tools":[{"name":"runner","function_id":"test::tool::run"}]}
    ;
}

test "policy deny yields is_error tool_result and the turn continues" {
    var h = try Harness.init(testing.allocator, &.{ tool_use_msg, end_turn_msg });
    defer h.deinit();
    // No rules at all: the gate's fail-closed default denies everything.
    const pw = try policy_mod.PolicyWorker.start(testing.allocator, &h.actor, &h.registry, &.{});
    defer pw.stop();

    const res = try h.runTurnCall(requestWith("\"policy_function\":\"zygos::policy::check\","));
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);

    var p = try json.parseFromSlice(json.Value, testing.allocator, res.ok, .{});
    defer p.deinit();
    try testing.expectEqualStrings("end_turn", p.value.object.get("stop").?.string);
    try testing.expectEqual(@as(i64, 2), p.value.object.get("steps").?.integer);
    try testing.expect(std.mem.indexOf(u8, res.ok, "policy_denied") != null);

    h.tool.mutex.lock();
    defer h.tool.mutex.unlock();
    try testing.expectEqual(@as(usize, 0), h.tool.calls); // never dispatched
}

test "policy ask + approval approve dispatches the tool" {
    var h = try Harness.init(testing.allocator, &.{ tool_use_msg, end_turn_msg });
    defer h.deinit();
    const pw = try policy_mod.PolicyWorker.start(testing.allocator, &h.actor, &h.registry, &.{
        .{ .tool = "runner", .verdict = .ask },
    });
    defer pw.stop();
    const aw = try approval_mod.ApprovalWorker.start(testing.allocator, &h.actor, &h.registry, .auto_approve);
    defer aw.stop();

    const res = try h.runTurnCall(requestWith(
        "\"policy_function\":\"zygos::policy::check\",\"approval_function\":\"zygos::approvals::request\",",
    ));
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try testing.expect(std.mem.indexOf(u8, res.ok, "\"stop\":\"end_turn\"") != null);

    h.tool.mutex.lock();
    defer h.tool.mutex.unlock();
    try testing.expectEqual(@as(usize, 1), h.tool.calls);
}

test "policy ask + approval deny yields approval_denied result, no dispatch" {
    var h = try Harness.init(testing.allocator, &.{ tool_use_msg, end_turn_msg });
    defer h.deinit();
    const pw = try policy_mod.PolicyWorker.start(testing.allocator, &h.actor, &h.registry, &.{
        .{ .tool = "runner", .verdict = .ask },
    });
    defer pw.stop();
    const aw = try approval_mod.ApprovalWorker.start(testing.allocator, &h.actor, &h.registry, .auto_deny);
    defer aw.stop();

    const res = try h.runTurnCall(requestWith(
        "\"policy_function\":\"zygos::policy::check\",\"approval_function\":\"zygos::approvals::request\",",
    ));
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try testing.expect(std.mem.indexOf(u8, res.ok, "approval_denied") != null);

    h.tool.mutex.lock();
    defer h.tool.mutex.unlock();
    try testing.expectEqual(@as(usize, 0), h.tool.calls);
}

test "policy function unreachable denies (fail closed)" {
    var h = try Harness.init(testing.allocator, &.{ tool_use_msg, end_turn_msg });
    defer h.deinit();
    // No policy worker registered at all → function_not_found on the bus.

    const res = try h.runTurnCall(requestWith("\"policy_function\":\"zygos::policy::check\","));
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try testing.expect(std.mem.indexOf(u8, res.ok, "policy_denied") != null);

    h.tool.mutex.lock();
    defer h.tool.mutex.unlock();
    try testing.expectEqual(@as(usize, 0), h.tool.calls);
}

fn weirdVerdict(_: ?*anyopaque, arena: std.mem.Allocator, _: []const u8) error{ Failed, OutOfMemory }![]const u8 {
    return arena.dupe(u8, "{\"verdict\":\"maybe\",\"reason\":\"shrug\"}");
}

test "malformed policy verdict denies (fail closed)" {
    var h = try Harness.init(testing.allocator, &.{ tool_use_msg, end_turn_msg });
    defer h.deinit();
    const weird = try inproc.Worker.spawn(testing.allocator, &h.actor, &h.registry, "weird-policy");
    defer weird.stop();
    try weird.registerFunction("zygos::policy::check", null, &weirdVerdict);

    const res = try h.runTurnCall(requestWith("\"policy_function\":\"zygos::policy::check\","));
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try testing.expect(std.mem.indexOf(u8, res.ok, "policy_denied") != null);

    h.tool.mutex.lock();
    defer h.tool.mutex.unlock();
    try testing.expectEqual(@as(usize, 0), h.tool.calls);
}

/// Y2: policy gate sees web_fetch's tool input (URL) on the policy request.
/// Records the last check payload and always allows so the tool still dispatches.
const RecordingPolicy = struct {
    gpa: std.mem.Allocator,
    worker: *inproc.Worker,
    mutex: sync.Mutex = .{},
    last_request: ?[]u8 = null,

    fn start(gpa: std.mem.Allocator, actor: *actor_mod.Actor, registry: *inproc.Registry) !*RecordingPolicy {
        const self = try gpa.create(RecordingPolicy);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .worker = try inproc.Worker.spawn(gpa, actor, registry, "recording-policy"),
        };
        errdefer self.worker.stop();
        try self.worker.registerFunction("zygos::policy::check", self, &handler);
        return self;
    }

    fn stop(self: *RecordingPolicy) void {
        self.worker.stop();
        if (self.last_request) |r| self.gpa.free(r);
        self.mutex.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    fn handler(ctx: ?*anyopaque, arena: std.mem.Allocator, request_json: []const u8) error{ Failed, OutOfMemory }![]const u8 {
        const self: *RecordingPolicy = @ptrCast(@alignCast(ctx.?));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.last_request) |r| self.gpa.free(r);
        self.last_request = self.gpa.dupe(u8, request_json) catch null;
        return arena.dupe(u8, "{\"verdict\":\"allow\",\"reason\":\"recorded\"}");
    }
};

const web_fetch_tool_use =
    \\{"stop_reason":"tool_use","content":[
    \\ {"type":"tool_use","id":"toolu_wf","name":"web_fetch","input":{"url":"https://example.com/page"}}]}
;

test "web_fetch dispatch consults policy with URL riding the policy request input" {
    var h = try Harness.init(testing.allocator, &.{ web_fetch_tool_use, end_turn_msg });
    defer h.deinit();
    const rp = try RecordingPolicy.start(testing.allocator, &h.actor, &h.registry);
    defer rp.stop();

    // Map web_fetch → the harness FakeTool (test::tool::run). Policy still
    // sees the model tool name + its input object with the URL.
    const req =
        \\{"model":"fake-1","system":"you are a test","max_steps":4,
        \\ "provider_function":"zygos::provider::fake::messages",
        \\ "policy_function":"zygos::policy::check",
        \\ "messages":[{"role":"user","content":"fetch it"}],
        \\ "tools":[{"name":"web_fetch","function_id":"test::tool::run"}]}
    ;
    const res = try h.runTurnCall(req);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);

    rp.mutex.lock();
    defer rp.mutex.unlock();
    try testing.expect(rp.last_request != null);
    const preq = rp.last_request.?;
    try testing.expect(std.mem.indexOf(u8, preq, "web_fetch") != null);
    try testing.expect(std.mem.indexOf(u8, preq, "https://example.com/page") != null);
    try testing.expect(std.mem.indexOf(u8, preq, "\"input\"") != null);

    h.tool.mutex.lock();
    defer h.tool.mutex.unlock();
    try testing.expectEqual(@as(usize, 1), h.tool.calls);
    try testing.expect(std.mem.indexOf(u8, h.tool.last_input.?, "https://example.com/page") != null);
}

/// A tool whose handler makes a bus call of its own before replying — the
/// deterministic way to hit turns::abort/steer mid-turn (the blocking call
/// completes before the tool result reaches the driver). Registers on
/// test::tool::run AFTER the harness FakeTool: last-registration-wins (S2).
const CallingTool = struct {
    gpa: std.mem.Allocator,
    worker: *inproc.Worker,
    target: []const u8,
    payload: []const u8,

    fn start(
        gpa: std.mem.Allocator,
        actor: *actor_mod.Actor,
        registry: *inproc.Registry,
        target: []const u8,
        payload: []const u8,
    ) !*CallingTool {
        const self = try gpa.create(CallingTool);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .worker = try inproc.Worker.spawn(gpa, actor, registry, "calling-tool"),
            .target = target,
            .payload = payload,
        };
        errdefer self.worker.stop();
        try self.worker.registerFunction("test::tool::run", self, &handler);
        return self;
    }

    fn stop(self: *CallingTool) void {
        self.worker.stop();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    fn handler(ctx: ?*anyopaque, arena: std.mem.Allocator, _: []const u8) error{ Failed, OutOfMemory }![]const u8 {
        const self: *CallingTool = @ptrCast(@alignCast(ctx.?));
        const res = self.worker.call(self.target, self.payload) catch return error.Failed;
        res.deinit(self.gpa);
        return arena.dupe(u8, "{\"output\":\"called\"}");
    }
};

test "abort between steps stops the turn with aborted" {
    var h = try Harness.init(testing.allocator, &.{tool_use_msg}); // provider always wants tools
    defer h.deinit();
    const aborter = try CallingTool.start(
        testing.allocator,
        &h.actor,
        &h.registry,
        "zygos::turns::abort",
        "{\"turn_id\":\"t-abort\"}",
    );
    defer aborter.stop();

    const res = try h.runTurnCall(requestWith("\"turn_id\":\"t-abort\","));
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);

    var p = try json.parseFromSlice(json.Value, testing.allocator, res.ok, .{});
    defer p.deinit();
    try testing.expectEqualStrings("aborted", p.value.object.get("stop").?.string);
    try testing.expectEqual(@as(i64, 1), p.value.object.get("steps").?.integer);
}

test "steer text lands in the next step's messages" {
    var h = try Harness.init(testing.allocator, &.{ tool_use_msg, end_turn_msg });
    defer h.deinit();
    const steerer = try CallingTool.start(
        testing.allocator,
        &h.actor,
        &h.registry,
        "zygos::turns::steer",
        "{\"turn_id\":\"t-steer\",\"text\":\"focus on X instead\"}",
    );
    defer steerer.stop();

    const res = try h.runTurnCall(requestWith("\"turn_id\":\"t-steer\","));
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try testing.expect(std.mem.indexOf(u8, res.ok, "\"stop\":\"end_turn\"") != null);

    // The steered text rode the step-2 provider request.
    h.provider.mutex.lock();
    defer h.provider.mutex.unlock();
    try testing.expect(std.mem.indexOf(u8, h.provider.last_request.?, "focus on X instead") != null);
}

// -- M2 driver: per-step routing + failover (spec contract 18-20) -----------

const router_mod = @import("router.zig");

fn startRouter(h: *Harness, zon: [:0]const u8) !*router_mod.RouterWorker {
    const cfg = try router_mod.Config.parse(testing.allocator, zon);
    return router_mod.RouterWorker.start(testing.allocator, &h.actor, &h.registry, cfg);
}

const routed_request =
    \\{"router_function":"zygos::models::resolve","step_id":"exec","max_steps":4,
    \\ "messages":[{"role":"user","content":"go"}],
    \\ "tools":[{"name":"runner","function_id":"test::tool::run"}]}
;

test "router resolves the provider and model per step" {
    var h = try Harness.init(testing.allocator, &.{end_turn_msg});
    defer h.deinit();
    const rw = try startRouter(h,
        \\.{ .routes = .{ .{ .step_id = "exec", .attempts = .{
        \\    .{ .provider_function = "zygos::provider::fake::messages", .model = "fake-routed" },
        \\} } } }
    );
    defer rw.stop();

    const res = try h.runTurnCall(routed_request);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try testing.expect(std.mem.indexOf(u8, res.ok, "\"stop\":\"end_turn\"") != null);

    // The routed model rode the provider request.
    h.provider.mutex.lock();
    defer h.provider.mutex.unlock();
    try testing.expect(std.mem.indexOf(u8, h.provider.last_request.?, "fake-routed") != null);
}

test "provider failure fails over to the next attempt and succeeds" {
    var h = try Harness.init(testing.allocator, &.{end_turn_msg});
    defer h.deinit();
    const rw = try startRouter(h,
        \\.{ .routes = .{ .{ .step_id = "exec", .attempts = .{
        \\    .{ .provider_function = "zygos::provider::missing::messages", .model = "ghost" },
        \\    .{ .provider_function = "zygos::provider::fake::messages", .model = "fallback-model" },
        \\} } } }
    );
    defer rw.stop();

    const res = try h.runTurnCall(routed_request);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);

    var p = try json.parseFromSlice(json.Value, testing.allocator, res.ok, .{});
    defer p.deinit();
    try testing.expectEqualStrings("end_turn", p.value.object.get("stop").?.string);
    // The failed attempt did not count as a step.
    try testing.expectEqual(@as(i64, 1), p.value.object.get("steps").?.integer);

    h.provider.mutex.lock();
    defer h.provider.mutex.unlock();
    try testing.expect(std.mem.indexOf(u8, h.provider.last_request.?, "fallback-model") != null);
}

// -- M2 driver: budget enforcement (spec contract 21-23) --------------------

const budget_mod = @import("budget.zig");

const usage_tool_msg =
    \\{"stop_reason":"tool_use","usage":{"input_tokens":10,"output_tokens":2},
    \\ "content":[{"type":"tool_use","id":"toolu_b","name":"runner","input":{"command":"x"}}]}
;
const usage_end_msg =
    \\{"stop_reason":"end_turn","usage":{"input_tokens":7,"output_tokens":3},
    \\ "content":[{"type":"text","text":"ok"}]}
;

test "budget exhausted stops the turn before the next step" {
    var h = try Harness.init(testing.allocator, &.{usage_tool_msg});
    defer h.deinit();
    const bw = try budget_mod.BudgetWorker.start(testing.allocator, &h.actor, &h.registry);
    defer bw.stop();

    const conf = try h.caller.call("zygos::budget::configure", "{\"scope\":\"turn-b\",\"max_tokens\":5}");
    conf.deinit(testing.allocator);

    const res = try h.runTurnCall(requestWith("\"budget_scope\":\"turn-b\","));
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);

    var p = try json.parseFromSlice(json.Value, testing.allocator, res.ok, .{});
    defer p.deinit();
    // Step 1 recorded 12 tokens against a 5-token budget; step 2 never ran.
    try testing.expectEqualStrings("budget_exhausted", p.value.object.get("stop").?.string);
    try testing.expectEqual(@as(i64, 1), p.value.object.get("steps").?.integer);
}

test "budget check unreachable stops the turn (fail closed)" {
    var h = try Harness.init(testing.allocator, &.{end_turn_msg});
    defer h.deinit();
    // No budget worker on the bus at all.

    const res = try h.runTurnCall(requestWith("\"budget_scope\":\"turn-b\","));
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);

    var p = try json.parseFromSlice(json.Value, testing.allocator, res.ok, .{});
    defer p.deinit();
    try testing.expectEqualStrings("budget_exhausted", p.value.object.get("stop").?.string);
    try testing.expectEqual(@as(i64, 0), p.value.object.get("steps").?.integer);
}

test "provider usage is recorded to the budget scope" {
    var h = try Harness.init(testing.allocator, &.{usage_end_msg});
    defer h.deinit();
    const bw = try budget_mod.BudgetWorker.start(testing.allocator, &h.actor, &h.registry);
    defer bw.stop();

    const res = try h.runTurnCall(requestWith("\"budget_scope\":\"turn-u\","));
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try testing.expect(std.mem.indexOf(u8, res.ok, "\"stop\":\"end_turn\"") != null);

    const c = try h.caller.call("zygos::budget::check", "{\"scope\":\"turn-u\"}");
    defer c.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, c.ok, "\"used_tokens\":10") != null);
}

test "routes exhausted fails the turn with route_exhausted" {
    var h = try Harness.init(testing.allocator, &.{end_turn_msg});
    defer h.deinit();
    const rw = try startRouter(h,
        \\.{ .routes = .{ .{ .step_id = "exec", .attempts = .{
        \\    .{ .provider_function = "zygos::provider::missing::messages", .model = "ghost" },
        \\} } } }
    );
    defer rw.stop();

    const res = try h.runTurnCall(routed_request);
    defer res.deinit(testing.allocator);
    try testing.expect(res == .ok);
    try testing.expect(std.mem.indexOf(u8, res.ok, "\"stop\":\"failed\"") != null);
    try testing.expect(std.mem.indexOf(u8, res.ok, "route_exhausted") != null);
}
