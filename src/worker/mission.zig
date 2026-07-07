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
    tasks: []Task = &.{},
    task_index: usize = 0,
    fail_count: usize = 0,
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
